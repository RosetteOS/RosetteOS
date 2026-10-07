#!/bin/sh
# Phase 6 packaging (baseline-canonicalization-and-z_compensate-deployment
# mission). Assembles a complete, self-contained deployment package: images,
# configs, decompiled DTB, manifest, checksums, baseline-difference report,
# and deployment/rollback instructions. Does NOT flash anything.
#
# Usage: sh scripts/build/package-deployment.sh [package-root]

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
ARTIFACT_DIR="$REPO_ROOT/artifacts/buildroot-halley5-v30-image"
PACKAGE_ROOT="${1:-$REPO_ROOT/build-work/deploy-packages}"

# Final Closure mission (2026-08-15): used to source manifests/
# dependencies.conf here for PELLCORP_K1_BASH_BUILD_IMAGE, needed for the
# DTB decompile below - that decompile now runs against a native `dtc` (see
# build-env/Dockerfile), no container reference needed, and no other field
# from that manifest is read anywhere in this file (confirmed: no other
# manifest variable appears below). Removed rather than left as unused,
# silently-passing dead weight.
for required in "$ARTIFACT_DIR/xImage" "$ARTIFACT_DIR/rootfs.squashfs" "$ARTIFACT_DIR/build-manifest.txt" "$REPO_ROOT/baseline-difference.txt"; do
	[ -f "$required" ] || { echo "FATAL: $required not found - run 05-final-build.sh and baseline-difference-gate.sh first" >&2; exit 1; }
done

TS=$(date -u +%Y%m%dT%H%M%SZ)
PKG_DIR="$PACKAGE_ROOT/rosetteos-deployment-${TS}"
mkdir -p "$PKG_DIR"

cp "$ARTIFACT_DIR/xImage" "$PKG_DIR/xImage"
cp "$ARTIFACT_DIR/rootfs.squashfs" "$PKG_DIR/rootfs.squashfs"
cp "$ARTIFACT_DIR/kernel.config" "$PKG_DIR/kernel.config"
cp "$ARTIFACT_DIR/halley5_v30.dts" "$PKG_DIR/halley5_v30.dts"
cp "$ARTIFACT_DIR/buildroot.config" "$PKG_DIR/buildroot.config"
cp "$ARTIFACT_DIR/build-manifest.txt" "$PKG_DIR/build-manifest.txt"
cp "$REPO_ROOT/baseline-difference.txt" "$PKG_DIR/baseline-difference.txt"

if [ -f "$ARTIFACT_DIR/Ender3V3SE_klipper.bin" ]; then
	echo "== copying Ender-3 V3 SE MCU firmware to deployment package =="
	cp "$ARTIFACT_DIR/Ender3V3SE_klipper.bin" "$PKG_DIR/Ender3V3SE_klipper.bin"
fi

if [ -f "$ARTIFACT_DIR/Ender3V2Neo_klipper.bin" ]; then
	echo "== copying Ender-3 V2 Neo MCU firmware to deployment package =="
	cp "$ARTIFACT_DIR/Ender3V2Neo_klipper.bin" "$PKG_DIR/Ender3V2Neo_klipper.bin"
fi

echo "== decompiling DTB for package inclusion =="
DTB_SRC="$REPO_ROOT/vendor/system/buildroot/output/build/linux-custom/module_drivers/dts/x2000/halley5_v30.dtb"
if [ -f "$DTB_SRC" ]; then
	cp "$DTB_SRC" "$PKG_DIR/halley5_v30.dtb"
	{ command -v dtc >/dev/null 2>&1 && dtc -I dtb -O dts "$PKG_DIR/halley5_v30.dtb" -o "$PKG_DIR/halley5_v30.decompiled.dts" 2>/dev/null || echo "dtc not available in this environment" >&2; } \
		|| echo "WARNING: DTB decompile failed - halley5_v30.dtb (binary) still included, halley5_v30.dts (source) is the authoritative reference"
else
	echo "WARNING: $DTB_SRC not found - shipping source DTS only"
fi

echo "== building SWUpdate package (.swu) =="
sh "$SCRIPT_DIR/package-swu.sh" "$PKG_DIR" "$TS"

echo "== generating SHA256SUMS =="
(cd "$PKG_DIR" && sha256sum xImage rootfs.squashfs kernel.config halley5_v30.dts buildroot.config build-manifest.txt $( [ -f halley5_v30.dtb ] && echo halley5_v30.dtb ) $( [ -f Ender3V3SE_klipper.bin ] && echo Ender3V3SE_klipper.bin ) $( [ -f Ender3V2Neo_klipper.bin ] && echo Ender3V2Neo_klipper.bin ) $(ls *.swu 2>/dev/null) > SHA256SUMS)

cat > "$PKG_DIR/DEPLOYMENT_INSTRUCTIONS.md" <<'EOF'
# Deployment instructions

Target: Ender-3 V3 KE Nebula Pad, custom slot only (kernel2/rootfs2).
Never write the stock slot (kernel/rootfs).

## Preconditions (all must be true)

1. Confirm device identity: `ssh root@<ip> "cat /proc/cmdline"` - board must be
   the expected Ender-3 V3 KE.
2. Printer idle: no active/paused print, `idle_timeout.state == "Idle"`,
   `print_stats.state == "standby"`.
3. Heater targets zero: `extruder.target == 0`, `heater_bed.target == 0`.
4. Device currently booted from the STOCK slot (`root=/dev/mmcblk0p7` in
   `/proc/cmdline`) - the custom slot (mmcblk0p6/p8) must be genuinely idle
   before flashing it. If currently on custom, cycle to stock first:
   `sh -c '. /etc/ota_marker.sh; write_ota_marker "ota:kernel"'` then `reboot`,
   and re-verify `/proc/cmdline` after the device comes back.
5. This package's SHA256SUMS verified locally before transfer.

## Flash sequence

```sh
scp SHA256SUMS xImage rootfs.squashfs build-manifest.txt root@<ip>:/usr/data/deploy-staging/
ssh root@<ip> 'cd /usr/data/deploy-staging && sha256sum -c SHA256SUMS'
scp scripts/flash-spare-slot.sh root@<ip>:/tmp/
ssh root@<ip> 'sh /tmp/flash-spare-slot.sh --check-only /usr/data/deploy-staging/xImage /usr/data/deploy-staging/rootfs.squashfs /usr/data/deploy-staging/build-manifest.txt'
# review --check-only output carefully before proceeding
ssh root@<ip> 'nohup sh /tmp/flash-spare-slot.sh /usr/data/deploy-staging/xImage /usr/data/deploy-staging/rootfs.squashfs /usr/data/deploy-staging/build-manifest.txt > /usr/data/flash.log 2>&1 < /dev/null &'
# poll /usr/data/flash.log for completion - a ~100MB write+verify takes several minutes
```

## After a verified-good write

```sh
ssh root@<ip> "sh -c '. /etc/ota_marker.sh; write_ota_marker \"ota:kernel2\"'"
ssh root@<ip> 'reboot'
# re-verify /proc/cmdline shows mmcblk0p8 after the device comes back
```

## Do not command during or after flashing

G28, G29, BED_MESH_CALIBRATE, PROBE_CALIBRATE, CRTENSE_NOZZLE_CLEAR,
NOZZLE_CLEAR, SAFE_MOVE_Z, Z_OFFSET_CALIBRATION, Z_OFFSET_APPLY_PROBE,
SAVE_CONFIG, any G0/G1, any heater command, any print.

## Ender-3 V3 SE MCU Firmware Flashing (SD Card)

If connecting the Nebula Pad to an Ender-3 V3 SE printer (GD32F303 mainboard):
1. Format a micro-SD card (<=32GB) with FAT32 and 4096-byte cluster size.
2. Copy `Ender3V3SE_klipper.bin` to the root of the SD card.
   (Note: The bootloader checks filename against the previously flashed binary. If reflashing, rename to a unique name e.g. `firmware_01.bin`).
3. Turn off the printer.
4. Insert the SD card into the Ender-3 V3 SE mainboard's SD card slot.
5. Turn on the printer and wait ~15-20 seconds.
6. Switch the active profile on Nebula Pad to Ender-3 V3 SE via GuppyScreen Settings -> Printer Model (or `rosetteos-profile set creality-ender3-v3-se`).

## Ender-3 V2 Neo MCU Firmware Flashing (SD Card)

If connecting the Nebula Pad to an Ender-3 V2 Neo printer (STM32F103 4.2.2 / 4.2.7 mainboard):
1. Format a micro-SD card (<=32GB) with FAT32 and 4096-byte cluster size.
2. Copy `Ender3V2Neo_klipper.bin` to the root of the SD card.
   (Note: The bootloader checks filename against the previously flashed binary. If reflashing, rename to a unique name e.g. `firmware_01.bin`).
3. Turn off the printer.
4. Insert the SD card into the Ender-3 V2 Neo mainboard's SD card slot.
5. Turn on the printer and wait ~15-20 seconds.
6. Switch the active profile on Nebula Pad to Ender-3 V2 Neo via GuppyScreen Settings -> Printer Model (or `rosetteos-profile set creality-ender3-v2-neo`).
EOF

cat > "$PKG_DIR/ROLLBACK_INSTRUCTIONS.md" <<'EOF'
# Rollback instructions

If post-flash verification fails at any point:

1. Cycle back to stock (if not already there):
   `sh -c '. /etc/ota_marker.sh; write_ota_marker "ota:kernel"'` then `reboot`.
   Stock was never written by this deployment - it remains the safe fallback.
2. The custom slot (kernel2/rootfs2) now has the NEW image, which may be the
   problem. To restore the PREVIOUS known-good custom image, re-run the flash
   sequence above with the previous package's xImage/rootfs.squashfs instead
   (keep prior packages under build-work/deploy-packages/ until a new one is
   confirmed good - never delete the immediately-prior package).
3. If the custom slot is suspected corrupted (not just "wrong content but
   bootable"), stay on stock and investigate before attempting another
   custom-slot write - do not repeatedly flash an already-failing target.
4. GuppyScreen/Klipper-only rollback (no reflash needed, if only those
   userspace pieces need reverting and the kernel/DTS are fine): see this
   session's own deployment-evidence rollback.sh for the plain-scp-based
   z_compensate.py/guppyscreen-binary rollback (does not apply if a squashfs
   reflash already happened, since GuppyScreen's binary is read-only squashfs
   content again after that point - only the pre-reflash rollback path was
   plain-scp; post-reflash requires another full image rollback per step 2).
EOF

echo "== package complete: $PKG_DIR =="
ls -la "$PKG_DIR"
