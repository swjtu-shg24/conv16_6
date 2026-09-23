# -*- coding: utf-8 -*-
"""stim_model.py —— 真实激励的定点模型（**唯一口径来源**）

口径（用户给定，2026-09-22 确认）：
    · 数据：Q4.4 有符号 8bit
        训练时 x_norm = 2*p/255 - 1 ∈ [-1, 1]
        量化     q = round(x_norm * 16) = round(32p/255 - 16)
        硬件实现 q = (p - 124) >>> 3      （一个减法器 + 算术右移，255≈256）
        反量化   x = q / 16
    · 参数：Q8  w_q = round(w * 256)
    · BN  ：y = (A_q*x + B_q) >>> 8
        A_q = round(scale * 256)                （Q8，RTL 的 bn_a）
        B_q = round(shift * 4096)               （Q8 再 ×16：抵掉数据通路相对 Q4.4 的 16 倍增益）
        scale = gamma / sqrt(var + eps) ; shift = beta - mean * scale
    · RTL 逐级（conv_l1.v，不改）：
        dwc = clamp((Σ q*w_dw_q + 128) >>> 8, 0, 255)      ← 寄存器里是 Q4.4（= 16 × 实际值）
        qq  = clamp((Σ dwc*w_pw_q + 128) >>> 8, 0, 255)
        bnq = clamp((A_q*qq + B_q) >>> 8, 0, 255)
        out = 2×2 max(bnq)

本文件只依赖 numpy / torch / PIL（在 conda 的 cyclegan 环境里跑）。
"""
import os
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
PTH = os.path.join(HERE, "netG_B_epoch11.pth")
JPG = os.path.join(HERE, "test.jpg")

IW, IH = 320, 240
ROWB = IW * 3
NBEAT = ROWB // 16               # 60
NTILE_R, NTILE_C = 24, 32
TILE_IN = 10
TILE_OUT = 5
BN_EPS = 1e-5

# 表格/仿真覆盖的 tile（首个 / 最中间 / 最后一个，与 feature_maps_3tiles 一致）
TILES = [(0, 0), (12, 16), (23, 31)]

# 定点口径：
#   SAT_MODE=True  三级量化按 Q4.4 满量程饱和（对应 conv_top 的 .Q44_SAT(1)）
#   BN_RELU =True  BN 之后接 ReLU（bnq 饱和到 [0,127]）—— 真实网络 dw+pw→BN→ReLU→pool
#                  对应 conv_top 的 .BN_RELU(1) 与 conv_l1 的 bnq_f
#   老 tb 默认 Q44_SAT=0 / BN_RELU=0，行为逐位不变
SAT_MODE = True
BN_RELU = True
# BN 再量化：False = 直接截断 x>>>8（默认，与 RTL 的 BN_ROUND=0 一致）
#             True  = 四舍五入 (x+128)>>>8（配 RTL 的 BN_ROUND=1）
BN_ROUND = False

# ROM 布局（18bit）—— 必须与 rtl/conv2/conv_wrom/conv_wrom.v 里的 B_* 常量一致
#   L1: dw 27 + pw 24 + bn_a 8 + bn_b 8
ROM_DW_BASE = 0      # [0..26]   w_dw
ROM_PW_BASE = 27     # [27..50]  w_pw
ROM_BA_BASE = 51     # [51..58]  bn_a[0..7]
ROM_BB_BASE = 59     # [59..66]  bn_b[0..7]
#   L2: dw 72 + pw 128 + dw 侧归一化 8+8 + pw 侧归一化 16+16
ROM_L2_DW_BASE  = 67      # [67..138]  w2_dw[0..71]
ROM_L2_PW_BASE  = 139     # [139..266] w2_pw[0..127]
ROM_L2_BDA_BASE = 267     # [267..274] b2_dw_a[0..7]
ROM_L2_BDB_BASE = 275     # [275..282] b2_dw_b[0..7]
ROM_L2_BPA_BASE = 283     # [283..298] b2_pw_a[0..15]
ROM_L2_BPB_BASE = 299     # [299..314] b2_pw_b[0..15]
ROM_N = 315

MASK18 = (1 << 18) - 1


def q44(p):
    """训练口径 p(0..255) → Q4.4 有符号整数，硬件实现 (p-124)>>>3（算术右移=向下取整）"""
    p = np.asarray(p, dtype=np.int64)
    return (p - 124) >> 3


def load_weights():
    """返回 (dw[3,3,3] float, pw[8,3] float, scale[8], shift[8], 以及 Q8/Q8x16 整数)

    ★ 这里的 scale/shift 是 model.2 的 **running 统计量**推出来的（= BatchNorm eval 口径）。
      目标口径是**实例归一化**：μ/σ 由 Python 按当前这张图算（见 instance_ab()），
      算出来的 A_q/B_q 一样从 ROM 灌给 RTL —— RTL 的 BN 算术不用动。
    """
    import torch
    sd = torch.load(PTH, map_location="cpu", weights_only=True)
    dw = sd["model.1.depthwise.weight"].numpy().reshape(3, 3, 3).astype(np.float64)
    pw = sd["model.1.pointwise.weight"].numpy().reshape(8, 3).astype(np.float64)
    g = sd["model.2.weight"].numpy().astype(np.float64)
    b = sd["model.2.bias"].numpy().astype(np.float64)
    m = sd["model.2.running_mean"].numpy().astype(np.float64)
    v = sd["model.2.running_var"].numpy().astype(np.float64)
    scale = g / np.sqrt(v + BN_EPS)
    shift = b - m * scale
    dw_q = np.round(dw * 256).astype(np.int64)
    pw_q = np.round(pw * 256).astype(np.int64)
    a_q = np.round(scale * 256).astype(np.int64)
    b_q = np.round(shift * 4096).astype(np.int64)
    return dict(dw=dw, pw=pw, scale=scale, shift=shift,
                gamma=g, beta=b,
                dw_q=dw_q, pw_q=pw_q, a_q=a_q, b_q=b_q)


def inorm_ab_real(x_real, gamma, beta):
    """按**浮点/理论**统计量算逐通道归一化参数（这是本工程约定的口径：
    μ/σ 由 Python 按当前这张图算理论值，编成 A_q/B_q 灌给 RTL，硬件里不做统计）。

    x_real : (H,W,C) **实际值**（float，不是 Q4.4 寄存器值！）
    返回 a_q[C] = round(scale*256)、b_q[C] = round(shift*4096)、scale[C]、shift[C]
    """
    C = x_real.shape[2]
    a_q = np.zeros(C, dtype=np.int64)
    b_q = np.zeros(C, dtype=np.int64)
    scale = np.zeros(C)
    shift = np.zeros(C)
    for c in range(C):
        v = x_real[:, :, c].astype(np.float64)
        m = v.mean()
        s = np.sqrt(v.var() + BN_EPS)
        sc = gamma[c] / s
        sh = beta[c] - m * sc
        scale[c] = sc
        shift[c] = sh
        a_q[c] = int(np.round(sc * 256))
        b_q[c] = int(np.round(sh * 4096))
    return a_q, b_q, scale, shift


def load_image():
    from PIL import Image
    img = np.asarray(Image.open(JPG).convert("RGB"), dtype=np.int64)
    assert img.shape == (IH, IW, 3), img.shape
    return img


def stages(img, W, sat=True, bn_relu=True, bn_round=False, ab=None):
    """按 RTL 语义算出全程中间数据（整帧）。
    sat=True     : 三级量化都 Q4.4 满量程饱和（对应 conv_top 的 Q44_SAT=1）
                   dw/pw → [-128,127]（对称，真实网络那里没有激活）
                   BN    → [0,127] 若 bn_relu 否则 [-128,127]
    sat=False    : 老行为，clamp 0..255
    bn_round     : BN 的再量化是否四舍五入（(x+128)>>>8）而不是直接截断（x>>>8）
                   —— 对应 conv_l1 的 BN_ROUND；dw/pw 两级本来就是 (x+128)>>>8
    ab           : (a_q, b_q) 归一化参数。**目标口径**是传 float_ref() 里按当前这张图
                   算出来的理论值（Python 算好灌给 RTL，硬件里不做统计）；
                   不传则退回 W 里 model.2 的 running 统计量（旧口径）。
    返回 dict: qin, dwc_raw, dwc, pwsum, qq, bnq, out, a_q, b_q（后两个是实际用的参数）
    """
    dw_q, pw_q = W["dw_q"], W["pw_q"]
    lo, hi = (-128, 127) if sat else (0, 255)
    bn_lo = 0 if (sat and bn_relu) else lo

    qin = q44(img)                                                    # (IH,IW,3) Q4.4
    pad = np.pad(qin, ((1, 1), (1, 1), (0, 0)), mode="reflect")        # reflect-101
    dwc_raw = np.zeros((IH, IW, 3), dtype=np.int64)
    for c in range(3):
        for kh in range(3):
            for kw in range(3):
                dwc_raw[:, :, c] += pad[kh:kh + IH, kw:kw + IW, c] * int(dw_q[c, kh, kw])
    dwc = np.clip((dwc_raw + 128) >> 8, lo, hi)

    pwsum = np.zeros((IH, IW, 8), dtype=np.int64)
    qq = np.zeros((IH, IW, 8), dtype=np.int64)
    for oc in range(8):
        s = np.zeros((IH, IW), dtype=np.int64)
        for c in range(3):
            s += dwc[:, :, c] * int(pw_q[oc, c])       # dwc 有符号（numpy 里有符号自然成立）
        pwsum[:, :, oc] = s
        qq[:, :, oc] = np.clip((s + 128) >> 8, lo, hi)

    a_q, b_q = (W["a_q"], W["b_q"]) if ab is None else ab

    bnq = np.zeros((IH, IW, 8), dtype=np.int64)
    bn_rnd = 128 if bn_round else 0
    for oc in range(8):
        # ★ BN：floor（RTL 原为 >>>8，无 +128）或四舍五入（+128 后 >>>8，BN_ROUND=1）
        bnq[:, :, oc] = np.clip((int(a_q[oc]) * qq[:, :, oc] + int(b_q[oc]) + bn_rnd) >> 8,
                                bn_lo, hi)

    out = np.zeros((IH // 2, IW // 2, 8), dtype=np.int64)
    for oc in range(8):
        a = bnq[0::2, 0::2, oc]; b = bnq[0::2, 1::2, oc]
        c_ = bnq[1::2, 0::2, oc]; d = bnq[1::2, 1::2, oc]
        out[:, :, oc] = np.maximum(np.maximum(a, b), np.maximum(c_, d))   # 有符号 max
    return dict(qin=qin, dwc_raw=dwc_raw, dwc=dwc, pwsum=pwsum, qq=qq, bnq=bnq, out=out,
                a_q=np.asarray(a_q), b_q=np.asarray(b_q))


def float_ref(img, W, bn_relu=False, input_mode="float"):
    """原网络浮点参考（**实例归一化**口径 = 本工程的目标口径）：
        x_norm → dw → pw → 归一化（μ/σ 由这里按当前这张图算，理论值）→ ReLU → 2×2 max
    同时把算出来的归一化参数量化成 A_q/B_q 一并返回，供 stages()/ROM 使用。

    input_mode : "float" = 真网络输入 2p/255-1（端到端画质参考）
                 "q44"   = 硬件输入 q44/16（**逐级对拍定点链路时必须用这个**，
                           否则比的是"输入量化 + 内部量化"的合计，定位不到内部）
    bn_relu=False 时 bnf 是没过 ReLU 的原始归一化输出（check_float_ref.py 要这个）。
    bnf_raw 始终是没过 ReLU 的。
    """
    dw, pw = W["dw"], W["pw"]
    if input_mode == "q44":
        xn = q44(img).astype(np.float64) / 16.0
    else:
        xn = img.astype(np.float64) / 127.5 - 1.0
    pad = np.pad(xn, ((1, 1), (1, 1), (0, 0)), mode="reflect")
    dwf = np.zeros((IH, IW, 3))
    for c in range(3):
        for kh in range(3):
            for kw in range(3):
                dwf[:, :, c] += pad[kh:kh + IH, kw:kw + IW, c] * dw[c, kh, kw]
    pwf = np.zeros((IH, IW, 8))
    for oc in range(8):
        for c in range(3):
            pwf[:, :, oc] += dwf[:, :, c] * pw[oc, c]

    # ★ 归一化参数：按当前这张图的**浮点/理论**统计量算（本工程约定的目标口径）
    a_q, b_q, scale, shift = inorm_ab_real(pwf, W["gamma"], W["beta"])

    bnf_raw = pwf * scale[None, None, :] + shift[None, None, :]
    bnf = np.maximum(0.0, bnf_raw) if bn_relu else bnf_raw
    outf = np.zeros((IH // 2, IW // 2, 8))
    for oc in range(8):
        a = bnf[0::2, 0::2, oc]; b = bnf[0::2, 1::2, oc]
        c_ = bnf[1::2, 0::2, oc]; d = bnf[1::2, 1::2, oc]
        outf[:, :, oc] = np.maximum(np.maximum(a, b), np.maximum(c_, d))
    return dict(dwf=dwf, pwf=pwf, bnf=bnf, bnf_raw=bnf_raw, outf=outf,
                scale=scale, shift=shift, a_q=a_q, b_q=b_q)


def rom_words(W, a_q=None, b_q=None, W2=None, ab_dw=None, ab_pw=None):
    """按 ROM 布局生成 315 个 18bit 字（已做二进制补码掩码）
    a_q/b_q         : L1 的归一化参数（实例口径时由 Python 按图算好传进来）
    W2/ab_dw/ab_pw  : 传了就一起写 L2 区（权重 + 归一化参数）
    """
    if a_q is None:
        a_q = W["a_q"]
    if b_q is None:
        b_q = W["b_q"]
    mem = [0] * ROM_N
    for i in range(27):
        mem[ROM_DW_BASE + i] = int(W["dw_q"].reshape(-1)[i]) & MASK18
    for i in range(24):
        mem[ROM_PW_BASE + i] = int(W["pw_q"].reshape(-1)[i]) & MASK18
    for i in range(8):
        mem[ROM_BA_BASE + i] = int(a_q[i]) & MASK18
        mem[ROM_BB_BASE + i] = int(b_q[i]) & MASK18
    if W2 is not None:
        dw2 = W2["dw_q"].reshape(-1)
        pw2 = W2["pw_q"].reshape(-1)
        for i in range(72):
            mem[ROM_L2_DW_BASE + i] = int(dw2[i]) & MASK18
        for i in range(128):
            mem[ROM_L2_PW_BASE + i] = int(pw2[i]) & MASK18
        ad, bd = ab_dw                     # L2 dw 侧归一化（8 通道）
        ap, bp = ab_pw                     # L2 pw 侧归一化（16 通道）
        for i in range(8):
            mem[ROM_L2_BDA_BASE + i] = int(ad[i]) & MASK18
            mem[ROM_L2_BDB_BASE + i] = int(bd[i]) & MASK18
        for i in range(16):
            mem[ROM_L2_BPA_BASE + i] = int(ap[i]) & MASK18
            mem[ROM_L2_BPB_BASE + i] = int(bp[i]) & MASK18
    return mem


def plane_golden(out):
    """池化输出面 → 30720 个 40bit unit。
    unit = (oc*120 + row)*32 + u ; row = tr*5+i ; u = tc
    单元内低字节 = 列 +0，高字节 = 列 +4
    """
    units = np.zeros(NTILE_R * NTILE_C * 8 * 5, dtype=np.uint64)
    for tr in range(NTILE_R):
        for tc in range(NTILE_C):
            for oc in range(8):
                for i in range(5):
                    row = tr * 5 + i
                    unit = (oc * 120 + row) * 32 + tc
                    v = 0
                    for j in range(5):
                        col = tc * 5 + j
                        # ★ 数据是 Q4.4 有符号（可能为负）→ 先取 8bit 补码再拼进 unit
                        v |= (int(out[row, col, oc]) & 0xFF) << (8 * j)
                    units[unit] = v
    return units


def plane_golden_l2(out, base=None):
    """L2 原地写回**同一个 L1 面**之后的完整 unit 视图（30,720 个 40bit unit）。

        unit = ((oc2>>1)*120 + r2)*32 + (oc2&1)*16 + k2
        r2 = 0..59（只用 L1 面的行 0..59），k2 = 0..15（= tile_c）
        一个 unit = **同一行连续 5 列**（低字节 = 列 +0），与 L1 面的打包方式相同

    ★ 注意 L2 的结果在地址空间里是**交错**的（奇 oc2 落在行的高半列、
      最大 unit = 28799），所以返回的是**整块面**：L2 区被覆盖，
      其余 unit 保持 base（= L1 的 plane_golden）；不给 base 就填 0。
      ⇒ 直接和 RTL 跑完 L1+L2 之后的整个面逐 unit 比。
    """
    nu = 8 * L2_IH * (L2_IW // 5)          # 30720：L1 面的 unit 总数
    cpu = L2_IW // 5                       # 32：每行 unit 数
    units = np.zeros(nu, dtype=np.uint64) if base is None else np.array(base, dtype=np.uint64)
    for r2 in range(L2_OH):
        for k2 in range(L2_OW // 5):
            for oc2 in range(L2_COUT):
                unit = ((oc2 >> 1) * L2_IH + r2) * cpu + (oc2 & 1) * (cpu // 2) + k2
                v = 0
                for j in range(5):
                    col = k2 * 5 + j
                    v |= (int(out[r2, col, oc2]) & 0xFF) << (8 * j)
                units[unit] = v
    return units


def tile_block(arr, tr, tc, size, ch_axis=2):
    return arr[tr * size:(tr + 1) * size, tc * size:(tc + 1) * size, :]

def fmt_rows(vals, per_row, fmt):
    return [" ".join(fmt % v for v in vals[i:i + per_row]) for i in range(0, len(vals), per_row)]


# =====================================================================
# L2：model.5 = DepthwiseSeparableConv(8→16, stride=1) + model.6 = MaxPool2d(2)
#     dw3×3(8 组, **零填充 pad=1**) → 归一化(8) → ReLU → pw1×1(8→16) → 归一化(16) → 2×2 max
#     ★ 注意：L1 用的是显式 ReflectionPad2d(1)（反射），L2 的 dw 是 Conv2d(...,padding=1)
#       = **零填充**。别照 L1 的窗口装载器去反射，否则边界两行两列全错。
#     输入 = L1 池化输出 (120,160,8) Q4.4；输出 = (60,80,16) Q4.4（**可以有负值**，pw 后没有 ReLU）
# =====================================================================
L2_IH, L2_IW = 120, 160          # L2 输入（= L1 输出）高/宽
L2_OH, L2_OW = 60, 80            # L2 输出高/宽
L2_CIN, L2_COUT = 8, 16


def load_weights_l2():
    """L2 的权重/归一化参数：model.5.depthwise.0/1 与 model.5.pointwise.0/1"""
    import torch
    sd = torch.load(PTH, map_location="cpu", weights_only=True)

    def bn(prefix):
        return dict(gamma=sd[prefix + ".weight"].numpy().astype(np.float64),
                    beta=sd[prefix + ".bias"].numpy().astype(np.float64),
                    mean=sd[prefix + ".running_mean"].numpy().astype(np.float64),
                    var=sd[prefix + ".running_var"].numpy().astype(np.float64))

    dw = sd["model.5.depthwise.0.weight"].numpy().reshape(L2_CIN, 3, 3).astype(np.float64)
    pw = sd["model.5.pointwise.0.weight"].numpy().reshape(L2_COUT, L2_CIN).astype(np.float64)
    return dict(dw=dw, pw=pw,
                bn_dw=bn("model.5.depthwise.1"),
                bn_pw=bn("model.5.pointwise.1"),
                dw_q=np.round(dw * 256).astype(np.int64),
                pw_q=np.round(pw * 256).astype(np.int64))


def stages_l2(x1, W2, sat=True, bn_relu_dw=True, bn_relu_pw=False, ab_dw=None, ab_pw=None):
    """L2 定点链路（RTL 口径）。
    x1 : (120,160,8) Q4.4 整数（L1 池化输出）
    ab_dw/ab_pw : (a_q, b_q) 归一化参数。**目标口径**是传 float_ref_l2() 里按当前这张图
                  算出来的理论值；不传就用 model.5 的 running 统计量（旧口径）。
    返回 dict: dwc, a_dw/b_dw, bn1(ReLU 后), qq, a_pw/b_pw, bn2, out
    口径：dw/pw 都是 clip((Σ+128)>>8, ±8 对称饱和)；
          dw 的归一化后有 ReLU（[0,127]），pw 的归一化**没有** ReLU（可负）
    """
    lo, hi = (-128, 127) if sat else (0, 255)
    dw_q, pw_q = W2["dw_q"], W2["pw_q"]

    # ---- dw 3×3，8 组，零填充 1 ----
    pad = np.zeros((L2_IH + 2, L2_IW + 2, L2_CIN), dtype=np.int64)
    pad[1:-1, 1:-1, :] = x1
    raw = np.zeros((L2_IH, L2_IW, L2_CIN), dtype=np.int64)
    for c in range(L2_CIN):
        for kh in range(3):
            for kw in range(3):
                raw[:, :, c] += pad[kh:kh + L2_IH, kw:kw + L2_IW, c] * int(dw_q[c, kh, kw])
    dwc = np.clip((raw + 128) >> 8, lo, hi)

    # ---- 归一化(8) + ReLU ----
    if ab_dw is None:
        # 旧口径：直接由 model.5.depthwise.1 的 running 统计量折成 A_q/B_q
        bnd = W2["bn_dw"]
        sc = bnd["gamma"] / np.sqrt(bnd["var"] + BN_EPS)
        a_dw = np.round(sc * 256).astype(np.int64)
        b_dw = np.round((bnd["beta"] - bnd["mean"] * sc) * 4096).astype(np.int64)
    else:
        a_dw, b_dw = ab_dw
    bn1 = np.zeros_like(dwc)
    for c in range(L2_CIN):
        v = (int(a_dw[c]) * dwc[:, :, c] + int(b_dw[c])) >> 8
        bn1[:, :, c] = np.clip(v, 0, 127) if bn_relu_dw else np.clip(v, lo, hi)

    # ---- pw 1×1 8→16 ----
    qq = np.zeros((L2_IH, L2_IW, L2_COUT), dtype=np.int64)
    for oc in range(L2_COUT):
        s = np.zeros((L2_IH, L2_IW), dtype=np.int64)
        for c in range(L2_CIN):
            s += bn1[:, :, c] * int(pw_q[oc, c])
        qq[:, :, oc] = np.clip((s + 128) >> 8, lo, hi)

    # ---- 归一化(16)，没有 ReLU ----
    if ab_pw is None:
        bnp = W2["bn_pw"]
        sc = bnp["gamma"] / np.sqrt(bnp["var"] + BN_EPS)
        a_pw = np.round(sc * 256).astype(np.int64)
        b_pw = np.round((bnp["beta"] - bnp["mean"] * sc) * 4096).astype(np.int64)
    else:
        a_pw, b_pw = ab_pw
    bn2 = np.zeros_like(qq)
    for oc in range(L2_COUT):
        v = (int(a_pw[oc]) * qq[:, :, oc] + int(b_pw[oc])) >> 8
        bn2[:, :, oc] = np.clip(v, 0, 127) if bn_relu_pw else np.clip(v, lo, hi)

    # ---- 2×2 max（有符号）----
    out = np.zeros((L2_OH, L2_OW, L2_COUT), dtype=np.int64)
    for oc in range(L2_COUT):
        a = bn2[0::2, 0::2, oc]; b = bn2[0::2, 1::2, oc]
        c_ = bn2[1::2, 0::2, oc]; d = bn2[1::2, 1::2, oc]
        out[:, :, oc] = np.maximum(np.maximum(a, b), np.maximum(c_, d))
    return dict(dwc=dwc, a_dw=a_dw, b_dw=b_dw, bn1=bn1, qq=qq,
                a_pw=a_pw, b_pw=b_pw, bn2=bn2, out=out)


def float_ref_l2(x1_real, W2, bn_relu_dw=True, bn_relu_pw=False):
    """L2 的浮点参考（用 Python 算的实例统计量）。
    x1_real : (120,160,8) float，L1 的**浮点**输出（实际值）
    """
    dw, pw = W2["dw"], W2["pw"]
    pad = np.zeros((L2_IH + 2, L2_IW + 2, L2_CIN))
    pad[1:-1, 1:-1, :] = x1_real
    dwf = np.zeros((L2_IH, L2_IW, L2_CIN))
    for c in range(L2_CIN):
        for kh in range(3):
            for kw in range(3):
                dwf[:, :, c] += pad[kh:kh + L2_IH, kw:kw + L2_IW, c] * dw[c, kh, kw]

    # ★ 归一化参数：按当前这张图的**浮点/理论**统计量算（本工程约定的目标口径）
    a_dw, b_dw, sc1, sh1 = inorm_ab_real(dwf, W2["bn_dw"]["gamma"], W2["bn_dw"]["beta"])
    n1 = dwf * sc1[None, None, :] + sh1[None, None, :]
    if bn_relu_dw:
        n1 = np.maximum(0.0, n1)
    pwf = np.zeros((L2_IH, L2_IW, L2_COUT))
    for oc in range(L2_COUT):
        for c in range(L2_CIN):
            pwf[:, :, oc] += n1[:, :, c] * pw[oc, c]
    a_pw, b_pw, sc2, sh2 = inorm_ab_real(pwf, W2["bn_pw"]["gamma"], W2["bn_pw"]["beta"])
    n2 = pwf * sc2[None, None, :] + sh2[None, None, :]
    if bn_relu_pw:
        n2 = np.maximum(0.0, n2)
    outf = np.zeros((L2_OH, L2_OW, L2_COUT))
    for oc in range(L2_COUT):
        a = n2[0::2, 0::2, oc]; b = n2[0::2, 1::2, oc]
        c_ = n2[1::2, 0::2, oc]; d = n2[1::2, 1::2, oc]
        outf[:, :, oc] = np.maximum(np.maximum(a, b), np.maximum(c_, d))
    return dict(dwf=dwf, n1=n1, pwf=pwf, n2=n2, outf=outf, sc1=sc1, sh1=sh1, sc2=sc2, sh2=sh2,
                ab_dw=(a_dw, b_dw), ab_pw=(a_pw, b_pw))