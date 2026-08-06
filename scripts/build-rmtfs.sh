#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
LINUX="$ROOT/linux"
BUILD="$LINUX/build"
IR="$BUILD/initramfs-root"
KERNEL_UAPI="$LINUX/include/uapi"

BRINGUP=${BRINGUP:-/usr/local/r11s/bringup}
SRC_DIR="$BRINGUP/src"
QRTR_DIR="$SRC_DIR/qrtr"
EUDEV_DIR="$SRC_DIR/eudev"
RMTFS_DIR="$SRC_DIR/rmtfs"

# Sources:
#   qrtr   : Debian source package (DebianOnMobile, libqrtr userspace library)
#   eudev  : independent udev implementation, built for static libudev.a
#   rmtfs  : upstream OPPO R11T modem storage daemon
QRTR_URL=${QRTR_URL:-https://mirrors.tuna.tsinghua.edu.cn/debian/pool/main/q/qrtr/qrtr_1.0.orig.tar.gz}
GH_MIRROR=${GH_MIRROR:-https://gh-proxy.com/github.com}
EUDEV_GIT="$GH_MIRROR/eudev-project/eudev.git"
RMTFS_GIT="$GH_MIRROR/CPH1707-Mainline/rmtfs-sdm660-oppor11-t.git"

CROSS=${CROSS:-aarch64-linux-gnu-}
HOST_TUPLE=${CROSS%-}
CC="${CROSS}gcc"
AR="${CROSS}ar"
STRIP="${CROSS}strip"

fail() { echo "ERROR: $*" >&2; exit 1; }

need() {
	command -v "$1" >/dev/null 2>&1 || fail "missing required tool '$1'. Install it first (e.g. apt-get install ${2:-})."
}

# ---- host toolchain checks -------------------------------------------------
need "$CC" "gcc-aarch64-linux-gnu"
need make
need autoconf
need automake
need libtoolize "libtool"
need gperf
if command -v wget >/dev/null 2>&1; then
	fetch() { wget -q -O "$1" "$2"; }
else
	need curl
	fetch() { curl -fsSL -o "$1" "$2"; }
fi

mkdir -p "$SRC_DIR" "$IR/bin"

# ---- 1. libqrtr (userspace QRTR library) -----------------------------------
if [ ! -d "$QRTR_DIR" ]; then
	echo "==> fetching qrtr sources"
	mkdir -p "$QRTR_DIR"
	ARCHIVE="$SRC_DIR/qrtr_1.0.orig.tar.gz"
	fetch "$ARCHIVE" "$QRTR_URL"
	tar xzf "$ARCHIVE" -C "$QRTR_DIR" --strip-components=1
fi
echo "==> building libqrtr.a"
(
	cd "$QRTR_DIR"
	"$CC" -c lib/logging.c lib/qrtr.c lib/qmi.c -Ilib -Isrc -I"$KERNEL_UAPI" -O2 \
		'-D__packed=__attribute__((packed))'
	"$AR" rcs libqrtr.a logging.o qrtr.o qmi.o
)

# ---- 2. eudev (for a static libudev.a) -------------------------------------
if [ ! -d "$EUDEV_DIR" ]; then
	echo "==> fetching eudev sources"
	git clone --depth 1 "$EUDEV_GIT" "$EUDEV_DIR"
fi
echo "==> building static libudev.a"
(
	cd "$EUDEV_DIR"
	if [ ! -f configure ]; then
		./autogen.sh || true
		[ -f configure ] || fail "eudev autogen.sh did not produce configure"
	fi
	if [ ! -f Makefile ]; then
		./configure --host="$HOST_TUPLE" --disable-selinux --disable-kmod \
			--disable-manpages --disable-gudev --disable-blkid \
			--disable-rule-generator --prefix="$BRINGUP"
	fi
	make -C src/shared
	make -C src/libudev
	[ -f src/libudev/.libs/libudev.a ] || fail "eudev build did not produce libudev.a"
)

# ---- 3. rmtfs (static cross build) ------------------------------------------
if [ ! -d "$RMTFS_DIR" ]; then
	echo "==> fetching rmtfs sources"
	git clone --depth 1 "$RMTFS_GIT" "$RMTFS_DIR"
fi
echo "==> building static rmtfs"
(
	cd "$RMTFS_DIR"
	"$CC" -static -O2 -o rmtfs qmi_rmtfs.c rmtfs.c rproc.c sharedmem.c storage.c util.c \
		-I"$QRTR_DIR/lib" -I"$KERNEL_UAPI" -I"$EUDEV_DIR/src/libudev" \
		'-D__packed=__attribute__((packed))' \
		"$QRTR_DIR/libqrtr.a" "$EUDEV_DIR/src/libudev/.libs/libudev.a" \
		-lpthread -lrt
	"$STRIP" rmtfs
)
cp -a "$RMTFS_DIR/rmtfs" "$IR/bin/rmtfs"
chmod 0755 "$IR/bin/rmtfs"

# ---- verify ----------------------------------------------------------------
echo "==> installed $IR/bin/rmtfs"
file "$IR/bin/rmtfs"
if aarch64-linux-gnu-readelf -l "$IR/bin/rmtfs" 2>/dev/null | grep -q 'INTERP'; then
	fail "rmtfs was not statically linked (has INTERP)"
fi
echo "rmtfs is a static aarch64 binary. Re-run scripts/build-diag-image.sh to continue."
