# conv 工程交接提示（复制给新会话用）

> **一键切换用**：把下面 `====` 之间的内容整段复制给新会话即可。

```
=====================================================================
【工程】D:\my_code\fpga\yilisi\conv10_10  （Efinity 工程 conv10_10，器件 Ti60F225）
【目标】写 conv 前端 RTL，输入是**已经池化好的 320x240x3（RGB888，8bit/ch）**，
        做到输出 **160x120x8** 为止（L1: dw3x3+pw1x1 + 池化融合）。
【硬约束】
  1. 池化用 4 输入 8bit 比较树，两级流水打拍，5x5 = 25 棵构成（已交付）
  2. PE 阵列要求**全流水**：每 tile 拍数 = CIN*9 + CIN*COUT（L1 = 3*9+3*8 = 51 拍）
  3. PE 用**用户自己的** rtl/pe/pe.v + rtl/pe10_10/pe_10_10.v（位宽 18bit 不动）
  4. 一个文件一个模块
  5. DDR 里池化图布局：base + row*960 + [0..319]=R / [320..639]=G / [640..959]=B
  6. 片型只用 ip/bram_10kb（SDP_RAM 512x20，1 片 = 1,280 B = 100% 利用率）
【当前进度】RTL 全部写完并能编译通过；仿真卡住未跑到 done，下一步是定位卡点。
【必读】rtl/conv/PROJECT_BRIEF.md（完整交接说明与注意事项）
=====================================================================
```

---

## 1. 网络与数据

| 级 | 输入 → 输出 | 说明 |
|---|---|---|
| 输入 | DDR 里的 **320×240×3 RGB888**（池化已在外部完成，本设计不含池化） | 行布局 `row*960 + {R320,G320,B320}`，240 行，共 230,400 B |
| L1 | 320×240×3 → 320×240×8 →（2×2 max 池化融合）→ **160×120×8** | 10×10 tile，32×24 = 768 tile |
| L2/L3（后续，不在本轮范围） | 160×120×8 → 80×60×16 → 80×60×32 | |

- 计算 8bit；tile 拍数 = `CIN*9 + CIN*COUT`（全流水，每抽头 1 拍）
- 时间预算（L1）：768 × 51 ≈ 39k 拍；整帧三级 ≈ 125k 拍 ≈ 0.63 ms @200MHz

## 2. 已实测确认的关键事实（不要再推翻）

| 项 | 结论 | 证据 |
|---|---|---|
| 器件 | Ti60F225：**256 片 × 10 Kbit = 320 KB BRAM**，160 DSP，60,800 XLR | Efinix 官方 Ti60 页面 |
| 片型 | **`ip/bram_10kb`（SDP_RAM，512 字 × 20 bit = 1,280 B/片，`bram_mapping_size = 1`，100%）** | `ip/bram_10kb/bram_decompose.vh` |
| 反例 | TDP 版要 2 片（640 B/片，50%）；宽字（128/120 bit）实测 7 片 / 240 片；20 bit 推断 RAM 会让 `efx_map` 崩 | `BRAM_VERIFY.md`、`STORAGE_V3.md` §9 |
| 100 PE 阵列资源 | **DSP 100/160 (62.5%)、XLR 14,974 (24.6%)** | `conv10_10_pe.xml` 综合 + PnR 报告 |
| DSP 双乘 | `EFX_DSP48 MODE="DUAL"`：`A[18:8]×B[17:8]`→O[36:16]、`A[7:0]×B[7:0]`→O[15:0]，两车道不重叠 | `rtl/dsp48/efx_dsp48.v` |

## 3. 存储方案 V4（132 片 = 51.6%）

详见 `MEM_PLAN_V4.md`。要点：

| 区域 | 结构 | 片数 | 带宽 |
|---|---|---|---|
| `conv_band12`（12 行 × 320px × 3ch = 11,520 B） | **6 bank** × 1 段 × 2 片 | **12** | 写 26.7 B/拍（满速 1.67×）。12 片 |
| `conv_plane`（P2/P4/P5 复用，153,600 B） | 6 bank × 10 段 × 2 片 | **120** | 读/写各 30 B/拍；每 bank 占用 ≤24% |

- **unit = 40 bit = 5 B = 2 片同址并联**；`bank = unit mod 6`（用计数器实现，不做除法）
- 行布局：`P2 行 = 160 B = 32 unit`、`P4 行 = 80 B = 16 unit`、`P5 行 = 160 B = 32 unit`
- 原地复用：`P4 行 r → P2 行 r 地址`、`P5 行 r → P4 行 2r 地址`；纪律 `wr_row ≤ rd_row − 2`
- 5 字节 unit 与池化块宽 5 天然对齐 → 池化写回"每行 5 字节"= 正好 1 个 unit，无需字节使能

## 4. 文件清单与状态

| 文件 | 状态 |
|---|---|
| `rtl/conv/conv_cmp4_tree.v` | ✅ 4 输入 8bit 两级流水比较树 |
| `rtl/conv/conv_pool_arr.v` | ✅ ROWS×COLS 阵列（5×5 = 25 棵） |
| `rtl/conv/conv_l1.v` | ✅ L1 引擎（窗口→dw→dwc→pw→量化→池化→逐 oc 输出 5×5） |
| `rtl/conv/conv_band12.v` | ✅ 6 bank × 2 片（`bram_10kb`） |
| `rtl/conv/conv_plane.v` | ✅ 6 bank × 10 段 × 2 片（120 片） |
| `rtl/conv/conv_win_load.v` | ⚠️ 能编译；**待改**：12 字节抽取改桶形移位、`%5` 改计数器 |
| `rtl/conv/conv_in_dma.v` | ✅ DDR→band12（5 beat = 16 unit），全计数器，已修保留字/编码问题 |
| `rtl/conv/conv_top.v` | ⚠️ 能编译；**待改**三处集成问题（见 §5） |
| `rtl/conv/conv_tb.v` | ✅ DDR 模型 + 黄金模型（比对 tile(0,0) 的 5×5×8） |
| `rtl/conv/filelist.f` / `sim_conv.do` / `run.bat` | ✅ 一键仿真（`-sv`、`-timescale`、方括号已加 `{}`） |
| `rtl/conv/MEM_PLAN_V4.md` | 存储/带宽方案（权威） |
| `rtl/conv/BRAM_VERIFY.md` / `STORAGE_V3.md` | 片型实测与方案演进（历史依据） |
| `project/conv/conv_pe_test.v` + `conv10_10_pe.xml` | 100 PE 资源标定（已实测 24.6% XLR） |
| `project/conv/conv_test.v` + `conv10_10_test.xml` + `conv10_10_pe.xml` | BRAM 形状/片数标定 |

## 5. 当前卡点（下一步从这开始）

**现象**：`vsim -c -do "do rtl/conv/sim_conv.do; quit -f"` 编译/elaboration 全过（`Errors: 0`），
但仿真 10 分钟未结束 —— 没跑到 `done`。

**最可能的四个原因（按怀疑度排序）**：

1. `conv_top` 与 `conv_l1` **重复计数通道 `ch`** → 握手错拍；
2. `conv_top` 里 `rows_free` 接了常量 1 → DMA 一路跑完 240 行冲掉 12 行环；
3. `wl_start`（一次性脉冲）与 `conv_l1` 的 `win_req`（电平）不匹配 → 第二次以后永远等不到 `win_vld`；
4. TB 超时设得太大（`#50000000`），卡住时无法定位。

**建议顺序**：
1. TB 超时改 `#300000`，每 1000 拍打印 `tile_r/tile_c/u_l1/st/u_dma/st/u_wl/st` → 定位卡点；
2. 修 `ch` 计数（顶层只维护 `tile_r/tile_c`，窗口加载由 `win_req` 驱动）；
3. `rows_free` 接真握手（L1 每消费 32 个 tile 释放 10 行）；
4. `wl_start` 改上升沿 + 非 busy 启动，装载完给 `win_vld` 电平；
5. 跑通后把比对范围从 tile(0,0) 扩到整帧 160×120×8。

## 6. 操作注意事项（踩过的坑）

| 坑 | 规矩 |
|---|---|
| PowerShell `Set-Content` 会把含中文的文件写成 ANSI → 非法 UTF-8 | **不要用 Set-Content/Add-Content 改这些文件**；用编辑工具，或 `[System.IO.File]::WriteAllText($p,$t,[System.Text.UTF8Encoding]::new($false))` |
| 同一个 IP 文件既在 IP 清单又被当 design_file 加一遍 | 报 `overwriting previous definition of module`；`ip/*/*.v` **只通过 IP 清单引入** |
| 数组端口是 SystemVerilog 语法 | `vlog` 必须带 `-sv` |
| EFX_RAM10 模型无 timescale | `vlog` 加 `-timescale "1ns/1ps"`；模型在 `ip/bram_1KB/_Testbench_nosyn/efx_ram10.v` |
| Tcl 里 `[0]` 是命令替换 | 波形路径用 `{sim:/.../pacc[0]}` 包起来 |
| `buf` 是 Verilog 保留字 | 内部变量改名（已改 `stage`） |
| 我的命令行 `efx_map.exe` 一直空指针 | 综合/布线请在 **GUI** 里跑（GUI 正常） |
| 100 PE 测试顶层别把 100×36 bit 都引成引脚 | 异或成 1 位输出（已改） |
