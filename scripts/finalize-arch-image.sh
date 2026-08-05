#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SOURCE=
OUTPUT=
CONFIRM=0
SOURCE_SIZE=56933465600
OUTPUT_SIZE=8589934592
MOUNT_ROOT=${R11S_FINALIZE_MOUNT:-/tmp/opencode/r11s-finalize}

while (($#)); do
	case "$1" in
	--source) SOURCE=${2:-}; shift 2 ;;
	--output) OUTPUT=${2:-}; shift 2 ;;
	--confirm) CONFIRM=1; shift ;;
	*) echo "usage: $0 --source 53g.img --output 8g.img --confirm" >&2; exit 2 ;;
	esac
done

[[ $EUID -eq 0 ]] || { echo 'ERROR: run as root' >&2; exit 1; }
[[ $CONFIRM -eq 1 ]] || { echo 'ERROR: --confirm is required' >&2; exit 1; }
[[ -f $SOURCE ]] || { echo 'ERROR: source image not found' >&2; exit 1; }
[[ $(stat -c %s "$SOURCE") == "$SOURCE_SIZE" ]] || {
	echo 'ERROR: source image does not have the R11S userdata size' >&2
	exit 1
}
[[ ! -e $OUTPUT ]] || { echo 'ERROR: output already exists' >&2; exit 1; }
[[ -f $ROOT/linux/build/boot-r11s-arch.img ]] || {
	echo 'ERROR: build the production boot image first' >&2
	exit 1
}

mkdir -p "$MOUNT_ROOT"
cp --reflink=auto --sparse=always "$SOURCE" "$OUTPUT"
LOOP=$(losetup --find --show "$OUTPUT")
mounted_root=0
cleanup() {
	if (( mounted_root )); then umount "$MOUNT_ROOT" || true; fi
	[[ -n ${LOOP:-} ]] && losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup EXIT

mount -o rw,noatime "$LOOP" "$MOUNT_ROOT"
mounted_root=1

cp -a --no-preserve=ownership "$ROOT/archlinux/rootfs-overlay/." "$MOUNT_ROOT/"
grep -qxF DisableSandbox "$MOUNT_ROOT/etc/pacman.conf" ||
	sed -i '/^\[options\]$/a DisableSandbox' "$MOUNT_ROOT/etc/pacman.conf"
find "$MOUNT_ROOT/usr/lib/r11s" -type f -exec chmod 0755 {} +
install -m 0755 "$ROOT/linux/build/initramfs-root/bin/bt-hci-test" \
	"$MOUNT_ROOT/usr/lib/r11s/bt-hci-test"
install -m 0644 "$ROOT/linux/build/boot-r11s-arch.img" \
	"$MOUNT_ROOT/usr/lib/r11s/boot-r11s-arch.img"

for unit in NetworkManager.service bluetooth.service sshd.service \
	r11s-usb-gadget.service serial-getty@ttyGS0.service fstrim.timer \
	r11s-grow-root.service r11s-hardware.target sddm.service; do
	systemctl --root="$MOUNT_ROOT" enable "$unit"
done
systemd-analyze verify --man=no --generators=no --root="$MOUNT_ROOT" \
	r11s-grow-root.service r11s-hardware.target sddm.service \
	NetworkManager.service bluetooth.service

sync
umount "$MOUNT_ROOT"
mounted_root=0
losetup -d "$LOOP"
LOOP=

min_blocks=$(resize2fs -P "$OUTPUT" 2>/dev/null |
	grep -oE 'minimum size of the filesystem: [0-9]+' |
	awk '{print $NF}')
max_blocks=$((OUTPUT_SIZE / 4096))
[[ -n $min_blocks && $min_blocks -le $max_blocks ]] || {
	echo "ERROR: rootfs data does not fit in the $OUTPUT_SIZE-byte output image" >&2
	exit 1
}

e2fsck -f "$OUTPUT" >/dev/null
resize2fs "$OUTPUT" 8G >/dev/null
truncate -s "$OUTPUT_SIZE" "$OUTPUT"
LOOP=$(losetup --find --show --read-only "$OUTPUT")
trap '[[ -n ${LOOP:-} ]] && losetup -d "$LOOP" 2>/dev/null || true' EXIT
e2fsck -fn "$LOOP" >/dev/null
losetup -d "$LOOP"
LOOP=
trap - EXIT

echo "Final image: $OUTPUT"
stat -c 'size=%s allocated_blocks=%b' "$OUTPUT"
sha256sum "$OUTPUT"
