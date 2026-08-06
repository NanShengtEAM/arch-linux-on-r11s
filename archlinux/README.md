# Arch Linux ARM for OPPO R11S

> [简体中文 / Simplified Chinese (also in Chinese)](README.zh-CN.md)

This directory contains the reproducible userspace and boot integration for an
Arch Linux ARM installation on the OPPO R11S. Generated files, firmware,
partition dumps, passwords, SSH keys, and flashable images are intentionally
excluded from Git.

The installation keeps the factory GPT. `userdata` is the ext4 system disk,
`system` is an ext4 offline rescue disk, and the Android boot image partitions
continue to carry the kernel, DTB, and initramfs.

## Safety model

- `boot`, `bootbak`, and `recovery` are raw Android boot image partitions.
- `vendor`, `modem`, `persist`, and all Qualcomm boot/calibration/NV partitions
  remain untouched.
- Formatting scripts require an explicit destructive confirmation and exact
  partition-size match.
- The installer recovery exposes an ACM control console and a USB ECM link at
  `172.31.66.1/24`. Configfs mass storage is not used because it is unstable on
  this device.
- Storage writes require an installer built with `--write`, an explicit target,
  byte count, SHA-256, and confirmation. The receiver verifies the same byte
  range by reading it back from eMMC.
- Kernel updates produce an image but never flash it from a pacman hook.

## Build order

The scripts must run in exactly this order. Steps 1-3 are host-side builds;
steps 4-6 run on the installer recovery via USB; step 7 is the end-user install.

1. Build the root and rescue ext4 images on exact-size loop devices with
   `scripts/install-arch-rootfs.sh` and `scripts/prepare-rescue-filesystem.sh`.
2. Build and verify the production boot image with
   `scripts/build-arch-boot-image.sh`.
   `scripts/build-arch-boot-image-gcc.sh` builds a separate native-GCC image
   and complete module archive under `linux/build-gcc`. Its
   `-sdm660-gcc+` kernel release keeps GCC modules separate from the Clang
   rollback image.
3. Build `scripts/build-installer-image.sh --target all --write`, flash only the
   recovery partition, and boot it.
4. Run `scripts/configure-installer-network.sh` on the host.
5. Start `receive_arch_image --target system|userdata` on ACM, then stream each
   image with `scripts/send-arch-image.sh --target system|userdata`.
6. Send the production boot image with `receive_arch_boot`; it verifies the
   complete old boot copy in `bootbak` before replacing `boot`.

The first installed account is `alarm`. The installer prompts for both root and
user passwords unless `R11S_SKIP_PASSWORDS=1` is explicitly set.

## Step-by-step guide (x86_64 host)

### 0. Host prerequisites

Debian 12 (bookworm) packages:

```sh
apt-get install -y clang clang-19 lld-19 llvm-19 llvm-19-tools llvm-19-dev \
    llvm-19-linker-tools llvm-19-runtime make bc flex bison \
    libelf-dev libssl-dev zstd cpio gzip device-tree-compiler gcc gcc-aarch64-linux-gnu \
    mkbootimg curl git
```

The kernel is Linux 7.0.x and requires clang >= 15, so a modern clang (19) is
mandatory; the bookworm default clang-14 is too old. Expose the LLVM 19
toolchain:

```sh
mkdir -p /usr/local/llvm19-bin
for t in clang clang++ ld.lld llvm-ar llvm-as llvm-nm llvm-objcopy \
         llvm-objdump llvm-ranlib llvm-readelf llvm-size llvm-strip; do
  ln -sf /usr/bin/$t-19 /usr/local/llvm19-bin/$t
done
export PATH=/usr/local/llvm19-bin:$PATH
```

To make the toolchain available in every new shell, append the PATH export to
`~/.bashrc`:

```sh
echo 'export PATH=/usr/local/llvm19-bin:$PATH' >> ~/.bashrc
```

Then open a new terminal or run `source ~/.bashrc` before building.

`mkbootimg` and `unpack_bootimg` come from the Debian `mkbootimg` package
(1:29.0.6-28).

### 1. Kernel source and configuration

```sh
git clone --depth 1 -b qcom-sdm660-7.0.y \
    https://github.com/NanShengtEAM/linux-sdm660-oppor11_s.git linux
make -C linux O=build ARCH=arm64 LLVM=1 sdm660_defconfig
```

The mainline tree carries the R11S device tree as
`arch/arm64/boot/dts/qcom/sdm660-oppo-r11s.dts` (compatible `oppo,r11s`) and
the modem memshare module as `drivers/soc/qcom/qcom-r11s-memshare.ko`
(Kconfig symbol `QCOM_R11S_MEMSHARE`). Boot images append the DTB to
`Image.gz` so the Qualcomm bootloader selects it.

### 2. Compile kernel and modules

```sh
make -C linux O=build ARCH=arm64 LLVM=1 -j$(nproc) \
    Image.gz qcom/sdm660-oppo-r11s.dtb modules
```

Artifacts: `linux/build/arch/arm64/boot/Image.gz`,
`linux/build/arch/arm64/boot/dts/qcom/sdm660-oppo-r11s.dtb`, and modules
under `linux/build` for `make modules_install`.

### 3. Diagnostic image (produces static busybox first)

```sh
scripts/build-diag-image.sh
```

This builds the AArch64 initramfs root with a static busybox at
`linux/build/initramfs-root/bin/busybox` and the diagnostic
`linux/build/r11s-initramfs.cpio.gz` / diag boot image. The production and
installer images reuse this busybox, so this script must run before them.

If you do not have the prebuilt static busybox yet, build it first with
`scripts/build-static-busybox.sh` (cross-compiles busybox 1.36.1 with
`aarch64-linux-gnu-gcc` and `CONFIG_STATIC=y` into
`linux/build/initramfs-root/bin/busybox`):

### 4. Root and rescue ext4 filesystem images

Create exact-size images first (userdata 56933465600 B, system 3481272320 B):

```sh
scripts/install-arch-rootfs.sh --device /dev/loopX --confirm
scripts/prepare-rescue-filesystem.sh --device /dev/loopY \
    --rootfs-image userdata.img --boot-image boot.img \
    --recovery-image recovery.img --confirm
```

Both format ext4 (no btrfs subvolumes). `finalize-arch-image.sh` shrinks the
53 GiB userdata image to 8 GiB afterward:

```sh
scripts/finalize-arch-image.sh --source userdata-53g.img \
    --output userdata-8g.img --confirm
```

### 5. Production boot image

```sh
scripts/build-arch-boot-image.sh
```

Output `linux/build/boot-r11s-arch.img` with cmdline
`root=PARTLABEL=userdata rootfstype=ext4 rootwait rw rdinit=/init`. The script
verifies the ramdisk stays below the firmware region (0x83000000-0x85600000)
and that the image fits boot. The native-GCC variant
`scripts/build-arch-boot-image-gcc.sh` is intended for building on the device
itself (aarch64 GCC); on x86_64 it is skipped in favour of the LLVM path.

### 6. Installer recovery image

```sh
scripts/build-installer-image.sh --target all --write
```

Output `linux/build/recovery-r11s-installer-ecm-all-write.img`, flashed only
to the `recovery` partition. It carries the initramfs ACM console and the USB
ECM link at 172.31.66.1/24.

### 7. On-device install flow

```sh
scripts/configure-installer-network.sh          # host: bring up 172.31.66.x
# installer console (ACM) : receive_arch_image --target system
scripts/send-arch-image.sh --image system.img --target system
# installer console (ACM) : receive_arch_image --target userdata
scripts/send-arch-image.sh --image userdata.img --target userdata
# installer console (ACM) : receive_arch_boot < boot-r11s-arch.img
```

`receive_arch_boot` verifies the old boot copy in `bootbak` before replacing
`boot`. Kernel updates produce a fresh image but are never auto-flashed by a
pacman hook; flash them manually only after checking bootbak integrity.
