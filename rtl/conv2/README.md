# conv2 —— conv10_10 L1 前端（重写版）

> 目标：DDR 里**已池化好的 320×240×3 RGB888** → L1(`dw3×3` + `pw1×1` + 量化 + 与 `2×2 max` 池化融合) → **160×120×8**
> 器件 Ti60F225，片型只用 `ip/bram_10kb`（SDP 512×20），PE 用你原来的 `rtl/pe/pe.v` + `rtl/pe10_10/pe_10_10.v`（一行不改）。

---

## 目录约定（**递归适用**）

> **每一个文件夹都必须自包含、都能单独仿真。** 规则：
> ① 一个模块一个文件夹，文件夹名 = 模块名；
> ② 每个文件夹里都要有自己的一套 **`filelist.f` + `run.bat` + `run.do`**，
>    以及 `<模块>.v` + `tb_<模块>.v`；仿真产物（`work/`、`transcript`、`*.wlf`）也落在本文件夹；
> ③ 子文件夹这样做，**子文件夹的子文件夹也这样做**（递归）。
> ④ **顶层模块 `conv_top.v` 写在本层（外部）**，不放进子文件夹；本层同样有自己的 `filelist.f` + `run.bat` + `run.do`。

```
rtl/conv2/                          ← 顶层（本层，外部）
│   README.md
│   filelist.f                      全量清单
│   run.bat                         ① 全量编译 ② 各模块 run.do ③ 端到端 tb_top
│   run.do                          全量编译 + 跑 tb_top
│   conv_top.v                      ← 顶层模块（**纯结构例化，无 always**）
│   tb_top.v                        端到端自检（80×40×3 → 40×20×8）
│   work/  transcript  top.wlf      本层仿真产物
│
├── conv_cmp4_tree/                 ← 每个模块文件夹都是自包含的：
│     conv_cmp4_tree.v               RTL
│     tb_cmp4_tree.v                 tb
│     filelist.f                     本模块清单（路径相对工程根目录）
│     run.bat                        双击即可单独仿真
│     run.do                         仿真脚本
│     work/  transcript  tree.wlf    仿真产物
├── conv_pool_arr/      conv_pool_arr.v      tb_pool.v      filelist.f run.bat run.do work/ …
├── conv_mem_unit/      conv_mem_unit.v      tb_mem_unit.v  …   ← 全工程唯一例化 bram_10kb 的地方
├── conv_band12/        conv_band12.v        tb_band.v      …
├── conv_win_load/      conv_win_load.v      tb_win.v       …
├── conv_in_dma/        conv_in_dma.v        tb_dma.v       …
├── conv_l1/            conv_l1.v            tb_l1_dw.v / tb_l1.v（run.do + run_dw.do）
├── conv_sched/         conv_sched.v         tb_sched.v     …
└── conv_plane/         conv_plane.v         tb_plane.v     …
```

**`conv_top` 是纯结构**：只做子模块例化 + 连线，**不放任何 always / 状态机**；
tile 调度与握手放在 `conv_sched` 里。**一个文件一个模块**。

---

## 输入数据布局（按你确认的）

DDR 里**一行 R、一行 G、一行 B** 这样存（不是像素交错）：

```
字节地址 = base + row*960 + ch*320 + col        row 0..239, ch 0=R/1=G/2=B, col 0..319
```

一行图像 = 960 B = 60 个 128bit beat（16 B/beat）。整帧 230,400 B。

---

## 存储约定

- **unit = 40 bit = 5 B = 2 片 bram_10kb 同址并联**
- 全工程统一：**`bank = unit mod 6`，`addr = unit / 6`**
- `conv_mem_unit` 的地址 = `{seg[3:0], a[8:0]}`；`SEG=1` 时只用 `a[8:0]`
- 读延迟 = **1 拍**

### band12（12 行输入带）

```
u = slot*192 + ch*64 + k         slot = row mod 12, ch 0..2, k 0..63
u ∈ [0,2303]  →  bank = u mod 6, addr = u/6 ∈ [0,383]
结构 = 6 bank × 1 段 × 512 unit × 40 bit = 12 片
一次访问 = 4 个连续 unit（20 B），起点 (bank,addr) 由上游给，内部递推
（连续 4 个 unit 的 bank 必不相同 → 无 bank 冲突）
```

### plane（160×120×8 输出面）

```
P2: unit = (oc*120 + row)*32 + u      row 0..119, u 0..31（32 unit = 160 B/行）
unit 总数 = 8*120*32 = 30,720  →  bank = unit mod 6, addr = unit/6 ∈ [0,5119]
结构 = 6 bank × 10 段 × 512 unit × 40 bit = 120 片
```

**片数总账：band 12 + plane 120 = 132 / 256 = 51.6%**

---

## PE 阵列的使用契约（由 `rtl/pe10_10/tb_pe_rules.v` 仿真实测钉死，7/7 PASS）

| # | 结论 |
|---|---|
| F1 | 复用卷积：`op=1`、`wdata_en=1`、`start=1` **同拍**（记该拍为 `t0`），正确的 3×3 加权和在 **`t0+10`** 出现，**只有这一拍干净** |
| F2 | `t0+10` 之后 `peo` 继续脏累加，必须只抓那一拍 |
| F3 | 窗口搬运顺序（对 PE(r,c)）= 光栅序：`win[r][c],win[r][c+1],win[r][c+2],win[r+1][c],…,win[r+2][c+2]` |
| F4 | **b 逐拍采样**：tap `m` 用的权重 = `load_b_in` 在第 `m` 拍被采样的值（即 `t0+m` 那一拍采） |
| F5 | 关闭阵列（`op=1` 不发 `start`）→ 100 个 `peo` 恒为 0 |
| F6 | 直接相乘（`op=0`）：`load_b_in` → `peo` = **3 拍**，1 拍 1 个乘积，**PE 内部不累加** → pw 必须在阵列外做 `pacc[0:99]` |
| F7 | `pe_10_10` 把 48bit `PE_output` 截成 36bit；本设计数据 8bit → ≤2^19，安全 |

### L1 dw 相位的实测时序（`conv_l1` 直接照这个写，不要猜）

用 `tb_l1_dw` 把 PE 阵列输出逐拍抓下来扫出来的（**9 个核位置单点置 1** 定映射 + **扫 (权重偏移, 拍号)** 定拍号）：

| 计数器 `c` | 动作 |
|---|---|
| `c=0` | `op=1`、`wdata_en=1`、`start=1` **同拍**（窗口走 `fm_wdata` 组合进 `feature_map_12_12`），同时喂 `w_dw[ch*9+0]` |
| `c=1..9` | 逐拍喂 **`w_dw[ch*9 + c - 1]`** ← 注意是 `c-1`，不是 `c` |
| **`c=13`** | **抓 100 个 `peo`** → 量化 → `dwc[ch][*]` |

两条实测证据（都在 `tb_l1_dw` 里，可复现）：

1. **核位置 p 配的是 `c=p+1` 拍喂的权重** → 所以喂 `w[c-1]` 时，9 个核位置正好配 `w[0..8]`。
   喂 `w[c]` 的话会错位一格：核位置 0..7 配到 `w[1..8]`，第 9 个核位置**拿不到权重**（结果是 8 抽头和）。
2. **`c=12` 抓只有 8 个乘积**（第 9 个还没进累加器）；`c=13` 抓才是完整的 9 乘积和。
   验证：窗口只留第 9 个核位置 =1、权重给 `(t+1)<<8` 时，`c=12` 抓出来 `dwc=0`、`c=13` 抓出来 `dwc=9`。

### L1 pw / 池化 / 写回的实测时序（同一个 tb 验的）

**pw 相位（直接相乘 `op=0`）**，每个 oc 15 拍（`pc=0..14`）：

| pc | 动作 |
|---|---|
| `0..2` | `fm_wdata_en<=1`、`pw_cin<=pc` → 于是 **pc=1,2,3 各载入一次** `dwc[pw_cin]`（`pw_cin` 寄存后滞后一拍） |
| `1..3` | `pe_lb <= w_pw[oc*3 + pc-1]` → lb 在 **pc=2,3,4** 分别是 `w_pw[oc*3+0..2]` |
| `5` | `pacc <= peo`（第 1 个乘积） |
| `6` | `pacc <= pacc + peo`（第 2 个） |
| `7` | `qq <= quant(pacc + peo)`（第 3 个，边加边量化） |
| `8..9` | `pl_en=1` **连续两拍** |
| `10..14` | 写回 5 行 |

推导依据（实测）：`peo(k) = A(k-2)*B(k-2)`，其中 `A(k)`（即 `input_reg_a[0]`）= `feature_map(k-1)` = **载入值(k-2)**，
`B(k)`（即 `input_reg_b`）= `load_b_in(k-1)`。所以 a 走 `wdata_en` 比 b 多一级流水，两者的"拍"必须错开。

★ **关键**：`feature_map_12_12` 的 `load_a_in` 只能来自它内部的 `feature_map[]`，
所以直接相乘的 a 数据**必须经 `wdata_en` 装进 12×12 图的左上 10×10**（这就是"放在左上区域"的真正含义）。

**池化**：`conv_cmp4_tree` 是**真两级流水**（第二级取上一拍的 `p_lo/p_hi`），
所以 `en` **必须连续两拍**——只给一拍第二级不动，输出会一直是旧值（症状：pool 全 0 或全旧值）。

**写回**：`unit = (oc*120 + row)*32 + tile_c`，`row = tile_r*5 + i`；
行间 unit 差 32 → `bank += 2 (mod 6)`，`addr += 5`，`bank+2` 溢出时再 `+1`。

---

## 决策记录（Q1~Q7，先用建议值，随时可改）

| # | 决策 |
|---|---|
| Q1 | band = **6 bank × 1 段**（片数与 3bank×2段 相同，去掉 seg，与 `PROJECT_PATH` §5.4 一致） |
| Q2 | "每 tile 51 拍" = **PE 发 MAC 的预算**；整 tile 墙钟 ≈118 拍（窗口/量化/池化与 MAC 重叠） |
| Q3 | 抓数拍以**实测 `t0+10`** 为准 |
| Q4 | 权重走顶层端口 `w_dw[0:26]` / `w_pw[0:23]` |
| Q5 | 本轮**只做 L1**（到 160×120×8） |
| Q6 | 直接相乘的数据放 **12×12 图的左上 10×10**（`load_a_in` 的实际映射） |
| Q7 | DDR 一行 960 B = 60 beat，一次发起整行 |

---

## 仿真（**每个文件夹都能单独仿真**）

三种跑法都行：

```bat
:: ① 顶层：全量编译 + 依次跑各模块（工程根目录）
rtl\conv2\run.bat

:: ② 顶层只做全量编译
vsim -c -do rtl/conv2/run.do

:: ③ 单独跑某一个模块（子文件夹里双击 run.bat 也行）
vsim -c -do rtl/conv2/conv_cmp4_tree/run.do    :: 4 输入比较树
vsim -c -do rtl/conv2/conv_pool_arr/run.do     :: 25 棵池化阵列
vsim -c -do rtl/conv2/conv_mem_unit/run.do     :: 512×40 unit（bram_10kb 封装）
vsim -c -do rtl/conv2/conv_band12/run.do       :: 输入 12 行带
vsim -c -do rtl/conv2/conv_win_load/run.do     :: 12×12 窗口 + 反射
vsim -c -do rtl/conv2/conv_in_dma/run.do       :: DDR → band（字节重对齐 + 信用）
vsim -c -do rtl/conv2/conv_plane/run.do        :: 输出面
```

每个文件夹一个独立 work 库，产物落在本文件夹：`work/`、`transcript`、`<模块>.wlf`。

| 文件夹 | 库名 | tb | 依赖（用 `../xxx/`） |
|---|---|---|---|
| `conv_cmp4_tree` | `ltree` | `tb_cmp4_tree` | — |
| `conv_pool_arr` | `lpool` | `tb_pool` | `../conv_cmp4_tree/` |
| `conv_mem_unit` | `lmem` | `tb_mem_unit` | — |
| `conv_band12` | `lband` | `tb_band` | `../conv_mem_unit/` |
| `conv_win_load` | `lwin` | `tb_win` | `../conv_mem_unit/` + `../conv_band12/` |
| `conv_in_dma` | `ldma` | `tb_dma` | `../conv_mem_unit/` + `../conv_band12/` |
| `conv_l1` | `ll1` | `tb_l1_dw` | `rtl/pe/` + `rtl/pe10_10/` + `rtl/dsp48/` |
| `conv_plane` | `lplane` | `tb_plane` | `../conv_mem_unit/` |
| 本层（顶层） | `c2all` | （`tb_top` 待写） | 全部 |

注意：`bram_10kb.v` 里 `include` 了 `bram_ini.vh` / `bram_decompose.vh`，
所以涉及 BRAM 的模块，vlog 必须带 `+incdir+ip/bram_10kb`（各 `filelist.f` 已配好对应的 `run.do`）。

## 当前进度

| 里程碑 | 内容 | 状态 |
|---|---|---|
| M0 | 目录骨架 + 接口约定 | ✅ |
| M1 | `conv_cmp4_tree` / `conv_pool_arr` / `conv_mem_unit` / `conv_band12` / `conv_plane` | ✅ |
| M2 | `conv_win_load`（band → 12×12 窗口，含边界反射） | ✅ |
| M3 | `conv_in_dma`（DDR → band，16B 字节重对齐 + `rows_free` 信用） | ✅ |
| M4 | `conv_l1` 的 dw 相位（**实测抓数拍 = `c=13`、权重喂 `w[c-1]`**） | ✅ |
| M5 | `conv_l1` 的 pw（外部 `pacc`）+ 量化 + 池化 + 写回 | ✅ |
| M6 | `conv_sched` + `conv_top`（顶层写在本层，纯结构例化）+ 端到端 `tb_top` | ✅ |
| M7 | 整帧回归 320×240×3 → 160×120×8 + 资源/时序 | ⬜ 待写 |

### 自检结果（10 个 tb 全 PASS）

| 模块 | tb | 验什么 | 结果 |
|---|---|---|---|
| `conv_cmp4_tree` | `tb_cmp4_tree` | max 正确 + 两级流水延迟 + `en=0` 保持；随机/全0/全255/全同值/最大值轮转 | **PASS** |
| `conv_pool_arr` | `tb_pool` | 25 点逐点 = 2×2 max + 延迟 + `en=0` 保持；6 个用例 | **PASS** |
| `conv_mem_unit` | `tb_mem_unit` | SEG=1 的 512 slot 全写全读；SEG=4 的段隔离与 `{seg,a}` 解码；读延迟=1 | **PASS** |
| `conv_band12` | `tb_band` | 2304 unit 全写全读；非对齐起点 u=1..8（bank 5→0 回绕 + addr 进位）；读延迟=1 | **PASS** |
| `conv_win_load` | `tb_win` | 12×12 窗口逐字节；**2 个相位 × 32 个 tile_c × 3 通道 = 192 个窗口**，含上/下边界反射与左/右列反射 | **PASS** |
| `conv_in_dma` | `tb_dma` | 240 行 DDR→band 全搬；**16B→20B 字节重对齐**；`rows_free` 信用真能挡停生产者；前 11 行 + 末 12 行共 4608 个 unit 逐字节比对 | **PASS** |
| `conv_l1`（dw 专项） | `tb_l1_dw` | 9 个核位置单点置 1 定映射；扫 (权重偏移, 拍号) 定抓数拍；3 通道 × 100 PE 全量对拍 | **PASS** |
| `conv_l1`（整片） | `tb_l1` | dw → pw → 量化 → **池化** → **写回**；8 oc × 5×5 池化结果 + plane 写口的 40 个 unit（地址 + 数据）全对 | **PASS** |
| `conv_sched` | `tb_sched` | tile 序列（r,c）逐拍核对；`l1_start`/`wl_start`/`rows_free` 次数；等带填满才起第一个 tile；`done` | **PASS** |
| `conv_plane` | `tb_plane` | 30,720 unit 全写全读；seg 0..9；读延迟=1 | **PASS** |
| **端到端** | `tb_top` | `conv_top` 小图 **80×40×3 → 40×20×8**（32 个 tile，所有地址/反射关系与整帧一致）；`done` 到达 + **1280 个 plane unit 逐字节对拍** | **PASS** |

### 踩坑记录（本工程）

| # | 坑 | 规矩 |
|---|---|---|
| 1 | **`buf` 是 Verilog 保留字** | 内部变量别叫 `buf`（本工程用 `abuf`） |
| 2 | **unit 号 `u` 最大 2300，要 12 bit** | 写 `wire [8:0] uu` 会被截断（2300 → 236）→ 地址全乱。凡涉及 `u` 的表达式都要 ≥12 bit |
| 3 | ModelSim 10.4 的 `vsim` **没有 `-work` 选项** | 库名直接写在 design 前面：`lband.tb_band` |
| 4 | `vsim -c` 批量模式**不产出 wlf** | 要看波形在 GUI 里跑 `run.do` |
| 5 | tb 里"计数脉冲"比 DUT 的 `done` **晚一拍** | 等 `done` 后要 `repeat(N) @(negedge clk)` 再读计数器 |
| 6 | **dw 权重喂早一拍会丢第 9 个抽头**（变成 8 抽头和，且不报错） | 必须喂 `w_dw[ch*9 + c-1]`，且 `c=13` 抓数；靠 `tb_l1_dw` 的两个相位守住 |
| 7 | **池化 `en` 只给一拍 → 第二级推不动** | `conv_cmp4_tree` 是真两级流水，`en` 必须连续两拍 |
| 8 | **pw 的 a 走 `wdata_en` 比 b 多一级流水** | a 与 b 的"拍"必须错开；`pw_cin` 要**寄存后**再用于 `fm_wdata` 的 mux（用组合 `pc` 会取到下一个 `dwc`） |
| 9 | **`start` 只有一拍、但状态机要等某个条件才启动 → 死锁** | 起第一个 tile 要等输入带填够 11 行，所以 `start` 必须**锁存**（`started` 标志），不能直接当条件用 |
| 10 | **仿真慢 + 超时设太大 = 卡住要等很久** | `tb_top` 里加"每 N 拍打印 tile_r/tile_c/关键状态"的进度探针，并把超时收到 300k 拍 |
| 11 | **下级的 `done` 保持到下一次 `start`（电平），上级用 `if (done)` 判 → 一次完成触发多次** | tile 计数器一次加 2、`win_req` 只有应有值的一半。上级必须取 **上升沿**（`done & ~done_d`） |
| 12 | **`rows_free` 只表示"允许写"，不表示"已经写好"** | 跨 tile 行时，下一行要的 rows 10k+11..10k+20 还没进带，而第一个 tile 立刻开跑 → 读到旧行。必须**等 `in_row_vld` 计数够**（`rcnt >= 10k+11`）再起 tile 行 |
| 13 | **tb 的黄金模型和 `dmem` 填充有 time-0 竞争** | 权重用 `reg` 初始化（不要 `wire`+`generate`，time 0 还没传播），并且 `wait(ready)` 后加 `#100` 再算黄金 |
| 14 | **tb 的桩太"乖"就抓不到接口 bug** | `tb_sched` 的假 conv_l1 一开始 `done` 只给一拍，所以才没抓到踩坑 #11；改成**和真 conv_l1 一样保持两拍**后立刻暴露 |
| 15 | **"等带填够"的门槛算错一行 → 直接死锁** | tile 行 k 最高只用到 row `10k+10`，而最后一行会被反射成 `IH-2`，所以门槛要钳到 `IH`：`min(10(k+1)+11, IH)`。写成 `10(k+1)+11` 时，最后一行永远等不到，卡在 `tile r=22 c=0` |
| 16 | **band 的 `CPU`（每通道每行 unit 数）必须在 DMA 和 win_load 传同一个值** | 布局是 `u = slot*(3*CPU) + ch*CPU + k`，`CPU = IW/5`。整帧 IW=320 时 CPU=64 正好等于默认值所以看不出来；小图 IW=80 时 DMA 按"整行连续"写、win_load 按 `ch*64` 读 → **ch1/ch2 全读到没写过的地方（0）**。`conv_top` 必须传 `.CPU(IW/5)` 给两者 |
| 17 | **`efx_map` 命令行空指针崩溃** | `ERROR: EXCEPTION_ACCESS_VIOLATION reading memory at (nil)`，栈固定是 `libefx.dll+0x3f333 → ucrtbase → efx_map.exe+0x19323`。**连之前跑通过的 memtest 原命令现在也崩**（同一段栈）→ 说明是**这个环境/这次会话**的问题，不是设计的锅（怀疑与一直开着的 Efinity GUI 抢资源/锁有关）。综合请走 GUI |

### 综合（GUI）当前进展与卡点

在 Efinity GUI 里跑 synthesis（2026.1）时，走到这一步崩了：

```
WARNING : Mapping into logic memory block 'u_top/u_l1/u_fm/feature_map' (2592 bits)
          because it has all constant reader/writer. [EFX-0657]
ERROR   : EXCEPTION_ACCESS_VIOLATION reading memory at 0x4a
          libvfc_database.dll + ... → efx_map.exe
```

**分析**：`feature_map_12_12` 里 144×18bit 的 `feature_map[]`，**读写下标全是常数**
（写是 `for i: feature_map[i] <= wdata[i]`；读是 genvar 常数下标），所以工具把它当
"logic memory block"（分布式 RAM）映射 —— 就在这之后数据库模块崩了。

**这是用户原文件，按约束不能改**。可尝试的绕过办法（按代价排序）：

1. **换 Efinity 版本**：本机还装了 `2023.2` / `2025.2`，2026.1 的这个 DB bug 很可能在别的版本没有；
2. 在 `rtl/pe10_10/feature_map_12_12.v:16` 的数组声明上加综合属性让它别推断成 memory，例如
   `(* syn_ramstyle = "registers" *) reg [17:0] feature_map [0:143];`（**1 行改动，但动了用户文件**）；
3. 在 GUI 的 synthesis 选项里关掉 logic-memory 推断（如果有这个开关）；
4. 我做一个**功能完全相同的副本** `conv_feature_map_12_12.v`（带属性、模块名不同）给 `conv_l1` 用，
   **原文件保持不动** —— 需要你同意（因为约束是"用用户的原件"）。

诊断用的小顶层在 `rtl/conv2/probe/`（`probe_plane.v` 只含存储、`probe_l1.v` 只含计算），
可以拿来在 GUI 里二分定位。

### 已做的绕过（EFX-0657）

按官方解释，EFX-0657 = **读写下标全接成常数 → 工具无法做成 BRAM，只能 bit-blast 成逻辑**，
它同时点了 `pacc` 和 `feature_map`。已加显式属性绕开那条推断路径：

| 数组 | 文件 | 处理 |
|---|---|---|
| `pacc[0:99]` / `qq[0:99]` / `pe_lb[0:99]` | `rtl/conv2/conv_l1/conv_l1.v`（我的文件） | 直接加 `(* syn_ramstyle = "registers" *)` |
| `feature_map[0:143]` | **用户原件不动**；另存一份 `rtl/conv2/conv_l1/feature_map_12_12_syn.v` | 只多一行属性，**模块名保持 `feature_map_12_12`**，综合 XML 指向这一份；**仿真仍用用户原件**（属性对仿真透明） |

> 若工具不认 `"registers"` 这个取值，换成 `"logic"` / `"distributed_ram"` 即可（只改这两个文件里的属性字符串）。

---

## 板级验证（不接 DDR，内部自己造激励）

`rtl/conv2/board/` 里是**可综合**的板级顶层：

| 文件 | 说明 |
|---|---|
| `conv_board_top.v` | 板级顶层：内部假 DDR（`rd_en` → 4 拍延迟 → 1 beat/拍）+ 图案 `addr[7:0]^addr[15:8]^0x5A`；跑完从 plane 回读 1280 个 unit 算 40bit 校验和；`led[0]=done`、`led[1]=PASS`、`led[2]=FAIL`、`led[3]=busy` |
| `tb_board.v` | 仿真自检（就是上面的假 DDR + 校验和比对），已 **PASS**，校验和 = `c2eaf2eaaf` |
| `conv_board.sdc` | 时钟约束（默认 100 MHz，`create_clock -period 10`） |
| `filelist.f` / `run.do` / `run.bat` | 单独仿真 |

**综合工程**：根目录 `conv_board.xml`（顶层 `conv_board_top`，含 15 个 design_file + `bram_10kb` IP + SDC）。

### 交接：在 Efinity GUI 里怎么跑

1. Efinity → **Open Project** → 选根目录的 `conv_board.xml`
2. 跑 **Synthesis**，看资源报告应为：
   - **RAMs = 132**（band 12 + plane 120）✓ 仿真里数过
   - **DSP = 100**（100 个 PE）
   - XLR 约 15k~25k（老 18bit PE 阵列是 14,974）
3. **分配引脚**（我不知道你的板子引脚，需要你按板子填）：
   - `clk`（第一版建议 ≤100 MHz，可直接用板上晶振；不需要 PLL）
   - `rst_n`（按键，低有效）
   - `led[3:0]`
4. 跑 Place & Route → Bitstream → 下载
5. **板上预期现象**：复位释放后几十微秒内 `led[0]`(done) 与 `led[1]`(PASS) 点亮、`led[2]`(FAIL) 不亮；
   若 `led[2]` 亮说明校验和对不上（先看 `chk_out` 调试口）。

> 板级顶层默认参数是**小图 80×40×3**（32 个 tile），上板第一版用它；
> 想跑整帧就把 `IW/IH/ROWB/NBEAT/NTILE_R/NTILE_C` 改成 `320/240/960/60/24/32`
> （校验和的 GOLDEN 需要重新用仿真取一次）。

### 整帧回归（`tb_top_full`，320×240×3 → 160×120×8，768 个 tile）—— **PASS**

- 跑到 `done`：**186,887 拍 ≈ 243 拍/tile ≈ 0.93 ms @200MHz**
  （其中纯计算 ≈ 171k 拍；多出来的 ~15.6k 拍是 23 个 tile 行边界各等 DMA 补 ~680 拍，
   这是"等带真正填好"的必然代价——用 `rows_free` 只放行不等待的版本会读到旧行，见踩坑 #12）
- 抽样 8 个 tile（四角 + 四边 + 中间）逐字节比对 plane 的 **320 个 unit，全部 0 失败**
- 窗口装载握手计数校验：`win_req = wl_start = win_vld = 2304`（= 768 tile × 3 通道），不多不少
- 片数实测：`band12` 12 片 + `plane` 120 片 = **132 / 256 = 51.6%**（`rtl/conv2/count_bram.do` 在仿真里数的）

> 速度参考：ModelSim 10.4 大约 **700~800 拍/秒**（100 个 DSP48 + 132 片 BRAM 行为模型）。
> `timescale` 由 1ps 改 1ns **不会变快**（tb 只有 ns 级事件，精度不影响事件数）；
> 真正的旋钮是去掉 `-voptargs=+acc`（它为了保留层次探针把优化关了）。
