# -*- coding: utf-8 -*-
"""inorm_granularity_test.py —— 实例归一化的"统计粒度"对精度的影响

真实 InstanceNorm 是把 μ/σ 在**整幅 H×W**（240×320）上逐通道算的。
硬件上要精确复现就得先扫一遍拿统计量（两遍法）；如果按更小的块统计就能省一次扫描。
这个脚本量三种粒度的差别，用来定架构：

    global : 整幅 240×320 逐通道            → 精确 IN，需要两遍扫描（或缓存整幅 4.9 Mbit）
    row    : 每个 tile 行（10×320）逐通道    → 需要缓存 10 行 qq（8×3200×8bit = 204 kbit ≈ 20 片 BRAM）
    tile   : 每个 tile（10×10）逐通道        → 不需要额外扫描，只要 tile 内 100 点的缓冲（最小）

参考 = 浮点 L1（整幅 IN）+ 其余层浮点。

跑法：
    & 'D:\\...\\envs\\cyclegan\\python.exe' rtl\\conv2\\picture_and_para\\inorm_granularity_test.py
"""
import os
import sys

import numpy as np
import torch
import torch.nn.functional as F

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import stim_model as M
import gen_fpga_image as G

EPS = 1e-5
LSB = 1.0 / 16.0


def l1_fixed(net, x_int, mode="global", dw_mul=1, region_rows=10):
    """RTL 整数口径的 L1，IN 的统计量按 mode 分组算"""
    xf = x_int.double()
    pad = F.pad(xf, (1, 1, 1, 1), mode="reflect")
    wdw = torch.round(net.model[1].depthwise.weight.detach().double() * 256) * dw_mul
    wpw = torch.round(net.model[1].pointwise.weight.detach().double() * 256)
    dwc = ((F.conv2d(pad, wdw, groups=3) + 128) // 256).clamp(-128, 127)
    qq = ((F.conv2d(dwc, wpw) + 128) // 256).clamp(-128, 127)          # (1,8,240,320)

    m = net.model[2]
    g = m.weight.detach().double().view(1, -1, 1, 1)
    b = m.bias.detach().double().view(1, -1, 1, 1)
    sc_reg = 16.0 * dw_mul

    if mode == "global":
        mu = qq.mean(dim=(2, 3), keepdim=True) / sc_reg
        var = qq.var(dim=(2, 3), unbiased=False, keepdim=True) / (sc_reg ** 2)
    elif mode == "row":
        n = qq.shape[2] // region_rows
        z = qq.view(1, 8, n, region_rows, qq.shape[3])
        mu = z.mean(dim=(3, 4), keepdim=True).view(1, 8, n, 1, 1) / sc_reg
        var = z.var(dim=(3, 4), unbiased=False, keepdim=True).view(1, 8, n, 1, 1) / (sc_reg ** 2)
        mu = mu.expand(1, 8, n, region_rows, qq.shape[3]).reshape(1, 8, qq.shape[2], qq.shape[3])
        var = var.expand(1, 8, n, region_rows, qq.shape[3]).reshape(1, 8, qq.shape[2], qq.shape[3])
    elif mode == "tile":
        n = qq.shape[2] // region_rows          # 24
        w = qq.shape[3] // region_rows          # 32
        z = qq.view(1, 8, n, region_rows, w, region_rows)
        mu = z.mean(dim=(3, 5), keepdim=True) / sc_reg
        var = z.var(dim=(3, 5), unbiased=False, keepdim=True) / (sc_reg ** 2)
        mu = mu.expand(1, 8, n, region_rows, w, region_rows).reshape(1, 8, qq.shape[2], qq.shape[3])
        var = var.expand(1, 8, n, region_rows, w, region_rows).reshape(1, 8, qq.shape[2], qq.shape[3])
    else:
        raise ValueError(mode)

    scale = g / torch.sqrt(var + EPS)
    shift = b - mu * scale
    a_q = torch.round(scale * 256 / dw_mul)
    b_q = torch.round(shift * 4096)
    bnq = torch.clamp(((a_q * qq + b_q) // 256), 0, 127)
    return (F.max_pool2d(bnq, 2, 2) / 16.0).float()


def main():
    img = M.load_image()
    net = G.bn_to_inorm(G.load_net())
    q_int = torch.from_numpy(((img.astype(np.int64) - 124) >> 3).astype(np.int64)).permute(2, 0, 1)[None]
    x_q44 = q_int.float() / 16.0
    x_base = torch.from_numpy(img.astype(np.float32) / 127.5 - 1.0).permute(2, 0, 1)[None]

    with torch.no_grad():
        l1_ref = net.model[0:5](x_q44).clone()        # 浮点 L1（整幅 IN）
        y_ref = net.model[5:](l1_ref).clone()
        y_base = net(x_base).clone()

    print("=" * 84)
    print("实例归一化统计粒度的影响（L1 全部定点，其余层浮点）")
    print("=" * 84)
    print("  %-10s | %-22s | %10s | %10s | %10s" %
          ("粒度", "硬件代价", "L1 mean|d|", "L1 max|d|", "最终图 PSNR"))
    print("  " + "-" * 80)
    rows = [("global", "两遍扫描（或 4.9 Mbit 缓存）"),
            ("row", "缓存 10 行（≈20 片 BRAM）"),
            ("tile", "只要 tile 内 100 点缓冲（最小）")]
    for mode, cost in rows:
        l1 = l1_fixed(net, q_int, mode=mode)
        with torch.no_grad():
            y = net.model[5:](l1)
        d = (l1 - l1_ref).abs()
        print("  %-10s | %-22s | %7.4f LSB      | %7.4f LSB | %6.2f dB"
              % (mode, cost, float(d.mean()) / LSB, float(d.max()) / LSB, G.psnr(y, y_base)))

    print()
    print("  注：参考 = 整幅 IN 的**浮点** L1；最终图 PSNR 以浮点基线为准（B 只量化输入 = 31.24 dB）")


main()
