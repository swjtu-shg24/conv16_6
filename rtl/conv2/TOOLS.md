# rtl/conv2 脚本工具总表（TOOLS）

> 这份文档回答三件事：**有哪些脚本能直接跑**、**怎么调用**、**看到什么才算过**。
> 所有命令都在**工程根目录**执行（`D:\my_code\fpga\yilisi\conv10_10`）。
> `.bat` 自己会 `cd` 到工程根，所以双击也行。

## 0. 最常用的三条

| 想干的事 | 命令 | 时间 |
|---|---|---|
| **验收总闸**（5 步，全绿才算工程是好的） | `rtl\conv2\sim\check_fixed_point.bat` | ~20 分钟 |
| **L1+L2 端到端判据**（整帧，从 plane 全量回读） | `vsim -c -do rtl/conv2/sim/run_l2.do` | 8~15 分钟 |
| **看"从输入到 L2 输出"的完整波形**（GUI，15 组） | `rtl\conv2\sim\run_wave_l2.bat` | 编译 ~2 分钟 + 仿真 |

ModelSim 工具必须按**全路径**调用（`D:\modeltech64_10.4\win64\vsim.exe`），`.bat` 里已经处理；
手工敲命令时若 `MODEL_TECH` 没设，裸名 `vsim` 会找不到 `modelsim.ini`。

---

## 1. 目录速查

```
rtl/conv2/
├── README.md            工程总说明（定点口径、模块清单、坑表）
├── TOOLS.md             本文件
├── filelist.f           顶层全量清单（顶层一次编全部）
├── conv_top.v           顶层（纯结构例化）
├── tb/                  顶层端到端 tb
├── sim/                 仿真脚本（run_* / wave_* / count_bram / check_fixed_point）
├── doc/                 HANDOFF.md（交接）/ WORKLOG.md（日志）/ L2_PLAN.md（方案）
├── conv_*/              每个模块一个文件夹，自包含（.v + tb + filelist.f + run.bat + run.do）
├── board/               板级顶层 + tb_board + sdc
├── picture_and_para/    激励/golden 生成与对拍（Python）+ test.jpg + .pth
└── probe/               手工探针（综合崩溃时二分定位用，不是自检 tb）
```

---

## 2. 一键总闸 —— `sim/check_fixed_point.bat`

```bat
rtl\conv2\sim\check_fixed_point.bat
```

依次跑 5 步，任一步 `findstr` 找不到 `... RESULT: PASS` 就立刻停并 `exit /b 1`：

| 步 | 做什么 | 判据字符串 |
|---|---|---|
| 0 | `picture_and_para/gen_stim.py` 重新生成激励 + golden + ROM | — |
| 1 | `sim/run_real.do` → `tb_top_real`：L1 整帧 768 tile + 30720 unit 全比对 | `TB_TOP_REAL RESULT: PASS` |
| 2 | `make_table.py`：RTL 逐级数据 vs golden 成表 | `MAKE_TABLE RESULT: PASS` |
| 3 | `fpga_l1_int_dump.py`：**独立整数实现** vs RTL golden | `FPGA_L1_INT_DUMP RESULT: PASS` |
| 4 | `sim/run_l2.do` → `tb_top_l2`：L1+L2 两面全量回读 + 3 tile 逐级 + 全帧转储 | `TB_TOP_L2 RESULT: PASS` |
| 4a | `compare_l2_dump.py`：L2 三级数据 vs golden | `MAKE_TABLE_L2 RESULT: PASS` |
| 4b | `dump_all_report.py`：全帧转储比对 + 出图 | `DUMP_ALL_REPORT RESULT: PASS` |

> 结尾打印：成功 `FIXED-POINT ERROR = 0  --  ALL CHECKS PASS`，失败 `FIXED-POINT CHECK FAILED`（`exit /b 1`）。
> 最后有 `pause`；在脚本/CI 里跑要 `< nul` 让 `pause` 直接过。
> **判据是"定点误差 = 0"**（逐点整数相同），浮点误差不是判据。

---

## 3. 顶层仿真脚本（`sim/`）

| 脚本 | 跑哪个 tb | 仿真什么 | 判据 | 时间 |
|---|---|---|---|---|
| `run.do` | `tb_top` | 小图 80×40×3 → 40×20×8 | `TB_TOP RESULT: PASS` | ~1 分钟 |
| `run_full.do` | `tb_top_full` | 整帧 320×240×3 → 160×120×8（L1） | `TB_TOP_FULL RESULT: PASS` | ~3.5 分钟 |
| `run_real.do` | `tb_top_real` | **真实 test.jpg + 真实权重 ROM**，L1 整帧 + 3 tile 逐级 + 30720 unit 全比对 | `TB_TOP_REAL RESULT: PASS`（预期 118,943 拍 / 30,720 unit / 失败 0） | ~3.5 分钟 |
| `run_l2.do` | `tb_top_l2` | **L1+L2 端到端**：L1 面回读 → 放行 L2 → 整面回读；L2 3 个 tile 逐级 + 12×12 窗口 | `TB_TOP_L2 RESULT: PASS`（见 §7 数字） | 8~15 分钟 |
| `count_bram.do` | `tb_top_full`（只 elaboration） | 数 `bram_10kb` 实际片数 | `total : 140 片 (expect 140 / 256 = 54.7%)` | 秒级 |
| `run.bat` | 全部 | ① 全量编译 ② 各模块 `run.do` ③ `tb_top` ④ `tb_top_real` | 依次看各 `RESULT` | ~10 分钟 |

调用方式（都在工程根目录）：

```bat
vsim -c -do rtl/conv2/sim/run_l2.do
vsim -c -do rtl/conv2/sim/run_real.do
```

`run_l2.do` 支持参数覆盖，例如只要判据不要全帧转储（快很多）：

```bat
vsim -c -voptargs=+acc -gDUMP_ALL=0 -do rtl/conv2/sim/run_l2.do c2all.tb_top_l2
```

> 每个 `run_*.do` 都会先 `vlib/vmap/vlog` 编到 `rtl/conv2/work`（库名 `c2all`），
> 日志落在 `rtl/conv2/sim/transcript*`。

---

## 4. 波形脚本（GUI）

| 脚本 | tb | 波形内容 | 产物 |
|---|---|---|---|
| `sim/run_wave_l2.bat` → `sim/wave_l2.do` | `tb_top_l2` | ★ **真实数据 L1→L2 全链**，15 组按数据流分组 | `sim/wave_l2.wlf` + `sim/transcript_wave_l2` |
| `sim/run_wave.bat` → `sim/wave_full.do` | `tb_top_full` | L1 整帧链路 | `sim/wave.wlf` + `sim/transcript_wave` |

`run_wave.bat` 可以带一个参数换 tb：`rtl\conv2\sim\run_wave.bat small`（用 `tb_top` 小图，秒级）。

手工等价命令：

```bat
vsim -gui -voptargs=+acc -gDUMP_ALL=0 -l rtl/conv2/sim/transcript_wave_l2 ^
     -wlf rtl/conv2/sim/wave_l2.wlf -do rtl/conv2/sim/wave_l2.do c2all.tb_top_l2
```

时间轴（@10ns/拍，整帧 262,016 拍 ≈ 2.62 ms）：

```
0 ─── L1 相位（cfg_l2=0，768 tile，118,943 拍）≈1.19ms
   ─── L1 面回读 30,720 unit
   ─── L2 相位（cfg_l2=1，192 tile，81,574 拍）≈2.01ms
   ─── 整面回读 + 收尾 ≈2.62ms
```

想直接跳到 L2：看第 0 组的 `cfg_l2` / `l2_go` / `u_top/l2_run`。

> `.do` 里的信号用**相对名**，名字对不上只打印一行 `[wave-skip]`，不会中断脚本。
> 带下标的信号必须写成 `{...[0]}`（Tcl 里 `[ ]` 是命令替换）。

---

## 5. 模块自检（每个模块文件夹）

每个模块文件夹都是自包含的，**双击 `run.bat`** 或：

```bat
vsim -c -do rtl/conv2/<模块名>/run.do
```

| 模块 | 脚本 | 测什么 | 判据 |
|---|---|---|---|
| `conv_mem_unit` | `run.do` | SDP 512×20 BRAM 单元（读延迟 1 拍） | `TB_MEM_UNIT RESULT: PASS` |
| `conv_band12` | `run.do` | 12 行环形带（band 读写 + 行跨距） | `TB_BAND RESULT: PASS` |
| `conv_plane` | `run.do` | L1/L2 共用输出面（**含 4 unit/拍宽读口**） | `TB_PLANE RESULT: PASS` |
| `conv_cmp4_tree` | `run.do` | 4 输入比较树 | `TB_CMP4_TREE RESULT: PASS` |
| `conv_pool_arr` | `run.do` | 2×2 有符号 max 池化阵列 | `TB_POOL RESULT: PASS` |
| `conv_win_load` | `run.do` | L1 窗口（band 源，**反射**填充） | `TB_WIN RESULT: PASS` |
| `conv_win_load_plane` | `run.do` | L2 窗口（L1 面源，**零填充**，1536 窗口 + 背靠背） | `TB_WIN_PLANE RESULT: PASS` |
| `conv_wb_fifo` | `run.do` | L2 结果 FIFO + **滞后一个 tile 行**排空回面 | `TB_WB_FIFO RESULT: PASS` |
| `conv_in_dma` | `run.do` | 16B/拍 → 5B/unit 字节重排（Q4.4） | `TB_DMA RESULT: PASS` |
| `conv_sched` | `run.do` | tile 调度 / 窗口仲裁 / 信用 / ch0 预取 / L2 相位 | `TB_SCHED RESULT: PASS` |
| `conv_wrom` | `run.do` | 权重 ROM（L1 67 字 + L2 248 字） | `TB_WROM RESULT: PASS` |
| `conv_l1` | `run.do` | **主入口** `tb_l1`：L1 引擎整片（预期 **S_PW=80 拍**） | `TB_L1 RESULT: PASS` |
| `conv_l1` | `run_dw.do` | dw 相位专项（定抓数拍 / 权重对齐） | `TB_L1_DW RESULT: PASS` |
| `conv_l1` | `run_l2.do` | **L2 引擎单独**（`tb_l2`，秒级；`USE_CFG=1` 走运行时 `cfg_l2`） | `TB_L2 RESULT: PASS` |
| `conv_l1` | `run_time.do` | 只数拍不做比对（开销分析） | 打印拍数 |
| `conv_l1` | `run_trans.do` | **L1→L2 切换复现**（`tb_l1_l2_trans`，秒级） | `TB_L1_L2_TRANS RESULT: PASS` |
| `board` | `run.do` | 板级顶层（含假 DDR，校验和门禁） | `TB_BOARD RESULT: PASS`（校验和应 = `eb131b12a5`） |

> 改完 RTL **必须**重跑的三条 L1 回归：`conv_l1/run.do`（S_PW=80）、`board/run.do`（校验和）、
> `sim/run_real.do`（118,943 拍 / 30,720 unit / 0 失败）。L2 侧再加 `sim/run_l2.do`。

---

## 6. Python 工具（`picture_and_para/`）

Python：`D:\Users\Administrator\anaconda3\envs\cyclegan\python.exe`（下面简写 `python`）。

### 6.1 生成激励 / golden（**判据的唯一来源**）

| 脚本 | 调用 | 产物 |
|---|---|---|
| `stim_model.py` | 不直接跑（**库**：定点口径唯一来源） | 被下面两个 import |
| `gen_stim.py` | `python rtl\conv2\picture_and_para\gen_stim.py` | `conv_wrom/wrom.hex`（315 字）、`img_ddr.hex`、`golden_plane.hex`、`golden_plane_l2.hex`、`l2_win_real.hex`、`l2_golden_real_flat.hex`、`golden_l1_stages.npz`、`golden_l2_stages.npz`、`golden_tiles.txt` |
| `gen_l2_stim.py` | `python rtl\conv2\picture_and_para\gen_l2_stim.py` | `l2_win.hex`、`l2_golden_flat.hex`（给 `tb_l2` 用） |

可选开关：`--bn-running`（用 BN running 统计量而不是逐样本 InstanceNorm）、`--bn-round`（BN 再量化用四舍五入）。
**改口径要同时改 `stim_model.py` / `gen_stim.py` / RTL 参数**，三者必须同源。

### 6.2 对拍与成表（判据类）

| 脚本 | 调用 | 输入 → 输出 | 判据 |
|---|---|---|---|
| `make_table.py` | 直接跑 | `golden_tiles.txt` + `real_dump.txt` → `feature_maps_real.xlsx` | `MAKE_TABLE RESULT: PASS` |
| `compare_l2_dump.py` | 直接跑 | `real_dump_l2.txt` + `l2_golden_real_flat.hex` → `feature_maps_real_l2.xlsx` | `MAKE_TABLE_L2 RESULT: PASS` |
| `dump_all_report.py` | 直接跑 | 4 个 `rtl_dump_*.txt` + `golden_*_stages.npz` → `dump_all/*.png|npy|xlsx` | `DUMP_ALL_REPORT RESULT: PASS` |
| `fpga_l1_int_dump.py` | 直接跑 | 独立整数实现 vs RTL golden → `fpga_l1_*.npy` | `FPGA_L1_INT_DUMP RESULT: PASS` |
| `compare_python.py` | `python ...\compare_python.py <你的.npy或结果>` | 你的 Python 量化结果 vs 本工程 golden | 逐点打印差异 |
| `check_weights.py` | 直接跑 | `gen_stim` 从 `.pth` 解析的权重 vs `netG_B_epoch11_weights.xlsx` | 逐数字比对 |

> `real_dump*.txt` / `rtl_dump_*.txt` 是 **tb 跑出来的中间产物**（`tb_top_real` / `tb_top_l2` 写），
> 删了没关系，重跑 tb 就有。

### 6.3 口径 / 精度分析（一次性，不进门禁）

| 脚本 | 干什么 |
|---|---|
| `check_float_ref.py` | 用本工程的网络定义 + `netG_B_epoch11.pth`（`strict=True`）验证浮点参考 |
| `check_inorm_equiv.py` | 证明 `bs=1` 的 BN == InstanceNorm（把"目标版本"钉死） |
| `l2_spec_check.py` | L2 整数规格验算（和 PyTorch 交叉验证：零填充 / 有符号池化 / 无 ReLU 的 bnq） |
| `quant_error_report.py` | RTL 定点 vs **浮点理论值**逐级误差（注意：这不是判据，判据是整数 0 差） |
| `bn_round_test.py` | BN 再量化：直接移位（截断） vs 四舍五入，误差对比 |
| `inorm_granularity_test.py` | InstanceNorm 统计粒度（整幅 / 分块）对精度的影响 |
| `eval_lianghua.py` / `eval_lianghua2.py` | 评估/对拍 `lianghua_infer.py` 那版定点口径（早期路线） |
| `lianghua_infer.py` | 早期量化推理脚本（**交互式**，运行时会 `input()`；不是门禁的一部分） |
| `gen_fpga_image.py` | 生成定点链路的最终图像，出侧对比图到 `fpga_images/` |
| `feature_map.py` | 库：滑窗/写 xlsx 的小工具（被其它脚本 import） |
| `cyclegna_mobilenet.py` | 网络定义（`MobileResnetGenerator`，与 `.pth` 严格对应） |

---

## 7. 关键数字（回归基线，改完对一下）

| 项 | 值 |
|---|---|
| L1 相位 | **118,943 拍** / 768 tile（154.9 拍/tile） |
| L2 相位 | **81,574 拍** / 192 tile（424.9 拍/tile） |
| 整帧总拍数 | **200,517 拍** ≈ 1.00 ms @200MHz |
| L1 面回读 | 30,720 unit，失败 **0** |
| L1+L2 之后整面回读 | 30,720 unit，失败 **0** |
| L2 逐级 + 窗口对拍 | 19,056 点，失败 **0** |
| 全帧转储比对 | L1 面 153,600 点 / L2 面 76,800 点 / 各级全帧 0 不一致 0 缺失 |
| `tb_l1` | `S_PW = 80` 拍 |
| `tb_board` | 校验和 `eb131b12a5` |
| BRAM | **140 / 256 = 54.7%**（band 12 + plane 120 + L2 写回 FIFO 8） |
| DSP | 100 / 160 |

---

## 8. 产物与临时文件

**可以随时删的临时文件**（重跑脚本即再生）：

```bat
:: ModelSim 库与波形、日志
rmdir /s /q rtl\conv2\work
del /q rtl\conv2\sim\transcript* rtl\conv2\sim\*.wlf
:: tb 写出来的中间转储
del /q rtl\conv2\picture_and_para\real_dump*.txt rtl\conv2\picture_and_para\rtl_dump_*.txt
:: 报告产物
rmdir /s /q rtl\conv2\picture_and_para\dump_all
del /q rtl\conv2\picture_and_para\feature_maps_*.xlsx
```

**不要删**（仿真的输入，tb 用 `$readmemh` 读）：`picture_and_para/*.hex`、`*.npz`、`*.npy`、
`test.jpg`、`netG_B_epoch11.pth`、`conv_wrom/wrom.hex`。

> 每个模块文件夹里的 `work/` / `transcript` / `*.wlf` 也是同类产物，各模块 `run.do` 会重建。

---

## 9. 目录整理记录

2026-09-22 整理（**只挪位置 + 改路径引用，不动任何 RTL 逻辑**）：

| 原来 | 现在 |
|---|---|
| `rtl/conv2/tb_top*.v` | `rtl/conv2/tb/` |
| `rtl/conv2/{run,wave,count,check}*.{do,bat}` | `rtl/conv2/sim/` |
| `rtl/conv2/{HANDOFF,WORKLOG,L2_PLAN}.md` | `rtl/conv2/doc/` |
| `work/`、`transcript*`、`*.wlf`、`wlft*`、`*.log`、`dump_all/`、`feature_maps_*.xlsx` | 删除（产物，可再生） |

`filelist.f`、各 `run*.do`、各 `*.bat` 里的路径已同步更新；`.bat` 仍为**纯 ASCII + CRLF**。
