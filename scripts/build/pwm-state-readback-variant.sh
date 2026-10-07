#!/bin/sh
# Applies the PWM state-readback (.get_state) patch (NebulaOS PWM state
# readback mission, 2026-08-xx - see
# docs/NEBULAOS_PWM_STATE_READBACK_REPORT.md and
# scripts/build/patches/pwm-ingenic-v2-get-state.patch) to the vendor
# kernel checkout, for a compile test only.
#
# THIS IS THE ONLY SCRIPT ALLOWED TO TOUCH
#   kernel/kernel-6.6/module_drivers/drivers/pwm/Kconfig
#   kernel/kernel-6.6/module_drivers/drivers/pwm/pwm-ingenic-v2.c
# FROM NOW ON - same overlapping-variant-script discipline as
# touch-qualification-variant.sh (see its own header comment for the real,
# silent-data-loss bug that convention now prevents project-wide).
#
# Background: this board's bound PWM driver (pwm-ingenic-v2.c) only ever
# implemented the .apply half of "struct pwm_ops" - no .get_state. The
# generic PWM core (drivers/pwm/core.c:pwm_device_request()) only reads
# real hardware into a PWM consumer's cached state if .get_state exists;
# without it, a fresh consumer's very first pwm_get_state() call - the
# only time this ever happens, since it's a one-shot seed at PWM request
# time - returns a fabricated all-zero/disabled state regardless of what
# the hardware is actually doing. This was flagged as a hard blocker in
# docs/NEBULAOS_BACKLIGHT_DIAGNOSTIC_PLAN.md: no live PWM mutation should
# be permitted until restoration can be proven exact, and it cannot be
# proven exact without this callback.
#
#   GETSTATE0 (default/today): baseline pwm-ingenic-v2.c, no .get_state -
#       byte-for-byte identical behavior to today (the new code added by
#       GETSTATE1 is entirely inside
#       #ifdef CONFIG_PWM_INGENIC_V2_GET_STATE blocks, so with the option
#       unselected the compiled object is unaffected; verified by this
#       variant's own test suite, which compiles both configurations and
#       diffs their symbol tables).
#   GETSTATE1 (prototype): applies
#       scripts/build/patches/pwm-ingenic-v2-get-state.patch (implements
#       ingenic_pwm_get_state(), wires it into ingenic_pwm_ops.get_state,
#       adds the exported ingenic_pwm_channel_get_state_is_exact() query
#       and a get_state_exact sysfs attribute, and extracts a shared
#       ingenic_pwm_tick_ns() helper so the .apply and .get_state paths
#       can never independently drift on tick<->ns conversion - see the
#       report for the full PRESCALE-ambiguity trace this helper
#       resolves), and selects CONFIG_PWM_INGENIC_V2_GET_STATE=y in the
#       tracked Kconfig fragment.
#
#       COMMON_MODE channels (the default - mode_sel[] is zero-
#       initialized and only ever changed via a debug-only sysfs store
#       handler) get an exact enabled/period/duty_cycle/polarity
#       readback, agreeing with .apply to within one hardware tick.
#       DMA_MODE channels have no simple duty/period register - .apply
#       still reports enabled/polarity accurately, but period/duty_cycle
#       are left at 0 and explicitly flagged NOT exact via
#       ingenic_pwm_channel_get_state_is_exact()/get_state_exact - never
#       fabricated. See the report for the full derivation and the
#       DMA_MODE handling decision (return 0/success with an honest
#       placeholder + out-of-band flag, not an error - an error return
#       would discard the accurate enabled/polarity fields too, per
#       drivers/pwm/core.c's own pwm_device_request() logic).
#
#       NEVER enable CONFIG_PWM_INGENIC_V2_GET_STATE for a production/
#       active-slot build until a live-hardware qualification pass
#       confirms .get_state's readback against real scope/logic-analyzer
#       measurement - this patch is offline/compile-tested only, exactly
#       like display-backlight-diag-variant.sh's own DIAG1.
#
# Same "always reset to the real git-committed baseline first" pattern as
# the sibling variant scripts - `git checkout --` on every affected file
# before deciding what GETSTATE0/GETSTATE1 needs, so repeated switches
# never drift or accumulate partial edits.
#
# IMPORTANT: never run this script while any build against this same
# vendor kernel checkout is in flight - see the equivalent warning in the
# other *-variant.sh scripts (05-final-build.sh's source-tree fingerprint
# check will correctly refuse to trust artifacts built from a tree that
# changed mid-build).
#
# Usage: sh scripts/build/pwm-state-readback-variant.sh <GETSTATE0|GETSTATE1>

set -eu

VARIANT="${1:?usage: $0 <GETSTATE0|GETSTATE1>}"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
SYSTEM_DIR="$REPO_ROOT/vendor/system"
PATCH="$SCRIPT_DIR/patches/pwm-ingenic-v2-get-state.patch"
FRAGMENT="$REPO_ROOT/artifacts/buildroot-halley5-v30-image/halley5-rosetteos-fragment.config"
MARKER="$REPO_ROOT/build-work/pwm-state-readback-variant-applied.txt"

AFFECTED_FILES="
kernel/kernel-6.6/module_drivers/drivers/pwm/Kconfig
kernel/kernel-6.6/module_drivers/drivers/pwm/pwm-ingenic-v2.c
"

BEGIN_MARK="#--- ROSETTEOS_PWM_STATE_READBACK_VARIANT_BEGIN ---"
END_MARK="#--- ROSETTEOS_PWM_STATE_READBACK_VARIANT_END ---"

case "$VARIANT" in
	GETSTATE0|GETSTATE1) ;;
	*)
		echo "unknown variant '$VARIANT' - must be one of GETSTATE0 GETSTATE1" >&2
		exit 1
		;;
esac

[ -f "$PATCH" ] || {
	echo "FATAL: $PATCH not found" >&2
	exit 1
}
[ -f "$FRAGMENT" ] || {
	echo "FATAL: $FRAGMENT not found" >&2
	exit 1
}

git -C "$SYSTEM_DIR" checkout -- $AFFECTED_FILES

if grep -qF "$BEGIN_MARK" "$FRAGMENT"; then
	sed -i "/^${BEGIN_MARK}\$/,/^${END_MARK}\$/d" "$FRAGMENT"
fi

if [ "$VARIANT" = "GETSTATE1" ]; then
	( cd "$SYSTEM_DIR" && git apply "$PATCH" )
	{
		echo "$BEGIN_MARK"
		echo "# NebulaOS PWM state readback mission (2026-08-xx) -"
		echo "# pwm-ingenic-v2.c .get_state variant. Offline/compile-tested only -"
		echo "# do not enable for a production/active-slot build until live"
		echo "# hardware qualification confirms the readback."
		echo "CONFIG_PWM_INGENIC_V2_GET_STATE=y"
		echo "$END_MARK"
	} >> "$FRAGMENT"
fi

mkdir -p "$(dirname "$MARKER")"
printf '%s\n' "$VARIANT" > "$MARKER"
echo "== pwm-state-readback-variant: $VARIANT applied =="
