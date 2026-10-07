#!/bin/sh
#
# Offline, repeatable tests for scripts/build/overlay/usr/bin/supervisorctl
# (the fake supervisorctl shim Moonraker's [machine] provider=supervisord_cli
# talks to on this BusyBox/no-supervisord image).
#
# Regression coverage for the real, live-found bug (Display Baseline
# Closeout Mission, 2026-08-03): print_process_status()'s field width
# (originally a bare printf "%-33s") silently produced NO separator at
# all between a service name and its RUNNING/STOPPED state whenever the
# name was >= 33 characters - printf does not truncate or pad a string
# already longer than the field width. Moonraker's own
# machine.py:_get_process_info() does `parts = line.split(); name =
# parts[0]; state = parts[1].lower()`, so a run-together line like
# "nebulaos-display-sleep-wake-controllerSTOPPED" became a single token
# and parts[1] raised IndexError - which silently killed Moonraker's
# "machine" component init, which in turn (via
# klippy_connection._get_service_info(), called unconditionally from
# _do_connect() before the ready/registration flow even starts) broke
# Moonraker's entire Klippy connection sequence: no printer.* endpoints
# ever registered, GuppyScreen's "can't connect" error, and
# S99confirm-good's own /server/info klippy_state poll never seeing
# "ready" - which is what caused the printer to revert to stock on every
# warm reboot until this was fixed.
#
# Tests the real shim script directly, calling it in its "status <names>"
# form (bypassing get_services()/the real /var/run/moonraker.pid, which
# this sandbox cannot fake) - is_running() itself will report STOPPED for
# any name with no real pidfile/process, which is fine: this suite is
# about output FORMAT/parseability, not about live service state.
#
# Usage: sh tests/supervisorctl-shim-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
SHIM="$REPO_ROOT/scripts/build/overlay/usr/bin/supervisorctl"

PASS=0
FAIL=0

fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { PASS=$((PASS + 1)); }

[ -f "$SHIM" ] || { echo "SKIP: $SHIM not present"; exit 0; }

# Reimplements Moonraker's own machine.py:_get_process_info() line
# parsing exactly (parts = line.split(); name = parts[0]; state =
# parts[1]) using POSIX word-splitting, so this test fails the same way
# Moonraker's own code failed if the shim ever regresses - not a
# reimplementation of some OTHER, looser check.
moonraker_would_parse_ok() {
	line="$1"
	# shellcheck disable=SC2086
	set -- $line
	[ "$#" -ge 2 ] || return 1
	return 0
}

# --- Test 1: the exact real-world regression name (39 chars, the actual
# S98 service name that broke this live) parses as two fields. ---
LONG_NAME="rosetteos-display-sleep-wake-controller"
LINE=$(sh "$SHIM" status "$LONG_NAME" 2>/dev/null)
if moonraker_would_parse_ok "$LINE"; then
	pass
else
	fail "supervisorctl status output for the real 39-char service name '$LONG_NAME' does not parse as 'name state': got '$LINE'"
fi

# --- Test 2: an even longer, hypothetical future name (never shipped,
# but proves this isn't a fix tuned to exactly 39 chars) also parses. ---
VERY_LONG_NAME="rosetteos-some-hypothetical-future-controller-with-a-very-long-name"
LINE=$(sh "$SHIM" status "$VERY_LONG_NAME" 2>/dev/null)
if moonraker_would_parse_ok "$LINE"; then
	pass
else
	fail "supervisorctl status output for a 68-char hypothetical service name does not parse as 'name state': got '$LINE'"
fi

# --- Test 3: a short, pre-existing name (e.g. real "klipper") still
# parses correctly too - the fix must not have broken the common case. ---
LINE=$(sh "$SHIM" status klipper 2>/dev/null)
if moonraker_would_parse_ok "$LINE"; then
	pass
else
	fail "supervisorctl status output for a short, ordinary service name ('klipper') does not parse: got '$LINE'"
fi

# --- Test 4: the parsed name field for the long-name case is the FULL,
# exact service name - not truncated, not merged with the state word. ---
LINE=$(sh "$SHIM" status "$LONG_NAME" 2>/dev/null)
# shellcheck disable=SC2086
set -- $LINE
PARSED_NAME="$1"
[ "$PARSED_NAME" = "$LONG_NAME" ] && pass \
	|| fail "parsed name field was '$PARSED_NAME', expected the full unmangled '$LONG_NAME'"

# --- Test 5: the parsed state field is a real state word (RUNNING or
# STOPPED), not a run-together "<name>RUNNING"/"<name>STOPPED" blob. ---
LINE=$(sh "$SHIM" status "$LONG_NAME" 2>/dev/null)
# shellcheck disable=SC2086
set -- $LINE
PARSED_STATE="$2"
case "$PARSED_STATE" in
	RUNNING|STOPPED) pass ;;
	*) fail "parsed state field was '$PARSED_STATE', expected exactly RUNNING or STOPPED" ;;
esac

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
