# 适用于 OPPO R11S 的 Arch Linux ARM

> [English (also in English)](README.md)

本目录包含 OPPO R11S 上 Arch Linux ARM 安装的可复现用户空间与引导集成。生成的文件、固件、分区转储、密码、SSH 密钥以及可刷写的镜像均有意不纳入 Git。

安装保留出厂 GPT。`userdata` 是 ext4 系统盘，`system` 是 ext4 离线救援盘，Android 引导镜像分区继续承载内核、DTB 与 initramfs。

## 安全模型

- `boot`、`bootbak` 和 `recovery` 是原始 Android 引导镜像分区。
- `vendor`、`modem`、`persist` 以及所有 Qualcomm 引导/校准/NV 分区保持不动。
- 格式化脚本要求明确的破坏性确认，并且分区尺寸必须精确匹配。
- 安装器恢复环境暴露 ACM 控制台和位于 `172.31.66.1/24` 的 USB ECM 链路。不使用 configfs 大容量存储，因为它在设备上不稳定。
- 写入存储要求安装器以 `--write` 构建，并带显式目标、字节数、SHA-256 和确认。接收端通过从 eMMC 回读同一字节范围来校验。
- 内核更新会生成镜像，但绝不会从 pacman hook 自动刷写。

## 构建顺序

脚本必须严格按照此顺序运行。第 1-3 步是主机端构建；第 4-6 步在通过 USB 连接的安装器恢复环境中运行；第 7 步是最终用户的安装。

1. 使用 `scripts/install-arch-rootfs.sh` 和 `scripts/prepare-rescue-filesystem.sh` 在精确尺寸的 loop 设备上构建根与救援 ext4 镜像。
2. 使用 `scripts/build-arch-boot-image.sh` 构建并校验生产引导镜像。
   `scripts/build-arch-boot-image-gcc.sh` 在 `linux/build-gcc` 下构建独立的原生 GCC 镜像与完整模块归档。其 `-sdm660-gcc+` 内核 release 使 GCC 模块与 Clang 回滚镜像保持分离。
3. 构建 `scripts/build-installer-image.sh --target all --write`，仅刷写 recovery 分区并启动它。
4. 在主机上运行 `scripts/configure-installer-network.sh`。
5. 在 ACM 上启动 `receive_arch_image --target system|userdata`，然后用 `scripts/send-arch-image.sh --target system|userdata` 流式传输各镜像。
6. 用 `receive_arch_boot` 发送生产引导镜像；它在替换 `boot` 前校验 `bootbak` 中完整的旧引导副本。

首次安装的账户是 `alarm`。除非显式设置 `R11S_SKIP_PASSWORDS=1`，否则安装器会提示设置 root 与用户密码。

## 分步指南（x86_64 主机）

### 0. 主机前置依赖

Debian 12（bookworm）软件包：

```sh
apt-get install -y clang clang-19 lld-19 llvm-19 llvm-19-tools llvm-19-dev \
    llvm-19-linker-tools llvm-19-runtime make bc flex bison \
    libelf-dev libssl-dev zstd cpio gzip device-tree-compiler libbluetooth-dev gcc gcc-aarch64-linux-gnu \
    mkbootimg curl git
```

内核为 Linux 7.0.x 且要求 clang >= 15，因此必须使用较新的 clang（19）；bookworm 默认的 clang-14 过旧。暴露 LLVM 19 工具链：

```sh
mkdir -p /usr/local/llvm19-bin
for t in clang clang++ ld.lld llvm-ar llvm-as llvm-nm llvm-objcopy \
         llvm-objdump llvm-ranlib llvm-readelf llvm-size llvm-strip; do
  ln -sf /usr/bin/$t-19 /usr/local/llvm19-bin/$t
done
export PATH=/usr/local/llvm19-bin:$PATH
```

为了让工具链在每个新 shell 中自动生效，把 PATH 导出追加到 `~/.bashrc`：

```sh
echo 'export PATH=/usr/local/llvm19-bin:$PATH' >> ~/.bashrc
```

然后重新打开终端或执行 `source ~/.bashrc` 后再构建。

`mkbootimg` 与 `unpack_bootimg` 来自 Debian 的 `mkbootimg` 软件包（1:29.0.6-28）。

### 1. 内核源码与配置

```sh
git clone --depth 1 -b qcom-sdm660-7.0.y \
    https://gh-proxy.com/https://github.com/NanShengtEAM/linux-sdm660-oppor11_s.git linux
make -C linux O=build ARCH=arm64 LLVM=1 sdm660_defconfig
```

大陆网络下 `gh-proxy.com` 前缀可加速克隆；替代镜像与回退方法见根 `README.md` 的国内镜像源说明。

主线内核树携带 R11S 设备树为 `arch/arm64/boot/dts/qcom/sdm660-oppo-r11s.dts`（compatible `oppo,r11s`），调制解调器 memshare 模块为 `drivers/soc/qcom/qcom-r11s-memshare.ko`（Kconfig 符号 `QCOM_R11S_MEMSHARE`）。引导镜像将 DTB 追加到 `Image.gz`，以便 Qualcomm 引导加载程序选择它。

### 2. 编译内核与模块

```sh
make -C linux O=build ARCH=arm64 LLVM=1 -j$(nproc) \
    Image.gz qcom/sdm660-oppo-r11s.dtb modules
```

产物：`linux/build/arch/arm64/boot/Image.gz`、`linux/build/arch/arm64/boot/dts/qcom/sdm660-oppo-r11s.dtb`，以及供 `make modules_install` 使用的 `linux/build` 下的模块。

### 3. 诊断镜像（先产出静态 busybox）

```sh
scripts/build-diag-image.sh
```

该脚本构建带静态 busybox 的 AArch64 initramfs 根目录（位于 `linux/build/initramfs-root/bin/busybox`）和诊断用 `linux/build/r11s-initramfs.cpio.gz` / diag 引导镜像。生产与安装器镜像会复用这个 busybox，因此该脚本必须先于它们运行。

如果还没有预先构建好的静态 busybox，先用 `scripts/build-static-busybox.sh` 构建它（用 `aarch64-linux-gnu-gcc` 以 `CONFIG_STATIC=y` 交叉编译 busybox 1.36.1，输出到 `linux/build/initramfs-root/bin/busybox`）：

诊断镜像还会打包三个设备 bring-up 二进制，它们不随本仓库分发（来自上游 r11t 项目）。必须在 `build-diag-image.sh` 成功前自行准备：

- `rmtfs`：从 `https://github.com/CPH1707-Mainline/rmtfs-sdm660-oppor11-t` 构建（需要 libqrtr 头文件与 `qmic`，通常在 bring-up 主机上交叉编译）。把静态二进制复制到 `linux/build/initramfs-root/bin/rmtfs`。
- `tqftpserv`：把静态二进制放到 `/tmp/opencode/tqftpserv/tqftpserv.static`。
- `diag-router`：把静态二进制放到 `/tmp/opencode/diag/diag-router`。

### 4. 根与救援 ext4 文件系统镜像

先创建精确尺寸的镜像（userdata 56933465600 B，system 3481272320 B）：

```sh
scripts/install-arch-rootfs.sh --device /dev/loopX --confirm
scripts/prepare-rescue-filesystem.sh --device /dev/loopY \
    --rootfs-image userdata.img --boot-image boot.img \
    --recovery-image recovery.img --confirm
```

两者都格式化为 ext4（没有 btrfs 子卷）。随后用 `finalize-arch-image.sh` 把 53 GiB 的 userdata 镜像缩小到 8 GiB：

```sh
scripts/finalize-arch-image.sh --source userdata-53g.img \
    --output userdata-8g.img --confirm
```

### 5. 生产引导镜像

```sh
scripts/build-arch-boot-image.sh
```

输出 `linux/build/boot-r11s-arch.img`，cmdline 为 `root=PARTLABEL=userdata rootfstype=ext4 rootwait rw rdinit=/init`。脚本会校验 ramdisk 保持在固件区（0x83000000-0x85600000）之下，且镜像能放入 boot。原生 GCC 变体 `scripts/build-arch-boot-image-gcc.sh` 面向在设备上构建（aarch64 GCC）；在 x86_64 上跳过它，改用 LLVM 路径。

### 6. 安装器恢复镜像

```sh
scripts/build-installer-image.sh --target all --write
```

输出 `linux/build/recovery-r11s-installer-ecm-all-write.img`，仅刷写到 `recovery` 分区。它携带 initramfs ACM 控制台和位于 172.31.66.1/24 的 USB ECM 链路。

### 7. 设备端安装流程

```sh
scripts/configure-installer-network.sh          # 主机：建立 172.31.66.x
# 安装器控制台（ACM）：receive_arch_image --target system
scripts/send-arch-image.sh --image system.img --target system
# 安装器控制台（ACM）：receive_arch_image --target userdata
scripts/send-arch-image.sh --image userdata.img --target userdata
# 安装器控制台（ACM）：receive_arch_boot < boot-r11s-arch.img
```

`receive_arch_boot` 会在替换 `boot` 前校验 `bootbak` 中的旧引导副本。内核更新会生成新镜像，但绝不会由 pacman hook 自动刷写；只在检查 bootbak 完整性后手动刷写。
