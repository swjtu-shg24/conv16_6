# -*- coding: utf-8 -*-
"""gen_l2_stim.py —— 给 tb_l2 生成激励与 golden（L2 引擎单独验）

产物（都在本目录）：
    l2_win.hex     24 行 = 3 个 tile × 8 通道，每行 144 个十六进制字节
                   （12×12 窗口，**零填充**：越界补 0，不是反射）
    l2_golden.txt  3 个 tile 的逐级 golden：DWC(量化后) / BNR(dw 侧归一化+ReLU) /
                   QQ(16oc) / BNQ(pw 侧归一化, 可负) / POOL(16oc × 5×5)

口径：与 stim_model.stages_l2 完全一致（dw/pw 对称 ±8 饱和、归一化参数由 Python 按图算、
      dw 侧归一化后有 ReLU、pw 侧归一化没有 ReLU、2×2 max 有符号）。
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import stim_model as M

HERE = M.HERE
# L2 的 tile 网格：输入 120 高 / 160 宽 → tile_r 0..11、tile_c 0..15
# 选 tile：两个角（覆盖零填充边界）+ 最活跃的一个（覆盖有数据的通路）
TILES_FIXED = [(0, 0), (11, 15)]


def build_windows(x1, tr, tc):
    """x1: (120,160,8) Q4.4 → 8 通道 × 12×12 窗口（**零填充**）"""
    out = []
    for ch in range(8):
        win = np.zeros((12, 12), dtype=np.int64)
        for i in range(12):
            y = tr * 10 - 1 + i
            for j in range(12):
                x = tc * 10 - 1 + j
                if 0 <= y < M.L2_IH and 0 <= x < M.L2_IW:
                    win[i, j] = x1[y, x, ch]
        out.append(win)
    return out


def main():
    img = M.load_image()
    W1 = M.load_weights()
    W2 = M.load_weights_l2()
    if len(sys.argv) > 1 and sys.argv[1] == "--bn-running":
        ab1 = None
    else:
        fl1 = M.float_ref(img, W1, bn_relu=True, input_mode="q44")
        ab1 = (fl1["a_q"], fl1["b_q"])
    st1 = M.stages(img, W1, sat=True, bn_relu=True, ab=ab1)
    x1 = st1["out"]                                        # (120,160,8) Q4.4

    # L2 的归一化参数：按 L1 的**浮点**输出算（理论值）—— 与 gen_stim.py 一致
    fl1b = M.float_ref(img, W1, bn_relu=True, input_mode="q44")
    fl2 = M.float_ref_l2(fl1b["outf"], W2)
    st2 = M.stages_l2(x1, W2, sat=True, ab_dw=fl2["ab_dw"], ab_pw=fl2["ab_pw"])

    print("=" * 78)
    print("gen_l2_stim : 给 tb_l2 的激励 + golden")
    print("=" * 78)
    print("  归一化(dw侧) A_q = %s" % list(st2["a_dw"]))
    print("  归一化(pw侧) A_q = %s ...（16 个）" % list(st2["a_pw"][:6]))

    # 选“最活跃”的 tile（按 L2 输出的平均幅度），和两个角一起凑 3 个
    #   st2["out"] 是 (60,80,16) 的像素网格 → 先按 5×5 归到 tile 网格 (12,16)
    per_pix = np.abs(st2["out"]).mean(axis=2)                   # (60,80)
    act = per_pix.reshape(12, 5, 16, 5).mean(axis=(1, 3))       # (12,16) 每个 tile 的平均幅度
    order = np.argsort(-act.reshape(-1))
    best = (int(order[0] // act.shape[1]), int(order[0] % act.shape[1]))
    TILES = TILES_FIXED + [best]
    print("  最活跃 tile = %s（|out| 均值 %.2f）" % (best, act[best[0], best[1]]))

    lines_win = []
    for (tr, tc) in TILES:
        for ch, win in enumerate(build_windows(x1, tr, tc)):
            lines_win.append(" ".join("%02x" % (int(v) & 0xFF) for v in win.reshape(-1)))
    with open(os.path.join(HERE, "l2_win.hex"), "w", encoding="ascii", newline="\n") as f:
        f.write("\n".join(lines_win) + "\n")
    print("  写出 l2_win.hex（%d 行 = %d tile × 8 通道 × 144 字节）" % (len(lines_win), len(TILES)))

    def h8(a):
        return " ".join("%02x" % (int(v) & 0xFF) for v in np.asarray(a).reshape(-1))

    gl = ["# l2_golden.txt —— gen_l2_stim.py 生成，单位 Q4.4 寄存器值",
          "# 键：DWC(ch,量化后) / BNR(ch,dw侧归一化+ReLU) / QQ(oc) / BNQ(oc) / POOL(oc)"]
    for ti, (tr, tc) in enumerate(TILES):
        gl.append("TILE %d %d %d" % (ti, tr, tc))
        for ch in range(8):
            gl.append("DWC %d %s" % (ch, h8(st2["dwc"][tr*10:tr*10+10, tc*10:tc*10+10, ch])))
        for ch in range(8):
            gl.append("BNR %d %s" % (ch, h8(st2["bn1"][tr*10:tr*10+10, tc*10:tc*10+10, ch])))
        for oc in range(16):
            gl.append("QQ %d %s" % (oc, h8(st2["qq"][tr*10:tr*10+10, tc*10:tc*10+10, oc])))
        for oc in range(16):
            gl.append("BNQ %d %s" % (oc, h8(st2["bn2"][tr*10:tr*10+10, tc*10:tc*10+10, oc])))
        for oc in range(16):
            gl.append("POOL %d %s" % (oc, h8(st2["out"][tr*5:tr*5+5, tc*5:tc*5+5, oc])))
    with open(os.path.join(HERE, "l2_golden.txt"), "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(gl) + "\n")
    print("  写出 l2_golden.txt（%d 行）" % len(gl))

    # ---- 再写一份"给 tb 直接读"的扁平 golden：每个 tile 固定 64 行 × 100 个值 ----
    #   行序：DWC ch0..7 | BNR ch0..7 | QQ oc0..15 | BNQ oc0..15 | POOL oc0..15（不足 100 补 0）
    def row100(a):
        v = [int(x) & 0xFF for x in np.asarray(a).reshape(-1)]
        return " ".join("%02x" % x for x in (v + [0] * (100 - len(v))))

    fl = []
    for (tr, tc) in TILES:
        for ch in range(8):
            fl.append(row100(st2["dwc"][tr*10:tr*10+10, tc*10:tc*10+10, ch]))
        for ch in range(8):
            fl.append(row100(st2["bn1"][tr*10:tr*10+10, tc*10:tc*10+10, ch]))
        for oc in range(16):
            fl.append(row100(st2["qq"][tr*10:tr*10+10, tc*10:tc*10+10, oc]))
        for oc in range(16):
            fl.append(row100(st2["bn2"][tr*10:tr*10+10, tc*10:tc*10+10, oc]))
        for oc in range(16):
            fl.append(row100(st2["out"][tr*5:tr*5+5, tc*5:tc*5+5, oc]))
    with open(os.path.join(HERE, "l2_golden_flat.hex"), "w", encoding="ascii", newline="\n") as f:
        f.write("\n".join(fl) + "\n")
    print("  写出 l2_golden_flat.hex（%d 行 = %d tile × 64 行 × 100 值）" % (len(fl), len(TILES)))
    print("  tile 列表：%s" % (TILES,))


main()
