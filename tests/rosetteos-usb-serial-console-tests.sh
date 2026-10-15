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
INIT_SCRIPT="$REPO_ROOT/scripts/build/overlay/etc/init.d/S00rosetteos-usb-serial"
UDEV_RULE="$REPO_ROOT/scripts/build/overlay/etc/udev/rules.d/92-usb-serial-console.rules"
KERNEL_FRAGMENT="$REPO_ROOT/artifacts/buildroot-halley5-v30-image/halley5-rosetteos-fragment.config"
CONFIGURE_SCRIPT="$REPO_ROOT/scripts/build/02-configure-buildroot.sh"
RCS_SCRIPT="$REPO_ROOT/scripts/build/overlay/etc/init.d/rcS"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/rosetteos-usb-serial-tests.XXXXXX")
[ -n "${WORK:-}" ] && [ -e "$WORK" ] || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT INT TERM

PASS=0
FAIL=0
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }

check_cmd() {
	_desc="$1"
	shift
	if "$@" >/dev/null 2>&1; then
		pass "$_desc"
	else
		fail "$_desc"
	fi
}

echo "=== Running RosetteOS USB Serial Console Tests ==="

# 1. Verification of files existence and permissions
echo "--- File Existence and Execution Permissions ---"
check_cmd "rosetteos-usb-serial-console exists" test -f "$CONSOLE_HELPER"
check_cmd "rosetteos-usb-serial-console is executable" test -x "$CONSOLE_HELPER"
check_cmd "S00rosetteos-usb-serial exists" test -f "$INIT_SCRIPT"
check_cmd "S00rosetteos-usb-serial is executable" test -x "$INIT_SCRIPT"
check_cmd "92-usb-serial-console.rules exists" test -f "$UDEV_RULE"

# 2. Syntax validation
echo "--- Shell Syntax Validation ---"
check_cmd "rosetteos-usb-serial-console passes sh -n" sh -n "$CONSOLE_HELPER"
check_cmd "S00rosetteos-usb-serial passes sh -n" sh -n "$INIT_SCRIPT"
check_cmd "rcS passes sh -n" sh -n "$RCS_SCRIPT"

# 3. Udev rule structure validation
echo "--- Udev Rule Syntax and Actions ---"
if grep -q 'ACTION=="add"' "$UDEV_RULE" && grep -q 'KERNEL=="ttyGS\[0-9\]\*"' "$UDEV_RULE" && grep -q 'rosetteos-usb-serial-console start %k' "$UDEV_RULE"; then
	pass "udev add rule triggers console helper start"
else
	fail "udev add rule invalid"
fi

if grep -q 'ACTION=="remove"' "$UDEV_RULE" && grep -q 'KERNEL=="ttyGS\[0-9\]\*"' "$UDEV_RULE" && grep -q 'rosetteos-usb-serial-console stop %k' "$UDEV_RULE"; then
	pass "udev remove rule triggers console helper stop"
else
	fail "udev remove rule invalid"
fi

# 4. Kernel fragment configuration verification
echo "--- Kernel Config Fragment Verification ---"
check_cmd "CONFIG_USB_DWC2_DUAL_ROLE=y is enabled" grep -q '^CONFIG_USB_DWC2_DUAL_ROLE=y' "$KERNEL_FRAGMENT"

if ! grep -q '^CONFIG_USB_DWC2_HOST=y' "$KERNEL_FRAGMENT"; then
	pass "CONFIG_USB_DWC2_HOST=y is not set"
else
	fail "CONFIG_USB_DWC2_HOST=y unexpectedly enabled"
fi

check_cmd "CONFIG_USB_GADGET=y is enabled" grep -q '^CONFIG_USB_GADGET=y' "$KERNEL_FRAGMENT"
check_cmd "CONFIG_USB_G_SERIAL=y is enabled" grep -q '^CONFIG_USB_G_SERIAL=y' "$KERNEL_FRAGMENT"
check_cmd "CONFIG_U_SERIAL_CONSOLE=y is enabled" grep -q '^CONFIG_U_SERIAL_CONSOLE=y' "$KERNEL_FRAGMENT"
check_cmd "CONFIG_USB_DWC2_SOF_FILTER=y is enabled" grep -q '^CONFIG_USB_DWC2_SOF_FILTER=y' "$KERNEL_FRAGMENT"
check_cmd "CONFIG_CMDLINE_BOOL=y is enabled for early bootlogs" grep -q '^CONFIG_CMDLINE_BOOL=y' "$KERNEL_FRAGMENT"
check_cmd "CONFIG_CMDLINE extends console=ttyGS0,115200" grep -q '^CONFIG_CMDLINE=.*console=ttyGS0,115200' "$KERNEL_FRAGMENT"
check_cmd "02-configure-buildroot.sh cleans obsolete S11 path" grep -q "etc/init.d/S11rosetteos-usb-serial" "$CONFIGURE_SCRIPT"
check_cmd "rcS broadcasts milestone telemetry to /dev/kmsg" grep -q '/dev/kmsg' "$RCS_SCRIPT"

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

cat > "$WORK/bin/mock-getty" << 'EOF'
#!/bin/sh
sleep 100
EOF
chmod +x "$WORK/bin/mock-getty"

touch "$WORK/dev/ttyGS0"

start_out=$(env ROSETTEOS_RUNDIR="$WORK/run" \
	ROSETTEOS_DEVNODE_PREFIX="$WORK/dev/" \
	ROSETTEOS_GETTY_BIN="$WORK/bin/mock-getty" \
	"$CONSOLE_HELPER" start ttyGS0 2>&1)
if [ -f "$WORK/run/rosetteos-usb-serial-ttyGS0.pid" ]; then
	pass "PID file created on start"
else
	fail "PID file not created on start: $start_out"
fi

sup_pid=$(cat "$WORK/run/rosetteos-usb-serial-ttyGS0.pid" 2>/dev/null || true)
if [ -n "$sup_pid" ] && kill -0 "$sup_pid" 2>/dev/null; then
	pass "supervisor process running (PID $sup_pid)"
else
	fail "supervisor process not running"
fi

if env ROSETTEOS_RUNDIR="$WORK/run" \
	ROSETTEOS_DEVNODE_PREFIX="$WORK/dev/" \
	ROSETTEOS_GETTY_BIN="$WORK/bin/mock-getty" \
	"$CONSOLE_HELPER" status ttyGS0 >/dev/null 2>&1; then
	pass "status reports running when active"
else
	fail "status reported not running when active"
fi

env ROSETTEOS_RUNDIR="$WORK/run" \
	ROSETTEOS_DEVNODE_PREFIX="$WORK/dev/" \
	ROSETTEOS_GETTY_BIN="$WORK/bin/mock-getty" \
	"$CONSOLE_HELPER" start ttyGS0 >/dev/null 2>&1
sup_pid2=$(cat "$WORK/run/rosetteos-usb-serial-ttyGS0.pid" 2>/dev/null || true)
if [ "$sup_pid" = "$sup_pid2" ]; then
	pass "idempotent start preserves existing supervisor PID"
else
	fail "idempotent start changed supervisor PID: $sup_pid -> $sup_pid2"
fi

env ROSETTEOS_RUNDIR="$WORK/run" \
	ROSETTEOS_DEVNODE_PREFIX="$WORK/dev/" \
	ROSETTEOS_GETTY_BIN="$WORK/bin/mock-getty" \
	"$CONSOLE_HELPER" stop ttyGS0 >/dev/null 2>&1

if [ ! -f "$WORK/run/rosetteos-usb-serial-ttyGS0.pid" ]; then
	pass "PID file removed on stop"
else
	fail "PID file still present after stop"
fi

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

# 7. Init Script S00rosetteos-usb-serial Validation
echo "--- Init Script Integration ---"
if env ROSETTEOS_CONSOLE_HELPER="$CONSOLE_HELPER" \
	ROSETTEOS_DEVNODE_PREFIX="$WORK/dev/empty_" \
	"$INIT_SCRIPT" start >/dev/null 2>&1; then
	pass "S00rosetteos-usb-serial start exits cleanly when no ttyGS present"
else
	fail "S00rosetteos-usb-serial start failed with no devices"
fi

env ROSETTEOS_CONSOLE_HELPER="$CONSOLE_HELPER" \
	ROSETTEOS_RUNDIR="$WORK/run" \
	ROSETTEOS_DEVNODE_PREFIX="$WORK/dev/" \
	ROSETTEOS_GETTY_BIN="$WORK/bin/mock-getty" \
	"$INIT_SCRIPT" start >/dev/null 2>&1

if [ -f "$WORK/run/rosetteos-usb-serial-ttyGS0.pid" ]; then
	pass "S00rosetteos-usb-serial start launches console for present devnode"
else
	fail "S00rosetteos-usb-serial start did not launch console"
fi

env ROSETTEOS_CONSOLE_HELPER="$CONSOLE_HELPER" \
	ROSETTEOS_RUNDIR="$WORK/run" \
	ROSETTEOS_DEVNODE_PREFIX="$WORK/dev/" \
	ROSETTEOS_GETTY_BIN="$WORK/bin/mock-getty" \
	"$INIT_SCRIPT" stop >/dev/null 2>&1

if [ ! -f "$WORK/run/rosetteos-usb-serial-ttyGS0.pid" ]; then
	pass "S00rosetteos-usb-serial stop shuts down console"
else
	fail "S00rosetteos-usb-serial stop failed"
fi

echo ""
echo "============================================================"
echo "RosetteOS USB Serial Console Tests: $PASS passed, $FAIL failed"
echo "============================================================"

[ "$FAIL" -eq 0 ]
