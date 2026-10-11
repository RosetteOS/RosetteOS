#!/bin/sh
#
# Offline, repeatable tests for the print-control config closure validator
# (mainline print-controls mission, 2026-07-29, see
# docs/NEBULAOS_FRONTEND_PRINT_CONTROLS.md). This is the build gate that
# must fail the image build if the factory printer_data/config seed is
# missing, or has duplicate definitions of, virtual_sdcard/pause_resume/
# display_status/PAUSE/RESUME/CANCEL_PRINT.
#
# Sources scripts/build/lib/validate-frontend-controls.sh directly - the
# exact functions scripts/build/04-cross-compile-app-stack.sh calls against
# the real overlay source - so these tests exercise the actual build gate,
# not a second/parallel reimplementation of its rules (same convention as
# tests/factory-seed-git-tests.sh and scripts/build/lib/make-seed-archive.sh).
# Never touches a real device or /usr/data.
#
# Usage: sh tests/rosetteos-frontend-controls-validation-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
LIB="$REPO_ROOT/scripts/build/lib/validate-frontend-controls.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/frontend-controls-tests.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM

# shellcheck disable=SC1090
. "$LIB"

PASS=0
FAIL=0

fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

EXPECTED_PATH="/opt/printer_data/gcodes"

# Runs the real resolve+validate pipeline against a fixture dir and
# compares the outcome to what the test expects.
# $1=label $2=fixture dir $3=entry file $4=expect_resolve_ok(0/1)
# $5=expect_validate_ok(0/1, ignored if $4=1)
check_scenario() {
	label="$1"; dir="$2"; entry="$3"; expect_resolve="$4"; expect_validate="$5"
	closure="$WORK/closure-$$.txt"
	if frontend_controls_resolve_closure "$dir" "$entry" "$closure" >"$WORK/log-$$.txt" 2>&1; then
		resolve_ok=0
	else
		resolve_ok=1
	fi
	if [ "$resolve_ok" != "$expect_resolve" ]; then
		fail "$label: resolve returned $resolve_ok, expected $expect_resolve ($(cat "$WORK/log-$$.txt"))"
		rm -f "$closure" "$WORK/log-$$.txt"
		return
	fi
	if [ "$expect_resolve" = "1" ]; then
		pass "$label: include resolution correctly failed"
		rm -f "$closure" "$WORK/log-$$.txt"
		return
	fi
	if frontend_controls_validate_closure "$closure" "$EXPECTED_PATH" >"$WORK/vlog-$$.txt" 2>&1; then
		validate_ok=0
	else
		validate_ok=1
	fi
	if [ "$validate_ok" = "$expect_validate" ]; then
		pass "$label"
	else
		fail "$label: validate returned $validate_ok, expected $expect_validate ($(cat "$WORK/vlog-$$.txt"))"
	fi
	rm -f "$closure" "$WORK/log-$$.txt" "$WORK/vlog-$$.txt"
}

# --- fixture builders ---------------------------------------------------

write_clean_fixture() {
	dir="$1"
	rm -rf "$dir"
	mkdir -p "$dir/GuppyScreen"
	cat > "$dir/printer.cfg" <<'EOF'
[include frontend-controls.cfg]
[include GuppyScreen/guppy_cmd.cfg]

[printer]
kinematics: cartesian
EOF
	cat > "$dir/frontend-controls.cfg" <<EOF
[virtual_sdcard]
path: $EXPECTED_PATH
on_error_gcode: CANCEL_PRINT

[pause_resume]

[display_status]

[gcode_macro PAUSE]
rename_existing: BASE_PAUSE
gcode:
  BASE_PAUSE

[gcode_macro RESUME]
rename_existing: BASE_RESUME
gcode:
  BASE_RESUME

[gcode_macro CANCEL_PRINT]
rename_existing: BASE_CANCEL_PRINT
gcode:
  BASE_CANCEL_PRINT
EOF
	echo "[respond]" > "$dir/GuppyScreen/guppy_cmd.cfg"
}

# --- Scenario 1: clean valid config passes -----------------------------

d="$WORK/s1"; write_clean_fixture "$d"
check_scenario "clean valid config passes" "$d" printer.cfg 0 0

# --- Scenario 2: missing frontend-controls include ---------------------

d="$WORK/s2"; write_clean_fixture "$d"
cat > "$d/printer.cfg" <<'EOF'
[include GuppyScreen/guppy_cmd.cfg]

[printer]
kinematics: cartesian
EOF
check_scenario "missing frontend-controls include is rejected" "$d" printer.cfg 0 1

# --- Scenario 3: missing included file (referenced but absent) ---------

d="$WORK/s3"; write_clean_fixture "$d"
rm -f "$d/frontend-controls.cfg"
check_scenario "missing included file is rejected" "$d" printer.cfg 1 0

# --- Scenario 4: missing virtual_sdcard ---------------------------------

d="$WORK/s4"; write_clean_fixture "$d"
cat > "$d/frontend-controls.cfg" <<'EOF'
[pause_resume]

[display_status]
EOF
check_scenario "missing virtual_sdcard is rejected" "$d" printer.cfg 0 1

# --- Scenario 5: wrong gcode path ----------------------------------------

d="$WORK/s5"; write_clean_fixture "$d"
cat > "$d/frontend-controls.cfg" <<'EOF'
[virtual_sdcard]
path: /home/pi/printer_data/gcodes
on_error_gcode: CANCEL_PRINT

[pause_resume]

[display_status]
EOF
check_scenario "wrong gcode path is rejected" "$d" printer.cfg 0 1

# --- Scenario 6: missing pause_resume --------------------------------

d="$WORK/s6"; write_clean_fixture "$d"
cat > "$d/frontend-controls.cfg" <<EOF
[virtual_sdcard]
path: $EXPECTED_PATH
on_error_gcode: CANCEL_PRINT

[display_status]
EOF
check_scenario "missing pause_resume is rejected" "$d" printer.cfg 0 1

# --- Scenario 7: missing display_status ---------------------------------

d="$WORK/s7"; write_clean_fixture "$d"
cat > "$d/frontend-controls.cfg" <<EOF
[virtual_sdcard]
path: $EXPECTED_PATH
on_error_gcode: CANCEL_PRINT

[pause_resume]
EOF
check_scenario "missing display_status is rejected" "$d" printer.cfg 0 1

# --- Scenario 7b: pause_resume present but the gcode_macro PAUSE/RESUME/ --
# --- CANCEL_PRINT wrapper macros are missing - the real bug reported live --
# --- (2026-07-29): Mainsail's frontend checks configfile.settings for ------
# --- these literal macro sections directly, regardless of whether the ------
# --- commands already work at runtime via pause_resume.py ------------------

d="$WORK/s7b"; write_clean_fixture "$d"
cat > "$d/frontend-controls.cfg" <<EOF
[virtual_sdcard]
path: $EXPECTED_PATH
on_error_gcode: CANCEL_PRINT

[pause_resume]

[display_status]
EOF
check_scenario "missing gcode_macro PAUSE/RESUME/CANCEL_PRINT wrappers is rejected even with pause_resume present" "$d" printer.cfg 0 1

# --- Scenario 8: duplicate PAUSE macro -----------------------------------

d="$WORK/s8"; write_clean_fixture "$d"
cat >> "$d/frontend-controls.cfg" <<'EOF'

[gcode_macro PAUSE]
rename_existing: BASE_PAUSE
gcode:
  BASE_PAUSE
EOF
echo "" >> "$d/GuppyScreen/guppy_cmd.cfg"
cat >> "$d/printer.cfg" <<'EOF'

[gcode_macro PAUSE]
rename_existing: BASE_PAUSE_2
gcode:
  BASE_PAUSE_2
EOF
check_scenario "duplicate PAUSE macro is rejected" "$d" printer.cfg 0 1

# --- Scenario 9: recursive rename_existing chain ------------------------

d="$WORK/s9"; write_clean_fixture "$d"
cat > "$d/frontend-controls.cfg" <<EOF
[virtual_sdcard]
path: $EXPECTED_PATH
on_error_gcode: CANCEL_PRINT

[pause_resume]

[display_status]

[gcode_macro PAUSE]
rename_existing: BASE_PAUSE
gcode:
  BASE_PAUSE

[gcode_macro RESUME]
rename_existing: BASE_RESUME
gcode:
  BASE_RESUME

[gcode_macro CANCEL_PRINT]
rename_existing: CANCEL_PRINT
gcode:
  CANCEL_PRINT
EOF
check_scenario "recursive rename_existing chain is rejected" "$d" printer.cfg 0 1

# --- Scenario 10: clean valid config supplies exactly what GuppyScreen ---
# --- actually calls (strings-confirmed against the real guppyscreen ------
# --- binary in docs/NEBULAOS_FRONTEND_PRINT_CONTROLS.md sec 4 Level 3) ---

d="$WORK/s10"; write_clean_fixture "$d"
closure="$WORK/s10-closure.txt"
frontend_controls_resolve_closure "$d" printer.cfg "$closure" >/dev/null 2>&1
guppy_needs_ok=1
for pattern in "virtual_sdcard" "pause_resume" "display_status"; do
	if ! grep -q -i -E "^\[[[:space:]]*$pattern([[:space:]]|\])" "$closure"; then
		guppy_needs_ok=0
	fi
done
if [ "$guppy_needs_ok" = "1" ]; then
	pass "clean config supplies every object GuppyScreen's binary references (virtual_sdcard/pause_resume/display_status)"
else
	fail "clean config is missing an object GuppyScreen's binary references"
fi

# --- Scenario 11: no Creality/RosetteOS-specific fallback was added --------
# --- (decision record concluded Level 4 is not needed at all - this is ---
# --- a regression guard against one being added silently later) --------

REAL_SRC="$REPO_ROOT/scripts/build/overlay/opt/printer_data/config"
if [ -f "$REAL_SRC/macros/mainsail.cfg" ]; then
	if grep -v '^[[:space:]]*#' "$REAL_SRC/macros/mainsail.cfg" | grep -q -i -E "rosetteos|prtouch_v2|z_compensate"; then
		fail "real mainsail.cfg unexpectedly references a Creality/RosetteOS-specific module"
	else
		pass "real mainsail.cfg references no Creality/RosetteOS-specific module (Level 4 correctly not used)"
	fi
else
	fail "real mainsail.cfg is missing from the tracked overlay source"
fi

# --- Scenario 12: the real, tracked overlay config passes end-to-end ---

if [ -f "$REAL_SRC/printer.cfg" ]; then
	real_closure="$WORK/real-closure.txt"
	if frontend_controls_resolve_closure "$REAL_SRC" printer.cfg "$real_closure" >"$WORK/real-log.txt" 2>&1; then
		if frontend_controls_validate_closure "$real_closure" "$EXPECTED_PATH" >"$WORK/real-vlog.txt" 2>&1; then
			pass "the real tracked overlay printer.cfg closure passes validation end-to-end"
		else
			fail "the real tracked overlay printer.cfg closure failed validation ($(cat "$WORK/real-vlog.txt"))"
		fi
	else
		fail "the real tracked overlay printer.cfg closure failed to resolve ($(cat "$WORK/real-log.txt"))"
	fi
else
	fail "real overlay printer.cfg not found at $REAL_SRC - repository layout has changed"
fi

echo ""
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
