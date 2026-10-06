#!/bin/sh
# Confirm every piece actually landed in the built rootfs.squashfs, the same way
# this whole project verified things without real hardware: unsquashfs presence
# checks plus readelf/file architecture checks on anything compiled. This is
# NOT a substitute for the real boot test (needs the user present) - it only
# proves the image contains what it's supposed to.
set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
IMAGES="$REPO_ROOT/vendor/system/buildroot/output/images"
KERNEL_CONFIG="$REPO_ROOT/vendor/system/buildroot/output/build/linux-custom/.config"
MANIFEST_FILE="$REPO_ROOT/artifacts/buildroot-halley5-v30-image/build-manifest.txt"

# 2026-08-07: source the same manifests/dependencies.conf every other pin-
# aware script reads, instead of a second, independently-hardcoded copy of
# each SHA - real bug found by this mission's own clean-room test: the
# Klipper pin here still said d839d037... after 00-fetch-vendor-sources.sh
# had long since moved to 0e5785dac..., so this script silently reported a
# false "pin drift" MISS against a checkout that was actually correct.
DEPS_MANIFEST="$REPO_ROOT/manifests/dependencies.conf"
[ -f "$DEPS_MANIFEST" ] || { echo "FATAL: $DEPS_MANIFEST not found" >&2; exit 1; }
. "$DEPS_MANIFEST"

if [ -f "$IMAGES/rootfs.squashfs" ]; then
	SQUASHFS="$IMAGES/rootfs.squashfs"
elif [ -f "$REPO_ROOT/artifacts/buildroot-halley5-v30-image/rootfs.squashfs" ]; then
	SQUASHFS="$REPO_ROOT/artifacts/buildroot-halley5-v30-image/rootfs.squashfs"
else
	echo "rootfs.squashfs not found - run 05-final-build.sh first" >&2
	exit 1
fi

# Vendor source pin drift checks validate the active pinned and moving
# repositories without fetching or modifying them.
echo "=== vendor source pin drift ==="
# Extended 2026-07-31 (NEBULAOS_CAMERA_USB_RT_SOURCE_ANALYSIS.md's vendor-pin
# audit): now also verifies the origin remote URL (catches a checkout quietly
# repointed at a fork/mirror) and working-tree cleanliness against an
# explicit per-repo allowlist of paths this project's own build scripts
# deterministically modify (e.g. the OKE System Buildroot subtree's generated
# config-layer copy-in) -
# an allowed path showing as different is NOT silently ignored as "fine
# either way", it's explicitly named so a reader knows exactly why it's
# expected, same convention as the rest of this project's "corrected in
# place with a note" pattern.
check_vendor_pin() {
	vp_name="$1"
	vp_expected="$2"
	vp_expected_url="$3"
	vp_bulk_dirty_expected="$4"
	shift 4
	vp_dir="$REPO_ROOT/vendor/$vp_name"
	if [ ! -d "$vp_dir/.git" ]; then
		echo "MISS vendor/$vp_name is not a git checkout - cannot verify its expected commit"
		return
	fi
	vp_actual=$(git -C "$vp_dir" rev-parse HEAD 2>/dev/null || echo "unknown")
	if [ "$vp_actual" = "$vp_expected" ]; then
		echo "OK   vendor/$vp_name HEAD matches its expected commit ($vp_expected)"
	else
		echo "MISS vendor/$vp_name HEAD is $vp_actual, expected commit $vp_expected"
	fi
	if [ -n "$vp_expected_url" ]; then
		vp_remotes=$(git -C "$vp_dir" remote -v 2>/dev/null)
		if printf '%s\n' "$vp_remotes" | grep -qF "$vp_expected_url"; then
			echo "OK   vendor/$vp_name has a remote matching $vp_expected_url"
		else
			echo "MISS vendor/$vp_name has no remote matching expected URL $vp_expected_url"
		fi
	fi
	vp_dirty=$(git -C "$vp_dir" status --porcelain -uall 2>/dev/null)
	for vp_allow in "$@"; do
		vp_dirty=$(printf '%s\n' "$vp_dirty" | grep -v -F "$vp_allow" || true)
	done
	vp_dirty=$(printf '%s\n' "$vp_dirty" | sed '/^$/d')
	if [ -z "$vp_dirty" ]; then
		echo "OK   vendor/$vp_name working tree has no unexplained changes"
	elif [ "$vp_bulk_dirty_expected" = "1" ]; then
		echo "OK   vendor/$vp_name working tree is dirty, as expected once apply-qualified-baseline.sh has run - see assert-baseline-config.sh for the real content-level check of this checkout's variant patches (too many individual paths across 9 variants to allowlist here without this list silently going stale again):"
		printf '%s\n' "$vp_dirty" | sed 's/^/     /'
	else
		echo "MISS vendor/$vp_name has unexplained working-tree changes:"
		printf '%s\n' "$vp_dirty" | sed 's/^/     /'
	fi
}
# Klipper runtime remains official upstream, pinned to the extension
# manifest's compatibility-qualified commit.
check_vendor_pin klipper "$KLIPPER_PIN" \
	"$KLIPPER_REPO" 0 \
	klippy/chelper/c_helper.so
check_vendor_pin klipper-extensions "$KLIPPER_EXTRAS_PIN" \
	"$KLIPPER_EXTRAS_REPO" 0
check_vendor_pin klipper-mcu "$MCU_PIN" \
	"$MCU_REPO" 0 \
	scripts/build.sh \
	configs/ender3-v3-se.defconfig \
	configs/ender3-v2-neo.defconfig
check_vendor_pin moonraker "$MOONRAKER_PIN" \
	"$MOONRAKER_REPO" 0
# Buildroot is the `buildroot/` subtree of the same OKE System checkout as
# the kernel. The shared checkout is validated above; verify the subtree is
# present and has the expected Buildroot entry point after configuration.
buildroot_dir="$REPO_ROOT/vendor/system/buildroot"
if [ -f "$buildroot_dir/Makefile" ]; then
	echo "OK   vendor/system/buildroot is the active OKE Buildroot subtree"
else
	echo "MISS vendor/system/buildroot is missing its Buildroot Makefile"
fi
check_vendor_pin k1-ustreamer "$K1_USTREAMER_PIN" \
	"$K1_USTREAMER_REPO" 0
# k1-ustreamer's own real git submodules (jpeg-9d, ustreamer) - pinned via
# the parent commit's own recorded submodule SHAs, so a plain `git status`
# on the parent won't show submodule drift; `submodule status` is the real
# check (a leading '+' means checked out at a different SHA than recorded,
# '-' means not initialized).
if [ -d "$REPO_ROOT/vendor/k1-ustreamer/.git" ]; then
	ku_submodules=$(git -C "$REPO_ROOT/vendor/k1-ustreamer" submodule status 2>/dev/null)
	if printf '%s\n' "$ku_submodules" | grep -qE '^[+-]'; then
		echo "MISS vendor/k1-ustreamer submodules are not at their pinned commits:"
		printf '%s\n' "$ku_submodules" | sed 's/^/     /'
	else
		echo "OK   vendor/k1-ustreamer submodules (jpeg-9d, ustreamer) match their pinned commits"
	fi
fi
# system: immutable dependency. Stages 00 and 01 check the checkout against
# SYSTEM_PIN before variants are composed.
#
# bulk_dirty_expected=1: this checkout is DELIBERATELY left dirty by
# apply-qualified-baseline.sh (9 accepted variant patches applied on top of
# the fetched branch HEAD) by the time this verify step runs - not drift.
# assert-baseline-config.sh (run earlier in the pipeline) is the real,
# precise content-level check of what that dirt should contain.
system_dir="$REPO_ROOT/vendor/system"
system_actual=$(git -C "$system_dir" rev-parse HEAD 2>/dev/null || echo "unknown")
if [ "$system_actual" = "$SYSTEM_PIN" ]; then
	echo "OK   vendor/system matches pinned commit $system_actual"
else
	echo "MISS vendor/system is HEAD=$system_actual, expected pinned commit $SYSTEM_PIN"
fi
system_remotes=$(git -C "$system_dir" remote -v 2>/dev/null)
if printf '%s\n' "$system_remotes" | grep -qF "$SYSTEM_REPO"; then
	echo "OK   vendor/system has a remote matching $SYSTEM_REPO"
else
	echo "MISS vendor/system has no remote matching expected URL $SYSTEM_REPO"
fi
system_dirty=$(git -C "$system_dir" status --porcelain -uall 2>/dev/null)
if [ -z "$system_dirty" ]; then
	echo "OK   vendor/system working tree has no unexplained changes"
else
	echo "OK   vendor/system working tree is dirty, as expected after apply-qualified-baseline.sh:"
	printf '%s\n' "$system_dirty" | sed 's/^/     /'
fi
# GuppyScreen is pinned by GUPPYSCREEN_PIN; verify both the pinned HEAD and the
# expected remote URL. The three allowlisted submodules are modified
# deterministically by the fetch/build stages (spdlog, lvgl, and libhv).
check_vendor_pin guppyscreen "$GUPPYSCREEN_PIN" \
	"$GUPPYSCREEN_REPO" 0 \
	libhv \
	lvgl \
	spdlog

echo "=== release artifact provenance (docs/NEBULAOS_RELEASE_ARTIFACT_PROVENANCE.md) ==="
check_artifact_sha256() {
	ca_path="$REPO_ROOT/$1"
	ca_expected="$2"
	if [ ! -f "$ca_path" ]; then
		echo "MISS $1 does not exist - cannot verify its hash"
		return
	fi
	ca_actual=$(sha256sum "$ca_path" | awk '{print $1}')
	if [ "$ca_actual" = "$ca_expected" ]; then
		echo "OK   $1 sha256 matches recorded provenance ($ca_expected)"
	else
		echo "MISS $1 sha256 is $ca_actual, expected recorded provenance $ca_expected"
	fi
}
check_artifact_sha256 vendor/mainsail-dist/mainsail.zip \
	"$MAINSAIL_SHA256"

# GuppyScreen's source is pinned, but its binary is still validated against
# the build manifest rather than a fixed hash because the toolchain embeds a
# build timestamp. Check self-consistency against THIS run's build-manifest.txt
# instead (already-recorded guppyscreen_sha256/guppybeep_sha256, right
# next to the source commit git_commit_guppyscreen that actually determines
# correctness) plus a real MIPS-ELF sanity check.
check_guppyscreen_binary() {
	gb_path="$REPO_ROOT/$1"
	gb_manifest_key="$2"
	if [ ! -f "$gb_path" ]; then
		echo "MISS $1 does not exist"
		return
	fi
	if ! file "$gb_path" 2>/dev/null | grep -q "MIPS.*statically linked"; then
		echo "MISS $1 is not a statically-linked MIPS ELF binary ($(file "$gb_path" 2>/dev/null))"
		return
	fi
	gb_recorded=$(grep "^${gb_manifest_key}=" "$MANIFEST_FILE" 2>/dev/null | cut -d= -f2)
	gb_actual=$(sha256sum "$gb_path" | awk '{print $1}')
	if [ -z "$gb_recorded" ]; then
		echo "MISS $1 - no $gb_manifest_key recorded in $MANIFEST_FILE (05-final-build.sh should have written one)"
	elif [ "$gb_actual" = "$gb_recorded" ]; then
		echo "OK   $1 sha256 matches this build's own manifest record ($gb_actual) - source pinned separately via git_commit_guppyscreen"
	else
		echo "MISS $1 sha256 is $gb_actual, this build's manifest recorded $gb_recorded - manifest is stale or binary was replaced after the build"
	fi
}
check_guppyscreen_binary artifacts/guppyscreen-mips/guppyscreen guppyscreen_sha256
check_guppyscreen_binary artifacts/guppyscreen-mips/guppybeep guppybeep_sha256

check_artifact_sha256 scripts/build/overlay/lib/firmware/brcm/brcmfmac43430-sdio.bin \
	82ed67a211877efa47aff4aab83d6d2d1ccf3d5d0f5c396df97f292ade01de9e
check_artifact_sha256 scripts/build/overlay/lib/firmware/brcm/brcmfmac43430-sdio.clm_blob \
	1dbe1a396b68786bb189b7c255318ae546fd2e9d15f70ccc8ecbdc52b6cd4c47
check_artifact_sha256 scripts/build/overlay/lib/firmware/brcm/brcmfmac43430-sdio.txt \
	78fee458ab69c0a66ea462f6d6769e15b36f73582693f4dbb5a0e8e8be3cfb0a
check_artifact_sha256 scripts/build/overlay/lib/firmware/regulatory.db \
	0a4abd7ae20d07bb70642937ccb2293a72a6504730eea45a698882599f586368
check_artifact_sha256 scripts/build/overlay/lib/firmware/regulatory.db.p7s \
	bcd81aed039ea6b9b6f3726fbf26911a0caf4a5d894210e0fa2effb384d6b326

# ns2009, the display panel, brcmfmac and the RNG are all built statically
# into vmlinux (=y, not =m) - see halley5-openke-fragment.config's own
# comments for why each one was switched. A built-in driver produces no
# separate .ko file under /lib/modules at all, so these are checked against
# the actual built kernel .config instead of unsquashfs'd out of rootfs.squashfs -
# checking for a .ko file here would silently and permanently report MISS
# for correctly-working built-in support.
echo "=== built-in kernel drivers (not loadable modules) ==="
if [ -f "$KERNEL_CONFIG" ]; then
	check_builtin() {
		sym="$1"
		if grep -q "^${sym}=y$" "$KERNEL_CONFIG"; then
			echo "OK   $sym=y (built-in)"
		else
			echo "MISS $sym"
		fi
	}
	check_builtin CONFIG_TOUCHSCREEN_NS2009
	check_builtin CONFIG_STAGE_OPENKE_GENERAL_480X272
	check_builtin CONFIG_BRCMFMAC
	check_builtin CONFIG_INGENIC_HW_RANDOM
	# NebulaOS Memory Resilience Gate: real bug this catches if regressed -
	# the original OOM/no-swap incident happened precisely because these
	# were silently absent from the kernel; a plain rootfs file check
	# can't see kernel config at all, so this is the only place a clean
	# build can catch this specific regression.
	check_builtin CONFIG_SWAP
	check_builtin CONFIG_ZRAM
	check_builtin CONFIG_CRYPTO_LZ4
	# Two competing WiFi drivers were a real, previously-hit bug (FIRMWARE.md
	# sec 24/36) - confirm the vendor's out-of-tree one stays disabled.
	if grep -q "^CONFIG_BCMDHD=y$" "$KERNEL_CONFIG"; then
		echo "MISS CONFIG_BCMDHD is set - conflicts with CONFIG_BRCMFMAC for the same SDIO chip"
	else
		echo "OK   CONFIG_BCMDHD not set (brcmfmac is the only WiFi driver)"
	fi
	# FIRMWARE.md sec 53: CONFIG_BRCMFMAC=y means brcmfmac's own firmware
	# request happens before the real rootfs is mounted - embedding the
	# firmware in the kernel image itself is what actually makes WiFi work,
	# not just having the files present in rootfs.squashfs (checked separately
	# below - both need to be true).
	if grep -q '^CONFIG_EXTRA_FIRMWARE="brcm/brcmfmac43430-sdio\.bin brcm/brcmfmac43430-sdio\.txt' "$KERNEL_CONFIG"; then
		echo "OK   CONFIG_EXTRA_FIRMWARE set (WiFi firmware embedded in the kernel image)"
	else
		echo "MISS CONFIG_EXTRA_FIRMWARE not set as expected - did fetch-cyw43430-wifi-firmware.sh run before 02-configure-buildroot.sh?"
	fi
	# FIRMWARE.md sec 23 (2026-07-23): the base vendor defconfig has this off
	# (a kernel-size trim, not deliberate for this project) - without it,
	# flock()/fcntl locking fail kernel-wide (ENOSYS/EACCES on a brand new,
	# uncontended file, confirmed on real hardware), which broke Moonraker
	# with sqlite3.OperationalError: database is locked on its very first
	# database open. Affects anything using file locks, not just sqlite.
	check_builtin CONFIG_FILE_LOCKING
	# Phase 1.9A/1.9B: ADXL345's bit-banged SPI bus and the physical
	# BL24C16F EEPROM's real production driver (at24/nvmem, NOT
	# [bl24c16f]/i2c-chardev - see accelerometer-eeprom-bus-enable-
	# variant.sh and OpenKE_Settings.cfg's own Phase 1.9B history).
	check_builtin CONFIG_SPI_GPIO
	check_builtin CONFIG_EEPROM_AT24
	if grep -q "^CONFIG_I2C_CHARDEV=y$" "$KERNEL_CONFIG"; then
		echo "MISS CONFIG_I2C_CHARDEV is set - Phase 1.9B retired its only consumer ([bl24c16f]/klipper_mcu i2c.c); it should no longer be needed"
	else
		echo "OK   CONFIG_I2C_CHARDEV not set (retired, Phase 1.9B - at24 is a real kernel driver, no /dev/i2c-* chardev needed)"
	fi
else
	echo "MISS $KERNEL_CONFIG not found - run 03-build-kernel-and-rootfs.sh first"
fi

# Functional production-baseline mission, Phase 4: assert the packaged, real,
# fully-resolved production DTB (not the layered .dts source, which would
# need this script to reimplement override-precedence itself) keeps every
# intentionally-disabled reference-design block disabled, and every required
# product device enabled. Decompiles with the dtc host tool Buildroot already
# builds (output/host/bin/dtc) - no Docker/network needed for this check.
DTB="$REPO_ROOT/vendor/system/buildroot/output/build/linux-custom/module_drivers/dts/x2000/halley5_v30.dtb"
DTC="$REPO_ROOT/vendor/system/buildroot/output/host/bin/dtc"
echo "=== production DTB capability assertions ==="
if [ -f "$DTB" ] && [ -x "$DTC" ]; then
	DECOMPILED=$(mktemp)
	"$DTC" -I dtb -O dts "$DTB" 2>/dev/null > "$DECOMPILED"

	# Prints the "status" value of the first node whose header line matches
	# $1, scoped to that node's own body only (stops descending into the
	# first child node it hits). No explicit status property = "okay" (the
	# devicetree spec default).
	node_status() {
		awk -v pat="$1" '
			BEGIN { found = 0; depth = 0; status = "okay" }
			found && depth >= 1 {
				if (match($0, /status = "[a-z]+"/)) {
					s = substr($0, RSTART, RLENGTH)
					gsub(/status = "|"/, "", s)
					status = s
					found = 2
				}
			}
			$0 ~ pat && /\{[ \t]*$/ && found == 0 { found = 1 }
			found >= 1 {
				o = gsub(/\{/, "{"); c = gsub(/\}/, "}")
				depth += o - c
				if (found == 1 && depth == 0) { found = 3 }
				else if (depth <= 0) { exit }
			}
			END { print status }
		' "$DECOMPILED"
	}

	assert_status() {
		name="$1"; pat="$2"; want="$3"
		got=$(node_status "$pat")
		case "$want" in
			enabled)
				if [ "$got" = "okay" ] || [ "$got" = "ok" ]; then
					echo "OK   $name enabled (status=$got)"
				else
					echo "MISS $name expected enabled, got status=$got"
				fi
				;;
			disabled)
				if [ "$got" = "disabled" ] || [ "$got" = "disable" ]; then
					echo "OK   $name disabled (status=$got)"
				else
					echo "MISS $name expected disabled, got status=$got"
				fi
				;;
		esac
	}

	echo "--- must stay disabled (unused reference-design blocks) ---"
	assert_status "mac1 (unpopulated Ethernet)"      'mac@134a0000 {'      disabled
	assert_status "msc2 (unused MMC controller)"      'msc@13490000 {'      disabled
	assert_status "sfc (unpopulated SPI-NOR/NAND)"    'sfc@13440000 {'      disabled
	assert_status "mscaler0 (unused v4l2_subdev)"     'mscaler@13702300 {'  disabled
	assert_status "mscaler1 (unused v4l2_subdev)"     'mscaler@13802300 {'  disabled
	assert_status "uart3 (guaranteed pin conflict)"   'serial@10033000 {'   disabled
	assert_status "as-dmic (no product mic array)"    'as-dmic {'           disabled
	assert_status "as-baic (BAIC0/4, no stock ALSA use)" 'as-baic {'        disabled
	assert_status "as-platform (ALSA DMA frontend)"   'as-platform {'       disabled
	assert_status "as-fmtcov (ALSA format conv)"      'as-fmtcov {'         disabled
	assert_status "as-dsp (ALSA DSP/LO_MUX)"          'as-dsp {'            disabled
	assert_status "as-mixer (ALSA aux mixer)"         'as-mixer {'          disabled
	assert_status "as-spdif (ALSA SPDIF)"             'as-spdif {'          disabled
	assert_status "icodec (on-chip audio codec)"      'icodec@10020000 {'   disabled

	echo "--- must stay enabled (required product devices) ---"
	assert_status "msc0/eMMC"           'msc@13450000 {'   enabled
	assert_status "msc1/WiFi SDIO"      'msc@13460000 {'   enabled
	assert_status "uart1 (printer MCU link)" 'serial@10031000 {' enabled
	assert_status "uart4 (console)"     'serial@10034000 {' enabled
	assert_status "i2c4 (touchscreen)"  'i2c@10054000 {'    enabled
	assert_status "dpu (display)"       'dpu@[0-9a-fx]+ {'  enabled
	assert_status "pwm (beeper channel)" 'pwm@134c0000 {'   enabled
	assert_status "otg (USB)"           'otg@13500000 {'    enabled
	assert_status "rtc"                 'rtc@10003000 {'    enabled
	assert_status "watchdog"            'watchdog@10002000 {' enabled
	assert_status "i2c2 (BL24C16F EEPROM bus)" 'i2c@10052000 {' enabled

	echo "--- Phase 1.9A/1.9B accelerometer/EEPROM node content ---"
	if grep -q 'spi_gpio_adxl345 {' "$DECOMPILED" && grep -q 'spi2 = "/spi_gpio_adxl345"' "$DECOMPILED"; then
		echo "OK   spi_gpio_adxl345 node and spi2 alias present"
	else
		echo "MISS spi_gpio_adxl345 node or spi2 alias missing"
	fi
	if grep -A8 'eeprom@50 {' "$DECOMPILED" | grep -q 'compatible = "atmel,24c16"'; then
		echo "OK   eeprom@50 node present with compatible = \"atmel,24c16\""
	else
		echo "MISS eeprom@50 node missing or wrong compatible string"
	fi
	if grep -A8 'eeprom@50 {' "$DECOMPILED" | grep -q 'reg = <0x50>'; then
		echo "OK   eeprom@50 reg = <0x50>"
	else
		echo "MISS eeprom@50 reg is not <0x50>"
	fi
	EEPROM_BODY=$(awk '/eeprom@50 \{/,/^\t+\};/' "$DECOMPILED")
	if echo "$EEPROM_BODY" | grep -q 'pagesize = <0x10>' \
		&& echo "$EEPROM_BODY" | grep -q 'size = <0x800>' \
		&& echo "$EEPROM_BODY" | grep -qE 'address-width = <0x0?8>' \
		&& echo "$EEPROM_BODY" | grep -qE 'num-addresses = <0x0?8>'; then
		echo "OK   eeprom@50 geometry matches BL24C16F exactly (pagesize=16, size=2048, address-width=8, num-addresses=8)"
	else
		echo "MISS eeprom@50 geometry does not match the expected BL24C16F values - dtc prints decimal DT integers in hex, compared here as such"
	fi

	rm -f "$DECOMPILED"
else
	echo "MISS DTB or dtc not found ($DTB / $DTC) - run 03-build-kernel-and-rootfs.sh first"
fi


SQUASHFS_FILES=$(unsquashfs -l "$SQUASHFS" 2>/dev/null)

sq_cat() {
	unsquashfs -cat "$SQUASHFS" "${1#/}" 2>/dev/null
}

sq_dump() {
	mkdir -p "$(dirname "$2")"
	unsquashfs -cat "$SQUASHFS" "${1#/}" > "$2" 2>/dev/null
}

check() {
	path="$1"
	rel="${path#/}"
	if echo "$SQUASHFS_FILES" | grep -q "^squashfs-root/$rel$"; then
		echo "OK   $path"
	else
		echo "MISS $path"
	fi
}

check_absent() {
	path="$1"
	rel="${path#/}"
	if echo "$SQUASHFS_FILES" | grep -q "^squashfs-root/$rel$"; then
		echo "MISS $path is present but should have been removed as obsolete"
	else
		echo "OK   $path is absent"
	fi
}

echo "=== kernel modules (still loadable, not built-in) ==="
# Production optimization mission, Phase 9 (2026-07-30): Bluetooth HCI UART
# transport is now removed entirely (CONFIG_BT is not set - uart3, its only
# wired transport, is permanently disabled in this board own DTS due to a
# real pin conflict with the NS2009 touch controller i2c4 bus, so it could
# never actually attach regardless). These modules are now expected
# ABSENT, not present - inverted from the check this section used before.
check_absent /lib/modules/6.6.18-rt23/kernel/drivers/bluetooth/hci_uart.ko
check_absent /lib/modules/6.6.18-rt23/kernel/drivers/bluetooth/btbcm.ko

echo "=== WiFi firmware (FIRMWARE.md sec 53 - proprietary, not committed, staged by fetch-cyw43430-wifi-firmware.sh) ==="
check /lib/firmware/brcm/brcmfmac43430-sdio.bin
check /lib/firmware/brcm/brcmfmac43430-sdio.clm_blob
check /lib/firmware/brcm/brcmfmac43430-sdio.txt

echo "=== camera ==="
check /usr/bin/ustreamer
check /usr/bin/v4l2-ctl
check /etc/init.d/S50webcam
check /etc/openke-camera-idle-controller.sh
check /etc/init.d/S51openke-camera-idle-controller

echo "=== app stack ==="
# FIRMWARE.md sec 23 (2026-07-23): real, previously-silent bug - the
# gcc-final packages INSTALL_TARGET_CMDS step (copies libstdc++.so* into
# the rootfs) is gated on a Buildroot package stamp that does not get
# invalidated just because BR2_INSTALL_LIBSTDCPP became load-bearing
# later - a stale stamp from the very first build meant this was
# silently missing from every build for days while Klipper (needs it via
# greenlet) died instantly with no log line at all.
# 03-build-kernel-and-rootfs.sh now forces gcc-final-reinstall; this
# check is the permanent guard against that regressing silently again.
check /usr/lib/libstdc++.so.6
# FIRMWARE.md sec 23 (2026-07-23): real, previously-silent bug found right
# after the libstdc++ fix above let Moonraker actually import far enough to
TARGET_PY_DIR="python3.14"
if [ -f "$REPO_ROOT/vendor/system/buildroot/package/python3/python3.mk" ]; then
	TARGET_PY_MAJOR=$(grep "^PYTHON3_VERSION_MAJOR =" "$REPO_ROOT/vendor/system/buildroot/package/python3/python3.mk" | awk '{print $3}')
	TARGET_PY_DIR="python${TARGET_PY_MAJOR}"
fi

# hit it - importlib_metadata (a real Moonraker dependency) imports zipp at
# runtime, but 04-cross-compile-app-stack.sh downloaded it with --no-deps,
# so zipp itself was never fetched. Moonraker died with
# ModuleNotFoundError: No module named zipp, before opening its own log.
check /usr/lib/${TARGET_PY_DIR}/site-packages/zipp
# FIRMWARE.md sec 23 (2026-07-23): numpy is a soft/lazy Klipper dependency -
# shaper_calibrate.py only raises a clean, user-facing error if it is
# missing (not a crash), and only when a user actually runs resonance
# testing. Not launch-blocking, but a real completeness gap for a near-
# universal Klipper workflow, and available as a ready Buildroot package
# (BR2_PACKAGE_PYTHON_NUMPY), so enabled rather than left missing.
check /usr/lib/${TARGET_PY_DIR}/site-packages/numpy
check /usr/bin/${TARGET_PY_DIR}
check /opt/klipper/klippy/klippy.py
check /opt/klipper/klippy/chelper/c_helper.so
check /opt/klipper/scripts/klippy-requirements.txt
check /opt/klipper/scripts/install-octopi.sh
check /opt/klipper/.nebulaos-chelper-verdict.json
check /opt/openke-seeds/klipper-chelper-verdict.json
check /opt/klipper-extensions/nebulaos-extensions.json
echo "=== NebulaOS Klipper extras ==="
for extra in \
	bl24c16f.py \
	guppy_config_helper.py \
	guppy_module_loader.py \
	calibrate_shaper_config.py \
	gcode_shell_command.py \
	tmcstatus.py \
	nebulaos_calibration.py \
	nebulaos_compat.py \
	nebulaos_plr_journal.py \
	nebulaos_power_loss_recovery.py \
	nebulaos_probe_pair.py \
	nebulaos_temperature_mcu.py \
	nebulaos_version.py \
	nebulaos_z_offset_probe.py \
	nozzle_clear.py \
	prtouch_test_support.py \
	virtual_pins.py \
	z_compensate.py; do
	check "/opt/klipper/klippy/extras/$extra"
done
echo "=== printer MCU firmware bundle ==="
check /opt/openke/mcu/klipper-creality.bin
check /opt/openke/mcu/klipper.bin
check /opt/openke/mcu/klipper.elf
check /opt/openke/mcu/klipper.config
check /opt/openke/mcu/manifest.env
check /opt/openke/mcu/tools/creality_flash.py
check /opt/openke/mcu/tools/creality_validator.py
check /opt/openke/mcu/tools/creality_packer.py
check /opt/openke/mcu/tools/stage4_first_flash.py
check /etc/init.d/S57openke-mcu-upgrade
MCU_MANIFEST_CONTENT=$(sq_cat /opt/openke/mcu/manifest.env)
MCU_IMAGE_SHA=$(printf "%s\n" "$MCU_MANIFEST_CONTENT" | sed -n 's/^image_sha256=//p')
if [ -n "$MCU_IMAGE_SHA" ] && printf "%s\n" "$MCU_IMAGE_SHA" | grep -qE "^[0-9a-f]{64}$"; then
	echo "OK   packaged printer MCU manifest contains a SHA256 image identity"
else
	echo "MISS packaged printer MCU manifest is missing a valid image SHA256"
fi
MCU_BUILT_IMAGE="$REPO_ROOT/vendor/system/buildroot/board/halley5-openke-overlay/opt/openke/mcu/klipper-creality.bin"
MCU_RECORDED_SHA=$(grep "^mcu_klipper_creality_bin_sha256=" "$MANIFEST_FILE" 2>/dev/null | cut -d= -f2)
MCU_ACTUAL_SHA=$(sha256sum "$MCU_BUILT_IMAGE" 2>/dev/null | awk "{print \$1}")
if [ -n "$MCU_RECORDED_SHA" ] && [ "$MCU_ACTUAL_SHA" = "$MCU_RECORDED_SHA" ]; then
	echo "OK   staged printer MCU image matches the final build manifest ($MCU_ACTUAL_SHA)"
else
	echo "MISS staged printer MCU image does not match the final build manifest"
fi
MCU_UPGRADE_CONTENT=$(sq_cat /etc/init.d/S57openke-mcu-upgrade)
if echo "$MCU_UPGRADE_CONTENT" | grep -q "stage4_first_flash.py" && echo "$MCU_UPGRADE_CONTENT" | grep -q "creality_flash.py" && echo "$MCU_UPGRADE_CONTENT" | grep -q "creality_validator.py"; then
	echo "OK   MCU boot service contains first-flash, update-flash, and validation paths"
else
	echo "MISS MCU boot service is missing one or more safety-gated paths"
fi
echo "=== Ender-3 V3 SE & V2 Neo MCU firmware artifacts ==="
if [ -f "$REPO_ROOT/artifacts/buildroot-halley5-v30-image/Ender3V3SE_klipper.bin" ]; then
	echo "OK   Ender-3 V3 SE MCU firmware present in artifacts/buildroot-halley5-v30-image/Ender3V3SE_klipper.bin"
fi
if ! echo "$SQUASHFS_FILES" | grep -q "^squashfs-root/opt/openke/mcu/Ender3V3SE_klipper.bin$"; then
	echo "OK   Ender-3 V3 SE MCU firmware correctly excluded from rootfs"
fi
if [ -f "$REPO_ROOT/artifacts/buildroot-halley5-v30-image/Ender3V2Neo_klipper.bin" ]; then
	echo "OK   Ender-3 V2 Neo MCU firmware present in artifacts/buildroot-halley5-v30-image/Ender3V2Neo_klipper.bin"
fi
if ! echo "$SQUASHFS_FILES" | grep -q "^squashfs-root/opt/openke/mcu/Ender3V2Neo_klipper.bin$"; then
	echo "OK   Ender-3 V2 Neo MCU firmware correctly excluded from rootfs"
fi
# Pure upstream Klipper does not ship the version object;
# build identity remains available in /opt/openke-version.json.
check /opt/openke-version.json
check /opt/moonraker/moonraker/server.py
check /usr/lib/${TARGET_PY_DIR}/site-packages/streaming_form_data
if sq_cat "/usr/lib/${TARGET_PY_DIR}/site-packages/streaming_form_data/targets.py" | grep -q "smart_open = None"; then
	echo "OK   streaming_form_data optional cloud target dependencies verified"
else
	echo "FAIL streaming_form_data has unhandled smart_open dependency"
	FAILURES=$((FAILURES + 1))
fi
check /usr/sbin/nginx
check /usr/share/mainsail/index.html
check /etc/init.d/S55klipper
check /etc/init.d/S56moonraker
check /etc/init.d/S50nginx
check /opt/printer_data/config/printer.cfg
check /opt/printer_data/config/moonraker.conf

echo "=== Phase 1.9A: host MCU (klipper_mcu) / ADXL345 / BL24C16F ==="
# klipper_mcu is Klipper's own MACH_LINUX build target, compiled as a native
# MIPS Linux program with the project's mipsel-buildroot-linux-gnu-
# toolchain (04-cross-compile-app-stack.sh) - serves [mcu rpi] for the
# physical accelerometer and EEPROM, both wired directly to the SoC. No
# interaction with the separate GD32F303 stepper-driver MCU S50nebulaos-
# mcu-guard manages.
check /usr/bin/klipper_mcu
check /etc/init.d/S54openke-host-mcu
# bl24c16f.py stays composed for provenance (Phase 1.9A) but is retired from
# production use as of Phase 1.9B - see the OpenKE_Settings.cfg [bl24c16f]-absence
# check and the [nebulaos_power_loss_recovery] presence check below.
check /opt/klipper/klippy/extras/bl24c16f.py
check /opt/klipper/klippy/extras/nebulaos_plr_journal.py
check /opt/klipper/klippy/extras/nebulaos_power_loss_recovery.py

NEBULA_CFG_CONTENT=$(sq_cat /opt/openke-seeds/printer_data-config/hardware/nebula_pad.cfg)
S54_CONTENT=$(sq_cat /etc/init.d/S54openke-host-mcu)
if echo "$NEBULA_CFG_CONTENT" | grep -qE "^\[mcu rpi\]$"; then
	echo "OK   nebula_pad.cfg declares [mcu rpi]"
else
	echo "MISS nebula_pad.cfg does not declare [mcu rpi]"
fi
if echo "$NEBULA_CFG_CONTENT" | grep -qE "^\[adxl345\]$"; then
	echo "OK   nebula_pad.cfg declares [adxl345]"
else
	echo "MISS nebula_pad.cfg does not declare [adxl345]"
fi
if echo "$NEBULA_CFG_CONTENT" | grep -qE "^\[resonance_tester\]$"; then
	echo "OK   nebula_pad.cfg declares [resonance_tester]"
else
	echo "MISS nebula_pad.cfg does not declare [resonance_tester]"
fi
if echo "$NEBULA_CFG_CONTENT" | grep -qE "^\[bl24c16f\]$"; then
	echo "MISS nebula_pad.cfg declares [bl24c16f] - Phase 1.9B retired this as the production EEPROM owner (should be [nebulaos_power_loss_recovery] over at24 instead)"
else
	echo "OK   nebula_pad.cfg does not declare [bl24c16f] (retired, Phase 1.9B)"
fi
if echo "$NEBULA_CFG_CONTENT" | grep -qE "^\[nebulaos_power_loss_recovery\]$"; then
	echo "OK   nebula_pad.cfg declares [nebulaos_power_loss_recovery]"
else
	echo "MISS nebula_pad.cfg does not declare [nebulaos_power_loss_recovery]"
fi
if echo "$NEBULA_CFG_CONTENT" | grep -A2 "^\[nebulaos_power_loss_recovery\]$" | grep -qF "eeprom_path: /sys/bus/i2c/devices/2-0050/eeprom"; then
	echo "OK   [nebulaos_power_loss_recovery]'s eeprom_path matches the at24 eeprom@50 DT node's sysfs path"
else
	echo "MISS [nebulaos_power_loss_recovery]'s eeprom_path does not match the expected at24 sysfs path"
fi
if echo "$S54_CONTENT" | grep -qF -- '--exec "$KLIPPER_HOST_MCU" -- -r -I "$SOCKET"'; then
	echo "OK   S54openke-host-mcu starts /usr/bin/klipper_mcu with -r -I \$SOCKET (explicit socket path)"
else
	echo "MISS S54openke-host-mcu does not start klipper_mcu with an explicit -I socket path"
fi
S54_SOCKET=$(echo "$S54_CONTENT" | grep -oE "^SOCKET=.*" | cut -d= -f2)
if [ -n "$S54_SOCKET" ] && echo "$NEBULA_CFG_CONTENT" | grep -A1 "^\[mcu rpi\]$" | grep -qF "serial: $S54_SOCKET"; then
	echo "OK   S54openke-host-mcu's \$SOCKET ($S54_SOCKET) exactly matches [mcu rpi]'s serial: in nebula_pad.cfg"
else
	echo "MISS S54openke-host-mcu's \$SOCKET does not match [mcu rpi]'s serial: in nebula_pad.cfg"
fi

echo "=== process launch arguments and config-path consistency (mainline print-controls mission addendum, 2026-07-29) ==="
# A newly reported Mainsail "Config Files -> config folder appears empty"
# report required proving Klipper, Moonraker, and Mainsail all resolve to
# the exact same canonical config directory - not inferring it from any
# one of them alone. Live investigation against the real device found the
# architecture already correct end to end (same inode on both the
# persistent and bind-mounted runtime path, Moonrakers own
# /server/files/roots reporting the canonical path with rw, a full
# create/read/edit/delete cycle through the real file-manager API); these
# checks exist to keep it that way, catching a future regression at build
# time rather than live on a real printer.
S55_CONTENT=$(sq_cat /etc/init.d/S55klipper)
S56_CONTENT=$(sq_cat /etc/init.d/S56moonraker)
S01_CONTENT=$(sq_cat /etc/init.d/S01persistent-datastore)
if echo "$S55_CONTENT" | grep -qE "^CONFIG=/opt/printer_data/config/printer.cfg$"; then
	echo "OK   S55klipper launches Klipper against the canonical /opt/printer_data/config/printer.cfg"
else
	echo "MISS S55klipper does not launch Klipper against the canonical printer.cfg path"
fi
if echo "$S56_CONTENT" | grep -qE "^DATAPATH=/opt/printer_data$"; then
	echo "OK   S56moonraker launches Moonraker with the canonical -d /opt/printer_data data path"
else
	echo "MISS S56moonraker does not launch Moonraker with the canonical data path"
fi
if echo "$S56_CONTENT" | grep -qE "^CONFIG=/opt/printer_data/config/moonraker.conf$"; then
	echo "OK   S56moonraker launches Moonraker against the canonical moonraker.conf"
else
	echo "MISS S56moonraker does not launch Moonraker against the canonical moonraker.conf path"
fi
if echo "$S55_CONTENT" | grep -qi "/usr/data/creality\|/opt/creality" || echo "$S56_CONTENT" | grep -qi "/usr/data/creality\|/opt/creality"; then
	echo "MISS S55klipper or S56moonraker still references an obsolete creality path"
else
	echo "OK   S55klipper and S56moonraker contain no obsolete creality path reference"
fi
if echo "$S01_CONTENT" | grep -qE "mount --bind ..PDATA. /opt/printer_data"; then
	echo "OK   S01persistent-datastore bind-mounts the persistent printer_data tree onto /opt/printer_data"
else
	echo "MISS S01persistent-datastore does not bind-mount printer_data onto /opt/printer_data as expected"
fi
if echo "$S01_CONTENT" | grep -qE "^DATA_ROOT=/usr/data/openke$"; then
	echo "OK   S01persistent-datastore uses the canonical persistent backing root /usr/data/openke"
else
	echo "MISS S01persistent-datastore does not use /usr/data/openke as the persistent backing root"
fi

echo "=== Moonraker update_manager / camera defaults (final implementation mission, 2026-07-27) ==="
check /usr/libexec/openke-seed-camera
check /etc/init.d/S57openke-camera-seed

# Content checks against the actual shipped moonraker.conf, not just its
# presence - the whole point of this mission was that a real, previously
# undetected content-level defect (unsupported options under the reserved
# klipper/moonraker update_manager sections; an active, permanently
# un-editable config-sourced default camera) shipped in a build that
# passed every existence-only check that came before it. unsquashfs extracts
# the real file content from the built image itself, not from the source
# tree, so a build where the overlay sync silently dropped or mismatched
# the edit will not pass this check.
#
# NOTE for future edits to this section: everything in this file from the
# earlier "docker run ... bash -c" line through its own matching close
# further below is one single-quoted string as far as the real, top-level
# shell running this script is concerned - a literal single-quote
# character anywhere in this region (even inside a # comment) would
# terminate that outer quoting early and corrupt the rest of the file.
# Use double quotes for every string/pattern added below instead - none
# of them need a literal dollar sign or backtick, so double-quoting is
# always safe here.
MOONRAKER_CONF_CONTENT=$(sq_cat /opt/printer_data/config/moonraker.conf)

check_conf_absent() {
	pattern="$1"; desc="$2"
	if echo "$MOONRAKER_CONF_CONTENT" | grep -qE "$pattern"; then
		echo "MISS moonraker.conf still contains: $desc"
	else
		echo "OK   moonraker.conf does not contain: $desc"
	fi
}
check_conf_present() {
	pattern="$1"; desc="$2"
	if echo "$MOONRAKER_CONF_CONTENT" | grep -qE "$pattern"; then
		echo "OK   moonraker.conf contains: $desc"
	else
		echo "MISS moonraker.conf missing: $desc"
	fi
}
# [file_manager] must retain enable_object_processing so Moonraker populates
# exclude_object polygons from sliced-gcode metadata. The verifier only rejects
# deprecated config_path/log_path overrides that could redirect the config root.
FILE_MANAGER_SECTION_BODY=$(echo "$MOONRAKER_CONF_CONTENT" | awk "
	/^\[file_manager\]\$/ { grab=1; next }
	/^\[/ { grab=0 }
	grab { print }
")
if echo "$FILE_MANAGER_SECTION_BODY" | grep -qE "^(config_path|log_path): "; then
	echo "MISS [file_manager] contains a deprecated config_path/log_path override (the config root must keep deriving from -d /opt/printer_data by default, not an override that could diverge from the printer.cfg path Klipper actually reads)"
else
	echo "OK   [file_manager] contains no config_path/log_path override"
fi
# Extracts just the [update_manager klipper] and [update_manager moonraker]
# sections own body (up to the next [section] header) - scoped
# deliberately, since path/type ARE legitimate, needed options under the
# DIFFERENT (generic, type: web) [update_manager mainsail] section; a
# whole-file check would wrongly flag those as a regression.
RESERVED_SECTIONS_BODY=$(echo "$MOONRAKER_CONF_CONTENT" | awk "
	/^\[update_manager klipper\]\$/ || /^\[update_manager moonraker\]\$/ { grab=1; next }
	/^\[/ { grab=0 }
	grab { print }
")

check_conf_absent "^\[webcam " "an active [webcam ...] section"
if echo "$RESERVED_SECTIONS_BODY" | grep -qE "^(type|path|origin|primary_branch|managed_services|virtualenv|requirements): "; then
	echo "MISS [update_manager klipper]/[update_manager moonraker] still contain unsupported options (type/path/origin/primary_branch/managed_services/virtualenv/requirements) - these are reserved slots, see docs/NEBULAOS_MOONRAKER_UPDATE_AND_CAMERA_ANALYSIS.md"
else
	echo "OK   [update_manager klipper]/[update_manager moonraker] contain no unsupported options"
fi
check_conf_present "^\[update_manager klipper\]\$" "the reserved [update_manager klipper] section"
check_conf_present "^\[update_manager moonraker\]\$" "the reserved [update_manager moonraker] section"
check_conf_present "^\[update_manager mainsail\]\$" "the Mainsail web updater section"
if echo "$RESERVED_SECTIONS_BODY" | grep -qE "^channel: dev\$"; then
	echo "OK   [update_manager klipper]/[update_manager moonraker] set channel: dev"
else
	echo "MISS [update_manager klipper]/[update_manager moonraker] missing channel: dev"
fi

echo "=== factory-seed git archives (auto-updates-camera-complete mission, 2026-07-28) ==="
# Real bug this whole mission exists to fix: the OLD flattened-synthetic-
# commit seed made every freshly-seeded klipper/moonraker checkout
# diverged=true, is_valid=false, permanently blocking real updates - see
# docs/NEBULAOS_MOONRAKER_UPDATE_AND_CAMERA_ANALYSIS.md. Existence-only
# checks cannot see this - it needs the actual archive content dumped out
# of the built image and inspected with real git commands, the same way
# the moonraker.conf content checks above go beyond existence-only.
# Real bug found live: the extracted archive keeps the UID it was tarred
# with on the build host, which does not match this containers root user
# - git refuses to operate on it at all ("detected dubious ownership"),
# silently making every symbolic-ref/remote/status command below return
# empty instead of erroring, which made every check misreport a MISS.
# Harmless here (a throwaway verification container, not a real trust
# boundary) - exempt the one fixed extraction path used below.
git config --global --add safe.directory /tmp/seed-check
check_seed_archive() {
	archive_path="$1"; expected_branch="$2"; expected_origin="$3"; label="$4"
	rm -rf /tmp/seed-check
	mkdir -p /tmp/seed-check
	if ! sq_dump "$archive_path" /tmp/seed-check.tar; then
		echo "MISS $label archive could not be dumped from the image ($archive_path)"
		return
	fi
	if ! tar -xzf /tmp/seed-check.tar -C /tmp/seed-check 2>/dev/null; then
		echo "MISS $label archive is not a valid tar file"
		return
	fi
	if git -C /tmp/seed-check log --all --format=%s 2>/dev/null | grep -q "NebulaOS factory seed snapshot"; then
		echo "MISS $label archive still contains a synthetic factory-seed wrapper commit"
	else
		echo "OK   $label archive contains no synthetic wrapper commit"
	fi
	actual_branch=$(git -C /tmp/seed-check symbolic-ref --short HEAD 2>/dev/null)
	if [ "$actual_branch" = "$expected_branch" ]; then
		echo "OK   $label archive is on branch $expected_branch"
	else
		echo "MISS $label archive is on branch \"$actual_branch\", expected $expected_branch"
	fi
	actual_origin=$(git -C /tmp/seed-check remote get-url origin 2>/dev/null)
	if [ "$actual_origin" = "$expected_origin" ]; then
		echo "OK   $label archive origin is $expected_origin"
	else
		echo "MISS $label archive origin is \"$actual_origin\", expected $expected_origin"
	fi
	actual_refspec=$(git -C /tmp/seed-check config --get remote.origin.fetch 2>/dev/null)
	if [ "$actual_refspec" = "+refs/heads/*:refs/remotes/origin/*" ]; then
		echo "OK   $label archive origin has the full wildcard fetch refspec"
	else
		echo "MISS $label archive origin fetch refspec is \"$actual_refspec\", expected the full wildcard form (a narrow refspec silently breaks a later git fetch origin from populating origin/$expected_branch, reproducing diverged=true)"
	fi
	# Production optimization mission, Phase 9 (2026-07-30): same pathspec
	# exclusion as the internal clean-tree guard in make-seed-archive.sh -
	# the klipper build own properly cross-compiled+stripped c_helper.so is
	# legitimately, always different from whatever is tracked in git for
	# that path (an untrusted upstream binary). Moonraker has no such
	# path, so this exclusion is a no-op there. Double quotes, not single
	# quotes, around the pathspec magic below - a literal single quote
	# here would close the outer docker bash -c string early exactly like
	# the apostrophe bugs elsewhere in this same file.
	if [ -z "$(git -C /tmp/seed-check status --porcelain -- . ":!klippy/chelper/c_helper.so" 2>/dev/null)" ]; then
		echo "OK   $label archive has a clean working tree"
	else
		echo "MISS $label archive has a dirty working tree"
	fi
	rm -rf /tmp/seed-check /tmp/seed-check.tar
}
check_seed_archive /opt/openke-seeds/klipper.tar.gz "$KLIPPER_BRANCH" "$KLIPPER_REPO" "klipper"
check_seed_archive /opt/openke-seeds/moonraker.tar.gz master "https://github.com/Arksine/moonraker.git" "moonraker"

# Real bug this catches if regressed: the c_helper.so committed inside
# vendor/klippers own git history (an upstream binary) is incompatible
# with this image and hangs Klipper indefinitely with no on-device
# compiler to fall back on - only this projects own cross-compiled copy,
# already baked into the immutable /opt/klipper baseline, actually loads.
# Confirms the seed archives copy (the one the persistent, git-updatable
# checkout actually ships) is byte-identical to the proven-working
# immutable one, not silently reverted to the incompatible upstream blob.
rm -rf /tmp/chelper-check
mkdir -p /tmp/chelper-check
sq_dump /opt/openke-seeds/klipper.tar.gz /tmp/chelper-check.tar.gz
if tar -xzf /tmp/chelper-check.tar.gz -C /tmp/chelper-check ./klippy/chelper/c_helper.so 2>/dev/null; then
	SEED_CHELPER_SHA=$(sha256sum /tmp/chelper-check/klippy/chelper/c_helper.so 2>/dev/null | cut -d" " -f1)
	BASELINE_CHELPER_SHA=$(sq_cat /opt/klipper/klippy/chelper/c_helper.so | sha256sum | cut -d" " -f1)
	if [ -n "$SEED_CHELPER_SHA" ] && [ "$SEED_CHELPER_SHA" = "$BASELINE_CHELPER_SHA" ]; then
		echo "OK   klipper seed archives c_helper.so matches the proven-working immutable baseline"
	else
		echo "MISS klipper seed archives c_helper.so ($SEED_CHELPER_SHA) does not match the immutable baseline ($BASELINE_CHELPER_SHA) - it may be the incompatible upstream binary"
	fi
else
	echo "MISS could not extract klippy/chelper/c_helper.so from the klipper seed archive for comparison"
fi
rm -rf /tmp/chelper-check /tmp/chelper-check.tar.gz
SEED_MANIFEST_CONTENT=$(sq_cat /opt/openke-seeds/seed-manifest.json)
if echo "$SEED_MANIFEST_CONTENT" | grep -q "git_bundle_flattened"; then
	echo "MISS seed-manifest.json still references the removed git_bundle_flattened format"
else
	echo "OK   seed-manifest.json does not reference the removed git_bundle_flattened format"
fi
if echo "$SEED_MANIFEST_CONTENT" | grep -q "git_repo_archive_real_history"; then
	echo "OK   seed-manifest.json records the real-history archive format"
else
	echo "MISS seed-manifest.json missing the real-history archive format record"
fi

echo "=== printer_data config factory seed (Ender-3 V3 KE, auto-updates-camera-complete mission addendum, 2026-07-28) ==="
# Real bug found live: a genuinely wiped printer_data/config left Klipper
# and Moonraker crash-looping forever on FileNotFoundError - nothing had
# ever shipped a seed for these files at a path immune to
# S01persistent-datastores own early, unconditional bind mount of the
# persistent copy over /opt/printer_data. Confirms the dedicated immutable
# seed at /opt/openke-seeds/printer_data-config/ actually landed in the
# packaged image, not just the tracked overlay source.
if echo "$SQUASHFS_FILES" | grep -q "^squashfs-root/opt/openke-seeds/printer_data-config/printer.cfg$"; then
	echo "OK   /opt/openke-seeds/printer_data-config/printer.cfg is present"
else
	echo "MISS /opt/openke-seeds/printer_data-config/printer.cfg is missing from the packaged seed"
fi
if echo "$SQUASHFS_FILES" | grep -q "^squashfs-root/opt/openke-seeds/printer_data-config/moonraker.conf$"; then
	echo "OK   /opt/openke-seeds/printer_data-config/moonraker.conf is present"
else
	echo "MISS /opt/openke-seeds/printer_data-config/moonraker.conf is missing from the packaged seed"
fi
if echo "$SQUASHFS_FILES" | grep -q "^squashfs-root/opt/openke-seeds/printer_data-config/macros/mainsail.cfg$"; then
	echo "OK   /opt/openke-seeds/printer_data-config/macros/mainsail.cfg is present"
else
	echo "MISS /opt/openke-seeds/printer_data-config/macros/mainsail.cfg is missing from the packaged seed"
fi
if echo "$SQUASHFS_FILES" | grep -q "^squashfs-root/opt/openke-seeds/printer_data-config/hardware/nebula_pad.cfg$"; then
	echo "OK   /opt/openke-seeds/printer_data-config/hardware/nebula_pad.cfg is present"
else
	echo "MISS /opt/openke-seeds/printer_data-config/hardware/nebula_pad.cfg is missing from the packaged seed"
fi
# Camera quality presets mission (2026-08-04): same class of check as
# mainsail.cfg above - confirms the two new files a fresh factory
# seed depends on (the macro/shell-command config, and the script the shell
# command actually invokes) really landed in the packaged image, not just
# the tracked overlay source.
if echo "$SQUASHFS_FILES" | grep -q "^squashfs-root/opt/openke-seeds/printer_data-config/macros/camera.cfg$"; then
	echo "OK   /opt/openke-seeds/printer_data-config/macros/camera.cfg is present"
else
	echo "MISS /opt/openke-seeds/printer_data-config/macros/camera.cfg is missing from the packaged seed"
fi
if echo "$SQUASHFS_FILES" | grep -q "^squashfs-root/opt/openke-seeds/printer_data-config/macros/print_start.cfg$"; then
	echo "OK   /opt/openke-seeds/printer_data-config/macros/print_start.cfg is present"
else
	echo "MISS /opt/openke-seeds/printer_data-config/macros/print_start.cfg is missing from the packaged seed"
fi
if echo "$SQUASHFS_FILES" | grep -q "^squashfs-root/opt/openke-seeds/printer_data-config/GuppyScreen/scripts/set_camera_quality.py$"; then
	echo "OK   /opt/openke-seeds/printer_data-config/GuppyScreen/scripts/set_camera_quality.py is present"
else
	echo "MISS /opt/openke-seeds/printer_data-config/GuppyScreen/scripts/set_camera_quality.py is missing from the packaged seed"
fi
rm -rf /tmp/printerdata-check
mkdir -p /tmp/printerdata-check/hardware /tmp/printerdata-check/macros /tmp/printerdata-check/GuppyScreen
	sq_dump /opt/openke-seeds/printer_data-config/printer.cfg /tmp/printerdata-check/printer.cfg
	sq_dump /opt/openke-seeds/printer_data-config/moonraker.conf /tmp/printerdata-check/moonraker.conf
	sq_dump /opt/openke-seeds/printer_data-config/macros/print_settings.cfg /tmp/printerdata-check/macros/print_settings.cfg
	sq_dump /opt/openke-seeds/printer_data-config/macros/print_start.cfg /tmp/printerdata-check/macros/print_start.cfg
	sq_dump /opt/openke-seeds/printer_data-config/hardware/nebula_pad.cfg /tmp/printerdata-check/hardware/nebula_pad.cfg
	sq_dump /opt/openke-seeds/printer_data-config/hardware/v3_features.cfg /tmp/printerdata-check/hardware/v3_features.cfg
	sq_dump /opt/openke-seeds/printer_data-config/macros/mainsail.cfg /tmp/printerdata-check/macros/mainsail.cfg
	sq_dump /opt/openke-seeds/printer_data-config/macros/adaptive_meshing.cfg /tmp/printerdata-check/macros/adaptive_meshing.cfg
	sq_dump /opt/openke-seeds/printer_data-config/macros/line_purge.cfg /tmp/printerdata-check/macros/line_purge.cfg
	sq_dump /opt/openke-seeds/printer_data-config/macros/smart_park.cfg /tmp/printerdata-check/macros/smart_park.cfg
	sq_dump /opt/openke-seeds/printer_data-config/macros/camera.cfg /tmp/printerdata-check/macros/camera.cfg
	sq_dump /opt/openke-seeds/printer_data-config/macros/profiles.cfg /tmp/printerdata-check/macros/profiles.cfg
	sq_dump /opt/openke-seeds/printer_data-config/macros/apps.cfg /tmp/printerdata-check/macros/apps.cfg
	sq_dump /opt/openke-seeds/printer_data-config/macros/timelapse.cfg /tmp/printerdata-check/macros/timelapse.cfg
	sq_dump /opt/openke-seeds/printer_data-config/user.cfg /tmp/printerdata-check/user.cfg
	sq_dump /opt/openke-seeds/printer_data-config/GuppyScreen/guppy_cmd.cfg /tmp/printerdata-check/GuppyScreen/guppy_cmd.cfg
	if [ -s /tmp/printerdata-check/printer.cfg ] && grep -q "^#\*# <---------------------- SAVE_CONFIG" /tmp/printerdata-check/printer.cfg 2>/dev/null; then
		echo "MISS packaged printer.cfg seed contains a real SAVE_CONFIG calibration block"
	else
		echo "OK   packaged printer.cfg seed contains no SAVE_CONFIG calibration block"
	fi
	# Pure upstream Klipper does not load the fork-only camera-quality or
	# nebulaos_version configuration sections.
	# A bare "key:" is only actually blank if nothing indented follows on the
	# next line - moonraker.confs own trusted_clients/cors_domains use this
	# multi-line list form legitimately; a naive single-line check flagged
	# them as false positives the first time this ran for real. Written to a
	# temp file rather than an inline awk single-quote block - this whole
	# section already lives inside one big single-quoted docker bash -c
	# argument, and a nested single quote here would close that early exactly
	# like the apostrophe bugs found earlier in this same mission.
	# Klipper's gcode option is explicitly excluded below because an empty
	# gcode body is valid for variable-only macros. Every other option present
	# without a value must either be a valid multiline list or fail.
	# Every other option name is still caught - keep this in sync with the
	# identical copy in 04-cross-compile-app-stack.sh.
	cat > /tmp/blank-required-option.awk <<'AWKPROG'
{
	if (pending != "") {
		if ($0 !~ /^[ \t]/) { print pending; exit 1 }
		pending = ""
	}
	if ($0 ~ /^[a-zA-Z_][a-zA-Z0-9_]*:[[:space:]]*$/ && $0 !~ /^gcode:[[:space:]]*$/) { pending = $0 }
}
END { if (pending != "") { print pending; exit 1 } }
AWKPROG
	blank_required_option() {
		awk -f /tmp/blank-required-option.awk "$1"
	}
	blank_found=0
	for f in /tmp/printerdata-check/printer.cfg /tmp/printerdata-check/moonraker.conf /tmp/printerdata-check/macros/mainsail.cfg /tmp/printerdata-check/hardware/nebula_pad.cfg; do
		[ -s "$f" ] || continue
		if ! blank_required_option "$f" >/dev/null; then
			blank_found=1
		fi
	done
	if [ "$blank_found" = "1" ]; then
		echo "MISS packaged printer.cfg/moonraker.conf/mainsail.cfg seed has an option present but syntactically blank"
	else
		echo "OK   packaged printer.cfg/moonraker.conf/mainsail.cfg seed has no syntactically blank options"
	fi

	# Print-control config closure validation against the actual packaged
	# seed (not just the tracked source) - mainline print-controls mission,
	# 2026-07-29, see docs/NEBULAOS_FRONTEND_PRINT_CONTROLS.md. The includes
	# in printer.cfg are just concatenated here (this codebase only ever uses
	# plain literal filenames in its config includes, one level of
	# GuppyScreen/ nesting, never glob patterns), so this is a deliberately
	# simple closure builder, not a general Klipper config parser. Grep
	# patterns below use double quotes only, and the awk program is written
	# to a temp file via a quoted heredoc rather than inline - see the
	# blank_required_option note above this same docker bash -c block about
	# why a literal single quote here would break the outer quoting.
	if [ -s /tmp/printerdata-check/printer.cfg ]; then
		# printer.cfg must include the NebulaOS-owned frontend controls, which provide
		# the single virtual_sdcard/pause_resume/display_status/macro closure.
		if grep -q "^\[include macros/mainsail\.cfg\]" /tmp/printerdata-check/printer.cfg; then
			echo "OK   packaged printer.cfg includes macros/mainsail.cfg"
		else
			echo "MISS packaged printer.cfg does not include macros/mainsail.cfg"
		fi
		cat /tmp/printerdata-check/printer.cfg \
		    /tmp/printerdata-check/macros/print_settings.cfg \
		    /tmp/printerdata-check/macros/print_start.cfg \
		    /tmp/printerdata-check/hardware/nebula_pad.cfg \
		    /tmp/printerdata-check/hardware/v3_features.cfg \
		    /tmp/printerdata-check/macros/mainsail.cfg \
		    /tmp/printerdata-check/macros/adaptive_meshing.cfg \
		    /tmp/printerdata-check/macros/line_purge.cfg \
		    /tmp/printerdata-check/macros/smart_park.cfg \
		    /tmp/printerdata-check/macros/camera.cfg \
		    /tmp/printerdata-check/macros/profiles.cfg \
		    /tmp/printerdata-check/macros/apps.cfg \
		    /tmp/printerdata-check/user.cfg \
		    /tmp/printerdata-check/GuppyScreen/guppy_cmd.cfg > /tmp/printerdata-check/closure.txt 2>/dev/null
	vsd_count=$(grep -c -i -E "^\[[[:space:]]*virtual_sdcard[[:space:]]*\]" /tmp/printerdata-check/closure.txt)
	pr_count=$(grep -c -i -E "^\[[[:space:]]*pause_resume[[:space:]]*\]" /tmp/printerdata-check/closure.txt)
	ds_count=$(grep -c -i -E "^\[[[:space:]]*display_status[[:space:]]*\]" /tmp/printerdata-check/closure.txt)
	pause_macro_count=$(grep -c -i -E "^\[[[:space:]]*gcode_macro[[:space:]]+pause[[:space:]]*\]" /tmp/printerdata-check/closure.txt)
	resume_macro_count=$(grep -c -i -E "^\[[[:space:]]*gcode_macro[[:space:]]+resume[[:space:]]*\]" /tmp/printerdata-check/closure.txt)
	cancel_macro_count=$(grep -c -i -E "^\[[[:space:]]*gcode_macro[[:space:]]+cancel_print[[:space:]]*\]" /tmp/printerdata-check/closure.txt)
	closure_ok=1
	if [ "$vsd_count" != "1" ]; then echo "MISS packaged config closure has $vsd_count [virtual_sdcard] sections, need exactly 1"; closure_ok=0; fi
	if [ "$pr_count" != "1" ]; then echo "MISS packaged config closure has $pr_count [pause_resume] sections, need exactly 1"; closure_ok=0; fi
	if [ "$ds_count" != "1" ]; then echo "MISS packaged config closure has $ds_count [display_status] sections, need exactly 1"; closure_ok=0; fi
	if [ "$pause_macro_count" != "1" ]; then echo "MISS packaged config closure has $pause_macro_count [gcode_macro PAUSE] sections, need exactly 1 (Mainsail checks configfile.settings for this section directly)"; closure_ok=0; fi
	if [ "$resume_macro_count" != "1" ]; then echo "MISS packaged config closure has $resume_macro_count [gcode_macro RESUME] sections, need exactly 1 (Mainsail checks configfile.settings for this section directly)"; closure_ok=0; fi
	if [ "$cancel_macro_count" != "1" ]; then echo "MISS packaged config closure has $cancel_macro_count [gcode_macro CANCEL_PRINT] sections, need exactly 1 (Mainsail checks configfile.settings for this section directly)"; closure_ok=0; fi
	if [ "$closure_ok" = "1" ]; then
		echo "OK   packaged config closure has exactly one each of virtual_sdcard/pause_resume/display_status/gcode_macro PAUSE/gcode_macro RESUME/gcode_macro CANCEL_PRINT"
	fi
	cat > /tmp/vsd-path-extract.awk <<'AWKPROG2'
/^\[[[:space:]]*virtual_sdcard[[:space:]]*\]/ { in_vsd = 1; next }
/^\[/ { in_vsd = 0 }
in_vsd && /^[[:space:]]*path[[:space:]]*:/ {
	sub(/^[[:space:]]*path[[:space:]]*:[[:space:]]*/, "")
	gsub(/[[:space:]]+$/, "")
	print
	exit
}
AWKPROG2
	vsd_path=$(awk -f /tmp/vsd-path-extract.awk /tmp/printerdata-check/closure.txt)
	if [ "$vsd_path" = "/opt/printer_data/gcodes" ]; then
		echo "OK   packaged [virtual_sdcard] path is the canonical /opt/printer_data/gcodes"
	else
		echo "MISS packaged [virtual_sdcard] path is $vsd_path, expected /opt/printer_data/gcodes"
	fi
else
	echo "MISS packaged printer.cfg could not be dumped from rootfs.squashfs - cannot validate print-control closure"
fi
rm -rf /tmp/printerdata-check
# Confirms the actual fix logic landed in the packaged init scripts, not
# just the seed content sitting there unused.
S02_CONTENT=$(sq_cat /etc/init.d/S02openke-namespace)
if echo "$S02_CONTENT" | grep -q "seed_printer_data_config"; then
	echo "OK   S02openke-namespace contains the printer_data config seeding logic"
else
	echo "MISS S02openke-namespace is missing the printer_data config seeding logic"
fi
S05_CONTENT=$(sq_cat /etc/init.d/S05openke-activate)
if echo "$S05_CONTENT" | grep -q "config/printer.cfg"; then
	echo "OK   S05openke-activate validates printer_data against the real required files, not just the config directory"
else
	echo "MISS S05openke-activate still validates printer_data against only the config directory - a wiped copy would pass validation empty"
fi

echo "=== obsolete overlay files (must be absent - Buildroots output/target copy is additive-only, see 02-configure-buildroot.sh) ==="
# Real bug found live 2026-07-28: a renamed overlay file (e.g.
# S03nebulaos-factory-seed/S04nebulaos-activate -> S04nebulaos-factory-seed/
# S05nebulaos-activate) leaves the OLD file sitting in Buildroots own
# output/target/ forever unless explicitly cleaned - and it ships in the
# real rootfs right alongside the new one. This is not cosmetic: the old,
# pre-fix activation script sorts earlier and silently wins over the new
# one whenever both are present. unsquashfs against rootfs.squashfs here
# does catch a real leftover, not just the tracked overlay source.
# check_absent() is defined once, earlier, right after check() (both used
# from the very first section in this docker block).
check_absent /etc/init.d/S01tmpfs-datastore
check_absent /etc/init.d/S39wifi
check_absent /etc/init.d/S03nebulaos-factory-seed
check_absent /etc/init.d/S04nebulaos-activate
check_absent /opt/nebulaos
check_absent /opt/nebulaos-seeds
check_absent /opt/printer_data/config/Macros
check_absent /opt/printer_data/config/Nebula.cfg
check_absent /opt/printer_data/config/OpenKE_Settings.cfg
check_absent /opt/printer_data/config/V3_Settings.cfg
check_absent /opt/printer_data/config/camera-quality.cfg
check_absent /opt/printer_data/config/frontend-controls.cfg
check_absent /opt/printer_data/config/print_controls.cfg

echo "=== SSH/console/recovery (FIRMWARE.md sec 18/21/22/24) ==="
check /usr/sbin/dropbear
check /usr/sbin/wpa_cli
check /etc/init.d/S00revert-safety
check /etc/init.d/S01persistent-datastore
check /etc/init.d/S01wifi
check /etc/openke-stable-mac.sh
check /etc/openke-wifi-power-save.sh
check /usr/libexec/openke-wifi-power-save
check /etc/openke-wifi-boot-wait.sh
check /etc/init.d/S99confirm-good
check /etc/ota_marker.sh
check /etc/hwrevision
check /etc/swupdate.cfg
check /opt/printer_data/config/GuppyScreen/scripts/static_ip.py

echo "=== OpenKE memory resilience (docs/NEBULAOS_MEMORY_RESILIENCE.md) ==="
check /sbin/mkswap
check /sbin/swapon
check /sbin/swapoff
check /usr/bin/free
check /etc/init.d/S00zram-swap
check /etc/init.d/S03openke-diskswap
check /etc/init.d/S02openke-namespace
check /etc/init.d/S02openke-boot-timing
check /etc/init.d/S04openke-factory-seed
check /etc/init.d/S05openke-activate
check /etc/init.d/S45openke-cleanup
check /etc/openke-retention.sh
check /etc/openke-healthcheck.sh
check /opt/openke-seeds/klipper.tar.gz
check /opt/openke-seeds/moonraker.tar.gz
check /opt/openke-seeds/seed-manifest.json
check /opt/openke-seeds/printer_profiles/creality-ender3-v3-ke/profile.json
check /opt/openke-seeds/printer_profiles/creality-ender3-v3-ke/printer.cfg
check /opt/openke-seeds/printer_profiles/creality-ender3-v3-se/profile.json
check /opt/openke-seeds/printer_profiles/creality-ender3-v2-neo/profile.json
check /opt/openke-seeds/apps.json
check /usr/bin/openke-app
check /usr/sbin/ntpd
check /etc/init.d/S40openke-ntpsync
check /etc/openke-update-supervisor.sh
echo "=== OpenKE Package Manager (opkg / Entware) ==="
check /usr/bin/opkg
check /etc/opkg.conf
check /etc/profile.d/10-openke-opkg.sh
check /opt/bin
check /opt/sbin
check /opt/lib
check /opt/etc
check /opt/share
check /opt/var

# Phase 7 live qualification: Moonraker machine.py needs real iproute2
# JSON output (`ip -json -det address`), which BusyBox ip cannot produce
# at all (confirmed live). /sbin/ip must be the real iproute2 ELF binary,
# not still the busybox multi-call symlink - unsquashfs -ll prints
# symlink targets with '->', so its presence (and pointing at
# busybox) is what would indicate the fix did not take.
check /sbin/ip
stat_out=$(unsquashfs -ll "$SQUASHFS" "sbin/ip" 2>&1)
case "$stat_out" in
	*"-> busybox"*|*"-> /bin/busybox"*)
		echo "MISS /sbin/ip is still the busybox applet symlink"
		;;
	*)
		echo "OK   /sbin/ip is a real binary, not the busybox symlink"
		;;
esac

echo "=== architecture spot-checks (host objdump has no MIPS backend - a future check here would use the Buildroot-generated mipsel-buildroot-linux-gnu-objdump, per Phase 11's unified-container migration; pellcorp/k1-bash-build is retired) ==="
# Production optimization mission, Phase 9 (2026-07-30): this used to spot-
# check hci_uart.ko's architecture - the only loadable kernel module this
# image ever shipped. Bluetooth is now removed entirely (CONFIG_BT is not
# set - see the kernel-modules section above), and nothing else in this
# kernel is built as a loadable module (confirmed live: `lsmod` on the real
# device shows nothing loaded), so there is currently nothing left here to
# spot-check. Left as an empty, documented section rather than deleted
# outright, so a future loadable module addition has an obvious place to
# add its own check back.

echo "== xImage/uImage terminology check =="
# FIRMWARE.md sec 31 ("REAL BOOT SUCCESS..."): this project's kernel image
# was called "uImage" in early docs/scripts by convention/habit, but the
# real built file is (and has always been) named xImage, and its header
# does NOT match a standard U-Boot legacy "uImage" (compressed vmlinux.bin)
# layout - see FIRMWARE.md sec 29-31's root-cause trace and the "Correction"
# note. scripts/build/README.md had a genuinely stale "uImage" reference
# from before that correction, found and fixed 2026-08-14/15. This check
# exists so a future doc/script edit that reintroduces "uImage" as the name
# of the actual build artifact gets caught here rather than silently
# drifting back out of sync with what 05-final-build.sh actually produces
# (xImage, see IMAGES/xImage and artifacts/buildroot-halley5-v30-image/
# xImage above).
if [ -f "$IMAGES/xImage" ]; then
	echo "PASS $IMAGES/xImage exists (correct artifact name)"
else
	echo "MISS $IMAGES/xImage not found - run 05-final-build.sh first"
fi
if [ -f "$IMAGES/uImage" ]; then
	echo "MISS $IMAGES/uImage exists - this project's kernel image is xImage, not uImage (see FIRMWARE.md sec 29-31); a stray uImage here means something built the wrong target"
fi
# Deliberately not grepping docs/ for stray "uImage" text here: docs/HISTORY.md
# and FIRMWARE.md are append-only dated journals that correctly say "uImage"
# in entries written before the sec 29-31 naming correction - a mechanical
# grep can't tell historical record from stale current claim, and got this
# wrong on a first pass (flagged docs/HISTORY.md's legitimate history as a
# MISS). That distinction needs a human read, which is how scripts/build/
# README.md's real stale reference was actually found and fixed
# (2026-08-14/15) - not something to re-attempt here.

echo "== verification complete - review any MISS lines above =="
