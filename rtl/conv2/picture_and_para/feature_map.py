# -*- coding: utf-8 -*-
"""feature_map.py —— 早期自检：按定点口径算 3 个 tile 的 DWC / PW 累加和 / Output，
一个 tile 一个 sheet 写进 feature_maps_3tiles.xlsx，用来看"某个中间值算得对不对"。

调用（★ 输出写在**当前目录**，所以进本目录再跑）：
    cd rtl\\conv2\\picture_and_para
    python feature_map.py
产物：feature_maps_3tiles.xlsx

说明：这是早期的分析脚本，**不参与** check_fixed_point 门禁；现行的逐级/全帧判据看
      make_table.py（RTL vs golden）和 dump_all_report.py（全帧）。
"""
import numpy as np
from numpy.lib.stride_tricks import sliding_window_view
from openpyxl import Workbook
from openpyxl.styles import PatternFill

IW, IH = 320, 240
ROWB = IW * 3
NBEAT = ROWB // 16
NTILE_R, NTILE_C = 24, 32
TILE_IN = 10
TILE_OUT = 5

TILES = [
    (0, 0),
    (12, 16),
    (23, 31),
]

wdw = np.array([(i % 9) + 1 for i in range(27)], dtype=np.int32)
wpw = np.array([(i % 3) + 1 for i in range(24)], dtype=np.int32)

print("生成输入...")
rr, cc = np.meshgrid(np.arange(IH), np.arange(IW), indexing='ij')
IN = np.zeros((IH, IW, 3), dtype=np.int32)
for ch in range(3):
    IN[:, :, ch] = (rr * 13 + cc * 7 + ch * 29) % 251

print("计算 DWC...")
padded = np.pad(IN, ((1, 1), (1, 1), (0, 0)), mode='reflect')
DWC_RAW = np.zeros((IH, IW, 3), dtype=np.int64)
for ch in range(3):
    w = wdw[ch*9:(ch+1)*9].reshape(3, 3)
    windows = sliding_window_view(padded[:, :, ch], (3, 3))
    DWC_RAW[:, :, ch] = (windows * w).sum(axis=(2, 3))
DWC = np.clip((DWC_RAW + 128) >> 8, 0, 255).astype(np.uint8)

print("计算 PW 累加和 + Q...")
PW_SUM = np.zeros((IH, IW, 8), dtype=np.int64)
Q      = np.zeros((IH, IW, 8), dtype=np.uint8)
for oc in range(8):
    s = np.zeros((IH, IW), dtype=np.int64)
    for ch in range(3):
        s += DWC[:, :, ch].astype(np.int64) * int(wpw[oc*3 + ch])
    PW_SUM[:, :, oc] = s
    Q[:, :, oc] = np.clip((s + 128) >> 8, 0, 255).astype(np.uint8)

print("计算 Output...")
OH, OW = IH // 2, IW // 2
OUT = np.zeros((OH, OW, 8), dtype=np.uint8)
for oc in range(8):
    a  = Q[0::2, 0::2, oc]
    b  = Q[0::2, 1::2, oc]
    c_ = Q[1::2, 0::2, oc]
    d  = Q[1::2, 1::2, oc]
    OUT[:, :, oc] = np.maximum(np.maximum(a, b), np.maximum(c_, d))

HEADER_FILL    = PatternFill(start_color="DDEBF7", end_color="DDEBF7", fill_type="solid")
HEX_TAG_FILL   = PatternFill(start_color="FFF2CC", end_color="FFF2CC", fill_type="solid")
PAD_TAG_FILL   = PatternFill(start_color="E2EFDA", end_color="E2EFDA", fill_type="solid")
PAD_TAG_FILL2  = PatternFill(start_color="FCE4D6", end_color="FCE4D6", fill_type="solid")
CONV_TAG_FILL  = PatternFill(start_color="D9E1F2", end_color="D9E1F2", fill_type="solid")
CONV_TAG_FILL2 = PatternFill(start_color="E4DFEC", end_color="E4DFEC", fill_type="solid")
QUANT_TAG_FILL = PatternFill(start_color="C6E0B4", end_color="C6E0B4", fill_type="solid")
QUANT_TAG_FILL2= PatternFill(start_color="FFE699", end_color="FFE699", fill_type="solid")
PW_TAG_FILL    = PatternFill(start_color="F8CBAD", end_color="F8CBAD", fill_type="solid")
PW_TAG_FILL2   = PatternFill(start_color="D6DCE4", end_color="D6DCE4", fill_type="solid")
PAD_FILL       = PatternFill(start_color="F2F2F2", end_color="F2F2F2", fill_type="solid")


def write_layer_sheet(wb, sheet_name, arr3d):
    ws = wb.create_sheet(sheet_name[:31])
    H, W, C = arr3d.shape
    gap = 1
    block_w = W + 1
    for c in range(C):
        col0 = c * (block_w + gap) + 1
        ws.cell(row=1, column=col0, value=f"ch{c} DEC").fill = HEADER_FILL
        ws.cell(row=1, column=col0 + 1, value="y\\x").fill = HEADER_FILL
        for x in range(W):
            ws.cell(row=1, column=col0 + 2 + x, value=x).fill = HEADER_FILL
        for y in range(H):
            ws.cell(row=2 + y, column=col0 + 1, value=y).fill = HEADER_FILL
            for x in range(W):
                ws.cell(row=2 + y, column=col0 + 2 + x, value=int(arr3d[y, x, c]))
        r0 = H + 3
        ws.cell(row=r0, column=col0, value=f"ch{c} HEX").fill = HEX_TAG_FILL
        ws.cell(row=r0, column=col0 + 1, value="y\\x").fill = HEX_TAG_FILL
        for x in range(W):
            ws.cell(row=r0, column=col0 + 2 + x, value=x).fill = HEX_TAG_FILL
        for y in range(H):
            ws.cell(row=r0 + 1 + y, column=col0 + 1, value=y).fill = HEX_TAG_FILL
            for x in range(W):
                v = int(arr3d[y, x, c])
                ws.cell(row=r0 + 1 + y, column=col0 + 2 + x, value=f"0x{v:02X}")


def write_input_sheet(wb, sheet_name, raw3d, pad3d, conv_raw3d, quant3d, pwsum3d):
    """
    输入层：3 个输入通道块（每块 8 段）+ 8 个 oc PWSUM 块（每块 2 段）
    输入块 8 段：DEC / HEX / PAD_DEC / PAD_HEX / CONV_DEC / CONV_HEX / QUANT_DEC / QUANT_HEX
    PWSUM 块 2 段：PWSUM_DEC / PWSUM_HEX
    """
    ws = wb.create_sheet(sheet_name[:31])
    H, W, C_in = raw3d.shape
    Hp, Wp, _ = pad3d.shape
    C_pw = pwsum3d.shape[2]
    gap = 1
    block_w = max(W, Wp) + 1

    # ---- 3 个输入通道块 ----
    for c in range(C_in):
        col0 = c * (block_w + gap) + 1

        # 段1 DEC
        ws.cell(row=1, column=col0, value=f"ch{c} DEC").fill = HEADER_FILL
        ws.cell(row=1, column=col0 + 1, value="y\\x").fill = HEADER_FILL
        for x in range(W):
            ws.cell(row=1, column=col0 + 2 + x, value=x).fill = HEADER_FILL
        for y in range(H):
            ws.cell(row=2 + y, column=col0 + 1, value=y).fill = HEADER_FILL
            for x in range(W):
                ws.cell(row=2 + y, column=col0 + 2 + x, value=int(raw3d[y, x, c]))

        # 段2 HEX
        r0 = H + 3
        ws.cell(row=r0, column=col0, value=f"ch{c} HEX").fill = HEX_TAG_FILL
        ws.cell(row=r0, column=col0 + 1, value="y\\x").fill = HEX_TAG_FILL
        for x in range(W):
            ws.cell(row=r0, column=col0 + 2 + x, value=x).fill = HEX_TAG_FILL
        for y in range(H):
            ws.cell(row=r0 + 1 + y, column=col0 + 1, value=y).fill = HEX_TAG_FILL
            for x in range(W):
                v = int(raw3d[y, x, c])
                ws.cell(row=r0 + 1 + y, column=col0 + 2 + x, value=f"0x{v:02X}")

        # 段3 PAD_DEC
        r1 = r0 + H + 2
        ws.cell(row=r1, column=col0, value=f"ch{c} PAD_DEC").fill = PAD_TAG_FILL
        ws.cell(row=r1, column=col0 + 1, value="y\\x").fill = PAD_TAG_FILL
        for x in range(Wp):
            ws.cell(row=r1, column=col0 + 2 + x, value=x).fill = PAD_TAG_FILL
        for y in range(Hp):
            ws.cell(row=r1 + 1 + y, column=col0 + 1, value=y).fill = PAD_TAG_FILL
            for x in range(Wp):
                cell = ws.cell(row=r1 + 1 + y, column=col0 + 2 + x,
                               value=int(pad3d[y, x, c]))
                if y == 0 or y == Hp - 1 or x == 0 or x == Wp - 1:
                    cell.fill = PAD_FILL

        # 段4 PAD_HEX
        r2 = r1 + Hp + 2
        ws.cell(row=r2, column=col0, value=f"ch{c} PAD_HEX").fill = PAD_TAG_FILL2
        ws.cell(row=r2, column=col0 + 1, value="y\\x").fill = PAD_TAG_FILL2
        for x in range(Wp):
            ws.cell(row=r2, column=col0 + 2 + x, value=x).fill = PAD_TAG_FILL2
        for y in range(Hp):
            ws.cell(row=r2 + 1 + y, column=col0 + 1, value=y).fill = PAD_TAG_FILL2
            for x in range(Wp):
                v = int(pad3d[y, x, c])
                cell = ws.cell(row=r2 + 1 + y, column=col0 + 2 + x, value=f"0x{v:02X}")
                if y == 0 or y == Hp - 1 or x == 0 or x == Wp - 1:
                    cell.fill = PAD_FILL

        # 段5 CONV_DEC
        r3 = r2 + Hp + 2
        ws.cell(row=r3, column=col0, value=f"ch{c} CONV_DEC").fill = CONV_TAG_FILL
        ws.cell(row=r3, column=col0 + 1, value="y\\x").fill = CONV_TAG_FILL
        for x in range(W):
            ws.cell(row=r3, column=col0 + 2 + x, value=x).fill = CONV_TAG_FILL
        for y in range(H):
            ws.cell(row=r3 + 1 + y, column=col0 + 1, value=y).fill = CONV_TAG_FILL
            for x in range(W):
                ws.cell(row=r3 + 1 + y, column=col0 + 2 + x, value=int(conv_raw3d[y, x, c]))

        # 段6 CONV_HEX
        r4 = r3 + H + 2
        ws.cell(row=r4, column=col0, value=f"ch{c} CONV_HEX").fill = CONV_TAG_FILL2
        ws.cell(row=r4, column=col0 + 1, value="y\\x").fill = CONV_TAG_FILL2
        for x in range(W):
            ws.cell(row=r4, column=col0 + 2 + x, value=x).fill = CONV_TAG_FILL2
        for y in range(H):
            ws.cell(row=r4 + 1 + y, column=col0 + 1, value=y).fill = CONV_TAG_FILL2
            for x in range(W):
                v = int(conv_raw3d[y, x, c])
                ws.cell(row=r4 + 1 + y, column=col0 + 2 + x, value=f"0x{(v & 0xFFFFFF):06X}")

        # 段7 QUANT_DEC
        r5 = r4 + H + 2
        ws.cell(row=r5, column=col0, value=f"ch{c} QUANT_DEC").fill = QUANT_TAG_FILL
        ws.cell(row=r5, column=col0 + 1, value="y\\x").fill = QUANT_TAG_FILL
        for x in range(W):
            ws.cell(row=r5, column=col0 + 2 + x, value=x).fill = QUANT_TAG_FILL
        for y in range(H):
            ws.cell(row=r5 + 1 + y, column=col0 + 1, value=y).fill = QUANT_TAG_FILL
            for x in range(W):
                ws.cell(row=r5 + 1 + y, column=col0 + 2 + x, value=int(quant3d[y, x, c]))

        # 段8 QUANT_HEX
        r6 = r5 + H + 2
        ws.cell(row=r6, column=col0, value=f"ch{c} QUANT_HEX").fill = QUANT_TAG_FILL2
        ws.cell(row=r6, column=col0 + 1, value="y\\x").fill = QUANT_TAG_FILL2
        for x in range(W):
            ws.cell(row=r6, column=col0 + 2 + x, value=x).fill = QUANT_TAG_FILL2
        for y in range(H):
            ws.cell(row=r6 + 1 + y, column=col0 + 1, value=y).fill = QUANT_TAG_FILL2
            for x in range(W):
                v = int(quant3d[y, x, c])
                ws.cell(row=r6 + 1 + y, column=col0 + 2 + x, value=f"0x{v:02X}")

    # ---- 8 个 oc PWSUM 块，接在输入通道块之后 ----
    for oc in range(C_pw):
        col0 = (C_in + oc) * (block_w + gap) + 1

        # DEC
        ws.cell(row=1, column=col0, value=f"oc{oc} PWSUM_DEC").fill = PW_TAG_FILL
        ws.cell(row=1, column=col0 + 1, value="y\\x").fill = PW_TAG_FILL
        for x in range(W):
            ws.cell(row=1, column=col0 + 2 + x, value=x).fill = PW_TAG_FILL
        for y in range(H):
            ws.cell(row=2 + y, column=col0 + 1, value=y).fill = PW_TAG_FILL
            for x in range(W):
                ws.cell(row=2 + y, column=col0 + 2 + x, value=int(pwsum3d[y, x, oc]))

        # HEX
        r0 = H + 3
        ws.cell(row=r0, column=col0, value=f"oc{oc} PWSUM_HEX").fill = PW_TAG_FILL2
        ws.cell(row=r0, column=col0 + 1, value="y\\x").fill = PW_TAG_FILL2
        for x in range(W):
            ws.cell(row=r0, column=col0 + 2 + x, value=x).fill = PW_TAG_FILL2
        for y in range(H):
            ws.cell(row=r0 + 1 + y, column=col0 + 1, value=y).fill = PW_TAG_FILL2
            for x in range(W):
                v = int(pwsum3d[y, x, oc])
                ws.cell(row=r0 + 1 + y, column=col0 + 2 + x,
                        value=f"0x{(v & 0xFFFFFF):06X}")


def tile_slice(arr3d, tr, tc, size):
    return arr3d[tr*size:(tr+1)*size, tc*size:(tc+1)*size, :]


wb = Workbook()
wb.remove(wb.active)

ws_p = wb.create_sheet("Params")
ws_p.append(["参数", "值", "说明"])
ws_p.append(["IW", IW, "图像宽度"])
ws_p.append(["IH", IH, "图像高度"])
ws_p.append(["ROWB", ROWB, "每行字节 = IW*3"])
ws_p.append(["NBEAT", NBEAT, "每行 128bit beat 数"])
ws_p.append(["NTILE_R", NTILE_R, "tile 行数"])
ws_p.append(["NTILE_C", NTILE_C, "tile 列数"])
ws_p.append(["tile 尺寸", "10x10", "池化后 5x5"])
ws_p.append(["输入公式", "(r*13 + c*7 + ch*29) % 251", ""])
ws_p.append(["wdw", "(wi%9)+1, wi=0..26", "3ch x 3x3 深度卷积"])
ws_p.append(["wpw", "(wi%3)+1, wi=0..23", "8oc x 3ic 点卷积"])
ws_p.append(["DW 量化", "(s + 128) >> 8, clamp 0..255", "通道内 3x3 累加"])
ws_p.append(["PW 累加", "Σ_ch dwc[ch]*w_pw[oc][ch]", "跨通道累加"])
ws_p.append(["PW 量化", "(s + 128) >> 8, clamp 0..255", "得到 Q"])
ws_p.append(["导出 tile", str(TILES), "第一个 / 最中间 / 最后一个"])
ws_p.append(["IN sheet", "3 输入块（各 8 段）+ 8 个 oc PWSUM 块（各 2 段）", ""])

ws_w = wb.create_sheet("Weights")
ws_w.append(["wdw[0..26]  3ch x 3x3"])
ws_w.append(["idx", "value", "ch", "kh", "kw"])
for i in range(27):
    ws_w.append([i, int(wdw[i]), i // 9, (i % 9) // 3, i % 3])
ws_w.append([])
ws_w.append(["wpw[0..23]  8oc x 3ic"])
ws_w.append(["idx", "value", "oc", "ic"])
for i in range(24):
    ws_w.append([i, int(wpw[i]), i // 3, i % 3])

for tr, tc in TILES:
    tin = tile_slice(IN, tr, tc, TILE_IN)
    y0 = tr * TILE_IN
    x0 = tc * TILE_IN
    tin_pad      = padded[y0:y0 + TILE_IN + 2, x0:x0 + TILE_IN + 2, :]
    tin_conv_raw = DWC_RAW[tr*TILE_IN:(tr+1)*TILE_IN, tc*TILE_IN:(tc+1)*TILE_IN, :]
    tin_quant    = DWC[tr*TILE_IN:(tr+1)*TILE_IN, tc*TILE_IN:(tc+1)*TILE_IN, :]
    tpwsum       = PW_SUM[tr*TILE_IN:(tr+1)*TILE_IN, tc*TILE_IN:(tc+1)*TILE_IN, :]
    tdwc         = tile_slice(DWC, tr, tc, TILE_IN)
    tq           = tile_slice(Q,   tr, tc, TILE_IN)
    tout         = tile_slice(OUT, tr, tc, TILE_OUT)

    write_input_sheet(wb, f"IN_t{tr:02d}_{tc:02d}", tin, tin_pad, tin_conv_raw, tin_quant, tpwsum)
    write_layer_sheet(wb, f"DWC_t{tr:02d}_{tc:02d}", tdwc)
    write_layer_sheet(wb, f"Q_t{tr:02d}_{tc:02d}",   tq)
    write_layer_sheet(wb, f"OUT_t{tr:02d}_{tc:02d}", tout)
    print(f"  tile({tr:02d},{tc:02d}) 完成  当前 sheet 数 = {len(wb.sheetnames)}")

wb.save("feature_maps_3tiles.xlsx")
print(f"\n完成。sheet 总数 = {len(wb.sheetnames)}")
print("输出: feature_maps_3tiles.xlsx")