# 适用于 OPPO R11S 的 Arch Linux ARM

> [English (also in English)](README.md)

OPPO R11S（`oppo,r11s`）主线 Linux 移植版的 Arch Linux ARM 部署、恢复与硬件集成源码。已部署的系统使用原始 Android `userdata` 分区上的 ext4 文件系统、systemd、KDE Plasma/Wayland、PipeWire、NetworkManager 以及设备专属主线内核。

建议从 [`archlinux/README.md`](archlinux/README.md) 开始阅读。仓库包含 rootfs 软件包清单与 overlay、生产/安装器 initramfs 源码、ECM 流式安装器、经过校验的引导镜像更新与回滚工具，以及镜像构建器所需的共享诊断程序。

相关源码仓库：

- 内核：<https://github.com/NanShengtEAM/linux-sdm660-oppor11_s>
- RMTFS：<https://github.com/HELPMEEADICE/rmtfs-sdm660-oppor11_s>
- 通用工具：<https://github.com/HELPMEEADICE/oppo-r11-mainline-tools-sdm660-oppor11_s>

构建脚本期望内核检出目录位于 `./linux`。该公开源码仓库有意排除设备固件、分区备份、生成的镜像、密码、SSH 密钥、MAC 地址以及提取的设备数据。固件与账户凭据在构建或运行时由设备保留的只读分区在本地提供。

WCN3990 的 bring-up 历史、协议细节、已知问题及硬件验证证据，请参见 `OPPO_R11S_WIFI_MAINLINE_BRINGUP.md`。

## `git clone` 之后的操作

先克隆本仓库，再把主线内核拉取到 `./linux`（构建脚本期望它在那里）：

```sh
git clone git@github.com:NanShengtEAM/arch-linux-on-r11s.git
cd arch-linux-on-r11s
git clone --depth 1 -b qcom-sdm660-7.0.y \
    https://github.com/NanShengtEAM/linux-sdm660-oppor11_s.git linux
```

安装主机前置依赖（Debian 12）：

```sh
apt-get install -y clang clang-19 lld-19 llvm-19 llvm-19-tools llvm-19-dev \
    llvm-19-linker-tools llvm-19-runtime make bc flex bison \
    libelf-dev libssl-dev zstd cpio gzip device-tree-compiler libbluetooth-dev gcc gcc-aarch64-linux-gnu \
    mkbootimg
```

内核为 Linux 7.0.x，需要 clang >= 15；bookworm 默认的 clang-14 过旧，因此需要让 LLVM 19 工具以 `clang`、`llvm-strip` 等名称出现在 PATH 中（精确的软链配置见 `archlinux/README.md`）。

随后按此顺序运行脚本（每一步的详细说明见 `archlinux/README.md`）：

```sh
# 1. 内核配置与编译（Image.gz、DTB、modules）
make -C linux O=build ARCH=arm64 LLVM=1 sdm660_defconfig
make -C linux O=build ARCH=arm64 LLVM=1 -j$(nproc) \
    Image.gz qcom/sdm660-oppo-r11s.dtb modules

# 2. 诊断镜像（产出后续镜像复用的静态 busybox）
scripts/build-diag-image.sh

# 3. 生产引导镜像（boot-r11s-arch.img）
scripts/build-arch-boot-image.sh

# 4. 安装器恢复镜像
scripts/build-installer-image.sh --target all --write
```

设备端安装流程（通过 USB 的 ECM/ACM）在 `archlinux/README.md` 第 7 节中说明：把安装器刷入 `recovery`，在 ACM 控制台运行 `receive_arch_image --target system|userdata`，用 `scripts/send-arch-image.sh` 流式传输根镜像与救援镜像，再以同样的方式应用引导镜像：在 ACM 控制台运行 `receive_arch_boot --bytes N --sha256 HASH --confirm`，并用 `scripts/send-arch-image.sh --image linux/build/boot-r11s-arch.img` 传输 `boot-r11s-arch.img`。`receive_arch_boot` 会在替换 `boot` 前校验 `bootbak` 中上一份引导副本的完整性。
