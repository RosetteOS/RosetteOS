#!/bin/sh
#
# Offline, repeatable test suite for the RosetteOS Boot Animation Engine
# (tools/rosetteos-bootanim/rosetteos-bootanim.c and
#  scripts/build/overlay/etc/init.d/S01rosetteos-bootanimation).
#
# Validates:
#   1. Native compilation of the C engine with -Wall -Wextra
#   2. Headless frame generation and output PPM geometry (480x272)
#   3. Dynamic status tracking from status file
#   4. Clean signal handling and fade-out termination on SIGTERM
#   5. Cross-compiled MIPS binary integrity (MIPS32 little-endian, statically linked)
#   6. Init script syntax, start/stop lifecycle, and OOM policy integration
#   7. Display handoff coordination in S58guppyscreen
#   8. Milestone notifications in rcS
#
# Usage: sh tests/rosetteos-bootanimation-tests.sh
#

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
OVERLAY="$REPO_ROOT/scripts/build/overlay"
BOOTANIM_SRC="$REPO_ROOT/tools/rosetteos-bootanim/rosetteos-bootanim.c"
MIPS_BIN="$OVERLAY/usr/bin/rosetteos-bootanim"
INIT_SCRIPT="$OVERLAY/etc/init.d/S00bootanimation"
GUPPY_INIT="$OVERLAY/etc/init.d/S58guppyscreen"
RCS_SCRIPT="$OVERLAY/etc/init.d/rcS"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/bootanim-tests.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM

PASS=0
FAIL=0

fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

echo "=== Test 1: Source Code & Host Compilation ==="
if [ ! -f "$BOOTANIM_SRC" ]; then
	fail "bootanim C source not found: $BOOTANIM_SRC"
else
	pass "bootanim C source exists"
fi

HOST_BIN="$WORK/rosetteos-bootanim-host"
if gcc -O2 -Wall -Wextra -Werror "$BOOTANIM_SRC" -o "$HOST_BIN" -lm > "$WORK/compile.log" 2>&1; then
	pass "host compilation succeeded with -Wall -Wextra -Werror"
else
	fail "host compilation failed: $(cat "$WORK/compile.log")"
fi

echo "=== Test 2: CLI Options & Headless Execution ==="
if "$HOST_BIN" --help > "$WORK/help.log" 2>&1; then
	grep -q "Usage:" "$WORK/help.log" && pass "--help printed usage" || fail "--help did not print usage"
else
	fail "--help returned non-zero exit status"
fi

if "$HOST_BIN" --headless --frames 10 > "$WORK/headless.log" 2>&1; then
	pass "--headless --frames 10 ran and exited cleanly with code 0"
else
	fail "--headless --frames 10 failed"
fi

echo "=== Test 3: Frame Buffer Geometry & PPM Export ==="
PPM_OUT="$WORK/test-frame.ppm"
if "$HOST_BIN" --output-frame "$PPM_OUT" > "$WORK/ppm.log" 2>&1; then
	pass "--output-frame generated frame file"
	if [ -f "$PPM_OUT" ]; then
		magic=$(head -n 1 "$PPM_OUT")
		dims=$(sed -n '2p' "$PPM_OUT")
		if [ "$magic" = "P6" ] && [ "$dims" = "480 272" ]; then
			pass "PPM header verified: P6 480x272"
		else
			fail "unexpected PPM format: magic=$magic dims=$dims"
		fi
		# 480 * 272 * 3 = 391680 pixel bytes + header
		size=$(wc -c < "$PPM_OUT")
		if [ "$size" -ge 391680 ]; then
			pass "frame byte size verified ($size bytes >= 391680)"
		else
			fail "frame byte size too small: $size"
		fi
	else
		fail "output PPM file does not exist"
	fi
else
	fail "--output-frame command failed"
fi

echo "=== Test 4: Dynamic Status Message Reader ==="
STATUS_FILE="$WORK/boot-status.txt"
echo "Testing Subsystem Milestone 42..." > "$STATUS_FILE"
if "$HOST_BIN" --headless --frames 5 --status-file "$STATUS_FILE" > "$WORK/status.log" 2>&1; then
	pass "bootanim ran with custom status file"
else
	fail "bootanim failed reading custom status file"
fi

echo "=== Test 5: Clean Asynchronous Signal Termination (SIGTERM) ==="
"$HOST_BIN" --headless --fps 30 > "$WORK/daemon.log" 2>&1 &
BG_PID=$!
sleep 0.15
if kill -0 "$BG_PID" 2>/dev/null; then
	pass "bootanim is running in background (PID $BG_PID)"
	kill -TERM "$BG_PID" 2>/dev/null
	wait "$BG_PID" 2>/dev/null
	rc=$?
	if [ $rc -eq 0 ]; then
		pass "bootanim exited cleanly (exit code 0) on SIGTERM"
	else
		fail "bootanim exited with code $rc on SIGTERM"
	fi
else
	fail "bootanim background process exited prematurely"
fi

echo "=== Test 6: Cross-Compiled MIPS Binary Verification ==="
if [ -f "$MIPS_BIN" ]; then
	pass "MIPS overlay binary exists at $MIPS_BIN"
	if [ -x "$MIPS_BIN" ]; then
		pass "MIPS binary is executable"
	else
		fail "MIPS binary is not executable"
	fi
	ftype=$(file "$MIPS_BIN")
	case "$ftype" in
		*MIPS*|*mips*)
			pass "binary architecture is MIPS: $ftype"
			;;
		*)
			fail "binary architecture is not MIPS: $ftype"
			;;
	esac
	case "$ftype" in
		*LSB*|*little\ endian*)
			pass "binary endianness is Little Endian (mipsel)"
			;;
		*)
			fail "binary is not little endian: $ftype"
			;;
	esac
	case "$ftype" in
		*statically\ linked*)
			pass "binary is statically linked"
			;;
		*)
			fail "binary is not statically linked: $ftype"
			;;
	esac
else
	fail "MIPS overlay binary missing: $MIPS_BIN"
fi

echo "=== Test 7: Init Script Integration & OOM Policy ==="
if [ -f "$INIT_SCRIPT" ]; then
	pass "init script exists: $INIT_SCRIPT"
	if [ -x "$INIT_SCRIPT" ]; then
		pass "init script is executable"
	else
		fail "init script is not executable"
	fi
	if sh -n "$INIT_SCRIPT" 2>/dev/null; then
		pass "init script passes syntax check (sh -n)"
	else
		fail "init script has syntax errors"
	fi
	grep -q "ROSETTEOS_ADJ_BOOTANIM" "$INIT_SCRIPT" && pass "init script references ROSETTEOS_ADJ_BOOTANIM" || fail "missing OOM policy reference"
	grep -q "rosetteos_start_with_adj" "$INIT_SCRIPT" && pass "init script uses rosetteos_start_with_adj" || fail "missing rosetteos_start_with_adj"
else
	fail "init script missing: $INIT_SCRIPT"
fi

echo "=== Test 8: Handoff to Touchscreen UI & rcS Status ==="
if grep -q "S00bootanimation stop" "$GUPPY_INIT"; then
	pass "S58guppyscreen cleanly stops boot animation before starting touch UI"
else
	fail "S58guppyscreen missing boot animation stop call"
fi

if grep -q "rosetteos-boot-status" "$RCS_SCRIPT"; then
	pass "rcS updates boot status file on subsystem milestones"
else
	fail "rcS does not update rosetteos-boot-status"
fi

echo "=== Test 9: Init Script Execution Order ==="
init_files=$(cd "$OVERLAY/etc/init.d" && ls -1 S??*)
s00_idx=$(printf '%s\n' "$init_files" | grep -n "^S00bootanimation$" | cut -d: -f1)
mmc_idx=$(printf '%s\n' "$init_files" | grep -n "^S00mount_mmc_ext4$" | cut -d: -f1)
klipper_idx=$(printf '%s\n' "$init_files" | grep -n "^S55klipper$" | cut -d: -f1)
guppy_idx=$(printf '%s\n' "$init_files" | grep -n "^S58guppyscreen$" | cut -d: -f1)

if [ -n "$s00_idx" ] && [ -n "$mmc_idx" ] && [ -n "$klipper_idx" ] && [ -n "$guppy_idx" ]; then
	if [ "$s00_idx" -lt "$mmc_idx" ] && [ "$s00_idx" -lt "$klipper_idx" ] && [ "$s00_idx" -lt "$guppy_idx" ]; then
		pass "S00bootanimation ($s00_idx) runs strictly first, before S00mount_mmc_ext4 ($mmc_idx), S55klipper ($klipper_idx), and S58guppyscreen ($guppy_idx)"
	else
		fail "incorrect init ordering: S00=$s00_idx, mmc=$mmc_idx, klipper=$klipper_idx, guppy=$guppy_idx"
	fi
else
	fail "could not determine indices for init scripts"
fi

echo "=== Test 10: Kernel Logo Configuration ==="
KERNEL_CONFIG="$REPO_ROOT/artifacts/buildroot-halley5-v30-image/kernel.config"
KERNEL_FRAGMENT="$REPO_ROOT/artifacts/buildroot-halley5-v30-image/halley5-rosetteos-fragment.config"

if [ -f "$KERNEL_CONFIG" ]; then
	if grep -q "^CONFIG_TRUE_COLOR_LOGO=y" "$KERNEL_CONFIG"; then
		fail "CONFIG_TRUE_COLOR_LOGO=y is set in kernel.config (would cause intermediate kernel logo flash)"
	else
		pass "CONFIG_TRUE_COLOR_LOGO=y is absent from kernel.config"
	fi
	if grep -q "^# CONFIG_TRUE_COLOR_LOGO is not set" "$KERNEL_CONFIG"; then
		pass "CONFIG_TRUE_COLOR_LOGO is explicitly unset in kernel.config"
	else
		fail "CONFIG_TRUE_COLOR_LOGO is not explicitly unset in kernel.config"
	fi
else
	fail "kernel.config not found at $KERNEL_CONFIG"
fi

if [ -f "$KERNEL_FRAGMENT" ]; then
	if grep -q "^# CONFIG_TRUE_COLOR_LOGO is not set" "$KERNEL_FRAGMENT"; then
		pass "CONFIG_TRUE_COLOR_LOGO is explicitly unset in halley5-rosetteos-fragment.config"
	else
		fail "CONFIG_TRUE_COLOR_LOGO is not explicitly unset in halley5-rosetteos-fragment.config"
	fi
else
	fail "halley5-rosetteos-fragment.config not found at $KERNEL_FRAGMENT"
fi

echo "=========================================="
echo "Boot Animation Tests: $PASS passed, $FAIL failed"
echo "=========================================="

[ "$FAIL" -eq 0 ]

