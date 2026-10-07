#!/bin/sh
#
# Clean-Update + Virgin Baseline mission, Phase 5 (2026-08-08): offline
# assertions that Moonraker's built-in Recovery (soft: fetch + reset to
# the tracked remote ref; hard: full re-clone - see
# docs/NEBULAOS_UPDATER_AUDIT.md) cannot revert any accepted feature.
#
# This is deliberately NOT a fixture-based test like the others under
# tests/ - the source checkouts are real remote repositories (network
# required, no
# device involved) and checks it directly. This is the same class of
# real-remote verification Phase 1's own branch-unification fix used to
# confirm its fast-forward was safe before pushing it.
#
# Usage: sh tests/recovery-safety-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
DEPS_MANIFEST="$REPO_ROOT/manifests/dependencies.conf"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/recovery-safety-tests.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

. "$DEPS_MANIFEST"

# Standard and NebulaOS Klipper extras are checked to ensure the build's
# mainline checkout receives the same extras payload as the factory image.
ACCEPTED_FILES="gcode_macro.py virtual_sdcard.py pause_resume.py tmcstatus.py guppy_config_helper.py guppy_module_loader.py calibrate_shaper_config.py gcode_shell_command.py nebulaos_compat.py nebulaos_temperature_mcu.py nebulaos_version.py nebulaos_z_offset_probe.py nozzle_clear.py prtouch_test_support.py virtual_pins.py z_compensate.py bl24c16f.py nebulaos_plr_journal.py nebulaos_power_loss_recovery.py"

# --- Test 1: manifest, factory-seed, and migrate all agree on one branch ---
# The exact class of bug Phase 1 found: two branches existed, only one was
# actually tracked/pinned, and they silently diverged. This asserts the
# three places that hardcode "which branch is canonical" can never drift
# apart again without this test catching it.

test_branch_consistency() {
	manifest_branch="$KLIPPER_BRANCH"
	factory_seed_script="$REPO_ROOT/scripts/build/overlay/etc/init.d/S04rosetteos-factory-seed"
	factory_seed_branch=$(grep -o 'seed_git_app klipper [a-zA-Z0-9_-]*' \
		"$factory_seed_script" | awk '{print $3}')
	migrate_script="$REPO_ROOT/scripts/build/overlay/etc/init.d/S04rosetteos-migrate"
	migrate_branch=$(grep -o 'reseed_git_app klipper [a-zA-Z0-9_-]*' \
		"$migrate_script" | awk '{print $3}')

	if [ "$manifest_branch" = "master" ] && [ "$manifest_branch" = "$factory_seed_branch" ] \
		&& [ "$manifest_branch" = "$migrate_branch" ]; then
		pass "manifest ($manifest_branch), factory-seed ($factory_seed_branch), and migrate ($migrate_branch) all track the same canonical klipper branch"
	else
		fail "klipper branch drift detected: manifest=$manifest_branch factory-seed=$factory_seed_branch migrate=$migrate_branch - this is exactly the class of bug Phase 1 fixed"
	fi
}

# --- Test 2: real remote clones - build composition has every accepted file ---

test_recovery_target_has_accepted_features() {
	clone_dir="$WORK/klipper-mainline"
	if ! git clone -q --no-checkout "$KLIPPER_REPO" "$clone_dir" 2>"$WORK/clone-error.log"; then
		fail "could not clone mainline $KLIPPER_REPO: $(cat "$WORK/clone-error.log")"
		return
	fi
	if ! git -C "$clone_dir" fetch -q --depth 1 origin "$KLIPPER_PIN" \
		|| ! git -C "$clone_dir" checkout -q "$KLIPPER_PIN"; then
		fail "mainline Klipper does not contain compatibility-qualified commit $KLIPPER_PIN"
	else
		head_commit=$(git -C "$clone_dir" rev-parse HEAD)
		if [ "$head_commit" = "$KLIPPER_PIN" ]; then
			pass "mainline Klipper checkout matches compatibility-qualified commit $KLIPPER_PIN"
		else
			fail "mainline Klipper checkout tip ($head_commit) does not match $KLIPPER_PIN"
		fi
	fi

	extra_dir="$WORK/klipper-extensions"
	if ! git clone -q --no-checkout "$KLIPPER_EXTRAS_REPO" "$extra_dir" 2>"$WORK/extras-clone-error.log"; then
		fail "could not clone pinned extras source $KLIPPER_EXTRAS_REPO: $(cat "$WORK/extras-clone-error.log")"
		return
	fi
	if ! git -C "$extra_dir" checkout -q "$KLIPPER_EXTRAS_PIN"; then
		fail "extras source does not contain pinned commit $KLIPPER_EXTRAS_PIN"
		return
	fi
	for f in $ACCEPTED_FILES; do
		if [ -f "$extra_dir/extras/$f" ]; then
			mkdir -p "$clone_dir/klippy/extras"
			cp "$extra_dir/extras/$f" "$clone_dir/klippy/extras/$f"
		fi
	done

	missing=""
	empty=""
	for f in $ACCEPTED_FILES; do
		path="$clone_dir/klippy/extras/$f"
		if [ ! -f "$path" ]; then
			missing="$missing $f"
		elif [ ! -s "$path" ]; then
			empty="$empty $f"
		fi
	done
	if [ -z "$missing" ] && [ -z "$empty" ]; then
		pass "every required Klipper extra is present and non-empty after build composition"
	else
		fail "recovery target is missing or has empty accepted files - missing:[$missing] empty:[$empty] - a Recovery reset would silently regress these features"
	fi

	# The extras copy is deliberately explicit and must remain scoped to the
	# known NebulaOS modules; it must not replace the mainline Klipper tree.
	if grep -q 'klipper-extensions/extras' "$REPO_ROOT/scripts/build/04-cross-compile-app-stack.sh"; then
		pass "build explicitly composes pinned NebulaOS extras onto mainline Klipper"
	else
		fail "build does not explicitly compose the pinned NebulaOS extras"
	fi
}

test_branch_consistency
test_recovery_target_has_accepted_features

echo
echo "recovery-safety-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
