# -*- coding: utf-8 -*-
"""gen_fpga_image.py —— 生成"定点计算"的最终图像，供肉眼对比

★ 归一化用**实例归一化**：模型是 batch_size=1 训练的，BatchNorm 的 running_mean/var
  等于最后一张训练图的统计量，本来就不对。bs=1 训练时 BN 干的事就是**逐样本逐通道**归一化
  = InstanceNorm，所以这里把所有 BatchNorm2d 换成 InstanceNorm2d（γ/β 照抄）。

四张图：
    A 基线        ：全浮点 + 实例归一化           x = 2p/255 - 1
    B 只量化输入  ：输入 Q4.4，其余全浮点
    C ★L1 定点    ：L1（dw+pw+BN+ReLU+pool）用 **RTL 整数口径**算，其余层浮点
    D 全定点      ：所有层 Q8.8 权重 + Q4.4 激活（hook），实例归一化

产物：rtl/conv2/picture_and_para/fpga_images/*.png + 指标写在 fpga_image_log.txt

跑法：
    & 'D:\\...\\envs\\cyclegan\\python.exe' rtl\\conv2\\picture_and_para\\gen_fpga_image.py
"""
import importlib.util
import os
import sys

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
from PIL import Image, ImageDraw

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import stim_model as M

HERE = M.HERE
OUT = os.path.join(HERE, "fpga_images")
EPS = 1e-5


_NETMOD = [None]


def load_net():
    spec = importlib.util.spec_from_file_location("lh_net", os.path.join(HERE, "cyclegna_mobilenet.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    _NETMOD[0] = mod
    net = mod.MobileResnetGenerator(ngf=8, n_blocks=9)
    sd = torch.load(M.PTH, map_location="cpu", weights_only=True)
    net.load_state_dict(sd)
    net.eval()
    return net


def bn_to_inorm(net):
    """把所有 BatchNorm2d 换成 InstanceNorm2d（γ/β 照抄）—— 对应 bs=1 训练时的实际行为"""
    def rec(module):
        for name, child in module.named_children():
            if isinstance(child, nn.BatchNorm2d):
                new = nn.InstanceNorm2d(child.num_features, eps=child.eps,
                                        momentum=0.0, affine=True, track_running_stats=False)
                with torch.no_grad():
                    new.weight.copy_(child.weight)
                    new.bias.copy_(child.bias)
                new.eval()
                setattr(module, name, new)
            else:
                rec(child)
    rec(net)
    return net


def q44_int(x):                      # x: float tensor（实际值）→ Q4.4 整数 tensor
    return torch.round(x * 16).clamp(-128, 127)


def to_img(t):                       # (1,3,H,W) in [-1,1] → PIL
    a = t[0].detach().cpu().numpy().transpose(1, 2, 0)
    return Image.fromarray(((a * 0.5 + 0.5).clip(0, 1) * 255).astype(np.uint8))


def psnr(a, b, rng=2.0):
    mse = float(((a - b) ** 2).mean())
    return 10 * np.log10(rng ** 2 / max(mse, 1e-12))


def l1_fixed_forward(net, x_int, dw_mul=1):
    """L1（model[0..4]）用 RTL 整数口径算，返回反量化后的 (1,8,120,160) float tensor。

    x_int : (1,3,240,320) Q4.4 整数（实际值 = /16）
    dw_mul: 增益重分配倍数（1 = 现状，全部增益在 BN 里；8 = dw 权重 ×8、A_q ÷8）
    口径  : dw/pw = clip((Σ+128)>>8, -128,127)
            IN    = A_q=round(scale*256/dw_mul), B_q=round(shift*4096),
                    bnq = clip((A_q*qq+B_q)>>8, 0,127)（scale/shift 用**本图**的实例统计量）
            pool  = 2×2 max（有符号）
    """
    xf = x_int.double()
    pad = F.pad(xf, (1, 1, 1, 1), mode="reflect")                     # ReflectionPad2d(1)
    wdw = torch.round(net.model[1].depthwise.weight.detach().double() * 256) * dw_mul
    wpw = torch.round(net.model[1].pointwise.weight.detach().double() * 256)
    dw_sum = F.conv2d(pad, wdw, groups=3)
    dwc = ((dw_sum + 128) // 256).clamp(-128, 127)                    # 对称饱和
    pw_sum = F.conv2d(dwc, wpw)
    qq = ((pw_sum + 128) // 256).clamp(-128, 127)

    inorm = net.model[2]                                             # InstanceNorm2d
    g = inorm.weight.detach().double().view(1, -1, 1, 1)
    b = inorm.bias.detach().double().view(1, -1, 1, 1)
    # ★ 实例统计量必须在**实际值**域里算（qq 寄存器值 = 16*dw_mul × 实际值）
    sc_reg = 16.0 * dw_mul
    mu = qq.mean(dim=(2, 3), keepdim=True) / sc_reg
    var = qq.var(dim=(2, 3), unbiased=False, keepdim=True) / (sc_reg ** 2)
    scale = g / torch.sqrt(var + EPS)                                # = gamma/sigma，实际值域
    shift = b - mu * scale
    a_q = torch.round(scale * 256 / dw_mul)                          # qq 已放大 dw_mul 倍
    b_q = torch.round(shift * 4096)                                  # 加性 bias 的标度不变
    bnq = torch.clamp(((a_q * qq + b_q) // 256), 0, 127)              # floor + ReLU + 上限

    pool = F.max_pool2d(bnq, 2, 2)
    return (pool / 16.0).float()                                      # 反量化成实际值


class QuantHook:
    """把每个子模块的输出量化到 Q4.4（返回量化后的张量，后续层真的用它继续算）
    extra_types：额外要挂的模块类型（lianghua_infer.py 还挂了 DepthwiseSeparableConv 包装类，
                 因为残差相加 out = out + x 发生在包装类里，不挂它那一步就不量化）
    """
    def __init__(self, net, extra_types=()):
        base = (nn.Conv2d, nn.ConvTranspose2d, nn.BatchNorm2d, nn.InstanceNorm2d, nn.ReLU,
                nn.MaxPool2d, nn.ReflectionPad2d, nn.Tanh) + tuple(extra_types)
        self.h = []
        self.stat = [0, 0]          # [撞 ±8 clamp 的元素数, 总数]
        for name, m in net.named_modules():
            if name == "":
                continue
            if isinstance(m, base):
                self.h.append(m.register_forward_hook(self._mk(self.stat)))

    @staticmethod
    def _mk(stat):
        def hook(module, inp, out):
            if not isinstance(out, torch.Tensor):
                return out
            stat[0] += int(((out < -8.0) | (out > 8.0 - 1 / 16)).sum().item())
            stat[1] += out.numel()
            return torch.round(out * 16).clamp(-128, 127) / 16
        return hook

    def detach(self):
        for h in self.h:
            h.remove()
        self.h = []


def quant_weights_q8(net):
    """权重 Q8（8 位小数）：round(w*256)/256。
    ★ clamp 的必须是 **实际值 ±128**（= 整数 ±32768），不是整数 ±128 ——
      写成整数 ±128 会把所有 |w|>0.5 的权重削到 0.5（含 BN 的 γ≈1.06 → 0.5），图会废掉。
    """
    with torch.no_grad():
        for p in net.parameters():
            p.copy_(torch.round(p * 256).clamp(-32768 * 1.0, 32767.0) / 256)


def main():
    os.makedirs(OUT, exist_ok=True)
    img = M.load_image()
    p8 = img.astype(np.uint8)

    x_base = torch.from_numpy(p8.astype(np.float32) / 127.5 - 1.0).permute(2, 0, 1)[None]
    q_int = torch.from_numpy(((img.astype(np.int64) - 124) >> 3).astype(np.int64)).permute(2, 0, 1)[None]
    x_q44 = (q_int.float() / 16.0)

    # ---------- 实例归一化那一组 ----------
    net = bn_to_inorm(load_net())
    n_in = sum(1 for m in net.modules() if isinstance(m, nn.InstanceNorm2d))
    print("=" * 78)
    print("gen_fpga_image : 定点推理出图")
    print("=" * 78)
    print("  实例归一化组：已把 %d 个 BatchNorm2d 换成 InstanceNorm2d（γ/β 照抄）" % n_in)

    with torch.no_grad():
        yA = net(x_base).clone()                                     # A 基线：全浮点
        yB = net(x_q44).clone()                                      # B 只量化输入
        yC = net.model[5:](l1_fixed_forward(net, q_int, dw_mul=1)).clone()   # C L1 定点（现状增益）
        yE = net.model[5:](l1_fixed_forward(net, q_int, dw_mul=8)).clone()   # E L1 定点 + 增益 ×8

    netD = bn_to_inorm(load_net())
    quant_weights_q8(netD)
    hk = QuantHook(netD)
    with torch.no_grad():
        yD = netD(x_q44).clone()                                     # D 全层定点 + 实例归一化
    hk.detach()

    # ---------- lianghua_infer.py 那一组：BatchNorm(eval) + 全层定点 ----------
    netF = load_net()                                                # 不换 IN，保留 BatchNorm
    mod = _NETMOD[0]                                                 # ★ 必须在 load_net() **之后**取：
    #    load_net() 每次都会重新 exec 一遍模块，得到**不同的类对象**；
    #    先取 mod 再 load_net() 的话 isinstance(子模块, mod.DepthwiseSeparableConv) 会是 False
    #    → 少挂包装类的 hook → 残差相加那一步不量化 → 结果对不上 lianghua_infer.py
    with torch.no_grad():
        yAbn = netF(x_base).clone()                                  # 它的基线：**浮点**（无 hook）
    quant_weights_q8(netF)
    hkF = QuantHook(netF, extra_types=(mod.DepthwiseSeparableConv, mod.DepthwiseSeparableConv2d))
    with torch.no_grad():
        yF = netF(x_q44).clone()                                     # F = lianghua_infer 阶段2
    n_hook = len(hkF.h)
    hkF.detach()
    print("  F: 挂了 %d 个 hook（lianghua_infer.py 自己报的是 87 个）" % n_hook)
    print("  F 的激活撞 ±8 clamp：%d / %d = %.2f%%   (D 的：%d / %d = %.2f%%)"
          % (hkF.stat[0], hkF.stat[1], 100.0 * hkF.stat[0] / max(hkF.stat[1], 1),
             hk.stat[0], hk.stat[1], 100.0 * hk.stat[0] / max(hk.stat[1], 1)))

    print()
    print("  对比（PSNR 都以各自那组的浮点基线为参考）")
    ims = [("A_baseline_inorm", yA, yA), ("B_input_q44_only", yB, yA),
           ("C_L1_fixed_inorm", yC, yA), ("E_L1_fixed_gain8", yE, yA),
           ("D_all_fixed_inorm", yD, yA)]
    log = ["定点推理出图", "=" * 70, "",
           "%-30s %10s %10s %10s" % ("对比", "max|d|", "mean|d|", "PSNR(dB)")]
    for name, y, ref in ims:
        to_img(y).save(os.path.join(OUT, name + ".png"))
        if name != "A_baseline_inorm":
            d = (y - ref).abs()
            line = "  %-24s max|d|=%.4f  mean|d|=%.5f  PSNR=%.2f dB" % (
                name, float(d.max()), float(d.mean()), psnr(y, ref))
            print(line)
            log.append("%-30s %10.4f %10.5f %10.2f" % (name, float(d.max()), float(d.mean()), psnr(y, ref)))

    print()
    print("  lianghua_infer.py 那一组（BatchNorm eval + 全层定点）")
    d = (yF - yAbn).abs()
    print("  %-24s max|d|=%.4f  mean|d|=%.5f  PSNR=%.2f dB" % (
        "F_all_fixed_batchnorm", float(d.max()), float(d.mean()), psnr(yF, yAbn)))
    log.append("%-30s %10.4f %10.5f %10.2f" % ("F_all_fixed_batchnorm(its baseline)",
                                               float(d.max()), float(d.mean()), psnr(yF, yAbn)))
    to_img(yAbn).save(os.path.join(OUT, "A2_baseline_batchnorm.png"))
    to_img(yF).save(os.path.join(OUT, "F_all_fixed_batchnorm.png"))
    print("  另外：两种归一化的**浮点**基线本身差 %.4f（max|d|），PSNR %.2f dB"
          % (float((yAbn - yA).abs().max()), psnr(yAbn, yA)))
    log.append("B站：Batchnorm基线 vs InstanceNorm基线 max|d|=%.4f PSNR=%.2f" %
               (float((yAbn - yA).abs().max()), psnr(yAbn, yA)))

    # 拼图 1（实例归一化那组）
    W, H = 320, 240
    pad, lab = 8, 22
    panels = [Image.fromarray(p8), to_img(yA), to_img(yC), to_img(yE), to_img(yD)]
    labels = ["original", "A: float baseline(IN)", "C: L1 fixed (as is)",
              "E: L1 fixed (gain x8)", "D: all fixed-point(IN)"]
    canvas = Image.new("RGB", (len(panels) * (W + 2 * pad), H + lab + 2 * pad), (255, 255, 255))
    dr = ImageDraw.Draw(canvas)
    for i, (lb, src) in enumerate(zip(labels, panels)):
        x = i * (W + 2 * pad) + pad
        dr.text((x + 2, pad), lb, fill=(0, 0, 0))
        canvas.paste(src, (x, pad + lab))
    canvas.save(os.path.join(OUT, "00_side_by_side.png"))

    # 拼图 2（lianghua_infer.py 那一组）
    panels2 = [Image.fromarray(p8), to_img(yAbn), to_img(yF), to_img(yD)]
    labels2 = ["original", "A2: float baseline(BN)", "F: all fixed + BatchNorm",
               "D: all fixed + InstanceNorm"]
    canvas2 = Image.new("RGB", (len(panels2) * (W + 2 * pad), H + lab + 2 * pad), (255, 255, 255))
    dr2 = ImageDraw.Draw(canvas2)
    for i, (lb, src) in enumerate(zip(labels2, panels2)):
        x = i * (W + 2 * pad) + pad
        dr2.text((x + 2, pad), lb, fill=(0, 0, 0))
        canvas2.paste(src, (x, pad + lab))
    canvas2.save(os.path.join(OUT, "01_side_by_side_batchnorm.png"))

    # 差异放大图（C 相对 A）
    d = (yC - yA).abs().mean(dim=1)[0].cpu().numpy()
    dv = (d / max(d.max(), 1e-8) * 255).astype(np.uint8)
    Image.fromarray(dv).save(os.path.join(OUT, "diff_C_vs_A.png"))

    with open(os.path.join(OUT, "fpga_image_log.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(log) + "\n")
    print()
    print("  出图目录:", OUT)
    print("  拼图    :", os.path.join(OUT, "00_side_by_side.png"))


if __name__ == "__main__":
    main()
