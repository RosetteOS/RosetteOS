#!/bin/sh
# Main kernel + base rootfs build - touch, display, WiFi, Bluetooth, camera-
# kernel-side, and Core SoC infra (RNG/MMC/I2C/DMA) all come from this one
# pass, since they're all just kernel config + device-tree, nothing
# cross-compiled outside Buildroot's own package builds.
#
# IMPORTANT: never move/rename this checkout mid-build. A real bug this
# session (FIRMWARE.md sec 14): several of Buildroot's own host tools (e.g.
# glib-compile-schemas) get built with their RUNPATH hardcoded to whatever
# absolute path vendor/system/buildroot/ was actually AT the first time they were
# built - a later stage run against a relocated/renamed checkout will fail
# with "cannot open shared object file" even though nothing about the build
# itself changed. Pick a checkout location and never move it mid-build.
# (Phase 11 note, 2026-08-15: before the unified-build-environment
# migration this was framed as "always mount at /src inside the container" -
# same underlying constraint, just expressed as a container-mount-path
# requirement back when a container boundary existed here. The real
# constraint was always "one consistent absolute path for the life of one
# build," not the specific string `/src` - flattening away the container
# boundary means REPO_ROOT below now legitimately differs between a Phase
# 9-era build (container path) and this build (real host path), which is
# exactly the BUILD_PATH_EMBEDDING-class artifact difference the Phase 11
# comparison tooling expects and accounts for, not a regression.)
#
# IMPORTANT: this force-cleans and rebuilds the kernel from scratch when its
# effective inputs have changed
# (`make linux-dirclean` before `make`), rather than relying on plain `make`
# alone. A real, previously-silent bug this session (FIRMWARE.md sec 24):
# LINUX_OVERRIDE_SRCDIR points Buildroot at this project's own kernel
# checkout, but Buildroot's own .stamp_built/.stamp_rsynced files don't
# detect source changes there - a plain `make` after editing a DTS/Kconfig
# file will silently keep using the last-built kernel binary, reporting
# success while shipping stale, unpatched code. The dirclean costs a slower,
# tradeoff in favor of correctness. Identical inputs can reuse the previous
# successful kernel build - re-run 02-configure-buildroot.sh first if
# scripts/build/overlay/ or the config artifacts changed, since this script
# does not re-sync those itself.
#
# IMPORTANT: also handles wpa_supplicant specifically for the same reason,
# but only dircleans it when the package-input fingerprint changes
# (FIRMWARE.md sec 24/27):
# Buildroot does not automatically rebuild an already-built *package* just
# because its own Kconfig options (BR2_PACKAGE_WPA_SUPPLICANT_CTRL_IFACE/
# _CLI in this case) changed after it was first built - only source changes
# for override-srcdir packages get this same treatment, and even that needs
# an explicit dirclean as above. This bit us for real: wpa_supplicant was
# already built once with CTRL_IFACE/CLI disabled, the .config was fixed to
# enable them, and a later plain `make` silently kept shipping the old,
# disabled build - passing every check except `06-verify.sh`'s explicit
# `wpa_cli` presence check. If any other package's Kconfig options get
# changed after it's already been built once, the same `<pkg>-dirclean`
# treatment is needed - this project has hit this exact class of bug twice
# now, for two different packages, for the same underlying reason.
#
# IMPORTANT: also force-reinstalls gcc-final specifically, a third instance of
# the same underlying bug (found 2026-07-23, real-hardware testing): this
# project's base defconfig has always had BR2_INSTALL_LIBSTDCPP=y, but the
# very first build's gcc-final .stamp_target_installed predates whatever
# point that became load-bearing (greenlet, Klipper's own C extension
# dependency, needs libstdc++.so.6 at runtime) - every build since silently
# kept reusing that stamp, so gcc-final's own INSTALL_TARGET_CMDS (the step
# that actually copies libstdc++.so* into the rootfs) never ran again, even
# though libstdc++ was genuinely compiled and sitting in the toolchain's own
# sysroot the whole time. Symptom: Klipper (and anything else linking a C++
# extension) fails ImportError: libstdc++.so.6: cannot open shared object
# file, with no log line at all (dies before its own log file opens).
# `gcc-final-reinstall` re-runs just the install steps (cheap - the compiler
# itself doesn't need rebuilding), unlike `gcc-final-dirclean` which would
# force a full toolchain rebuild for no reason.
#
# Phase 11 (2026-08-15): flattened out of pellcorp/k1-bash-build - see
# 02-configure-buildroot.sh's own Phase 11 note for why (one unified
# container now, no per-stage container boundary, no per-stage apt-get).
set -e
export FORCE_UNSAFE_CONFIGURE=1

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

DEPS_MANIFEST="$REPO_ROOT/manifests/dependencies.conf"
[ -f "$DEPS_MANIFEST" ] || { echo "FATAL: $DEPS_MANIFEST not found" >&2; exit 1; }
. "$DEPS_MANIFEST"

# 2026-07-23: see 02-configure-buildroot.sh for why this lock exists.
exec 9>"$REPO_ROOT/.rosetteos-build.lock"
flock -n 9 || { echo "another build stage already owns $REPO_ROOT/.rosetteos-build.lock" >&2; exit 1; }

BUILDROOT_DIR="$REPO_ROOT/vendor/system/buildroot"
KERNEL_MOUNT="$REPO_ROOT/vendor/system/kernel/kernel-6.6"
KERNEL_FINGERPRINT_FILE="$BUILDROOT_DIR/output/.rosetteos-kernel-fingerprint"
OPENSSL_FINGERPRINT_FILE="$BUILDROOT_DIR/output/.rosetteos-libopenssl-fingerprint"
BUSYBOX_FINGERPRINT_FILE="$BUILDROOT_DIR/output/.rosetteos-busybox-fingerprint"
WPA_SUPPLICANT_FINGERPRINT_FILE="$BUILDROOT_DIR/output/.rosetteos-wpa-supplicant-fingerprint"
SWUPDATE_FINGERPRINT_FILE="$BUILDROOT_DIR/output/.rosetteos-swupdate-fingerprint"

if [ ! -f "$BUILDROOT_DIR/.config" ]; then
	echo "buildroot not configured - run 02-configure-buildroot.sh first" >&2
	exit 1
fi
for kernel_input in \
	"$BUILDROOT_DIR/board/halley5-rosetteos-fragment.config" \
	"$BUILDROOT_DIR/board/halley5-rosetteos-busybox-fragment.config" \
	"$BUILDROOT_DIR/local.mk"; do
	[ -f "$kernel_input" ] || {
		echo "kernel input missing: $kernel_input - run 02-configure-buildroot.sh first" >&2
		exit 1
	}
done

openssl_input_fingerprint() {
	{
		printf 'package=libopenssl\n'
		printf 'system_pin=%s\n' "$SYSTEM_PIN"
		sha256sum "$BUILDROOT_DIR/.config"
	} | sha256sum | awk '{print $1}'
}
busybox_input_fingerprint() {
	{
		printf 'package=busybox\n'
		printf 'system_pin=%s\n' "$SYSTEM_PIN"
		sha256sum \
			"$BUILDROOT_DIR/.config" \
			"$BUILDROOT_DIR/board/halley5-rosetteos-busybox-fragment.config"
	} | sha256sum | awk '{print $1}'
}
wpa_supplicant_input_fingerprint() {
	{
		printf 'package=wpa_supplicant\n'
		printf 'system_pin=%s\n' "$SYSTEM_PIN"
		sha256sum "$BUILDROOT_DIR/.config"
	} | sha256sum | awk '{print $1}'
}
swupdate_input_fingerprint() {
	{
		printf 'package=swupdate\n'
		printf 'system_pin=%s\n' "$SYSTEM_PIN"
		sha256sum \
			"$BUILDROOT_DIR/package/swupdate/swupdate.config"
	} | sha256sum | awk '{print $1}'
}

OPENSSL_INPUT_FINGERPRINT=$(openssl_input_fingerprint)
BUSYBOX_INPUT_FINGERPRINT=$(busybox_input_fingerprint)
WPA_SUPPLICANT_INPUT_FINGERPRINT=$(wpa_supplicant_input_fingerprint)
SWUPDATE_INPUT_FINGERPRINT=$(swupdate_input_fingerprint)
WPA_SUPPLICANT_REBUILD_REQUIRED=1
if [ -f "$WPA_SUPPLICANT_FINGERPRINT_FILE" ] && \
	[ "$(cat "$WPA_SUPPLICANT_FINGERPRINT_FILE")" = "$WPA_SUPPLICANT_INPUT_FINGERPRINT" ]; then
	WPA_SUPPLICANT_REBUILD_REQUIRED=0
fi
if [ "$WPA_SUPPLICANT_REBUILD_REQUIRED" -eq 0 ]; then
	echo "== wpa_supplicant inputs unchanged ($WPA_SUPPLICANT_INPUT_FINGERPRINT); reusing package build =="
else
	echo "== wpa_supplicant inputs changed or no successful fingerprint; refreshing package =="
fi

# Compute this before touching the kernel's generated files. The System pin
# is included explicitly, while the content-addressed diff captures the
# accepted variant changes applied on top of that pin.
kernel_input_fingerprint() {
	{
		printf 'system_pin=%s\n' "$SYSTEM_PIN"
		printf 'system_head='
		git -C "$REPO_ROOT/vendor/system" rev-parse HEAD
		printf 'kernel_diff\n'
		git -C "$REPO_ROOT/vendor/system" diff --binary --no-ext-diff HEAD -- kernel/kernel-6.6
		printf 'kernel_status\n'
		git -C "$REPO_ROOT/vendor/system" status --porcelain=v2 -uall -- kernel/kernel-6.6
		sha256sum \
			"$BUILDROOT_DIR/.config" \
			"$BUILDROOT_DIR/board/halley5-rosetteos-fragment.config" \
			"$BUILDROOT_DIR/local.mk"
	} | sha256sum | awk '{print $1}'
}

KERNEL_INPUT_FINGERPRINT=$(kernel_input_fingerprint)
KERNEL_REBUILD_REQUIRED=1
if [ -f "$KERNEL_FINGERPRINT_FILE" ] && \
	[ -f "$BUILDROOT_DIR/output/build/linux-custom/.stamp_built" ] && \
	[ "$(cat "$KERNEL_FINGERPRINT_FILE")" = "$KERNEL_INPUT_FINGERPRINT" ]; then
	KERNEL_REBUILD_REQUIRED=0
	echo "== kernel inputs unchanged ($KERNEL_INPUT_FINGERPRINT); reusing successful kernel build =="
else
	echo "== kernel inputs changed or no successful fingerprint; forcing kernel rebuild =="
fi

# Stale-config purge (2026-07-31, per the NEBULAOS_CAMERA_USB_RT_SOURCE
# _ANALYSIS.md vendor-pin audit): a real, previously-undetected gotcha was
# found on this exact checkout - vendor/system/kernel/kernel-6.6/
# .config and .config.old, dated well before a real Kconfig fragment fix
# (the BCMDHD-disable change), sitting stale in the mounted kernel source
# tree. Whether `make linux-dirclean` below reliably wipes an
# override-srcdir kernel's own in-tree .config/.config.old/include/config on
# every host/Buildroot version combination is not something this project
# trusts blindly (this file's own header already documents three separate,
# real instances of Buildroot's stamp/config invalidation not doing what
# you'd assume) - so wipe them explicitly before a fingerprint-mismatched
# rebuild. This guarantees the kernel source tree never
# carries forward a stale Kconfig resolution from a previous, possibly-
# different build.
if [ "$KERNEL_REBUILD_REQUIRED" -eq 1 ]; then
	rm -f "$KERNEL_MOUNT/.config" "$KERNEL_MOUNT/.config.old"
	rm -rf "$KERNEL_MOUNT/include/config" "$KERNEL_MOUNT/include/generated"
fi

(
	cd "$BUILDROOT_DIR"
	if [ "$KERNEL_REBUILD_REQUIRED" -eq 1 ]; then
		make BR2_TAR_OPTIONS=--no-same-owner linux-dirclean
	fi
	if [ "$WPA_SUPPLICANT_REBUILD_REQUIRED" -eq 1 ]; then
		make BR2_TAR_OPTIONS=--no-same-owner wpa_supplicant-dirclean
	fi
	# Same staleness class as the two dircleans above (FIRMWARE.md sec 28): a
	# plain incremental make only rebuilds a package whose stamp is missing
	# or whose config hash changed, and toggling a Kconfig option alone does
	# not invalidate an already-built package stamp. Hit this for real
	# chasing a matplotlib build failure - host-python3 kept silently
	# reusing its original SSL-less build across multiple
	# BR2_PACKAGE_HOST_PYTHON3_SSL config-flip rebuilds, so pip inside it
	# could never actually reach the network no matter what else changed.
	# Fixed with one `make host-python3-dirclean` (not kept here
	# permanently - a real, one-time transition, not an ongoing one like the
	# two dircleans above; host-python3 does not need forcing on every build
	# once it is correctly built once). If the host-python3
	# BR2_PACKAGE_HOST_PYTHON3_* options change again later, this needs a
	# manual `make host-python3-dirclean` before the next build, same as any
	# other already-built package whose Kconfig options changed.
	make BR2_TAR_OPTIONS=--no-same-owner gcc-final-reinstall
	make BR2_TAR_OPTIONS=--no-same-owner
)

mkdir -p "$(dirname "$KERNEL_FINGERPRINT_FILE")"
printf '%s\n' "$KERNEL_INPUT_FINGERPRINT" > "$KERNEL_FINGERPRINT_FILE"
printf '%s\n' "$OPENSSL_INPUT_FINGERPRINT" > "$OPENSSL_FINGERPRINT_FILE"
printf '%s\n' "$BUSYBOX_INPUT_FINGERPRINT" > "$BUSYBOX_FINGERPRINT_FILE"
printf '%s\n' "$WPA_SUPPLICANT_INPUT_FINGERPRINT" > "$WPA_SUPPLICANT_FINGERPRINT_FILE"
printf '%s\n' "$SWUPDATE_INPUT_FINGERPRINT" > "$SWUPDATE_FINGERPRINT_FILE"

echo "== kernel + base rootfs built: $BUILDROOT_DIR/output/images/{xImage,rootfs.squashfs} =="
