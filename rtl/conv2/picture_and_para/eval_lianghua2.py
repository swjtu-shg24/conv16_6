# -*- coding: utf-8 -*-
"""eval_lianghua2.py —— 把新版 lianghua_infer.py 的定点口径，和 RTL 的口径逐步对拍

lianghua_infer.py（新版）做的事：
    权重  : Q8.8  round(w*256)/256，clamp[-128, 127.996]
    激活  : Q4.4  round(t*16)/16，clamp[-8, 7.9375]  ← 挂在 Conv2d/BN/ReLU/MaxPool 等所有层后面
    模式  : netG.eval()

RTL 做的事：
    dwc = sat((Σ q*w_q + 128) >>> 8)     ← 移位前 +128 = **四舍五入**（round half up）
    qq  = sat((Σ dwc*w_q + 128) >>> 8)
    bnq = sat((A_q*qq + B_q) >>> 8)      ← 注意：**没有 +128 = 直接截断（floor）**
    pool= 2×2 max（有符号）
    ★ RTL 的 BN 之后**没有 ReLU**（±8 是对称饱和）
"""
import importlib.util
import os

import numpy as np
import torch
import torch.nn.functional as F

import stim_model as M

HERE = M.HERE


def load_their_module():
    spec = importlib.util.spec_from_file_location("lh", os.path.join(HERE, "lianghua_infer.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)          # 有 __main__ 保护，不会跑主流程
    return mod


def cmp(name, a, b):
    """a,b 都是 Q4.4 寄存器整数（numpy int64）"""
    d = np.abs(a - b)
    eq = float((d == 0).mean()) * 100
    print("   %-28s 相同 %6.2f%%   平均|差| %.4f LSB   最大|差| %d LSB" %
          (name, eq, d.mean(), int(d.max())))
    return d


def main():
    lh = load_their_module()
    img = M.load_image()
    x_q44 = ((img - 124) >> 3).astype(np.float32) / 16.0

    # ---- 他们的口径：建网 + 权重量化 Q8.8 + eval ----
    net = lh.MobileResnetGenerator(ngf=8, n_blocks=9)
    sd = torch.load(M.PTH, map_location="cpu", weights_only=True)
    net.load_state_dict(sd)
    net.eval()
    qerr, nparam = lh.quantize_model_weights_q8_8(net)
    print("=" * 78)
    print("① 他们的权重量化 Q8.8：最大误差 %.3e，参数 %d 个" % (qerr, nparam))
    print("=" * 78)

    x = torch.from_numpy(x_q44).permute(2, 0, 1)[None]
    with torch.no_grad():
        pad = net.model[0](x)                                    # ReflectionPad2d(1)
        dwf = net.model[1].depthwise(pad)                        # dw 3x3 groups=3, Q8.8 权重
        dwq = lh.quantize_q4_4(dwf)                              # ← Q4.4 限位
        pwf = net.model[1].pointwise(dwq)                        # pw 1x1, Q8.8 权重
        qqf = lh.quantize_q4_4(pwf)                              # ← Q4.4 限位
        bnf = net.model[2](qqf)                                  # BatchNorm2d(eval, running 统计)
        bnq_py = lh.quantize_q4_4(bnf)                           # ← Q4.4 限位
        relu = net.model[3](bnq_py.clone())                      # ReLU
        reluq = lh.quantize_q4_4(relu)                           # 再量化（ReLU 后仍 >=0）
        pool_py = net.model[4](reluq)                            # MaxPool2d(2,2)

    def to_reg(t):                                               # 反量化 → Q4.4 寄存器整数
        return np.round(t[0].permute(1, 2, 0).numpy().astype(np.float64) * 16).astype(np.int64)

    their_bn = to_reg(bnq_py)                                    # (240,320,8)
    their_bn_reluq = to_reg(reluq)
    their_pool = to_reg(pool_py)                                 # (120,160,8)

    # ---- RTL 口径（本工程 stim_model，已与 RTL 仿真逐点对过）----
    W = M.load_weights()
    st = M.stages(img, W, sat=True)
    hw_bn = st["bnq"]                                            # floor + ±8 饱和，无 ReLU
    hw_bn_relu = np.maximum(0, hw_bn)                            # 假若 BN 后加 ReLU
    hw_pool = st["out"]                                          # 无 ReLU 的池化
    hw_pool_relu = np.zeros_like(hw_pool)
    for oc in range(8):
        a = hw_bn_relu[0::2, 0::2, oc]; b = hw_bn_relu[0::2, 1::2, oc]
        c = hw_bn_relu[1::2, 0::2, oc]; d = hw_bn_relu[1::2, 1::2, oc]
        hw_pool_relu[:, :, oc] = np.maximum(np.maximum(a, b), np.maximum(c, d))

    print()
    print("② dw 输出（dwc）对拍")
    print("=" * 78)
    their_dw = np.round(dwf[0].permute(1, 2, 0).numpy() * 16).astype(np.int64)
    cmp("他们的 round(dw) vs RTL floor", np.round(dwq[0].permute(1, 2, 0).numpy() * 16).astype(np.int64), st["dwc"])

    print()
    print("③ pw 输出（qq）对拍")
    print("=" * 78)
    cmp("他们的 round(pw) vs RTL floor", np.round(qqf[0].permute(1, 2, 0).numpy() * 16).astype(np.int64), st["qq"])

    print()
    print("④ BN 输出对拍（关键：RTL 是 floor，他们是 round；RTL 无 ReLU，他们有 ReLU）")
    print("=" * 78)
    cmp("他们的 bnq vs RTL bnq", their_bn, hw_bn)
    cmp("他们的 bnq(ReLU后) vs RTL bnq", their_bn_reluq, hw_bn)
    cmp("他们的 bnq(ReLU后) vs RTL+ReLU", their_bn_reluq, hw_bn_relu)

    print()
    print("⑤ 池化输出对拍")
    print("=" * 78)
    cmp("他们的 pool vs RTL pool", their_pool, hw_pool)
    cmp("他们的 pool vs RTL+ReLU pool", their_pool, hw_pool_relu)

    print()
    print("=" * 78)
    print("⑥ 结论性数字")
    print("=" * 78)
    print("   RTL bnq 范围 %d..%d（其中负值 %.1f%%）" %
          (hw_bn.min(), hw_bn.max(), 100.0 * (hw_bn < 0).mean()))
    print("   他们 bnq 范围 %d..%d（ReLU 后负值必然 0）" % (their_bn.min(), their_bn.max()))
    print("   池化后：RTL 负值 %.1f%%，他们 %.1f%%" %
          (100.0 * (hw_pool < 0).mean(), 100.0 * (their_pool < 0).mean()))


main()
