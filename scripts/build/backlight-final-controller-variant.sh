#!/bin/sh
# Applies the DISPLAY-B-FINAL kernel-owned backlight final controller
# (post-incident redesign, 2026-08-02+ - see
# vendor/system/kernel/kernel-6.6/module_drivers/drivers/misc/
# nebulaos_backlight_final_controller.c's own file header for the full
# incident writeup and design rationale, and
# scripts/build/patches/backlight-final-controller.patch) to the vendor
# kernel checkout, for a compile test only. NEVER apply this to a build
# destined for the active/production slot until live hardware testing
# confirms correct behavior.
#
#   FINAL0 (default/today): no controller driver, no DT node for it.
#       Identical to today's real baseline.
#   FINAL1: applies scripts/build/patches/backlight-final-controller.patch
#       (a new platform driver,
#       module_drivers/drivers/misc/nebulaos_backlight_final_controller.c,
#       plus its Kconfig/Makefile wiring - all guarded by
#       #ifdef/depends-on CONFIG_NEBULAOS_BACKLIGHT_FINAL_CONTROLLER so the
#       compiled tree is unaffected unless the option is also selected in
#       the Kconfig fragment, which THIS script does as a separate step),
#       selects CONFIG_NEBULAOS_BACKLIGHT_FINAL_CONTROLLER=y in the tracked
#       Kconfig fragment, and adds a new DT node instantiating the
#       controller against the three candidate hardware resources it
#       exclusively owns (GPC0 as GPIO, GPC0/PWM channel 0, and the
#       candidate enable-GPIO PC22).
#
#       CRITICAL DIFFERENCE FROM THE OLDER display-backlight-diag-variant.sh
#       PROTOTYPE, AND THE ENTIRE REASON THIS DRIVER EXISTS: this script
#       NEVER touches the shared &pwm controller node's own pinctrl-0
#       property - that edit (repointing it from the unused channel-1 pin
#       to the real candidate channel-0 pin) is EXACTLY what caused a real
#       incident on the physical printer (the screen going dark from boot -
#       see the driver's own file header for the full root-cause writeup).
#       &pwm's pinctrl-0 stays <&pwm1_pc> always, in both FINAL0 and
#       FINAL1 - this script only ever adds/removes its OWN DT node, which
#       carries its OWN pinctrl-names/pinctrl-0 pointing at the same
#       <&pwm0_pc> group under a state named "pwm-active" (deliberately
#       never "default"/"init", so the device core's automatic
#       pinctrl_bind_pins() never selects it either - see the driver's
#       file header for the exact mechanism). GPC0 is muxed to the PWM
#       peripheral function ONLY when the driver's own code explicitly
#       selects that state at runtime, in response to an explicit
#       "pwm-active-25/50/75" debugfs command issued from safe-on - never
#       automatically, never at boot, never at module bind time. A
#       dedicated test in
#       tests/backlight-final-controller-variant-tests.sh greps for the
#       exact pristine &pwm pinctrl-0 line and asserts it is byte-identical
#       before and after this script applies/reverts FINAL1.
#
#       The controller driver itself never touches GPC0/PC22/PWM0 state at
#       module bind time - it only registers, sets up debugfs, and starts
#       in "boot-preserve" (zero hardware claimed). Every operation is
#       opt-in via a bounded debugfs command interface, arms a kernel-owned
#       watchdog (hard 2-second cap) BEFORE applying any hardware mutation,
#       and always converges back to the live-proven-safe target (GPC0 =
#       GPIO output HIGH) on completion, timeout, error, or explicit
#       disarm. See the driver's own file header for the complete state
#       machine and the exact pinctrl-core/pinctrl-ingenic.c call chains
#       this relies on.
#
# Same "always reset to the real git-committed baseline first" pattern as
# the sibling variant scripts, and the SAME scoped-revert discipline
# wifi-sdio-variant.sh/display-backlight-diag-variant.sh now use for the
# shared DTS file (marker-based strip, never a blanket `git checkout --`)
# - this script's own DTS edit is entirely additive (a new top-level node
# appended, wrapped in its own begin/end markers) and never touches any
# line any other variant script owns, so switching this script back and
# forth can never wipe out wifi-sdio-variant.sh's or
# display-backlight-diag-variant.sh's own edits regardless of run order,
# and vice versa.
#
# IMPORTANT: never run this script while any build against this same
# vendor kernel checkout is in flight - a build's own source-tree
# fingerprint check (05-final-build.sh) will correctly refuse to trust
# artifacts built from a tree that changed mid-build. Apply the desired
# variant BEFORE starting a build, not during one.
#
# Usage: sh scripts/build/backlight-final-controller-variant.sh <FINAL0|FINAL1>

set -eu

VARIANT="${1:?usage: $0 <FINAL0|FINAL1>}"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
SYSTEM_DIR="$REPO_ROOT/vendor/system"
PATCH="$SCRIPT_DIR/patches/backlight-final-controller.patch"
DTS_REL="kernel/kernel-6.6/module_drivers/dts/x2000/halley5_v30.dts"
DTS="$SYSTEM_DIR/$DTS_REL"
FRAGMENT="$REPO_ROOT/artifacts/buildroot-halley5-v30-image/halley5-rosetteos-fragment.config"
MARKER="$REPO_ROOT/build-work/backlight-final-controller-variant-applied.txt"

NEW_DRIVER_REL="kernel/kernel-6.6/module_drivers/drivers/misc/nebulaos_backlight_final_controller.c"

BEGIN_MARK="#--- ROSETTEOS_BACKLIGHT_FINAL_CONTROLLER_VARIANT_BEGIN ---"
END_MARK="#--- ROSETTEOS_BACKLIGHT_FINAL_CONTROLLER_VARIANT_END ---"
# Plain alphanumeric+underscore only, same rationale as
# display-backlight-diag-variant.sh's DTS_MARK_BEGIN/END - used directly as
# an unanchored sed /pattern/ substring match, avoiding any need to
# regex-escape the /* */ C-comment delimiters wrapped around it in the DTS.
DTS_MARK_BEGIN="ROSETTEOS_BACKLIGHT_FINAL_CONTROLLER_VARIANT_DTS_BEGIN"
DTS_MARK_END="ROSETTEOS_BACKLIGHT_FINAL_CONTROLLER_VARIANT_DTS_END"

case "$VARIANT" in
	FINAL0|FINAL1) ;;
	*)
		echo "unknown variant '$VARIANT' - must be one of FINAL0 FINAL1" >&2
		exit 1
		;;
esac

[ -f "$PATCH" ] || {
	echo "FATAL: $PATCH not found" >&2
	exit 1
}
[ -f "$DTS" ] || {
	echo "FATAL: $DTS not found - run 00-fetch-vendor-sources.sh first" >&2
	exit 1
}
[ -f "$FRAGMENT" ] || {
	echo "FATAL: $FRAGMENT not found" >&2
	exit 1
}

# Always reset the misc driver files to their real, git-committed baseline
# first - these are wholly owned by this script, no sharing concern (no
# other variant script touches drivers/misc/Kconfig|Makefile or this new
# driver file). The new driver file is untracked when absent, so
# `git checkout --` on it alone would fail with "did not match any files" -
# remove it directly instead, then let a fresh `git apply` recreate it if
# FINAL1 was requested.
git -C "$SYSTEM_DIR" checkout -- \
	kernel/kernel-6.6/module_drivers/drivers/misc/Kconfig \
	kernel/kernel-6.6/module_drivers/drivers/misc/Makefile
rm -f "$SYSTEM_DIR/$NEW_DRIVER_REL"

# The DTS IS shared with wifi-sdio-variant.sh/display-backlight-diag-
# variant.sh (unrelated &msc1/&pwm nodes and top-level nodes of their own).
# Deliberately NOT a blanket `git checkout -- "$DTS_REL"` here - see the
# real, confirmed bug both of those scripts' own headers document (a
# composed qualification build silently losing one script's DT node because
# another script's blanket checkout wiped it after the fact). Scoped
# instead: this script's own DTS edit is a single, wholly self-contained,
# marker-wrapped top-level node appended at the end of the file - it never
# edits any EXISTING line (in particular, and unlike the older
# display-backlight-diag-variant.sh prototype, it NEVER touches the &pwm
# node's own pinctrl-0 line at all - see the file header above), so
# reverting it is just "strip the marked block if present", nothing else.
if grep -qF "$DTS_MARK_BEGIN" "$DTS"; then
	sed -i "/${DTS_MARK_BEGIN}/,/${DTS_MARK_END}/d" "$DTS"
fi

if ! grep -q '^&pwm {' "$DTS"; then
	echo "FATAL: could not find the &pwm node in $DTS - has the board DTS changed?" >&2
	exit 1
fi
if ! grep -q 'pinctrl-0 = <&pwm1_pc>;' "$DTS"; then
	echo "FATAL: &pwm's pinctrl-0 is not the expected pristine <&pwm1_pc> - " \
		"has another variant script left it modified, or has the board DTS " \
		"changed? This script refuses to proceed rather than silently " \
		"building against an unexpected &pwm pinctrl-0 value." >&2
	exit 1
fi

# Strip any previously-applied fragment block first, unconditionally - same
# idempotent pattern as the sibling variant scripts.
if grep -qF "$BEGIN_MARK" "$FRAGMENT"; then
	sed -i "/^${BEGIN_MARK}\$/,/^${END_MARK}\$/d" "$FRAGMENT"
fi

if [ "$VARIANT" = "FINAL1" ]; then
	( cd "$SYSTEM_DIR" && git apply "$PATCH" )

	# Append-only: a single new top-level node. Deliberately does NOT
	# touch &pwm's pinctrl-0 - see the file header above and
	# tests/backlight-final-controller-variant-tests.sh's dedicated
	# byte-identical assertion for this.
	{
		echo "/* $DTS_MARK_BEGIN */"
		echo "/* Post-incident backlight controller redesign (2026-08-02+) -"
		echo " * DISPLAY-B-FINAL kernel-owned exclusive owner of GPC0 (as GPIO"
		echo " * and as PWM channel 0's peripheral function) and the candidate"
		echo " * enable-GPIO PC22. Deliberately does NOT touch the &pwm node's"
		echo " * own pinctrl-0 above (that edit is what caused a real incident -"
		echo " * see nebulaos_backlight_final_controller.c's file header). GPC0's"
		echo " * PWM-function pinmux is instead selected dynamically, only by"
		echo " * this driver's own code, only at the moment pwm-active is"
		echo " * actually entered - the pinctrl-0 group below is named"
		echo " * \"pwm-active\", deliberately not \"default\"/\"init\", so the"
		echo " * device core's automatic pinctrl_bind_pins() never selects it. */"
		echo "/ {"
		echo "	nebulaos_backlight_final: nebulaos_backlight_final {"
		echo "		compatible = \"nebulaos,backlight-final-controller\";"
		echo "		pwms = <&pwm 0 20000>;"
		echo "		backlight-gpios = <&gpc 0 GPIO_ACTIVE_HIGH INGENIC_GPIO_NOBIAS>;"
		echo "		enable-gpios = <&gpc 22 GPIO_ACTIVE_HIGH INGENIC_GPIO_NOBIAS>;"
		echo "		pinctrl-names = \"pwm-active\";"
		echo "		pinctrl-0 = <&pwm0_pc>;"
		echo "		status = \"okay\";"
		echo "	};"
		echo "};"
		echo "/* $DTS_MARK_END */"
	} >> "$DTS"

	{
		echo "$BEGIN_MARK"
		echo "# Post-incident backlight controller redesign (2026-08-02+) -"
		echo "# DISPLAY-B-FINAL kernel-owned backlight final controller variant."
		echo "CONFIG_NEBULAOS_BACKLIGHT_FINAL_CONTROLLER=y"
		echo "$END_MARK"
	} >> "$FRAGMENT"
fi

mkdir -p "$(dirname "$MARKER")"
printf '%s\n' "$VARIANT" > "$MARKER"
echo "== backlight-final-controller-variant: $VARIANT applied =="
