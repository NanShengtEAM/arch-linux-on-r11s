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
RMTFS_DIR="$SRC_DIR/rmtfs"

# Sources:
#   qrtr  : Debian source package (DebianOnMobile, libqrtr userspace library)
#   rmtfs : upstream OPPO R11T modem storage daemon
QRTR_URL=${QRTR_URL:-https://mirrors.tuna.tsinghua.edu.cn/debian/pool/main/q/qrtr/qrtr_1.0.orig.tar.gz}
GH_MIRROR=${GH_MIRROR:-https://gh-proxy.com/github.com}
RMTFS_GIT="$GH_MIRROR/CPH1707-Mainline/rmtfs-sdm660-oppor11-t.git"

CROSS=${CROSS:-aarch64-linux-gnu-}
CC="${CROSS}gcc"
AR="${CROSS}ar"
STRIP="${CROSS}strip"

fail() { echo "ERROR: $*" >&2; exit 1; }

need() {
	command -v "$1" >/dev/null 2>&1 || fail "missing required tool '$1'. Install it first (e.g. apt-get install ${2:-})."
}

# ---- host toolchain checks -------------------------------------------------
need "$CC" "gcc-aarch64-linux-gnu"
need git
need tar
need gzip
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

# ---- 2. rmtfs (static cross build, sysfs-backed, no libudev) ----------------
if [ ! -d "$RMTFS_DIR" ]; then
	echo "==> fetching rmtfs sources"
	git clone --depth 1 "$RMTFS_GIT" "$RMTFS_DIR"
fi
echo "==> building static rmtfs"
(
	cd "$RMTFS_DIR"
	# -DANDROID selects the sysfs-backed sharedmem path in sharedmem.c,
	# which reads /sys/class/rmtfs/qcom_rmtfs_mem* directly and therefore
	# needs no libudev at all.
	"$CC" -static -O2 -DANDROID -o rmtfs qmi_rmtfs.c rmtfs.c rproc.c sharedmem.c storage.c util.c \
		-I"$QRTR_DIR/lib" -I"$KERNEL_UAPI" \
		'-D__packed=__attribute__((packed))' \
		"$QRTR_DIR/libqrtr.a" -lpthread -lrt
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
