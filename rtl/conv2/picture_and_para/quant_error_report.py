# -*- coding: utf-8 -*-
"""quant_error_report.py —— RTL 定点链路 vs Python 浮点理论值，逐级误差报告

三个对照物，别混：
    ① Python **整数**模型（fpga_l1_int_dump.py / stim_model.stages）
       —— 与 RTL 仿真**逐点相同（0 LSB）**，这一环已经证明，不是本报告要测的
    ② Python **浮点理论值**（x=2p/255-1 → dw → pw → BN → ReLU → pool）
       —— 这就是"理论值"，本报告测的是 RTL 离它有多远 = **定点的代价**
    ③ Q4.4 理想取整（把浮点值直接 round 到 1/16 格点）
       —— 误差下限，用来判断"离理论值的差距"里有多少只是格点粒度

跑法：
    & 'D:\\...\\envs\\cyclegan\\python.exe' rtl\\conv2\\picture_and_para\\quant_error_report.py
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import stim_model as M

LSB = 1.0 / 16.0          # Q4.4 一个步长 = 0.0625（实际值）


def stat(name, rtl_q, flt, ideal_q=None):
    """rtl_q/ideal_q: Q4.4 寄存器整数；flt: 浮点理论值（实际值）"""
    r = rtl_q / 16.0
    d = r - flt
    ad = np.abs(d)
    rms = float(np.sqrt((d ** 2).mean()))
    corr = float(np.corrcoef(r.reshape(-1), flt.reshape(-1))[0, 1]) if (r.std() > 0 and flt.std() > 0) else float("nan")
    sig = float(np.abs(flt).mean())
    line = ("  %-14s | %7.3f..%7.3f | %8.4f %8.4f | %8.4f | %7.2f%% | %+.4f"
            % (name, flt.min(), flt.max(),
               float(ad.mean()) / LSB, float(ad.max()) / LSB, rms / LSB,
               100.0 * float(ad.mean()) / max(sig, 1e-9), corr))
    print(line)
    if ideal_q is not None:
        di = np.abs(ideal_q / 16.0 - flt)
        print("  %-14s | 理想 Q4.4 取整：mean|d|=%.4f LSB  max|d|=%.4f LSB  →  实际/理想 = %.2f 倍"
              % ("", float(di.mean()) / LSB, float(di.max()) / LSB,
                 (float(ad.mean()) / max(float(di.mean()), 1e-12))))
    return dict(mean_lsb=float(ad.mean()) / LSB, max_lsb=float(ad.max()) / LSB,
                rms_lsb=rms / LSB, rel=100.0 * float(ad.mean()) / max(sig, 1e-9), corr=corr)


def main():
    img = M.load_image()
    W = M.load_weights()

    st = M.stages(img, W, sat=True, bn_relu=True)        # = RTL 仿真（已证明 0 LSB）
    fl = M.float_ref(img, W, bn_relu=True)               # 浮点理论值

    print("=" * 100)
    print("RTL 定点链路  vs  Python 浮点理论值（单位：Q4.4 的 LSB = 1/16 = 0.0625 实际值）")
    print("=" * 100)
    print("  %-14s | %15s | %19s | %8s | %7s | %s" %
          ("级", "理论值范围(实际)", "mean|d|  max|d| (LSB)", "RMS(LSB)", "相对误差", "相关系数"))
    print("  " + "-" * 96)

    st_dw = stat("dw 输出", st["dwc"], fl["dwf"],
                 np.round(fl["dwf"] * 16))
    st_pw = stat("pw 输出", st["qq"], fl["pwf"],
                 np.round(fl["pwf"] * 16))
    st_bn = stat("BN 输出(ReLU)", st["bnq"], fl["bnf"],
                 np.round(fl["bnf"] * 16))
    st_out = stat("池化输出", st["out"], fl["outf"],
                  np.round(fl["outf"] * 16))

    print()
    print("=" * 100)
    print("池化输出（就是写回 plane 的 160×120×8）逐通道")
    print("=" * 100)
    print("  %-5s | %-22s | %10s %10s | %7s | %s" % ("oc", "理论值范围", "mean|d|", "max|d|", "RMS", "相关系数"))
    print("  " + "-" * 84)
    for oc in range(8):
        r = st["out"][:, :, oc] / 16.0
        f = fl["outf"][:, :, oc]
        d = np.abs(r - f)
        corr = float(np.corrcoef(r.reshape(-1), f.reshape(-1))[0, 1]) if (r.std() > 0 and f.std() > 0) else float("nan")
        print("  oc%-3d | %+8.3f .. %+8.3f | %10.4f %10.4f | %7.4f | %+.4f"
              % (oc, f.min(), f.max(), d.mean() / LSB, d.max() / LSB,
                 np.sqrt((d ** 2).mean()) / LSB, corr))

    # 全通道汇总
    d = np.abs(st["out"] / 16.0 - fl["outf"])
    print()
    print("=" * 100)
    print("汇总")
    print("=" * 100)
    print("  池化输出（160×120×8 = 153600 个值）：")
    print("     平均绝对误差 = %.4f LSB = %.4f（实际值）" % (d.mean() / LSB, d.mean()))
    print("     最大绝对误差 = %.4f LSB = %.4f（实际值）" % (d.max() / LSB, d.max()))
    print("     RMSE        = %.4f LSB" % (np.sqrt((d ** 2).mean()) / LSB))
    print("     95%% 分位    = %.4f LSB" % (np.percentile(d / LSB, 95)))
    print("     完全为 0 的点 %.1f%%，|差| <= 0.5 LSB 的点 %.1f%%，<= 1 LSB 的 %.1f%%"
          % (100.0 * (d == 0).mean(), 100.0 * (d <= 0.5 * LSB).mean(), 100.0 * (d <= LSB).mean()))
    rng = fl["outf"].max() - fl["outf"].min()
    mse = float((d ** 2).mean())
    print("     理论值动态范围 %.3f，按此算 PSNR = %.1f dB" % (rng, 10 * np.log10(rng ** 2 / max(mse, 1e-12))))
    print()
    print("  对照：Python 整数模型 vs RTL 仿真 = **0 LSB（逐点完全相同）**")
    print("        上面这些差异全部来自『定点 vs 浮点』，不是仿真算错。")

    # ---------------- 误差来自哪里 + 一个试算 ----------------
    print()
    print("=" * 100)
    print("误差来源：Q4.4 的格点 (1/16) 在 BN 的增益下被放大")
    print("=" * 100)
    print("  dw/pw 两级几乎就是理想取整（1.08 / 1.20 倍），说明 Q8 权重和整数舍入基本不花钱；")
    print("  真正的误差出在 BN：它把 qq 的 ~0.3 LSB 格点误差乘上 scale(3.4~23.4) 再输出。")
    print("  而 qq 现在只用到 ±9（Q4.4 满量程是 ±127）→ **量程浪费了 3 bit 多**。")

    print()
    print("  试算：把**增益从 BN 挪到前面**（层的数学不变、浮点理论值不变，只是改定点标度）")
    print("        qq 只用到 ±9 而量程是 ±127 → 白白浪费 3 bit 多；把 pw 权重 ×8、A_q ÷8 就能用起来")
    print()
    print("  %-34s | %-16s | %10s %10s | %8s" % ("方案", "qq 范围", "BN mean|d|", "池化 mean|d|", "降到"))
    print("  " + "-" * 94)

    def variant(tag, dw_mul=1, pw_mul=1):
        Wv = dict(W)
        Wv["dw_q"] = (W["dw_q"] * dw_mul).astype(np.int64)
        Wv["pw_q"] = (W["pw_q"] * pw_mul).astype(np.int64)
        # dwc 被放大 dw_mul 倍、pw 又放大 pw_mul 倍 → BN 增益要除以两者之积
        Wv["a_q"] = np.round(W["a_q"] / float(dw_mul * pw_mul)).astype(np.int64)
        sv = M.stages(img, Wv, sat=True, bn_relu=True)
        # ★ 标度：dwc 被放大 dw_mul 倍、qq 被放大 dw_mul*pw_mul 倍；
        #   但 A_q 已经除回去了，所以 **BN 输出和池化输出的标度不变**（还是 Q4.4 实际值 ×16）
        e_bn = np.abs(sv["bnq"] / 16.0 - fl["bnf"]).mean() / LSB
        e_po = np.abs(sv["out"] / 16.0 - fl["outf"]).mean() / LSB
        e_dw = np.abs(sv["dwc"] / 16.0 / dw_mul - fl["dwf"]).mean() / LSB
        print("  %-34s | %6d..%-8d | %10.4f %10.4f | %7.0f%%   (dwc 误差 %.4f LSB)"
              % (tag, sv["qq"].min(), sv["qq"].max(), e_bn, e_po, 100.0 * e_po / (1.9828), e_dw))
        return e_dw, e_bn, e_po

    e0 = (0.2729, 1.7443, 1.9828)
    print("  %-34s | %6d..%-8d | %10.4f %10.4f | %7.0f%%"
          % ("现状（全部增益在 BN 里）", st["qq"].min(), st["qq"].max(), e0[1], e0[2], 100.0))
    variant("A: pw 权重 x8, A_q /8", 1, 8)
    variant("B: dw 权重 x8（pw 不变）, A_q /8", 8, 1)
    variant("D: dw 权重 x4（保守，留余量）, A_q /4", 4, 1)
    variant("C: dw x8 且 pw x8, A_q /64", 8, 8)


main()
