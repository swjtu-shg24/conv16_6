# -*- coding: utf-8 -*-
"""gen_stim.py —— 生成真实仿真激励（权重 ROM + DDR 图像 + 整帧 golden + 3 个 tile 的逐级 golden）

产物：
    rtl/conv2/conv_wrom/wrom.hex                          67 个 18bit 字（权重 ROM 初始化）
    rtl/conv2/picture_and_para/img_ddr.hex                230400 字节（DDR 原图，p 原样 0..255）
    rtl/conv2/picture_and_para/golden_plane.hex           30720 个 40bit unit（整帧池化输出面）
    rtl/conv2/picture_and_para/golden_tiles.txt           3 个 tile 的逐级 golden（给 make_table.py 比对）

跑法（conda cyclegan 环境）：
    & 'D:\\Users\\Administrator\\anaconda3\\envs\\cyclegan\\python.exe' rtl\\conv2\\picture_and_para\\gen_stim.py
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import stim_model as M

HERE = M.HERE
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))          # 工程根目录
WROM_DIR = os.path.join(ROOT, "rtl", "conv2", "conv_wrom")


def main():
    print("=" * 74)
    print("gen_stim : 真实图片 + 真实权重 -> 仿真激励（输入 Q4.4 / 权重 Q8）")
    print("=" * 74)

    W = M.load_weights()
    img = M.load_image()
    bn_mode = "running" if '--bn-running' in sys.argv else "instance"
    print("权重 : dw(3,3,3) Q8 = %d..%d ; pw(8,3) Q8 = %d..%d" %
          (W["dw_q"].min(), W["dw_q"].max(), W["pw_q"].min(), W["pw_q"].max()))
    print("图片 : %dx%d, R/G/B 范围 %d..%d" % (M.IW, M.IH, img.min(), img.max()))

    # ---- 0. 归一化参数 ----
    #   ★ 目标口径 bn_mode="instance"：μ/σ 由 Python 按**当前这张图**算（浮点=理论值），
    #     编成 A_q/B_q 灌进 ROM → RTL 的 BN 算术不用动，效果上就是实例归一化。
    #     "--bn-running" 可切回旧的 running 统计量口径（BatchNorm eval）。
    print("归一化 : %s" % ("实例（Python 按当前图算 μ/σ → 灌 A_q/B_q）" if bn_mode == "instance"
                           else "running 统计量（BatchNorm eval 口径）"))

    # ---- 3'. 先跑定点逐级（实例统计量要从 qq 算，所以先算一遍拿参数）----
    bn_round = M.BN_ROUND or ('--bn-round' in sys.argv)
    bn_relu_tmp = M.BN_RELU
    if bn_mode == "instance":
        # ★ 目标口径：归一化参数由 Python 按**浮点理论值**算（μ/σ 取自浮点 pw 输出）
        fl_tmp = M.float_ref(img, W, bn_relu=bn_relu_tmp)
        ab_use = (fl_tmp["a_q"], fl_tmp["b_q"])
        print("         scale = %s" % np.round(fl_tmp["scale"], 4).tolist())
        print("         shift = %s" % np.round(fl_tmp["shift"], 4).tolist())
    else:
        ab_use = None                                   # 旧口径：用 model.2 的 running 统计量
    st = M.stages(img, W, sat=M.SAT_MODE, bn_relu=M.BN_RELU, bn_round=bn_round, ab=ab_use)
    aq_use, bq_use = st["a_q"], st["b_q"]

    print("BN   : A_q = %s" % list(aq_use))
    print("       B_q = %s" % list(bq_use))

    # ---- 1. 权重 ROM（含上面算出来的归一化参数 + L2 的权重/参数）----
    #   L2 的归一化参数同样按"浮点理论值"算（用 L1 的浮点输出接 L2 的浮点参考）
    W2 = M.load_weights_l2()
    fl1_for_l2 = M.float_ref(img, W, bn_relu=M.BN_RELU, input_mode="q44")
    fl2 = M.float_ref_l2(fl1_for_l2["outf"], W2)
    print("L2   : dw(8,3,3) Q8 = %d..%d ; pw(16,8) Q8 = %d..%d" %
          (W2["dw_q"].min(), W2["dw_q"].max(), W2["pw_q"].min(), W2["pw_q"].max()))
    print("       dw 侧 A_q = %s" % list(fl2["ab_dw"][0]))
    os.makedirs(WROM_DIR, exist_ok=True)
    mem = M.rom_words(W, a_q=aq_use, b_q=bq_use, W2=W2,
                      ab_dw=fl2["ab_dw"], ab_pw=fl2["ab_pw"])
    with open(os.path.join(WROM_DIR, "wrom.hex"), "w", encoding="ascii", newline="\n") as f:
        # ★ 纯 hex，不写注释：$readmemh 对注释的支持依赖工具，越简单越保险
        #   布局见 conv_wrom.v 文件头
        for v in mem:
            f.write("%05x\n" % v)
    print("写出 %s  (%d 字)" % (os.path.join("rtl", "conv2", "conv_wrom", "wrom.hex"), M.ROM_N))

    # ---- 2. DDR 图像（原样像素 p，硬件里再做 (p-124)>>>3）----
    with open(os.path.join(HERE, "img_ddr.hex"), "w", encoding="ascii", newline="\n") as f:
        for r in range(M.IH):
            for ch in range(3):
                for c in range(M.IW):
                    f.write("%02x\n" % int(img[r, c, ch]))
    print("写出 img_ddr.hex  (%d 字节 = %dx%dx3)" % (M.IH * M.ROWB, M.IW, M.IH))

    # ---- 3. 定点逐级 + 整帧池化输出面 ----
    #   ★ SAT_MODE=True ：dw/pw 对称饱和 [-128,127]（真实网络那里没有激活）
    #     BN_RELU=True  ：BN 之后接 ReLU → bnq 饱和 [0,127]
    #   对应 tb_top_real 里 conv_top 的 .Q44_SAT(1) .BN_RELU(1)
    print("定点模式 : Q44_SAT=%d BN_RELU=%d（dw/pw %s；BN %s）" %
          (1 if M.SAT_MODE else 0, 1 if M.BN_RELU else 0,
           "对称饱和 ±8" if M.SAT_MODE else "老行为 clamp 0..255",
           "ReLU+上限饱和 [0,127]" if (M.SAT_MODE and M.BN_RELU) else "对称饱和"))
    units = M.plane_golden(st["out"])
    with open(os.path.join(HERE, "golden_plane.hex"), "w", encoding="ascii", newline="\n") as f:
        for v in units:
            f.write("%010x\n" % int(v))
    print("写出 golden_plane.hex (%d 个 unit)" % len(units))
    print("     池化输出 Q4.4 范围 %d..%d（实际值 %.2f..%.2f）" %
          (st["out"].min(), st["out"].max(), st["out"].min() / 16, st["out"].max() / 16))

    # ---- 3b. 整帧定点输出导出成 .npy，方便和你自己的 Python 结果逐点对拍 ----
    out_npy = np.ascontiguousarray(st["out"].astype(np.int16))          # (120, 160, 8) Q4.4
    np.save(os.path.join(HERE, "golden_out_plane.npy"), out_npy)
    print("写出 golden_out_plane.npy  shape=%s dtype=int16（Q4.4，实际值 = /16）" % (out_npy.shape,))

    # ---- 3c. ★ L2 的整帧 golden：**原地复用 L1 面**（L2_PLAN §6.3 的映射）----
    #   输入用 L1 的**定点整数**输出 st["out"]（与 RTL 真正落在面上的数据同源）；
    #   归一化参数用上面灌进 ROM 的同一组 ab（fl2）—— 两处必须同源。
    st2 = M.stages_l2(st["out"], W2, sat=M.SAT_MODE,
                      ab_dw=fl2["ab_dw"], ab_pw=fl2["ab_pw"])
    #   ★ 返回的是**整块面**：L2 区覆盖、其余（L1 行 60..119）保持 L1 的 golden
    units2 = M.plane_golden_l2(st2["out"], base=units)
    with open(os.path.join(HERE, "golden_plane_l2.hex"), "w", encoding="ascii", newline="\n") as f:
        for v in units2:
            f.write("%010x\n" % int(v))
    print("写出 golden_plane_l2.hex (%d 个 unit = 整个面；L2 区 %d 个被覆盖)"
          % (len(units2), 60 * 80 * 16 // 5))
    print("     L2 输出 Q4.4 范围 %d..%d（实际值 %.2f..%.2f）" %
          (st2["out"].min(), st2["out"].max(),
           st2["out"].min() / 16, st2["out"].max() / 16))
    np.save(os.path.join(HERE, "golden_out_plane_l2.npy"),
            np.ascontiguousarray(st2["out"].astype(np.int16)))
    print("写出 golden_out_plane_l2.npy  shape=%s（Q4.4，实际值 = /16）" % (st2["out"].shape,))

    # ---- 3d. ★ L2 的**逐级** golden（真实数据通路，3 个 tile；给 tb_top_l2 逐点对拍）----
    #   口径：输入 = L1 的定点输出 st["out"]（= RTL 真正落在面里的数据）
    #        窗口从它按 **零填充** 取 12×12（与 conv_win_load_plane 完全一致）
    #        逐级 = stages_l2 的 dwc / bn1(归一化+ReLU) / qq / bn2(归一化，可负) / out(池化)
    L2_TILES = [(0, 0), (5, 7), (11, 15)]     # 与 tb_top_l2.v 里的 LTR/LTC 必须一致
    lines_win = []
    for (tr, tc) in L2_TILES:
        for ch in range(M.L2_CIN):
            win = np.zeros((12, 12), dtype=np.int64)
            for i in range(12):
                yy = tr * 10 - 1 + i
                for j in range(12):
                    xx = tc * 10 - 1 + j
                    if (0 <= yy < M.L2_IH) and (0 <= xx < M.L2_IW):
                        win[i, j] = st["out"][yy, xx, ch]
            lines_win.append(" ".join("%02x" % (int(v) & 0xFF) for v in win.reshape(-1)))
    with open(os.path.join(HERE, "l2_win_real.hex"), "w", encoding="ascii", newline="\n") as f:
        f.write("\n".join(lines_win) + "\n")
    print("写出 l2_win_real.hex (%d 行 = %d tile × 8 通道 × 144 字节，零填充)"
          % (len(lines_win), len(L2_TILES)))

    def row100(a):
        v = [int(x) & 0xFF for x in np.asarray(a).reshape(-1)]
        return " ".join("%02x" % x for x in (v + [0] * (100 - len(v))))

    rows2 = []
    for (tr, tc) in L2_TILES:
        for ch in range(8):      # DWC：量化后的 dw 输出
            rows2.append(row100(st2["dwc"][tr*10:tr*10+10, tc*10:tc*10+10, ch]))
        for ch in range(8):      # BNR：dw 侧归一化 + ReLU 之后
            rows2.append(row100(st2["bn1"][tr*10:tr*10+10, tc*10:tc*10+10, ch]))
        for oc in range(16):     # QQ：pw 量化
            rows2.append(row100(st2["qq"][tr*10:tr*10+10, tc*10:tc*10+10, oc]))
        for oc in range(16):     # BNQ：pw 侧归一化（可负）
            rows2.append(row100(st2["bn2"][tr*10:tr*10+10, tc*10:tc*10+10, oc]))
        for oc in range(16):     # POOL：2×2 max → 5×5
            rows2.append(row100(st2["out"][tr*5:tr*5+5, tc*5:tc*5+5, oc]))
    with open(os.path.join(HERE, "l2_golden_real_flat.hex"), "w",
              encoding="ascii", newline="\n") as f:
        f.write("\n".join(rows2) + "\n")
    print("写出 l2_golden_real_flat.hex (%d 行 = %d tile × 64 行 × 100 值；tile 列表 %s)"
          % (len(rows2), len(L2_TILES), L2_TILES))

    # ---- 3e. ★ 逐级**全帧** golden（.npz，给 dump_all_report.py 全量对拍用）----
    np.savez(os.path.join(HERE, "golden_l1_stages.npz"),
             dwc=st["dwc"].astype(np.int16), qq=st["qq"].astype(np.int16),
             bnq=st["bnq"].astype(np.int16), pool=st["out"].astype(np.int16))
    np.savez(os.path.join(HERE, "golden_l2_stages.npz"),
             dwc=st2["dwc"].astype(np.int16), bnr=st2["bn1"].astype(np.int16),
             qq=st2["qq"].astype(np.int16), bnq=st2["bn2"].astype(np.int16),
             pool=st2["out"].astype(np.int16))
    print("写出 golden_l1_stages.npz / golden_l2_stages.npz（两层逐级全帧，Q4.4）")

    # ---- 4. 3 个 tile 的逐级 golden ----
    fl = M.float_ref(img, W, bn_relu=M.BN_RELU)
    lines = []

    def emit(key, idx, vals, fmt):
        lines.append("%s %d %s" % (key, idx, " ".join(fmt(v) for v in vals)))

    # ★ 所有整数一律按"定宽二进制补码十六进制"写：
    #     8bit  → %02x （Q4.4 数据 / 量化结果，0..255 或负数补码）
    #     24bit → %06x （pw 累加和）
    #   和 tb_top_real.v 里的 $fwrite("%02x"/"%06x") 完全同格式，便于逐点比对
    H8 = lambda a: "%02x" % (int(a) & 0xFF)
    H24 = lambda a: "%06x" % (int(a) & 0xFFFFFF)

    lines.append("# golden_tiles.txt -- generated by gen_stim.py, do not edit")
    lines.append("# keys: QIN/WIN/DWCRAW/DWC/PWSUM/QQ/BNQ/POOL (+ float ref: DWF/PWF/BNF/OUTF)")
    lines.append("# same key names as tb_top_real.v's real_dump.txt so they can be diffed")
    lines.append("PARAM IW %d" % M.IW)
    lines.append("PARAM IH %d" % M.IH)
    lines.append("PARAM NTILE_R %d" % M.NTILE_R)
    lines.append("PARAM NTILE_C %d" % M.NTILE_C)
    lines.append("PARAM NTILES %d" % len(M.TILES))
    lines.append("PARAM SAT %d" % (1 if M.SAT_MODE else 0))
    lines.append("PARAM BNRELU %d" % (1 if M.BN_RELU else 0))
    lines.append("PARAM BNROUND %d" % (1 if bn_round else 0))
    lines.append("PARAM BNMODE %s" % bn_mode)
    lines.append("PARAM AQ %s" % " ".join(str(int(v)) for v in aq_use))
    lines.append("PARAM BQ %s" % " ".join(str(int(v)) for v in bq_use))
    for i, (tr, tc) in enumerate(M.TILES):
        lines.append("PARAM TILE%d %d %d" % (i, tr, tc))
        lines.append("PARAM AQ%d %s" % (i, " ".join(str(int(v)) for v in W["a_q"])))
        lines.append("PARAM BQ%d %s" % (i, " ".join(str(int(v)) for v in W["b_q"])))
    lines.append("PARAM DWQ %s" % " ".join(str(int(v)) for v in W["dw_q"].reshape(-1)))
    lines.append("PARAM PWQ %s" % " ".join(str(int(v)) for v in W["pw_q"].reshape(-1)))

    for i, (tr, tc) in enumerate(M.TILES):
        y0, x0 = tr * M.TILE_IN, tc * M.TILE_IN
        lines.append("TILE %d %d %d" % (i, tr, tc))
        # 输入 tile（原图像素 p / Q4.4）与 12x12 反射窗口
        for c in range(3):
            emit("RAW", c, img[y0:y0 + 10, x0:x0 + 10, c].reshape(-1), lambda v: "%d" % v)
        for c in range(3):
            emit("QIN", c, st["qin"][y0:y0 + 10, x0:x0 + 10, c].reshape(-1), H8)
        pad = np.pad(st["qin"], ((1, 1), (1, 1), (0, 0)), mode="reflect")
        for c in range(3):
            emit("WIN", c, pad[y0:y0 + 12, x0:x0 + 12, c].reshape(-1), H8)
        for c in range(3):
            emit("DWCRAW", c, st["dwc_raw"][y0:y0 + 10, x0:x0 + 10, c].reshape(-1), H24)
            emit("DWC", c, st["dwc"][y0:y0 + 10, x0:x0 + 10, c].reshape(-1), H8)
        for oc in range(8):
            emit("PWSUM", oc, st["pwsum"][y0:y0 + 10, x0:x0 + 10, oc].reshape(-1), H24)
            emit("QQ", oc, st["qq"][y0:y0 + 10, x0:x0 + 10, oc].reshape(-1), H8)
            emit("BNQ", oc, st["bnq"][y0:y0 + 10, x0:x0 + 10, oc].reshape(-1), H8)
        for oc in range(8):
            emit("POOL", oc, st["out"][tr * 5:(tr + 1) * 5, tc * 5:(tc + 1) * 5, oc].reshape(-1), H8)
        # 浮点参考（只给 BN 之后 10x10 与池化 5x5，够填表）
        for oc in range(8):
            b = fl["bnf"][y0:y0 + 10, x0:x0 + 10, oc].reshape(-1)
            emit("BNF", oc, b, lambda v: "%.6f" % v)
        for oc in range(8):
            o = fl["outf"][tr * 5:(tr + 1) * 5, tc * 5:(tc + 1) * 5, oc].reshape(-1)
            emit("OUTF", oc, o, lambda v: "%.6f" % v)
        for c in range(3):
            d = fl["dwf"][y0:y0 + 10, x0:x0 + 10, c].reshape(-1)
            emit("DWF", c, d, lambda v: "%.6f" % v)
        for oc in range(8):
            p = fl["pwf"][y0:y0 + 10, x0:x0 + 10, oc].reshape(-1)
            emit("PWF", oc, p, lambda v: "%.6f" % v)

    with open(os.path.join(HERE, "golden_tiles.txt"), "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    print("写出 golden_tiles.txt (3 个 tile × 全通路)")

    # ---- 5. 结论摘要 ----
    dwc = st["dwc"]; qq = st["qq"]; bnq = st["bnq"]; out = st["out"]
    print("-" * 74)
    print("定点链路统计（整帧 %d 点/通道）" % (M.IH * M.IW))
    print("  dwc  : %d..%d   ==0 %.1f%%" % (dwc.min(), dwc.max(), 100.0 * (dwc == 0).mean()))
    print("  qq   : %d..%d   ==0 %.1f%%" % (qq.min(), qq.max(), 100.0 * (qq == 0).mean()))
    print("  bnq  : %d..%d" % (bnq.min(), bnq.max()))
    print("  pool : %d..%d" % (out.min(), out.max()))
    print("  （都是 Q4.4 寄存器值，实际值 = /16）")
    # 饱和命中率：Q44_SAT=1 时饱和点是 +127 / -128
    for nm, arr in (("dwc", dwc), ("qq", qq), ("bnq", bnq)):
        hit = int((arr >= 127).sum() + (arr <= -128).sum())
        print("  %s 饱和到 ±满量程的点数 = %d / %d (%.4f%%)" %
              (nm, hit, arr.size, 100.0 * hit / arr.size))
    print("\n完成。下一步：vsim -c -do rtl/conv2/sim/run_real.do")


main()
