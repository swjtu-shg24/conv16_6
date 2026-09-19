# conv10_10 L1 前端 · 重写完成计划（V5）

> 本文是**要我（新会话）照着做**的施工计划，供你审阅。
> 纪律：**先写 tb 拿到期望值，再写 RTL**；每一步都能单独验收，不跑到最后一起调。
> 说明：`_user_originals_backup/ai_rewritten/` 里的旧 RTL **完全不参考**，下面是独立推导。

---

## 0. 前提与盘点

### 0.1 目标（只做 L1，到 160×120×8 为止）

| 项 | 内容 |
|---|---|
| 器件 | Efinix Ti60F225（工程 `conv10_10`） |
| 输入 | DDR 里**已池化好的** 320×240×3 RGB888，行布局 `base + row*960 + {R[320],G[320],B[320]}`，共 230,400 B |
| 计算 | L1 = `dw3×3` + `pw1×1` + 量化 + 与 `2×2 max` 池化融合 |
| 输出 | 160×120×8 |
| tile | 输出面 10×10 一块 → 12×12 输入窗口（含反射边界）；32×24 = **768** tile |
| 片型 | **只用** `ip/bram_10kb`（SDP 512×20）；unit = 40 bit = 5 B = **2 片同址并联** |

### 0.2 硬约束（照抄，不解释）

1. 池化 = **4 输入 8bit 比较树、两级流水**，5×5 = **25 棵**（已交付 `conv_cmp4_tree.v` / `conv_pool_arr.v`）
2. PE 阵列**全流水**（每个 tap 占 1 拍，不许插气泡）
3. PE 用你原来的 `rtl/pe/pe.v` + `rtl/pe10_10/pe_10_10.v` + `rtl/pe10_10/feature_map_12_12.v`，**一行不改**
4. **一个文件一个模块**
5. DDR 布局 `row*960 + {R,G,B}`；片型只用 `ip/bram_10kb`
6. **禁止**用 PowerShell `Set-Content`/`Add-Content` 改这些文件（会写成 ANSI）

### 0.3 我已经用仿真钉死的事实（本计划的时序全部据此）

来自我写的 `rtl/pe10_10/tb_pe_rules.v`（7/7 PASS，结论已在上轮汇报）：

| # | 事实 | 数值 |
|---|---|---|
| F1 | 一次复用卷积（`op=1` + **一次** `start`，`op` 全程不拉低），**正确的 3×3 加权和出现在 `t0+10` 拍**，只在这一拍干净 | `t0` = `wdata_en`/`op`/`start` 同拍那个时钟沿 |
| F2 | `t0+10` 之后 `peo` 继续累加（脏），**必须只抓那一拍** | 实测 126 → 153 → 180… |
| F3 | 窗口搬运顺序 = "一行 3 个、换行 +12"（12 宽窗口） | `a0 = 1,2,3, 13,14,15, 25,26,27, …` |
| F4 | **b 是逐拍采样的**：9 个 tap 可以用 9 个不同权重（真 3×3 核成立） | 窗口≡1、b 循环 {1,2,3,4,6,7,8,9,10} → peo=**50** |
| F5 | 关闭阵列（`op=1` 不发 `start`）→ 100 个 `peo` **恒为 0** | 20 拍 × 100 lane 全 0 |
| F6 | 直接相乘（`op=0`）：`load_b_in` → `peo` = **3 拍**，**1 拍 1 个乘积**，且**不累加**（`acc<=dsp_o`） | 20,21,22… 线性跟随 |
| F7 | `pe_10_10.v` 把 `pe.v` 的 48 bit `PE_output` 截成 **36 bit**（100 条 vsim-3015 警告） | 本项目数据是 8 bit：乘积 ≤65025、9 tap ≤585,225 < 2^19 → **36 bit 够用，不是阻塞项** |

> **F6 是架构级结论**：pw 相位**不能**靠 PE 自己的累加器（直接相乘模式 `acc_en=0`），
> 必须在阵列外做 `pacc[0:99]` 累加。这是 `conv_l1` 的主要 FF 开销（100 × ~24 bit）。

### 0.4 rtl/conv 现状盘点（要清掉的东西）

| 文件 | 处置 | 原因 |
|---|---|---|
| `conv_cmp4_tree.v`、`conv_pool_arr.v` | ✅ **保留** | 已交付，一文件一模块，符合约束 1 |
| **`conv_pool_tree.v`** | ❌ **删除** | 它把 `conv_cmp4_tree` + `conv_pool_arr` **两个模块重复定义在同一个文件里**，既违反约束 4，又与上面两个文件**模块重名**（一起编译会报重复定义） |
| `conv_top.v`、`conv_tb.v` | ♻️ **重写** | 现 `conv_top.v` 例化的 `conv_in_dma/conv_band12/conv_win_load/conv_l1/conv_plane` 已不在 `rtl/conv`（在 `_user_originals_backup/ai_rewritten/`），**现在编译不过** |
| `conv_pe.v`、`conv_pe_10_10.v`、`conv_feature_map.v` | ❌ **删除/隔离** | 是 `pe.v`/`pe_10_10.v`/`feature_map_12_12.v` 的 8bit 变体副本，且**中文注释编码已损坏**（3 字节 UTF-8 序列末字节被写成 `0x3F`）。按约束 3 应直接用原始文件，不需要这三份 |
| `filelist.f` | ♻️ 重写 | 引用了 5 个不存在的文件 |
| `PROJECT_PATH.md` | 📌 **唯一权威文档**，我只追加不改写 | |
| `PROJECT_BRIEF.md` / `DESIGN.md` / `BRAM_VERIFY.md` / `STORAGE_V3.md` / `MEM_REUSE_PLAN.md` | 📚 历史，仅作参考 | 结论已被 `MEM_PLAN_V4.md` / `PROJECT_PATH.md` 取代 |

---

## 1. 总体架构

```
DDR(128bit/beat)
  │
  ▼  conv_in_dma           行 960 B = 60 beat；240 行
  │
  ▼  conv_band12           12 行环 × 320px × 3ch = 11,520 B（12 片）
  │                        slot = row mod 12，消费完 10 行 → rows_free
  ▼  conv_win_load         12×12 × 1ch = 144 B（含反射），逐通道装
  │
  ▼  conv_l1               dw3×3(3ch) → pw1×1(3→8) → 量化 → 2×2 max 池化 → 5×5×8
  │                        内部例化 pe_10_10 + feature_map_12_12（原样不动）
  ▼  conv_plane            160×120×8 = 153,600 B（120 片），P2/P4/P5 同址复用
  │
  ▼  p2_rd_*（读回/给下一级）
```

### 模块表（一文件一模块）

| # | 文件 | 职责 | 关键端口 |
|---|---|---|---|
| 1 | `conv_mem_unit.v` | **唯一例化 `bram_10kb` 的地方**：2 片同址并联成 1 个 40bit unit；参数 `SEG` 段数 | `wr_en/wr_addr/wr_data`、`rd_en/rd_addr/rd_data` |
| 2 | `conv_band12.v` | 12 行环物理存储：6 bank × 1 段 × 512 unit（12 片）；**3 组读写端口**（一拍 3 unit = 15 B） | `bk_wr_*[0:2]`、`bk_rd_*[0:2]`、`slot` |
| 3 | `conv_plane.v` | 输出面：6 bank × 10 段 × 512 unit（120 片） | `wr_en/bank/addr[12:0]/data[39:0]`、`rd_*` |
| 4 | `conv_in_dma.v` | DDR → band：行级 DMA + **16B→15B 字节重对齐** + slot 环 + `rows_free` 信用 | DDR 读接口、`b12_wr_*`、`rows_free` |
| 5 | `conv_win_load.v` | band → 12×12 窗口（144 B），行/列双向反射 `-1→1`、`N→N-2` | `tile_r/tile_c/ch` → `win_d[0:143]`、`win_vld` |
| 6 | `conv_l1.v` | **核心**：dw 相位 → pw 相位 → 量化 → 池化 → 写回 | 窗口 + 权重 → plane 写口 |
| 7 | `conv_cmp4_tree.v` | 4 输入比较树（两级流水） | 已交付 |
| 8 | `conv_pool_arr.v` | 25 棵阵列（10×10 → 5×5） | 已交付 |
| 9 | `conv_top.v` | tile 调度 + 握手 + `done` | DDR 接口 + 权重 + plane 读口 |

---

## 2. 存储与地址映射

### 2.1 unit / bank / addr 约定

- `unit = 40 bit = 5 B`；**bank = unit mod 6**；一次访问"每 bank 各取 1 个 unit" → 一拍 30 B（6 bank）
- 本设计**实际每次只用 3 个连续 unit**（15 B），落在 3 个不同 bank 上
- **不做除法**：bank 用 `u mod 6` 计数器轮转，`addr = u/6` 用每 6 拍 +1 的计数器

### 2.2 band12

```
u = slot*192 + ch*64 + k        slot = row mod 12, ch = 0..2, k = 0..63
u 范围 0..2303 → bank = u mod 6, addr = u/6 (0..383)
片数 = 6 bank × 1 段 × 2 片 = 12 片

为什么 u 是 slot*192 + ch*64 + k：一行 320 B = 64 unit/通道，3 通道 = 192 unit
为什么 6 bank：一行任意位置起取 12 B，跨 3 个 unit，一次读 15 B > 12 B（1 次访问/行）
```

> ⚠️ **文档冲突待拍板**：`MEM_PLAN_V4.md` §1 用 **3 bank × 2 段**（每 bank 768 unit），
> `PROJECT_PATH.md` §5.4 与 `conv_top.v` 的端口（`bank[2:0]`/`addr[8:0]`）用 **6 bank**。
> 两者片数都是 12。**我建议 6 bank × 1 段**：片数相同、`addr` 只需要 9 bit（384/512 用量）、
> 与现有 `conv_top.v` 端口一致、`MEM_PLAN_V4` §5.2 里的 "2 段" 在 u ≤ 2303 时其实用不到。

### 2.3 plane（P2 视图）

```
P2: unit = (oc*120 + row)*32 + u      oc 0..7, row 0..119, u 0..31（32 unit = 160 B/行）
unit 总数 = 8*120*32 = 30,720
bank = unit mod 6, addr13 = unit/6 (0..5119) → conv_plane 内拆成 {seg[3:0], a[8:0]}
片数 = 6 bank × 10 段 × 2 片 = 120 片
写回：每 oc 每行 5 B = 1 个 unit → 40 拍/tile（8 oc × 5 行）
```

**片数总账**：band 12 + plane 120 = **132 / 256 = 51.6%**（与 `PROJECT_PATH.md` §5.4 一致）

### 2.4 输入写口的字节重对齐（关键细节）

DDR 一拍 **16 B**，unit 是 **5 B**，两者不对齐；一行 960 B = 192 unit 正好整除（行首对齐）。

→ `conv_in_dma` 内部维护一个 40 bit 移位拼接缓冲 + 5 字节计数：
每凑满 5 B 出一个 unit，每 3 个 unit（15 B）打包成一次 3 端口写。
平均写需求 = 230,400 B / 39,168 拍 = **5.9 B/拍**，供给 15 B/拍 → **2.5× 余量**。

---

## 3. conv_l1 相位与拍数（每 tile）

### 3.1 相位表

| 相位 | 拍 | 动作 |
|---|---|---|
| `S_WAIT` | — | 等 `win_vld`；收到后发**一次** `start` 的许可 |
| `S_DW` ×3 | 3 × 10 = **30** | `t0`：`op=1`/`wdata_en=1`/`start=1` **同拍**；`t0+1..t0+9` 逐拍喂 `w_dw[ch*9+t]`；**`t0+10` 抓 100 个 `peo`** → `dwc[ch][0:99]`。窗口装载（36 拍）与这里重叠 |
| `S_PW` ×8 | 8 × 4 = **32** | 每个 oc：清 `pacc` → 3 拍流式喂 `(a=dwc[cin][p], b=w_pw[oc*3+cin])` → 第 4 拍量化 `(pacc+128)>>>8` clamp 0..255 |
| `S_POOL` ×8 | 8 × 2 = **16** | 25 棵比较树两级流水，第 2 拍出 5×5 |
| `S_WR` | **40** | 8 oc × 5 行，每行 5 B = 1 unit 写 plane |
| **合计** | **≈ 118** | 768 tile × 118 ≈ 90.6k 拍 ≈ **0.45 ms @200MHz** |

### 3.2 我对硬约束 2 的理解（请确认）

> "每 tile 拍数 = `CIN*9 + CIN*COUT` = 3×9 + 3×8 = **51**"

我理解 **51 是 PE 阵列的"发 MAC 拍数预算"**：`CIN*9`=27 拍做 dw（每拍一个 tap），`CIN*COUT`=24 拍做 pw
（每拍一组 `(a,b)`），要求这 51 个 MAC 槽位**一个气泡都不许有**（全流水）。
而上面 118 拍是**整个 tile 的墙钟拍数**，多出来的 67 拍是窗口装载/量化/池化的开销，
这些开销要与 MAC 重叠（`PROJECT_PATH.md` §7.1 也是这么写的）。
→ **如果 51 是"整 tile 不许超过 51 拍"，那本方案不成立**，请明确。

### 3.3 pw 为什么要外部累加（F6 的直接后果）

直接相乘模式下 `pe.v` 的 `acc_en = op_reg[2] && !lao_reg[1] = 0` → `acc <= dsp_o`，**PE 不累加**。
所以 `conv_l1` 必须自己维护 `pacc[0:99]`（signed 24 bit，100 × 24 = 2,400 FF）在阵列外做 3 次累加。
（这是 `DESIGN.md` §5.2 里那 5,000 FF 的主要来源，属预期开销。）

---

## 4. 验证计划（分层，先 tb 后 RTL）

| 层 | tb | 验什么 | 判据 |
|---|---|---|---|
| V0 | `rtl/pe10_10/tb_pe_rules.v` ✅**已完成** | PE 阵列使用规则 + 抓数拍 | 7/7 PASS，**`t0+10` 抓数** |
| V1 | `tb_pool.v` | 25 棵池化树：随机 / 全 0 / 全 255 / 全同值 / 边界位置 | mismatch = 0，且**恰好 2 拍**流水 |
| V2 | `tb_band.v` | 3 端口并写 → 读回逐字节；slot 环回绕；addr 384/512 边界 | 每行 192 unit 全对 |
| V3 | `tb_plane.v` | 写满 30,720 unit → 读回；bank 0↔5、seg 0↔9 边界 | 逐 unit 全对 |
| V4 | `tb_win.v` | 已知 band 内容 → 12×12 逐字节；**四角 + 四边 tile** 的反射 | 3 通道 × 144 B 全对 |
| V5 | `tb_dma.v` | DDR 图案 → band：`u = slot*192+ch*64+k`，16B→15B 重对齐 | 整行 192 unit 全对 + 240 行不丢 |
| V6 | `tb_l1_dw.v` | 只跑 dw，权重 1..9，真实窗口 | `dwc[ch][0:99]` = `(Σ+128)>>8` clamp，3 通道全对 |
| V7 | `tb_l1_pw.v` | 写死 `dwc`，只跑 pw | 8 oc × 100 点 = `Σ_cin dwc*w_pw` 全对 |
| V8 | `tb_l1.v` | `conv_l1` 整片，小图 `80×40×3` → 1 个 tile 的 5×5×8 | mismatch = 0 且跑到 `done` |
| V9 | `tb_top_small.v` | 端到端 `80×40×3 → 40×20×8`（32 tile） | 全帧逐点对 + `done` |
| V10 | `tb_top_full.v` | 整帧 `320×240×3 → 160×120×8` | 抽样对 + `done` + 打印总拍数 |

**统一约定**
- 小图一律 `80×40×3 → 40×20×8`（tile 仍 10×10，8×4 = 32 tile），布局关系与整帧完全一致
- 黄金模型用 SystemVerilog 写在 tb 里（DDR 图案用可复现公式，如 `(r*13+c*7+ch*29)%251`）
- 失败时 tb 直接打印"第几拍 / 哪个 lane / got vs exp"，**不看波形猜**
- tb 超时统一 `#300000`，并每 1000 拍打印 `tile_r/tile_c/各 FSM 状态` 便于定位

---

## 5. 实施顺序与里程碑（≈6 天）

| 里程碑 | 内容 | 验收 | 估时 |
|---|---|---|---|
| **M0 清场** | 删 `conv_pool_tree.v`、3 份损坏副本；重写 `filelist.f`；冻结接口契约 | `vlog` 0 error，`tb_pe_rules` 仍 PASS | 0.5 天 |
| **M1 存储层** | `conv_mem_unit` + `conv_band12` + `conv_plane` + V2/V3 | 逐 unit 全对 | 1 天 |
| **M2 窗口** | `conv_win_load` + V4 | 反射逐字节对 | 0.5 天 |
| **M3 输入 DMA** | `conv_in_dma` + V5（含 16B→15B 重对齐、slot 环、`rows_free`） | 整行 unit 对 | 0.5 天 |
| **M4 dw 相位** | `conv_l1` 的 dw 部分（含 `feature_map_12_12` 驱动、`t0+10` 抓数）+ V6 | 3 通道 dwc 对 | 1 天 |
| **M5 pw+量化+池化+写回** | `conv_l1` 补全（外部 `pacc`）+ V7/V8 | 8 oc × 5×5 对 | 1 天 |
| **M6 顶层集成** | `conv_top` 重写（tile 调度/握手/`rows_free`/`done`）+ V9 | 小图端到端全对 | 1 天 |
| **M7 整帧与资源** | V10 + Efinity 综合看片数/时序 | 132 片、`done`、抽样对 | 0.5 天 |

**每一步的红线**：tb 不 PASS 就不往下走，**不允许"改 RTL → 看波形 → 再改"**。

---

## 6. 已知风险

| # | 风险 | 缓解 |
|---|---|---|
| R1 | `ch` 被 `conv_top` 和 `conv_l1` 重复计数 → 握手错拍（`PROJECT_BRIEF.md` §5 的头号怀疑对象） | **单一职责**：`conv_top` 只维护 `tile_r/tile_c`；通道由 `conv_l1` 独占，`conv_win_load` 从 `conv_l1` 取 `ch`（踩坑 #10 的教训） |
| R2 | `rows_free` 接常量 → DMA 冲掉环（`PROJECT_BRIEF.md` §5 第 2 条） | M3 就做真握手：L1 消费完 32 个 tile（10 行）才放行，配 SVA 断言"未消费不得覆盖" |
| R3 | `wl_start` 单拍脉冲 vs `win_req` 电平不匹配，第二次以后等不到 `win_vld` | 握手统一成**单拍 req / 单拍 ack 脉冲**（踩坑 #7），V4 里专门测"连续 3 个 tile 都拿到窗口" |
| R4 | 拍数对不齐（抓数拍早/晚 1~2 拍） | 已在 **V0 用独立 tb 量出来 = `t0+10`**，写死不再猜 |
| R5 | 36 bit `PE_output` 截断 | 8bit 数据下 ≤2^19，**安全**；但会在 V8 加一条"最大值/负值"用例守住 |
| R6 | 3 个写端口并发写同一 bank 冲突 | band 写口固定写 `u, u+1, u+2`（**bank 必不同**），用 generate 断言 `bank(u)!=bank(u+1)!=bank(u+2)` |

---

## 7. 需要你拍板的 7 件事

| # | 问题 | 我的建议 |
|---|---|---|
| Q1 | band 到底 **3 bank × 2 段**（`MEM_PLAN_V4`）还是 **6 bank × 1 段**（`PROJECT_PATH` §5.4 + `conv_top.v` 端口）？片数都是 12 | **6 bank × 1 段**，去掉 seg |
| Q2 | §3.2 的"51 拍"是**PE 发 MAC 预算**还是**整 tile 墙钟上限**？ | 按"PE 预算"做（整 tile ≈118 拍） |
| Q3 | `PROJECT_PATH.md` §8 第 1 步写"第 10 拍 `peo[0]=198`"，我实测正确值在 `t0+10`（`§7.2` 也是 `t0+10`）。以哪个为准？ | 以**实测 `t0+10`** 为准 |
| Q4 | 权重来源：顶层端口 `w_dw[0:26]`/`w_pw[0:23]`（照现 `conv_top.v`），还是片上 ROM / 运行时寄存器？ | 先照现端口，方便 tb 直接喂 |
| Q5 | 本轮是否**只做 L1**（到 160×120×8），L2/L3 不做？ | 只做 L1，但 `conv_plane` 按 120 片留好原地复用空间 |
| Q6 | 使用规则里"直接相乘放在**左上的 16×6 区域**"——本阵列是 10×10，`load_a_in[i]=feature_map[(i/10)*12+i%10]` 实际取的是**左上 10×10** | 按 **10×10** 做（"16×6"应是别的阵列尺寸的说法） |
| Q7 | `DDR 读突发`：一行 960 B = 60 beat，一次发起整行，还是分 2~3 块？ | 一次整行（60 beat），简单且余量大 |

---

## 附：我**不会**做的事

- ❌ 不参考 `_user_originals_backup/ai_rewritten/` 下的任何 RTL
- ❌ 不改 `rtl/pe/pe.v`、`rtl/pe10_10/pe_10_10.v`、`rtl/pe10_10/feature_map_12_12.v`、`rtl/dsp48/efx_dsp48.v`、`ip/bram_10kb/*`
- ❌ 不用 PowerShell `Set-Content`/`Add-Content` 写这些文件
- ❌ 不在 tb 没 PASS 的情况下继续往下写
