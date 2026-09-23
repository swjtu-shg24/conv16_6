# -*- coding: utf-8 -*-
"""eval_lianghua.py —— 评估 lianghua_infer.py 到底验了什么、没验什么

复现它的核心流程（只量化输入 → 整个网络用 float 跑 → 比最终输出），并和
"真正的定点链路（Q8 权重 + 三级 ±8 限位）"对比，看两者差多少。
"""
import importlib.util
import os

import numpy as np
import torch
from PIL import Image

import stim_model as M

HERE = M.HERE


def load_net(mod_file, cls_name, pth, ngf=8, n_blocks=9):
    spec = importlib.util.spec_from_file_location("m_" + cls_name, os.path.join(HERE, mod_file))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    net = getattr(mod, cls_name)(ngf=ngf, n_blocks=n_blocks)
    sd = torch.load(pth, map_location="cpu", weights_only=True)
    if any(k.startswith("module.") for k in sd):
        sd = {k.replace("module.", "", 1): v for k, v in sd.items()}
    net.load_state_dict(sd)
    return net


def metrics(y_ref, y):
    d = (y - y_ref).abs()
    mse = d.pow(2).mean().item()
    return d.max().item(), d.mean().item(), (10 * np.log10(4.0 / max(mse, 1e-12)) if mse > 0 else float("inf"))


def main():
    img = M.load_image()
    p = img.astype(np.uint8)
    x_base = p.astype(np.float32) / 127.5 - 1.0
    q_int = (p.astype(np.int32) - 124) >> 3
    x_q44 = q_int.astype(np.float32) / 16.0

    print("=" * 78)
    print("① lianghua_infer.py 的输入量化部分（这部分是对的）")
    print("=" * 78)
    d = np.abs(x_q44 - x_base)
    print("   q=(p-124)>>3 范围 %d..%d ✓ 与工程口径一致" % (q_int.min(), q_int.max()))
    print("   输入误差 max|d|=%.5f  mean|d|=%.6f   （它 log 里报的就是这两个数）" % (d.max(), d.mean()))

    net = load_net("lianghua_infer.py", "MobileResnetGenerator", M.PTH)
    tb = torch.from_numpy(x_base).permute(2, 0, 1)[None]
    tq = torch.from_numpy(x_q44).permute(2, 0, 1)[None]

    print()
    print("=" * 78)
    print("② 它跑的其实是**整网 float 推理**（没有权重量化、没有中间限位）")
    print("=" * 78)
    for mode in ("train", "eval"):
        getattr(net, mode)()
        with torch.no_grad():
            yb = net(tb).clone()
            yq = net(tq).clone()
        mx, mn, ps = metrics(yb, yq)
        print("   netG.%s()： 输入量化→整网输出  max|d|=%.5f  mean|d|=%.6f  PSNR=%.2f dB"
              % (mode, mx, mn, ps))

    # train / eval 两种模式下"基线输出"本身差多少
    net.train()
    with torch.no_grad():
        yb_train = net(tb).clone()
    net.eval()
    with torch.no_grad():
        yb_eval = net(tb).clone()
    mx, mn, ps = metrics(yb_eval, yb_train)
    print("\n   ★ netG.train() vs netG.eval() 的**基线输出**差：max|d|=%.4f mean|d|=%.4f（PSNR %.2f dB）"
          % (mx, mn, ps))
    print("     （train 模式下 BatchNorm 用**本张图自己的统计量**，不是 running_mean/var；")
    print("       FPGA 用的是 running_mean/var → 它这个设置和硬件不是一回事）")

    print()
    print("=" * 78)
    print("③ 真正的定点链路（Q8 权重 + 三级 ±8 限位）与本工程浮点参考的差")
    print("=" * 78)
    W = M.load_weights()
    st = M.stages(img, W, sat=True)
    fl = M.float_ref(img, W)

    print("   第 1 层（dw+pw+BN）输出，Q4.4 反量化 vs 浮点：")
    for name, mine, f in (("BN 输出(bnq)", st["bnq"] / 16.0, fl["bnf"]),
                          ("池化输出", st["out"] / 16.0, np.maximum(0.0, fl["outf"]))):
        dd = np.abs(mine - f)
        print("     %-12s max|d|=%.4f  mean|d|=%.4f   相关系数 %.4f"
              % (name, dd.max(), dd.mean(),
                 np.corrcoef(mine.reshape(-1), f.reshape(-1))[0, 1]))

    print("\n   而 lianghua_infer.py 完全没经过这条链路：")
    print("     · 权重仍是 float32（没有 round(w*256)）")
    print("     · 中间结果没有量化、没有 ±8 限位")
    print("     · 它测的是『只把输入换成 Q4.4、其余全 float』对**整网最终输出**的影响")


main()
