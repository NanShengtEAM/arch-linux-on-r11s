# Arch Linux ARM for OPPO R11S

> [简体中文 / Simplified Chinese (also in Chinese)](README.zh-CN.md)

Arch Linux ARM deployment, recovery, and hardware-integration sources for the
OPPO R11S (`oppo,r11s`) mainline Linux port. The deployed system uses ext4 on
the original Android `userdata` partition, systemd, KDE Plasma/Wayland,
PipeWire, NetworkManager, and the device-specific mainline kernel.

Start with [`archlinux/README.md`](archlinux/README.md). The repository includes
the rootfs package manifest and overlay, production and installer initramfs
sources, ECM streaming installer, verified boot-image update and rollback
tools, and the shared diagnostics required by the image builders.

Related source repositories:

- Kernel: <https://github.com/NanShengtEAM/linux-sdm660-oppor11_s>
- RMTFS: <https://github.com/HELPMEEADICE/rmtfs-sdm660-oppor11_s>
- General tools: <https://github.com/HELPMEEADICE/oppo-r11-mainline-tools-sdm660-oppor11_s>

The build scripts expect the kernel checkout at `./linux`. This public source
repository intentionally excludes device firmware, partition backups,
generated images, passwords, SSH keys, MAC addresses, and extracted device
data. Firmware and account credentials are supplied locally at build or runtime
from the device's preserved read-only partitions.

See `OPPO_R11S_WIFI_MAINLINE_BRINGUP.md` for the WCN3990 bring-up history,
protocol details, known issues, and hardware validation evidence.

## Getting started after `git clone`

Clone this repository, then fetch the mainline kernel into `./linux` (the build
scripts expect it there):

```sh
git clone git@github.com:NanShengtEAM/arch-linux-on-r11s.git
cd arch-linux-on-r11s
git clone --depth 1 -b qcom-sdm660-7.0.y \
    https://gh-proxy.com/https://github.com/NanShengtEAM/linux-sdm660-oppor11_s.git linux
```

### Note for mainland China networks (国内镜像源)

Direct access to `github.com` is often slow or interrupted from mainland China.
The `gh-proxy.com` prefix in the clone URL above is a GitHub reverse proxy that
speeds up `git clone` and file downloads. The build scripts clone dependencies
(tinyalsa) through the same proxy automatically.

If `gh-proxy.com` is down or slow, alternatives:

- `https://ghfast.top/https://github.com/<owner>/<repo>.git`
- `https://gh-proxy.net/https://github.com/<owner>/<repo>.git`
- Mirror on Gitee: search the repo name on <https://gitee.com> and clone from
  there, then later sync to the official GitHub origin.

To fall back to the official source, just drop the proxy prefix:

```sh
git clone --depth 1 -b qcom-sdm660-7.0.y \
    https://github.com/NanShengtEAM/linux-sdm660-oppor11_s.git linux
```

For updating an existing clone where `git pull` fails with TLS errors, use the
same prefix on the fetch URL (see the proxy section above) and switch back to
the official URL afterwards. Pushes must always go to the official
`github.com` origin.

Install the host prerequisites (Debian 12):

```sh
apt-get install -y clang clang-19 lld-19 llvm-19 llvm-19-tools llvm-19-dev \
    llvm-19-linker-tools llvm-19-runtime make bc flex bison \
    libelf-dev libssl-dev zstd cpio gzip device-tree-compiler libbluetooth-dev gcc gcc-aarch64-linux-gnu \
    mkbootimg
```

The kernel is Linux 7.0.x and needs clang >= 15; the bookworm default clang-14
is too old, so make the LLVM 19 tools the ones named `clang`, `llvm-strip`,
etc. in your PATH (see `archlinux/README.md` for the exact symlink setup).

Then run the scripts in this order (each step is detailed in
`archlinux/README.md`):

```sh
# 1. Kernel config + compile (Image.gz, DTB, modules)
make -C linux O=build ARCH=arm64 LLVM=1 sdm660_defconfig
make -C linux O=build ARCH=arm64 LLVM=1 -j$(nproc) \
    Image.gz qcom/sdm660-oppo-r11s.dtb modules

# 2. Diagnostic image (produces the static busybox the later images reuse)
scripts/build-diag-image.sh

# 3. Production boot image (boot-r11s-arch.img)
scripts/build-arch-boot-image.sh

# 4. Installer recovery image
scripts/build-installer-image.sh --target all --write
```

The device-side install flow (ECM/ACM via USB) is covered in step 7 of
`archlinux/README.md`: flash the installer to `recovery`, run
`receive_arch_image --target system|userdata` on the ACM console, stream the
root and rescue images with `scripts/send-arch-image.sh`, then apply the boot
image the same way: run `receive_arch_boot --bytes N --sha256 HASH --confirm`
on the ACM console and stream `boot-r11s-arch.img` with
`scripts/send-arch-image.sh --image linux/build/boot-r11s-arch.img`.
`receive_arch_boot` verifies the previous boot copy in `bootbak` before
replacing `boot`.
