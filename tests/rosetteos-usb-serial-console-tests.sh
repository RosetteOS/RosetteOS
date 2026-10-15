#!/bin/sh
#
# Offline unit tests for RosetteOS Micro-USB CDC-ACM Serial Console
# (g_serial / ttyGS0) userspace helpers, udev rules, and kernel configuration.
#
# Usage: sh tests/rosetteos-usb-serial-console-tests.sh
#

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

CONSOLE_HELPER="$REPO_ROOT/scripts/build/overlay/usr/libexec/rosetteos-usb-serial-console"
INIT_SCRIPT="$REPO_ROOT/scripts/build/overlay/etc/init.d/S11rosetteos-usb-serial"
UDEV_RULE="$REPO_ROOT/scripts/build/overlay/etc/udev/rules.d/92-usb-serial-console.rules"
KERNEL_FRAGMENT="$REPO_ROOT/artifacts/buildroot-halley5-v30-image/halley5-rosetteos-fragment.config"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/rosetteos-usb-serial-tests.XXXXXX")
[ -n "${WORK:-}" ] && [ -e "$WORK" ] || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT INT TERM

PASS=0
FAIL=0
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }

echo "=== Running RosetteOS USB Serial Console Tests ==="

# 1. Verification of files existence and permissions
echo "--- File Existence and Execution Permissions ---"
[ -f "$CONSOLE_HELPER" ] && pass "rosetteos-usb-serial-console exists" || fail "rosetteos-usb-serial-console missing"
[ -x "$CONSOLE_HELPER" ] && pass "rosetteos-usb-serial-console is executable" || fail "rosetteos-usb-serial-console not executable"

[ -f "$INIT_SCRIPT" ] && pass "S11rosetteos-usb-serial exists" || fail "S11rosetteos-usb-serial missing"
[ -x "$INIT_SCRIPT" ] && pass "S11rosetteos-usb-serial is executable" || fail "S11rosetteos-usb-serial not executable"

[ -f "$UDEV_RULE" ] && pass "92-usb-serial-console.rules exists" || fail "92-usb-serial-console.rules missing"

# 2. Syntax validation
echo "--- Shell Syntax Validation ---"
sh -n "$CONSOLE_HELPER" 2>/dev/null && pass "rosetteos-usb-serial-console passes sh -n" || fail "rosetteos-usb-serial-console syntax error"
sh -n "$INIT_SCRIPT" 2>/dev/null && pass "S11rosetteos-usb-serial passes sh -n" || fail "S11rosetteos-usb-serial syntax error"

# 3. Udev rule structure validation
echo "--- Udev Rule Syntax and Actions ---"
grep -q 'ACTION=="add"' "$UDEV_RULE" && grep -q 'KERNEL=="ttyGS\[0-9\]\*"' "$UDEV_RULE" && grep -q 'rosetteos-usb-serial-console start %k' "$UDEV_RULE" \
	&& pass "udev add rule triggers console helper start" || fail "udev add rule invalid"

grep -q 'ACTION=="remove"' "$UDEV_RULE" && grep -q 'KERNEL=="ttyGS\[0-9\]\*"' "$UDEV_RULE" && grep -q 'rosetteos-usb-serial-console stop %k' "$UDEV_RULE" \
	&& pass "udev remove rule triggers console helper stop" || fail "udev remove rule invalid"

# 4. Kernel fragment configuration verification
echo "--- Kernel Config Fragment Verification ---"
grep -q '^CONFIG_USB_DWC2_DUAL_ROLE=y' "$KERNEL_FRAGMENT" \
	&& pass "CONFIG_USB_DWC2_DUAL_ROLE=y is enabled" || fail "CONFIG_USB_DWC2_DUAL_ROLE=y missing"

! grep -q '^CONFIG_USB_DWC2_HOST=y' "$KERNEL_FRAGMENT" \
	&& pass "CONFIG_USB_DWC2_HOST=y is not set" || fail "CONFIG_USB_DWC2_HOST=y unexpectedly enabled"

grep -q '^CONFIG_USB_GADGET=y' "$KERNEL_FRAGMENT" \
	&& pass "CONFIG_USB_GADGET=y is enabled" || fail "CONFIG_USB_GADGET=y missing"

grep -q '^CONFIG_USB_G_SERIAL=y' "$KERNEL_FRAGMENT" \
	&& pass "CONFIG_USB_G_SERIAL=y is enabled" || fail "CONFIG_USB_G_SERIAL=y missing"

grep -q '^CONFIG_U_SERIAL_CONSOLE=y' "$KERNEL_FRAGMENT" \
	&& pass "CONFIG_U_SERIAL_CONSOLE=y is enabled" || fail "CONFIG_U_SERIAL_CONSOLE=y missing"

grep -q '^CONFIG_USB_DWC2_SOF_FILTER=y' "$KERNEL_FRAGMENT" \
	&& pass "CONFIG_USB_DWC2_SOF_FILTER=y is enabled" || fail "CONFIG_USB_DWC2_SOF_FILTER=y missing"

# 5. Device validation and error handling
echo "--- Device Validation and Error Handling ---"
if env ROSETTEOS_RUNDIR="$WORK/run" "$CONSOLE_HELPER" status sda >/dev/null 2>&1; then
	fail "console helper accepted invalid device sda"
else
	pass "console helper rejected invalid device sda"
fi

if env ROSETTEOS_RUNDIR="$WORK/run" ROSETTEOS_DEVNODE_PREFIX="$WORK/dev/" "$CONSOLE_HELPER" start ttyGS0 >/dev/null 2>&1; then
	fail "console helper start succeeded without devnode"
else
	pass "console helper start failed cleanly when device node was missing"
fi

# 6. Functional Lifecycle in Sandbox
echo "--- Functional Lifecycle and Process Management ---"
mkdir -p "$WORK/run" "$WORK/dev" "$WORK/bin"

# Create a mock getty binary that sleeps
cat > "$WORK/bin/mock-getty" << 'EOF'
#!/bin/sh
sleep 100
EOF
chmod +x "$WORK/bin/mock-getty"

# Create mock tty node
touch "$WORK/dev/ttyGS0"

# Start service
start_out=$(env ROSETTEOS_RUNDIR="$WORK/run" \
	ROSETTEOS_DEVNODE_PREFIX="$WORK/dev/" \
	ROSETTEOS_GETTY_BIN="$WORK/bin/mock-getty" \
	"$CONSOLE_HELPER" start ttyGS0 2>&1)
[ -f "$WORK/run/rosetteos-usb-serial-ttyGS0.pid" ] \
	&& pass "PID file created on start" || fail "PID file not created on start: $start_out"

sup_pid=$(cat "$WORK/run/rosetteos-usb-serial-ttyGS0.pid" 2>/dev/null || true)
if [ -n "$sup_pid" ] && kill -0 "$sup_pid" 2>/dev/null; then
	pass "supervisor process running (PID $sup_pid)"
else
	fail "supervisor process not running"
fi

# Test status command
env ROSETTEOS_RUNDIR="$WORK/run" \
	ROSETTEOS_DEVNODE_PREFIX="$WORK/dev/" \
	ROSETTEOS_GETTY_BIN="$WORK/bin/mock-getty" \
	"$CONSOLE_HELPER" status ttyGS0 >/dev/null 2>&1 \
	&& pass "status reports running when active" || fail "status reported not running when active"

# Test idempotent start
idempotent_out=$(env ROSETTEOS_RUNDIR="$WORK/run" \
	ROSETTEOS_DEVNODE_PREFIX="$WORK/dev/" \
	ROSETTEOS_GETTY_BIN="$WORK/bin/mock-getty" \
	"$CONSOLE_HELPER" start ttyGS0 2>&1)
sup_pid2=$(cat "$WORK/run/rosetteos-usb-serial-ttyGS0.pid" 2>/dev/null || true)
if [ "$sup_pid" = "$sup_pid2" ]; then
	pass "idempotent start preserves existing supervisor PID"
else
	fail "idempotent start changed supervisor PID: $sup_pid -> $sup_pid2"
fi

# Test stop command
env ROSETTEOS_RUNDIR="$WORK/run" \
	ROSETTEOS_DEVNODE_PREFIX="$WORK/dev/" \
	ROSETTEOS_GETTY_BIN="$WORK/bin/mock-getty" \
	"$CONSOLE_HELPER" stop ttyGS0 >/dev/null 2>&1

[ ! -f "$WORK/run/rosetteos-usb-serial-ttyGS0.pid" ] \
	&& pass "PID file removed on stop" || fail "PID file still present after stop"

if kill -0 "$sup_pid" 2>/dev/null; then
	fail "supervisor process still running after stop"
else
	pass "supervisor process terminated on stop"
fi

if env ROSETTEOS_RUNDIR="$WORK/run" \
	ROSETTEOS_DEVNODE_PREFIX="$WORK/dev/" \
	ROSETTEOS_GETTY_BIN="$WORK/bin/mock-getty" \
	"$CONSOLE_HELPER" status ttyGS0 >/dev/null 2>&1; then
	fail "status reports running after stop"
else
	pass "status returns non-zero when stopped"
fi

# 7. Init Script S11rosetteos-usb-serial Validation
echo "--- Init Script Integration ---"
# When no ttyGS devices exist
env ROSETTEOS_CONSOLE_HELPER="$CONSOLE_HELPER" \
	ROSETTEOS_DEVNODE_PREFIX="$WORK/dev/empty_" \
	"$INIT_SCRIPT" start >/dev/null 2>&1 \
	&& pass "S11rosetteos-usb-serial start exits cleanly when no ttyGS present" \
	|| fail "S11rosetteos-usb-serial start failed with no devices"

# When mock ttyGS0 exists
env ROSETTEOS_CONSOLE_HELPER="$CONSOLE_HELPER" \
	ROSETTEOS_RUNDIR="$WORK/run" \
	ROSETTEOS_DEVNODE_PREFIX="$WORK/dev/" \
	ROSETTEOS_GETTY_BIN="$WORK/bin/mock-getty" \
	"$INIT_SCRIPT" start >/dev/null 2>&1

[ -f "$WORK/run/rosetteos-usb-serial-ttyGS0.pid" ] \
	&& pass "S11rosetteos-usb-serial start launches console for present devnode" \
	|| fail "S11rosetteos-usb-serial start did not launch console"

# Init stop
env ROSETTEOS_CONSOLE_HELPER="$CONSOLE_HELPER" \
	ROSETTEOS_RUNDIR="$WORK/run" \
	ROSETTEOS_DEVNODE_PREFIX="$WORK/dev/" \
	ROSETTEOS_GETTY_BIN="$WORK/bin/mock-getty" \
	"$INIT_SCRIPT" stop >/dev/null 2>&1

[ ! -f "$WORK/run/rosetteos-usb-serial-ttyGS0.pid" ] \
	&& pass "S11rosetteos-usb-serial stop shuts down console" \
	|| fail "S11rosetteos-usb-serial stop failed"

echo ""
echo "============================================================"
echo "RosetteOS USB Serial Console Tests: $PASS passed, $FAIL failed"
echo "============================================================"

[ "$FAIL" -eq 0 ]
