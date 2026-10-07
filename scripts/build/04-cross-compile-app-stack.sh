#!/bin/sh
# Cross-compile the handful of things that need the Buildroot-built
# toolchain directly (Klipper's chelper C extension, Moonraker's
# streaming-form-data C extension, ustreamer itself), download the
# pure-Python wheels with no Buildroot package, and assemble the full
# app-stack overlay - Klipper/Moonraker source, Mainsail's static build,
# and everything above - on top of the hand-written files stage 2 already
# put in place. The mainline Klipper checkout receives the pinned NebulaOS
# extras below before the wholesale klippy/ copy stages it into the rootfs.
#
# Must run after 03-build-kernel-and-rootfs.sh - needs the Buildroot
# toolchain and target Python headers to already be built.
set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

# ROSETTEOS_VERSION/GUPPYSCREEN_THEME (section 6, below) come
# from the same authoritative dependency manifest 00-fetch-vendor-sources.sh
# already sources - see that script/manifests/dependencies.conf's own
# header for why dependency settings live in one file instead of being hardcoded per-script.
MANIFEST="$REPO_ROOT/manifests/dependencies.conf"
[ -f "$MANIFEST" ] || {
	echo "FATAL: $MANIFEST not found - this is the one authoritative dependency pin file, required to build at all" >&2
	exit 1
}
. "$MANIFEST"

klipper_build_head=$(git -C "$REPO_ROOT/vendor/klipper" rev-parse HEAD 2>/dev/null || echo missing)
[ "$klipper_build_head" = "$KLIPPER_PIN" ] || {
	echo "FATAL: vendor/klipper is $klipper_build_head, expected mainline compatibility pin $KLIPPER_PIN" >&2
	echo "Run scripts/build/00-fetch-vendor-sources.sh before continuing; refusing to package an incompatible Klipper image." >&2
	exit 1
}

# 2026-07-23: see 02-configure-buildroot.sh for why this lock exists.
exec 9>"$REPO_ROOT/.rosetteos-build.lock"
flock -n 9 || { echo "another build stage already owns $REPO_ROOT/.rosetteos-build.lock" >&2; exit 1; }

# Phase 11 (2026-08-15): the orphaned-container-cleanup loop and per-call
# `--label rosetteos-build-pid=$$` that used to live here are gone - nothing in
# this script spawns a nested container of its own any more to leak (see
# 02-configure-buildroot.sh's own Phase 11 note for the full rationale).
VENDOR="$REPO_ROOT/vendor"
BUILDROOT_DIR="$VENDOR/system/buildroot"
OVERLAY="$BUILDROOT_DIR/board/halley5-rosetteos-overlay"
TOOLCHAIN_HOST="$BUILDROOT_DIR/output/host"
SYSROOT="$TOOLCHAIN_HOST/mipsel-buildroot-linux-gnu/sysroot"
WORK="$REPO_ROOT/build-work/app-stack-extras"
CHELPER_CACHE="$WORK/chelper"
CHELPER_FINGERPRINT_FILE="$CHELPER_CACHE/fingerprint"
STREAMING_CACHE="$WORK/streaming-form-data"
STREAMING_FINGERPRINT_FILE="$STREAMING_CACHE/fingerprint"
VENV_SEED_CACHE="$WORK/venv-seeds"
PYWHEELS_DIR="$WORK/pywheels"
PYWHEELS_FINGERPRINT_FILE="$PYWHEELS_DIR/fingerprint"
BYTECODE_CACHE="$WORK/bytecode"
BYTECODE_FORMAT_VERSION=1

# Buildroot's output/target sync is additive. Remove only the generated
# Klipper paths before restaging so an older full .git tree or runtime copy
# cannot survive a rebuild and override the current compatibility-qualified
# source. The tracked overlay remains untouched.
rm -rf "$OVERLAY/opt/klipper" \
	"$OVERLAY/opt/klipper-extensions" \
	"$BUILDROOT_DIR/output/target/opt/klipper" \
	"$BUILDROOT_DIR/output/target/opt/klipper-extensions" \
	"$BUILDROOT_DIR/output/build/buildroot-fs/ext2/target/opt/klipper" \
	"$BUILDROOT_DIR/output/build/buildroot-fs/ext2/target/opt/klipper-extensions"

if [ ! -x "$TOOLCHAIN_HOST/bin/mipsel-buildroot-linux-gnu-gcc" ]; then
	echo "Buildroot toolchain not built - run 03-build-kernel-and-rootfs.sh first" >&2
	exit 1
fi

# Production optimization mission, Phase 4 (2026-07-30): Buildroot's own
# HOST-built python3 - identical CPython 3.11 version/build to the target,
# so bytecode magic numbers match exactly, the same tool
# BR2_PACKAGE_PYTHON3_PYC_ONLY already uses for system packages (see
# vendor/system/buildroot/package/python3/python3.mk). Used below to
# precompile Klipper/Moonraker's own Python source, which - unlike system
# Buildroot packages - was never routed through that mechanism. Degrade to
# source-only (no precompiled .pyc) rather than failing the build if
# missing for any reason, exactly like every other optional step here.
HOST_PYTHON3="$TOOLCHAIN_HOST/bin/python3"
if [ ! -x "$HOST_PYTHON3" ]; then
	echo "WARNING: $HOST_PYTHON3 not found - Klipper/Moonraker will ship without precompiled bytecode" >&2
	HOST_PYTHON3=""
fi

if [ -f "$REPO_ROOT/vendor/system/buildroot/package/python3/python3.mk" ]; then
	TARGET_PY_MAJOR=$(grep "^PYTHON3_VERSION_MAJOR =" "$REPO_ROOT/vendor/system/buildroot/package/python3/python3.mk" | awk '{print $3}')
	TARGET_PY_FULL=$(grep "^PYTHON3_VERSION =" "$REPO_ROOT/vendor/system/buildroot/package/python3/python3.mk" | head -n1 | sed -e 's/.*= *//' -e "s/\$(PYTHON3_VERSION_MAJOR)/$TARGET_PY_MAJOR/")
fi
TARGET_PY_MAJOR="${TARGET_PY_MAJOR:-3.14}"
TARGET_PY_FULL="${TARGET_PY_FULL:-3.14.5}"
TARGET_PY_DIR="python${TARGET_PY_MAJOR}"
TARGET_PY_TAG=$(echo "$TARGET_PY_MAJOR" | tr -d '.')

bytecode_input_fingerprint() {
	bytecode_source_dir="$1"
	bytecode_source_pin="$2"
	bytecode_mount_path="$3"
	bytecode_patch_file="$4"
	bytecode_extra_dir="$5"
	{
		printf 'format=%s\n' "$BYTECODE_FORMAT_VERSION"
		printf 'source_pin=%s\n' "$bytecode_source_pin"
		printf 'mount_path=%s\n' "$bytecode_mount_path"
		printf 'python_version='
		"$HOST_PYTHON3" --version 2>&1
		sha256sum "$HOST_PYTHON3"
		[ -z "$bytecode_patch_file" ] || sha256sum "$bytecode_patch_file"
		find "$bytecode_source_dir" -type f ! -path '*/__pycache__/*' -print | sort |
			while IFS= read -r bytecode_source; do sha256sum "$bytecode_source"; done
		if [ -n "$bytecode_extra_dir" ]; then
			find "$bytecode_extra_dir" -type f ! -path '*/__pycache__/*' -print | sort |
				while IFS= read -r bytecode_source; do sha256sum "$bytecode_source"; done
		fi
	} | sha256sum | awk '{print $1}'
}

compile_or_reuse_bytecode() {
	bytecode_name="$1"
	bytecode_source_dir="$2"
	bytecode_source_pin="$3"
	bytecode_mount_path="$4"
	bytecode_patch_file="$5"
	bytecode_extra_dir="$6"
	bytecode_cache_dir="$BYTECODE_CACHE/$bytecode_name"
	bytecode_cache_tar="$bytecode_cache_dir/pycache.tar.gz"
	bytecode_fingerprint_file="$bytecode_cache_dir/fingerprint"
	bytecode_fingerprint=$(bytecode_input_fingerprint \
		"$bytecode_source_dir" "$bytecode_source_pin" "$bytecode_mount_path" \
		"$bytecode_patch_file" "$bytecode_extra_dir")

	if [ -f "$bytecode_fingerprint_file" ] && \
		[ "$(cat "$bytecode_fingerprint_file")" = "$bytecode_fingerprint" ] && \
		[ -s "$bytecode_cache_tar" ] && \
		tar -tzf "$bytecode_cache_tar" | grep -q '__pycache__/'; then
		find "$bytecode_source_dir" -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true
		tar -C "$bytecode_source_dir" -xzf "$bytecode_cache_tar"
		echo "== $bytecode_name bytecode inputs unchanged ($bytecode_fingerprint); reusing cached bytecode =="
		return 0
	fi

	echo "== $bytecode_name bytecode inputs changed or no successful fingerprint; compiling =="
	bytecode_compile_status=0
	PYTHONPATH="" "$HOST_PYTHON3" -m compileall -q -f \
		--invalidation-mode checked-hash \
		-s "$bytecode_source_dir" -p "$bytecode_mount_path" \
		"$bytecode_source_dir" || bytecode_compile_status=$?
	if [ "$bytecode_compile_status" -ne 0 ]; then
		echo "WARNING: bytecode precompilation failed for $bytecode_name - shipping source-only" >&2
		return 0
	fi
	bytecode_cache_tmp=$(mktemp "$WORK/$bytecode_name-bytecode.XXXXXX.tar.gz")
	if ! ( cd "$bytecode_source_dir" && find . -type d -name __pycache__ -print | \
		tar -C "$bytecode_source_dir" -czf "$bytecode_cache_tmp" -T - ) || \
		! tar -tzf "$bytecode_cache_tmp" | grep -q '__pycache__/'; then
		rm -f "$bytecode_cache_tmp"
		return 0
	fi
	rm -rf "$bytecode_cache_dir"
	mkdir -p "$bytecode_cache_dir"
	mv "$bytecode_cache_tmp" "$bytecode_cache_tar"
	printf '%s\n' "$bytecode_fingerprint" > "$bytecode_fingerprint_file"
}

mkdir -p "$WORK"

### 0. Printer MCU firmware: build, validate, and stage the immutable
###    Creality image plus the identity-gated runtime tools.
sh "$SCRIPT_DIR/build-mcu-firmware.sh"

### 1. Klipper: klippy/ source + a freshly cross-compiled chelper.so
###    Official upstream builds this helper from the source list in
###    klippy/chelper/__init__.py; there is no chelper Makefile.
chelp_sources="pyhelper.c serialqueue.c stepcompress.c steppersync.c itersolve.c trapq.c pollreactor.c msgblock.c trdispatch.c kin_cartesian.c kin_corexy.c kin_corexz.c kin_delta.c kin_deltesian.c kin_polar.c kin_rotary_delta.c kin_winch.c kin_extruder.c kin_shaper.c kin_idex.c kin_generic.c"
CHELPER_INPUT_FINGERPRINT=$(
	{
		printf 'klipper_pin=%s\n' "$KLIPPER_PIN"
		printf 'system_pin=%s\n' "$SYSTEM_PIN"
		printf 'compiler_flags=-Wall -g -O2 -shared -fPIC -flto -fwhole-program -fno-use-linker-plugin\n'
		find "$VENDOR/klipper/klippy/chelper" -type f \
			\( -name '*.c' -o -name '*.h' \) -print | sort |
			while IFS= read -r source; do sha256sum "$source"; done
		sha256sum \
			"$TOOLCHAIN_HOST/bin/mipsel-buildroot-linux-gnu-gcc" \
			"$TOOLCHAIN_HOST/bin/mipsel-buildroot-linux-gnu-strip"
	} | sha256sum | awk '{print $1}'
)
CHELPER_REBUILD_REQUIRED=1
if [ -f "$CHELPER_FINGERPRINT_FILE" ] && \
	[ "$(cat "$CHELPER_FINGERPRINT_FILE")" = "$CHELPER_INPUT_FINGERPRINT" ] && \
	[ -s "$CHELPER_CACHE/c_helper.so" ] && \
	[ -s "$CHELPER_CACHE/c_helper.so.debug" ]; then
	CHELPER_REBUILD_REQUIRED=0
	echo "== chelper inputs unchanged ($CHELPER_INPUT_FINGERPRINT); reusing cached build =="
else
	echo "== chelper inputs changed or no successful fingerprint; rebuilding =="
fi

if [ "$CHELPER_REBUILD_REQUIRED" -eq 1 ]; then
	echo "== cross-compiling Klipper's chelper C extension =="
(
	cd "$VENDOR/klipper/klippy/chelper"
	export PATH="$BUILDROOT_DIR/output/host/bin:$PATH"
	rm -f c_helper.so _temp_c_helper.so *.o *.a
	mipsel-buildroot-linux-gnu-gcc -Wall -g -O2 -shared -fPIC \
		-flto -fwhole-program -fno-use-linker-plugin \
		-o _temp_c_helper.so $chelp_sources
	mv -f _temp_c_helper.so c_helper.so
)
fi

# Production optimization mission, Phase 6 (2026-07-30): c_helper.so shipped
# with full debug symbols in every rootfs.squashfs built so far - Buildroot's
# own blanket TARGET_FINALIZE strip pass never reaches this file since it's
# copied into the overlay directly by this script, after that pass runs, not
# built as a real Buildroot package. Same class of gap as ustreamer/v4l2-ctl
# below, which already strip explicitly for the same reason. Keep an
# unstripped copy with symbols in the gitignored build-work tree (not the
# production rootfs) before stripping, matching the ustreamer/v4l2-ctl
# pattern's build-ID-preserving intent.
mkdir -p "$WORK/debug-symbols"
if [ "$CHELPER_REBUILD_REQUIRED" -eq 1 ]; then
	cp "$VENDOR/klipper/klippy/chelper/c_helper.so" "$WORK/debug-symbols/c_helper.so.debug"
	(
		cd "$VENDOR/klipper/klippy/chelper"
		export PATH="$BUILDROOT_DIR/output/host/bin:$PATH"
		mipsel-buildroot-linux-gnu-strip --strip-unneeded c_helper.so
	)
	rm -rf "$CHELPER_CACHE"
	mkdir -p "$CHELPER_CACHE"
	cp "$VENDOR/klipper/klippy/chelper/c_helper.so" "$CHELPER_CACHE/c_helper.so"
	cp "$WORK/debug-symbols/c_helper.so.debug" "$CHELPER_CACHE/c_helper.so.debug"
	printf '%s\n' "$CHELPER_INPUT_FINGERPRINT" > "$CHELPER_FINGERPRINT_FILE"
else
	cp "$CHELPER_CACHE/c_helper.so" "$VENDOR/klipper/klippy/chelper/c_helper.so"
	cp "$CHELPER_CACHE/c_helper.so.debug" "$WORK/debug-symbols/c_helper.so.debug"
fi
chelper_dir="$VENDOR/klipper/klippy/chelper"
newest=$(ls -t "$chelper_dir"/*.c "$chelper_dir"/*.h "$chelper_dir"/__init__.py 2>/dev/null | head -1)
[ -n "$newest" ] && touch -r "$newest" "$chelper_dir/c_helper.so" 2>/dev/null || true
touch -d "@2000000000" "$chelper_dir/c_helper.so" 2>/dev/null || true

# Publish the platform proof consumed by nebulaos_compat. Keep it staged
# outside the Klipper checkout so the upstream source remains clean; it is
# copied into the immutable runtime and injected into the factory seed later.
CHELPER_VERDICT="$WORK/nebulaos-chelper-verdict.json"
cat > "$CHELPER_VERDICT" <<EOF
{
  "status": "ok",
  "target": "klippy/chelper/c_helper.so",
  "target_sha256": "$(sha256sum "$VENDOR/klipper/klippy/chelper/c_helper.so" | cut -d' ' -f1)",
  "requirement": "prebuilt_so_mtime_newer_than_all_chelper_sources"
}
EOF

### 1a. klipper_mcu: upstream Klipper's own MACH_LINUX build target, compiled
###    as a native MIPS Linux program (not cross-compiled embedded firmware
###    in the flashing sense - it links and runs like any other userspace
###    binary on the target, just built with the target's own cross
###    toolchain instead of the host's). This is the Phase 1.9A host-MCU
###    restoration: it serves [mcu rpi] over a Unix socket for the physical
###    ADXL345 accelerometer and BL24C16F EEPROM, both wired directly to the
###    SoC rather than to the GD32F303 stepper-driver MCU that
###    S50nebulaos-mcu-guard/creality_flash.py manage - zero interaction
###    with that subsystem.
###
### test/configs/linuxprocess.config is upstream's own reference Kconfig for
### this target; CROSS_PREFIX is the only variable this Makefile needs to
### produce a MIPS binary instead of a host-native one (CC/AS/LD/OBJCOPY all
### derive from it - see vendor/klipper/Makefile).
echo "== cross-compiling Klipper's host MCU (MACH_LINUX / klipper_mcu) =="
(
	cd "$VENDOR/klipper"
	rm -rf out .config .config.old
	cp test/configs/linuxprocess.config .config
	export PATH="$BUILDROOT_DIR/output/host/bin:$PATH"
	make olddefconfig
	make CROSS_PREFIX=mipsel-buildroot-linux-gnu- || {
		echo "FATAL: cross-compiling klipper_mcu (MACH_LINUX) failed" >&2
		exit 1
	}
	[ -f out/klipper.elf ] || {
		echo "FATAL: out/klipper.elf was not produced" >&2
		exit 1
	}
) || exit 1

# Debug-symbol preservation mirrors c_helper.so/ustreamer/v4l2-ctl above -
# TARGET_FINALIZE's blanket strip pass never reaches this file since it is
# copied into the overlay directly by this script, after that pass runs.
cp "$VENDOR/klipper/out/klipper.elf" "$WORK/debug-symbols/klipper_mcu.debug"
(
	cd "$VENDOR/klipper"
	export PATH="$BUILDROOT_DIR/output/host/bin:$PATH"
	mipsel-buildroot-linux-gnu-strip --strip-unneeded out/klipper.elf
)
mkdir -p "$OVERLAY/usr/bin"
cp "$VENDOR/klipper/out/klipper.elf" "$OVERLAY/usr/bin/klipper_mcu"
chmod 755 "$OVERLAY/usr/bin/klipper_mcu"
# Leave vendor/klipper's top-level tree exactly as it was before this step -
# out/.config are build-local scratch state, not shipped inputs, and the
# klippy/ copy below is taken from the source tree, not this build's out/.
rm -rf "$VENDOR/klipper/out" "$VENDOR/klipper/.config" "$VENDOR/klipper/.config.old"

mkdir -p "$OVERLAY/opt/klipper"
rm -rf "$OVERLAY/opt/klipper/klippy"

# RosetteOS mutable-runtime closure mission (2026-07-27): empty mount-point
# baked into the squashfs so S05nebulaos-activate can bind-mount the real,
# persistent Klipper venv ($ROSETTEOS_ROOT/envs/klipper) onto it at boot.
# Required specifically because Moonraker's update_manager hardcodes
# "~/klippy-env/bin/python" as its bootstrap default for the klipper slot
# (klippy_connection.py's own __init__, used synchronously at Moonraker
# startup, before Klippy's real identify handshake has a chance to report
# its actual executable) - with no config override available for this
# slot (confirmed live: path/env/virtualenv aren't in update_manager's own
# OPTION_OVERRIDES), the only way to make update_manager succeed on the
# very first Moonraker start (not just self-heal after a lucky second
# restart once Klippy's real path gets persisted to Moonraker's own db)
# is to make that exact hardcoded default path real. /root is part of the
# read-only squashfs, so this directory must exist here at build time -
# mkdir at runtime would fail (read-only filesystem).
mkdir -p "$OVERLAY/root/klippy-env"
# Install the companion extensions tree separately from Klipper core. The
# extension compatibility code resolves its manifest from the real module
# path and verifies that runtime modules are symlinks into this tree, which is
# also how RosetteOS identifies a complete, supported installation.
extension_runtime="$OVERLAY/opt/klipper-extensions"
rm -rf "$extension_runtime"
mkdir -p "$extension_runtime"
cp -r "$VENDOR/klipper-extensions/extras" "$extension_runtime/"
cp "$VENDOR/klipper-extensions/nebulaos-extensions.json" \
	"$extension_runtime/"

# Stage symlinks separately so the upstream Klipper checkout itself remains
# clean for make_seed_archive(). These relative targets remain valid when the
# symlink set is copied into /opt/klipper/klippy/extras on the device.
extra_stage="$WORK/nebulaos-klipper-runtime-extras"
rm -rf "$extra_stage"
mkdir -p "$extra_stage"
for extra in \
	bl24c16f.py \
	guppy_config_helper.py \
	guppy_module_loader.py \
	calibrate_shaper_config.py \
	gcode_shell_command.py \
	tmcstatus.py \
	nebulaos_calibration.py \
	nebulaos_compat.py \
	nebulaos_plr_journal.py \
	nebulaos_power_loss_recovery.py \
	nebulaos_probe_pair.py \
	nebulaos_temperature_mcu.py \
	nebulaos_version.py \
	nebulaos_z_offset_probe.py \
	nozzle_clear.py \
	prtouch_test_support.py \
	virtual_pins.py \
	z_compensate.py; do
	ln -s "/opt/klipper-extensions/extras/$extra" \
		"$extra_stage/$extra"
done
cp -r "$VENDOR/klipper/klippy" "$OVERLAY/opt/klipper/"
cp -P "$extra_stage"/* "$OVERLAY/opt/klipper/klippy/extras/"
# Moonraker's reserved Klipper update-manager slot validates this helper
# path even when no explicit install_script option is configured. Keep it in
# the immutable fallback as well as the full persistent seed checkout, so a
# deliberately rejected/incomplete persistent checkout cannot make Moonraker
# fail merely because S05 selected the safe immutable path.
mkdir -p "$OVERLAY/opt/klipper/scripts"
cp "$VENDOR/klipper/scripts/install-octopi.sh" \
	"$OVERLAY/opt/klipper/scripts/install-octopi.sh"
cp "$CHELPER_VERDICT" "$OVERLAY/opt/klipper/.nebulaos-chelper-verdict.json"
# Keep the immutable fallback small. The writable factory-seeded checkout
# carries the complete Git repository; the fallback only needs the qualified
# identity for nebulaos_compat's read-only startup check. S05 replaces this
# fallback with the complete writable checkout after successful provisioning.
mkdir -p "$OVERLAY/opt/klipper/.git/refs/heads" \
	"$OVERLAY/opt/klipper/.git/objects/info" \
	"$OVERLAY/opt/klipper/.git/objects/pack"
printf 'ref: refs/heads/%s\n' "$KLIPPER_BRANCH" > "$OVERLAY/opt/klipper/.git/HEAD"
printf '%s\n' "$KLIPPER_PIN" > "$OVERLAY/opt/klipper/.git/refs/heads/$KLIPPER_BRANCH"
cat > "$OVERLAY/opt/klipper/.git/config" <<EOF
[core]
	repositoryformatversion = 0
	bare = false
[remote "origin"]
	url = $KLIPPER_REPO
[branch "$KLIPPER_BRANCH"]
	remote = origin
	merge = refs/heads/$KLIPPER_BRANCH
EOF
find "$OVERLAY/opt/klipper" -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
# Production optimization mission, Phase 4 (2026-07-30): this squashfs
# copy is the immutable fallback used if persistent storage/the real bind-
# mounted seed is ever unavailable - precompile it too, not just the seed
# archive below, so that fallback path benefits as well. See the seed
# archive's own Phase 4 comment for why $HOST_PYTHON3 is the right tool.
if [ -n "$HOST_PYTHON3" ]; then
	compile_or_reuse_bytecode klipper \
		"$OVERLAY/opt/klipper/klippy" \
		"$KLIPPER_PIN:$KLIPPER_EXTRAS_PIN" \
		"/opt/klipper" "" \
		"$VENDOR/klipper-extensions/extras"
fi
rm -f "$OVERLAY/opt/klipper/klippy/chelper"/*.o "$OVERLAY/opt/klipper/klippy/chelper"/*.a
if [ -f "$OVERLAY/opt/klipper/klippy/chelper/c_helper.so" ]; then
	chelper_dir="$OVERLAY/opt/klipper/klippy/chelper"
	newest=$(ls -t "$chelper_dir"/*.c "$chelper_dir"/*.h "$chelper_dir"/__init__.py 2>/dev/null | head -1)
	[ -n "$newest" ] && touch -r "$newest" "$chelper_dir/c_helper.so" 2>/dev/null || true
	touch -d "@2000000000" "$chelper_dir/c_helper.so" 2>/dev/null || true
fi

# Stock-parity fix (FIRMWARE.md sec 13): only klippy/ was ever staged here,
# so Moonraker's file_manager always registered "config_examples" ->
# /opt/klipper/config and "docs" -> /opt/klipper/docs (its own unconditional
# behavior, not custom-specific), and both warned "invalid path" every boot
# since neither existed. Stock's real Klipper install (/usr/share/klipper)
# ships the full upstream checkout, config/ and docs/ included, which is
# why stock never showed this warning - not a different Moonraker behavior,
# just real content actually being present. Our own vendor/klipper is a
# full checkout too; it was just never copied. Packaging the exact same
# revision's reference content here, not fabricated placeholder content.
rm -rf "$OVERLAY/opt/klipper/config" "$OVERLAY/opt/klipper/docs"
cp -r "$VENDOR/klipper/config" "$OVERLAY/opt/klipper/"
cp -r "$VENDOR/klipper/docs" "$OVERLAY/opt/klipper/"
# Moonraker's reserved Klipper updater validates this path even when the
# immutable fallback is active. Ship the small host-runtime requirements file
# without copying Klipper's full development scripts tree into the rootfs.
mkdir -p "$OVERLAY/opt/klipper/scripts"
cp "$VENDOR/klipper/scripts/klippy-requirements.txt" \
	"$OVERLAY/opt/klipper/scripts/"

# Pure upstream Klipper is copied unchanged from the refreshed official
# checkout. Fork-only RosetteOS/Creality extras are intentionally not
# injected into the runtime image.

### 2. Moonraker: source + its Python dependency chain
echo "== copying Moonraker source =="
mkdir -p "$OVERLAY/opt/moonraker"
rm -rf "$OVERLAY/opt/moonraker/moonraker"
cp -r "$VENDOR/moonraker/moonraker" "$OVERLAY/opt/moonraker/"
find "$OVERLAY/opt/moonraker" -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true

# RosetteOS (2026-07-23): vendor/moonraker is a plain upstream clone re-fetched
# fresh by 00-fetch-vendor-sources.sh every time (unlike the kernel, which
# is a real fork we commit to) - so this patch is applied to the copy that
# just landed in the overlay, not to vendor/moonraker itself, which would
# silently lose it on the next fetch. Fixes a real, reproducible hang/
# "database is locked" error found on real hardware: strace showed
# fcntl64(fd, F_SETLK64, F_RDLCK, PENDING_BYTE) = -1 EACCES on this
# kernel's tmpfs, with zero real lock contention (single connection, first
# ever access) - SQLite's own documented nolock=1 URI workaround for
# filesystems with broken POSIX locking fixes it, confirmed reliably
# reproducible/fixed multiple times in a row (see FIRMWARE.md sec 23).
#
# -N: the copy above is a fresh rm -rf + cp -r from vendor/moonraker every
# run, so this should always be pristine and apply cleanly - but patch's own
# "already applied" detection has, in practice, still triggered here and
# (without -N) aborted the whole script via set -e despite the file already
# being in the correct end state. -N makes patch skip hunks it detects as
# already-applied instead of erroring, so this stays idempotent either way.
patch -N -p1 -d "$OVERLAY/opt/moonraker" < "$SCRIPT_DIR/patches/moonraker-sqlite-nolock.patch" || true
patch -N -p1 -d "$OVERLAY/opt/moonraker" < "$SCRIPT_DIR/patches/moonraker-components-extension.patch" || true


# Production optimization mission, Phase 4 (2026-07-30): precompile after
# the patch above, not before, so bytecode reflects the final patched
# content rather than needing that one file recompiled on first import.
# Same immutable-fallback reasoning as the klipper copy above.
if [ -n "$HOST_PYTHON3" ]; then
	compile_or_reuse_bytecode moonraker \
		"$OVERLAY/opt/moonraker/moonraker" \
		"$MOONRAKER_PIN" \
		"/opt/moonraker" "$SCRIPT_DIR/patches/moonraker-sqlite-nolock.patch" ""
fi

# RosetteOS (2026-07-23): zipp added after a real, previously-silent bug found
# on real hardware - importlib_metadata (below) imports zipp at runtime, but
# --no-deps meant it was never actually downloaded, so Moonraker died
# instantly with ModuleNotFoundError: No module named zipp, before opening
# its own log file at all.
echo "== downloading Moonraker's pure-Python deps with no Buildroot package =="
mkdir -p "$PYWHEELS_DIR"
PYTHON_WHEEL_REQUIREMENTS="inotify-simple==2.0.1 libnacl==2.1.0 apprise==1.13.0 ldap3==2.9.1 importlib_metadata==9.0.0 preprocess-cancellation==0.2.1 pyasn1==$MOONRAKER_PYASN1_VERSION zipp==4.1.0 wheel==0.45.1"
python_wheels_fingerprint() {
	{
		printf 'requirements=%s\n' "$PYTHON_WHEEL_REQUIREMENTS"
		for wheel in "$PYWHEELS_DIR"/*.whl; do
			[ -f "$wheel" ] && sha256sum "$wheel"
		done
	} | sha256sum | awk '{print $1}'
}
PYTHON_WHEELS_FINGERPRINT=$(python_wheels_fingerprint)
if [ -f "$PYWHEELS_FINGERPRINT_FILE" ] && \
	[ "$(cat "$PYWHEELS_FINGERPRINT_FILE")" = "$PYTHON_WHEELS_FINGERPRINT" ]; then
	echo "== Moonraker Python wheel inputs unchanged ($PYTHON_WHEELS_FINGERPRINT); reusing cached downloads =="
else
	echo "== Moonraker Python wheel inputs changed or no successful fingerprint; refreshing downloads =="
	rm -f "$PYWHEELS_DIR"/*.whl
	pip3 download -d "$PYWHEELS_DIR" --no-deps --only-binary=:all: $PYTHON_WHEEL_REQUIREMENTS
	PYTHON_WHEELS_FINGERPRINT=$(python_wheels_fingerprint)
	printf '%s\n' "$PYTHON_WHEELS_FINGERPRINT" > "$PYWHEELS_FINGERPRINT_FILE"
fi
SITEPKG="$OVERLAY/usr/lib/$TARGET_PY_DIR/site-packages"
mkdir -p "$SITEPKG"
for whl in "$WORK"/pywheels/*.whl; do
	python3 -m zipfile -e "$whl" "$SITEPKG/" 2>&1 || unzip -o -q "$whl" -d "$SITEPKG"
done

echo "== cross-compiling Moonraker's one real C extension: streaming-form-data =="
STREAMING_VERSION="2.1.0"
STREAMING_ARCHIVE=$(ls "$PYWHEELS_DIR"/streaming[-_]form[-_]data-${STREAMING_VERSION}.tar.gz 2>/dev/null | head -n 1 || true)
if [ ! -s "$STREAMING_ARCHIVE" ]; then
	STREAMING_URL="https://files.pythonhosted.org/packages/dc/fd/d49f3b4e6258e865566fd8aa3da9966f47ca5a7d7fd8ca181f8209010605/streaming_form_data-2.1.0.tar.gz"
	STREAMING_SHA256="2c5c81fc9c451ea133083bc6da959f87e9b91fba3effe99411f1f90461ea7c5b"
	STREAMING_TARGET="$PYWHEELS_DIR/streaming_form_data-${STREAMING_VERSION}.tar.gz"
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL -o "$STREAMING_TARGET" "$STREAMING_URL"
	elif command -v wget >/dev/null 2>&1; then
		wget -q -O "$STREAMING_TARGET" "$STREAMING_URL"
	else
		python3 -c "import urllib.request; urllib.request.urlretrieve('$STREAMING_URL', '$STREAMING_TARGET')"
	fi
	echo "$STREAMING_SHA256  $STREAMING_TARGET" | sha256sum -c -
	STREAMING_ARCHIVE="$STREAMING_TARGET"
fi
STREAMING_INPUT_FINGERPRINT=$(
	{
		printf 'package=streaming-form-data==%s\n' "$STREAMING_VERSION"
		printf 'system_pin=%s\n' "$SYSTEM_PIN"
		printf 'compiler_flags=-shared -fPIC -O2\n'
		printf 'patch=make-cloud-deps-optional-v1\n'
		sha256sum "$STREAMING_ARCHIVE"
		find "$SYSROOT/usr/include/$TARGET_PY_DIR" -type f -print | sort |
			while IFS= read -r header; do sha256sum "$header"; done
		sha256sum \
			"$TOOLCHAIN_HOST/bin/mipsel-buildroot-linux-gnu-gcc" \
			"$TOOLCHAIN_HOST/bin/mipsel-buildroot-linux-gnu-strip"
	} | sha256sum | awk '{print $1}'
)
STREAMING_REBUILD_REQUIRED=1
if [ -f "$STREAMING_FINGERPRINT_FILE" ] && \
	[ "$(cat "$STREAMING_FINGERPRINT_FILE")" = "$STREAMING_INPUT_FINGERPRINT" ] && \
	[ -s "$STREAMING_CACHE/package/streaming_form_data/_parser.cpython-${TARGET_PY_TAG}-mipsel-linux-gnu.so" ] && \
	[ -s "$STREAMING_CACHE/package/streaming_form_data/_parser.c" ] && \
	[ -s "$STREAMING_CACHE/package/streaming_form_data/__init__.py" ] && \
	[ -s "$STREAMING_CACHE/debug/_parser.cpython-${TARGET_PY_TAG}-mipsel-linux-gnu.so.debug" ]; then
	STREAMING_REBUILD_REQUIRED=0
	echo "== streaming-form-data inputs unchanged ($STREAMING_INPUT_FINGERPRINT); reusing cached build =="
else
	echo "== streaming-form-data inputs changed or no successful fingerprint; rebuilding =="
fi

rm -rf "$WORK/streaming_form_data-${STREAMING_VERSION}" "$WORK/streaming-form-data-${STREAMING_VERSION}" "$WORK/streaming_form_data"
if [ "$STREAMING_REBUILD_REQUIRED" -eq 1 ]; then
	tar xzf "$STREAMING_ARCHIVE" -C "$WORK"
	STREAMING_EXTRACT_DIR=$(find "$WORK" -maxdepth 1 -type d \( -name "streaming_form_data-${STREAMING_VERSION}" -o -name "streaming-form-data-${STREAMING_VERSION}" \) | head -n 1)
	if [ -d "$STREAMING_EXTRACT_DIR/src/streaming_form_data" ]; then
		STREAMING_PKG_DIR="$STREAMING_EXTRACT_DIR/src/streaming_form_data"
	else
		STREAMING_PKG_DIR="$STREAMING_EXTRACT_DIR/streaming_form_data"
	fi
	# Make optional cloud targets (smart_open, aiofiles) non-fatal on import
	# so Moonraker's standard FileTarget/ValueTarget/SHA256Target work without
	# pulling in huge unnecessary cloud SDKs (boto3, google-cloud-storage, etc.).
	python3 -c "
p = '$STREAMING_PKG_DIR/targets.py'
with open(p, 'r') as f:
    s = f.read()
s = s.replace('import smart_open', 'try:\n    import smart_open\nexcept ImportError:\n    smart_open = None')
s = s.replace('import aiofiles', 'try:\n    import aiofiles\nexcept ImportError:\n    aiofiles = None')
with open(p, 'w') as f:
    f.write(s)
"
	(
		cd "$STREAMING_PKG_DIR"
		export PATH="$TOOLCHAIN_HOST/bin:$PATH"
		mipsel-buildroot-linux-gnu-gcc -shared -fPIC -O2 \
			-I"$SYSROOT/usr/include/$TARGET_PY_DIR" \
			-o "_parser.cpython-${TARGET_PY_TAG}-mipsel-linux-gnu.so" \
			_parser.c
	)
else
	STREAMING_PKG_DIR="$WORK/streaming_form_data/streaming_form_data"
	mkdir -p "$STREAMING_PKG_DIR"
	cp -r "$STREAMING_CACHE/package/streaming_form_data/." "$STREAMING_PKG_DIR/"
fi

# Production optimization mission, Phase 6 (2026-07-30): same unstripped-
# debug-symbols gap as c_helper.so above - this .so is never routed through
# a real Buildroot package strip pass either. Preserve symbols in
# build-work, strip the copy that actually ships.
mkdir -p "$WORK/debug-symbols"
if [ "$STREAMING_REBUILD_REQUIRED" -eq 1 ]; then
	cp "$STREAMING_PKG_DIR/_parser.cpython-${TARGET_PY_TAG}-mipsel-linux-gnu.so" \
		"$WORK/debug-symbols/_parser.cpython-${TARGET_PY_TAG}-mipsel-linux-gnu.so.debug"
	(
		cd "$STREAMING_PKG_DIR"
		export PATH="$TOOLCHAIN_HOST/bin:$PATH"
		mipsel-buildroot-linux-gnu-strip --strip-unneeded "_parser.cpython-${TARGET_PY_TAG}-mipsel-linux-gnu.so"
	)
	rm -rf "$STREAMING_CACHE"
	mkdir -p "$STREAMING_CACHE/debug" "$STREAMING_CACHE/package/streaming_form_data"
	cp -r "$STREAMING_PKG_DIR/." "$STREAMING_CACHE/package/streaming_form_data/"
	cp "$WORK/debug-symbols/_parser.cpython-${TARGET_PY_TAG}-mipsel-linux-gnu.so.debug" \
		"$STREAMING_CACHE/debug/_parser.cpython-${TARGET_PY_TAG}-mipsel-linux-gnu.so.debug"
	printf '%s\n' "$STREAMING_INPUT_FINGERPRINT" > "$STREAMING_FINGERPRINT_FILE"
else
	cp "$STREAMING_CACHE/debug/_parser.cpython-${TARGET_PY_TAG}-mipsel-linux-gnu.so.debug" \
		"$WORK/debug-symbols/_parser.cpython-${TARGET_PY_TAG}-mipsel-linux-gnu.so.debug"
fi

mkdir -p "$SITEPKG/streaming_form_data"
cp "$STREAMING_PKG_DIR"/*.py \
   "$STREAMING_PKG_DIR"/*.so \
   "$SITEPKG/streaming_form_data/"
ln -sf "_parser.cpython-${TARGET_PY_TAG}-mipsel-linux-gnu.so" "$SITEPKG/streaming_form_data/_parser.so"
if [ -n "$HOST_PYTHON3" ]; then
	"$HOST_PYTHON3" -m compileall -q -f "$SITEPKG/streaming_form_data" >/dev/null 2>&1 || true
fi

### 3. ustreamer (camera pipeline)
#
# RosetteOS fix (USB/webcam stock-parity mission, FIRMWARE.md sec 60): this
# used to build via pellcorp's own `pellcorp/k1-camera-build` docker image,
# which bundles Ingenic's stock vendor toolchain
# (/opt/toolchains/mips-gcc720-glibc229, glibc 2.29). That toolchain's
# glibc uses a DIFFERENT MIPS ABI than this project's own Buildroot-built
# target glibc (2.38, confirmed via /lib/libc.so.6's own banner:
# "libc ABIs: MIPS_PLT UNIQUE MIPS_O32_FP64 ABSOLUTE MIPS_XHASH") - the
# resulting ustreamer.bin's own dynamic-linker request
# (`readelf -l` -> "Requesting program interpreter:
# /lib/ld-linux-mipsn8.so.1") never matched this rootfs's real interpreter
# (plain /lib/ld.so.1), so the binary could never actually execute here -
# busybox ash reports this as a confusing "not found" (it's really the
# missing interpreter, not the file itself; confirmed real files/libs were
# all present and correctly staged). This was never caught before because
# no prior session had a real UVC webcam physically attached to test with.
#
# Fix: build the *exact same*, untouched pellcorp/k1-ustreamer source
# (still vendor/k1-ustreamer at its pinned commit, submodules unchanged)
# with this project's own internal Buildroot toolchain instead - the same
# one already used for Klipper's chelper and Moonraker's streaming-form-
# data above, guaranteeing ABI consistency with the rest of the rootfs.
# Mirrors docker.sh's own real, proven build steps (jpeg-9d, libevent,
# libmd, libbsd, then ustreamer itself) with the toolchain swapped.
echo "== preparing ustreamer (this project's own Buildroot toolchain, not pellcorp/k1-camera-build's incompatible one) =="
USTREAMER_CACHE="$REPO_ROOT/build-work/ustreamer-mips"
USTREAMER_FINGERPRINT_FILE="$USTREAMER_CACHE/fingerprint"
USTREAMER_BIN="$USTREAMER_CACHE/ustreamer.bin"
USTREAMER_LIB_DIR="$USTREAMER_CACHE/lib"
ustreamer_input_fingerprint() {
	{
		printf 'k1_ustreamer_pin=%s\n' "$K1_USTREAMER_PIN"
		printf 'system_pin=%s\n' "$SYSTEM_PIN"
		printf 'build_script='
		sha256sum "$SCRIPT_DIR/04-cross-compile-app-stack.sh"
		printf 'cross_compiler='
		sha256sum "$TOOLCHAIN_HOST/bin/mipsel-buildroot-linux-gnu-gcc"
		printf 'buildroot_config='
		sha256sum "$BUILDROOT_DIR/.config"
		printf 'submodules\n'
		git -C "$VENDOR/k1-ustreamer" submodule status
	} | sha256sum | awk '{print $1}'
}
USTREAMER_INPUT_FINGERPRINT=$(ustreamer_input_fingerprint)
USTREAMER_REBUILD_REQUIRED=1
if [ -f "$USTREAMER_FINGERPRINT_FILE" ] && \
	[ -s "$USTREAMER_BIN" ] && [ -d "$USTREAMER_LIB_DIR" ] && \
	[ "$(cat "$USTREAMER_FINGERPRINT_FILE")" = "$USTREAMER_INPUT_FINGERPRINT" ]; then
	USTREAMER_REBUILD_REQUIRED=0
	echo "== ustreamer inputs unchanged ($USTREAMER_INPUT_FINGERPRINT); reusing cached build =="
else
	echo "== ustreamer inputs changed or no successful fingerprint; rebuilding =="
fi

if [ "$USTREAMER_REBUILD_REQUIRED" -eq 1 ]; then
	rm -rf "$VENDOR/k1-ustreamer/build"
	rm -rf "$USTREAMER_CACHE"
(
	set -e
	SRC="$VENDOR/k1-ustreamer"
	# Append, not prepend: Buildroot's own host/bin dir also carries its own
	# internal automake-1.16/autoconf wrappers (built for its own package
	# builds), which are broken when found ahead of the real system
	# automake/autoconf - they hardcode paths only valid inside the
	# Buildroot build tree itself. Appending still finds the uniquely-named
	# mipsel-buildroot-linux-gnu-* cross tools (no name collision with
	# anything already on PATH) without shadowing them.
	export PATH="$PATH:$TOOLCHAIN_HOST/bin"
	export BUILD_PREFIX="$SRC/build/ustreamer-deps"
	export CC=mipsel-buildroot-linux-gnu-gcc
	export AR=mipsel-buildroot-linux-gnu-gcc-ar
	export LD=mipsel-buildroot-linux-gnu-ld
	export STRIP=mipsel-buildroot-linux-gnu-strip
	export CFLAGS="-I$BUILD_PREFIX/include/"
	export LDFLAGS="-L$BUILD_PREFIX/lib/"
	mkdir -p "$SRC/build"

	cd "$SRC/jpeg-9d" && git clean -xdf
	cd "$SRC/ustreamer" && make clean PKG_CONFIG=true

	cd "$SRC/build"
	tar xf ../libevent-2.1.12-stable.tar.gz && cd libevent-2.1.12-stable
	./configure --host=mipsel-buildroot-linux-gnu --prefix="$BUILD_PREFIX" \
		--disable-openssl --disable-samples --disable-libevent-regress
	make && make install

	cd "$SRC/build"
	tar xf ../libmd-1.1.0.tar.xz && cd libmd-1.1.0
	./configure --host=mipsel-buildroot-linux-gnu --prefix="$BUILD_PREFIX"
	make && make install

	cd "$SRC/build"
	tar xf ../libbsd-0.11.7.tar.xz && cd libbsd-0.11.7
	./configure --host=mipsel-buildroot-linux-gnu --prefix="$BUILD_PREFIX"
	make && make install

	cd "$SRC/jpeg-9d"
	./configure --host=mipsel-buildroot-linux-gnu --build=x86_64-pc-linux-gnu --prefix="$BUILD_PREFIX"
	make && make install

	cd "$SRC/ustreamer"
	export CFLAGS="$CFLAGS -Os -march=mips32r2 -ffunction-sections -fdata-sections"
	export LDFLAGS="$LDFLAGS -Wl,--gc-sections -s"
	make PKG_CONFIG=true WITH_PTHREAD_NP=0 WITH_SETPROCTITLE=0
	mipsel-buildroot-linux-gnu-strip --strip-unneeded src/ustreamer.bin
)
mkdir -p "$USTREAMER_LIB_DIR"
cp "$VENDOR/k1-ustreamer/ustreamer/src/ustreamer.bin" "$USTREAMER_BIN"
cp -a "$VENDOR/k1-ustreamer/build/ustreamer-deps/lib/." "$USTREAMER_LIB_DIR/"
fi
file "$USTREAMER_BIN" | grep -q "MIPS" || {
	echo "FATAL: $USTREAMER_BIN is not a MIPS binary (got: $(file "$USTREAMER_BIN"))" >&2
	exit 1
}
if [ "$USTREAMER_REBUILD_REQUIRED" -eq 1 ]; then
	printf '%s\n' "$USTREAMER_INPUT_FINGERPRINT" > "$USTREAMER_FINGERPRINT_FILE"
fi
mkdir -p "$OVERLAY/usr/bin" "$OVERLAY/usr/lib"
cp "$USTREAMER_BIN" "$OVERLAY/usr/bin/ustreamer"
chmod 755 "$OVERLAY/usr/bin/ustreamer"
cp "$USTREAMER_LIB_DIR"/*.so* "$OVERLAY/usr/lib/"
# re-create the SONAME symlinks the binary actually needs - verified fresh
# against this rebuilt binary via `readelf -d ustreamer | grep NEEDED`,
# not assumed from the old pellcorp-toolchain build.
( cd "$OVERLAY/usr/lib" && \
  ln -sf libjpeg.so.9.4.0 libjpeg.so.9 && \
  ln -sf libevent-2.1.so.7.0.1 libevent-2.1.so.7 && \
  ln -sf libevent_core-2.1.so.7.0.1 libevent_core-2.1.so.7 && \
  ln -sf libevent_extra-2.1.so.7.0.1 libevent_extra-2.1.so.7 && \
  ln -sf libevent_pthreads-2.1.so.7.0.1 libevent_pthreads-2.1.so.7 && \
  ln -sf libmd.so.0.1.0 libmd.so.0 && \
  ln -sf libbsd.so.0.11.7 libbsd.so.0 )

### 4. v4l2-ctl (USB/webcam stock-parity mission, FIRMWARE.md sec 60)
#
# Buildroot provides package/libv4l with BR2_PACKAGE_LIBV4L_UTILS=y
# which compiles and installs v4l2-ctl directly into output/target/usr/bin/v4l2-ctl.
[ -s "$BUILDROOT_DIR/output/target/usr/bin/v4l2-ctl" ] || {
	echo "FATAL: Buildroot output/target/usr/bin/v4l2-ctl is missing (BR2_PACKAGE_LIBV4L_UTILS not built)" >&2
	exit 1
}
echo "== v4l2-ctl verified in Buildroot target (package libv4l) =="

### 5. Mainsail static build (already unpacked by 00-fetch-vendor-sources.sh)
echo "== copying Mainsail static build =="
mkdir -p "$OVERLAY/usr/share/mainsail"
cp -r "$VENDOR"/mainsail-dist/dist/* "$OVERLAY/usr/share/mainsail/"

### 6. GuppyScreen (RosetteOS frontend at the pinned source commit; consumes the z_compensate
# structured status contract - see docs/z_compensate_status_api.md)
#
# GuppyScreen is pinned by stage 00. Reuse its existing tracked binaries when
# the artifact manifest records that same source commit; otherwise build with
# the exact MIPS toolchain and upstream build script.
GUPPYSCREEN_SRC="$VENDOR/guppyscreen"
if [ ! -d "$GUPPYSCREEN_SRC" ]; then
	echo "FATAL: $GUPPYSCREEN_SRC not found - run 00-fetch-vendor-sources.sh first" >&2
	exit 1
fi
GUPPY_ARTIFACT_DIR="$REPO_ROOT/artifacts/guppyscreen-mips"
GUPPY_ARTIFACT_MANIFEST="$REPO_ROOT/artifacts/buildroot-halley5-v30-image/build-manifest.txt"
GUPPY_BIN="$GUPPY_ARTIFACT_DIR/guppyscreen"
GUPPY_BEEP="$GUPPY_ARTIFACT_DIR/guppybeep"
GUPPYSCREEN_COMMIT="$GUPPYSCREEN_PIN"
GUPPY_ARTIFACT_COMMIT=$(grep '^git_commit_guppyscreen=' "$GUPPY_ARTIFACT_MANIFEST" 2>/dev/null | cut -d= -f2)
if [ "$GUPPY_ARTIFACT_COMMIT" = "$GUPPYSCREEN_PIN" ] && \
	[ -s "$GUPPY_BIN" ] && [ -s "$GUPPY_BEEP" ] && \
	file "$GUPPY_BIN" 2>/dev/null | grep -q 'MIPS.*statically linked' && \
	file "$GUPPY_BEEP" 2>/dev/null | grep -q 'MIPS.*statically linked'; then
	echo "== reusing GuppyScreen binaries from pinned commit $GUPPYSCREEN_PIN =="
else
	GUPPYSCREEN_COMMIT=$(git -C "$GUPPYSCREEN_SRC" rev-parse HEAD)
	echo "== cross-compiling GuppyScreen (pinned commit $GUPPYSCREEN_COMMIT; Bootlin mips32el-musl toolchain) =="
	rm -rf "$GUPPYSCREEN_SRC/build" "$GUPPYSCREEN_SRC/spdlog/build" "$GUPPYSCREEN_SRC/spdlog/build-mips" "$GUPPYSCREEN_SRC/libhv/build" "$GUPPYSCREEN_SRC/libhv/build-mips"
	(
	set -e
	cd "$GUPPYSCREEN_SRC"
	export ROSETTEOS_VERSION="$ROSETTEOS_VERSION"
	export GUPPY_THEME="$GUPPYSCREEN_THEME"
	# Scoped to this subshell only, NOT the image's global PATH - see
	# build-env/Dockerfile's own comment on GUPPYSCREEN_TOOLCHAIN_BIN for
	# why (this toolchain's own bundled autoreconf/automake is broken and
	# would shadow the system one v4l2-ctl's autoreconf step needs, if put
	# on PATH globally).
	if [ -n "${GUPPYSCREEN_TOOLCHAIN_BIN:-}" ]; then
		export PATH="$GUPPYSCREEN_TOOLCHAIN_BIN:$PATH"
	elif [ -d "$TOOLCHAIN_HOST/bin" ]; then
		export PATH="$TOOLCHAIN_HOST/bin:$PATH"
	fi
	# wiki/Building-from-Source.md step 3 ("Build the bundled libraries") -
	# scripts/build-mips.sh backs up and restores these three native
	# archives around its own MIPS rebuild, so they must already exist.
	# Deliberately NOT setting CROSS_COMPILE for these three - the top-level
	# Makefile switches CC/AR/etc the moment CROSS_COMPILE is non-empty (see
	# its own `ifdef CROSS_COMPILE` block), and these three targets need a
	# plain NATIVE build here (confirmed: setting it broke `make libhv.a`
	# with "Relocations in generic ELF" - its own build system does not
	# cross-compile correctly through this simple CC override, unlike
	# build-mips.sh below, which cross-compiles libhv/spdlog itself via a
	# proper CMake toolchain file).
	make wpaclient
	make libhv.a
	make libspdlog.a
	# build-mips.sh defaults CROSS_COMPILE to mipsel-linux- itself when
	# unset - not overridden here, for the same reason as above. Finds the
	# Migration-A toolchain via this image's own PATH (build-env/Dockerfile
	# puts /toolchains/mips32el--musl--stable-2024.02-1/bin on PATH
	# directly, matching what ghcr.io/coreflake1/guppydev used to provide).
	bash scripts/build-mips.sh
	# scripts/release.sh, the documented release packaging step for this
	# project, strips both binaries before shipping them - matches the
	# previously hand-built binary being replaced here, and there is no
	# reason to ship debug symbols on the printer.
	mipsel-linux-strip build/bin/guppyscreen build/bin/guppybeep
	)
	GUPPY_BIN="$GUPPYSCREEN_SRC/build/bin/guppyscreen"
	GUPPY_BEEP="$GUPPYSCREEN_SRC/build/bin/guppybeep"
fi
# Phase 11 (2026-08-15): the alpine:latest chown-fixup container that used
# to run here is gone - it existed only to reclaim ownership of build/
# after the old guppydev container wrote it as root. This build now runs
# as one consistent user throughout, so build/ was never root-owned to
# begin with.

# Verify real output rather than trusting a zero exit code alone - the
# per-object-directory-race retry logic inside build-mips.sh (see its own
# header comment) is a real, documented workaround, not proof the final
# binary is actually a complete, correctly-linked MIPS executable.
for bin in "$GUPPY_BIN" "$GUPPY_BEEP"; do
	[ -s "$bin" ] || { echo "FATAL: $bin missing or empty after build" >&2; exit 1; }
	file "$bin" | grep -q "MIPS" || { echo "FATAL: $bin is not a MIPS binary (got: $(file "$bin"))" >&2; exit 1; }
done
file "$GUPPY_BIN" | grep -q "statically linked" || {
	echo "FATAL: $GUPPY_BIN is not statically linked - this rootfs has no dynamic linker entry for it (see the ustreamer section above for the exact ABI-mismatch failure mode a dynamically-linked binary hits here)" >&2
	exit 1
}
echo "== GuppyScreen build verified: $(file "$GUPPY_BIN") =="

mkdir -p "$OVERLAY/opt/guppyscreen" "$REPO_ROOT/artifacts/guppyscreen-mips"
cp "$GUPPY_BIN" "$OVERLAY/opt/guppyscreen/guppyscreen"
cp "$GUPPY_BEEP" "$OVERLAY/opt/guppyscreen/guppybeep"
if [ "$GUPPY_BIN" != "$REPO_ROOT/artifacts/guppyscreen-mips/guppyscreen" ]; then
	cp "$GUPPY_BIN" "$REPO_ROOT/artifacts/guppyscreen-mips/guppyscreen"
fi
if [ "$GUPPY_BEEP" != "$REPO_ROOT/artifacts/guppyscreen-mips/guppybeep" ]; then
	cp "$GUPPY_BEEP" "$REPO_ROOT/artifacts/guppyscreen-mips/guppybeep"
fi
chmod 755 "$OVERLAY/opt/guppyscreen/guppyscreen" "$OVERLAY/opt/guppyscreen/guppybeep"

### 7. NebulaOS mutable-runtime mission, Phase 4 (revised - real-history
# repair mission, see docs/NEBULAOS_MOONRAKER_UPDATE_AND_CAMERA_ANALYSIS.md
# and the auto-updates-camera-complete mission): immutable offline factory
# seeds for Klipper and Moonraker, baked into the read-only squashfs so
# first-boot namespace seeding (S04nebulaos-factory-seed) never depends on
# GitHub, PyPI, or DNS being reachable. Mainsail needs no seed archive - it
# is already a plain static release tree, not a git repo, so the existing
# /usr/share/mainsail copy above IS its own offline seed; first-boot
# seeding just cp -a's it.
#
# PRIOR APPROACH (removed): each vendor checkout was flattened into a
# single synthetic orphan commit ("NebulaOS factory seed snapshot of
# <branch> @ <true_commit>") before bundling, because a plain
# `git bundle create` of vendor/klipper's depth-1 shallow clone
# (00-fetch-vendor-sources.sh's clone_branch) produces a bundle that
# `git bundle verify` reports as fine but a real `git clone` of rejects
# with "Failed to traverse parents of commit ..." / "remote did not send all
# necessary objects" (confirmed again against git 2.55.0 - a genuine,
# still-present git limitation, not a syntax mistake). That synthetic
# commit had no shared ancestry with the real Klipper3d/klipper
# or Arksine/moonraker history on GitHub, which made Moonraker's own
# `git merge-base --is-ancestor HEAD origin/<branch>` check permanently
# fail (return code 1) on every freshly-seeded device - HEAD could never
# be an ancestor of a real remote branch it shared no history with. This
# set `diverged=true` -> `has_recoverable_errors()=true` ->
# `is_valid()=false` (vendor/moonraker/moonraker/components/update_manager/
# git_deploy.py) permanently, blocking every real Klipper/Moonraker update.
#
# FIX: stop bundling/flattening entirely. Archive each vendor checkout's
# REAL `.git` directory (shallow boundary, real branch, real commits) plus
# its working tree as a plain tar file, with the local branch renamed to
# match Moonraker's hardcoded reserved-slot expectation ("master" - see
# BASE_CONFIG in update_manager/common.py, not configurable) and origin
# rewritten to the real public remote. On-device seeding (S04) then
# extracts the tar directly into place - no `git clone` at all, which is
# also strictly cheaper on this 208MB device than the clone-from-bundle
# step it replaces (plain tar extraction does no object repacking).
# vendor/klipper remains the official moving master checkout configured in
# manifests/dependencies.conf. The NebulaOS modules were staged separately,
# then added to both the rootfs copy and the offline seed archive without
# dirtying the upstream checkout.
echo "== NebulaOS Klipper extensions copied into mainline klippy/extras/ =="
# vendor/moonraker is already a full (non-shallow) clone of the official
# Arksine/moonraker repo with HEAD == origin/master, so it needs no branch
# surgery at all - only the same archive-instead-of-bundle treatment.
# make_seed_archive() itself lives in scripts/build/lib/make-seed-archive.sh,
# shared verbatim with tests/factory-seed-git-tests.sh so the tests exercise
# this exact function rather than a parallel reimplementation of its rules.
. "$SCRIPT_DIR/lib/make-seed-archive.sh"

echo "== creating offline factory-seed archives (Klipper, Moonraker) =="
# Real bug found live: $OVERLAY/opt/rosetteos-seeds/ is created directly by
# this script, not by 02-configure-buildroot.sh's tracked-template resync
# (which only mirrors scripts/build/overlay/) - so it is never cleaned
# between runs. A stale, now-uncompressed-format klipper.tar/moonraker.tar
# left over from before the .tar.gz switch sat alongside the new files and
# would have doubled the seed footprint in the packaged image. Always
# start from a clean directory here.
rm -rf "$OVERLAY/opt/rosetteos-seeds"
mkdir -p "$OVERLAY/opt/rosetteos-seeds"
# Keep a separate, non-hidden copy of the c_helper platform proof. The
# Klipper archive also carries the dotfile, but some device tar implementations
# have proved unreliable around hidden archive entries. S04 installs this
# sidecar explicitly into the persistent checkout after extraction.
cp "$CHELPER_VERDICT" \
	"$OVERLAY/opt/rosetteos-seeds/klipper-chelper-verdict.json"
cp "$VENDOR/klipper/klippy/chelper/c_helper.so" \
	"$OVERLAY/opt/rosetteos-seeds/c_helper.so"
touch -d "@2000000000" "$OVERLAY/opt/rosetteos-seeds/c_helper.so" 2>/dev/null || true
# Second, separate real bug found live, one layer deeper: Buildroot's own
# rootfs-overlay copy step (board overlay -> output/target/, and again
# into output/build/buildroot-fs/ext2/target/) is additive-only - it never
# deletes a file that existed in a PREVIOUS run's overlay but is absent
# from the current one. The rm -rf above only cleans the tracked-adjacent
# source; every earlier format this seed ever shipped (klipper.bundle/
# moonraker.bundle from the original synthetic-commit design, then the
# short-lived uncompressed klipper.tar/moonraker.tar) was still sitting in
# BOTH of Buildroot's own output copies, discovered only because the
# packaged rootfs.ext2 (fixed at 400M) failed to build with "Could not
# allocate block" despite the tracked overlay source alone being a
# reasonable ~46MB. Clean every one of this seed's known-historical
# filenames from both real Buildroot output locations here too, not just
# the tracked overlay - this is the actual root cause location, and must
# be revisited again if this seed's filenames ever change in the future.
for stale_dir in "$BUILDROOT_DIR/output/target/opt/rosetteos-seeds" \
                 "$BUILDROOT_DIR/output/build/buildroot-fs/ext2/target/opt/rosetteos-seeds" \
                 "$BUILDROOT_DIR/output/target/opt/nebulaos-seeds" \
                 "$BUILDROOT_DIR/output/build/buildroot-fs/ext2/target/opt/nebulaos-seeds"; do
	rm -f "$stale_dir/klipper.bundle" "$stale_dir/moonraker.bundle" \
	      "$stale_dir/klipper.tar" "$stale_dir/moonraker.tar" 2>/dev/null || true
done
klipper_origin="$KLIPPER_REPO"
klipper_seed_commit=$(make_seed_archive "$VENDOR/klipper" "$KLIPPER_BRANCH" \
	"$klipper_origin" "$OVERLAY/opt/rosetteos-seeds/klipper.tar.gz" "/lib/" \
	"$HOST_PYTHON3" "/opt/klipper" "$extra_stage" "$CHELPER_VERDICT")
klipper_is_shallow=$(git -C "$VENDOR/klipper" rev-parse --is-shallow-repository)

moonraker_origin="https://github.com/Arksine/moonraker.git"
moonraker_seed_commit=$(make_seed_archive "$VENDOR/moonraker" master \
	"$moonraker_origin" "$OVERLAY/opt/rosetteos-seeds/moonraker.tar.gz" "" \
	"$HOST_PYTHON3" "/opt/moonraker")
moonraker_is_shallow=$(git -C "$VENDOR/moonraker" rev-parse --is-shallow-repository)
mainsail_version=$(cat "$VENDOR/mainsail-dist/dist/.version" 2>/dev/null || echo "unknown")
build_date=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# 2026-08-08 (Clean-Update + Virgin Baseline mission, Phase 3): a derived,
# not manually-maintained, migration identifier - see
# docs/NEBULAOS_PERSISTENT_LIFECYCLE.md for the full design. Deliberately
# a content-derived hash, not a hand-incremented counter: a counter can be
# forgotten to bump (exactly the class of drift this whole mission exists
# to close), while this changes automatically and exactly when any
# component's expected persistent-app version actually changes, and
# compares with plain string equality on-device with no history lookup
# needed. Not a security hash - just a stable, cheap "does the installed
# generation match what THIS image expects" fingerprint.
PRINTER_DATA_CONFIG_SRC="$SCRIPT_DIR/overlay/opt/printer_data/config"
PRINTER_PROFILES_SRC="$SCRIPT_DIR/overlay/opt/rosetteos-seeds/printer_profiles"
migration_version=$(printf '%s' "${klipper_seed_commit}:${moonraker_seed_commit}:${GUPPYSCREEN_COMMIT:-unknown}" | sha256sum | cut -c1-16)
config_version=$(find "$PRINTER_DATA_CONFIG_SRC" "$PRINTER_PROFILES_SRC" -type f -exec sha256sum {} + 2>/dev/null | sort | sha256sum | cut -c1-16)
firmware_head=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo "unknown")

cat > "$OVERLAY/opt/rosetteos-seeds/seed-manifest.json" <<EOF
{
  "schema_version": 2,
  "build_date": "$build_date",
  "migration_version": "$migration_version",
  "config_version": "$config_version",
  "firmware_head": "$firmware_head",
  "guppyscreen_commit": "${GUPPYSCREEN_COMMIT:-unknown}",
  "seeds": {
    "klipper": {
      "format": "git_repo_archive_real_history",
      "file": "klipper.tar.gz",
      "repository": "$klipper_origin",
      "branch": "$KLIPPER_BRANCH",
      "seed_commit": "$klipper_seed_commit",
      "is_shallow": $klipper_is_shallow,
      "sha256": "$(sha256sum "$OVERLAY/opt/rosetteos-seeds/klipper.tar.gz" | cut -d' ' -f1)",
      "compatibility_level": 2,
      "note": "real upstream Klipper history; checkout follows the official master branch at build time"
    },
    "moonraker": {
      "format": "git_repo_archive_real_history",
      "file": "moonraker.tar.gz",
      "repository": "$moonraker_origin",
      "branch": "master",
      "seed_commit": "$moonraker_seed_commit",
      "is_shallow": $moonraker_is_shallow,
      "sha256": "$(sha256sum "$OVERLAY/opt/rosetteos-seeds/moonraker.tar.gz" | cut -d' ' -f1)",
      "compatibility_level": 2,
      "note": "full, non-shallow real history; HEAD equals official Arksine/moonraker origin/master at build time"
    },
    "mainsail": {
      "format": "directory_copy",
      "source_path": "/usr/share/mainsail",
      "version": "$mainsail_version",
      "compatibility_level": 2
    }
  }
}
EOF
if [ -f "$REPO_ROOT/manifests/apps.json" ]; then
	cp -a "$REPO_ROOT/manifests/apps.json" "$OVERLAY/opt/rosetteos-seeds/apps.json"
fi
echo "== factory seeds created: $(ls -la "$OVERLAY/opt/rosetteos-seeds/") =="

# Clean-Update + Virgin Baseline mission, Phase 6 (2026-08-08): a single,
# immutable, squashfs-resident record of exactly what this image IS -
# firmware tag/SHA, kernel/GuppyScreen commit IDs - read at runtime by
# the generated /opt/nebulaos-version.json (see docs/NEBULAOS_PERSISTENT_LIFECYCLE.md
# and docs/NEBULAOS_UPDATE_OWNERSHIP.md) and combined there with the
# LIVE Klipper checkout's own git state plus $SYSTEM/app-generation.json,
# so "what's actually running" is always queryable in one place rather
# than scattered across Moonraker's update_manager, this file, and manual
# SSH commands. firmware_tag intentionally allows an unclean git describe
# (e.g. "...-5-gdc241c8") - that just means this build is N commits past
# the last tag, a normal and honest thing to report, not an error.
#
# Virgin-Baseline Fix + Rebuild mission (2026-08-08): --match 'nebulaos-*'
# is required, not cosmetic - real bug found live in this mission's own
# fresh-build output: a vendor-dependency-archive release tag
# (v4l-utils-vendor-src-3b22ab0, created to carry a downloadable pinned
# source asset, not to mark a NebulaOS release) sits on this same linear
# main-branch history and is chronologically newer than every real
# baseline tag, so a plain `git describe --tags` picked IT as the
# "nearest" tag and reported a firmware_tag that looks like a dependency
# archive version, not a NebulaOS baseline. Every real baseline tag this
# project creates is named nebulaos-*; every asset-carrier tag (this one,
# wifi-firmware-v1.0.0) is not - restricting the match pattern is what
# actually fixes this, not a coincidence of current tag names.
firmware_tag=$(git -C "$REPO_ROOT" describe --tags --match 'rosetteos-*' --match 'nebulaos-*' 2>/dev/null || echo "unknown")
kernel_sha=$(git -C "$VENDOR/system" rev-parse HEAD 2>/dev/null || echo "unknown")
cat > "$OVERLAY/opt/rosetteos-version.json" <<EOF
{
  "build_date": "$build_date",
  "firmware_tag": "$firmware_tag",
  "firmware_sha": "$firmware_head",
  "kernel_sha": "$kernel_sha",
  "guppyscreen_sha": "${GUPPYSCREEN_COMMIT:-unknown}"
}
EOF
echo "== wrote /opt/rosetteos-version.json: $(cat "$OVERLAY/opt/rosetteos-version.json") =="

# Production optimization mission, Phase 11 (2026-07-30): pre-built venv
# seeds, so S04nebulaos-factory-seed can extract a ready-made virtualenv
# on first boot instead of running `python3 -m venv` live on this
# underpowered target (confirmed live: ~59s per venv, ~118s combined,
# the single largest first-boot cost this project has ever measured).
#
# Root cause found live: neither setup_klipper_env() nor
# setup_moonraker_env() passes --without-pip, so every venv creation also
# runs ensurepip - confirmed by inspecting a real, already-created venv on
# the device: lib/python3.11/site-packages/ contains ONLY pip, setuptools,
# and pkg_resources (nothing else - --system-site-packages correctly makes
# every real dependency invisible from that directory, inherited instead
# via the site-packages .pth mechanism), and that alone accounts for the
# entire venv's 25.5MB footprint. ensurepip's own wheel-unpack-and-install
# work is almost certainly the dominant cost of the ~59s, not the venv
# module's own (otherwise tiny) scaffolding.
#
# A venv's own files are not architecture-specific - pyvenv.cfg is plain
# text, activate* scripts are plain shell/text, and bin/python3 is just a
# symlink to an external interpreter, never a copied binary - so the same
# reasoning Phase 4 already used for bytecode precompilation applies here:
# $HOST_PYTHON3 (Buildroot's own host-built python3 - see below) can
# build the whole skeleton, which then only needs its symlinks/pyvenv.cfg/
# activate scripts repointed from this build's own paths to the real,
# fixed, always-identical target absolute paths (Buildroot always installs
# to the target /usr/bin/python3.X on this product), not literally
# recreated per-architecture.
if [ -n "$HOST_PYTHON3" ]; then
	TARGET_PY_VERSION="$TARGET_PY_FULL"
	TARGET_PY_ABS="/usr/bin/$TARGET_PY_DIR"
	build_venv_seed() {
		envname="$1"; envdir="$2"; seed_out="$3"
		seed_cache="$VENV_SEED_CACHE/$envname.tar.gz"
		fingerprint_file="$VENV_SEED_CACHE/$envname.fingerprint"
		seed_fingerprint=$(
			{
				printf 'seed_format=1\n'
				printf 'envname=%s\n' "$envname"
				printf 'envdir=%s\n' "$envdir"
				printf 'system_pin=%s\n' "$SYSTEM_PIN"
				printf 'target_python_version=%s\n' "$TARGET_PY_VERSION"
				printf 'target_python=%s\n' "$TARGET_PY_ABS"
				"$HOST_PYTHON3" --version 2>&1
				sha256sum "$HOST_PYTHON3"
			} | sha256sum | awk '{print $1}'
		)
		mkdir -p "$(dirname "$seed_out")"
		if [ -f "$fingerprint_file" ] && \
			[ "$(cat "$fingerprint_file")" = "$seed_fingerprint" ] && \
			[ -s "$seed_cache" ]; then
			cp "$seed_cache" "$seed_out"
			echo "== $envname venv seed inputs unchanged ($seed_fingerprint); reusing cached seed =="
			return 0
		fi

		echo "== $envname venv seed inputs changed or no successful fingerprint; rebuilding =="
		rm -rf "$WORK/venv-seed-$envname"
		if ! "$HOST_PYTHON3" -m venv --system-site-packages --without-pip \
			"$WORK/venv-seed-$envname" >/tmp/venv-seed-$envname.log 2>&1; then
			echo "WARNING: could not build $envname venv seed - S04rosetteos-factory-seed will fall back to on-device venv creation" >&2
			return 1
		fi
		vdir="$WORK/venv-seed-$envname"
		# Real target paths, not this build's own host-side paths.
		cat > "$vdir/pyvenv.cfg" <<PYVENVCFG
home = /usr/bin
include-system-site-packages = true
version = $TARGET_PY_VERSION
executable = $TARGET_PY_ABS
command = $TARGET_PY_ABS -m venv --system-site-packages --without-pip $envdir
PYVENVCFG
		rm -f "$vdir/bin/python" "$vdir/bin/python3" "$vdir/bin/$TARGET_PY_DIR"
		ln -s "$TARGET_PY_ABS" "$vdir/bin/$TARGET_PY_DIR"
		ln -s "$TARGET_PY_DIR" "$vdir/bin/python3"
		ln -s python3 "$vdir/bin/python"
		# The activate* scripts embed the venv's own absolute path -
		# rewrite from this build's throwaway $vdir to the real,
		# fixed target envdir these seeds will actually be extracted
		# into. Unused by this project's own S55klipper/S56moonraker
		# (which invoke bin/python3 directly, never source activate),
		# kept anyway for parity/manual debugging convenience since
			# they cost nothing extra to include.
			for af in activate activate.csh activate.fish; do
				[ -f "$vdir/bin/$af" ] && sed -i "s#$vdir#$envdir#g" "$vdir/bin/$af"
			done
		[ -f "$vdir/pyvenv.cfg" ] || return 1
		tar -C "$vdir" -czf "$seed_out" .
		if ! tar -tzf "$seed_out" | grep -qx './pyvenv.cfg'; then
			echo "WARNING: $envname venv seed archive is missing pyvenv.cfg" >&2
			return 1
		fi
		mkdir -p "$VENV_SEED_CACHE"
		cp "$seed_out" "$seed_cache"
		printf '%s\n' "$seed_fingerprint" > "$fingerprint_file"
	}
	if build_venv_seed klipper /usr/data/rosetteos/envs/klipper "$OVERLAY/opt/rosetteos-seeds/klipper-venv-seed.tar.gz"; then
		echo "== klipper venv seed created: $(ls -la "$OVERLAY/opt/rosetteos-seeds/klipper-venv-seed.tar.gz") =="
	fi
	if build_venv_seed moonraker /usr/data/rosetteos/envs/moonraker "$OVERLAY/opt/rosetteos-seeds/moonraker-venv-seed.tar.gz"; then
		echo "== moonraker venv seed created: $(ls -la "$OVERLAY/opt/rosetteos-seeds/moonraker-venv-seed.tar.gz") =="
	fi
else
	echo "WARNING: HOST_PYTHON3 not available - shipping without venv seeds, S04rosetteos-factory-seed will use its existing on-device venv creation path" >&2
fi

# Real bug found live (auto-updates-camera-complete mission addendum,
# 2026-07-28): S01persistent-datastore bind-mounts $NEBULAOS_ROOT/printer_data
# over /opt/printer_data unconditionally, very early in boot - so by the time
# any later boot stage could try to read /opt/printer_data/config as "the
# immutable default", it is already looking at the (possibly empty)
# persistent copy, not the real immutable content. The one thing that ever
# populated printer.cfg/moonraker.conf into a fresh persistent copy was a
# migration from a legacy /usr/data/rosetteos path, deleted as part of an
# earlier closure mission on the belief no fresh device would ever need it
# again - leaving genuinely no code path that seeds these files at all.
# Reproduced live: a truly wiped /usr/data/rosetteos/printer_data/config
# left Klipper and Moonraker crash-looping forever on FileNotFoundError.
#
# Fixed the same way klipper.tar.gz/moonraker.tar.gz already solve the
# identical shadowing problem: ship a second, dedicated immutable copy
# under /opt/rosetteos-seeds/ (never subject to any bind mount) that
# S02rosetteos-namespace can copy from into the real persistent location
# whenever it is missing. The actual config content itself is not
# authored here - it already exists, already deliberately stripped of
# development-machine calibration data (see printer.cfg's own header),
# at scripts/build/overlay/opt/printer_data/config/ - this just makes a
# second immutable copy of that same tracked content available at a path
# nothing ever mounts over.
echo "== creating printer_data config seed (Ender-3 V3 KE factory defaults) =="
PRINTER_DATA_CONFIG_SRC="$SCRIPT_DIR/overlay/opt/printer_data/config"
PRINTER_DATA_SEED_DEST="$OVERLAY/opt/rosetteos-seeds/printer_data-config"
if [ ! -f "$PRINTER_DATA_CONFIG_SRC/printer.cfg" ] || [ ! -f "$PRINTER_DATA_CONFIG_SRC/moonraker.conf" ]; then
	echo "FATAL: $PRINTER_DATA_CONFIG_SRC is missing printer.cfg or moonraker.conf - refusing to build a factory seed that would ship without them" >&2
	exit 1
fi
# Validate the tracked RosetteOS-owned config closure. frontend-controls.cfg
# provides the single frontend-required print-control sections; no external
# vendor configuration is part of the factory seed.
# Lightweight sanity checks on the tracked source, not a full Klipper
# config parser - catches the two concrete regressions this mission has
# actually hit: a real device's carried-over SAVE_CONFIG calibration block,
# and a required option left syntactically blank (confirmed live to hard-
# fail Klipper's config parser outright, see printer.cfg's own z_offset
# history).
if grep -q '^#\*# <---------------------- SAVE_CONFIG' "$PRINTER_DATA_CONFIG_SRC/printer.cfg"; then
	echo "FATAL: $PRINTER_DATA_CONFIG_SRC/printer.cfg contains a real SAVE_CONFIG block - refusing to ship development-machine calibration data as the factory default" >&2
	exit 1
fi
# A bare "key:" is only actually blank if nothing indented follows it on
# the next line - both printer.cfg/moonraker.conf's own INI-style parsers
# support multi-line list values this way (moonraker.conf's own
# trusted_clients/cors_domains use exactly this, confirmed live: a naive
# single-line grep for "key:$" flagged them as false positives the first
# time this check ran for real).
	blank_required_option() {
		# Klipper's gcode option is explicitly excluded because an empty
		# gcode body is valid for variable-only macros. Every other option present
		# without a value must either be a valid multiline list or fail.
		awk '
			{
				if (pending != "") {
					if ($0 !~ /^[ 	]/) { print pending; exit 1 }
					pending = ""
				}
				if ($0 ~ /^[a-zA-Z_][a-zA-Z0-9_]*:[[:space:]]*$/ && $0 !~ /^gcode:[[:space:]]*$/) { pending = $0 }
			}
			END { if (pending != "") { print pending; exit 1 } }
		' "$1"
	}
	for f in "$PRINTER_DATA_CONFIG_SRC/printer.cfg" "$PRINTER_DATA_CONFIG_SRC/moonraker.conf" "$PRINTER_DATA_CONFIG_SRC/macros/mainsail.cfg" "$PRINTER_DATA_CONFIG_SRC/macros/fluidd.cfg" "$PRINTER_DATA_CONFIG_SRC/hardware/nebula_pad.cfg"; do
		[ -f "$f" ] || continue
		if ! blank_required_option "$f" >/dev/null; then
			echo "FATAL: $f has an option present but syntactically blank (not a multi-line list value) - refusing to ship a factory default that fails to parse" >&2
			exit 1
		fi
	done

# Print-control config closure validation (mainline print-controls mission,
# 2026-07-29 - see docs/NEBULAOS_FRONTEND_PRINT_CONTROLS.md). Shared with
# tests/rosetteos-frontend-controls-validation-tests.sh via
# scripts/build/lib/validate-frontend-controls.sh, so the tests exercise
# this exact function rather than a parallel reimplementation.
. "$SCRIPT_DIR/lib/validate-frontend-controls.sh"
PRINTER_DATA_CONFIG_CLOSURE="$WORK/printer-data-config-closure.txt"
if ! frontend_controls_resolve_closure "$PRINTER_DATA_CONFIG_SRC" printer.cfg "$PRINTER_DATA_CONFIG_CLOSURE"; then
	echo "FATAL: could not resolve the printer_data config include closure" >&2
	exit 1
fi
if ! frontend_controls_validate_closure "$PRINTER_DATA_CONFIG_CLOSURE" /opt/printer_data/gcodes; then
	echo "FATAL: print-control config closure failed validation - see docs/NEBULAOS_FRONTEND_PRINT_CONTROLS.md" >&2
	exit 1
fi
echo "== print-control config closure validated: virtual_sdcard/pause_resume/display_status each defined exactly once, path correct, no duplicate or circular macros =="
for stale_dir in "$BUILDROOT_DIR/output/target/opt/rosetteos-seeds" \
                 "$BUILDROOT_DIR/output/build/buildroot-fs/ext2/target/opt/rosetteos-seeds" \
                 "$BUILDROOT_DIR/output/target/opt/nebulaos-seeds" \
                 "$BUILDROOT_DIR/output/build/buildroot-fs/ext2/target/opt/nebulaos-seeds"; do
	rm -rf "$stale_dir/printer_data-config" 2>/dev/null || true
done
rm -rf "$PRINTER_DATA_SEED_DEST"
mkdir -p "$PRINTER_DATA_SEED_DEST"
cp -a "$PRINTER_DATA_CONFIG_SRC/." "$PRINTER_DATA_SEED_DEST/"
cat > "$PRINTER_DATA_SEED_DEST/../printer-data-config-manifest.json" <<EOF
{
  "schema_version": 1,
  "printer": "Creality Ender-3 V3 KE",
  "build_date": "$build_date",
  "files": {
    "printer.cfg": "$(sha256sum "$PRINTER_DATA_SEED_DEST/printer.cfg" | cut -d' ' -f1)",
    "moonraker.conf": "$(sha256sum "$PRINTER_DATA_SEED_DEST/moonraker.conf" | cut -d' ' -f1)"
  }
}
EOF
echo "== printer_data config seed created: $(ls -la "$PRINTER_DATA_SEED_DEST/") =="

echo "== validating printer profiles repository =="
PRINTER_PROFILES_SRC="$SCRIPT_DIR/overlay/opt/rosetteos-seeds/printer_profiles"
if [ ! -d "$PRINTER_PROFILES_SRC" ]; then
	echo "FATAL: $PRINTER_PROFILES_SRC missing - printer profiles must exist" >&2
	exit 1
fi
for pdir in "$PRINTER_PROFILES_SRC"/*; do
	[ -d "$pdir" ] || continue
	pname=$(basename "$pdir")
	if [ ! -f "$pdir/profile.json" ] || [ ! -f "$pdir/printer.cfg" ]; then
		echo "FATAL: printer profile $pname missing profile.json or printer.cfg" >&2
		exit 1
	fi
done
echo "== validated $(ls -d "$PRINTER_PROFILES_SRC"/* | wc -l) printer profiles =="

for stale_dir in "$BUILDROOT_DIR/output/target/opt/rosetteos-seeds" \
                 "$BUILDROOT_DIR/output/build/buildroot-fs/ext2/target/opt/rosetteos-seeds" \
                 "$BUILDROOT_DIR/output/target/opt/nebulaos-seeds" \
                 "$BUILDROOT_DIR/output/build/buildroot-fs/ext2/target/opt/nebulaos-seeds"; do
	rm -rf "$stale_dir/printer_profiles" 2>/dev/null || true
done
rm -rf "$OVERLAY/opt/rosetteos-seeds/printer_profiles"
cp -a "$PRINTER_PROFILES_SRC" "$OVERLAY/opt/rosetteos-seeds/printer_profiles"

# Stage 04 creates these artifacts after stage 02 has already synchronized
# the tracked overlay. Buildroot's output/target sync is additive, so refresh
# the exact generated paths here; otherwise a previous klipper.tar.gz (and
# its previous Git commit) can remain in the image indefinitely.
for generated_path in klipper klipper-extensions rosetteos-seeds printer_data; do
	rm -rf "$BUILDROOT_DIR/output/target/opt/$generated_path"
	mkdir -p "$(dirname "$BUILDROOT_DIR/output/target/opt/$generated_path")"
	cp -a "$OVERLAY/opt/$generated_path" \
		"$BUILDROOT_DIR/output/target/opt/$generated_path"
done
packaged_klipper_seed=$(gzip -dc "$BUILDROOT_DIR/output/target/opt/rosetteos-seeds/klipper.tar.gz" 2>/dev/null \
	| tar -xOf - ./.git/refs/heads/$KLIPPER_BRANCH 2>/dev/null \
	| tr -d '[:space:]' || true)
[ "$packaged_klipper_seed" = "$KLIPPER_PIN" ] || {
	echo "FATAL: synchronized Klipper seed contains $packaged_klipper_seed, expected $KLIPPER_PIN" >&2
	echo "Refusing to package a stale or incompatible offline Klipper archive." >&2
	exit 1
}
echo "== generated Klipper runtime and seed paths synchronized into Buildroot output/target =="

echo "== app-stack overlay assembled at $OVERLAY =="
