# -*- coding: utf-8 -*-
"""fpga_l1_int_dump.py —— 用**整数运算**复刻 RTL 的 L1 口径，导出 .npy 供对拍

和 stim_model.py 是**两条独立实现**，可以互相验证：
    stim_model.py  : numpy 滑窗累加
    本文件          : torch F.conv2d（float64 载整数，结果精确） + numpy 整数移位

口径（与 RTL 逐位一致）：
    输入   q  = (p - 124) >> 3                       整数，Q4.4
    dw     dwc= clip((Σ q*w_dw_q + 128) >> 8, -128, 127)     ← +128 = round half up
    pw     qq = clip((Σ dwc*w_pw_q + 128) >> 8, -128, 127)
    BN     bnq= clip((A_q*qq + B_q) >> 8, 0, 127)            ← **没有 +128 = floor**；下限 0 = ReLU
    池化   2×2 max（有符号）
    A_q = round(scale*256)，B_q = round(shift*4096)

产物：
    py_l1_bnq.npy   (240,320,8) int16，Q4.4 寄存器值
    py_l1_pool.npy  (120,160,8) int16，Q4.4 寄存器值  ← 直接喂 compare_python.py

跑法：
    & 'D:\\...\\envs\\cyclegan\\python.exe' rtl\\conv2\\picture_and_para\\fpga_l1_int_dump.py
    & 'D:\\...\\envs\\cyclegan\\python.exe' rtl\\conv2\\picture_and_para\\compare_python.py rtl\\conv2\\picture_and_para\\py_l1_pool.npy
"""
import os
import sys

import numpy as np
import torch
import torch.nn.functional as F

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import stim_model as M

HERE = M.HERE


def main():
    print("=" * 74)
    print("fpga_l1_int_dump : 整数运算复刻 RTL 的 L1（独立实现）")
    print("=" * 74)

    W = M.load_weights()
    img = M.load_image()

    # ---- 1. 输入量化（整数） ----
    q = ((img - 124) >> 3).astype(np.int64)                     # (240,320,3)  Q4.4
    print("  q 范围 %d..%d" % (q.min(), q.max()))

    # ---- 2. dw：reflect pad + 分组卷积（权重转成整数，float64 精确） ----
    qt = torch.from_numpy(q.astype(np.float64)).permute(2, 0, 1)[None]      # (1,3,240,320)
    padt = F.pad(qt, (1, 1, 1, 1), mode="reflect")                          # reflect-101
    wdw = torch.from_numpy(W["dw_q"].reshape(3, 1, 3, 3).astype(np.float64))
    dw_sum = F.conv2d(padt, wdw, groups=3)[0].permute(1, 2, 0).numpy()
    dw_sum = np.round(dw_sum).astype(np.int64)                              # 精确整数
    dwc = np.clip((dw_sum + 128) >> 8, -128, 127).astype(np.int64)          # ← Q44_SAT 对称饱和
    print("  dwc 范围 %d..%d  (==0 %.1f%%)" % (dwc.min(), dwc.max(), 100.0 * (dwc == 0).mean()))

    # ---- 3. pw：1×1 卷积 ----
    pt = torch.from_numpy(dwc.astype(np.float64)).permute(2, 0, 1)[None]
    wpw = torch.from_numpy(W["pw_q"].reshape(8, 3, 1, 1).astype(np.float64))
    pw_sum = F.conv2d(pt, wpw)[0].permute(1, 2, 0).numpy()
    pw_sum = np.round(pw_sum).astype(np.int64)
    qq = np.clip((pw_sum + 128) >> 8, -128, 127).astype(np.int64)
    print("  qq  范围 %d..%d  (==0 %.1f%%)" % (qq.min(), qq.max(), 100.0 * (qq == 0).mean()))

    # ---- 4. 归一化（逐 oc；floor 无 +128；下限 0 = ReLU）----
    #   ★ 使用**实例归一化**参数：μ/σ 由 Python 按当前这张图算（浮点=理论值），
    #     编成 A_q = round(scale*256)、B_q = round(shift*4096) —— 与 gen_stim.py 灌进 ROM 的一致
    fl1 = M.float_ref(img, W, bn_relu=True)          # 浮点理论值 → 归一化参数
    a_q, b_q = fl1["a_q"], fl1["b_q"]
    print("  实例归一化参数（来自浮点理论值）：A_q = %s" % list(a_q))
    print("                  A_q = %s" % list(a_q))
    bnq = np.zeros_like(qq)
    for oc in range(8):
        bnq[:, :, oc] = np.clip((int(a_q[oc]) * qq[:, :, oc] + int(b_q[oc])) >> 8, 0, 127)
    print("  bnq 范围 %d..%d" % (bnq.min(), bnq.max()))

    # ---- 5. 2×2 max 池化（有符号） ----
    out = np.zeros((M.IH // 2, M.IW // 2, 8), dtype=np.int64)
    for oc in range(8):
        a = bnq[0::2, 0::2, oc]; b = bnq[0::2, 1::2, oc]
        c = bnq[1::2, 0::2, oc]; d = bnq[1::2, 1::2, oc]
        out[:, :, oc] = np.maximum(np.maximum(a, b), np.maximum(c, d))
    print("  pool 范围 %d..%d" % (out.min(), out.max()))

    np.save(os.path.join(HERE, "py_l1_bnq.npy"), bnq.astype(np.int16))
    np.save(os.path.join(HERE, "py_l1_pool.npy"), out.astype(np.int16))
    print("\n写出 py_l1_bnq.npy (240,320,8)、py_l1_pool.npy (120,160,8)（int16，Q4.4）")

    # ---- 6. 顺便和 golden（= RTL 仿真）当场比一下 ----
    gold = os.path.join(HERE, "golden_out_plane.npy")
    verdict = "SKIP"
    if os.path.exists(gold):
        g = np.load(gold).astype(np.int64)
        d = np.abs(out - g)
        print("\n  与 golden_out_plane.npy（RTL 仿真）逐点比：")
        print("     不一致点数 = %d / %d   最大|差| = %d LSB" % (int((d > 0).sum()), d.size, int(d.max())))
        if int((d > 0).sum()) == 0:
            print("     MATCH：整数口径的 Python 与 RTL 仿真**逐点一致**")
            verdict = "PASS"
        else:
            print("     MISMATCH：检查输入量化 / 权重 Q8 / BN 的 B_q / ReLU / 有符号池化")
            verdict = "FAIL"
    # ★ ASCII 判定行：给 check_fixed_point.bat 用（bat 必须纯 ASCII，不能拿中文去 findstr）
    print("FPGA_L1_INT_DUMP RESULT: %s" % verdict)

    # ---- 7. 顺手也和 stim_model 的定点模型比（两条独立实现互验）----
    st = M.stages(img, W, sat=True, bn_relu=True)
    for nm, a, b in (("bnq", bnq, st["bnq"]), ("pool", out, st["out"])):
        d = np.abs(a - b)
        print("  与 stim_model.%s 比：不一致 %d，最大|差| %d" % (nm, int((d > 0).sum()), int(d.max())))


main()
