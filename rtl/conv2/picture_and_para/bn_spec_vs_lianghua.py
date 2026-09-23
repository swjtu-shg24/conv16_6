# -*- coding: utf-8 -*-
"""bn_spec_vs_lianghua.py —— 对比 lianghua_infer.py 的 BN 口径 vs 工程口径（stim_model.py / RTL）

回答的问题："为什么 lianghua_infer.py 生成的归一化结果和仿真里看到的不一样？"

做三件事（全部用同一张 test.jpg，工程库 stim_model 当裁判）：
  1. 打印两边的归一化参数：工程 A_q=round(scale*256)/B_q=round(shift*4096)
     vs 脚本 round(a*256)/(round(b*256)*16)，逐通道对比差异；
  2. 逐点对比 bnq（BN 之后、池化之前 160×120×8）：分别只换"舍入"、只换"a/b"、
     以及脚本完整口径 vs 工程口径，给出不同点数 / max|Δ|；
  3. 同样对比池化输出 out，看误差往下游传成什么样。

调用（工程根目录）：
    python rtl\\conv2\\picture_and_para\\bn_spec_vs_lianghua.py

结论（实测，对 test.jpg）：A_q/B_q **8/8 通道都不同**（ch0 4241 vs 3917、ch1 4678 vs 4077），
bnq **19.5%** 的点不同（max 6 LSB；只换 a/b 时 max 7 LSB），池化输出 **23.7%** 的点不同
（只换舍入这一项就占 27.7% 点差 1 LSB）。原因见 README 坑表 #49：
  ① 脚本的 μ/σ 统计的是**量化后**的激活（权重 Q8.8 + 激活 Q4.4 + (acc+128)>>8 全做完），
     工程口径统计的是**浮点** pw 输出（float_ref 的 pwf）；
  ② 脚本 BN 恒用 (acc+128)>>8 四舍五入，工程口径/RTL 默认 >>8 截断（BN_ROUND=0）；
  ③ 脚本先把 γ/β 量化到 Q8.8 再算 a/b，工程口径先用未量化 γ/β 算 scale/shift、最后才 round；
  ④ 脚本每图实时算，RTL 的 bn_a/bn_b 是 wrom.hex 里对 test.jpg 固化的 ROM 值。
"""
import os, sys
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import stim_model as M

img = M.load_image()
W   = M.load_weights()

# ---------- 工程口径（唯一口径来源）----------
#   ★ L1 的 ROM 参数就是 gen_stim.py 里这么算的：
#       M.float_ref(img, W, bn_relu=M.BN_RELU)     ← input_mode 默认 "float"，
#       即"真网络输入 2p/255-1 → 浮点 dw → 浮点 pw → 按 H×W 逐通道 μ/σ"
ref = M.float_ref(img, W, bn_relu=M.BN_RELU)     # μ/σ 来自**浮点** pwf（真网络输入）
a_q_spec, b_q_spec = ref["a_q"], ref["b_q"]     # A_q=round(scale*256), B_q=round(shift*4096)
st_spec = M.stages(img, W, ab=(a_q_spec, b_q_spec), bn_round=False)   # RTL: BN_ROUND=0
qq = st_spec["qq"]                              # Q4.4 整数码（RTL 里就是 qq）
assert (np.asarray(st_spec["a_q"]) == np.asarray(a_q_spec)).all()
assert (np.asarray(st_spec["b_q"]) == np.asarray(b_q_spec)).all()

# ---------- 脚本口径（lianghua_infer.FixedBatchNorm2d）----------
g = W["gamma"]; b = W["beta"]
# 脚本: gamma/beta 先量化到 Q8.8 再还原成浮点用
g_q = np.round(g * 256.0) / 256.0
b_q = np.round(b * 256.0) / 256.0
x = qq.astype(np.float64) / 16.0               # 脚本的 x_float：**已经量化过**的激活
mean = x.mean(axis=(0, 1))                     # 脚本: dims (0,2,3) → 本脚本是 HWC
var  = x.var(axis=(0, 1))
a_s = g_q / np.sqrt(var + M.BN_EPS)
b_s = b_q - mean * a_s
a_s_int = np.round(a_s * 256.0).astype(np.int64)
b_s_int = np.round(b_s * 256.0).astype(np.int64)
b_s_q16 = b_s_int * 16                          # 脚本 acc = x*a_int + b_int*16

st_scr = M.stages(img, W, ab=(a_s_int, b_s_q16), bn_round=True)       # 脚本恒 (x+128)>>8
st_rnd = M.stages(img, W, ab=(a_q_spec, b_q_spec), bn_round=True)     # 只换舍入
st_ab  = M.stages(img, W, ab=(a_s_int, b_s_q16), bn_round=False)      # 只换 a/b

def diff(A, B, name):
    d = np.abs(A.astype(np.int64) - B.astype(np.int64))
    print("  %-34s 不同点数 %7d / %7d (%.2f%%)  max|Δ|=%d  mean|Δ|=%.4f"
          % (name, int((d > 0).sum()), d.size, 100.0 * (d > 0).mean(), d.max(), d.mean()))

print("=" * 100)
print("1) 归一化参数（前 8 通道；A_q=round(scale*256)，B_q=round(shift*4096)）")
print("   ch |   工程 A_q |  脚本 A_q | ΔA |   工程 B_q |  脚本 B_q*16 | ΔB")
for c in range(8):
    print("   %2d | %10d | %9d | %3d | %10d | %12d | %4d"
          % (c, a_q_spec[c], a_s_int[c], a_s_int[c] - a_q_spec[c],
             b_q_spec[c], b_s_q16[c], b_s_q16[c] - b_q_spec[c]))
print("   A_q 不同的通道数: %d/8   B_q 不同的通道数: %d/8"
      % (int((a_s_int != a_q_spec).sum()), int((b_s_q16 != b_q_spec).sum())))

print("=" * 100)
print("2) bnq（BN 之后、池化之前，160×120×8 = 153600 点）逐点对比")
diff(st_rnd["bnq"], st_spec["bnq"], "只换舍入(截断 -> +128 四舍五入)")
diff(st_ab["bnq"],  st_spec["bnq"], "只换 a/b(浮点μσ -> 量化后μσ)")
diff(st_scr["bnq"], st_spec["bnq"], "脚本完整口径 vs 工程口径")

print("=" * 100)
print("3) 再往下游传：池化输出 out（80×60×8 = 38400 点）")
diff(st_rnd["out"], st_spec["out"], "只换舍入")
diff(st_ab["out"],  st_spec["out"], "只换 a/b")
diff(st_scr["out"], st_spec["out"], "脚本完整口径 vs 工程口径")

print("=" * 100)
print("4) 工程口径的 scale/shift 与脚本口径的 a/b（浮点，前 3 通道）")
for c in range(3):
    print("   ch%d: 工程 scale=%.6f shift=%+.6f | 脚本 a=%.6f b=%+.6f"
          % (c, ref["scale"][c], ref["shift"][c], a_s[c], b_s[c]))
