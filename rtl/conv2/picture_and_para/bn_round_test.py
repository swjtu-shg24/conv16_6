# -*- coding: utf-8 -*-
"""bn_round_test.py —— BN 再量化：直接移位（截断） vs 四舍五入，哪个误差小？"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import stim_model as M

LSB = 1.0 / 16.0






def err(rtl_q, flt):
    d = np.abs(rtl_q / 16.0 - flt)
    return d.mean() / LSB, d.max() / LSB, float(np.sqrt((d ** 2).mean())) / LSB


def main():
    img = M.load_image()
    W = M.load_weights()
    fl = M.float_ref(img, W, bn_relu=True)

    print("=" * 84)
    print("BN 再量化：>>>8（截断/floor） vs (x+128)>>>8（四舍五入）")
    print("=" * 84)
    print("  %-24s | %14s | %14s | %10s" % ("方案", "BN mean|d|", "池化 mean|d|", "池化最大|d|"))
    print("  " + "-" * 76)

    res = {}
    for tag, rnd in (("截断 x>>>8（现状）", False), ("四舍五入 (x+128)>>>8", True)):
        st = M.stages(img, W, sat=True, bn_relu=True, bn_round=rnd)
        e_bn = err(st["bnq"], fl["bnf"])
        e_po = err(st["out"], fl["outf"])
        res[tag] = (e_bn, e_po)
        print("  %-24s | %6.4f LSB   | %6.4f LSB   | %8.4f LSB" % (tag, e_bn[0], e_po[0], e_po[1]))

    a = res["截断 x>>>8（现状）"]
    b = res["四舍五入 (x+128)>>>8"]
    print()
    print("  四舍五入 relative 到现状：BN 误差 %.1f%%，池化误差 %.1f%%" %
          (100.0 * b[0][0] / a[0][0], 100.0 * b[1][0] / a[1][0]))

    # 有符号偏差诊断：截断会把结果系统性压低
    st0 = M.stages(img, W, sat=True, bn_relu=True, bn_round=False)
    st1 = M.stages(img, W, sat=True, bn_relu=True, bn_round=True)
    for tag, st in (("截断", st0), ("四舍五入", st1)):
        d = st["bnq"] / 16.0 - fl["bnf"]
        print("  %-10s BN 误差的**平均符号偏差** = %+.4f LSB（有符号平均，0 表示无偏）"
              % (tag, d.mean() / LSB))
    for tag, st in (("截断", st0), ("四舍五入", st1)):
        d = st["out"] / 16.0 - fl["outf"]
        print("  %-10s 池化误差的**平均符号偏差** = %+.4f LSB" % (tag, d.mean() / LSB))

    # 饱和点会不会变多
    for tag, rnd in (("截断", False), ("四舍五入", True)):
        st = M.stages(img, W, sat=True, bn_relu=True, bn_round=rnd)
        hit = int((st["bnq"] >= 127).sum())
        print("  %-10s bnq 撞上限 127 的点数 = %d" % (tag, hit))


main()
