# conv2 —— conv10_10 L1 前端（重写版）

> 目标：DDR 里**已池化好的 320×240×3 RGB888** → L1(`dw3×3` + `pw1×1` + 量化 + **BatchNorm2d** + `2×2 max` 池化融合) → **160×120×8**
> 器件 Ti60F225，片型只用 `ip/bram_10kb`（SDP 512×20），PE 用你原来的 `rtl/pe/pe.v` + `rtl/pe10_10/pe_10_10.v`。
> **对 PE 只加了一个默认关闭的参数** `C_BIAS_EN`（0 = 老行为，逐位不变；1 = 把 `c_in` 加到 DSP 的 C 端口，
> 给 BatchNorm 的 `+b` 用）—— 见 `rtl/pe/pe.v` / `rtl/pe10_10/pe_10_10.v` 和 `tb_pe_cbias`，其余一行没改。
>
> **BatchNorm2d**：`y = (bn_a*x + bn_b) >>> 8`（Q8 定点，clamp 0..255），插在 pw 量化出的 10×10 之后、2×2 max 之前。
> 参数现在是**端口** `bn_a[0:7]/bn_b[0:7]`（逐 oc，由 `conv_wrom` 给真实网络的 model.2）；
> 老 tb 仍传旧常数 384/2560，**逐位不变**。

---

## ★ 真实激励仿真（test.jpg + 真实权重 ROM）—— 后加的一层，先看这一节

> 目的：不再用"公式造"的假图假权重（`(r*13+c*7+ch*29)%251` / `w=(i%9)+1`），
> 而是把 **`picture_and_para/test.jpg`（真实图片）** + **`netG_B_epoch11.pth` 第一层权重** 灌进仿真，
> 并把逐级数据导成表格 `picture_and_para/feature_maps_real.xlsx`，方便一个个数字对着看。

### 定点口径（用户给定，全工程唯一口径）

| 项 | 口径 |
|---|---|
| 数据 | **Q4.4 有符号 8bit**：`q = (p - 124) >>> 3`（p = DDR 里的原图像素 0..255） |
| | 依据：训练 `x = 2p/255 - 1`，`q = round(x*16) = round(32p/255 - 16)`；255≈256 且四舍五入补偿 +4 |
| | 硬件实现 = **一个减法器 + 算术右移 3 位**（无除法/无查表）。例：p=78 → -46>>>3 = -6 = `0xFA` → -0.375（训练值 -0.388） |
| 权重 | **Q8**：`w_q = round(w*256)`，18bit 有符号 |
| BN | `A_q = round(scale*256)`、`B_q = round(shift*4096)`；`scale = gamma/sqrt(var+eps)`、`shift = beta - mean*scale` |
| | ★ `B_q` 额外 ×16：数据通路相对 Q4.4 有 16 倍增益，而 RTL 的再量化固定 `>>>8`（不这么编码 bias 就小 16 倍） |
| 表里所有数字 | 都是 **Q4.4 寄存器值**，实际值 = 数字 / 16 |
| 中间饱和 | **dw/pw：对称饱和 `[-128, 127]`**（真实网络在 dw/pw 处**没有**激活），负值保留 |
| | **BN：饱和 `[0, 127]`** = **ReLU + 上限饱和**（真实网络是 `BN → ReLU → MaxPool`） |
| | 对应 `conv_top` 的 `Q44_SAT=1` + `BN_RELU=1`；配套：pw 的 a 通路符号扩展、池化比较器改有符号 |
| | （实测整帧：dwc/qq/bnq 撞到边界的点 **0 个** —— 极少越界，这个饱和只是兜底） |
| 限位位置 | 统一放在 **PE 阵列输出**（`conv_top` 的 `PE_SAT=1`）：移位前一次饱和到 `[-32768, +32639]` |
| | ★ 量纲是 Q4.4 的 256 倍（Q12.8），所以界是 32768 量级而不是 8；**HI 必须留 128** 给 `(x+128)>>>8`，写成 32767 会溢出成 −128 |
| | ★ 与"三级各自限位"**逐位等价**：80 万点穷举 + 两遍整帧仿真（`-gPE_SAT_TB=0/1`）对同一份 golden 都 30720 unit 全对 |
| | ★ `pe.v: assign PE_output = acc;` 是**组合**的 → 这是**零拍**改动，`c=13 / pc=7 / pc=4` 三个抓数点都不用动 |

网络侧依据（`picture_and_para/cyclegna_mobilenet.py`）：
`ReflectionPad2d(1) → DepthwiseSeparableConv2d(3,8) → BatchNorm2d(8) → ReLU → MaxPool2d(2,2)`，
即 `model.1.depthwise.weight(3,1,3,3)` + `model.1.pointwise.weight(8,3,1,1)` + `model.2`；
网络在 dw 前就做了 ReflectionPad2d(1)，与 `conv_win_load` 的 reflect-101 **逐点等价**。

### 新增/改动的文件

| 文件 | 作用 |
|---|---|
| `picture_and_para/stim_model.py` | 定点模型（**口径的唯一来源**）：量化、逐级算术、浮点参考 |
| `picture_and_para/gen_stim.py` | 生成 `conv_wrom/wrom.hex`、`img_ddr.hex`、`golden_plane.hex`、`golden_tiles.txt` |
| `picture_and_para/make_table.py` | 用 RTL 抓的 `real_dump.txt` + golden 生成 `feature_maps_real.xlsx` |
| `conv_wrom/conv_wrom.v` | **权重 ROM**：67 个字 = 27 dw + 24 pw + 8 bn_a + 8 bn_b，`$readmemh` 初始化 |
| `conv_wrom/tb_wrom.v` | ROM 自检（并行口 + 地址口逐字校验） |
| `tb_top_real.v` | 真实激励端到端：整帧 + 3 个 tile 逐级抓数 + **30720 个 plane unit 全比对** |
| `run_real.do` | 跑法：全量编译 + `tb_top_real` |
| `conv_in_dma.v` | **+参数 `Q44_EN`**（默认 0 = 老行为）：字节级 `p → Q4.4` |
| `conv_l1.v` | **+参数 `DW_SIGNED`**（dw 窗口符号扩展）；**BN 参数改成逐 oc 数组**；**+参数 `Q44_SAT`**（dw/pw 对称饱和 ±8、pw/BN 的 a 通路符号扩展、池化接 `SIGNED_CMP`）；**+参数 `BN_RELU`**（BN 后接 ReLU → `[0,127]`）；**+参数 `PE_SAT`**（限位挪到 PE 输出） |
| `conv_cmp4_tree.v` | **+参数 `SIGNED_CMP`**（默认 0 = 无符号比较）：Q4.4 有符号数据必须置 1，否则 `0xFA`(-6) 会被当成 250 |
| `conv_pool_arr.v` | 同上，把 `SIGNED_CMP` 透传给 25 棵比较树 |
| `conv_top.v` | **+端口 `bn_a[0:7]/bn_b[0:7]`**，+参数 `Q44_EN/DW_SIGNED/Q44_SAT/BN_RELU/PE_SAT`（默认 0 → 老 tb 逐位不变） |
| `picture_and_para/fpga_l1_int_dump.py` | **整数运算**复刻 RTL 口径的**独立实现**（torch 卷积 + numpy 移位），导出 `py_l1_bnq.npy`/`py_l1_pool.npy` 供对拍 |
| `picture_and_para/compare_python.py` | 把任意来源的 Python 结果和 RTL 仿真逐点对拍（自动认形状/反量化并把差异定位到坐标） |
| `picture_and_para/check_weights.py` | 验证 `.pth` 解析与你的 `netG_B_epoch11_weights.xlsx` 逐个数字一致 |
| `picture_and_para/check_float_ref.py` | 用你的 `cyclegna_mobilenet.py` 建网装 `.pth`，验证本工程浮点参考逐点一致 |
| `picture_and_para/eval_lianghua.py` `eval_lianghua2.py` | 评估 `lianghua_infer.py` 各版本的口径与 RTL 的差距 |

### 验证链条（哪几环已经对过、哪一环还没）

| # | 这一环 | 怎么验的 | 结果 |
|---|---|---|---|
| ① | `.pth` 解析 vs **你的** `netG_B_epoch11_weights.xlsx` | `check_weights.py` | **一致**（dw/pw 最大差 5.6e-17，BN 的 a/b 差 1.2e-6 只是表格显示位数） |
| ② | 本工程浮点参考 vs **你的** `cyclegna_mobilenet.py` 官方前向 | `check_float_ref.py` | **一致**（dw 5.7e-8 / pw 7.0e-8 / BN 9.9e-7 / 池化 9.0e-7；state_dict 装载 0 缺 0 多） |
| ③ | **RTL 仿真** vs 本工程定点模型 | `tb_top_real` | **逐点一致**：整帧 30720 unit 全对 + 3 个 tile 的 dwc/pwsum/qq/bnq/pool 0 处不一致 |
| ④ | RTL vs **你的 Python 定点结果** | `fpga_l1_int_dump.py` + `compare_python.py` | ✅ **逐点一致**：0 / 153600 点不同，最大差 0 LSB（两条独立实现：torch 卷积 vs numpy 滑窗，互相也一致） |
| ⑤ | 限位放 PE 输出 vs 放三级量化里 | `tb_top_real` 跑 `-gPE_SAT_TB=0/1` | ✅ **逐位等价**：两遍对同一份 golden 都 30720 unit 全对（另有 80 万点穷举验证） |

①②③ 说明"参数没搞错、仿真算得对"，④ 说明"你的 Python 口径和 RTL 相同"，⑤ 说明"限位换位置不掉一位"。
你要拿自己的 Python 结果对拍，只要它走**整数运算 + 这套口径**（Q4.4 输入 / Q8 权重 /
`(Σ+128)>>8` 的 dw·pw / BN 用 `>>>8`（floor）+ ReLU / `A_q=round(scale*256)`、`B_q=round(shift*4096)` /
reflect-101 / 有符号池化），结果必然一致；

```bat
:: 你的结果是 Q4.4 整数（和 golden 同口径）
& 'D:\Users\Administrator\anaconda3\envs\cyclegan\python.exe' rtl\conv2\picture_and_para\compare_python.py 你的结果.npy
:: 你的结果是反量化后的实际值（|x| <= 8 的小数），加 --deq 自动 ×16
& 'D:\Users\Administrator\anaconda3\envs\cyclegan\python.exe' rtl\conv2\picture_and_para\compare_python.py 你的结果.npy --deq
```

形状随便：(120,160,8) / (8,120,160) / (160,120,8) / 拉平 153600 都能自动认；不一致会打印前 20 个坐标
（y,x,oc + 你的值/RTL 值/实际值）并写出 `feature_maps_vs_python.xlsx`，还会给出按 oc 的分布，
方便直接定位是哪一级口径不同。

### 跑法（三步，都要在**工程根目录**）

```bat
:: ① 生成激励（用你的 conda cyclegan 环境，里面有 torch/numpy/openpyxl/PIL）
& 'D:\Users\Administrator\anaconda3\envs\cyclegan\python.exe' rtl\conv2\picture_and_para\gen_stim.py
:: ② 真实激励仿真：整帧 320x240x3 -> 160x120x8（约 3.5 分钟）
vsim -c -do rtl/conv2/run_real.do
:: ③ 生成数据变化表
& 'D:\Users\Administrator\anaconda3\envs\cyclegan\python.exe' rtl\conv2\picture_and_para\make_table.py
```

### 表格内容（`feature_maps_real.xlsx`，17 个 sheet）

| sheet | 内容 |
|---|---|
| `Params` | 口径说明、tile 列表、**RTL vs Golden 逐级比对结果**、已知偏差 |
| `Weights` | 27 个 dw + 24 个 pw（Q8 整数 + 浮点），8 组 BN（A_q/B_q/scale/shift） |
| `IN_t{tr}_{tc}` | 3 通道：Q4.4 输入 10×10 + **12×12 反射窗口**（都带实际值 /16） |
| `DWC_t{tr}_{tc}` | 3 通道：**累加和**（量化前，十进制）→ **RTL dwc** → GOLD → 浮点×16 |
| `PW_t{tr}_{tc}` | 8 个 oc：**Σ dwc*w_pw** → RTL qq → GOLD → 浮点×16 |
| `BN_t{tr}_{tc}` | 8 个 oc：RTL bnq / 实际值 / GOLD / 浮点×16 |
| `OUT_t{tr}_{tc}` | 8 个 oc：**池化 5×5**（就是写回 plane 的值）/ 实际值 / GOLD / 浮点×16 |

抓的是 3 个 tile：**(0,0) 首个、(12,16) 最中间、(23,31) 最后一个**。
"浮点×16"= 同一位置跑浮点（`x=2p/255-1`，dw→pw→BN→ReLU）×16，**和 RTL 直接可比，差多少就是定点损失**。
RTL 与 Golden 不一致的点会**标红**。

### 实测结果

| 项 | 结果 |
|---|---|
| `tb_wrom` | **PASS**（67 字逐字校验） |
| `tb_top_real` 整帧 | **PASS**：`done` @ **118,943 拍**（768 tile，154 拍/tile，与老 tb 完全一致 → 时序与数据无关） |
| 整帧回读比对 | **30,720 个 plane unit 全对，失败 0**（不是抽样，是整帧逐字） |
| 3 个 tile 逐级 | **DWC/PWSUM/QQ/BNQ/POOL 全部与 golden 一致（0 处不一致）** |
| 限位位置等价性 | `PE_SAT=1` 与 `PE_SAT=0` 两遍都 **30720 unit 全对**（同一份 golden）→ **逐位等价** |
| **Python vs RTL** | `fpga_l1_int_dump.py` 的整数结果与 RTL 仿真 **0/153600 点不同，最大差 0 LSB** |
| 握手计数 | `win_req/wl_start/win_vld = 1560/2304/2304` ✓ 与整帧回归期望值一致 |
| 老 tb | `tb_l1`/`tb_top`/`tb_top_full`/`tb_board`/`tb_cmp4_tree`/`tb_pool`/`tb_sched` 全部 **PASS**、校验和 `eb131b12a5` 不变（新参数默认 0，逐位中性） |

数值分布（整帧 76800 点/通道，都是 Q4.4 寄存器值）：
| 级 | 范围 | 备注 |
|---|---|---|
| `dwc` | −8..7 | **只有 9.1% 为 0**（最早是 0..7、54.7% 为 0） |
| `qq` | −8..9 | **19.2% 为 0**（最早 0..5、69.8% 为 0），oc4/oc5 不再退化 |
| `bnq` | 0..48 | ReLU 之后非负，实际值 0..3.00 |
| 池化输出 | 0..48 | 实际值 0..3.00 |

> 上表是**实例归一化参数**（`gen_stim.py` 现在的默认口径）下的分布；切回 `--bn-running` 时 bnq/池化是 0..70。

> ★ **两次口径修正的来龙去脉**：
> ① 最早三级量化都 clamp 到 `0..255`，对 Q4.4 数据等于在 dw、pw 输出各插了一个 ReLU，
>    把一半特征图抹成 0（dw 输出本来就有正有负）→ 改成 **dw/pw 对称饱和 ±8**，负值保留；
> ② 但真实网络是 `dw+pw → BN → ReLU → pool`：dw/pw 处**没有**激活，**BN 之后才有 ReLU**。
>    所以 BN 的下限必须是 **0（ReLU）**、上限 127；这一步把池化输出从"37% 是负值"拉回全非负，
>    也让 RTL 与你的 Python（同样有 ReLU）口径一致 —— 实测两者在此之前池化只有 33.6% 相同。
> 表里的 `GOLD` 列就是同口径定点模型，`FLT×16` 列是浮点参考，方便直接对照你 Python 的数。

### 验收门禁：定点误差 = 0（一条命令）

> **设计要求**：RTL 仿真结果必须与**定点模型完全一致（定点误差 = 0）**；浮点误差不是硬性要求。
> 双击 `rtl\conv2\check_fixed_point.bat`（或工程根目录执行它）即可跑完整门禁，四步全过才打印
> `FIXED-POINT ERROR = 0 -- ALL CHECKS PASS`：

| 步 | 做什么 | 判据 |
|---|---|---|
| 0 | `gen_stim.py` 重生成激励 + golden（口径的唯一来源） | 正常退出 |
| 1 | `tb_top_real` 整帧 RTL 仿真 vs `golden_plane.hex` | `TB_TOP_REAL RESULT: PASS`、`30720 个 unit，失败 0` |
| 2 | `make_table.py` 比对 RTL 抓的逐级数据 vs `golden_tiles.txt` | `RTL vs Golden 不一致点数 = 0` |
| 3 | `fpga_l1_int_dump.py` **独立整数实现** vs RTL golden | `不一致点数 = 0 / 153600`、`MATCH` |

**当前实测**：四步全过，逐点 0 差异（最大 \|差\| = 0 LSB）。

> ⚠️ **注意"定点模型"指哪一份**：本工程的口径基准是 `stim_model.py`（numpy 滑窗）+
> `fpga_l1_int_dump.py`（torch 卷积整数），**两者互相一致、也都与 RTL 逐点相同**。
> 而 `picture_and_para/lianghua_infer.py` 是**浮点模拟量化**（float 卷积 + `round()` + hook），
> 它不是整数定点：实测与 RTL 在 BN/池化上平均差 0.28 LSB、最大 24 LSB（BN 的 floor vs round
> 被 ×21.6 的 scale 放大），**不能拿它当"定点误差 = 0"的判据**。要让它也对齐，需要把它的
> 中间计算换成整数（`(Σ+128)>>8` / `>>>8` / `A_q=round(scale*256)`、`B_q=round(shift*4096)`）。

### 定点推理出图（`gen_fpga_image.py`，实例归一化）

> 用 RTL 的整数口径把 **L1** 算出来，其余层接浮点，最后出图肉眼对比。
> **归一化用实例归一化**：模型是 batch_size=1 训练的，BatchNorm 的 `running_mean/var`
> 就是最后一张训练图的统计量、本来就不对；bs=1 训练时 BN 干的事正是逐样本逐通道归一化
> = InstanceNorm，所以脚本把 26 个 `BatchNorm2d` 全换成 `InstanceNorm2d`（γ/β 照抄）。
> 产物在 `picture_and_para/fpga_images/`（含 `00_side_by_side.png` 拼图）。

| 变体 | max\|d\| | mean\|d\| | PSNR | 说明 |
|---|---|---|---|---|
| A 基线（全浮点） | — | — | — | 参考 |
| B 只量化输入 Q4.4 | 0.667 | 0.0388 | **31.24 dB** | 输入量化的代价 |
| C **L1 定点**（现状增益）+ 其余浮点 | 0.787 | 0.0983 | **23.78 dB** | 肉眼接近，略偏黄/对比略强 |
| E L1 定点 + **增益重分配**（dw 权重 ×8、A_q ÷8） | 0.637 | 0.0476 | **29.59 dB** | **几乎看不出差别** |
| D 全层定点（Q8.8 权重 + 每层激活 Q4.4，**IN**） | 0.894 | 0.109 | **23.02 dB** | ≈ C，全层量化并不比只 L1 差多少 |
| F 全层定点 + **BatchNorm(eval)** ＝ `lianghua_infer.py` 阶段2 | 1.073 | 0.137 | **20.74 dB** | 与它自己日志逐位一致 |

结论：
1. **L1 定点（现状增益）已经接近基线（23.8 dB）**；把 dw 权重 ×8、`A_q` ÷8（纯 ROM 数据改动）
   后到 **29.6 dB，肉眼基本无差别** —— 收益最大的一步。
2. 全层定点（D/F）与"只 L1 定点"（C）差不多（23.0 / 20.7 vs 23.8 dB），说明"每层都上 Q4.4"不是主要损失；
   **真正决定画面的是归一化用哪一套**：BatchNorm(eval) 与 InstanceNorm 的**浮点基线本身**就差
   `max|d|=0.957`（PSNR 21.26 dB），比定点化带来的差别还大。

> ★ 三个坑（都是写这个脚本时踩的，已修）：
> ① **实例统计量必须在实际值域里算**：`qq` 是 Q4.4 寄存器值（=16×实际值），直接 `qq.mean()/qq.var()`
>    会把 `scale=γ/σ` 算小 16 倍 → 出图只有 15.9 dB（看着像"定点毁了图"）。换算到实际值域后 23.8 dB。
>    **RTL/golden 那条链路没这个问题**（`stim_model` 的 scale/shift 本就是实际值域）。
> ② **权重量化的 clamp 要按实际值域**：`round(w*256)` 之后应 clamp 到 **±32768**（= 实际值 ±128）；
>    写成整数 ±128 会把所有 `|w|>0.5` 的权重削到 0.5（含 BN 的 γ≈1.06 → 0.5），图直接废掉
>    （这就是我一度报出"D = 16.05 dB、发灰"的原因，实际 23.02 dB）。
>    `lianghua_infer.py` 的 `quantize_q8_8` 是对的（clamp 实际值 ±128）。
> ③ 它的 hook 还挂在 `DepthwiseSeparableConv/Conv2d` **包装类**上（残差 `out = out + x` 在包装类里做），
>    所以残差相加那一步也量化；要复现它的数必须一起挂，而且 `importlib` 每次 exec 出的**类对象不同**，
>    `mod` 必须在 `load_net()` **之后**取，否则 `isinstance` 失败、hook 少挂。

### BN 再量化：截断 vs 四舍五入（`bn_round_test.py`）

`conv_top` 新增 `BN_ROUND`（默认 0）：0 = `x>>>8` 直接截断；1 = `(x+128)>>>8` 四舍五入。
实测（答案：**影响在噪声级，默认保持 0**）：

| 口径 | BN mean\|d\| | 池化 mean\|d\| | 实例归一化出图 |
|---|---|---|---|
| 截断 `x>>>8`（默认） | 1.7443 LSB | 1.9828 LSB | L1 误差 0.0847，最终图 **23.78 dB** |
| 四舍五入 `(x+128)>>>8` | 1.7408 LSB | 2.0028 LSB | L1 误差 0.0857，最终图 **24.15 dB** |

两边基本打平（定点误差略差 1%，图像略好 0.4 dB）。原因：**误差主项不是 BN 自己的舍入**
（只贡献约 0.04 LSB 的有符号偏差），而是 `qq` 的格点误差被 `scale`（3.4~23.4）放大。
`BN_ROUND=1` 的路径也跑过整帧验证（配 `gen_stim.py --bn-round` 的 golden）：**30720 unit 全对**，随时可开。

### ★ 目标与路线（先把整个网络跑通；实例归一化后续再进硬件）

> **归一化不做到硬件里**：μ/σ 由 **Python 按当前这张图算**（浮点 = 理论值），编成 `A_q/B_q`
> 灌进 ROM 交给 RTL —— RTL 里的 BN 算术本来就是"逐通道仿射"，**一行都不用改**，
> 效果上就等于用上了实例归一化。真正的在线统计（两遍扫描 / 除法 / 开方）留到**后面优化**时再做。
>
> 依据：模型是 `batch_size=1` 训练的，`netG.train()` 时 BN 干的事就是逐样本逐通道归一化。
> 实测（`check_inorm_equiv.py`）：`netG.train()` 与 `BatchNorm→InstanceNorm2d + eval()`
> **逐位相同**（整网 max|d| = 0.000e+00，dw/pw/BN 逐层也是 0）。

`gen_stim.py` 现在**默认就是实例口径**（`bn_mode="instance"`）：
μ/σ 在整幅 240×320 上逐通道算 → `scale = γ/σ`、`shift = β - μ·scale` → `A_q = round(scale*256)`、`B_q = round(shift*4096)`。
实测（test.jpg）：`σ = 0.057~0.268`、`A_q = 632~4073`（旧 running 口径是 `883~5978`）；加 `--bn-running` 可切回旧口径对比。

**为什么统计量必须按整幅算**（`inorm_granularity_test.py`，L1 全定点、其余浮点）：

| 统计粒度 | 硬件代价 | L1 mean\|d\| | 最终图 PSNR |
|---|---|---|---|
| **整幅 240×320（现在的做法：Python 离线算）** | 0 | 1.35 LSB | **23.78 dB** |
| 每个 tile 行 10×320 | 缓存 10 行 qq ≈20 片 BRAM | 6.16 LSB | 13.49 dB |
| 每个 tile 10×10 | tile 内 100 点缓冲 | 8.44 LSB（撞满量程） | 13.00 dB |

→ 以后真要在硬件里做实例归一化，也**必须整幅**（= 两遍扫描）；按行/按块会把图打到 13 dB。

**完整网络层次清单**（`MobileResnetGenerator(ngf=8, n_blocks=9)`，按 state_dict 的键解析）：

| 级 | 结构 | 空间尺寸 | 通道 | 状态 |
|---|---|---|---|---|
| L1 | `ReflectionPad2d(1) + dw3×3 + pw1×1 + 归一化 + ReLU + MaxPool2` | 320×240 → 160×120 | 3→8 | ✅ 已实现、定点误差 0 |
| L2 | `DSC(8→16) + MaxPool2`（dw3×3 → 归一化 → ReLU，pw1×1 → 归一化） | 160×120 → 80×60 | 8→16 | ⬜ |
| L3 | `DSC(16→32) + MaxPool2` | 80×60 → 40×30 | 16→32 | ⬜ |
| L4 | **9 × `DSC(32→32)` 残差块**（`out = out + x`） | 40×30 | 32→32 | ⬜ |
| L5 | `ConvTranspose2d(32→16) + 归一化 + ReLU` | → 80×60 | 32→16 | ⬜ |
| L6 | `ConvTranspose2d(16→8) + 归一化 + ReLU` | → 160×120 | 16→8 | ⬜ |
| L7 | `ConvTranspose2d(8→8) + 归一化 + ReLU` | → 320×240 | 8→8 | ⬜ |
| L8 | `ReflectionPad2d(3) + Conv2d(8→3, 7×7) + Tanh` | 320×240 | 8→3 | ⬜ |

**每一层都照 L1 的套路做**（这是保证"定点误差 = 0"的唯一办法）：
① 先定整数规格（数据/权重/归一化参数/饱和/舍入各在哪一步）→ ② Python 出整数 golden →
③ RTL 实现 → ④ `tb` 逐点对拍，不一致必须为 0。

**归一化参数怎么灌**：L1 现在是 8 组 `(A_q,B_q)` 写在 ROM 里。整网共 **26 个归一化层、688 组**
`(A_q,B_q)`（≈24.8 kbit ≈ 3 片 BRAM）—— Python 一次算好，硬件做个"参数寄存器组 / 小 BRAM"按层切换即可，是很小的一块。

### 定点误差：RTL 离"浮点理论值"有多远（`quant_error_report.py`）

> 先分清三个对照物：**Python 整数模型 vs RTL 仿真 = 0 LSB（逐点完全相同，见上面的门禁）**；
> 下面测的是 **RTL 定点链 vs 浮点理论值**，也就是"定点的代价"。单位 LSB = 1/16 = 0.0625 实际值。
> ★ 这一节是**参考信息**：设计要求只要求"与定点模型相同（误差 0）"，浮点误差不是硬性指标。

| 级 | 理论值范围（实际） | mean\|d\| | max\|d\| | RMS | 相对误差 | 相关系数 | 离理想 Q4.4 取整 |
|---|---|---|---|---|---|---|---|
| dw 输出 | −0.489..0.426 | 0.27 LSB | 0.98 LSB | 0.32 | 10.6% | 0.994 | **1.08 倍** |
| pw 输出 | −0.502..0.513 | 0.30 LSB | 1.45 LSB | 0.37 | 16.6% | 0.988 | 1.20 倍 |
| BN 输出(ReLU) | 0..4.907 | 1.74 LSB | 21.4 LSB | 3.17 | 19.0% | 0.963 | 12.4 倍 |
| **池化输出** | 0..4.907 | **1.98 LSB**（0.124） | **20.3 LSB**（1.27） | 3.45 | 18.5% | 0.963 | 12.7 倍 |

池化输出（160×120×8 = 153600 点）：平均绝对误差 **1.98 LSB = 0.124**，最大 **20.3 LSB = 1.27**，
95% 分位 8.0 LSB，**52.2% 的点 ≤ 1 LSB**，按理论动态范围算 PSNR **27.2 dB**；逐 oc 差别大（oc0/oc1 因 scale 21.6/23.4 误差最大，约 4.0/4.3 LSB；oc2/oc6 只有 0.73/0.78 LSB）。

**误差从哪来**：dw/pw 两级几乎就是理想取整（1.08 / 1.20 倍）→ **Q8 权重和整数舍入基本不花钱**；
大头是 BN 把 qq 的 ~0.3 LSB 格点误差乘上 `scale`（3.4~23.4）再输出。
而 `qq` 实际只用到 **±9**，Q4.4 量程是 ±127 —— **白白浪费了 3 bit 多**。

**可选的改进（只改 ROM 里的数，RTL 一行不动）** —— ★ **当前不需要**（设计要求只要"与定点模型一致"，
浮点误差不是硬指标），留在这里备查：把 dw 权重整体 ×8、`A_q` 同步 ÷8
（层的数学完全不变，浮点理论值不变，只是把增益从 BN 挪到 dw 前面），实测：

| 方案 | qq 范围 | 池化 mean\|d\| | 相对现状 |
|---|---|---|---|
| 现状 | −8..9 | 1.98 LSB | 100% |
| dw 权重 ×8、A_q ÷8 | −65..67 | **0.52 LSB** | **26%** |
| dw 权重 ×4、A_q ÷4（保守） | −33..34 | 0.65 LSB | 33% |
| pw 权重 ×8、A_q ÷8 | −65..69 | 0.99 LSB | 50% |
| dw ×8 且 pw ×8 | −128..127（饱和） | 2.16 LSB | 109% ← 过度放大反而变差 |

即：**池化误差可以从 1.98 LSB 降到 0.52 LSB（相对误差 18.5% → 4.9%），代价只是换一份 ROM 数据**。
注意 ×8 的余量是按 test.jpg 量的（worst case 理论上 dw 输出可到 ±20，换图要留神），保守一点用 ×4。


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

## PE 阵列的使用契约（由 `rtl/pe10_10/tb_pe_rules.v` 8/8 + `rtl/pe10_10/tb_pe_pw_stream.v` 钉死）

| # | 结论 |
|---|---|
| F1 | 复用卷积：`op=1`、`wdata_en=1`、`start=1` **同拍**（记该拍为 `t0`），正确的 3×3 加权和在 **`t0+10`** 出现，**只有这一拍干净** |
| F2 | `t0+10` 之后 `peo` 继续脏累加，必须只抓那一拍 |
| F3 | 窗口搬运顺序（对 PE(r,c)）= 光栅序：`win[r][c],win[r][c+1],win[r][c+2],win[r+1][c],…,win[r+2][c+2]` |
| F4 | **b 逐拍采样**：tap `m` 用的权重 = `load_b_in` 在第 `m` 拍被采样的值（即 `t0+m` 那一拍采） |
| F5 | 关闭阵列（`op=1` 不发 `start`）→ 100 个 `peo` 恒为 0 |
| F6 | 直接相乘（`op=0`）：`load_b_in` → `peo` = **3 拍**，1 拍 1 个乘积；**`acc_en_pw=0` 时不累加**（`acc <= dsp_o`，每拍被乘积装载） |
| F7 | `pe_10_10` 把 48bit `PE_output` 截成 36bit；本设计数据 8bit → ≤2^19，安全 |
| F8 | 直接相乘要**内部累加**：拉高 `acc_en_pw`。但 PE 里取的是 `acc_en_pw_reg[2] & acc_en_pw_reg[3]`（两级"与"，`acc_en_pw_reg` 是 `acc_en_pw&&!op` 的 4 级移位寄存器）→ 累加窗口比拉高窗口**后移 3 拍、少 1 拍**：拉高 N 拍只有 N-1 拍累加 |
| F9 | 要"把累加归零重来"：拉高 `acc_clr`（**延迟 3 拍**生效，判的是 `acc_clr_reg[2]`）→ 该拍 `acc <= dsp_o`，即把当前乘积当作本组第 1 项；`acc_clr` 优先级**高于** `acc_en`。于是 `acc_en_pw` 可以**全程拉高**，改用 `acc_clr` 分组：连续拉高 N 拍就一拍一个乘积累加 N-1 拍、**零空拍**（`tb_pe_pw_stream` 验的：两组各 8 项，和 = 836 / 900 与 `acc` 逐位吻合） |

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

### L1 pw / BatchNorm / 池化 / 写回的实测时序（同一个 tb 验的）

#### ① 先看一个 oc 自己的"格"（`pc` 相对该 oc 的起点，`pc=0..7`，**8 拍**）

| pc | 动作 |
|---|---|
| `0` | `fm_wdata_en<=1`、`pw_cin<=0` → **pc=1 载入 `dwc0`**（`pw_cin` 寄存后滞后一拍） |
| `1,2` | `fm_wdata_en<=1`、`pw_cin<=1,2` → **pc=2,3 载入 `dwc1`,`dwc2`** |
| `1..3` | `pe_lb <= w_pw[oc*3 + pc-1]` → lb 在 **pc=2,3,4** 分别是 `w_pw[oc*3+0..2]` |
| `1..3` | **`acc_en_pw=1`** —— 正好是"逐拍喂 `w_pw[oc*3+0..2]`"的那 3 拍 |
| `4` | `acc_en` 无效 → `acc` 被 `dsp_o` 装载成**第 1 个乘积**（顺带清掉上一个 oc 的残值） |
| `5,6` | PE 内部 `acc <= acc + dsp_o`（第 2、3 个乘积到达） |
| `7` | `qq <= quant(peo)` —— **`peo` 就是 p1+p2+p3**（阵列外不再有 `pacc`） |

推导依据（实测）：`peo(k) = A(k-2)*B(k-2)`，其中 `A(k)`（即 `input_reg_a[0]`）= `feature_map(k-1)` = **载入值(k-2)**，
`B(k)`（即 `input_reg_b`）= `load_b_in(k-1)`。所以 a 走 `wdata_en` 比 b 多一级流水，两者的"拍"必须错开。
更精确的、**BN 以后逐拍对齐用的**式子（`c_bn`、`bnq` 就是按它排的）：

```
dsp_o(t)  = fm_la(t-2) * pe_lb(t-2) + C(t)        ← C 是 DSP 的 C 端口（组合进加法器）
pe_out(t) = acc(t)                                 ← acc(组合输出)，acc 只在时钟沿更新
acc 在 acc_en=0 的拍被 dsp_o 装载，acc_en=1 的拍做 acc += dsp_o
```

**累加搬进 PE**（原来在阵列外做 `pacc[0:99]`）：`dsp_o` 上第 1/2/3 个乘积落在 **pc=4/5/6**，
所以只需要"pc=4 不累加、pc=5/6 累加"，反推 `acc_en_pw` 要在 **pc=1,2,3** 拉高（见 F8 的"后移 3 拍、少 1 拍"）。
结果是 pc=7 的 `peo` = p1+p2+p3。契约由 `tb_pe_rules` 的 **T7** 钉死。

#### ② BatchNorm2d 插进来以后：格从 5 拍变 8 拍

BN 的位置是 **pw 量化出的 10×10（`qq`）之后、2×2 max 池化之前**，算 `bnq = (bn_a*qq + bn_b) >>> 8`（clamp 0..255）。
实现上**不新增任何乘法器**：复用这 100 个 PE —— 把 `qq` 经 `fm_wdata_en` 装回 `feature_map` 的左上 10×10，
`b` 广播 `bn_a`，`bias` 走 DSP 的 **C 端口**（`pe` 的 `C_BIAS_EN=1` 时 `N_SEL="C"` 且 `W_SEL="X"` → `O = A*B + C`）。

因为是软件流水，BN 的 1 个乘积和 pw 的 3 个乘积**在同一个 DSP 上错开排**，每组（组号 g = 正在喂的 oc）8 拍：

| m | 喂 a（`fm_wdata_en`） | 喂 b（`pe_lb`） | DSP 的 C | 这一拍拿到什么 |
|---|---|---|---|---|
| `0` | **`qq`**（`bn_load=1`，来自上一组 m=7 写好的 `qq`） | — | 0 | — |
| `1` | `dwc0`（`pw_cin=0`） | **`bn_a`** | 0 | — |
| `2` | `dwc1` | `w0` | 0 | — |
| `3` | `dwc2` | `w1` | **`bn_b`** | — |
| `4` | — | `w2` | 0 | `pe_out(4) = qq*bn_a + bn_b` → **`bnq`**；同时 `dsp_o(4)=dwc0*w0` 被 acc 装载 |
| `5` | — | — | 0 | `dsp_o(5)=dwc1*w1` → `acc +=`；**`pl_en` 第 1 拍**（池化 oc-1） |
| `6` | — | — | 0 | `dsp_o(6)=dwc2*w2` → `acc +=`；**`pl_en` 第 2 拍** |
| `7` | — | — | 0 | `pe_out(7)` = p1+p2+p3 → **`qq`**；置起下一组的 `fm_wdata_en`/`bn_load`；装载写回基底 |

推导（把上面的式子代进去，**这就是为什么 m=0 载 qq、m=4 才抓 `bnq`**）：

* m=0 载 `qq` → `fm_la(1)=qq`；m=0 那拍给 `pe_lb` 赋 `bn_a` → `pe_lb(1)=bn_a`；m=3 给 `C=bn_b`
  → `dsp_o(3) = qq*bn_a + bn_b`；`acc_en(3)=0` ⇒ `acc(3) = dsp_o(3)`；`pe_out(4) = acc(3)` ✔
* m=1 载 `dwc0` → `fm_la(2)=dwc0`；m=1 那拍给 `pe_lb` 赋 `w0` → `pe_lb(2)=w0` → `dsp_o(4)=dwc0*w0` = p1 ✔
* m=2/3 同理给 `dsp_o(5)/dsp_o(6)` = p2/p3 ✔（**这三拍的 `C` 必须是 0**，所以 `c_bn` 只在 m=3 非零）
* m=4 的 `pe_out` 抓 `bnq`，而 m=4 同时是"acc 装载 p1"那一拍 —— 抓数读的是沿**之前**的值，
  装载发生在沿上，两者互不干扰（这正是流水能叠起来的地方）
* m=5,6 池化（连续两拍），池化结果 m=7 就绪 → **下一组的 m=0..4 正好读它写回**（写回的是 oc-2）

**流水化**：令 `oc` = 组号 g（正在"喂"的 oc）、`pc` = 组内位置 m，则

| m | 喂 oc（组号 g） | 算 oc-1 | 写回 oc-2 |
|---|---|---|---|
| 0 | 载 `qq`（**给 BN 的 a**）+ `bn_a` | BN 的 a/b 进流水 | row0 |
| 1 | 载 `dwc0` + `w0` + `acc_en_pw` | — | row1 |
| 2 | 载 `dwc1` + `w1` + `acc_en_pw` | — | row2 |
| 3 | 载 `dwc2` + `w2` + `acc_en_pw`、`C=bn_b` | — | row3 |
| 4 | `acc` 装载 p1 | `bnq <= BN(peo)` | row4 + 装载下一个写回基底 |
| 5 | — | `pl_en` 第 1 拍 | — |
| 6 | — | `pl_en` 第 2 拍 | — |
| 7 | 量化 → `qq`；置起下一组的 BN 载入 | — | — |

一个 oc 从"开始喂"到"写完"跨 3 组 = 24 拍，但**吞吐是 8 拍/oc**：`S_PW` = (COUT+2) × 8 = **80 拍**。

**为什么是 8 拍、不能再快**：
① plane 写口 1 unit/拍，一个 oc 要写 5 个 unit（5 行）⇒ 相邻 oc 的写回至少隔 5 拍（m=0..4）；
② 池化结果必须在写回**读完** `pl_dout` 之后才能覆盖它 ⇒ `pl_en` 只能排到 m=5,6；
③ BN 的 a 只能从 m=0 载（`qq` 要到上一组 m=7 沿才有效），于是 pw 的 3 个 a 被迫排到 m=1,2,3，
   乘积落在 `dsp_o` 的 m=4,5,6，量化落在 m=7。
⇒ m=0..7 全部占满，**8 拍就是这一版的硬下限**。8 oc × 5 unit = 40 unit 的写口占用率 = 61/80 = 76%。

实测（`tb_l1_time`）：`S_PW` **50 → 80 拍**，整个 tile **96 → 126 拍**（`S_WREQ`1 + `S_WWAIT`2 + `S_DW`42 + `S_PW`80 + `S_DONE`1），
`p2_wr_en` 仍是 40 次、`fm_wdata_en` 32 次、`win_req` 在 pw 相位仍是 **0 次**。
**代价换来的是数据变了** → 校验和从 `c2eaf2eaaf` 变成 `eb131b12a5`（`tb_board` 已按新值更新）。


### L1 dw 相位：窗口预取 + 握手去延迟

用**真实** `conv_top`（真 `win_load`）在 `tb_top` 里量出来的每 tile 开销：

| | 改前 | 改后 |
|---|---|---|
| `S_WREQ`（发 `win_req`） | 3 | **1**（只有 ch0 还走这条） |
| `S_WWAIT`（等 `win_vld`） | 54（18/窗口） | **24**（8/窗口） |
| `S_DW`（3×3 复用卷积） | 42 | 42 |
| `S_PW` | 50 | 50 |
| 合计 | 150 | **126 拍/tile** |

做法（两处，都在时序逻辑里，不碰存储/数据通路）：

1. **窗口预取**（`conv_l1`）：进 `S_DW` 后，在 **`c=1`** 发出下一个通道的 `win_req`，
   让"窗口装载（band 读口）"和"3×3 计算（PE）"重叠 —— 这两件事用的是完全不同的
   硬件，原来却完全串行（每通道白等 18 拍）。`wl_nxt_rdy` 记住预取窗口已到，
   下一通道直接进 `S_DW`，不再等。
   > ★ **为什么必须卡在 `c=1`**：`fm_wdata_en` 在 `c=0` 置起、`c=1` 有效，
   > `feature_map` 正是在 **`c=1` 那一拍的时钟沿**把 `win_d` 锁进去的。
   > 更早（比如在 `S_WWAIT` 那一拍）就发请求的话，`win_load` 回来的**新窗口会在
   > `c=1` 之前覆盖 `win_d`** → feature_map 锁到**下一个通道**的窗口（见踩坑 #24）。

2. **`wl_start` 组合化 + `win_load` 的 `S_DONE` 直接接下一窗口**：
   原来 `wl_start` 是寄存器，`win_req → wl_start` 固定 2 拍（pend 1 + 寄存 1），
   而且 `win_load` 跑完一个窗口时 `wl_start` 也只能等它回到 `S_IDLE` 才到。
   改成组合后，`win_load` 把 `busy` 在 **`S_RUN` 最后一拍**就落 0，于是它的
   `S_DONE`（同时在做 `wbuf → win_d` 转储）当拍就能看到 `start`，直接接着开
   下一个窗口，省掉一次 `S_IDLE`。

3. **ch0 跨 tile 预取**（`conv_sched` + `conv_l1`）：
   每个 tile 的第一个窗口（ch0）原本要"现要现等"约 14 拍，而这个 tile 的 pw 相位
   有 50 拍、`win_load` 完全空闲。所以在**本 tile 的 CIN 个窗口都装完之后**
   （此时 ch2 的窗口已锁进 `feature_map`、`win_d` 空出来了），趁 pw 把
   **下一个 tile 的 ch0** 窗口先装好、压在 `win_d` 里，下一个 tile 直接用。
   `conv_l1` 在 `S_IDLE` 看到 `ch0_rdy=1` 就跳过 `S_WREQ/S_WWAIT` 直接进 `S_DW`。
   只对"同一 tile 行的下一个 `tile_c`"做（行内 band 的行不变，数据一定还在）；
   跨 tile 行要等 DMA 补带，退回原来那条路。
   实测：32 个 tile 里 **28 个**吃到预取（4 个是行首），`S_WREQ` 16 → **4 拍**。

| | 改前 | 改后 |
|---|---|---|
| `S_WREQ` | 3 | **1** |
| `S_WWAIT`（等 `win_vld`） | 54（18/窗口） | **30**（10/窗口） |
| 小计（真实 `conv_top`） | 150 | **126** |

加上第 3 步之后（`tb_top`，32 tile）：`S_WREQ` **4**、`S_WWAIT` **320/32 = 10 拍/tile**、
`S_DW` 42、`S_PW` 50、`S_DONE` 1 → **174 拍/tile**（最初 221）。

**理论下限**：一个 12×12 窗口要读 12 行，每行 1 次 band 访问（行距 192 unit，没法合并），
band 读口 1 次/拍 ⇒ **12 拍/窗口**是硬下限（现测 `S_RUN` = 13 拍）。
3 通道 × 12 = **36 拍/tile** 是 dw 相位"窗口侧"的极限；再加上最后一个通道的结果
要 `start+13` 才出来（PE 契约），dw 相位极限约 **49~52 拍**。
要再压下去需要：`conv_win_load` 的 `S_RUN` 流式化（双缓冲 `wbuf`，让 12 次读背靠背、
去掉每窗口那 1 拍 `S_DONE`）＋ `conv_l1` 的 `S_DW` 改成 **9 拍节拍**
（`start` 间隔 9 拍、结果仍在 `start+13` 抓；这个节拍已由 `tb_pe_dw_stream` 在 `CAD=9` 下
用 4 次**不同窗口 + 不同权重**的卷积验证通过）。

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

### 全局仿真 + 波形（GUI，按数据流分组）

```bat
:: 整帧 320x240x3 -> 160x120x8（约 4~7 分钟，tb_top_full）
rtl\conv2\run_wave.bat

:: 小图 80x40x3 -> 40x20x8（约 30 秒，看波形更舒服，tb_top）
rtl\conv2\run_wave.bat small
```

`run_wave.bat` 只管编译 + 起 GUI，波形布局在 `rtl/conv2/wave_full.do`，
按**数据流顺序**分成 12 组（共 90 多个关键信号）：

| 组 | 内容 | 代表信号 |
|---|---|---|
| 0 | 全局 | `clk/rstn/start/done` + `u_top/tile_r`、`tile_c`、`u_sched/rcnt` |
| 1 | DDR 读激励（tb 假 DDR） | `rd_en/rd_addr/rd_valid/rd_data`、`lat/lat_addr/rcnt/rbusy` |
| 2 | `conv_in_dma` 字节重排 | `st/row/slot/limit/beat/bcnt/fill/e/uu/abuf`、`b_wr_*` |
| 3 | `conv_band12` | `b_wr_*` / `b_rd_*`（bank/addr/data） |
| 4 | `conv_win_load` 窗口装配 | `st/r/slot_q/slot_eff/rd_addr_w`、`row_base_q/u0_q/bank_q/addr_off_q/chr_q`、`win_d[0..2]` |
| 5 | dw 相位（3×3） | `st/ch/c`、`win_req/win_ch`、`fm_op/fm_start/fm_wdata_en`、`pe_lb[0]/pe_out[0]/dwc[*][0]` |
| 6 | pw 相位（1×1+量化+池化） | `oc/pc/pw_cin/acc_en_pw`、`pe_out[0]/qq[0]/pl_en/pool_q[0..2]/pool_vld/pool_oc` |
| 7 | 写回 plane | `u_l1/wbank/waddr/obank/oaddr`、`p2_wr_en/bank/addr/data` |
| 8 | 调度/握手 | `u_sched/started/l1_done_p/need_next/wl_pend/pend_row`、`rows_free/l1_start/l1_done/wl_busy` |
| 9 | 回读校验 | `p2_rd_en_r/p2_rd_bank_r/p2_rd_addr_r/p2_rd_data` |
| 10 | 结果总线 | `u_top/p2_rd_data`、`u_l1/done` |
| 11 | `run -all` | — |

两个坑（脚本里已处理）：

1. **`[ ]` 是 Tcl 的命令替换** —— `add wave u_wl/win_d[0]` 会报
   `invalid command name "0"`。调用点用 `{...}` 括住，并且 `proc w` 内部还要把
   `[`/`]` 转义（`uplevel`/`eval` 都是"拼成命令串再求值"）。
2. `add wave` 失败会**中断整个 do 宏** —— 所以每条都包在 `catch` 里，
   名字对不上只打印一行 `[wave-skip]`，后面的分组照常加。
   （验证方式：用小图跑一遍，日志里应当**一条 `[wave-skip]` 都没有**。）

产物：`rtl/conv2/wave.wlf`（波形）、`rtl/conv2/transcript_wave`（文字）。

### run.bat 的两个坑（12 个 bat 已统一重建：**纯 ASCII + CRLF**）

1. **LF 行尾 + UTF-8 中文 = cmd 解析错位**。`chcp 65001` 一改码页，`cmd.exe` 按字节偏移
   续读批处理文件就会落到行中间，把注释当命令执行 —— 现象就是一堆
   `'害' 不是内部或外部命令`、`'EM' …`、`'ve（文字记录）' …` 这种被切碎的片段。
   → 所有 `run.bat` 改成 **CRLF + 纯 ASCII 注释**（中文说明留在 README 和 `.do` 里；
   `.do` 是 ModelSim 的 Tcl 读的，UTF-8 没问题）。
2. **`vlog`/`vmap` 用裸名字调用会找不到 `modelsim.ini`**。它们靠 `argv[0]` 定位安装目录：
   走 PATH 的裸名字只会在**当前目录**找 ini（本机 `MODEL_TECH` 没设置、cwd 也没有 ini），
   直接报 `(vlog-7) Failed to open ini file "modelsim.ini"` / `(vmap-20) Cannot access…`。
   → bat 里统一用**全路径**调用 `D:\modeltech64_10.4\win64\{vsim,vlib,vmap,vlog}.exe`。
   （`run.do` 里嵌套的裸名 `vlib/vmap/vlog/vsim` 是没问题的：外层 vsim 会把
   `MODEL_TECH` 传给子进程。）**换 ModelSim 安装路径就改 bat 顶部那 4 行 `if exist`。**
3. 顺带修掉 `board\run.bat` 里 `cd /d %~dp0..\..\..\..`（多退了一级，会跑到工作区外面）。


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
| M5 | `conv_l1` 的 pw（累加在 **PE 内部**，用 `acc_en_pw`）+ 量化 + 池化 + 写回 | ✅ |
| M6 | `conv_sched` + `conv_top`（顶层写在本层，纯结构例化）+ 端到端 `tb_top` | ✅ |
| M7 | 整帧回归 320×240×3 → 160×120×8 + 资源/时序 | ⬜ 待写 |

### 自检结果（15 个 tb 全 PASS）

| 模块 | tb | 验什么 | 结果 |
|---|---|---|---|
| `conv_cmp4_tree` | `tb_cmp4_tree` | max 正确 + 两级流水延迟 + `en=0` 保持；随机/全0/全255/全同值/最大值轮转 | **PASS** |
| `conv_pool_arr` | `tb_pool` | 25 点逐点 = 2×2 max + 延迟 + `en=0` 保持；6 个用例 | **PASS** |
| `conv_mem_unit` | `tb_mem_unit` | SEG=1 的 512 slot 全写全读；SEG=4 的段隔离与 `{seg,a}` 解码；读延迟=1 | **PASS** |
| `conv_band12` | `tb_band` | 2304 unit 全写全读；非对齐起点 u=1..8（bank 5→0 回绕 + addr 进位）；读延迟=1 | **PASS** |
| `conv_win_load` | `tb_win` | 12×12 窗口逐字节；**2 个相位 × 32 个 tile_c × 3 通道 = 192 个窗口**，含上/下边界反射与左/右列反射 | **PASS** |
| `conv_in_dma` | `tb_dma` | 240 行 DDR→band 全搬；**16B→20B 字节重对齐**；`rows_free` 信用真能挡停生产者；前 11 行 + 末 12 行共 4608 个 unit 逐字节比对 | **PASS** |
| `conv_l1`（dw 专项） | `tb_l1_dw` | 9 个核位置单点置 1 定映射；扫 (权重偏移, 拍号) 定抓数拍；3 通道 × 100 PE 全量对拍 | **PASS** |
| `pe_10_10` 使用契约 | `tb_pe_rules` | PE 规则 8 项；**T7 = 直接相乘 + `acc_en_pw` 内部累加**（照 `conv_l1` 的 pw 相位驱动，pc=7 的 100 个 lane = `a0*w0+a1*w1+a2*w2`） | **PASS** |
| `pe_10_10` DSP C 端口 bias | `tb_pe_cbias` | **`O = A*B + C`**：`C_BIAS_EN=1` 的阵列必须拿到 `a*x+b`（5 组 a/x/b，含负 bias、饱和区），`C_BIAS_EN=0` 的阵列必须**完全忽略** `c_in`（逐位回归）；**钉死 `N_SEL="C"` 必须配 `W_SEL="X"`** | **PASS** |
| `pe_10_10` 流式累加 | `tb_pe_pw_stream` | **F9**：`acc_en_pw` 全程拉高 + `acc_clr` 分组 → 两组各 8 项**连续累加、零空拍**；`dsp_o` 逐拍 +1（每拍一个新乘积） | **PASS** |
| `pe_10_10` 3×3 背靠背 | `tb_pe_dw_stream` | 4 次复用卷积，**窗口与权重每次都不同**，`start` 间隔 **9 / 10 / 14** 拍 → 每次都在 `start+13` 处 100/100 全匹配（证明 dw 的"格"是 **9** 拍，不是 14） | **PASS** |
| `conv_l1`（整片） | `tb_l1` | dw → pw → 量化 → **BatchNorm2d** → **池化** → **写回**；8 oc × 5×5 池化结果 + plane 写口的 40 个 unit（地址 + 数据）全对 | **PASS** |
| `conv_sched` | `tb_sched` | tile 序列（r,c）逐拍核对；`l1_start`/`wl_start`/`rows_free` 次数；等带填满才起第一个 tile；`done` | **PASS** |
| `conv_plane` | `tb_plane` | 30,720 unit 全写全读；seg 0..9；读延迟=1 | **PASS** |
| **端到端** | `tb_top` | `conv_top` 小图 **80×40×3 → 40×20×8**（32 个 tile，所有地址/反射关系与整帧一致）；`done` 到达 + **1280 个 plane unit 逐字节对拍**（黄金含 BN） | **PASS** |

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
| 18 | **wire 用在声明之前 → vlog 当隐式 net，正式声明处报 `(vlog-2388) already declared`** | 新加的 `wire acc_en_pw` 一开始写在 `pe_10_10` 例化**之后**，例化里先引用了一次 → 必须先声明再用（`default_nettype none` 也能提前暴露） |
| 19 | **PE 的 `acc_en_pw` 不是"拉高即累加"** | PE 内部取的是 `acc_en_pw_reg[2] & acc_en_pw_reg[3]`（两级"与"），累加窗口比拉高窗口**后移 3 拍、少 1 拍**：拉高 N 拍只累加 N-1 拍。要累加 2 次（pc=5,6）就得拉高 3 拍（pc=1,2,3）。契约由 `tb_pe_rules` 的 **T7** 钉死 |
| 20 | **`qq` 是 8bit，把 `quant24` 删掉不是"不量化"，而是"低 8 位回绕"** | `qq[p] <= pe_out[p][23:0]` 实际只留 bit[7:0]（2295→247、-20→236），函数不再单调 → 池化取 max 失去意义。症状：`tb_l1`/`tb_top`/`tb_board` 全挂（校验和从 `c2eaf2eaaf` 变成 `1fca38fc76`），但 `tb_l1_dw` 照样 PASS（dw 路径没动）→ 一眼定位到 pw 输出那一级。要真去量化必须把 `qq` + 池化树（`conv_cmp4_tree`/`conv_pool_arr`）+ 写回通路一起加宽；或者利用 quant 的单调性把它**搬到池化之后**（`max∘quant ≡ quant∘max`，结果逐位等价，golden 不用改） |
| 21 | **PE 新增端口后忘了接，会让旧实例悬空成 `z`** | `acc_clr` 加进来后，`conv_l1`/`tb_pe_rules` 里没接的实例会悬空；`z` 在 `if` 里恰好当假所以"碰巧能跑"，但不能留着 —— 仿真给假值、综合给 0，两边语义不一致。新端口一律显式接（本工程 `conv_l1` 接 `1'b0`、`tb_pe_rules` 接 `acc_clr` 并置 0） |
| 22 | **"每拍一个 oc"看着很诱人，但 plane 写口才是 pw 的硬下限** | 一个 oc 要写 5 个 unit（5 行 = 5B），写口 1 unit/拍 ⇒ 相邻 oc 至少隔 5 拍。再快就得改 `conv_plane` 的写口宽度或 40bit/unit 的打包方式。所以流水化做到 **50 拍**（7×5 + 15 排空）就到头了，不是 24 拍 |
| 23 | **流水化时"谁在什么时候用 `pl_dout`"必须逐拍对齐，否则最后一行的写回被冲掉** | oc 的池化结果在它的 row0 写回那一拍才就绪，直到 row4 写完才允许被下一个 oc 的 `pl_en` 覆盖。本设计靠"oc-2 写回 5 拍 / 下一个池化 en 在 m=3,4"天然错开；但最后一组（`oc=COUT+1`，对应无效的 `oc-1=COUT`）必须把 `pl_en` 卡掉，否则会在 `COUT-1` 的 row4 写回当拍把 `pl_dout` 冲掉 |
| 24 | **dw 窗口预取发早了 → `feature_map` 锁到下一个通道的窗口** | `fm_wdata_en` 在 `c=0` 置起、**`c=1` 才有效**，`feature_map` 是在 **`c=1` 那一拍的时钟沿**采 `win_d` 的。所以预取请求**必须等到 `c=1`** 再发：更早发（比如 `S_WWAIT` 那一拍）时，`win_load` 回来的新窗口会在 `c=1` 之前就把 `win_d` 覆盖掉。症状：`tb_l1_dw` 直接 FAIL、`tb_l1` 的 pool 全错 |
| 25 | **把握手寄存改成组合，能一次省掉 2~3 拍，但要同时照顾"对端什么时候能接"** | `wl_start` 由寄存器改组合后，`win_req → wl_start` 从 2 拍变 0 拍；但要让 `win_load` 的 `S_DONE` 当拍就能接下一个窗口，它必须把 `busy` 在 **`S_RUN` 最后一拍**就落 0（否则 `wl_start` 的组合条件 `!wl_busy` 在 `S_DONE` 当拍不成立）。pend 计数也要改成"一进一出当拍不变"（`wl_start && win_req` 时 `wl_pend` 保持） |
| 26 | **预取请求要"发出当拍锁存目标坐标"，不能用组合从当前 tile 推** | 请求可能因为 `win_load` 忙而晚几拍才被收下，那时 `tile_r/tile_c` 可能已经翻到下一个 tile 了，组合推出来的 `nxt_r/nxt_c` 就指错 tile。`tb_sched` 的假 `conv_l1` 跑得快，正好把这个坑踩出来（真设计里 tile 很长所以侥幸没暴露） |
| 27 | **`wcnt` 要按"本 tile 已经覆盖了几个通道的窗口"计数** | ch0 是预取来的时候，`conv_l1` **不会再发 ch0 的 `win_req`**，`wcnt` 只数到 2、永远 `!= CIN` → 下一个 tile 不再预取 → 症状是"**预取完美地隔一个 tile 生效一次**"（`issue_pre` 16/32）。tile 起点要写 `wcnt <= ch0_rdy ? 1 : 0` |
| 28 | **行末 `tile_c` 先清 0、`tile_r` 后 +1 的"间隙"里会误判成同一行** | 跨 tile 行时 `tile_c` 在 `l1_done` 那拍就清 0，而 `tile_r` 要等 band 填够（`pend_row` 期间）才 +1。这段间隙里 `(tile_r, tile_c)` 看起来像 `(旧行, 0)`，`nxt_same_row` 误判为真 → 发出一次**指向错行**的预取，`ch0_rdy` 会指错窗口。`issue_pre` 必须加 `!pend_row` |
| 29 | **`wl_start` 只有一根，正常请求和预取同拍时必须让正常请求优先** | 否则正常 `win_req` 会被当成预取、丢掉一次服务（`tb_sched` 里表现为某些 tile 的 `wl_start` 次数变成 2 或 4）。做法：`wire wl_norm_go = ((wl_pend!=0)||win_req) && !wl_busy;`，`wl_start = wl_norm_go || (pre_req && !wl_busy);`，`pre_act = pre_req && !wl_busy && !wl_norm_go;`，并且**用 `pre_act`（而不是 `pre_req`）来判断分类** |
| 30 | **光把 `N_SEL` 改成 `"C"` 是拿不到 bias 的：`W_SEL="P"` 会把加法器整个绕过去** | `efx_dsp48.v` 里是 `assign W = (W_SEL=="P") ? P_a : W_p;` —— `W_SEL="P"` 时 `W = P_a`（乘法结果），`M+N` 被旁路，`c_in` 加了也看不见（实测 `b=1000` 只出来 `3`）。必须同时 `N_SEL="C"` **且** `W_SEL="X"`（原语里 `W_SEL` 只允许 `"P"`/`"X"`）。写 `"W"` 会被 `efx_dsp48.v` 判非法直接 `$finish`。`N_SEL="CONST0"` 时 `X = P_a + 0`，所以这个改动对老行为**逐位中性**（`tb_pe_cbias` 两组阵列对比验的） |
| 31 | **DSP 的 C 端口是"组合进加法器"的，所以 bias 和乘积在时序上并不自动对齐** | 实测 `dsp_o(t) = fm_la(t-2)*pe_lb(t-2) + C(t)`：C 必须在"`pe_out` 读到乘积的**前一拍**"给出。BN 里写成了 `c_bn` 只在 m=3（`pe_out(4)` 读 `dsp_o(3)`）非零；**m=4/5/6 必须是 0**，否则那三个乘积会被一起加上 bias。`tb_pe_cbias` 里 bias 是常数全程保持所以看不出来，逐拍对齐必须自己算 |
| 32 | **`bn_load` 多拉高一拍 = 把 pw 的第一个 a（`dwc0`）冲掉** | `fm_wdata` 的 mux 是 `bn_load ? qq : dwc[pw_cin]`，而 `bn_load` 是寄存器：在 m=7 置起、要**在 m=0 清掉**（不是 m=1）。m=1 才清的话，m=1 那一拍的 fm 载入也拿到 `qq`，于是 p1 变成 `qq*w0` 而不是 `dwc0*w0`（症状很隐蔽：`qq` 只是略微偏小，池化 max 之后大部分点还是一样，只有个别点差 1） |
| 33 | **BN 只在 `oc < COUT` 时置起 `bn_load`，第一组必须算进去** | `qq` 是"本组 m=7 沿"才写好的，BN 的 a 要到**下一组 m=0** 才能载入，所以 m=7 置 `bn_load` 的条件是**本组 oc < COUT**（g=0 也算）。原来写成 `oc>=1 && oc<=COUT`：g=0 不置起 → 第一组算 BN 时 `fm_la` 还是上一个 dw 窗口的残值（实测 `pe_out(4)=16768=384*37+2560` 而不是 `2944=384*1+2560`），池化结果全偏（`tb_l1` 报 `got 67 exp 11`） |
| 34 | **`ch0_rdy` 悬空成 `z` 会"碰巧能跑"，接成 `1` 反而错** | `tb_l1` 原来没接这个新端口（`z` 在 `if` 里当假 ⇒ 等价于 0，正好是 tb 想要的"不做跨 tile 预取"）。后来显式接 `1'b1` 时，`conv_l1` 以为 ch0 窗口已经预取好、**不再发 ch0 的 `win_req`** → 3 个通道只装到 2 个，个别池化点 `got 10 exp 11`。tb 里要显式接 **`1'b0`** |
| 35 | **别用 PowerShell 的 `Get-Content`/`Set-Content` 改这些源文件** | 源文件是 UTF-8（无 BOM），`Set-Content` 会按 ANSI 写回 → 中文注释全变成 `?`、行还会被并到一起（`tb_board.v` 被整片毁过一次，靠 `git checkout` 救回来）。改文件一律用编辑工具（保留编码） |

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
它同时点了 `pacc`（**现已随"累加搬进 PE"整体删除**）和 `feature_map`。已加显式属性绕开那条推断路径：

| 数组 | 文件 | 处理 |
|---|---|---|
| `dwc[0:2][0:99]` | `rtl/conv2/conv_l1/conv_l1.v`（我的文件） | 加 `(* syn_ramstyle = "registers" *)`；`pacc[0:99]` 已整体删除 |
| `feature_map[0:143]` | **用户原件不动**；另存一份 `rtl/conv2/conv_l1/feature_map_12_12_syn.v` | 只多一行属性，**模块名保持 `feature_map_12_12`**，综合 XML 指向这一份；**仿真仍用用户原件**（属性对仿真透明） |

> 若工具不认 `"registers"` 这个取值，换成 `"logic"` / `"distributed_ram"` 即可（只改这两个文件里的属性字符串）。

---

## 200 MHz 时序优化（第一轮）

约束：`rtl/conv2/board/conv_board.sdc` → `create_clock -period 5.0000`（200 MHz）。
`outflow/conv_board_inf.timing.rpt`（2026-09-20 01:34，含 win_load 优化）当时的结果：

```
Maximum possible analyzed clocks frequency : 5.118 ns / 195.389 MHz
Setup worst slack : -0.118 ns
```

**关键发现**：setup 最差的 10 条路径**全部**是
`u_top/u_plane/g_bank[*].u_mem/...|RCLK → led[1]~FF|D`（45 级逻辑、4.99 ns），
也就是**板级测试顶层的回读校验和**，不是卷积数据通路。
（`set_false_path -to [get_ports led[*]]` 只作用于**端口**，管不到驱动它的寄存器，
所以这条路照旧被报出来。）

| # | 改动 | 文件 | 效果 |
|---|---|---|---|
| 1 | `conv_win_load` 每 tile 常量预计算 + slot 计数器（**已含在上面那份报告里**） | `conv_win_load/conv_win_load.v` | 59 级 → 8 级 |
| 2 | **回写地址递推**：`oc` 每 +1 时 unit += 120×32 = 3840，而 `3840 % 6 == 0` ⇒ **bank 不变、addr 只 +640**；整块基底只在 `start` 那拍算一次并寄存 | `conv_l1/conv_l1.v` | 去掉回写路径上的 `*120`、`%6`、`/6` 组合链 |
| 3 | **校验和三级流水**：① 读数据寄一拍 ② 只做 40 bit 加法 ③ 比较按 5×8 bit 分片各自寄存再 AND | `board/conv_board_top.v` | 45 级 → 每级 2~3 级 |

> 改动 3 的坑：流水之后**最后一个 unit 会漏加**（第一次跑出来 `chk = c1e9f1eaaf`，
> 与 GOLDEN 差 `0x0101010000`，正好一个 unit）。原因是最后一拍数据在 FSM 离开
> `S_RD` 那一拍才出现，必须先"冲刷"两拍（`S_CMP` 收数、`S_CMP2` 再加）才能比较。
> 现在状态机是 `S_RUN → S_RD → S_CMP → S_CMP2 → S_CMP3(分片比较) → S_CMP4(汇总) → S_END`。

优化后回归：

| 项 | 结果 |
|---|---|
| `tb_l1` | **PASS** |
| `tb_board` | **PASS**，校验和 `eb131b12a5`（★ BN 插入后重取；BN 前是 `c2eaf2eaaf`） |
| `tb_top_full`（整帧 320×240×3→160×120×8） | **PASS**，抽样 320 个 plane unit **0 失败**，`win_req/wl_start/win_vld = 2304/2304/2304`，**118,943 拍**（BN 后；BN 前 95,903） |

**下一步**：用 `conv_board_inf.xml` 重新跑 PnR，把新的 timing report 发我 ——
这条校验和路径拆掉之后，才能看到真正的下一条关键路径（预计会落到
`conv_in_dma` 的字节重排 / `conv_l1` 的 100 路累加 上）。

---

## 板级验证（不接 DDR，内部自己造激励）

`rtl/conv2/board/` 里是**可综合**的板级顶层：

| 文件 | 说明 |
|---|---|
| `conv_board_top.v` | 板级顶层：内部假 DDR（`rd_en` → 4 拍延迟 → 1 beat/拍）+ 图案 `addr[7:0]^addr[15:8]^0x5A`；跑完从 plane 回读 1280 个 unit 算 40bit 校验和；`led[0]=done`、`led[1]=PASS`、`led[2]=FAIL`、`led[3]=busy` |
| `tb_board.v` | 仿真自检（就是上面的假 DDR + 校验和比对），已 **PASS**，校验和 = `eb131b12a5`（★ BN 插入后重取） |
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

- 跑到 `done`：**118,943 拍 ≈ 154 拍/tile ≈ 0.59 ms @200MHz**
  （四步优化的轨迹：**186,887** → 133,127（pw 软件流水）→ 113,159（dw 窗口预取）
   → 108,551（`wl_start` 组合化 + `win_load` 的 `S_DONE` 直连下一窗口）
   → 102,023（ch0 跨 tile 预取，但只对一半 tile 生效）→ **95,903**（修掉 `wcnt` 计数）
   → **118,943**（★ 插入 BatchNorm2d：pw 的"格"5 → 8 拍、`S_PW` 50 → 80 拍，**数据变了**
     所以校验和也必须跟着变。BN 复用了这 100 个 PE 和 DSP 的 C 端口，**没有增加任何乘法器/DSP**；
     一个 tile 的活动时间 118 → **155 拍**，其余是 23 个 tile 行边界等 DMA 补带 —— 见踩坑 #12）
- 抽样 8 个 tile（四角 + 四边 + 中间）逐字节比对 plane 的 **320 个 unit，全部 0 失败**（黄金含 BN）
- 窗口装载握手计数校验：`win_req = wl_start = win_vld = 2304`（= 768 tile × 3 通道），不多不少
- 片数实测：`band12` 12 片 + `plane` 120 片 = **132 / 256 = 51.6%**（`rtl/conv2/count_bram.do` 在仿真里数的）
  —— BN 是纯算术、不占存储，**片数不变**

> 速度参考：ModelSim 10.4 大约 **700~800 拍/秒**（100 个 DSP48 + 132 片 BRAM 行为模型）。
> `timescale` 由 1ps 改 1ns **不会变快**（tb 只有 ns 级事件，精度不影响事件数）；
> 真正的旋钮是去掉 `-voptargs=+acc`（它为了保留层次探针把优化关了）。
