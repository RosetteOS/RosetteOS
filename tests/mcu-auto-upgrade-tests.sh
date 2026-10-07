#!/bin/sh
# Offline structural tests for the printer-MCU build and boot-upgrade path.
# These tests do not open a serial port or execute an MCU write.
set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
BUILD_SCRIPT="$REPO_ROOT/scripts/build/build-mcu-firmware.sh"
UPGRADE_SCRIPT="$REPO_ROOT/scripts/build/overlay/etc/init.d/S57rosetteos-mcu-upgrade"
INITD_DIR="$REPO_ROOT/scripts/build/overlay/etc/init.d"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
contains() {
	file=$1
	text=$2
	grep -Fq -- "$text" "$file" && pass || fail "$file is missing: $text"
}

for script in "$BUILD_SCRIPT" "$UPGRADE_SCRIPT" \
	"$REPO_ROOT/scripts/build/00-fetch-vendor-sources.sh" \
	"$REPO_ROOT/scripts/build/04-cross-compile-app-stack.sh" \
	"$REPO_ROOT/scripts/build/05-final-build.sh" \
	"$REPO_ROOT/scripts/build/06-verify.sh"; do
	sh -n "$script" && pass || fail "shell syntax check failed: $script"
done

contains "$BUILD_SCRIPT" 'build_mcu_target "$MCU_BUILD" "$GENERATED_ARTIFACTS/ke/pass1"'
contains "$BUILD_SCRIPT" 'build_mcu_target "$MCU_BUILD" "$GENERATED_ARTIFACTS/ke/pass2"'
contains "$BUILD_SCRIPT" 'cmp -s "$GENERATED_ARTIFACTS/ke/pass1/klipper.bin" "$GENERATED_ARTIFACTS/ke/pass2/klipper.bin"'
contains "$BUILD_SCRIPT" 'creality_validator.py" target'
contains "$BUILD_SCRIPT" 'creality_flash.py" inspect'
contains "$BUILD_SCRIPT" 'DEFAULT_ALLOWED_HW_IDS'
contains "$UPGRADE_SCRIPT" 'mcu-auto-upgrade.disabled'
contains "$UPGRADE_SCRIPT" 'stage4_first_flash.py'
contains "$UPGRADE_SCRIPT" '--authorize'
contains "$UPGRADE_SCRIPT" '--skip-validator'
contains "$UPGRADE_SCRIPT" 'creality_flash.py" flash'
contains "$UPGRADE_SCRIPT" 'creality_validator.py" format'
contains "$UPGRADE_SCRIPT" 'image_sha256='

sorted=$(cd "$INITD_DIR" && ls -1 | sort)
index_of() { printf '%s\n' "$sorted" | grep -n "^$1\$" | cut -d: -f1; }
i_klipper=$(index_of S55klipper)
i_moonraker=$(index_of S56moonraker)
i_mcu=$(index_of S57rosetteos-mcu-upgrade)
i_guppy=$(index_of S58guppyscreen)
if [ -n "$i_klipper" ] && [ -n "$i_moonraker" ] && [ -n "$i_mcu" ] && [ -n "$i_guppy" ] \
	&& [ "$i_klipper" -lt "$i_moonraker" ] \
	&& [ "$i_moonraker" -lt "$i_mcu" ] \
	&& [ "$i_mcu" -lt "$i_guppy" ]; then
	pass
else
	fail "MCU service is not ordered S55klipper < S56moonraker < S57 MCU < S58guppyscreen"
fi

if [ "$FAIL" -eq 0 ]; then
	echo "PASS: $PASS MCU auto-upgrade checks"
	exit 0
fi
echo "FAIL: $FAIL of $((PASS + FAIL)) MCU auto-upgrade checks"
exit 1
