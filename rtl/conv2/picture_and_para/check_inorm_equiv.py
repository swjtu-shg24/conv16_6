# -*- coding: utf-8 -*-
"""check_inorm_equiv.py —— 确认"目标那一版"的口径

你的模型是 batch_size=1 训练的，BN 在 train 模式下干的事 = **逐样本逐通道**归一化
（统计量在整幅 H×W 上算）= InstanceNorm。这个脚本证明三者等价，方便把"目标版本"钉死：

    ① netG.train()          （你现在改回的版本）
    ② BatchNorm2d 换成 InstanceNorm2d + eval()   ← 确定性、无副作用，适合当基准
    ③ 纯浮点手算（可选的中间量核对）

跑法：
    & 'D:\\...\\envs\\cyclegan\\python.exe' rtl\\conv2\\picture_and_para\\check_inorm_equiv.py
"""
import os
import sys

import numpy as np
import torch
import torch.nn as nn

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import stim_model as M
import gen_fpga_image as G


def main():
    img = M.load_image()
    x = torch.from_numpy(img.astype(np.float32) / 127.5 - 1.0).permute(2, 0, 1)[None]

    print("=" * 78)
    print("check_inorm_equiv : netG.train()  vs  BatchNorm→InstanceNorm(eval)")
    print("=" * 78)

    # ① train() 模式（bs=1）
    net1 = G.load_net()
    net1.train()
    with torch.no_grad():
        y1 = net1(x).clone()

    # ② BatchNorm → InstanceNorm，eval
    net2 = G.bn_to_inorm(G.load_net())
    net2.eval()
    with torch.no_grad():
        y2 = net2(x).clone()

    d = (y1 - y2).abs()
    print("  整网输出：max|d| = %.3e   mean|d| = %.3e" % (float(d.max()), float(d.mean())))
    print("  → %s" % ("**等价**（差异只是浮点舍入）" if float(d.max()) < 1e-4
                      else "有差异，需要进一步查（例如 eps / unbiased 设置）"))

    # 逐层核对：L1 那三个中间量
    print()
    print("  逐层核对（取 L1）：")
    with torch.no_grad():
        n1, n2 = G.load_net(), G.bn_to_inorm(G.load_net())
        n1.train(); n2.eval()
        p1 = n1.model[1].depthwise(n1.model[0](x))
        p2 = n2.model[1].depthwise(n2.model[0](x))
        q1 = n1.model[1].pointwise(p1)
        q2 = n2.model[1].pointwise(p2)
        b1 = n1.model[2](q1)
        b2 = n2.model[2](q2)
    for nm, a, b in (("dw 输出", p1, p2), ("pw 输出", q1, q2), ("BN 输出", b1, b2)):
        print("     %-8s max|d| = %.3e" % (nm, float((a - b).abs().max())))

    # 手算 InstanceNorm 核对（第 0 个通道）
    with torch.no_grad():
        mu = q2.mean(dim=(2, 3), keepdim=True)
        var = q2.var(dim=(2, 3), unbiased=False, keepdim=True)
        g = n2.model[2].weight.view(1, -1, 1, 1)
        bb = n2.model[2].bias.view(1, -1, 1, 1)
        manual = (q2 - mu) / torch.sqrt(var + n2.model[2].eps) * g + bb
    print("     手算 IN vs 模块输出：max|d| = %.3e" % float((manual - b2).abs().max()))

    print()
    print("  结论：目标口径 = **实例归一化**（逐通道、在整幅 H×W 上算 μ/σ）")
    print("        基准建议用 ②（BN→IN + eval）：无副作用、可重复；① 的 train() 会更新 running 统计量。")


main()
