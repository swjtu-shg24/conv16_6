# HANDOFF —— 交接提示词（直接复制粘贴给新会话 / 新 agent）

---

你接手的是 **`D:\my_code\fpga\yilisi\conv10_10`** 这个仓库里的 `rtl/conv2` 工程
（MobileNet 风格 CycleGAN 生成器 `netG_B` 的 FPGA 逐层实现，器件 Ti60F225，存储只用 `ip/bram_10kb`，
计算用**用户原样**的 `rtl/pe/pe.v` + `rtl/pe10_10/pe_10_10.v`，100 个 PE = 100 DSP）。

**开工前先完整读这几份**（2026-09-22 起顶层 tb 在 `tb/`、脚本在 `sim/`、过程文档在 `doc/`）：

- **`sim/` 与 [`../TOOLS.md`](../TOOLS.md)** —— ★ **脚本工具总表**：每个脚本叫什么、怎么调用、看到什么才算过
- **`doc/WORKLOG.md`** —— 总结/交接文档：定位、架构、口径、进度、坑、命令、下一步（**最重要，先读这个**）
- `../README.md` —— L1 全过程 + 踩坑记录（PE 契约 F1~F9、时序实测表、性能轨迹）
- `doc/L2_PLAN.md` —— L2 方案；**§2.5 是已定的 L2 整数规格**

## 当前进度

- ✅ **L1 通路全部打通并验证到"定点误差 = 0"**：整帧 768 tile / **118,943 拍** / **30,720 个 plane unit 全对**，
  独立整数 Python 实现与 RTL **0/153600 差异**。片数 band12 12 + L1 面 120 = **132/256**。
- ✅ **L2 计算引擎验通**：`tb_l2` **15600 点失败 0**，390 拍/tile；`tb_l2 USE_CFG=1`（运行时配置通路）也 PASS。
- ✅ **L2 已接进数据通路并端到端验通**：
  - L1/L2 **共用同一个 `conv_l1` 实例**（`cfg_l2` 运行时切 CIN/COUT/dw 侧归一化/ReLU），DSP 仍 **100**；
  - 窗口源 `conv_win_load_plane`（从 L1 面读、**零填充**）；
  - 结果**原地写回 L1 面**（`conv_wb_fifo`：tile 行结果 FIFO + **滞后一个 tile 行**排空），
    片数（`count_bram.do` 实测）**140/256**（band 12 + 面 120 + FIFO 8）；
  - 端到端 `tb_top_l2`：**PASS** —— L1 面 30,720 unit + L1+L2 之后整面 30,720 unit
    与 `golden_plane.hex` / `golden_plane_l2.hex` **逐 unit 0 失败**；
    L1 相位 **118,943 拍**（与只跑 L1 一致）、L2 相位 **81,574 拍**（424 拍/tile）、
    整帧 **200,517 拍 ≈ 1.00 ms @200 MHz**。
- ⬜ **还没做**：板级把 `L2_EN=1` 的整链跑通（重取校验和）、L3(16→32) / L4(9 个残差块) /
  L5~L7(转置卷积) / L8(7×7+Tanh)。

**跑 L2 端到端 / 看全部仿真数据**（工程根目录，先确保 golden 是最新的）：

```bat
& 'D:\Users\Administrator\anaconda3\envs\cyclegan\python.exe' rtl\conv2\picture_and_para\gen_stim.py
vsim -c -do rtl/conv2/sim/run_l2.do          :: L1+L2 整帧 + 3 tile 逐级对拍 + **全帧转储**（约 10~15 分钟）
:: ★ 看"从输入到 L2 输出"的完整波形（GUI + wave_l2.wlf，15 组按数据流分组）
rtl\conv2\sim\run_wave_l2.bat
:: 想单独看 L2 逐级数字（RTL vs Golden + 出 xlsx）：
& 'D:\Users\Administrator\anaconda3\envs\cyclegan\python.exe' rtl\conv2\picture_and_para\compare_l2_dump.py
:: 看"全部仿真数据"（两层逐级全帧 → 全量对拍 + npy/png/xlsx）：
& 'D:\Users\Administrator\anaconda3\envs\cyclegan\python.exe' rtl\conv2\picture_and_para\dump_all_report.py
```

## 铁律（违反会白干）

1. **先定整数规格 → ② Python 出整数 golden → ③ RTL 实现 → ④ tb 逐点对拍，不一致必须为 0。**
2. **验收判据是"定点误差 = 0"**（RTL 仿真 == 定点模型，逐点相同）。**浮点误差不是硬性要求**，别去优化它。
3. **老功能必须逐位不变**：新能力一律走**参数、默认 0 = 老行为**
   （现有：`Q44_EN / DW_SIGNED / Q44_SAT / BN_RELU / PE_SAT / BN_ROUND / DW_NORM / cfg_l2 / L2_EN`）。
   每次改完必须重跑：`tb_l1`（应仍 S_PW=80 拍）+ `tb_top_real`（应仍 118,943 拍 / 30,720 unit 失败 0）
   + `tb_board`（校验和应仍 `eb131b12a5`）+ `tb_top_l2`（L1+L2 整面逐 unit 0 失败）。
4. **归一化参数由 Python 按当前这张图算理论值**（浮点 μ/σ → `A_q=round(scale*256)`、`B_q=round(shift*4096)`）
   灌进 `conv_wrom` 的 ROM 给 RTL；**硬件里不做统计**（真正的实例归一等优化阶段）。
5. **代码要有流水线思维**：多 oc 同时在飞、窗口预取、写口打满，不许退化成串行。
6. **口径的唯一来源是 `rtl/conv2/picture_and_para/stim_model.py`**；改口径要同时改 `gen_stim.py` 和 RTL 参数。

## 关键口径（速查）

| 项 | 口径 |
|---|---|
| 数据 | Q4.4 有符号：`q = (p-124) >>> 3` |
| 权重 | Q8：`w_q = round(w*256)`，18bit 有符号 |
| dw/pw | `clip((Σ+128)>>8, -128,127)`（对称饱和） |
| 归一化 | `(A_q*x+B_q)>>8`（floor，无 +128）。**ReLU 在哪一级**：L1 只有 pw 之后那一级（`BN_RELU=1`，`[0,127]`）；L2 是 **dw 侧归一化之后有 ReLU**（`dn_f` 里固定）、**pw 侧归一化之后没有**（可负，`BN_RELU2=0` → 对称 ±8） |
| 限位 | PE 阵列输出移位前饱和 `[-32768,+32639]`（`PE_SAT=1`，与三级各自限位逐位等价） |
| 池化 | 2×2 max，**有符号**（`SIGNED_CMP`） |
| 填充 | **L1 反射**；**L2 起零填充**（`Conv2d(padding=1)`，别照抄 L1 的反射！） |
| pw 流水"格" | **`GRP = CIN+5`**（L1 的 3→8 拍；L2 的 8→13 拍），组数 `COUT+2` |
| L2 配置 | `conv_l1` 的 `cfg_l2=1` → `CIN=8 / COUT=16 / dw 侧归一化=1 / pw 侧无 ReLU`；权重端口数组按最大配置定宽（`w_dw[0:71]`/`w_pw[0:127]`/`bn[0:15]`/`dn[0:7]`） |
| L2 写回 | **原地复用 L1 面**：`unit = ((oc2>>1)*120 + r2)*32 + (oc2&1)*16 + k2`；经 `conv_wb_fifo` **滞后一个 tile 行**（1280 unit）排空，绝不可就地立刻写（见 WORKLOG 坑 #11/#15） |

## 环境 / 命令

```bat
:: 工程根目录  D:\my_code\fpga\yilisi\conv10_10
:: ModelSim 10.4 用全路径（裸名找不到 modelsim.ini）
D:\modeltech64_10.4\win64\{vsim,vlib,vmap,vlog}.exe
:: Python 用这个 conda 环境（torch 2.5.1 / numpy / openpyxl / PIL）
D:\Users\Administrator\anaconda3\envs\cyclegan\python.exe

python rtl\conv2\picture_and_para\gen_stim.py        :: 生成激励+golden+ROM（315 字，含 L2 面 golden）
python rtl\conv2\picture_and_para\gen_l2_stim.py     :: 生成 L2 引擎级激励+golden
vsim -c -do rtl/conv2/sim/run_real.do                    :: L1 整帧端到端（~3.5 分钟）
vsim -c -do rtl/conv2/sim/run_l2.do                      :: ★ L1+L2 整帧端到端（从 plane 全量回读，~8 分钟）
vsim -c -do rtl/conv2/conv_l1/run_l2.do              :: L2 引擎（秒级）
vsim -c -do rtl/conv2/conv_win_load_plane/run.do     :: L2 窗口装载器（1536 个窗口）
vsim -c -do rtl/conv2/conv_wb_fifo/run.do            :: L2 写回 FIFO / 滞后排空
vsim -c -do rtl/conv2/conv_l1/run.do                 :: tb_l1（秒级）
rtl\conv2\sim\check_fixed_point.bat                      :: 一键门禁：定点误差 = 0
```

**别踩**：源文件是 UTF-8，**不能用 PowerShell `Set-Content` 改**（会变 ANSI、毁中文注释）；
`run.bat` 必须**纯 ASCII + CRLF**；`.gitignore` 是白名单，
**`.py`/`.hex`/`.jpg`/`.pth`/`.xlsx` 都不被跟踪**（要提交得 `git add -f`）。

## 你现在要做的事（按 WORKLOG §8）

1. **板级接通 L2**（下一步）：`conv_board_top` 现在默认 `L2_EN=0`（校验和仍是 `eb131b12a5`）。
   要跑 L1+L2 的板级：给 `conv_top` 传 `.L2_EN(1)`、把 L2 权重/参数接上（`w2_*`/`b2_*`，
   可以例化 `conv_wrom` 或继续用公式权重）、`l2_go` 接 1，然后**重取校验和**。
   建议分两个校验和：`chk_L1`（必须仍是 `eb131b12a5`）+ `chk_L2`（新值）。
2. 重新 PnR 看时序/资源：**片数 140/256**（band 12 + 面 120 + FIFO 8）、DSP 100/160；
   LUT 是历史上最紧的资源（老版本到过 94%），L2 新增的 mux 要盯一下。
3. 再往后：L3(16→32) → L4(9 个 32→32 残差块) → L5~L7(转置卷积) → L8(7×7+Tanh)，
   每层都照 L1/L2 的套路：**先定整数规格 → Python 出整数 golden → RTL → tb 逐点对拍，不一致必须为 0**。

**每一步做完都要**：跑 L1 回归确认逐位不变（`tb_l1` S_PW=80、`tb_board` 校验和、`tb_top_real` 118,943 拍）
→ 跑新 tb 确认定点误差 0 → 更新 `WORKLOG.md` 的进度与坑表。
