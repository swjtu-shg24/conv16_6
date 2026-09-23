# -*- coding: utf-8 -*-
"""dump_all_report.py —— 把 tb_top_l2 的**全帧转储**整理成"能看的全部仿真数据"

输入（都在 picture_and_para/，由 gen_stim.py + tb_top_l2.v 产出）：
    rtl_dump_plane_l1.txt    L1 面：30720 行 "u <hex40>"（RTL 跑完 L1 后回读）
    rtl_dump_plane_l2.txt    L1+L2 之后整面：30720 行（L2 区 = 原地写回后的结果）
    rtl_dump_l1_stage.txt    L1 逐级全帧：DWC(3ch)/QQ(8oc)/BNQ(8oc)/POOL(8oc)
    rtl_dump_l2_stage.txt    L2 逐级全帧：DWC(8ch)/BNR(8ch)/QQ(16oc)/BNQ(16oc)/POOL(16oc)
    golden_*_stages.npz      同口径全帧 golden（gen_stim.py 生成）

产物（都在 picture_and_para/dump_all/）：
    L1_plane.npy / L2_plane.npy                    两层输出面（Q4.4）
    L1_<stage>_<ch>.png / L2_<stage>_<ch>.png      每个 stage 每通道一张图（归一化显示）
    feature_maps_dump_all.xlsx                     逐级全帧 RTL vs GOLD 统计 + 面比对统计
并在 stdout 打印**全量**比对结果（每级：点数 / 不一致 / 最大|差| / 范围）。

跑法（工程根目录）：
    & 'D:\\Users\\Administrator\\anaconda3\\envs\\cyclegan\\python.exe' rtl\\conv2\\picture_and_para\\dump_all_report.py
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import stim_model as M

HERE = M.HERE
OUT = os.path.join(HERE, "dump_all")

# 两层各自的"逐级"键（顺序随便，按名字取）
L1_STAGES = [("DWC", 3), ("QQ", 8), ("BNQ", 8), ("POOL", 8)]
L2_STAGES = [("DWC", 8), ("BNR", 8), ("QQ", 16), ("BNQ", 16), ("POOL", 16)]


def s8(x):
    """Q4.4 数据是**有符号 8bit**：dump 里写的是补码无符号字节，这里转回 -128..127"""
    return ((np.asarray(x, dtype=np.int64) + 128) % 256) - 128


def read_plane(path):
    """读 "u hex40" 转储 → dict u -> 40bit 整数"""
    d = {}
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for ln in f:
            ln = ln.strip()
            if (not ln) or ln.startswith("#"):
                continue
            a = ln.split()
            if len(a) < 2:
                continue
            try:
                d[int(a[0])] = int(a[1], 16)
            except ValueError:
                continue
    return d


def plane_to_l1(d):
    """L1 面 unit → (120,160,8) Q4.4（**有符号**；低字节 = 列 +0）"""
    a = np.zeros((120, 160, 8), dtype=np.int64)
    for u, v in d.items():
        col5 = u % 32
        rest = u // 32
        row = rest % 120
        oc = rest // 120
        if (row >= 120) or (oc >= 8):
            continue
        for j in range(5):
            col = col5 * 5 + j
            if col < 160:
                a[row, col, oc] = s8((v >> (8 * j)) & 0xFF)
    return a


def plane_to_l2(d):
    """整面 unit → L2 输出 (60,80,16) Q4.4（**有符号**；原地复用映射：
       unit = ((oc2>>1)*120 + r2)*32 + (oc2&1)*16 + k2）"""
    a = np.zeros((60, 80, 16), dtype=np.int64)
    for oc2 in range(16):
        for r2 in range(60):
            for k2 in range(16):
                u = ((oc2 >> 1) * 120 + r2) * 32 + (oc2 & 1) * 16 + k2
                v = d.get(u, 0)
                for j in range(5):
                    a[r2, k2 * 5 + j, oc2] = s8((v >> (8 * j)) & 0xFF)
    return a


def read_stage(path):
    """读逐级转储 → {stage: {(tr,tc,idx): np.array(values)}}（值按有符号 8bit 解释）"""
    out = {}
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for ln in f:
            ln = ln.strip()
            if (not ln) or ln.startswith("#"):
                continue
            a = ln.split()
            if len(a) < 4:
                continue
            st = a[0]
            try:
                tr, tc, idx = int(a[1]), int(a[2]), int(a[3])
                vals = s8([int(x, 16) for x in a[4:]])
            except ValueError:
                continue          # 含 x → 跳过（会在统计里体现为缺块）
            out.setdefault(st, {})[(tr, tc, idx)] = vals
    return out


def assemble(stage_dict, ntr, ntc, blk, n_idx):
    """把逐 tile 的块拼成整帧：tile 网格 ntr×ntc，每块 blk×blk（10=未池化，5=池化）
    返回 (rows, cols, n_idx) 的数组 + 缺失块数（缺的填 -9999）"""
    rows, cols = ntr * blk, ntc * blk
    arr = np.full((rows, cols, n_idx), -9999, dtype=np.int64)
    miss = 0
    for tr in range(ntr):
        for tc in range(ntc):
            for idx in range(n_idx):
                v = stage_dict.get((tr, tc, idx))
                if v is None:
                    miss += 1
                    continue
                k = int(round(np.sqrt(len(v))))          # 100 → 10×10；25 → 5×5
                blk_vals = v[:k * k].reshape(k, k)
                arr[tr * blk:tr * blk + blk, tc * blk:tc * blk + blk, idx] = blk_vals
    return arr, miss


def cmp_stat(name, rtl, gold):
    m = (rtl >= -9000)
    n = int(m.sum())
    d = np.abs(rtl[m].astype(np.int64) - gold[m].astype(np.int64))
    bad = int((d > 0).sum())
    return (name, n, bad, int(d.max()) if n else 0,
            (int(rtl[m].min()), int(rtl[m].max())) if n else (0, 0))


def save_png(arr, path, title=""):
    try:
        from PIL import Image
    except ImportError:
        return False
    x = np.asarray(arr, dtype=np.float64)
    lo, hi = float(x.min()), float(x.max())
    if hi <= lo:
        hi = lo + 1.0
    img = ((x - lo) / (hi - lo) * 255.0).astype(np.uint8)
    Image.fromarray(img, mode="L").resize((img.shape[1] * 3, img.shape[0] * 3),
                                           Image.NEAREST).save(path)
    return True


def main():
    os.makedirs(OUT, exist_ok=True)
    need = ["rtl_dump_plane_l1.txt", "rtl_dump_plane_l2.txt",
            "rtl_dump_l1_stage.txt", "rtl_dump_l2_stage.txt",
            "golden_l1_stages.npz", "golden_l2_stages.npz"]
    for n in need:
        p = os.path.join(HERE, n)
        if not os.path.exists(p):
            print("缺文件：%s" % p)
            print("  先跑：gen_stim.py  →  vsim -c -do rtl/conv2/sim/run_l2.do（DUMP_ALL=1）")
            return 1

    print("=" * 78)
    print("dump_all_report : 两层**全部**仿真数据（真实图 + 真实权重）")
    print("=" * 78)

    # ---------- ① 两块面 ----------
    l1 = plane_to_l1(read_plane(os.path.join(HERE, "rtl_dump_plane_l1.txt")))
    l2 = plane_to_l2(read_plane(os.path.join(HERE, "rtl_dump_plane_l2.txt")))
    g1 = np.load(os.path.join(HERE, "golden_out_plane.npy")).astype(np.int64)
    g2 = np.load(os.path.join(HERE, "golden_out_plane_l2.npy")).astype(np.int64)
    np.save(os.path.join(OUT, "L1_plane.npy"), l1.astype(np.int16))
    np.save(os.path.join(OUT, "L2_plane.npy"), l2.astype(np.int16))

    stats = []
    d = np.abs(l1 - g1)
    stats.append(("L1 输出面 (120,160,8)", l1.size, int((d > 0).sum()), int(d.max()),
                  (int(l1.min()), int(l1.max()))))
    d = np.abs(l2 - g2)
    stats.append(("L2 输出面 (80,60,16)", l2.size, int((d > 0).sum()), int(d.max()),
                  (int(l2.min()), int(l2.max()))))
    for s in stats:
        print("  %-22s 点 %7d  不一致 %6d  最大|差| %4d  范围 %s" % s)

    # ---------- ② 逐级全帧 ----------
    sl1 = read_stage(os.path.join(HERE, "rtl_dump_l1_stage.txt"))
    sl2 = read_stage(os.path.join(HERE, "rtl_dump_l2_stage.txt"))
    gl1 = np.load(os.path.join(HERE, "golden_l1_stages.npz"))
    gl2 = np.load(os.path.join(HERE, "golden_l2_stages.npz"))
    gkey = {"POOL": "pool"}

    def gname(st):
        return gkey.get(st, st.lower())

    # L1：tile 网格 24×32；DWC/QQ/BNQ 每块 10×10（240×320），POOL 每块 5×5（120×160）
    for (st, nch) in L1_STAGES:
        blk = 5 if st == "POOL" else 10
        arr, miss = assemble(sl1.get(st, {}), M.NTILE_R, M.NTILE_C, blk, nch)
        gold = gl1[gname(st)].astype(np.int64)
        stats.append(cmp_stat("L1 %s %s" % (st, arr.shape[:2]), arr, gold) + (miss,))
        for c in range(nch):
            save_png(arr[:, :, c], os.path.join(OUT, "L1_%s_%02d.png" % (st, c)))
    # L2：tile 网格 12×16；DWC/BNR/QQ/BNQ 每块 10×10（120×160），POOL 每块 5×5（60×80）
    for (st, nch) in L2_STAGES:
        blk = 5 if st == "POOL" else 10
        arr, miss = assemble(sl2.get(st, {}), M.L2_IH // 10, M.L2_IW // 10, blk, nch)
        gold = gl2[gname(st)].astype(np.int64)
        stats.append(cmp_stat("L2 %s %s" % (st, arr.shape[:2]), arr, gold) + (miss,))
        for c in range(nch):
            save_png(arr[:, :, c], os.path.join(OUT, "L2_%s_%02d.png" % (st, c)))

    print("-" * 78)
    print("  %-28s %8s %8s %8s %8s %6s" % ("级（全帧）", "点数", "不一致", "最大|差|", "范围", "缺行"))
    bad_all = 0
    for s in stats:
        # s = (name, n, bad, maxd, rng) 或 (name, n, bad, maxd, rng, miss)
        name, n, bad, maxd, rng = s[0], s[1], s[2], s[3], s[4]
        miss = s[5] if len(s) > 5 else 0
        bad_all += bad + miss
        print("  %-28s %8d %8d %8d %8s %6d" % (name, n, bad, maxd, str(rng), miss))

    # ---------- ③ xlsx ----------
    try:
        from openpyxl import Workbook
        wb = Workbook()
        ws = wb.active
        ws.title = "Summary"
        ws.append(["级（全帧）", "点数", "不一致", "最大|差|", "最小值", "最大值", "缺行"])
        for s in stats:
            name, n, bad, maxd, rng = s[0], s[1], s[2], s[3], s[4]
            miss = s[5] if len(s) > 5 else 0
            ws.append([name, n, bad, maxd, rng[0], rng[1], miss])
        wb.save(os.path.join(OUT, "feature_maps_dump_all.xlsx"))
        print("  写出 dump_all/feature_maps_dump_all.xlsx（+ L1/L2 各 stage 的 PNG、npy）")
    except ImportError:
        print("  （没装 openpyxl，跳过 xlsx）")

    print("-" * 78)
    print("  全部级合计：不一致 + 缺行 = %d" % bad_all)
    print("DUMP_ALL_REPORT RESULT: %s  (bad=%d)" % ("PASS" if bad_all == 0 else "FAIL", bad_all))
    return 0 if bad_all == 0 else 1


sys.exit(main())
