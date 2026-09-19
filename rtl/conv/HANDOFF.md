# conv10_10 工程交接（复制给新会话用）

> **一键切换用**：把下面 `====` 之间的内容整段复制给新会话即可。

```
=====================================================================
【工程】D:\my_code\fpga\yilisi\conv10_10  （Efinity，器件 Ti60F225）
【目标】输入 = DDR 里【已池化好的 320×240×3 RGB888】，
        输出 = 160×120×8（L1: dw3×3 + pw1×1 + 量化，与 2×2 max 池化融合）
【硬约束】
  ① 池化 4 输入 8bit 比较树、两级流水、5×5=25 棵
  ② PE 阵列全流水；tile 拍数 = CIN*9 + CIN*COUT
  ③ PE 用用户自己的 rtl/pe/pe.v + rtl/pe10_10/pe_10_10.v（18bit 不动）
  ④ 一文件一模块
  ⑤ DDR 布局 row*960 + {R,G,B}；片型只用 ip/bram_10kb（SDP 512×20）
  ⑥ 【禁止】用 PowerShell Set-Content/Add-Content 改这些文件（会写成 ANSI，
     中文注释变乱码、Verilog 语法崩坏）
【必读】rtl/conv/PROJECT_PATH.md（唯一权威文档：目标+契约+已验证时序+实现路径+踩坑）
【权威接口】rtl/pe10_10/pe_10_10_tb.v 里的注释就是 PE 阵列的接口契约
【当前状态】从头重写。rtl/conv 里只剩用户原有文件；
            AI 之前写的 RTL 全部作废，收在 _user_originals_backup/ai_rewritten/
【下一步】按 PROJECT_PATH.md 第八节的第 1 步开始（先写 tb、拿到期望值，再写 RTL）
=====================================================================
```

---

## 目录现状

```
conv10_10/
├── rtl/conv/PROJECT_PATH.md     ★ 唯一权威文档（先读这个）
├── rtl/conv/PROJECT_BRIEF.md    旧的交接说明（历史，可参考）
├── rtl/conv/                    只保留用户原有文件：
│     conv_cmp4_tree.v  conv_pool_arr.v  conv_pool_tree.v
│     conv_top.v  conv_tb.v  conv_pe.v  conv_pe_tb.v
│     conv_pe_10_10.v  conv_feature_map.v
│     filelist.f  run.bat  sim_conv.do
│     DESIGN.md  BRAM_PLAN.md  BRAM_VERIFY.md
│     MEM_PLAN_V4.md  MEM_REUSE_PLAN.md  STORAGE_V3.md
├── rtl/pe/pe.v                  ★ 用户原始，不要动
├── rtl/pe10_10/pe_10_10.v       ★ 用户原始，不要动
├── rtl/pe10_10/feature_map_12_12.v ★ 用户原始，不要动
├── rtl/pe10_10/pe_10_10_tb.v    ★ 接口契约权威来源
├── rtl/dsp48/efx_dsp48.v        DSP48 原语
├── ip/bram_10kb/bram_10kb.v     BRAM 片型
└── _user_originals_backup/      用户原始文件备份 + AI 作废的 RTL
```

## 三条最重要的"别踩"

1. **`start` 一次复用卷积只能发一次**，`op` 全程不拉低 —— 这是用户的接口契约。
2. **`feature_map_12_12` 的 `start_reg` 移位会周期性触发 autoload**，
   `load_a_in_opt` 脉冲会重装 PE 的 `input_reg_a[0]`、**把累加器清零**。
   症状：`peo` 出现 4 拍循环。详见 `PROJECT_PATH.md` 第 4.5 节。
3. **先写 tb 拿期望值，再写 RTL**。不要"改 RTL → 看波形 → 再改"。
