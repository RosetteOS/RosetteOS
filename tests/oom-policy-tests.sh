#!/bin/sh
#
# MEM-T07: OOM priority at process birth. Every service init script starts its
# daemon through rosetteos_start_with_adj, no script writes oom_score_adj to a
# pid read back from a pidfile, and the helper really gives the child the value
# (raising oom_score_adj needs no privilege, so this uses the real kernel file).
#
# Usage: sh tests/oom-policy-tests.sh

set -u
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
OV="$REPO_ROOT/scripts/build/overlay"
POLICY="$OV/etc/rosetteos-oom-policy.sh"
PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

sh -n "$POLICY" && pass "policy file parses" || fail "policy file does not parse"

for s in S54rosetteos-host-mcu S55klipper S56moonraker S58touch-ui S50webcam S59rosetteos-update-supervisor; do
	f="$OV/etc/init.d/$s"
	grep -q 'rosetteos_start_with_adj "\$ROSETTEOS_ADJ_' "$f" && pass "$s starts its daemon through rosetteos_start_with_adj" || fail "$s does not use rosetteos_start_with_adj"
	grep -q 'ROSETTEOS_OOM_POLICY' "$f" && pass "$s sources the policy" || fail "$s does not source the policy"
done
if grep -n 'oom_score_adj' "$OV"/etc/init.d/* | grep -q 'cat "\$'; then
	fail "an init script still writes oom_score_adj to a pid read from a pidfile"
else
	pass "no post-start pidfile adj writes remain"
fi

# shellcheck disable=SC1090
. "$POLICY"
[ "$ROSETTEOS_ADJ_KLIPPER_MCU" -lt "$ROSETTEOS_ADJ_KLIPPY" ] && [ "$ROSETTEOS_ADJ_KLIPPY" -lt "$ROSETTEOS_ADJ_MOONRAKER" ] \
	&& [ "$ROSETTEOS_ADJ_MOONRAKER" -lt "$ROSETTEOS_ADJ_TOUCH_UI" ] && [ "$ROSETTEOS_ADJ_TOUCH_UI" -lt "$ROSETTEOS_ADJ_USTREAMER" ] \
	&& [ "$ROSETTEOS_ADJ_USTREAMER" -lt "$ROSETTEOS_ADJ_UPDATE_SUPERVISOR" ] \
	&& pass "priority order: klipper_mcu < klippy < moonraker < touch_ui < ustreamer < updates" \
	|| fail "priority order broken"
[ "$ROSETTEOS_ADJ_KLIPPY" -gt -1000 ] && pass "klippy stays killable (not -1000)" || fail "klippy is OOM-immune"

if [ -w /proc/self/oom_score_adj ]; then
	mine=$(cat /proc/self/oom_score_adj)
	want=$((mine + 123)); [ "$want" -gt 1000 ] && want=1000
	got=$(rosetteos_start_with_adj "$want" cat /proc/self/oom_score_adj)
	[ "$got" = "$want" ] && pass "the child is born with the requested adj ($got)" || fail "child adj is '$got', wanted $want"
	[ "$(cat /proc/self/oom_score_adj)" = "$mine" ] && pass "the caller's own adj is untouched" || fail "the caller's adj changed"
fi

echo "oom-policy-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
