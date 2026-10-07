#!/bin/sh
# Applies the TOUCH-FINAL-QUALIFICATION genuinely-one-shot irq-assist
# driver (display/touch investigation mission follow-on, 2026-08-02+ - see
# scripts/build/patches/touch-final-qualification.patch) to the vendor
# kernel checkout, for a compile test only.
#
# This is a NEW, separate feature from the existing
# CONFIG_TOUCHSCREEN_NS2009_QUALIFICATION (touch-qualification-variant.sh /
# scripts/build/patches/touch-qualification-unified.patch) - that driver,
# its patch, its toggle script, and its tests are left completely
# untouched by this one. Informed by a real, live finding from that
# driver's own irq-observe mode (a plain FALLING-edge IRQ that only
# counts/handles events hit a real bounce storm: 492 raw IRQ events across
# only 56 touch/release cycles), TOUCH-FINAL-QUALIFICATION fixes the root
# cause with a genuinely one-shot design: a real hard-IRQ handler masks the
# line before anything else runs, and that mask stays in effect for the
# ENTIRE duration of a contact, not just until a threaded handler returns.
# See ns2009_final_qualification.c's own header comment for the full
# design.
#
# IMPORTANT - why this script does NOT do a blanket `git checkout --` of
# the affected files (unlike every earlier touch-*-variant.sh script,
# including touch-qualification-variant.sh): that pattern is exactly what
# caused this project's own, previously-real "overlapping touch variant
# scripts" bug - three separate scripts all targeting the identical two
# files (Kconfig/ns2009.c), where applying one and reverting a *different*
# one silently discarded the first one's patch too. This script instead
# applies/reverts its own content ONE AFFECTED FILE AT A TIME, via
# `git apply --include=<path>` / `git apply -R --include=<path>`, and
# checks each file's own actual current content (not just a cached
# assumption) before deciding whether to touch it - so it never blindly
# discards someone else's change to a file it shares, and it self-heals
# from a PARTIALLY-applied state instead of silently leaving one behind
# (see the next paragraph for exactly when that matters).
#
# IMPORTANT - a real, tested, ONE-DIRECTIONAL limitation this project
# cannot fully close, because fixing it would require editing
# touch-qualification-variant.sh, which is off limits: that script's own
# "off"/"on" step still does an unconditional blanket
# `git checkout -- $AFFECTED_FILES` of Kconfig and ns2009.c as ITS OWN
# first action. If touch-qualification-variant.sh (QUAL0 or QUAL1) is run
# AFTER this feature's content is already present in those same two files,
# its checkout step WILL silently discard this feature's Kconfig/ns2009.c
# content too - directly verified, not assumed (run
# `sh touch-qualification-variant.sh QUAL1` after `sh
# touch-final-qualification-variant.sh FINALQUAL1` and inspect
# ns2009.c: this feature's #ifdef blocks are gone, while
# ns2009_final_qualification.c and the Makefile lines - untouched by that
# other script - remain, which is exactly the "partially wiped" state this
# script's self-healing per-file logic (see above) is designed to recover
# from correctly on the next FINALQUAL0/FINALQUAL1 invocation, rather than
# getting stuck in an inconsistent half-applied state).
#
# The safe, tested order is: run touch-qualification-variant.sh (QUAL0 or
# QUAL1) FIRST if you need it at all for a given compile test, THEN run
# this script (FINALQUAL0 or FINALQUAL1) SECOND, every time. Directly
# verified (both directions of application, not just this one) to compose
# cleanly with `git apply --check` when done in that order:
#
#   QUAL1 then FINALQUAL1 (apply)                          -> clean
#   FINALQUAL1 then QUAL1 (apply, reverse order)            -> clean
#   revert both, in the order applied, back to a clean tree -> clean
#   revert FINALQUAL1 alone while QUAL1 stays applied        -> clean,
#       QUAL1's own content verified still intact afterward
#
# ...but re-running touch-qualification-variant.sh a SECOND time (e.g. to
# flip QUAL1 -> QUAL0 -> QUAL1 again) after this script has already run
# will still wipe this feature's Kconfig/ns2009.c content each time,
# because that is simply what that script's own, unmodifiable "off" step
# does to those two files regardless of what else is currently in them.
# This is the mirror image of the original overlapping-scripts bug, not a
# new instance of it: nothing here silently corrupts state or fails
# quietly - re-running this script (FINALQUAL1) afterward always restores
# a fully clean, fully-applied state again, and
# tests/touch-final-qualification-variant-tests.sh directly exercises and
# asserts this exact recovery.
#
#   FINALQUAL0 (default/today): baseline ns2009.c/Kconfig/Makefile, no
#       final-qualification feature, no ns2009_final_qualification.c.
#   FINALQUAL1 (prototype): applies
#       scripts/build/patches/touch-final-qualification.patch (new
#       ns2009_final_qualification.c file + a tiny, isolated footprint in
#       ns2009.c/Kconfig/Makefile, all guarded by #ifdef
#       CONFIG_TOUCHSCREEN_NS2009_FINAL_QUALIFICATION so the compiled code
#       is byte-for-byte identical to FINALQUAL0 unless the option is also
#       selected in the Kconfig fragment - which THIS script does as its
#       second step), and selects
#       CONFIG_TOUCHSCREEN_NS2009_FINAL_QUALIFICATION=y in the tracked
#       Kconfig fragment.
#
#       The feature always boots into poll-only mode (byte-for-byte
#       identical to the original, unmodified 30ms poll path - no GPIO IRQ
#       requested under any circumstance). irq-assist is selectable via
#       /sys/kernel/debug/ns2009_final_qualification/mode - see the
#       patch/Kconfig help text for the full design and fail-safe behavior.
#
# IMPORTANT: never run this script while any build against this same
# vendor kernel checkout is in flight - see the equivalent warning in the
# other touch-*-variant.sh scripts.
#
# Usage: sh scripts/build/touch-final-qualification-variant.sh <FINALQUAL0|FINALQUAL1>

set -eu

VARIANT="${1:?usage: $0 <FINALQUAL0|FINALQUAL1>}"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
SYSTEM_DIR="$REPO_ROOT/vendor/system"
PATCH="$SCRIPT_DIR/patches/touch-final-qualification.patch"
FRAGMENT="$REPO_ROOT/artifacts/buildroot-halley5-v30-image/halley5-rosetteos-fragment.config"
MARKER="$REPO_ROOT/build-work/touch-final-qualification-variant-applied.txt"

KCONFIG_REL="kernel/kernel-6.6/drivers/input/touchscreen/Kconfig"
MAKEFILE_REL="kernel/kernel-6.6/drivers/input/touchscreen/Makefile"
NS2009_REL="kernel/kernel-6.6/drivers/input/touchscreen/ns2009.c"
NEWFILE_REL="kernel/kernel-6.6/drivers/input/touchscreen/ns2009_final_qualification.c"

BEGIN_MARK="#--- ROSETTEOS_TOUCH_FINAL_QUALIFICATION_VARIANT_BEGIN ---"
END_MARK="#--- ROSETTEOS_TOUCH_FINAL_QUALIFICATION_VARIANT_END ---"

# A stable, unique marker string this patch alone ever adds to each shared
# file - used to detect the file's ACTUAL current content (never assumed
# from any prior run's own success/failure) before deciding whether to
# apply or revert this patch's hunk for that one file. This is what makes
# each file's handling self-healing across an external tool (i.e.
# touch-qualification-variant.sh - see the header comment above) silently
# discarding just some of this patch's files.
KCONFIG_MARKER="config TOUCHSCREEN_NS2009_FINAL_QUALIFICATION"
NS2009_MARKER="CONFIG_TOUCHSCREEN_NS2009_FINAL_QUALIFICATION"
MAKEFILE_MARKER="ns2009-\$(CONFIG_TOUCHSCREEN_NS2009_FINAL_QUALIFICATION)"

case "$VARIANT" in
	FINALQUAL0|FINALQUAL1) ;;
	*)
		echo "unknown variant '$VARIANT' - must be one of FINALQUAL0 FINALQUAL1" >&2
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

apply_file_hunk() {
	rel="$1"
	git -C "$SYSTEM_DIR" apply --include="$rel" "$PATCH"
}

revert_file_hunk() {
	rel="$1"
	git -C "$SYSTEM_DIR" apply -R --include="$rel" "$PATCH"
}

if [ "$VARIANT" = "FINALQUAL0" ]; then
	# New file: purely ours, always safe to just remove outright.
	rm -f "$SYSTEM_DIR/$NEWFILE_REL"

	# Makefile: never touched by any other touch-*-variant.sh script -
	# still handled marker-first (not a blanket checkout) for the same
	# self-healing consistency as the two shared files below.
	if grep -qF "$MAKEFILE_MARKER" "$SYSTEM_DIR/$MAKEFILE_REL" 2>/dev/null; then
		revert_file_hunk "$MAKEFILE_REL"
	fi

	# Kconfig/ns2009.c: shared with touch-qualification-variant.sh. Only
	# revert if THIS patch's own marker is actually present right now -
	# never assume based on what a previous invocation of this script did.
	if grep -qF "$KCONFIG_MARKER" "$SYSTEM_DIR/$KCONFIG_REL" 2>/dev/null; then
		revert_file_hunk "$KCONFIG_REL"
	fi
	if grep -qF "$NS2009_MARKER" "$SYSTEM_DIR/$NS2009_REL" 2>/dev/null; then
		revert_file_hunk "$NS2009_REL"
	fi

	if grep -qF "$BEGIN_MARK" "$FRAGMENT"; then
		sed -i "/^${BEGIN_MARK}\$/,/^${END_MARK}\$/d" "$FRAGMENT"
	fi
else
	if ! grep -qF "$KCONFIG_MARKER" "$SYSTEM_DIR/$KCONFIG_REL" 2>/dev/null; then
		apply_file_hunk "$KCONFIG_REL"
	fi
	if ! grep -qF "$NS2009_MARKER" "$SYSTEM_DIR/$NS2009_REL" 2>/dev/null; then
		apply_file_hunk "$NS2009_REL"
	fi
	if ! grep -qF "$MAKEFILE_MARKER" "$SYSTEM_DIR/$MAKEFILE_REL" 2>/dev/null; then
		apply_file_hunk "$MAKEFILE_REL"
	fi
	if [ ! -f "$SYSTEM_DIR/$NEWFILE_REL" ]; then
		apply_file_hunk "$NEWFILE_REL"
	fi

	if grep -qF "$BEGIN_MARK" "$FRAGMENT"; then
		sed -i "/^${BEGIN_MARK}\$/,/^${END_MARK}\$/d" "$FRAGMENT"
	fi
	{
		echo "$BEGIN_MARK"
		echo "# Display/touch investigation mission follow-on (2026-08-02+) -"
		echo "# TOUCH-FINAL-QUALIFICATION genuinely-one-shot irq-assist variant."
		echo "CONFIG_TOUCHSCREEN_NS2009_FINAL_QUALIFICATION=y"
		echo "$END_MARK"
	} >> "$FRAGMENT"
fi

mkdir -p "$(dirname "$MARKER")"
printf '%s\n' "$VARIANT" > "$MARKER"
echo "== touch-final-qualification-variant: $VARIANT applied =="
