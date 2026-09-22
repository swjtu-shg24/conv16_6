# conv2 —— 项目总结 / 工作记录（WORKLOG）

> 最后更新：2026-09-22。**看这一份就能接手**：定位、架构、口径、进度、坑、命令、下一步。
> 详细背景：`README.md`（L1 全过程 + 踩坑 35 条）；L2 方案：`L2_PLAN.md`（§2.5 是已定的 L2 整数规格）。

---

## 0. 一句话现状

**L1 通路已全部打通并验证到"定点误差 = 0"**；**L2 也已经接进数据通路并端到端验通**
（L1 面 → 零填充窗口 → 共用同一套 100 PE → **原地写回同一个 plane**），
判据仍是"整帧逐 unit 与定点 golden 相同"。

```
[✅ 通] DDR → conv_in_dma → conv_band12 → conv_win_load → conv_l1(L1) → conv_plane → 回读
         整帧 768 tile / 118,943 拍 / 30,720 个 plane unit 全对
[✅ 通] L1 面 → conv_win_load_plane(零填充) → conv_l1(cfg_l2=1) → conv_wb_fifo → 原地写回 plane
         L2 192 tile（12×16）/ 81,574 拍（424 拍/tile）/ 从 plane 全量回读 30,720 unit 全对
         整帧 L1+L2 = 200,517 拍 ≈ 1.00 ms @200 MHz；片数 140/256（含 FIFO 8）
[⬜ 未做] L3(16→32) / L4(9 个 32→32 残差块) / L5~L7(转置卷积) / L8(7×7+Tanh)
```

**L2 的四个关键决定（都已落地并验证）**：

| # | 决定 | 为什么 |
|---|---|---|
| 1 | L1/L2 **共用同一个 `conv_l1` 实例**（`cfg_l2` 运行时切配置） | Ti60 只有 160 个 DSP，各来一套 100 PE = 200 装不下 |
| 2 | L2 的窗口从 **L1 输出面**读、**零填充**（`conv_win_load_plane`） | L2 的 dw 是 `Conv2d(padding=1)` = 零填充；L1 才是反射 |
| 3 | L2 结果 **原地写回 L1 面**（L2_PLAN §6.3 的映射，省 60 片 BRAM） | 省存储；但必须解决"自己踩自己" |
| 4 | 写回经 **tile 行结果 FIFO + 滞后一个 tile 行排空**（`conv_wb_fifo`，8 片） | 见下面"为什么" |

> ★ **更正 L2_PLAN §6.3 的两处估算**（实测推导）：
> ① 写回**不能**"就地立刻写"：`oc2` 为奇数时写的是行内**高半列**（列 `80+5tc..`），
>    会踩到同一 tile 行里后面 `tc+1..tc+8` 个 tile 的读；
> ② 因此也**不能**只滞后一个 tile（那样后面那些 tile 还是被踩）；
>    需要的缓冲也**不是**"3.2 kbit 寄存器就够"，而是**一个 tile 行**（1280 unit ≈ 8 片）。
> 现在实现的是：引擎写口在 L2 相位先推进 FIFO，积够一个 tile 行后按同速率持续排水，
> **滞后恒定 = 一个 tile 行** ⇒ 排空时的写行 `5tr-5..5tr-1` 与"此后还会发生的读"行
> `≥10tr-1` **不相交**（一行证明），列怎么撞都无所谓。

---

## 1. 工程定位

MobileNet 风格 CycleGAN 生成器（`netG_B`）的 FPGA 逐层实现。器件 **Ti60F225**，
存储只用 `ip/bram_10kb`（SDP 512×20），计算用用户原样的 `rtl/pe/pe.v` + `rtl/pe10_10/pe_10_10.v`（100 个 PE = 100 DSP）。

**完整网络层次**（`MobileResnetGenerator(ngf=8, n_blocks=9)`）：

| 级 | 结构 | 尺寸 | 通道 | 状态 |
|---|---|---|---|---|
| L1 | `ReflectPad(1)+dw3×3+pw1×1+归一化+ReLU+MaxPool2` | 320×240→160×120 | 3→8 | ✅ 完成，定点误差 0 |
| L2 | `DSC(8→16)+MaxPool2` | 160×120→80×60 | 8→16 | ✅ 引擎验通，通路未接 |
| L3 | `DSC(16→32)+MaxPool2` | 80×60→40×30 | 16→32 | ⬜ |
| L4 | **9 × `DSC(32→32)` 残差块** | 40×30 | 32→32 | ⬜ |
| L5~L7 | `ConvTranspose2d` + 归一化 + ReLU | →80×60→160×120→320×240 | 32→8 | ⬜ |
| L8 | `ReflectPad(3)+Conv2d(8→3,7×7)+Tanh` | 320×240 | 8→3 | ⬜ |

---

## 2. 铁律（每一步都照这个走）

1. **先定整数规格 → ② Python 出整数 golden → ③ RTL 实现 → ④ tb 逐点对拍，不一致必须为 0。**
2. **验收判据：定点误差 = 0**（RTL 仿真必须与定点模型逐点相同）。**浮点误差不是硬性要求。**
3. **老功能逐位不变**：新能力一律走**参数、默认 0 = 老行为**
   （`Q44_EN / DW_SIGNED / Q44_SAT / BN_RELU / PE_SAT / BN_ROUND / DW_NORM` 都是这个套路）。
4. **归一化参数由 Python 按当前这张图算理论值**（浮点 μ/σ → `A_q=round(scale*256)`、`B_q=round(shift*4096)`），
   灌进 ROM 给 RTL；**硬件里不做统计**（真正的实例归一等优化阶段再做）。
5. **代码要有流水线思维**：多 oc 同时在飞、窗口预取、写口打满，不许退化成串行。
6. **三处同步**：口径改动要同时改 `stim_model.py`（基准）、`gen_stim.py`（生成物）、RTL 参数。

---

## 3. 架构总览

```
DDR(320×240×3) ──w_read_*──► conv_in_dma ──► conv_band12 ──► conv_win_load ──► conv_l1 ──► conv_plane ──► p2_rd_data
                              (16B→20B, Q44_EN)  (12 行环带)    (12×12 窗口)     (卷积引擎)    (输出面)
                                    └──────────────────── conv_sched（tile 调度 + 全部握手）────────────────┘
                                                               ▲
                                                  conv_wrom（权重+归一化参数，315 字）
```
`conv_top.v` 是**纯结构**（只有例化 + 连线，没有 `always`/状态机）。

### 3.1 模块清单

| 模块 | 职责 | 关键点 |
|---|---|---|
| `conv_top` | 顶层，纯结构 | 参数 `IW/IH/ROWB/NBEAT/NTILE_R/NTILE_C` + 定标开关 + **`L2_EN`（默认 0）**；按 `cfg_l2` 做窗口源/权重源/写口/读口的 mux |
| `conv_in_dma` | DDR→band | 16B/beat→20B/组 字节重对齐；`rows_free` 信用；`Q44_EN` 时 `q=(p-124)>>>3` |
| `conv_band12` | 12 行环带 | 6 bank ×1 段×512 unit×40bit = **12 片** |
| `conv_win_load` | band→12×12 窗口 | **reflect-101**；每拍 1 行；`busy` 在 S_RUN 末拍落 0 |
| **`conv_win_load_plane`** | **L1 面→12×12 窗口（L2 用）** | **零填充**；一次 4-unit 读（12 行 = 12 次访问）；地址 `bank=(2B+u0)%6`、`addr=5B+(2B+u0)/6` 一次算好，逐行 +32 递推 |
| **`conv_l1`** | **可配层卷积引擎（L1/L2 共用一个实例）** | dw →〔`S_DWN`〕→ pw 软件流水 → 池化 → 写回；`CIN/COUT/GRP` 由 `cfg_l2` 运行时选；端口数组按最大配置定宽 |
| **`conv_wb_fifo`** | **L2 写回：tile 行结果 FIFO + 滞后一行排空** | 1280 unit（一个 tile 行）积满才排空；地址递推用"基底/当前行"两个寄存器（见坑 #6） |
| `conv_cmp4_tree`/`conv_pool_arr` | 取最大 / 25 棵 | 真两级流水（`en` 连续两拍）；`SIGNED_CMP` 支持有符号 |
| `conv_plane` | 输出面（L1: 160×120×8） | 6 bank×10 段×512 = **120 片**；写口 1 unit/拍；**读口 4 unit（160bit）**，`SEG` 已是参数 |
| `conv_mem_unit` | 512×40 unit | **全工程唯一例化 `bram_10kb` 的地方**；FIFO 也用它（`SEG=4`） |
| `conv_sched` | 调度 + 握手 | 窗口仲裁、`rows_free` 发放、ch0 跨 tile 预取；**L2 相位**（`L2_EN`，`l2_go` 放行，done 等 `wb_empty`） |
| `conv_wrom` | 权重/归一化参数 ROM | **315 字**：L1 67 + L2 248 |

### 3.2 存储与地址映射

统一：**unit = 40bit（=2 片 bram_10kb 并联）**，`bank = unit mod 6`、`addr = unit/6`，读延迟 1 拍。

| 存储 | 映射 | 容量 |
|---|---|---|
| band12 | `u = slot*192 + ch*64 + k`（slot = row mod 12） | 2304 unit → 6 bank×512 = **12 片** |
| L1 面 | `unit = (oc*120+row)*32 + col/5` | 30,720 → 6 bank×10 段 = **120 片** |
| **L2 结果** | **原地复用 L1 面**：`unit = ((oc2>>1)*120 + r2)*32 + (oc2&1)*16 + k2`（r2 0..59, k2 0..15） | 占 L1 面行 0..59 = 15,360 unit，**不额外占片** |
| **L2 写回 FIFO** | 线性 2048 unit（只用前 1280+80）`conv_mem_unit #(.SEG(4))` | **8 片** |

片数总账：**12 + 120 + 6 ≈ 138 / 256**（L2_EN=0 的纯 L1 版仍是 132；FIFO 在纯 L1 版里没用上，
以后可以用 `generate if (L2_EN)` 把它整块去掉，省下 6 片）。

### 3.3 计算引擎的流水线时序（核心）

**dw 相位**：`c=0` 同拍 `wdata_en/start` + 喂 `w_dw[ch*9+0]`；`c=1..9` 喂 `w_dw[ch*9+c-1]`；
**`c=13` 抓 100 个 `peo`** → 量化。每通道 14 拍（3 通道 = 42 拍）。下一通道窗口在 `c=1` 预取。

**`S_DWN`（`DW_NORM=1`，L2 用）**：dw 之后再过一遍归一化+ReLU，**复用同一套 PE 阵列**。
每通道 5 拍：`m=0` 载 `a=dwc[dn_ch]`/`b=dn_a[dn_ch]`，`m=3` 给 `C=dn_b[dn_ch]`，`m=4` 抓 `pe_out` → `dn_f()` → 就地写回 `dwc`。8 通道 = 40 拍。

**pw 软件流水**：组内周期 **`GRP = CIN+5`**（L1: 3→**8 拍**；L2: 8→**13 拍**），组数 `COUT+2`：

| 组内 m | 动作（作用在不同 oc/资源上，所以能叠） |
|---|---|
| 0 | 载归一化的 a=qq(oc-1)+b=bn_a(oc-1)；写回 oc-2 row0 |
| 1..CIN | 喂 pw 的 a=dwc[i-1]、b=w_pw[oc][i-1]、`acc_en_pw`；写回 row1..4 |
| 3 | DSP 的 C 端口给 bn_b(oc-1) |
| 4 | 抓 bnq(oc-1)；acc 装载 p1（累加在 DSP 内部，阵列外无 pacc） |
| 5,6 | 池化 `en` 连续两拍（oc-1） |
| **CIN+4=GRP-1** | **抓 `pe_out` → qq(oc) 量化**，同拍置 `bn_load`（下一组 m=0 锁 qq） |

L1：`S_PW=10×8=80`，整 tile `1+10+42+80+1=134` + 窗口等待 ≈ **154 拍**（实测均值）。
L2：`S_PW=18×13=234` + `S_DWN 40` → **实测 390 拍/tile**。

**三个硬下限**：① plane 写口 1 unit/拍 → 相邻 oc ≥5 拍；② 池化结果要等写回读完 `pl_dout`；
③ 归一化的 a 只能从 m=0 载。

### 3.4 定点口径（`picture_and_para/stim_model.py` 是唯一来源）

| 项 | 口径 |
|---|---|
| 数据 | **Q4.4 有符号**：`q = (p-124) >>> 3` |
| 权重 | **Q8**：`w_q = round(w*256)`，18bit 有符号 |
| dw/pw 量化 | `clip((Σ+128)>>8, -128,127)`（对称饱和；真实网络那里没有激活） |
| 归一化 | `(A_q*x+B_q)>>8`，`A_q=round(scale*256)`、`B_q=round(shift*4096)`，**floor 无 +128** |
| ReLU | pw 之后的归一化**有**（`[0,127]`，`BN_RELU=1`）；dw 之后的**也有**（`S_DWN` 固定有） |
| 限位 | 统一在 **PE 阵列输出**（`PE_SAT=1`）移位前饱和 `[-32768,+32639]`，与三级各自限位**逐位等价** |
| 池化 | 2×2 max，**有符号**（`SIGNED_CMP`） |
| 填充 | **L1 反射**（网络有 `ReflectionPad2d(1)`）；**L2 起零填充**（`Conv2d(padding=1)`） |
| 归一化参数 | Python 按当前图算理论 μ/σ 灌 ROM；硬件只做逐通道仿射 |

`conv_wrom` 315 字布局：`L1 dw27 | pw24 | bn_a8 | bn_b8` + `L2 w2_dw72 | w2_pw128 | b2_dw_a8 | b2_dw_b8 | b2_pw_a16 | b2_pw_b16`
（基址见 `conv_wrom.v` 的 `B_*` 与 `stim_model.py` 的 `ROM_*_BASE`，**两处必须一致**）。

### 3.5 调度与流控（`conv_sched`）

tile 光栅扫 → `l1_start`；`win_req` 补成组合 `wl_start`（省 2 拍），**正常请求优先于预取**；
`rows_free` 信用：开局允许写到第 10 行，之后每消费一个 tile 行多放 10 行，起 tile 行还要等 `in_row_vld` 计数够；
**ch0 跨 tile 预取**：趁本 tile 的 pw 相位预装下一个 `tile_c` 的 ch0 窗口（32 个 tile 里 28 个吃到）。

---

## 4. 验证体系与现状（全绿）

**方法**：规格 → Python 整数 golden → RTL → tb 逐点对拍（判据：**不一致 = 0**）。

```
tb_l1 PASS（S_PW 仍 80 拍）        tb_l2 PASS（15600 点，失败 0，390 拍/tile）
tb_l2 USE_CFG=1 PASS（**运行时 cfg 通路**，与参数通路逐位相同）
tb_wrom PASS（315 字全查）          tb_l1_dw / tb_win / tb_dma / tb_band / tb_mem_unit / tb_cmp4_tree / tb_pool PASS
tb_win_plane PASS（1536 个窗口 × 144 字节，四边零填充，0 失败）
tb_wb_fifo PASS（L2 区 15360 unit 全对 + L1 区未动 + 滞后 ≥1280）
tb_sched PASS                       tb_plane PASS（含 4-unit 宽读口用例）
tb_top_real PASS（整帧 30,720 unit 失败 0，118,943 拍 —— S1/S2/S5 之后重跑仍一致）
tb_board PASS（校验和 eb131b12a5 不变）
tb_top_l2 PASS（L1 面 30,720 unit + L1+L2 之后整面 30,720 unit，逐 unit 0 失败；
              L1 相位 118,943 拍、L2 相位 81,574 拍、总 200,517 拍）★ 新的端到端门禁
make_table：RTL vs Golden 不一致 0
```

**验证链条**：① `.pth` 解析 = 用户的 `netG_B_epoch11_weights.xlsx`　② 浮点基准 = 用户的网络定义
（`netG.train()` ≡ `InstanceNorm`，逐位相同；BN 的 running 统计量在 bs=1 训练下本来就不对）
③ RTL = 定点模型　④ RTL = 独立整数 Python　⑤ 限位换位置不掉一位。

**一键门禁**：`rtl\conv2\sim\check_fixed_point.bat`（gen_stim → 整帧仿真 → 逐级比对 → 独立实现对拍）。

**出图**（`gen_fpga_image.py`，实例归一化）：只量化输入 31.24 dB；L1 定点 23.78 dB；
**L1 定点 + dw 权重×8 增益重分配 29.59 dB**；全层定点 23.02 dB；BatchNorm 版 20.74 dB。

---

## 5. 文件清单

**RTL（`rtl/conv2/`）**：`conv_top.v` `conv_in_dma/` `conv_band12/` `conv_win_load/`
**`conv_win_load_plane/`（L2 面源窗口，零填充）** `conv_l1/`（含 `tb_l2.v`）
**`conv_wb_fifo/`（L2 写回 FIFO + 滞后一行排空）** `conv_cmp4_tree/` `conv_pool_arr/`
`conv_plane/` `conv_sched/` `conv_wrom/` `conv_mem_unit/` `board/` `probe/`。
顶层 tb：`tb_top.v`（小图）`tb_top_full.v`（整帧抽样）`tb_top_real.v`（整帧逐 unit，L1）
**`tb_top_l2.v`（L1+L2 端到端，整面逐 unit）** + `run_l2.do`。
跨层复用：`rtl/pe/pe.v`、`rtl/pe10_10/{pe_10_10,feature_map_12_12}.v`（**用户原样，别改**）。

**Python（`rtl/conv2/picture_and_para/`）**：
`stim_model.py`(**口径唯一来源，L1+L2**；含 `plane_golden_l2`) · `gen_stim.py`(ROM+golden+激励+
**`golden_plane_l2.hex`/`golden_out_plane_l2.npy`/`l2_win_real.hex`/`l2_golden_real_flat.hex`/
`golden_l1_stages.npz`/`golden_l2_stages.npz`**) ·
`compare_l2_dump.py`(**L2 3-tile 逐级 RTL vs Golden + `feature_maps_real_l2.xlsx`**) ·
**`dump_all_report.py`（★ 全帧转储的报告：两层逐级全帧全量对拍 + npy/png/xlsx）** ·
`gen_l2_stim.py`(L2 引擎级激励+golden) ·
`make_table.py`(xlsx) · `fpga_l1_int_dump.py`(L1 独立整数实现) · `l2_spec_check.py`(L2 规格验算) ·
`compare_python.py` · `check_weights.py` · `check_float_ref.py` · `check_inorm_equiv.py` ·
`quant_error_report.py` · `inorm_granularity_test.py` · `gen_fpga_image.py` · `bn_round_test.py` · `eval_lianghua*.py`。
用户原件：`cyclegna_mobilenet.py`、`lianghua_infer.py`、`feature_map.py`、`test.jpg`、`.pth`、`xlsx`。

**全帧转储（`tb_top_l2`，`DUMP_ALL=1` 默认开）**：`rtl_dump_plane_l1.txt` / `rtl_dump_plane_l2.txt`
（两块面 30,720 unit）+ `rtl_dump_l1_stage.txt` / `rtl_dump_l2_stage.txt`（两层每个 tile 每一级，
行格式 `级 tr tc idx v...`）；用 `dump_all_report.py` 拼回整帧、全量对拍并出图（`dump_all/`）。

**波形（从输入到 L2 输出）**：`rtl\conv2\sim\run_wave_l2.bat` → GUI + `wave_l2.do`（15 组，按数据流，
专门标出 L2 相位：面源零填充窗口 / 共用引擎 `cfg_l2=1` / 写回 FIFO 滞后一行排空 / 面写口 mux）；
产物 `wave_l2.wlf` + `transcript_wave_l2`。L1 单独波形仍是 `run_wave.bat`（`wave_full.do`）。

**文档**：`README.md`（L1 全过程 + 35 条踩坑）· `L2_PLAN.md`（L2 方案 + §2.5 规格）· `WORKLOG.md`（本文）· `HANDOFF.md`（交接提示词）。

---

## 6. 环境与命令

```bat
:: 工程根目录  D:\my_code\fpga\yilisi\conv10_10
:: ModelSim 10.4 全路径（裸名会找不到 modelsim.ini）
D:\modeltech64_10.4\win64\{vsim,vlib,vmap,vlog}.exe
:: Python（torch 2.5.1 / numpy / openpyxl / PIL）
D:\Users\Administrator\anaconda3\envs\cyclegan\python.exe

:: 生成激励+golden+ROM（实例归一化口径；--bn-running 切旧口径）
python rtl\conv2\picture_and_para\gen_stim.py
python rtl\conv2\picture_and_para\gen_l2_stim.py          :: L2 激励+golden
:: 仿真
vsim -c -do rtl/conv2/sim/run_real.do          :: L1 整帧端到端（~3.5 分钟）
vsim -c -do rtl/conv2/conv_l1/run_l2.do    :: L2 引擎（秒级）
vsim -c -do rtl/conv2/conv_l1/run.do       :: tb_l1（秒级）
rtl\conv2\sim\check_fixed_point.bat            :: 一键门禁（定点误差 = 0）
```

**git 注意**：`.gitignore` 是**白名单**（放行 `.v .sv .vh .svh .f .xml .json .sdc .lpf .pdc .ini .do .bat .sh .tcl .md README*`）。
**`.py` / `.hex` / `.jpg` / `.pth` / `.xlsx` 都不被跟踪** → 要进版本库得 `git add -f`（或加白名单规则）。
最近提交：`055ad42 添加批归一化以及L1层的全参数仿真`。

---

## 7. 踩坑清单（本项目，继续累加）

| # | 坑 | 规矩 |
|---|---|---|
| 1 | **别用 PowerShell `Set-Content` 改源文件** | UTF-8 会被写成 ANSI，中文注释全毁（用编辑工具） |
| 2 | `run.bat` 必须**纯 ASCII + CRLF** | `chcp` 后 cmd 按字节续读会错位 |
| 3 | `CIN[2:0]` 在 CIN=8 时是 0 | 通道数比较**一律用整数比较** `(CIN-1)` |
| 4 | `fm_wdata_en` 相位 | 载荷发生在"置起后的下一拍"；要 `fm_la(1)=a` 就必须让它在 **m=0 那一拍有效**（上一拍置起），晚一拍就只能加到 C 端口 |
| 5 | oc 索引位宽 | `oc` 是 0..COUT+1，抓数用 `l1_oc[2:0]` 对 oc≥8 会**回绕覆盖**其他 oc 的数据 |
| 6 | `dwc` 会被 `S_DWN` 就地覆盖 | 要抓"量化后的 dw 输出"必须在 dw 相位 `c=13` 抓 |
| 7 | 加了新端口必须**所有例化都接** | 悬空成 `z` 会"碰巧能跑"，仿真与综合语义不一致 |
| 8 | 池化 `en` 必须**连续两拍** | `conv_cmp4_tree` 是真两级流水，给一拍第二级不动 |
| 9 | `$readmemh` 目标数组必须够大 | 文件字数超过数组会报 "Too many data words" 并把 `initial` 搞乱（tb 会读到 x） |
| 10 | 逐级对拍**两端输入必须一样** | 一边浮点输入 `2p/255-1`、一边 Q4.4 输入，比出来的是"输入量化+内部量化"合计，定位不到内部 |
| 11 | **原地写回的 oc 边界步进要用"基底"寄存器** | `+16/+3824` 是 **基底(base, i=0)之间**的步进；从 `(oc,i=4)` 到 `(oc+1,i=0)` 的实际步进是 `16-128 = -112`（oc 偶）/ `3824-128 = +3696`（oc 奇）。写成 `+16/+3824` 会让地址从每个 oc 的第 2 行起整体漂移，最后漂进别的行 → 症状：L2 区回读全 0、L1 区一半被写坏。正解：`bank/addr`（当前行指针，行内 +32）与 `bbank/baddr`（当前 oc 基底，oc 边界 +16/+3824）两个寄存器 |
| 12 | **`dk[10:0]` 这种越界位选返回 x** | `dk` 只有 7 bit，写 `pop_ptr + dk[10:0]` ⇒ 高位取不到值、整个和变 **x**（FIFO 读地址全 x → 排空写进去的数据全是 0，而且不报错）。7bit 变量要写成 `{4'b0, dk}` 补零扩展 |
| 13 | **面的 4-unit 读口：slice 映射必须寄存一拍** | `conv_band12` 能直接用组合 `rb[]` 去选，是因为它的 `rd_bank` 在整个窗口内**恒定**；面的读 bank 是**逐行变**的（每行 +32 unit → bank+2），用当前 `rb[]` 选上一拍读回的数据会**整块错位**。正解：把 4 个 bank 也寄存一拍（`rb_d`），与 BRAM 的 1 拍读延迟对齐 |
| 14 | **声明顺序（第四次踩）** | 例化里引用的 `wire`（`fifo_re`/`fifo_ra`/`dk`）必须先声明；顶层 `conv_top` 的 L2 mux 用到引擎输出（`p2_wr_*`）也必须先声明。vlog 报的是 `(vlog-2730) Undefined variable` + `(vlog-2388) already declared` 成对出现 |
| 15 | **滞后排空要比"一个 tile"更长** | `oc2` 奇数时 L2 写的是行内**高半列**（列 `80+5tc..`），会踩到同一 tile 行里后面 `tc+1..tc+8` 个 tile 的读列；所以"滞后一个 tile"不够，必须**滞后一个 tile 行**（`conv_wb_fifo` 的阈值 = `NTILE_C*80` unit） |
| 16 | **L1→L2 过渡时 `l1_start` 要延后一拍** | `clr_pend` 清 `ch0_rdy` 是延迟一拍的（原来故意让它在 `l1_start` 那拍仍可见，给 L1 的跨 tile 预取用）；切 L2 时这个残留会让 `conv_l1` 直接进 `S_DW`、用**没装载**的 `win_d`（x）→ **L2 第一个 tile 全 x**。修法：过渡当拍清 `ch0_rdy`，`l1_start` 用 `l2_pend` 延后一拍 |
| 17 | **加宽端口后所有例化点（含 tb）都要跟着加宽** | `conv_win_load` 的 `ch` 从 2bit 加宽到 3bit 后，老 tb 仍驱动 2bit → 只有一条 `(vsim-3015)` 告警，但**高位变 z/x** → 地址 x → 读到 x（`tb_win` FAIL）。端口宽度改动必须连 tb 一起改 |
| 18 | **探针读"本拍正要写的寄存器"读到旧值** | 非阻塞赋值沿后才生效：在 `dwc[..] <= ...` 那一拍读 `dwc`，拿到的是上一拍的值（我第一次查 L2 的 x 就是被这个骗到），探针要晚一拍 |
| 19 | **tb 里等脉冲要先排空旧脉冲** | `while (win_vld !== 1)` 进入时若旧 `win_vld` 还高，会立刻退出并拿旧窗口对新参数（`tb_win_plane` 的背靠背相位被我这样骗了两次） |

---

## 8. 下一步（按顺序，每步都有"定点误差 = 0"的判据）

| 步 | 做什么 | 判据 | 状态 |
|---|---|---|---|
| 0 | L2 整数规格 + Python golden + 引擎单独验 | `tb_l2` PASS（15600 点 0 失败） | ✅ |
| 1 | `conv_l1` 运行时配置化（`cfg_l2`）—— 一套 100 PE 分时跑 L1/L2 | `cfg_l2=0` 时 L1 逐位不变（`tb_l1` S_PW=80、`tb_board` 校验和 `eb131b12a5`、`tb_top_real` 118,943 拍）；`tb_l2 USE_CFG=1` PASS | ✅ |
| 2 | `conv_plane` 读口加宽到 **4 unit**（L2 窗口要用） | `tb_plane` PASS（含宽读口用例；单 unit 回读语义不变 = slice 0） | ✅ |
| 3 | **`conv_win_load_plane`**：从 L1 面读 12×12、**零填充** | `tb_win_plane` PASS（1536 窗口 × 144 字节全对） | ✅ |
| 4 | **`conv_wb_fifo`**：原地写回 + 滞后一个 tile 行排空 | `tb_wb_fifo` PASS（L2 区 15360 全对、L1 区未动、滞后 ≥1280） | ✅ |
| 5 | `conv_sched` L2 阶段 + `conv_top` 接线（窗口源/权重/写口/读口 mux） | `tb_sched` PASS（L1 不变）+ `tb_top_real` 仍 118,943 拍 | ✅ |
| 6 | **L1+L2 端到端**（整帧，从 plane 全量回读） | `tb_top_l2` PASS：L1 面 30,720 unit + L1+L2 之后整面 30,720 unit，逐 unit 0 失败 | ✅ |
| 7 | 板级：把 `L2_EN=1` 的整链跑通、重取校验和（`chk_L1` 保持 `eb131b12a5`，新增 `chk_L2`）、重新 PnR 看时序/资源 | `tb_board`（L2 版）+ 上板 PASS | ⬅ 下一步 |
| 8 | 再往后：L3(16→32) → L4(9 个 32→32 残差块) → L5~L7(ConvTranspose) → L8(7×7+Tanh) | 每层同套路：先定整数规格 → Python golden → RTL → tb 逐点 0 差异 | ⬜ |
