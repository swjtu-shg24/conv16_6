# -*- coding: utf-8 -*-
"""lianghua_infer.py —— **早期路线**的量化推理模拟（交互式，手动拖路径）

做的事情：把整网按 Q4.4 激活 + Q8.8 权重量化后用 PyTorch 跑一遍，出对比图，
用来看"如果只这样量化，图像会变成什么样"。

调用（★ 交互式，运行后会依次让你拖入 .pth 权重和图片路径）：
    cd rtl\\conv2\\picture_and_para
    python lianghua_infer.py

说明：这是早期探索脚本，**不是**本工程现行口径（现行口径见 stim_model.py），也不参与门禁。
      与它对拍/评估的口径差异见 eval_lianghua.py / eval_lianghua2.py。
"""
# fpga_quant_sim.py
import os
import sys
import numpy as np
import torch
import torch.nn as nn
import torchvision.transforms as transforms
from PIL import Image, ImageDraw

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt


# ==================== 量化函数 ====================
def quantize_q4_4(t):
    """
    Q4.4：8 位有符号定点，4 位小数。
    范围 [-8, 7.9375]，步长 1/16 = 0.0625。
    """
    scale = 16.0
    q = torch.round(t * scale) / scale
    return q.clamp(-8.0, 8.0 - 1.0 / scale)


def quantize_q8_8(t):
    """
    Q8.8：16 位有符号定点，8 位小数。
    范围 [-128, 127.99609375]，步长 1/256 = 0.00390625。
    """
    scale = 256.0
    q = torch.round(t * scale) / scale
    return q.clamp(-128.0, 128.0 - 1.0 / scale)


def quantize_model_weights_q8_8(net):
    """
    把所有 nn.Parameter 原地量化为 Q8.8。
    返回最大绝对量化误差。
    """
    max_err = 0.0
    total = 0
    with torch.no_grad():
        for name, p in net.named_parameters():
            orig = p.detach().clone()
            q = quantize_q8_8(orig)
            err = (q - orig).abs().max().item()
            max_err = max(max_err, err)
            total += orig.numel()
            p.copy_(q)
    return max_err, total


# ==================== 生成器定义 ====================
class DepthwiseSeparableConv(nn.Module):
    def __init__(self, in_ch, out_ch, stride=1):
        super().__init__()
        self.use_res = (stride == 1 and in_ch == out_ch)
        self.depthwise = nn.Sequential(
            nn.Conv2d(in_ch, in_ch, 3, stride, 1, groups=in_ch, bias=False),
            nn.BatchNorm2d(in_ch),
            nn.ReLU(True)
        )
        self.pointwise = nn.Sequential(
            nn.Conv2d(in_ch, out_ch, 1, bias=False),
            nn.BatchNorm2d(out_ch)
        )

    def forward(self, x):
        out = self.depthwise(x)
        out = self.pointwise(out)
        if self.use_res:
            out = out + x
        return out


class DepthwiseSeparableConv2d(nn.Module):
    def __init__(self, in_ch, out_ch, stride=1):
        super().__init__()
        self.depthwise = nn.Conv2d(in_ch, in_ch, 3, stride, 0, groups=in_ch, bias=False)
        self.pointwise = nn.Conv2d(in_ch, out_ch, 1, bias=False)

    def forward(self, x):
        x = self.depthwise(x)
        x = self.pointwise(x)
        return x


class MobileResnetGenerator(nn.Module):
    def __init__(self, input_nc=3, output_nc=3, ngf=8, n_blocks=9):
        super().__init__()
        model = [nn.ReflectionPad2d(1),
                 DepthwiseSeparableConv2d(input_nc, ngf),
                 nn.BatchNorm2d(ngf),
                 nn.ReLU(True),
                 nn.MaxPool2d(2, 2)]
        model += [DepthwiseSeparableConv(ngf, ngf * 2, stride=1),
                  nn.MaxPool2d(kernel_size=2, stride=2)]
        ngf *= 2
        model += [DepthwiseSeparableConv(ngf, ngf * 2, stride=1),
                  nn.MaxPool2d(kernel_size=2, stride=2)]
        ngf *= 2
        for _ in range(n_blocks):
            model.append(DepthwiseSeparableConv(ngf, ngf, stride=1))
        model += [nn.ConvTranspose2d(ngf, ngf // 2, 3, 2, 1,
                                     output_padding=1, bias=False),
                  nn.BatchNorm2d(ngf // 2), nn.ReLU(True)]
        ngf //= 2
        model += [nn.ConvTranspose2d(ngf, ngf // 2, 3, 2, 1,
                                     output_padding=1, bias=False),
                  nn.BatchNorm2d(ngf // 2), nn.ReLU(True)]
        ngf //= 2
        model += [nn.ConvTranspose2d(ngf, ngf, 3, 2, 1,
                                     output_padding=1, bias=False),
                  nn.BatchNorm2d(ngf), nn.ReLU(True)]
        model += [nn.ReflectionPad2d(3),
                  nn.Conv2d(ngf, output_nc, 7, 1, 0, bias=False),
                  nn.Tanh()]
        self.model = nn.Sequential(*model)

    def forward(self, x):
        return self.model(x)


# ==================== FPGA 输入量化 ====================
def fpga_input_quant_np(p):
    """
    p: numpy uint8 (H, W, 3)，取值 [0, 255]
    q = (p - 124) >> 3         (算术右移，等价于 floor((p-124)/8))
    x = q / 16                 (反量化为浮点，用于 PyTorch 推理)
    """
    p_int = p.astype(np.int32)
    q_int = (p_int - 124) >> 3
    x_fp = q_int.astype(np.float32) / 16.0
    return q_int, x_fp


def baseline_norm_np(p):
    """基线：x = 2p/255 - 1"""
    return p.astype(np.float32) / 127.5 - 1.0


def to_tensor_chw(x_hw3):
    """HWC float32 numpy -> CHW torch 张量 (1, C, H, W)"""
    return torch.from_numpy(x_hw3).permute(2, 0, 1).unsqueeze(0).contiguous()


# ==================== Hook：激活 Q4.4 量化 ====================
class QuantActivationCollector:
    def __init__(self, net, max_samples_per_layer=100000):
        self.net = net
        self.handles = []
        self.records = {}
        self.order = []
        self.index_map = {}
        self.flat_values = {}
        self.max_samples_per_layer = max_samples_per_layer

        # Q4.4 量化误差累计
        self.quant_total = 0
        self.quant_err_sum = 0.0
        self.quant_err_max = 0.0

        # clamp 命中统计（超出 [-8, 7.9375] 的元素）
        self.clamp_count = 0
        self.clamp_layers = set()

    def _hook_fn(self, name):
        def hook(module, inp, out):
            if not isinstance(out, torch.Tensor):
                return out

            # ===== 关键：Q4.4 量化，并 clamp 到 [-8, 7.9375] =====
            q = quantize_q4_4(out)
            # =====================================================

            # 量化误差统计
            err = (q - out).abs()
            self.quant_total += out.numel()
            self.quant_err_sum += err.sum().item()
            self.quant_err_max = max(self.quant_err_max, err.max().item())

            # clamp 命中统计
            lo_hi_mask = (out < -8.0) | (out > 8.0 - 1.0 / 16.0)
            if lo_hi_mask.any():
                self.clamp_layers.add(name)
                self.clamp_count += int(lo_hi_mask.sum().item())

            t = q.detach().float()

            if name not in self.index_map:
                self.order.append(name)
                self.index_map[name] = len(self.order)

            self.records.setdefault(name, []).append({
                'min':    t.min().item(),
                'max':    t.max().item(),
                'mean':   t.mean().item(),
                'std':    t.std().item(),
                'absmax': t.abs().max().item(),
                'nan':    torch.isnan(t).any().item(),
                'inf':    torch.isinf(t).any().item(),
                'shape':  tuple(t.shape),
                'count':  t.numel(),
                'sum':    t.sum().item(),
                'sumsq':  (t * t).sum().item(),
            })
            if name not in self.flat_values:
                flat = t.flatten()
                if flat.numel() > self.max_samples_per_layer:
                    idx = torch.randperm(flat.numel())[:self.max_samples_per_layer]
                    flat = flat[idx]
                self.flat_values[name] = flat.cpu().numpy()

            # 返回量化后的张量，让后续层真的用 Q4.4 的值继续算
            return q
        return hook

    def attach(self):
        target_types = (nn.Conv2d, nn.ConvTranspose2d, nn.BatchNorm2d,
                        nn.ReLU, nn.MaxPool2d, nn.ReflectionPad2d, nn.Tanh,
                        DepthwiseSeparableConv, DepthwiseSeparableConv2d)
        for name, module in self.net.named_modules():
            if name == '':
                continue
            if isinstance(module, target_types):
                self.handles.append(module.register_forward_hook(self._hook_fn(name)))

    def detach(self):
        for h in self.handles:
            h.remove()
        self.handles = []

    def aggregate(self):
        agg = {}
        for name, lst in self.records.items():
            if not lst:
                continue
            n = sum(d['count']  for d in lst)
            s = sum(d['sum']    for d in lst)
            q = sum(d['sumsq']  for d in lst)
            mean = s / n
            var  = max(0.0, q / n - mean * mean)
            agg[name] = {
                'idx':       self.index_map.get(name, -1),
                'type':      type(self.net.get_submodule(name)).__name__,
                'shape':     lst[0]['shape'],
                'min':       min(d['min']    for d in lst),
                'max':       max(d['max']    for d in lst),
                'mean':      mean,
                'std':       var ** 0.5,
                'absmax':    max(d['absmax'] for d in lst),
                'nan_count': sum(1 for d in lst if d['nan']),
                'inf_count': sum(1 for d in lst if d['inf']),
            }
        return agg

    def quant_summary(self):
        if self.quant_total == 0:
            return 0.0, 0.0
        return self.quant_err_sum / self.quant_total, self.quant_err_max


# ==================== 工具 ====================
def clean_path(s):
    s = s.strip()
    if len(s) >= 2 and s[0] == s[-1] and s[0] in ("'", '"'):
        s = s[1:-1]
    s = s.replace('\\ ', ' ')
    s = os.path.expanduser(s)
    return os.path.abspath(s)


def prompt_path(msg):
    while True:
        raw = input(msg).strip()
        if not raw:
            print("  ⚠️  路径为空，请重新拖入后回车。")
            continue
        p = clean_path(raw)
        if not os.path.exists(p):
            print(f"  ⚠️  路径不存在：{p}")
            continue
        return p


def list_images(folder):
    exts = ('.jpg', '.jpeg', '.png', '.bmp', '.tif', '.tiff', '.webp')
    return sorted([f for f in os.listdir(folder)
                   if f.lower().endswith(exts)])


def to_display(tensor_chw):
    arr = tensor_chw.detach().cpu().numpy().transpose(1, 2, 0)
    return (arr * 0.5 + 0.5).clip(0, 1)


def tensor_to_pil(tensor_chw):
    return Image.fromarray((to_display(tensor_chw) * 255).astype(np.uint8))


def make_grid(pil_imgs, labels, cols=None, gap=8, pad=8, label_h=22,
              bg=(255, 255, 255)):
    n = len(pil_imgs)
    if cols is None:
        cols = n
    rows = (n + cols - 1) // cols
    w, h = pil_imgs[0].size
    cell_w = pad + w + pad
    cell_h = pad + label_h + h + pad
    canvas = Image.new("RGB", (cols * cell_w, rows * cell_h), bg)
    draw = ImageDraw.Draw(canvas)
    for i, (im, lb) in enumerate(zip(pil_imgs, labels)):
        r, c = divmod(i, cols)
        x = c * cell_w + pad
        y = r * cell_h + pad
        draw.text((x + 2, y), lb, fill=(0, 0, 0))
        canvas.paste(im, (x, y + label_h))
    return canvas


# ==================== 可视化 ====================
def visualize_input_quant(p, q_int, x_base, x_fpga, save_dir, tag=""):
    os.makedirs(save_dir, exist_ok=True)

    x_base_vis = ((x_base + 1.0) / 2.0 * 255).clip(0, 255).astype(np.uint8)
    x_fpga_vis = ((x_fpga + 1.0) / 2.0 * 255).clip(0, 255).astype(np.uint8)
    diff = x_fpga - x_base

    fig, axes = plt.subplots(1, 4, figsize=(18, 5))
    axes[0].imshow(p)
    axes[0].set_title(f"Original (uint8 p)\n{tag}", fontsize=10)
    axes[1].imshow(x_base_vis)
    axes[1].set_title("Baseline input\n(2p/255 - 1)", fontsize=10)
    axes[2].imshow(x_fpga_vis)
    axes[2].set_title("FPGA input\n((p-124)>>3) / 16", fontsize=10)
    im = axes[3].imshow(diff, cmap='RdBu_r', vmin=-1/16, vmax=1/16)
    axes[3].set_title(f"Input diff (FPGA - Baseline)\n"
                      f"max|diff|={np.abs(diff).max():.4f}", fontsize=10)
    plt.colorbar(im, ax=axes[3], fraction=0.046)
    for ax in axes:
        ax.axis('off')
    plt.tight_layout()
    f1 = os.path.join(save_dir, "01_input_compare.png")
    plt.savefig(f1, dpi=150)
    plt.close(fig)

    fig, axes = plt.subplots(1, 3, figsize=(18, 5))
    ps = np.arange(0, 256, dtype=np.int32)
    qs = (ps - 124) >> 3
    axes[0].plot(ps, qs, color='tab:blue', linewidth=2)
    axes[0].set_title("Quantizer: q = (p - 124) >> 3")
    axes[0].set_xlabel("p (uint8 input pixel)")
    axes[0].set_ylabel("q (Q4.4 code)")
    axes[0].grid(True, alpha=0.3)
    axes[0].set_xticks([0, 124, 255])
    axes[0].axvline(124, color='gray', linestyle='--', alpha=0.5)
    axes[0].axhline(0, color='gray', linestyle='--', alpha=0.5)

    axes[1].hist(x_base.flatten(), bins=80, alpha=0.55,
                 label='Baseline', color='tab:orange', density=True)
    axes[1].hist(x_fpga.flatten(), bins=80, alpha=0.55,
                 label='FPGA Q4.4', color='tab:green', density=True)
    axes[1].set_title("Input value distribution")
    axes[1].set_xlabel("x")
    axes[1].set_ylabel("density")
    axes[1].grid(True, alpha=0.3)
    axes[1].legend()

    axes[2].hist(diff.flatten(), bins=80, color='tab:red', alpha=0.7)
    axes[2].set_title(f"Input diff distribution\n"
                      f"mean={diff.mean():.5f}, "
                      f"std={diff.std():.5f}, "
                      f"max|d|={np.abs(diff).max():.5f}")
    axes[2].set_xlabel("x_fpga - x_base")
    axes[2].set_ylabel("count")
    axes[2].grid(True, alpha=0.3)
    plt.tight_layout()
    f2 = os.path.join(save_dir, "02_quantizer_hist.png")
    plt.savefig(f2, dpi=150)
    plt.close(fig)
    return f1, f2


def visualize_output(y_base, y_fpga, y_input_only, save_dir, tag=""):
    img_base = tensor_to_pil(y_base[0])
    img_fpga = tensor_to_pil(y_fpga[0])
    img_in_only = tensor_to_pil(y_input_only[0])

    diff = (y_fpga[0] - y_base[0]).abs().mean(dim=0).cpu().numpy()
    diff_vis = (diff / max(diff.max(), 1e-8) * 255).astype(np.uint8)
    diff_img = Image.fromarray(diff_vis).convert("RGB")

    grid = make_grid(
        [img_base, img_in_only, img_fpga, diff_img],
        ["Baseline (fp32)",
         "Input-quant only",
         "Full FPGA (Q8.8 W + Q4.4 A)",
         f"|diff| map (max={diff.max():.4f})"],
        cols=4)
    f3 = os.path.join(save_dir, "03_output_compare.png")
    grid.save(f3)
    return f3


def visualize_activation_quant(collector, agg, save_dir):
    """
    可视化激活量化：
      - 每层 max/min 分布
      - 每层激活值合并直方图
      - 每层量化误差（可选，从日志看）
    """
    os.makedirs(save_dir, exist_ok=True)
    if not agg:
        return None

    ordered = sorted(agg.items(), key=lambda kv: kv[1]['idx'])
    max_vals = np.array([s['max'] for _, s in ordered])
    min_vals = np.array([s['min'] for _, s in ordered])

    fig, axes = plt.subplots(1, 2, figsize=(14, 5))
    axes[0].hist(max_vals, bins=40, color='tab:red',
                 edgecolor='black', alpha=0.75)
    axes[0].set_title('Per-layer MAX after Q4.4')
    axes[0].set_xlabel('Max value')
    axes[0].set_ylabel('Number of layers')
    axes[0].grid(True, alpha=0.3)

    axes[1].hist(min_vals, bins=40, color='tab:blue',
                 edgecolor='black', alpha=0.75)
    axes[1].set_title('Per-layer MIN after Q4.4')
    axes[1].set_xlabel('Min value')
    axes[1].set_ylabel('Number of layers')
    axes[1].grid(True, alpha=0.3)
    plt.tight_layout()
    f = os.path.join(save_dir, "04_activation_q4_4_minmax.png")
    plt.savefig(f, dpi=150)
    plt.close(fig)

    # 所有激活值合并直方图
    if collector.flat_values:
        all_vals = np.concatenate(list(collector.flat_values.values()))
        if all_vals.size > 0:
            lo, hi = np.percentile(all_vals, [0.5, 99.5])
            clipped = all_vals[(all_vals >= lo) & (all_vals <= hi)]
            fig, ax = plt.subplots(figsize=(10, 6))
            ax.hist(clipped, bins=120, color='tab:green',
                    edgecolor='black', alpha=0.75)
            ax.axvline(float(min_vals.min()), color='blue', linestyle='--',
                       label=f"global min = {min_vals.min():.3f}")
            ax.axvline(float(max_vals.max()), color='red', linestyle='--',
                       label=f"global max = {max_vals.max():.3f}")
            ax.set_title('Histogram of ALL activations after Q4.4 '
                         '(0.5-99.5 percentile)')
            ax.set_xlabel('Value')
            ax.set_ylabel('Count')
            ax.grid(True, alpha=0.3)
            ax.legend()
            plt.tight_layout()
            f = os.path.join(save_dir, "05_all_activation_hist.png")
            plt.savefig(f, dpi=150)
            plt.close(fig)
    return True


# ==================== 主流程 ====================
def main():
    print("=" * 68)
    print("  FPGA 量化推理模拟")
    print("  输入: q = (p - 124) >> 3, x = q / 16")
    print("  权重: Q8.8 (16-bit, 8 位小数)")
    print("  激活: Q4.4 (8-bit, 4 位小数, 范围 [-8, 7.9375])")
    print("=" * 68)

    weights = prompt_path("👉 请拖入【生成器权重 .pth】，然后回车：\n   > ")
    in_path = prompt_path("👉 请拖入【输入图片文件夹或单张图片】，然后回车：\n   > ")

    if os.path.isfile(in_path):
        input_dir = os.path.dirname(in_path)
        single_file = os.path.basename(in_path)
    else:
        input_dir = in_path
        single_file = None

    weights_dir = os.path.dirname(weights)
    weights_base = os.path.splitext(os.path.basename(weights))[0]
    output_dir = os.path.join(weights_dir, f"fpga_quant_sim_{weights_base}")
    os.makedirs(output_dir, exist_ok=True)

    device = torch.device('cuda' if torch.cuda.is_available() else 'cpu')
    print(f"\n设备: {device}")
    print(f"输出目录: {output_dir}\n")

    # 加载模型
    netG = MobileResnetGenerator(ngf=8, n_blocks=9).to(device)
    sd = torch.load(weights, map_location=device)
    if any(k.startswith('module.') for k in sd.keys()):
        sd = {k.replace('module.', '', 1): v for k, v in sd.items()}
    netG.load_state_dict(sd)
    netG.train()
    print("✅ 浮点权重加载完成（eval 模式）\n")

    filenames = [single_file] if single_file else list_images(input_dir)
    if not filenames:
        print("❌ 没找到图片")
        return

    # 日志
    log_lines = []
    log_lines.append("FPGA 量化推理模拟日志")
    log_lines.append("=" * 90)
    log_lines.append("输入量化 : q = (p - 124) >> 3, x = q / 16")
    log_lines.append("权重量化 : Q8.8 (16-bit, 8 位小数, 范围 [-128, 127.996])")
    log_lines.append("激活量化 : Q4.4 (8-bit, 4 位小数, 范围 [-8, 7.9375])")
    log_lines.append(f"权重文件 : {weights}")
    log_lines.append(f"输入目录 : {input_dir}")
    log_lines.append("")
    log_lines.append(
        f"{'文件':<26} {'in_max|d|':>10} {'in_mean|d|':>11} "
        f"{'仅输入量化':>12} {'完整FPGA':>12} {'完整FPGA':>10}")
    log_lines.append(
        f"{'':<26} {'':>10} {'':>11} "
        f"{'out_max|d|':>12} {'out_max|d|':>12} {'PSNR(dB)':>10}")
    log_lines.append("-" * 90)

    # 累积
    g_in_max = 0.0
    g_in_sum = 0.0
    g_in_cnt = 0
    g_inq_out_max = 0.0   # 仅输入量化 vs baseline
    g_inq_out_sum = 0.0
    g_inq_out_cnt = 0
    g_full_out_max = 0.0  # 完整 FPGA vs baseline
    g_full_out_sum = 0.0
    g_full_out_cnt = 0

    # ========== 第一遍：baseline 浮点推理，保存输出 ==========
    print("阶段 1/2：baseline 浮点推理 ...")
    y_base_cache = {}
    y_input_only_cache = {}
    with torch.no_grad():
        for i, fname in enumerate(filenames, 1):
            src = os.path.join(input_dir, fname)
            try:
                pil_orig = Image.open(src).convert('RGB')
            except Exception as e:
                print(f"[{i}/{len(filenames)}] ❌ {fname}: {e}")
                continue
            pil_orig = pil_orig.resize((320, 240), Image.LANCZOS)
            p = np.array(pil_orig)

            # baseline
            x_base_np = baseline_norm_np(p)
            x_base_t = to_tensor_chw(x_base_np).to(device)
            y_base = netG(x_base_t).cpu()
            y_base_cache[fname] = y_base

            # 仅输入量化（浮点权重 + 浮点激活 + FPGA 输入）
            q_int, x_fpga_np = fpga_input_quant_np(p)
            x_fpga_t = to_tensor_chw(x_fpga_np).to(device)
            y_in_only = netG(x_fpga_t).cpu()
            y_input_only_cache[fname] = y_in_only

            print(f"[{i}/{len(filenames)}] baseline OK: {fname}")

    # ========== 第二遍：权重量化 Q8.8 + 激活量化 Q4.4 ==========
    print("\n阶段 2/2：权重量化 Q8.8 + 激活量化 Q4.4 推理 ...")
    w_err, w_total = quantize_model_weights_q8_8(netG)
    log_lines.append(f"权重 Q8.8 量化：参数总数={w_total:,}，"
                     f"最大绝对误差={w_err:.8f}")
    print(f"✅ 权重已量化为 Q8.8，参数数={w_total:,}，"
          f"最大误差={w_err:.8f}")

    collector = QuantActivationCollector(netG, max_samples_per_layer=100000)
    collector.attach()
    print(f"✅ 已挂载 {len(collector.handles)} 个 hook"
          f"（激活 Q4.4 量化 + clamp 到 [-8, 7.9375]）\n")

    with torch.no_grad():
        for i, fname in enumerate(filenames, 1):
            if fname not in y_base_cache:
                continue
            src = os.path.join(input_dir, fname)
            pil_orig = Image.open(src).convert('RGB').resize((320, 240),
                                                             Image.LANCZOS)
            p = np.array(pil_orig)

            x_base_np = baseline_norm_np(p)
            q_int, x_fpga_np = fpga_input_quant_np(p)

            # 输入量化误差
            in_diff = np.abs(x_fpga_np - x_base_np)
            in_max = float(in_diff.max())
            in_mean = float(in_diff.mean())
            g_in_max = max(g_in_max, in_max)
            g_in_sum += in_diff.sum()
            g_in_cnt += in_diff.size

            # 完整 FPGA：Q8.8 权重 + Q4.4 激活 + FPGA 输入
            x_fpga_t = to_tensor_chw(x_fpga_np).to(device)
            y_full = netG(x_fpga_t).cpu()

            y_base = y_base_cache[fname]
            y_in_only = y_input_only_cache[fname]

            # 误差 1：仅输入量化 vs baseline
            d1 = (y_in_only - y_base).abs()
            o1_max = float(d1.max())
            g_inq_out_max = max(g_inq_out_max, o1_max)
            g_inq_out_sum += d1.sum().item()
            g_inq_out_cnt += d1.numel()

            # 误差 2：完整 FPGA vs baseline
            d2 = (y_full - y_base).abs()
            o2_max = float(d2.max())
            o2_mean = float(d2.mean())
            g_full_out_max = max(g_full_out_max, o2_max)
            g_full_out_sum += d2.sum().item()
            g_full_out_cnt += d2.numel()

            mse = d2.pow(2).mean().item()
            psnr = 10 * np.log10(4.0 / max(mse, 1e-12)) if mse > 0 else float('inf')

            log_lines.append(
                f"{fname:<26} {in_max:>10.5f} {in_mean:>11.6f} "
                f"{o1_max:>12.5f} {o2_max:>12.5f} {psnr:>10.2f}")

            print(f"[{i}/{len(filenames)}] {fname}  "
                  f"in_max|d|={in_max:.4f}  "
                  f"input_quant_out_max|d|={o1_max:.4f}  "
                  f"full_fpga_out_max|d|={o2_max:.4f}  PSNR={psnr:.2f} dB")

            # 保存可视化
            stem = os.path.splitext(fname)[0]
            sub = os.path.join(output_dir, stem)
            os.makedirs(sub, exist_ok=True)

            if i == 1:
                visualize_input_quant(p, q_int, x_base_np, x_fpga_np, sub, tag=fname)

            visualize_output(y_base, y_full, y_in_only, sub, tag=fname)

            img_base_pil = tensor_to_pil(y_base[0])
            img_full_pil = tensor_to_pil(y_full[0])
            img_in_pil = tensor_to_pil(y_in_only[0])
            grid = make_grid(
                [pil_orig, img_base_pil, img_in_pil, img_full_pil],
                ["Original", "Baseline fp32",
                 "Input quant only",
                 "Full FPGA (Q8.8 W + Q4.4 A)"],
                cols=4)
            grid.save(os.path.join(sub, "00_side_by_side.png"))

    # 激活量化汇总
    mean_q_err, max_q_err = collector.quant_summary()
    log_lines.append("-" * 90)
    log_lines.append("")
    log_lines.append("激活 Q4.4 量化统计")
    log_lines.append("=" * 90)
    log_lines.append(f"参与量化的元素总数 : {collector.quant_total:,}")
    log_lines.append(f"平均绝对量化误差   : {mean_q_err:.8f}")
    log_lines.append(f"最大绝对量化误差   : {max_q_err:.8f}")
    log_lines.append(f"发生 clamp 的元素数 : {collector.clamp_count:,}")
    log_lines.append(f"发生 clamp 的层数   : {len(collector.clamp_layers)}")
    if collector.clamp_layers:
        log_lines.append("发生 clamp 的层名:")
        for n in sorted(collector.clamp_layers):
            log_lines.append(f"  - {n}")

    # 激活 min/max 汇总
    agg = collector.aggregate()
    if agg:
        act_min = min(s['min'] for _, s in agg.items())
        act_max = max(s['max'] for _, s in agg.items())
        log_lines.append(f"激活全局 min (Q4.4 后) : {act_min:.6f}")
        log_lines.append(f"激活全局 max (Q4.4 后) : {act_max:.6f}")
        visualize_activation_quant(collector, agg, output_dir)

    # 全局汇总
    log_lines.append("")
    log_lines.append("=" * 90)
    log_lines.append("全局汇总")
    log_lines.append("=" * 90)
    if g_in_cnt > 0:
        log_lines.append(f"输入量化误差: max|d|={g_in_max:.6f}, "
                         f"mean|d|={g_in_sum/g_in_cnt:.6f}")
    if g_inq_out_cnt > 0:
        log_lines.append(f"仅输入量化   vs baseline: "
                         f"max|d|={g_inq_out_max:.6f}, "
                         f"mean|d|={g_inq_out_sum/g_inq_out_cnt:.6f}")
    if g_full_out_cnt > 0:
        mse_all = g_full_out_sum / g_full_out_cnt
        psnr_all = 10 * np.log10(4.0 / max(mse_all, 1e-12))
        log_lines.append(f"完整 FPGA    vs baseline: "
                         f"max|d|={g_full_out_max:.6f}, "
                         f"mean|d|={g_full_out_sum/g_full_out_cnt:.6f}, "
                         f"MSE={mse_all:.8f}, PSNR={psnr_all:.2f} dB")

    log_path = os.path.join(output_dir, "fpga_quant_log.txt")
    with open(log_path, 'w', encoding='utf-8') as f:
        f.write("\n".join(log_lines))

    print("\n" + "=" * 68)
    print("全局汇总")
    print("=" * 68)
    print(f"输入量化误差 max|d|  = {g_in_max:.6f}")
    print(f"输入量化误差 mean|d| = {g_in_sum/max(g_in_cnt,1):.6f}")
    print(f"仅输入量化  vs baseline: max|d|={g_inq_out_max:.6f}, "
          f"mean|d|={g_inq_out_sum/max(g_inq_out_cnt,1):.6f}")
    print(f"完整 FPGA   vs baseline: max|d|={g_full_out_max:.6f}, "
          f"mean|d|={g_full_out_sum/max(g_full_out_cnt,1):.6f}")
    print(f"权重 Q8.8 最大误差   = {w_err:.8f}")
    print(f"激活 Q4.4 平均误差   = {mean_q_err:.8f}")
    print(f"激活 Q4.4 最大误差   = {max_q_err:.8f}")
    print(f"激活发生 clamp 元素数: {collector.clamp_count:,}")
    print(f"\n日志: {log_path}")
    print(f"结果: {output_dir}")

    collector.detach()
    if sys.platform == 'darwin':
        os.system(f'open "{output_dir}"')


if __name__ == '__main__':
    main()