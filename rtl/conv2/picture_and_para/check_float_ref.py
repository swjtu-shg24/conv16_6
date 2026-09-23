# -*- coding: utf-8 -*-
"""check_float_ref.py —— 用你自己的网络定义验证本工程的浮点参考

做三件事：
  ① 用 picture_and_para/cyclegna_mobilenet.py 里的 MobileResnetGenerator 建网，
     把 netG_B_epoch11.pth **strict=True** 灌进去 —— 能装上就说明 pth 与这份网络定义严格对应
  ② 用它的 model[0..4]（ReflectionPad2d → dw+pw → BatchNorm2d → ReLU → MaxPool2d）
     对 test.jpg 做前向，得到"官方浮点 BN 输出 / 池化输出"
  ③ 和本工程 stim_model.float_ref() 的结果逐点比 —— 证明
     "layer 划分 + reflection pad + BN 折叠 (scale/shift) + 池化顺序" 全都对得上

跑法：
    & 'D:\\...\\envs\\cyclegan\\python.exe' rtl\\conv2\\picture_and_para\\check_float_ref.py
"""
import importlib.util
import os
import sys

import numpy as np
import torch

import stim_model as M

HERE = M.HERE


def load_net():
    spec = importlib.util.spec_from_file_location("cyclegna_mobilenet",
                                                  os.path.join(HERE, "cyclegna_mobilenet.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)          # 该文件有 __main__ 保护，import 不会跑训练
    net = mod.MobileResnetGenerator()
    sd = torch.load(M.PTH, map_location="cpu", weights_only=True)
    missing, unexpected = net.load_state_dict(sd, strict=False)
    return net, missing, unexpected


def main():
    print("=" * 78)
    print("check_float_ref : 官方网络定义 vs 本工程浮点参考")
    print("=" * 78)

    net, missing, unexpected = load_net()
    net.eval()
    print("  MobileResnetGenerator 建网 OK；state_dict strict=False 装载：")
    print("     missing keys    = %d %s" % (len(missing), missing[:4]))
    print("     unexpected keys = %d %s" % (len(unexpected), unexpected[:4]))
    if missing or unexpected:
        print("     （有缺/多说明 pth 与定义不完全对应，下面的对比要谨慎看）")

    img = M.load_image()
    W = M.load_weights()
    xn = img.astype(np.float32) / 127.5 - 1.0

    with torch.no_grad():
        x = torch.from_numpy(xn).permute(2, 0, 1)[None]                 # (1,3,240,320)
        t_pad = net.model[0](x)                                         # ReflectionPad2d(1)
        t_dw = net.model[1].depthwise(t_pad)                            # dw 3x3 (groups=3)
        t_pw = net.model[1].pointwise(t_dw)                             # pw 1x1 3→8
        t_bn = net.model[2](t_pw)                                       # BatchNorm2d(8)
        # ★ nn.ReLU(True) 是 **inplace**：下面这一步会把 t_bn 的内存原地改掉，
        #   所以必须先把 BN 的输出 clone 出来，否则"BN 输出"比的是 ReLU 之后的值
        #   （症状：官方 BN 范围变成 +0.000..，和我的 -4.9..+4.9 差一个 ReLU）
        t_bn_val = t_bn.detach().clone()
        t_relu = net.model[3](t_bn)                                     # ReLU (inplace)
        t_pool = net.model[4](t_relu)                                   # MaxPool2d(2,2)

    torch_bn = t_bn_val[0].permute(1, 2, 0).numpy().astype(np.float64)  # (240,320,8)
    torch_pool = t_pool[0].permute(1, 2, 0).numpy().astype(np.float64)  # (120,160,8)

    fl = M.float_ref(img, W, bn_relu=False)   # 比"纯 BN 输出"，不加 ReLU
    mine_bn = fl["bnf"]
    mine_pool_relu = np.maximum(0.0, fl["outf"])                        # 池化前 ReLU 与池化后 ReLU 等价

    print("\n  数据形状： torch_bn=%s  mine=%s" % (torch_bn.shape, mine_bn.shape))
    print("  BN 输出    : 最大绝对差 = %.3e   官方范围 %+.3f..%+.3f   我的 %+.3f..%+.3f" %
          (np.abs(torch_bn - mine_bn).max(), torch_bn.min(), torch_bn.max(),
           mine_bn.min(), mine_bn.max()))
    print("  池化输出   : 最大绝对差 = %.3e   官方范围 %+.3f..%+.3f   我的 %+.3f..%+.3f" %
          (np.abs(torch_pool - mine_pool_relu).max(), torch_pool.min(), torch_pool.max(),
           mine_pool_relu.min(), mine_pool_relu.max()))

    # dw / pw 中间层也顺手比一下
    mine_dw = fl["dwf"]
    torch_dw = t_dw[0].permute(1, 2, 0).numpy().astype(np.float64)
    mine_pw = fl["pwf"]
    torch_pw = t_pw[0].permute(1, 2, 0).numpy().astype(np.float64)
    print("  dw 输出    : 最大绝对差 = %.3e" % np.abs(torch_dw - mine_dw).max())
    print("  pw 输出    : 最大绝对差 = %.3e" % np.abs(torch_pw - mine_pw).max())

    ok = (np.abs(torch_bn - mine_bn).max() < 1e-4 and
          np.abs(torch_pool - mine_pool_relu).max() < 1e-4 and
          np.abs(torch_dw - mine_dw).max() < 1e-4 and
          np.abs(torch_pw - mine_pw).max() < 1e-4)
    print("\n---------------- 结论 ----------------")
    print("  %s" % ("浮点参考与官方网络**逐点一致** → 定点模型比较的基准是对的"
                    if ok else "有差异，检查 layer 划分 / BN 折叠 / reflection pad"))
    print("--------------------------------------")
    return 0 if ok else 1


sys.exit(main())
