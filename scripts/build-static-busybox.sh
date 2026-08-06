#!/usr/bin/env bash
set -euo pipefail

# Build a static AArch64 busybox into $BUILD/initramfs-root/bin/busybox,
# which build-diag-image.sh requires. Run this once before the image builders.
# Requires: aarch64-linux-gnu-gcc, curl, tar, bzip2.

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
LINUX="$ROOT/linux"
BUILD="$LINUX/build"
DEST="$BUILD/initramfs-root/bin/busybox"

BUSYBOX_VER=${BUSYBOX_VER:-1.36.1}
SRC_ROOT=/usr/local/src
TARBALL="$SRC_ROOT/busybox-$BUSYBOX_VER.tar.bz2"
WORK="$SRC_ROOT/busybox-$BUSYBOX_VER"

[ -x "$DEST" ] && {
	echo "busybox already present: $DEST"
	exit 0
}

command -v aarch64-linux-gnu-gcc >/dev/null || {
	echo "ERROR: aarch64-linux-gnu-gcc not found" >&2
	echo "Install: apt-get install -y gcc-aarch64-linux-gnu" >&2
	exit 1
}

mkdir -p "$SRC_ROOT"
if [ ! -f "$TARBALL" ]; then
	curl -fsSL -o "$TARBALL" \
		"https://busybox.net/downloads/busybox-$BUSYBOX_VER.tar.bz2"
fi
if [ ! -d "$WORK" ]; then
	tar xf "$TARBALL" -C "$SRC_ROOT"
fi
cd "$WORK"

make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- defconfig
sed -i 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config
grep -q '^CONFIG_STATIC=y' .config || {
	echo "ERROR: failed to enable CONFIG_STATIC" >&2
	exit 1
}
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j"$(nproc)"

mkdir -p "$BUILD/initramfs-root/bin"
cp -a busybox "$DEST"
chmod 0755 "$DEST"

aarch64-linux-gnu-readelf -l "$DEST" | grep -q INTERP && {
	echo "ERROR: busybox is not static (INTERP section found)" >&2
	exit 1
}

echo "Static AArch64 busybox installed: $DEST"
aarch64-linux-gnu-readelf -h "$DEST" | grep -E 'Class|Machine'
