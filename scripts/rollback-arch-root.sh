#!/usr/bin/env bash
set -euo pipefail

EXPECTED_SIZE=56933465600
MOUNT_ROOT=${R11S_ROLLBACK_MOUNT:-/tmp/opencode/r11s-rollback}
RESCUE_ROOT=${R11S_RESCUE_ROOT:-/srv/r11s-rescue}
DEVICE=
RESCUE_DEVICE=
CONFIRM=0

usage() {
	echo "usage: $0 --device /dev/<userdata-lun> [--rescue-device /dev/<system-lun>] --confirm" >&2
	exit 2
}

while (($#)); do
	case "$1" in
	--device) DEVICE=${2:-}; shift 2 ;;
	--rescue-device) RESCUE_DEVICE=${2:-}; shift 2 ;;
	--confirm) CONFIRM=1; shift ;;
	*) usage ;;
	esac
done

[[ $EUID -eq 0 ]] || { echo 'ERROR: run as root' >&2; exit 1; }
[[ $CONFIRM -eq 1 ]] || { echo 'ERROR: --confirm is required' >&2; exit 1; }
[[ -b $DEVICE ]] || { echo "ERROR: not a block device: $DEVICE" >&2; exit 1; }
[[ $(blockdev --getsize64 "$DEVICE") == "$EXPECTED_SIZE" ]] || {
	echo 'ERROR: device does not have the exact R11S userdata size' >&2
	exit 1
}
mountpoint -q "$MOUNT_ROOT" && { echo 'ERROR: rollback mount is busy' >&2; exit 1; }

cleanup() {
	set +e
	mountpoint -q "$MOUNT_ROOT" && umount "$MOUNT_ROOT"
	[[ -n ${RESCUE_DEVICE:-} ]] && mountpoint -q "$RESCUE_ROOT" && umount "$RESCUE_ROOT"
}
trap cleanup EXIT

if ! mountpoint -q "$RESCUE_ROOT"; then
	if [[ -z $RESCUE_DEVICE ]]; then
		[ -e /dev/disk/by-partlabel/system ] || {
			echo 'ERROR: cannot resolve the rescue system partition' >&2
			exit 1
		}
		RESCUE_DEVICE=$(readlink -f /dev/disk/by-partlabel/system)
	fi
	[[ -b $RESCUE_DEVICE ]] || { echo "ERROR: not a block device: $RESCUE_DEVICE" >&2; exit 1; }
	mkdir -p "$RESCUE_ROOT"
	mount -o ro "$RESCUE_DEVICE" "$RESCUE_ROOT"
fi

manifest="$RESCUE_ROOT/installer/rootfs/r11s-arch-rootfs.manifest"
[[ -f $manifest ]] || {
	echo 'ERROR: rescue filesystem has no rootfs manifest' >&2
	exit 1
}
rootfs_image="$RESCUE_ROOT/installer/rootfs/$(sed -n 's/^file=//p' "$manifest")"
[[ -f $rootfs_image ]] || {
	echo 'ERROR: rescue filesystem has no stored rootfs image' >&2
	exit 1
}
expected_size=$(sed -n 's/^size=//p' "$manifest")
expected_hash=$(sed -n 's/^sha256=//p' "$manifest")
[[ $(stat -c %s "$rootfs_image") == "$expected_size" ]] || {
	echo 'ERROR: stored rootfs image size mismatch' >&2
	exit 1
}
stored_hash=$(sha256sum "$rootfs_image" | cut -d' ' -f1)
[[ $stored_hash == "$expected_hash" ]] || {
	echo 'ERROR: stored rootfs image hash mismatch' >&2
	exit 1
}

boot_image="$RESCUE_ROOT/kernels/boot-r11s-arch.img"
[[ -f $boot_image ]] || {
	echo 'ERROR: rescue filesystem has no stored boot image' >&2
	exit 1
}
[[ $(dd if="$boot_image" bs=8 count=1 status=none) == 'ANDROID!' ]] || {
	echo 'ERROR: stored boot image has no Android boot header' >&2
	exit 1
}
boot_hash=$(sha256sum "$boot_image" | cut -d' ' -f1)

echo "Restoring rootfs image ($expected_size bytes) to $DEVICE"
dd if="$rootfs_image" of="$DEVICE" bs=4M conv=fsync status=none
sync
pages=$(( expected_size / 4096 ))
readback_hash=$(dd if="$DEVICE" bs=4096 count="$pages" status=none | \
	sha256sum | cut -d' ' -f1)
[[ $readback_hash == "$expected_hash" ]] || {
	echo "ERROR: userdata readback mismatch: $readback_hash" >&2
	exit 1
}

[ -e /dev/disk/by-partlabel/boot ] && [ -e /dev/disk/by-partlabel/bootbak ] || {
	echo 'ERROR: cannot resolve boot/bootbak partitions' >&2
	exit 1
}
boot=$(readlink -f /dev/disk/by-partlabel/boot)
bootbak=$(readlink -f /dev/disk/by-partlabel/bootbak)
dd if="$boot_image" of="$boot" bs=4096 conv=fsync status=none
dd if="$boot" of="$bootbak" bs=4M conv=fsync status=none
boot_readback=$(sha256sum "$boot" | cut -d' ' -f1)
[[ $boot_readback == "$boot_hash" ]] || {
	echo 'ERROR: boot readback mismatch' >&2
	exit 1
}

echo "Restored rootfs image: $expected_hash"
echo "Restored boot image: $boot_hash"
echo 'Reboot the device to complete the rollback.'
