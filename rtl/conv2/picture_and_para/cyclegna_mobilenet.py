# -*- coding: utf-8 -*-
"""cyclegna_mobilenet.py —— **网络定义 + 训练脚本**（CycleGAN 的 MobileResnetGenerator）

前半段是 `MobileResnetGenerator(ngf=8, n_blocks=9)` 的定义（本工程 RTL 实现的就是它，
`netG_B_epoch11.pth` 与它 **strict=True** 严格对应）；`if __name__ == '__main__'` 之后是训练循环。

调用（★ 训练脚本：直接跑会**重新训练并覆盖 netG_A/B_epoch*.pth**，除非你要重训，否则别跑）：
    cd rtl\\conv2\\picture_and_para
    python cyclegna_mobilenet.py

只想要网络定义/做前向，用 `check_float_ref.py`（它负责把 .pth 灌进来验证浮点参考）。
"""
import torch
import torch.nn as nn
import torch.optim as optim
import torchvision.transforms as transforms
from torch.utils.data import DataLoader, Dataset
from PIL import Image
import os
import random
import time
import numpy as np
import matplotlib.pyplot as plt

# ==================== 超参数 ====================
BATCH_SIZE = 1
IMAGE_HEIGHT = 240
IMAGE_WIDTH = 320
LAMBDA_A = 10.0
LAMBDA_B = 10.0
LAMBDA_IDT = 0.5
N_EPOCHS = 200
DECAY_EPOCHS = 100
LR = 0.0002
BETA1 = 0.5
POOL_SIZE = 50
SAVE_INTERVAL = 1

DEVICE = torch.device('cuda' if torch.cuda.is_available() else 'cpu')

# ==================== 数据集类 ====================
class UnalignedDataset(Dataset):
    def __init__(self, root, transform=None):
        self.root = root
        self.transform = transform
        self.path_A = sorted(os.listdir(os.path.join(root, 'trainA')))
        self.path_B = sorted(os.listdir(os.path.join(root, 'trainB')))
        self.len_A = len(self.path_A)
        self.len_B = len(self.path_B)

    def __len__(self):
        return max(self.len_A, self.len_B)

    def __getitem__(self, index):
        idx_A = random.randint(0, self.len_A - 1)
        idx_B = random.randint(0, self.len_B - 1)
        img_A = Image.open(os.path.join(self.root, 'trainA', self.path_A[idx_A])).convert('RGB')
        img_B = Image.open(os.path.join(self.root, 'trainB', self.path_B[idx_B])).convert('RGB')
        if self.transform:
            img_A = self.transform(img_A)
            img_B = self.transform(img_B)
        return {'A': img_A, 'B': img_B}

# ==================== 轻量级生成器组件 ====================
class DepthwiseSeparableConv(nn.Module):
    def __init__(self, in_ch, out_ch, stride=1):
        super().__init__()
        self.use_res = (stride == 1 and in_ch == out_ch)

        # 逐通道卷积
        self.depthwise = nn.Sequential(
            nn.Conv2d(in_ch, in_ch, 3, stride, 1, groups=in_ch, bias=False),
            nn.BatchNorm2d(in_ch),
            nn.ReLU(True)
        )
        # 逐点卷积
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
        model = [nn.ReflectionPad2d(1),                         #322*242
        DepthwiseSeparableConv2d(input_nc, ngf),        # 
        nn.BatchNorm2d(ngf),#
        nn.ReLU(True),
        nn.MaxPool2d(2, 2)]

        # 下采样（深度可分离，stride=2）
        model += [
            DepthwiseSeparableConv(ngf, ngf * 2, stride=1),   # 8 → 16, stride=1
            nn.MaxPool2d(kernel_size=2, stride=2),            # 120×160 → 60×80
        ]
        ngf *= 2   # 16
        model += [
            DepthwiseSeparableConv(ngf, ngf * 2, stride=1),   # 16 → 32, stride=1
            nn.MaxPool2d(kernel_size=2, stride=2),            # 60×80 → 30×40
        ]
        ngf *= 2   # 32

        # 残差块（深度可分离，stride=1，带残差）
        for _ in range(n_blocks):
            model.append(DepthwiseSeparableConv(ngf, ngf, stride=1))

        # 上采样（转置卷积）
        # 上采样 1：30×40 → 60×80
        model += [
            nn.ConvTranspose2d(ngf, ngf // 2, 3, 2, 1, output_padding=1, bias=False),
            nn.BatchNorm2d(ngf // 2),
            nn.ReLU(True),
        ]
        ngf //= 2   # 32 → 16 
        # 上采样 2：60×80 → 120×160
        model += [
            nn.ConvTranspose2d(ngf, ngf // 2, 3, 2, 1, output_padding=1, bias=False),
            nn.BatchNorm2d(ngf // 2),
            nn.ReLU(True),
        ]
        ngf //= 2   # 16 → 8
        # 上采样 3：120×160 → 240×320（通道保持 8）
        model += [
            nn.ConvTranspose2d(ngf, ngf, 3, 2, 1, output_padding=1, bias=False),
            nn.BatchNorm2d(ngf),
            nn.ReLU(True),
        ]
        # 输出层
        model += [nn.ReflectionPad2d(3),
                  nn.Conv2d(ngf, output_nc, 7, 1, 0, bias=False),
                  nn.Tanh()]

        self.model = nn.Sequential(*model)

    def forward(self, x):
        return self.model(x)

# ==================== 判别器（与原版一致） ====================
class NLayerDiscriminator(nn.Module):
    def __init__(self, input_nc=3, ndf=8, n_layers=3):
        super().__init__()
        kw = 4
        padw = 1
        sequence = [nn.Conv2d(input_nc, ndf, kw, 2, padw, bias=False),
                    nn.LeakyReLU(0.2, True)]
        nf_mult = 1
        nf_mult_prev = 1
        for n in range(1, n_layers):
            nf_mult_prev = nf_mult
            nf_mult = min(2**n, 8)
            sequence += [nn.Conv2d(ndf*nf_mult_prev, ndf*nf_mult, kw, 2, padw, bias=False),
                         nn.InstanceNorm2d(ndf*nf_mult),
                         nn.LeakyReLU(0.2, True)]
        nf_mult_prev = nf_mult
        nf_mult = min(2**n_layers, 8)
        sequence += [nn.Conv2d(ndf*nf_mult_prev, ndf*nf_mult, kw, 1, padw, bias=False),
                     nn.InstanceNorm2d(ndf*nf_mult),
                     nn.LeakyReLU(0.2, True)]
        sequence += [nn.Conv2d(ndf*nf_mult, 1, kw, 1, padw, bias=False)]
        self.model = nn.Sequential(*sequence)

    def forward(self, x):
        return self.model(x)

# ==================== 损失与辅助类 ====================
class GANLoss(nn.Module):
    def __init__(self):
        super().__init__()
        self.loss = nn.MSELoss()
    def __call__(self, pred, target_is_real):
        target = torch.ones_like(pred) if target_is_real else torch.zeros_like(pred)
        return self.loss(pred, target)

class ImagePool:
    def __init__(self, pool_size):
        self.pool_size = pool_size
        self.images = []
    def query(self, images):
        if self.pool_size == 0:
            return images
        out = []
        for img in images:
            if len(self.images) < self.pool_size:
                self.images.append(img)
                out.append(img)
            else:
                if random.random() > 0.5:
                    idx = random.randint(0, self.pool_size-1)
                    out.append(self.images[idx])
                    self.images[idx] = img
                else:
                    out.append(img)
        return torch.stack(out, dim=0)

def print_network_params(net, name, log_file=None):
    num_params = sum(p.numel() for p in net.parameters())
    info = f"[Network {name}] Total parameters: {num_params:,} ({num_params/1e6:.3f} M)"
    print(info)
    if log_file:
        with open(log_file, 'a') as f:
            f.write(info + '\n')
    return num_params

# ==================== 训练入口 ====================
if __name__ == '__main__':
    start_time = time.time()
    print(f"Using device: {DEVICE}")

    # 初始化网络（生成器已替换为轻量级版本）
    netG_A = MobileResnetGenerator().to(DEVICE)
    netG_B = MobileResnetGenerator().to(DEVICE)
    netD_A = NLayerDiscriminator().to(DEVICE)
    netD_B = NLayerDiscriminator().to(DEVICE)

    optimG = optim.Adam(list(netG_A.parameters()) + list(netG_B.parameters()),
                        lr=LR, betas=(BETA1, 0.999))
    optimD = optim.Adam(list(netD_A.parameters()) + list(netD_B.parameters()),
                        lr=LR, betas=(BETA1, 0.999))

    criterionGAN = GANLoss()
    criterionCycle = nn.L1Loss()
    criterionIdt = nn.L1Loss()

    pool_A = ImagePool(POOL_SIZE)
    pool_B = ImagePool(POOL_SIZE)

    # 打印参数并对比原版生成器
    print("\n========== Network Parameters ==========")
    param_log = 'model_params_mobilenet.txt'
    with open(param_log, 'w') as f:
        f.write(f"MobileNet-style generator (depthwise separable conv)\n")
        f.write(f"Image size: {IMAGE_HEIGHT}x{IMAGE_WIDTH}, Batch size: {BATCH_SIZE}\n")
        f.write("Parameters at initialization:\n")

    for name, net in [('G_A (mobile)', netG_A), ('G_B (mobile)', netG_B),
                      ('D_A', netD_A), ('D_B', netD_B)]:
        print_network_params(net, name, param_log)

    # 数据加载
    transform = transforms.Compose([
        transforms.Resize((IMAGE_HEIGHT, IMAGE_WIDTH)),
        transforms.ToTensor(),
        transforms.Normalize(mean=[0.5, 0.5, 0.5], std=[0.5, 0.5, 0.5])
    ])
    dataset = UnalignedDataset(root='./datasets/vangogh2photo_320_240', transform=transform)
    dataloader = DataLoader(dataset, batch_size=BATCH_SIZE, shuffle=True, num_workers=0)
    os.makedirs('./output_images', exist_ok=True)

    # 训练循环
    print("开始训练...")
    total_iters = 0
    for epoch in range(1, N_EPOCHS + 1):
        # 学习率衰减
        if epoch > DECAY_EPOCHS:
            decay_factor = 1.0 - (epoch - DECAY_EPOCHS) / (N_EPOCHS - DECAY_EPOCHS)
            for param_group in optimG.param_groups:
                param_group['lr'] = LR * decay_factor
            for param_group in optimD.param_groups:
                param_group['lr'] = LR * decay_factor

        epoch_loss_G = 0.0
        epoch_loss_D = 0.0
        for i, data in enumerate(dataloader):
            real_A = data['A'].to(DEVICE)
            real_B = data['B'].to(DEVICE)

            # 前向
            fake_B = netG_A(real_A)
            rec_A = netG_B(fake_B)
            fake_A = netG_B(real_B)
            rec_B = netG_A(fake_A)

            # 更新 G
            optimG.zero_grad()
            if LAMBDA_IDT > 0:
                idt_A = netG_A(real_B)
                loss_idt_A = criterionIdt(idt_A, real_B) * LAMBDA_B * LAMBDA_IDT
                idt_B = netG_B(real_A)
                loss_idt_B = criterionIdt(idt_B, real_A) * LAMBDA_A * LAMBDA_IDT
            else:
                loss_idt_A = 0.0
                loss_idt_B = 0.0

            loss_G_A = criterionGAN(netD_A(fake_B), True)
            loss_G_B = criterionGAN(netD_B(fake_A), True)
            loss_cycle_A = criterionCycle(rec_A, real_A) * LAMBDA_A
            loss_cycle_B = criterionCycle(rec_B, real_B) * LAMBDA_B

            loss_G = loss_G_A + loss_G_B + loss_cycle_A + loss_cycle_B + loss_idt_A + loss_idt_B
            loss_G.backward()
            optimG.step()

            # 更新 D
            optimD.zero_grad()
            fake_B_pool = pool_B.query(fake_B.detach())
            loss_D_A_real = criterionGAN(netD_A(real_B), True)
            loss_D_A_fake = criterionGAN(netD_A(fake_B_pool), False)
            loss_D_A = (loss_D_A_real + loss_D_A_fake) * 0.5
            loss_D_A.backward()

            fake_A_pool = pool_A.query(fake_A.detach())
            loss_D_B_real = criterionGAN(netD_B(real_A), True)
            loss_D_B_fake = criterionGAN(netD_B(fake_A_pool), False)
            loss_D_B = (loss_D_B_real + loss_D_B_fake) * 0.5
            loss_D_B.backward()

            optimD.step()

            epoch_loss_G += loss_G.item()
            epoch_loss_D += loss_D_A.item() + loss_D_B.item()
            total_iters += 1

            if (i+1) % 50 == 0:
                print(f"Epoch {epoch}/{N_EPOCHS} Iter {i+1}/{len(dataloader)} | G_loss: {loss_G.item():.4f} | D_loss: {(loss_D_A+loss_D_B).item():.4f}")

        avg_G = epoch_loss_G / len(dataloader)
        avg_D = epoch_loss_D / len(dataloader)
        print(f"Epoch {epoch} finished | Avg G loss: {avg_G:.4f} | Avg D loss: {avg_D:.4f} | LR: {optimG.param_groups[0]['lr']:.6f}")

        # 保存图像与模型
        if epoch % SAVE_INTERVAL == 0:
            with torch.no_grad():
                sample_batch = next(iter(dataloader))
                real_A = sample_batch['A'].to(DEVICE)
                real_B = sample_batch['B'].to(DEVICE)
                fake_B = netG_A(real_A)
                fake_A = netG_B(real_B)

                def to_display(tensor):
                    return (tensor.cpu().numpy().transpose(0, 2, 3, 1) * 0.5 + 0.5).clip(0, 1)

                img_A = to_display(real_A)[0]
                img_B = to_display(real_B)[0]
                img_fake_B = to_display(fake_B)[0]
                img_fake_A = to_display(fake_A)[0]

                fig, axes = plt.subplots(2, 2, figsize=(10, 10))
                axes[0, 0].imshow(img_A); axes[0, 0].set_title('Real A'); axes[0, 0].axis('off')
                axes[0, 1].imshow(img_fake_B); axes[0, 1].set_title('Fake B (A→B)'); axes[0, 1].axis('off')
                axes[1, 0].imshow(img_B); axes[1, 0].set_title('Real B'); axes[1, 0].axis('off')
                axes[1, 1].imshow(img_fake_A); axes[1, 1].set_title('Fake A (B→A)'); axes[1, 1].axis('off')
                plt.tight_layout()
                plt.savefig(f'./output_images/epoch_{epoch:03d}.png')
                plt.close(fig)

            torch.save(netG_A.state_dict(), f'netG_A_epoch{epoch}.pth')
            torch.save(netG_B.state_dict(), f'netG_B_epoch{epoch}.pth')
            torch.save(netD_A.state_dict(), f'netD_A_epoch{epoch}.pth')
            torch.save(netD_B.state_dict(), f'netD_B_epoch{epoch}.pth')
            print(f"Models saved at epoch {epoch}")

    total_time = time.time() - start_time
    print(f"训练完成！总耗时: {total_time/60:.2f} 分钟")