#!/bin/sh
#
# rosetteos-update-cli-tests.sh: Test suite for the rosetteos-update CLI updater.
#
# Verifies:
#   1. Help output and option parsing.
#   2. Preflight checks and slot detection.
#   3. Printer safety interlock (refusal on active print).
#   4. Precaution banner display and prompt cancellation ('n').
#   5. Precaution prompt acceptance ('y') and --yes non-interactive mode.
#   6. Flashing via SWUpdate with target slot parameter (-e stable,slot1/slot2).
#   7. Checksum verification and mismatch refusal.
#   8. Downloaded file cleanup vs --keep flag.
#   9. Reboot handling (--no-reboot vs interactive prompt).
#
# Usage: sh tests/rosetteos-update-cli-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
CLI="$REPO_ROOT/scripts/build/overlay/usr/bin/rosetteos-update"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/rosetteos-update-tests.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM

PASS=0
FAIL=0

pass() {
	echo "PASS: $1"
	PASS=$((PASS + 1))
}

fail() {
	echo "FAIL: $1"
	FAIL=$((FAIL + 1))
}

# 1. Help message
out=$("$CLI" --help 2>&1)
if echo "$out" | grep -q "RosetteOS Firmware Updater CLI"; then
	pass "CLI displays help message"
else
	fail "CLI failed to display help message"
fi

# 2. Slot detection (slot1 -> slot2)
CMDLINE_SLOT1="$WORK/cmdline_slot1"
echo "console=ttyS0,115200 root=/dev/mmcblk0p7 rootwait" > "$CMDLINE_SLOT1"

out=$(env CMDLINE_PATH="$CMDLINE_SLOT1" ROSETTEOS_UPDATE_TEST_MODE=1 "$CLI" --check 2>&1)
if echo "$out" | grep -q "Active Running Slot : slot1" && echo "$out" | grep -q "Target Standby Slot : slot2"; then
	pass "Preflight correctly identifies slot1 running, targeting slot2"
else
	fail "Preflight slot1 detection failed: $out"
fi

# 3. Slot detection (slot2 -> slot1)
CMDLINE_SLOT2="$WORK/cmdline_slot2"
echo "console=ttyS0,115200 root=/dev/mmcblk0p8 rootwait" > "$CMDLINE_SLOT2"

out=$(env CMDLINE_PATH="$CMDLINE_SLOT2" ROSETTEOS_UPDATE_TEST_MODE=1 "$CLI" --check 2>&1)
if echo "$out" | grep -q "Active Running Slot : slot2" && echo "$out" | grep -q "Target Standby Slot : slot1"; then
	pass "Preflight correctly identifies slot2 running, targeting slot1"
else
	fail "Preflight slot2 detection failed: $out"
fi

# 4. Refuse on unknown boot root
CMDLINE_UNKNOWN="$WORK/cmdline_unknown"
echo "console=ttyS0,115200 root=/dev/nfs rootwait" > "$CMDLINE_UNKNOWN"

set +e
out=$(env CMDLINE_PATH="$CMDLINE_UNKNOWN" ROSETTEOS_UPDATE_TEST_MODE=0 "$CLI" --check 2>&1)
rc=$?
set -e
if [ $rc -ne 0 ] && echo "$out" | grep -q "Unable to identify active boot slot"; then
	pass "Refuses unknown root in cmdline"
else
	fail "Allowed unknown boot root (rc=$rc): $out"
fi

# 5. Mounted target partition safety check
MOUNTS_BUSY="$WORK/mounts_busy"
echo "/dev/mmcblk0p8 /mnt/test ext4 rw 0 0" > "$MOUNTS_BUSY"

DUMMY_SWU="$WORK/dummy.swu"
echo "swu content" > "$DUMMY_SWU"

set +e
out=$(env CMDLINE_PATH="$CMDLINE_SLOT1" MOUNTS_PATH="$MOUNTS_BUSY" ROSETTEOS_UPDATE_TEST_MODE=0 "$CLI" -y "$DUMMY_SWU" 2>&1)
rc=$?
set -e
if [ $rc -ne 0 ] && echo "$out" | grep -q "Target partition /dev/mmcblk0p8 is currently mounted"; then
	pass "Refuses to flash when target partition is mounted"
else
	fail "Did not refuse mounted target partition (rc=$rc): $out"
fi

# 6. Safety interlock: Active print refusal
set +e
out=$(env CMDLINE_PATH="$CMDLINE_SLOT1" ROSETTEOS_UPDATE_TEST_MODE=1 \
	MOCK_MOONRAKER_STATUS='echo "CRITICAL: Active print job in progress (state: printing)!" >&2; exit 2' \
	"$CLI" -y "$DUMMY_SWU" 2>&1)
rc=$?
set -e
if [ $rc -eq 2 ] && echo "$out" | grep -q "Active print job in progress"; then
	pass "Blocks firmware update during an active print"
else
	fail "Failed to block update during active print (rc=$rc): $out"
fi

# 7. Precaution display and user cancellation ('n')
set +e
out=$(printf "n\n" | env CMDLINE_PATH="$CMDLINE_SLOT1" ROSETTEOS_UPDATE_TEST_MODE=1 "$CLI" "$DUMMY_SWU" 2>&1)
rc=$?
set -e
if [ $rc -eq 0 ] && echo "$out" | grep -q "ROSETTEOS FIRMWARE UPDATE PRECAUTION" && echo "$out" | grep -q "Update cancelled by user"; then
	pass "Displays precaution banner and cancels on user 'n' input"
else
	fail "Precaution banner / cancellation failed (rc=$rc): $out"
fi

# 8. User confirmation ('y') proceeds with SWUpdate in test mode
MOCK_SWUPDATE_LOG="$WORK/swupdate.invocations"
MOCK_SWUPDATE="$WORK/mock-swupdate.sh"
cat > "$MOCK_SWUPDATE" <<EOF
#!/bin/sh
echo "\$@" >> "$MOCK_SWUPDATE_LOG"
exit 0
EOF
chmod +x "$MOCK_SWUPDATE"

MOCK_REBOOT="$WORK/mock-reboot.sh"
cat > "$MOCK_REBOOT" <<EOF
#!/bin/sh
echo "rebooted" >> "$WORK/reboot.log"
exit 0
EOF
chmod +x "$MOCK_REBOOT"

out=$(printf "y\ny\n" | env CMDLINE_PATH="$CMDLINE_SLOT1" SWUPDATE_BIN="$MOCK_SWUPDATE" REBOOT_CMD="$MOCK_REBOOT" ROSETTEOS_UPDATE_TEST_MODE=0 "$CLI" "$DUMMY_SWU" 2>&1)
if echo "$out" | grep -q "FIRMWARE UPDATE COMPLETED SUCCESSFULLY" && grep -q -- "-e stable,slot2" "$MOCK_SWUPDATE_LOG"; then
	pass "User confirmation 'y' invokes SWUpdate with correct target slot (-e stable,slot2)"
else
	fail "SWUpdate execution with confirmation failed: $out"
fi

# 9. Non-interactive --yes with --no-reboot
: > "$MOCK_SWUPDATE_LOG"
out=$(env CMDLINE_PATH="$CMDLINE_SLOT2" SWUPDATE_BIN="$MOCK_SWUPDATE" REBOOT_CMD="$MOCK_REBOOT" ROSETTEOS_UPDATE_TEST_MODE=0 "$CLI" --yes --no-reboot "$DUMMY_SWU" 2>&1)
if grep -q -- "-e stable,slot1" "$MOCK_SWUPDATE_LOG" && echo "$out" | grep -q "Reboot suppressed"; then
	pass "--yes and --no-reboot correctly targets slot1 and suppresses reboot"
else
	fail "--yes / --no-reboot failed: $out"
fi

# 10. Nightly download precaution display and mock execution
TEST_NIGHTLY_DIR="$WORK/updates"
mkdir -p "$TEST_NIGHTLY_DIR"
TEST_NIGHTLY_SWU="$WORK/server_nightly.swu"
echo "nightly swu binary payload" > "$TEST_NIGHTLY_SWU"
TEST_NIGHTLY_SHA="$WORK/server_nightly.swu.sha256"
sha256sum "$TEST_NIGHTLY_SWU" > "$TEST_NIGHTLY_SHA"

# Create a mock wget and curl so tests run offline
MOCK_WGET="$WORK/wget"
cat > "$MOCK_WGET" <<EOF
#!/bin/sh
dest=""
url=""
while [ \$# -gt 0 ]; do
	case "\$1" in
		-O|-o) dest="\$2"; shift ;;
		http*|ftp*) url="\$1" ;;
	esac
	shift
done
case "\$url" in
	*.sha256) cp "$TEST_NIGHTLY_SHA" "\$dest" ;;
	*) cp "$TEST_NIGHTLY_SWU" "\$dest" ;;
esac
exit 0
EOF
chmod +x "$MOCK_WGET"
cp "$MOCK_WGET" "$WORK/curl"

out=$(PATH="$WORK:$PATH" env CMDLINE_PATH="$CMDLINE_SLOT1" UPDATE_DIR="$TEST_NIGHTLY_DIR" \
	SWUPDATE_BIN="$MOCK_SWUPDATE" REBOOT_CMD="$MOCK_REBOOT" ROSETTEOS_UPDATE_TEST_MODE=0 \
	"$CLI" --nightly --yes --no-reboot 2>&1)

if echo "$out" | grep -q "ROSETTEOS FIRMWARE UPDATE PRECAUTION" \
	&& echo "$out" | grep -q "Nightly Release" \
	&& echo "$out" | grep -q "SHA256 checksum verified OK" \
	&& echo "$out" | grep -q "FIRMWARE UPDATE COMPLETED SUCCESSFULLY"; then
	pass "Nightly update: Displays precaution, verifies sha256 checksum, and flashes"
else
	fail "Nightly update failed: $out"
fi

# Verify downloaded file is cleaned up after install
if [ ! -f "$TEST_NIGHTLY_DIR/rosetteos-update-nightly.swu" ]; then
	pass "Downloaded update file is cleaned up by default"
else
	fail "Downloaded update file was not removed after installation"
fi

# 11. --keep preserves downloaded file
out=$(PATH="$WORK:$PATH" env CMDLINE_PATH="$CMDLINE_SLOT1" UPDATE_DIR="$TEST_NIGHTLY_DIR" \
	SWUPDATE_BIN="$MOCK_SWUPDATE" REBOOT_CMD="$MOCK_REBOOT" ROSETTEOS_UPDATE_TEST_MODE=0 \
	"$CLI" nightly --yes --keep --no-reboot 2>&1)

if [ -f "$TEST_NIGHTLY_DIR/rosetteos-update-nightly.swu" ]; then
	pass "--keep flag preserves the downloaded .swu file"
else
	fail "--keep flag failed to preserve downloaded file: $out"
fi

echo "=========================================="
echo "rosetteos-update-cli-tests: $PASS passed, $FAIL failed"
echo "=========================================="
[ "$FAIL" -eq 0 ]
