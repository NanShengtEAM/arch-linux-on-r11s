#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
IMAGE=${1:-}
BOOT_IMAGE=${2:-$ROOT/linux/build/boot-r11s-arch.img}
MOUNT_ROOT=/tmp/r11s-update-root
LOOP=

usage() {
	echo "usage: $0 ROOTFS_IMAGE [BOOT_IMAGE]" >&2
	exit 2
}

[[ $EUID -eq 0 ]] || { echo 'ERROR: run as root' >&2; exit 1; }
[[ -n $IMAGE && -f $IMAGE && -f $BOOT_IMAGE ]] || usage
[[ $(stat -c %s "$IMAGE") -eq $((8 * 1024 * 1024 * 1024)) ]] || {
	echo 'ERROR: deployment rootfs must be exactly 8 GiB' >&2
	exit 1
}
[[ $(dd if="$BOOT_IMAGE" bs=8 count=1 status=none) == 'ANDROID!' ]] || {
	echo 'ERROR: boot image has no Android boot magic' >&2
	exit 1
}

cleanup() {
	set +e
	mountpoint -q "$MOUNT_ROOT" && umount "$MOUNT_ROOT"
	[[ -n $LOOP ]] && losetup -d "$LOOP"
}
trap cleanup EXIT

mkdir -p "$MOUNT_ROOT"
LOOP=$(losetup --find --show "$IMAGE")
mount -o rw,noatime "$LOOP" "$MOUNT_ROOT"

cp -a --no-preserve=ownership "$ROOT/archlinux/rootfs-overlay/." "$MOUNT_ROOT/"
grep -qxF DisableSandbox "$MOUNT_ROOT/etc/pacman.conf" ||
	sed -i '/^\[options\]$/a DisableSandbox' "$MOUNT_ROOT/etc/pacman.conf"
install -m 0755 "$ROOT/linux/build/initramfs-root/bin/bt-hci-test" \
	"$MOUNT_ROOT/usr/lib/r11s/bt-hci-test"
install -m 0644 "$BOOT_IMAGE" "$MOUNT_ROOT/usr/lib/r11s/boot-r11s-arch.img"

if [[ ${R11S_SKIP_MODULE_INSTALL:-0} != 1 ]]; then
	make -C "$ROOT/linux" O=build ARCH=arm64 INSTALL_MOD_PATH="$MOUNT_ROOT" \
		INSTALL_MOD_STRIP=1 modules_install
fi
set -- "$MOUNT_ROOT"/lib/modules/*
[[ $# -eq 1 && -d $1 ]] || {
	echo 'ERROR: expected exactly one installed kernel module version' >&2
	exit 1
}
kernel_release=${1##*/}
rm -f "$1/build" "$1/source"
depmod -b "$MOUNT_ROOT" "$kernel_release"

if [[ -n ${R11S_PASSWORD:-} ]]; then
	printf 'root:%s\nalarm:%s\n' "$R11S_PASSWORD" "$R11S_PASSWORD" | \
		chroot "$MOUNT_ROOT" /usr/sbin/chpasswd
fi

for unit in NetworkManager.service bluetooth.service sshd.service \
	r11s-usb-gadget.service serial-getty@ttyGS0.service fstrim.timer \
	r11s-grow-root.service r11s-hardware.target sddm.service; do
	systemctl --root="$MOUNT_ROOT" enable "$unit" >/dev/null
done

sync
umount "$MOUNT_ROOT"
losetup -d "$LOOP"
LOOP=
e2fsck -fn "$IMAGE"
sha256sum "$IMAGE" "$BOOT_IMAGE"
