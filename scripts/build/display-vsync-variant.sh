#!/bin/sh
# Applies the DISPLAY-V1 compile-only vsync-gated pan_display prototype
# (powered-on display investigation mission, 2026-08-01 - see
# docs/NEBULAOS_DISPLAY_OS_HARDWARE_ANALYSIS.md §4 for the real,
# source-acknowledged tearing race this closes: dpu_ctrl_rdma_change(), the
# function FBIOPAN_DISPLAY calls to switch the active scanout frame, never
# waits for the in-flight frame's scan-out to complete before writing the
# new frame's address).
#
#   V0 (default/today): baseline fb_stage driver, unmodified pan_display
#       behavior - dpu_ctrl_rdma_change() is called immediately with no
#       wait.
#   V1 (prototype): applies scripts/build/patches/display-vsync-gate.patch
#       to the vendor kernel checkout (Kconfig option + struct fields +
#       ingenicfb_pan_display()/ingenicfb_set_vsync_value() changes, all
#       guarded by #ifdef CONFIG_FB_INGENIC_PAN_VSYNC_GATE so the compiled
#       code is byte-for-byte identical to V0 unless the option is also
#       selected in the Kconfig fragment - which THIS script does as its
#       second step), and selects CONFIG_FB_INGENIC_PAN_VSYNC_GATE=y in the
#       tracked Kconfig fragment.
#
#       ingenicfb_pan_display() then waits (bounded, ~34ms, ~2 frame
#       periods at this panel's ~59.98Hz) for the next real vsync event
#       before applying the frame switch, reusing the existing vsync IRQ/
#       waitqueue infrastructure that already drives FBIO_WAITFORVSYNC -
#       not a new interrupt or a new hardware wait primitive. On timeout
#       (or if the DPU is currently blanked/suspended) it falls back to
#       applying the switch immediately, exactly like V0 - display
#       functionality is never blocked indefinitely. Also adds an
#       independent, always-active bounds check on the pan_display target
#       frame index (a real, pre-existing gap: next_frm was never
#       validated against CONFIG_FB_INGENIC_NR_FRAMES before use, despite
#       being derived directly from userspace-supplied var->yoffset).
#
# Same "always reset to the real git-committed baseline first" pattern as
# wifi-sdio-variant.sh/display-backlight-variant.sh - `git checkout --` on
# every affected file before deciding what V0/V1 needs, so repeated
# switches never drift or accumulate partial edits.
#
# IMPORTANT: never run this script while any build against this same vendor
# kernel checkout is in flight - a build's own source-tree fingerprint
# check (05-final-build.sh) will correctly (and rightly) refuse to trust
# artifacts built from a tree that changed mid-build. Apply the desired
# variant BEFORE starting a build, not during one.
#
# Usage: sh scripts/build/display-vsync-variant.sh <V0|V1>

set -eu

VARIANT="${1:?usage: $0 <V0|V1>}"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
SYSTEM_DIR="$REPO_ROOT/vendor/system"
PATCH="$SCRIPT_DIR/patches/display-vsync-gate.patch"
FRAGMENT="$REPO_ROOT/artifacts/buildroot-halley5-v30-image/halley5-rosetteos-fragment.config"
MARKER="$REPO_ROOT/build-work/display-vsync-variant-applied.txt"

AFFECTED_FILES="
kernel/kernel-6.6/module_drivers/drivers/video/fbdev/ingenic/fb_stage/Kconfig
kernel/kernel-6.6/module_drivers/drivers/video/fbdev/ingenic/fb_stage/ingenicfb.c
kernel/kernel-6.6/module_drivers/drivers/video/fbdev/ingenic/include/ingenicfb.h
"

BEGIN_MARK="#--- ROSETTEOS_PAN_VSYNC_GATE_VARIANT_BEGIN ---"
END_MARK="#--- ROSETTEOS_PAN_VSYNC_GATE_VARIANT_END ---"

case "$VARIANT" in
	V0|V1) ;;
	*)
		echo "unknown variant '$VARIANT' - must be one of V0 V1" >&2
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

# Always reset the affected kernel files to their real, git-committed
# baseline first - never trust that a previous invocation was cleanly
# undone. Only touches the 3 files this patch actually affects, not the
# whole kernel tree (unlike wifi-sdio-variant.sh/display-backlight-variant.sh,
# which each only ever touch one shared DTS - here we scope narrowly since
# other in-flight variant selections, e.g. wifi-sdio-variant.sh's own DTS
# edits, may legitimately coexist and must not be discarded by this script).
git -C "$SYSTEM_DIR" checkout -- $AFFECTED_FILES

# Strip any previously-applied fragment block first, unconditionally -
# same idempotent pattern as sibling variant scripts. Marker text here has no
# BRE-special characters (no "/*"/"*/"), so a direct address is safe as-is
# (see the display-backlight-variant.sh history for why that would NOT be
# safe if the markers contained C-comment syntax).
if grep -qF "$BEGIN_MARK" "$FRAGMENT"; then
	sed -i "/^${BEGIN_MARK}\$/,/^${END_MARK}\$/d" "$FRAGMENT"
fi

if [ "$VARIANT" = "V1" ]; then
	( cd "$SYSTEM_DIR" && git apply "$PATCH" )
	{
		echo "$BEGIN_MARK"
		echo "# Display investigation mission (2026-08-01) - DISPLAY-V1"
		echo "# vsync-gated pan_display qualification variant."
		echo "CONFIG_FB_INGENIC_PAN_VSYNC_GATE=y"
		echo "$END_MARK"
	} >> "$FRAGMENT"
fi

mkdir -p "$(dirname "$MARKER")"
printf '%s\n' "$VARIANT" > "$MARKER"
echo "== display-vsync-variant: $VARIANT applied =="
