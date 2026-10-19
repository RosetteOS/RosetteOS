#!/bin/sh
#
# Offline tests for scripts/build/overlay/usr/bin/sudo shim
# Verifies that Moonraker (and other services) can call sudo commands
# (e.g. sudo reboot, sudo poweroff, sudo -S cmd) without failing.

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
SHIM="$REPO_ROOT/scripts/build/overlay/usr/bin/sudo"

PASS=0
FAIL=0

fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { PASS=$((PASS + 1)); }

[ -f "$SHIM" ] || { echo "SKIP: $SHIM not present"; exit 0; }

# Test 1: Bare command execution
OUT=$(sh "$SHIM" echo "success_test_1" 2>/dev/null)
if [ "$OUT" = "success_test_1" ]; then
	pass
else
	fail "sudo echo failed: got '$OUT'"
fi

# Test 2: Moonraker's standard stdin-pass mode (-S)
OUT=$(sh "$SHIM" -S echo "success_test_2" 2>/dev/null)
if [ "$OUT" = "success_test_2" ]; then
	pass
else
	fail "sudo -S echo failed: got '$OUT'"
fi

# Test 3: Sudo with user flag (-u root)
OUT=$(sh "$SHIM" -u root echo "success_test_3" 2>/dev/null)
if [ "$OUT" = "success_test_3" ]; then
	pass
else
	fail "sudo -u root echo failed: got '$OUT'"
fi

# Test 4: Sudo with combined flags and separator (-- echo arg1 arg2)
OUT=$(sh "$SHIM" -S -u root -- echo "hello" "world" 2>/dev/null)
if [ "$OUT" = "hello world" ]; then
	pass
else
	fail "sudo with multiple options failed: got '$OUT'"
fi

# Test 5: Sudo with non-interactive flag (-n)
OUT=$(sh "$SHIM" -n echo "non_interactive" 2>/dev/null)
if [ "$OUT" = "non_interactive" ]; then
	pass
else
	fail "sudo -n echo failed: got '$OUT'"
fi

# Test 6: Sudo version flag
OUT=$(sh "$SHIM" --version 2>/dev/null)
if echo "$OUT" | grep -q "sudo (RosetteOS embedded shim)"; then
	pass
else
	fail "sudo --version failed: got '$OUT'"
fi

# Test 7: Sudo with no arguments returns non-zero error code
if sh "$SHIM" >/dev/null 2>&1; then
	fail "sudo with no arguments should fail"
else
	pass
fi

echo "sudo-shim-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
