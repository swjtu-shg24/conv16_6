# -*- coding: utf-8 -*-
"""l2_spec_check.py —— L2 的整数规格验算（和 L1 一样的套路：先定规格 + 出 golden）

L2 结构（`model.5` = DepthwiseSeparableConv(8→16, stride=1)，`model.6` = MaxPool2d(2)）：
    输入 = L1 池化输出 160×120×8（Q4.4，ReLU 后非负）
    dw3×3（8 组，**零填充 pad=1** —— 不是 L1 那种反射！）
      → 归一化(8, 实例, Python 算) → ReLU → [0,127]
    pw1×1（8→16）→ 归一化(16, 实例, Python 算) → **没有 ReLU**（可以有负值）
    2×2 max → 80×60×16

做四件事：
  ① 打印 L2 权重/归一化参数与定点范围
  ② 逐级对拍：定点 vs 浮点（LSB、相关系数、饱和点数）
  ③ 交叉验证浮点参考：numpy 版 vs PyTorch 的 model[5]（换成 InstanceNorm）
  ④ 整网影响：把定点 L2 的输出接回浮点网络，看到最终图像的 PSNR

跑法：
    & 'D:\\...\\envs\\cyclegan\\python.exe' rtl\\conv2\\picture_and_para\\l2_spec_check.py
"""
import os
import sys

import numpy as np
import torch

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import stim_model as M
import gen_fpga_image as G

LSB = 1.0 / 16.0


def main():
    img = M.load_image()
    W1 = M.load_weights()
    W2 = M.load_weights_l2()

    print("=" * 84)
    print("L2 整数规格验算  (dw3×3 8组 零填充 → 归一化+ReLU → pw1×1 8→16 → 归一化 → 2×2max)")
    print("=" * 84)
    print("权重 : dw(8,3,3) Q8 = %d..%d ; pw(16,8) Q8 = %d..%d" %
          (W2["dw_q"].min(), W2["dw_q"].max(), W2["pw_q"].min(), W2["pw_q"].max()))

    # ---- ① L1（定点 + 浮点；归一化参数取浮点理论值）----
    fl1 = M.float_ref(img, W1, bn_relu=True, input_mode="q44")   # ★ 与定点链路同输入
    st1 = M.stages(img, W1, sat=True, bn_relu=True, ab=(fl1["a_q"], fl1["b_q"]))
    x1_int = st1["out"]                                     # (120,160,8) Q4.4
    x1_flt = fl1["outf"]                                    # 浮点 L1 输出（实际值）

    # ---- ② L2 定点（归一化参数同样取浮点理论值）----
    fl2 = M.float_ref_l2(x1_flt, W2)
    st2 = M.stages_l2(x1_int, W2, sat=True, ab_dw=fl2["ab_dw"], ab_pw=fl2["ab_pw"])
    print("归一化 : dw 侧 A_q = %s" % list(st2["a_dw"]))
    print("         pw 侧 A_q = %s ...（16 个）" % list(st2["a_pw"][:6]))
    print()
    print("定点范围（Q4.4 寄存器值；实际值 = /16）：")
    for nm, a in (("dwc(L2 dw)", st2["dwc"]), ("bn1(归一化+ReLU)", st2["bn1"]),
                  ("qq (L2 pw)", st2["qq"]), ("bn2(归一化)", st2["bn2"]), ("out(L2 输出)", st2["out"])):
        print("   %-18s %5d..%-5d  负值 %5.1f%%   饱和点数 %d" %
              (nm, a.min(), a.max(), 100.0 * (a < 0).mean(),
               int((a >= 127).sum() + (a <= -128).sum())))

    # ---- ③ 逐级对拍 ----
    print()
    print("逐级对拍（定点 vs 浮点，单位 LSB）：")
    for nm, a, b in (("dwc", st2["dwc"], fl2["dwf"]),
                     ("bn1 (IN+ReLU)", st2["bn1"], fl2["n1"]),
                     ("qq", st2["qq"], fl2["pwf"]),
                     ("bn2 (IN)", st2["bn2"], fl2["n2"]),
                     ("out (池化)", st2["out"], fl2["outf"])):
        d = np.abs(a / 16.0 - b)
        corr = float(np.corrcoef((a / 16.0).reshape(-1), b.reshape(-1))[0, 1]) if b.std() > 0 else float("nan")
        print("   %-14s mean|d| = %7.4f LSB   max|d| = %8.4f LSB   相关系数 %+.4f"
              % (nm, d.mean() / LSB, d.max() / LSB, corr))

    # ---- ④ 交叉验证浮点参考 ----
    print()
    net = G.bn_to_inorm(G.load_net())
    q_int = torch.from_numpy(((img.astype(np.int64) - 124) >> 3).astype(np.int64)).permute(2, 0, 1)[None]
    with torch.no_grad():
        l1_t = net.model[0:5](q_int.float() / 16.0)
        l2_t = net.model[5](l1_t)                            # DSC(8→16)：dw+IN+ReLU，pw+IN
        l2_t = l2_t[0].permute(1, 2, 0).numpy().astype(np.float64)
    d = np.abs(l2_t - fl2["n2"])
    print("交叉验证：PyTorch model[5]（InstanceNorm） vs 我的 numpy 浮点：max|d| = %.3e" % d.max())
    print("           （应该 ~1e-6；不一致说明 L2 的结构/零填充/归一化套错了）")

    # ---- ⑤ 整网影响 ----
    with torch.no_grad():
        x_base = torch.from_numpy(img.astype(np.float32) / 127.5 - 1.0).permute(2, 0, 1)[None]
        y_base = net(x_base).clone()
        # 定点 L2 输出 → 反量化 → 接回浮点网络（model[6:] = MaxPool + 之后所有层）
        l2_fixed = torch.from_numpy((st2["out"] / 16.0).astype(np.float32)).permute(2, 0, 1)[None]
        y_fix = net.model[7:](l2_fixed).clone()   # model[6] 就是 L2 的 MaxPool，已包含在 stages_l2 里
        # 对照：L1 定点（L2 浮点）
        l1_fixed = torch.from_numpy((x1_int / 16.0).astype(np.float32)).permute(2, 0, 1)[None]
        y_l1 = net.model[6:](net.model[5](l1_fixed)).clone()
    print()
    print("整网影响（都以浮点基线为准）：")
    print("   L1 定点 + L2 浮点 : PSNR = %.2f dB" % G.psnr(y_l1, y_base))
    print("   L1 定点 + L2 定点 : PSNR = %.2f dB" % G.psnr(y_fix, y_base))
    print("   （L1+L2 都定点后掉多少 = L2 定点化的代价）")
    return 0


main()
