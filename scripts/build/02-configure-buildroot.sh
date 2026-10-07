#!/bin/sh
# Wire up Buildroot's configuration: the real, already-verified .config this
# project produced (artifacts/buildroot-halley5-v30-image/buildroot.config),
# the kernel config fragment (FIRMWARE.md sec 10-12's additions on top of
# the vendor x2000_halley5_v30_linux defconfig), the LINUX_OVERRIDE_SRCDIR
# pointer, and this repo's own hand-written overlay content.
#
# Reusing the exact verified .config here (rather than re-deriving every
# BR2_PACKAGE_* option from scratch) is deliberate: several of those options
# hit a real class of bug this session where a naive `echo "X=y" >> .config`
# landed on a duplicate line that a later `make olddefconfig` pass then lost
# to the file's *other*, unedited copy of the same symbol (see FIRMWARE.md
# sec 14) - copying the known-good, already-normalized file sidesteps that
# whole class of mistake rather than risking reintroducing it.
#
# IMPORTANT: always re-run this script after ANY change to scripts/build/overlay/
# or the kernel fragment/buildroot.config artifacts, and before 03/05 - a real
# bug this session (FIRMWARE.md sec 24): editing the git-tracked overlay
# template alone does nothing, since Buildroot only ever reads from
# vendor/system/buildroot/board/halley5-rosetteos-overlay/ (gitignored), which
# this script is what syncs the template into. A rebuild after only touching
# the template, without re-running this first, silently uses whatever this
# script last copied there.
#
# IMPORTANT: renaming or deleting a file from scripts/build/overlay/ does NOT
# remove it from a real build - a genuinely separate bug from the one above,
# found for real deleting S01tmpfs-datastore in favor of
# S01persistent-datastore (the GuppyScreen persistent-storage work): this
# script re-syncs the overlay TEMPLATE cleanly every time (the rm -rf above),
# but Buildroot's own output/target/ staging directory only ever gets files
# ADDED or OVERWRITTEN by the rootfs-overlay step, never removed, and
# accumulates across every build since the last full clean. Both
# S01tmpfs-datastore (deleted from the overlay days earlier) and
# S01persistent-datastore (its replacement) ended up in the same built image
# at once - actively dangerous here specifically, since the stale script
# re-mounted tmpfs right after the new one finished setting up real
# persistent storage, silently undoing it. Buildroot has no cheap way to
# selectively re-sync output/target/ (its package install stamps live
# elsewhere and do not get invalidated by removing target files directly, so
# deleting output/target/ alone leaves it mostly empty instead of clean) - a
# renamed or deleted overlay file must also be removed by hand from
# vendor/system/buildroot/output/target/ before the next 05-final-build.sh, or
# the build needs a full clean. 06-verify.sh inspects the actual
# packaged rootfs.squashfs directly (via unsquashfs) to confirm a removed
# file is genuinely gone.
#
# Phase 11 (2026-08-15, unified-build-environment migration): this script
# used to wrap every step in `docker run pellcorp/k1-bash-build ...`,
# crossing a container boundary that meant paths differed between the host
# view (/repo/vendor/...) and the container's own view (/repo/... mounted
# from the host root). Now that the whole 00-06 pipeline already runs
# inside ONE unified nebulaos-build container (or directly on a host that
# has build-env/'s tools installed), there is no second boundary to cross -
# every path below is just the real filesystem path, and the root/non-root
# chown dance that used to follow every docker --user root call is gone
# because there's no longer a second UID entering the picture. The
# per-container `--label rosetteos-build-pid=$$` / orphan-container-cleanup
# logic is gone for the same reason: nothing here spawns a container of its
# own to leak.
set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

DEPS_MANIFEST="$REPO_ROOT/manifests/dependencies.conf"
[ -f "$DEPS_MANIFEST" ] || { echo "FATAL: $DEPS_MANIFEST not found" >&2; exit 1; }
. "$DEPS_MANIFEST"

# 2026-07-23: this and the other numbered build stages all write into the
# same shared vendor/system/buildroot tree - running two of these at once
# (e.g. from two terminals) would silently interleave writes. Cheap
# insurance: a single exclusive lock file, held for the whole script.
exec 9>"$REPO_ROOT/.rosetteos-build.lock"
flock -n 9 || { echo "another build stage already owns $REPO_ROOT/.rosetteos-build.lock" >&2; exit 1; }

BUILDROOT_DIR="$REPO_ROOT/vendor/system/buildroot"
ARTIFACTS="$REPO_ROOT/artifacts/buildroot-halley5-v30-image"
KERNEL_SRCDIR="$REPO_ROOT/vendor/system/kernel/kernel-6.6"
OPENSSL_FINGERPRINT_FILE="$BUILDROOT_DIR/output/.rosetteos-libopenssl-fingerprint"
BUSYBOX_FINGERPRINT_FILE="$BUILDROOT_DIR/output/.rosetteos-busybox-fingerprint"
SWUPDATE_FINGERPRINT_FILE="$BUILDROOT_DIR/output/.rosetteos-swupdate-fingerprint"

if [ ! -f "$BUILDROOT_DIR/Makefile" ]; then
	echo "vendor/system/buildroot not found - run 00-fetch-vendor-sources.sh first" >&2
	exit 1
fi

cp "$ARTIFACTS/buildroot.config" "$BUILDROOT_DIR/.config"
mkdir -p "$BUILDROOT_DIR/board"
cp "$ARTIFACTS/halley5-rosetteos-fragment.config" "$BUILDROOT_DIR/board/halley5-rosetteos-fragment.config"
cp "$ARTIFACTS/halley5-rosetteos-busybox-fragment.config" "$BUILDROOT_DIR/board/halley5-rosetteos-busybox-fragment.config"
if [ -f "$REPO_ROOT/scripts/build/configs/swupdate.config" ]; then
	cp "$REPO_ROOT/scripts/build/configs/swupdate.config" "$BUILDROOT_DIR/package/swupdate/swupdate.config"
fi
# Phase 11 (2026-08-15): CONFIG_EXTRA_FIRMWARE_DIR in the tracked fragment
# is a literal "/src/board/halley5-rosetteos-overlay/lib/firmware" - valid
# only under the old nested pellcorp/k1-bash-build container, which always
# mounted this project at the fixed path /src regardless of the host
# checkout location. Now that the pipeline runs natively (real host paths
# throughout, no fixed mount point), that path doesn't exist and the kernel
# build fails outright once it reaches drivers/base/firmware_loader. Fixing
# up the *copy* here (not the tracked artifacts/ file, which stays as the
# real historical record of what the old container-based build actually
# used, and which assert-baseline-config.sh/baseline-difference-gate.sh
# diff verbatim against the accepted baseline tag) to point at where the
# overlay's firmware actually lands post-copy below: real host path, so it
# works from any checkout location.
sed -i "s#/src/board/halley5-rosetteos-overlay#$BUILDROOT_DIR/board/halley5-rosetteos-overlay#" \
	"$BUILDROOT_DIR/board/halley5-rosetteos-fragment.config"
cat > "$BUILDROOT_DIR/local.mk" <<EOF
LINUX_OVERRIDE_SRCDIR = $KERNEL_SRCDIR
EOF
rm -rf "$BUILDROOT_DIR/board/halley5-rosetteos-wheels"
rm -rf "$BUILDROOT_DIR/board/halley5-rosetteos-overlay"
mkdir -p "$BUILDROOT_DIR/board/halley5-rosetteos-overlay"
cp -r "$REPO_ROOT/scripts/build/overlay/." "$BUILDROOT_DIR/board/halley5-rosetteos-overlay/"
mkdir -p "$BUILDROOT_DIR/board/halley5-rosetteos-overlay/opt/printer_data/comms" \
         "$BUILDROOT_DIR/board/halley5-rosetteos-overlay/opt/printer_data/logs" \
         "$BUILDROOT_DIR/board/halley5-rosetteos-overlay/opt/printer_data/gcodes"
# Real bug found live on 2026-07-28: this rm -rf/cp only cleans the BOARD
# overlay staging dir (above), not output/target/ or
# output/build/buildroot-fs/ext2/target/ - per the IMPORTANT comment near
# the top of this file, those two are additive-only and keep every
# renamed-away overlay file forever unless a full clean is done. This has
# now bitten three separate renames (S01tmpfs-datastore ->
# S01persistent-datastore; S39wifi -> S01wifi; S03nebulaos-factory-seed/
# S04nebulaos-activate -> S04nebulaos-factory-seed/S05nebulaos-activate),
# and the last two shipped together on a real flashed device: BOTH old and
# new init.d scripts were present in the same booted squashfs, and because
# the new activate scripts bind_if_not_already() no-ops when its target
# is already mounted, the OLD (pre-fix, less-validated) activation script -
# which sorts earlier and ran first - was the one actually deciding every
# real bind-mount, silently shadowing the fix. Clean every historically
# renamed/removed overlay-relative path from both real output copies here;
# add to this list whenever an overlay file is renamed or deleted, the same
# way dcf7060 does for the seed archives in 04-cross-compile-app-stack.sh.
for obsolete_rel in \
	"etc/init.d/S01tmpfs-datastore" \
	"etc/init.d/S39wifi" \
	"etc/init.d/S03nebulaos-factory-seed" \
	"opt/printer_data/config/simpleaf" \
	"etc/init.d/S04nebulaos-activate" \
	"etc/init.d/S02nebulaos-boot-timing" \
	"etc/init.d/S02nebulaos-namespace" \
	"etc/init.d/S02nebulaos-wifi-irq-priority" \
	"etc/init.d/S03nebulaos-diskswap" \
	"etc/init.d/S04nebulaos-factory-seed" \
	"etc/init.d/S04nebulaos-migrate" \
	"etc/init.d/S05nebulaos-activate" \
	"etc/init.d/S40nebulaos-ntpsync" \
	"etc/init.d/S45nebulaos-cleanup" \
	"etc/init.d/S46nebulaos-dropbear-keys" \
	"etc/init.d/S51nebulaos-camera-idle-controller" \
	"etc/init.d/S54nebulaos-host-mcu" \
	"etc/init.d/S57nebulaos-camera-seed" \
	"etc/init.d/S57nebulaos-mcu-upgrade" \
	"etc/init.d/S59nebulaos-update-supervisor" \
	"etc/init.d/S97nebulaos-display-qualified-apply" \
	"etc/init.d/S98nebulaos-display-sleep-wake-controller" \
	"etc/nebulaos-camera-idle-controller.sh" \
	"etc/nebulaos-display-qualified.sh" \
	"etc/nebulaos-display-sleep-wake-controller.sh" \
	"etc/nebulaos-healthcheck.sh" \
	"etc/nebulaos-maintenance-gate.sh" \
	"etc/nebulaos-retention.sh" \
	"etc/nebulaos-stable-mac.sh" \
	"etc/nebulaos-update-supervisor.sh" \
	"etc/nebulaos-wifi-boot-wait.sh" \
	"etc/nebulaos-wifi-power-save.sh" \
	"etc/sysctl.d/99-nebulaos-resilience.conf" \
	"usr/libexec/nebulaos-display-qualified-write" \
	"usr/libexec/nebulaos-seed-camera" \
	"opt/printer_data/config/Macros" \
	"opt/printer_data/config/Nebula.cfg" \
	"opt/printer_data/config/RosetteOS_Settings.cfg" \
	"opt/printer_data/config/V3_Settings.cfg" \
	"opt/printer_data/config/camera-quality.cfg" \
	"opt/printer_data/config/frontend-controls.cfg" \
	"opt/printer_data/config/print_controls.cfg" \
	"usr/lib/swupdate/conf.d/10-mongoose-args" \
	"etc/swupdate/conf.d/10-mongoose-args" \
	"var/www/swupdate" \
	"opt/nebulaos" \
	"opt/nebulaos-seeds" \
	"opt/nebulaos-version.json"; do
	rm -rf "$BUILDROOT_DIR/output/target/$obsolete_rel" \
	      "$BUILDROOT_DIR/output/build/buildroot-fs/ext2/target/$obsolete_rel" 2>/dev/null || true
done
rm -rf "$BUILDROOT_DIR/output/target/opt/printer_data" \
      "$BUILDROOT_DIR/output/build/buildroot-fs/ext2/target/opt/printer_data" 2>/dev/null || true
mkdir -p "$BUILDROOT_DIR/output/target/opt/printer_data"
cp -a "$REPO_ROOT/scripts/build/overlay/opt/printer_data/." "$BUILDROOT_DIR/output/target/opt/printer_data/"

echo "== normalizing .config (resolves any derived Kconfig selects) =="
# The checkout may be mounted on a filesystem (for example a Windows/WSL
# bind mount) that cannot represent the numeric owners stored in some source
# archives.  Keep extraction portable by making Buildroot's tar invocations
# If conf was compiled on a host with newer libc than the container, wipe it so make rebuilds it
if [ -f "$BUILDROOT_DIR/output/build/buildroot-config/conf" ]; then
	if ! "$BUILDROOT_DIR/output/build/buildroot-config/conf" -h >/dev/null 2>&1; then
		rm -rf "$BUILDROOT_DIR/output/build/buildroot-config"
	fi
fi
( cd "$BUILDROOT_DIR" && make BR2_TAR_OPTIONS=--no-same-owner olddefconfig )

# Buildroot does not invalidate package stamps when a package suboption or
# BusyBox fragment changes. Track those effective inputs and only dirclean
# the affected packages when they differ from the last successful Stage 03
# build. The marker is deliberately written by Stage 03, not here, so a
# failed build cannot certify a package state as reusable.
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
SWUPDATE_INPUT_FINGERPRINT=$(swupdate_input_fingerprint)
OPENSSL_REBUILD_REQUIRED=1
BUSYBOX_REBUILD_REQUIRED=1
SWUPDATE_REBUILD_REQUIRED=1
if [ -f "$OPENSSL_FINGERPRINT_FILE" ] && \
	[ "$(cat "$OPENSSL_FINGERPRINT_FILE")" = "$OPENSSL_INPUT_FINGERPRINT" ]; then
	OPENSSL_REBUILD_REQUIRED=0
fi
if [ -f "$BUSYBOX_FINGERPRINT_FILE" ] && \
	[ "$(cat "$BUSYBOX_FINGERPRINT_FILE")" = "$BUSYBOX_INPUT_FINGERPRINT" ]; then
	BUSYBOX_REBUILD_REQUIRED=0
fi
if [ -f "$SWUPDATE_FINGERPRINT_FILE" ] && \
	[ "$(cat "$SWUPDATE_FINGERPRINT_FILE")" = "$SWUPDATE_INPUT_FINGERPRINT" ]; then
	SWUPDATE_REBUILD_REQUIRED=0
fi
if [ "$OPENSSL_REBUILD_REQUIRED" -eq 0 ]; then
	echo "== OpenSSL inputs unchanged ($OPENSSL_INPUT_FINGERPRINT); reusing package build =="
else
	echo "== OpenSSL inputs changed or no successful fingerprint; refreshing package =="
fi
if [ "$BUSYBOX_REBUILD_REQUIRED" -eq 0 ]; then
	echo "== BusyBox inputs unchanged ($BUSYBOX_INPUT_FINGERPRINT); reusing package build =="
else
	echo "== BusyBox inputs changed or no successful fingerprint; refreshing package =="
fi
if [ "$SWUPDATE_REBUILD_REQUIRED" -eq 0 ]; then
	echo "== SWUpdate inputs unchanged ($SWUPDATE_INPUT_FINGERPRINT); reusing package build =="
else
	echo "== SWUpdate inputs changed or no successful fingerprint; refreshing package =="
fi

(
	cd "$BUILDROOT_DIR"
	if [ "$OPENSSL_REBUILD_REQUIRED" -eq 1 ]; then
		make libopenssl-dirclean 2>/dev/null || true
	fi
	if [ "$BUSYBOX_REBUILD_REQUIRED" -eq 1 ]; then
		make busybox-dirclean 2>/dev/null || true
	fi
	if [ "$SWUPDATE_REBUILD_REQUIRED" -eq 1 ]; then
		make swupdate-dirclean 2>/dev/null || true
	fi
)

echo "== buildroot configured =="
