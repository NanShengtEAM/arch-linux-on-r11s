#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
LINUX="$ROOT/linux"
BUILD="$LINUX/build"
SRC_INIT="$ROOT/initramfs"
IR="$BUILD/initramfs-root"

# Kernel 7.0 requires clang >= 15; if the default clang is too old, pick a
# versioned one so LLVM=-NN uses clang-NN/llvm-*-NN from PATH.
# NOTE: do not export any LLVM* variable here: the kernel Makefile defines
# LLVM_PREFIX/LLVM_SUFFIX itself and an env var would corrupt CC (clang1).
LLVM_SUFFIX=1
if ! clang --version 2>/dev/null | grep -qE 'clang version (1[5-9]|2[0-9])'; then
	for v in 19 18 17 16 15; do
		if command -v "clang-$v" >/dev/null 2>&1; then
			LLVM_SUFFIX="-$v"
			break
		fi
	done
fi
LLVM_MAKE="LLVM=$LLVM_SUFFIX"

KVER=$(make -C "$LINUX" O=build ARCH=arm64 $LLVM_MAKE -s kernelrelease)

# GNU strip handles aarch64 static binaries more reliably than llvm-strip,
# which can fail with "Link field value ... is not a symbol table".
if command -v aarch64-linux-gnu-strip >/dev/null 2>&1; then
	STRIP=aarch64-linux-gnu-strip
else
	STRIP=${STRIP:-llvm-strip}
fi

echo "Kernel release: $KVER"

# Preserve busybox if present; rebuild root otherwise.
mkdir -p "$IR"/{bin,lib/modules,lib/firmware,dev,proc,sys,mnt/vendor,mnt/modem}

if [ ! -x "$IR/bin/busybox" ] && [ -x "$IR/bin/busybox.static" ]; then
	cp -a "$IR/bin/busybox.static" "$IR/bin/busybox"
fi
if [ ! -x "$IR/bin/busybox" ]; then
	echo "ERROR: missing $IR/bin/busybox" >&2
	exit 1
fi

cp -a "$SRC_INIT/init" "$IR/init"
chmod 0755 "$IR/init"
if [ -x "$SRC_INIT/gpu-msm-probe" ]; then
	cp -a "$SRC_INIT/gpu-msm-probe" "$IR/bin/gpu-msm-probe"
else
	aarch64-linux-gnu-gcc -static -Os -Wall -Wextra \
		-o "$IR/bin/gpu-msm-probe" "$SRC_INIT/gpu-msm-probe.c"
fi
chmod 0755 "$IR/bin/gpu-msm-probe"
aarch64-linux-gnu-gcc -static -Os -Wall -Wextra \
	-o "$IR/bin/nl80211-scan" "$SRC_INIT/nl80211-scan.c"
$STRIP "$IR/bin/nl80211-scan"
aarch64-linux-gnu-gcc -static -Os -Wall -Wextra \
	-o "$IR/bin/test_keys" "$SRC_INIT/key-test.c"
$STRIP "$IR/bin/test_keys"
aarch64-linux-gnu-gcc -static -Os -Wall -Wextra \
	-o "$IR/bin/bt-hci-test" "$SRC_INIT/bt-hci-test.c"
$STRIP "$IR/bin/bt-hci-test"
aarch64-linux-gnu-gcc -static -Os -Wall -Wextra -Werror \
	-o "$IR/bin/wifi-mac" "$SRC_INIT/wifi-mac.c"
$STRIP "$IR/bin/wifi-mac"
aarch64-linux-gnu-gcc -static -Os -Wall -Wextra -Werror \
	-o "$IR/bin/audio-jack-test" "$SRC_INIT/audio-jack-test.c"
$STRIP "$IR/bin/audio-jack-test"
aarch64-linux-gnu-gcc -static -Os -Wall -Wextra -Werror \
	-o "$IR/bin/audio-tone" "$SRC_INIT/audio-tone.c"
$STRIP "$IR/bin/audio-tone"
aarch64-linux-gnu-gcc -static -Os -Wall -Wextra -Werror \
	-o "$IR/bin/reboot-mode" "$SRC_INIT/reboot-mode.c"
$STRIP "$IR/bin/reboot-mode"
TINYALSA_UTILS=${TINYALSA_UTILS:-/usr/local/r11s/tinyalsa-r11s/utils}
if [ ! -x "$TINYALSA_UTILS/tinymix" ] || [ ! -x "$TINYALSA_UTILS/tinyplay" ] || \
	[ ! -x "$TINYALSA_UTILS/tinycap" ]; then
	echo "building static tinyalsa utils from source"
	mkdir -p /usr/local/src
	TINYALSA_SRC=/usr/local/src/tinyalsa
	if [ ! -d "$TINYALSA_SRC" ]; then
		git clone --depth 1 \
			https://gh-proxy.com/https://github.com/tinyalsa/tinyalsa.git \
			"$TINYALSA_SRC"
	fi
	make -C "$TINYALSA_SRC/src" libtinyalsa.a \
		CC=aarch64-linux-gnu-gcc AR=aarch64-linux-gnu-ar
	make -C "$TINYALSA_SRC/utils" \
		CC=aarch64-linux-gnu-gcc AR=aarch64-linux-gnu-ar \
		LDFLAGS="-L $TINYALSA_SRC/src -static" \
		tinymix tinyplay tinycap
	mkdir -p "$TINYALSA_UTILS"
	for tool in tinymix tinyplay tinycap; do
		cp -a "$TINYALSA_SRC/utils/$tool" "$TINYALSA_UTILS/$tool"
	done
fi
for tool in tinymix tinyplay tinycap; do
	if [ -x "$TINYALSA_UTILS/$tool" ]; then
		cp -a "$TINYALSA_UTILS/$tool" "$IR/bin/$tool"
		$STRIP "$IR/bin/$tool"
	fi
	if [ ! -x "$IR/bin/$tool" ]; then
		echo "ERROR: missing static tinyalsa utility $tool" >&2
		exit 1
	fi
done
if [ -x /usr/local/r11s/tqftpserv/tqftpserv.static ]; then
	cp -a /usr/local/r11s/tqftpserv/tqftpserv.static "$IR/bin/tqftpserv"
fi
if [ -x /usr/local/r11s/diag/diag-router ]; then
	cp -a /usr/local/r11s/diag/diag-router "$IR/bin/diag-router"
fi
for tool in rmtfs tqftpserv diag-router; do
	if [ ! -x "$IR/bin/$tool" ]; then
		cat >&2 <<EOF
WARNING: static diagnostic tool $IR/bin/$tool is missing

These tools (rmtfs, tqftpserv, diag-router) are device bring-up binaries
from the upstream r11t project and are not shipped in this repository.
init/ starts each one only if present (checks -x), so the diag image is
still buildable and bootable without them.

  rmtfs:       run scripts/build-rmtfs.sh to cross-build it automatically
               (fetches libqrtr and builds a static sysfs-backed aarch64
               binary; no libudev needed)
  tqftpserv:   place the static binary at /usr/local/r11s/tqftpserv/tqftpserv.static
  diag-router: place the static binary at /usr/local/r11s/diag/diag-router

Continuing without $tool. To make it mandatory, set R11S_REQUIRE_BRINGUP=1.
EOF
		if [ "${R11S_REQUIRE_BRINGUP:-0}" = 1 ]; then
			exit 1
		fi
		continue
	fi
	chmod 0755 "$IR/bin/$tool"
done

# Display / touch modules already used previously.
mods=(
	"$BUILD/drivers/soc/qcom/mdt_loader.ko"
	"$BUILD/drivers/soc/qcom/ocmem.ko"
	"$BUILD/drivers/soc/qcom/ubwc_config.ko"
	"$BUILD/drivers/soc/qcom/llcc-qcom.ko"
	"$BUILD/drivers/soc/qcom/qcom_aoss.ko"
	"$BUILD/drivers/regulator/qcom-oledb-regulator.ko"
	"$BUILD/drivers/gpu/drm/drm_exec.ko"
	"$BUILD/drivers/gpu/drm/scheduler/gpu-sched.ko"
	"$BUILD/drivers/gpu/drm/drm_gpuvm.ko"
	"$BUILD/drivers/media/cec/core/cec.ko"
	"$BUILD/drivers/gpu/drm/display/drm_display_helper.ko"
	"$BUILD/drivers/gpu/drm/display/drm_dp_aux_bus.ko"
	"$BUILD/drivers/gpu/drm/panel/panel-samsung-s6e3fa3.ko"
	"$BUILD/drivers/gpu/drm/msm/msm.ko"
	"$BUILD/drivers/input/rmi4/rmi_core.ko"
	"$BUILD/drivers/input/rmi4/rmi_i2c.ko"
	# Read-only external fuel-gauge support
	"$BUILD/drivers/power/supply/bq27xxx_battery.ko"
	"$BUILD/drivers/power/supply/bq27xxx_battery_i2c.ko"
	"$BUILD/drivers/iio/adc/qcom-spmi-rradc.ko"
	"$BUILD/drivers/power/supply/qcom_smbx.ko"
	# PM660L notification and camera flash LEDs
	"$BUILD/drivers/leds/led-class-flash.ko"
	"$BUILD/drivers/leds/led-class-multicolor.ko"
	"$BUILD/drivers/leds/rgb/leds-qcom-lpg.ko"
	"$BUILD/drivers/leds/trigger/ledtrig-pattern.ko"
	"$BUILD/drivers/leds/flash/leds-qcom-flash.ko"
	# Wi-Fi stack
	"$BUILD/lib/crypto/libarc4.ko"
	"$BUILD/net/rfkill/rfkill.ko"
	"$BUILD/net/wireless/cfg80211.ko"
	"$BUILD/net/mac80211/mac80211.ko"
	"$BUILD/drivers/net/wireless/ath/ath.ko"
	"$BUILD/drivers/soc/qcom/qmi_helpers.ko"
	"$BUILD/drivers/soc/qcom/rmtfs_mem.ko"
	"$BUILD/drivers/soc/qcom/qcom-r11s-memshare.ko"
	"$BUILD/drivers/soc/qcom/qcom_pdr_msg.ko"
	"$BUILD/drivers/soc/qcom/pdr_interface.ko"
	"$BUILD/drivers/soc/qcom/qcom_pd_mapper.ko"
	"$BUILD/drivers/net/ipa2-lite/ipa2-lite.ko"
	"$BUILD/net/qrtr/qrtr.ko"
	"$BUILD/net/qrtr/qrtr-smd.ko"
	"$BUILD/drivers/remoteproc/qcom_pil_info.ko"
	"$BUILD/drivers/remoteproc/qcom_common.ko"
	"$BUILD/drivers/remoteproc/qcom_sysmon.ko"
	"$BUILD/drivers/remoteproc/qcom_q6v5.ko"
	"$BUILD/drivers/remoteproc/qcom_q6v5_mss.ko"
	"$BUILD/drivers/net/wireless/ath/ath10k/ath10k_core.ko"
	"$BUILD/drivers/net/wireless/ath/ath10k/ath10k_snoc.ko"
	# Bluetooth stack (hci_qca is linked into hci_uart.ko)
	"$BUILD/crypto/ecc.ko"
	"$BUILD/crypto/ecdh_generic.ko"
	"$BUILD/lib/crc/crc-ccitt.ko"
	"$BUILD/net/bluetooth/bluetooth.ko"
	"$BUILD/drivers/bluetooth/btqca.ko"
	"$BUILD/drivers/bluetooth/btintel.ko"
	"$BUILD/drivers/bluetooth/btbcm.ko"
	"$BUILD/drivers/bluetooth/btrtl.ko"
	"$BUILD/drivers/bluetooth/hci_uart.ko"
	# ADSP and internal audio codec stack
	"$BUILD/drivers/remoteproc/qcom_q6v5_pas.ko"
	"$BUILD/drivers/soc/qcom/apr.ko"
	"$BUILD/drivers/pinctrl/qcom/pinctrl-lpass-lpi.ko"
	"$BUILD/drivers/pinctrl/qcom/pinctrl-sdm660-lpass-lpi.ko"
	"$BUILD/sound/soundcore.ko"
	"$BUILD/sound/core/snd.ko"
	"$BUILD/sound/core/snd-timer.ko"
	"$BUILD/sound/core/snd-pcm.ko"
	"$BUILD/sound/core/snd-compress.ko"
	"$BUILD/sound/soc/snd-soc-core.ko"
	"$BUILD/sound/soc/qcom/snd-soc-qcom-common.ko"
	"$BUILD/sound/soc/qcom/qdsp6/snd-q6dsp-common.ko"
	"$BUILD/sound/soc/qcom/qdsp6/q6core.ko"
	"$BUILD/sound/soc/qcom/qdsp6/q6afe.ko"
	"$BUILD/sound/soc/qcom/qdsp6/q6afe-clocks.ko"
	"$BUILD/sound/soc/qcom/qdsp6/q6afe-dai.ko"
	"$BUILD/sound/soc/qcom/qdsp6/q6adm.ko"
	"$BUILD/sound/soc/qcom/qdsp6/q6routing.ko"
	"$BUILD/sound/soc/qcom/qdsp6/q6asm.ko"
	"$BUILD/sound/soc/qcom/qdsp6/q6asm-dai.ko"
	"$BUILD/sound/soc/codecs/snd-soc-msm8916-digital.ko"
	"$BUILD/sound/soc/codecs/snd-soc-msm8916-analog.ko"
	"$BUILD/sound/soc/codecs/snd-soc-ak4375.ko"
	"$BUILD/sound/soc/codecs/snd-soc-tfa989x.ko"
	"$BUILD/sound/soc/qcom/snd-soc-sdm660-int.ko"
)

rm -f "$IR"/lib/modules/*.ko
for m in "${mods[@]}"; do
	if [ ! -f "$m" ]; then
		echo "WARN: missing module $m" >&2
		continue
	fi
	cp -a "$m" "$IR/lib/modules/"
	$STRIP --strip-debug "$IR/lib/modules/$(basename "$m")"
done

# Firmware sources: prefer a staged r11s_pmos-firmware.zip (downloaded from
# the kernel repo qcom-sdm660-7.0.y branch on first use), otherwise the
# device-info/ partition dumps.
FIRMWARE_ZIP=${FIRMWARE_ZIP:-$ROOT/firmware/r11s_pmos-firmware.zip}
FIRMWARE_URL=${FIRMWARE_URL:-https://gh-proxy.com/github.com/NanShengtEAM/linux-sdm660-oppor11_s/raw/refs/heads/qcom-sdm660-7.0.y/r11s_pmos-firmware.zip}
FW_DIR=
if [ ! -f "$FIRMWARE_ZIP" ]; then
	if command -v wget >/dev/null 2>&1 || command -v curl >/dev/null 2>&1; then
		echo "downloading $FIRMWARE_ZIP" >&2
		mkdir -p "$(dirname "$FIRMWARE_ZIP")"
		if command -v wget >/dev/null 2>&1; then
			wget -q -O "$FIRMWARE_ZIP" "$FIRMWARE_URL" || true
		else
			curl -fsSL -o "$FIRMWARE_ZIP" "$FIRMWARE_URL" || true
		fi
	fi
fi
if [ -f "$FIRMWARE_ZIP" ]; then
	command -v unzip >/dev/null 2>&1 || {
		echo "ERROR: firmware zip present but 'unzip' is missing (apt-get install unzip)" >&2
		exit 1
	}
	FW_SRC_ROOT="$BUILD/firmware-src"
	if [ ! -d "$FW_SRC_ROOT/pmos-firmware/lib/firmware" ]; then
		mkdir -p "$FW_SRC_ROOT"
		unzip -q -o "$FIRMWARE_ZIP" -d "$FW_SRC_ROOT"
	fi
	FW_DIR="$FW_SRC_ROOT/pmos-firmware/lib/firmware"
else
	FW_DIR="$ROOT/device-info/firmware"
fi

# GPU firmware: OPPO-signed A512 ZAP + A530 microcode used by A512.
mkdir -p "$IR/lib/firmware/qcom"
GPU_SRC=
if [ -f "$FW_DIR/qcom/a530_pm4.fw" ]; then
	GPU_SRC="$FW_DIR/qcom"
elif [ -d "$ROOT/device-info/firmware/gpu" ]; then
	GPU_SRC="$ROOT/device-info/firmware/gpu"
fi
if [ -n "$GPU_SRC" ]; then
	cp -a "$GPU_SRC/a530_pm4.fw" "$IR/lib/firmware/qcom/"
	cp -a "$GPU_SRC/a530_pfp.fw" "$IR/lib/firmware/qcom/"
	cp -a "$GPU_SRC/a530_pm4.fw" "$IR/lib/firmware/"
	cp -a "$GPU_SRC/a530_pfp.fw" "$IR/lib/firmware/"
	cp -a "$GPU_SRC/a512_zap".* "$IR/lib/firmware/" 2>/dev/null || true
	ln -sfn a512_zap.mdt "$IR/lib/firmware/a512_zap.mbn"
else
	echo "WARNING: GPU firmware (a530/a512_zap) not found; GPU will not initialize" >&2
fi

# Touch firmware (read-only archive in image; not auto-flashed).
if [ -d "$ROOT/device-info/firmware/tp" ]; then
	mkdir -p "$IR/lib/firmware/tp/16051"
	cp -a "$ROOT"/device-info/firmware/tp/* "$IR/lib/firmware/tp/16051/"
fi
if [ -f "$FW_DIR/rmi4/17011_FW_S3508_SYNAPTICS.img" ]; then
	mkdir -p "$IR/lib/firmware/rmi4"
	cp -a "$FW_DIR/rmi4/17011_FW_S3508_SYNAPTICS.img" "$IR/lib/firmware/rmi4/"
fi

# ath10k host firmware (system package preferred, pmos zip as fallback).
mkdir -p "$IR/lib/firmware/ath10k/WCN3990/hw1.0"
for f in /usr/lib/firmware/ath10k/WCN3990/hw1.0/firmware-5.bin \
	/usr/lib/firmware/ath10k/WCN3990/hw1.0/board-2.bin; do
	[ -f "$f" ] && cp -a "$f" "$IR/lib/firmware/ath10k/WCN3990/hw1.0/"
done
if [ -f "$FW_DIR/ath10k/WCN3990/hw1.0/board.bin" ]; then
	cp -a "$FW_DIR/ath10k/WCN3990/hw1.0/board.bin" \
		"$IR/lib/firmware/ath10k/WCN3990/hw1.0/"
fi
# R11S BDF reference (for later board-2 packaging; not consumed raw by ath10k).
if [ -f "$ROOT/device-info/firmware/wifi/bdwlan_16051.bin" ]; then
	cp -a "$ROOT/device-info/firmware/wifi/bdwlan_16051.bin" \
		"$IR/lib/firmware/ath10k/WCN3990/hw1.0/"
fi

# WCN3990 Bluetooth rampatch and NVM (system package preferred, pmos fallback).
mkdir -p "$IR/lib/firmware/qca"
for f in /usr/lib/firmware/qca/crbtfw21.tlv /usr/lib/firmware/qca/crnv21.bin; do
	[ -f "$f" ] && cp -a "$f" "$IR/lib/firmware/qca/"
done
if [ -f "$FW_DIR/qca/crbtfw21.tlv" ]; then
	cp -a "$FW_DIR/qca/crbtfw21.tlv" "$IR/lib/firmware/qca/"
fi
if [ -f "$FW_DIR/qca/crnv21.bin" ]; then
	cp -a "$FW_DIR/qca/crnv21.bin" "$IR/lib/firmware/qca/"
fi

# Regulatory DB if present on host or staged under /usr/local/r11s.
for f in /usr/local/r11s/regulatory.db /usr/local/r11s/regulatory.db.p7s \
	/usr/lib/firmware/regulatory.db /usr/lib/firmware/regulatory.db.p7s \
	/lib/firmware/regulatory.db /lib/firmware/regulatory.db.p7s; do
	[ -f "$f" ] && cp -a "$f" "$IR/lib/firmware/" || true
done

# Rebuild DTB (touch DTS changes) and image.
make -C "$LINUX" O=build ARCH=arm64 $LLVM_MAKE -j"$(nproc)" \
	qcom/sdm660-oppo-r11s.dtb Image.gz

# Pack initramfs.
(
	cd "$IR"
	find . -print0 | cpio --null -ov --format=newc
) | gzip -9 > "$BUILD/r11s-initramfs.cpio.gz"

ramdisk_size=$(stat -c %s "$BUILD/r11s-initramfs.cpio.gz")
ramdisk_limit=$((0x85600000 - 0x83000000))
if (( ramdisk_size >= ramdisk_limit )); then
	printf 'ERROR: ramdisk size %d crosses firmware reservation at 0x85600000\n' \
		"$ramdisk_size" >&2
	exit 1
fi
printf 'Ramdisk boundary: 0x%x (%d bytes free)\n' \
	$((0x83000000 + ramdisk_size)) $((ramdisk_limit - ramdisk_size))

# Append DTB to Image.gz for Qualcomm bootloader selection.
cp "$BUILD/arch/arm64/boot/Image.gz" "$BUILD/arch/arm64/boot/Image.gz-dtb"
dd if="$BUILD/arch/arm64/boot/dts/qcom/sdm660-oppo-r11s.dtb" \
	of="$BUILD/arch/arm64/boot/Image.gz-dtb" oflag=append conv=notrunc status=none

# Kernel at 0x80008000 expands ~27MiB. Firmware reserved begins at 0x85600000.
# Keep ramdisk below that: use 0x83000000 (base 0x80000000 + 0x03000000),
# leaving ~38MiB before 0x85600000. Do NOT use 0x84000000 once initramfs >22MiB.
mkbootimg \
	--kernel "$BUILD/arch/arm64/boot/Image.gz-dtb" \
	--ramdisk "$BUILD/r11s-initramfs.cpio.gz" \
	--pagesize 4096 \
	--base 0x80000000 \
	--kernel_offset 0x00008000 \
	--ramdisk_offset 0x03000000 \
	--second_offset 0x00f00000 \
	--tags_offset 0x00000100 \
	--header_version 1 \
	--os_version 9.0.0 \
	--os_patch_level 2019-09 \
	--cmdline 'console=tty0 console=ttyMSM0,115200n8 androidboot.console=ttyMSM0 earlycon=msm_serial_dm,0xc170000 androidboot.hardware=qcom user_debug=31 printk.devkmsg=on loglevel=8 ignore_loglevel keep_bootcon panic=10 root=/dev/ram0 rw rdinit=/init init=/init' \
	-o "$BUILD/recovery-r11s-diag.img"

echo "=== image info ==="
rm -rf "$BUILD/unpack-verify"
unpack_bootimg --boot_img "$BUILD/recovery-r11s-diag.img" --out "$BUILD/unpack-verify" >/dev/null
sha256sum "$BUILD/recovery-r11s-diag.img"
ls -lh "$BUILD/recovery-r11s-diag.img" "$BUILD/r11s-initramfs.cpio.gz"
echo "modules:"; ls -1 "$IR/lib/modules" | wc -l
du -sh "$IR" "$IR/lib/firmware" "$IR/lib/modules"
