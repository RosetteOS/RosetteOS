#!/bin/sh
# Build and stage the Ender-3 V3 KE, Ender-3 V3 SE, and Ender-3 V2 Neo printer-MCU firmwares.
#
# The source repository is deliberately thin: it fetches the exact upstream
# Klipper revision it owns, applies its explicit GD32F303 patch queue, builds
# twice, packs the raw image into Creality's format (when required), and validates the result.
#
# - Ender-3 V3 KE firmware is staged to the rootfs overlay for boot-time MCU upgrade.
# - Ender-3 V3 SE and Ender-3 V2 Neo firmwares are placed exclusively into build artifacts
#   (and packaged by package-deployment.sh) for user SD-card flashing, and are NOT included in rootfs.
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
MANIFEST="$REPO_ROOT/manifests/dependencies.conf"
. "$MANIFEST"

VENDOR="$REPO_ROOT/vendor"
MCU_REPO_DIR="$VENDOR/klipper-mcu"
BUILDROOT_DIR="$VENDOR/system/buildroot"
OVERLAY="$BUILDROOT_DIR/board/halley5-rosetteos-overlay"
WORK="$REPO_ROOT/build-work/klipper-mcu"
MCU_BUILD="$WORK/klipper-src"
ARTIFACT_REL="artifacts/nebulaos-firmware"
GENERATED_ARTIFACTS="$MCU_REPO_DIR/$ARTIFACT_REL"
MCU_CACHE="$WORK/cache"
MCU_CACHE_FINGERPRINT="$MCU_CACHE/fingerprint"
TOOLCHAIN_ROOT="$WORK/arm-gnu-toolchain"
TOOLCHAIN_CACHE="$REPO_ROOT/vendor-downloads"

SE_CONFIG="$SCRIPT_DIR/configs/ender3-v3-se.defconfig"
if [ ! -f "$SE_CONFIG" ] && [ -f "$MCU_REPO_DIR/configs/ender3-v3-se.defconfig" ]; then
	SE_CONFIG="$MCU_REPO_DIR/configs/ender3-v3-se.defconfig"
fi

NEO_CONFIG="$SCRIPT_DIR/configs/ender3-v2-neo.defconfig"
if [ ! -f "$NEO_CONFIG" ] && [ -f "$MCU_REPO_DIR/configs/ender3-v2-neo.defconfig" ]; then
	NEO_CONFIG="$MCU_REPO_DIR/configs/ender3-v2-neo.defconfig"
fi

[ -d "$MCU_REPO_DIR/.git" ] || {
	echo "FATAL: vendor/klipper-mcu is missing - run 00-fetch-vendor-sources.sh first" >&2
	exit 1
}
[ "$(git -C "$MCU_REPO_DIR" rev-parse HEAD)" = "$MCU_PIN" ] || {
	echo "FATAL: vendor/klipper-mcu is not at pinned commit $MCU_PIN" >&2
	exit 1
}

mkdir -p "$WORK" "$TOOLCHAIN_CACHE"
TOOLCHAIN_BIN=$(TOOLCHAIN_CACHE_DIR="$TOOLCHAIN_CACHE" \
	"$MCU_REPO_DIR/scripts/install-toolchain.sh" "$TOOLCHAIN_ROOT")
export PATH="$TOOLCHAIN_BIN:$PATH"

MCU_UPSTREAM_SHA=$(sed -n 's/^KLIPPER_SHA=//p' "$MCU_REPO_DIR/upstream.lock")
[ -n "$MCU_UPSTREAM_SHA" ] || {
	echo "FATAL: vendor MCU upstream.lock does not define KLIPPER_SHA" >&2
	exit 1
}

# The vendor repository is pinned, but keep the build inputs explicit so a
# build-script, patch, toolchain, or packaging-policy change cannot reuse an
# old firmware image accidentally.
MCU_FINGERPRINT=$(
	{
		echo "mcu_pin=$MCU_PIN"
		echo "upstream_klipper_sha=$MCU_UPSTREAM_SHA"
		echo "metadata_version=$MCU_METADATA_VERSION"
		echo "expected_hw_id=$MCU_EXPECTED_HW_ID"
	sha256sum "$SCRIPT_DIR/build-mcu-firmware.sh" "$MCU_REPO_DIR/upstream.lock" \
		"$MCU_REPO_DIR/configs/ender3-v3-ke.defconfig" \
		"$SE_CONFIG" \
		"$NEO_CONFIG" \
		"$MCU_REPO_DIR/patches/series"
	find "$MCU_REPO_DIR/scripts" "$MCU_REPO_DIR/patches" -type f -print | sort |
		while IFS= read -r file; do sha256sum "$file"; done
	sha256sum "$TOOLCHAIN_BIN/arm-none-eabi-gcc"
	} | sha256sum | awk '{print $1}'
)

ARTIFACTS="$GENERATED_ARTIFACTS"
MCU_REBUILD=1
if [ -f "$MCU_CACHE_FINGERPRINT" ] && [ "$(cat "$MCU_CACHE_FINGERPRINT")" = "$MCU_FINGERPRINT" ] \
	&& [ -s "$MCU_CACHE/klipper.bin" ] \
	&& [ -s "$MCU_CACHE/klipper-creality.bin" ] \
	&& [ -s "$MCU_CACHE/klipper.elf" ] \
	&& [ -s "$MCU_CACHE/klipper.config" ] \
	&& [ -s "$MCU_CACHE/Ender3V3SE_klipper.bin" ] \
	&& [ -s "$MCU_CACHE/Ender3V2Neo_klipper.bin" ] \
	&& [ -s "$MCU_CACHE/validator-report.txt" ]; then
	ARTIFACTS="$MCU_CACHE"
	MCU_REBUILD=0
	echo "== reusing printer MCU firmware from matching build cache =="
fi

build_mcu_target() {
	_target_build_dir="$1"
	_target_artifact_dir="$2"
	_target_metadata_ver="$3"
	_target_config_file="$4"

	mkdir -p "$_target_artifact_dir"
	cp "$_target_config_file" "$_target_build_dir/.config"
	(
		cd "$_target_build_dir"
		python3 lib/kconfiglib/olddefconfig.py src/Kconfig >/dev/null
		make clean >/dev/null
		make >/dev/null
		cp out/klipper.elf "$_target_artifact_dir/klipper.elf"
		cp out/klipper.bin "$_target_artifact_dir/klipper.bin"
		cp .config "$_target_artifact_dir/klipper.config"
	)

	if [ "$_target_metadata_ver" != "none" ] && [ "$_target_metadata_ver" != "raw" ] && [ -n "$_target_metadata_ver" ]; then
		python3 "$MCU_REPO_DIR/tools/creality_packer.py" "$_target_artifact_dir/klipper.bin" "$_target_artifact_dir/klipper-creality.bin" \
			--version "$_target_metadata_ver"
	fi
}

if [ "$MCU_REBUILD" -eq 1 ]; then
	rm -rf "$MCU_BUILD" "$GENERATED_ARTIFACTS"
	mkdir -p "$GENERATED_ARTIFACTS/ke/pass1" "$GENERATED_ARTIFACTS/ke/pass2"
	mkdir -p "$GENERATED_ARTIFACTS/se/pass1" "$GENERATED_ARTIFACTS/se/pass2"
	mkdir -p "$GENERATED_ARTIFACTS/neo/pass1" "$GENERATED_ARTIFACTS/neo/pass2"

	echo "== fetching pinned upstream Klipper for printer MCU =="
	"$MCU_REPO_DIR/scripts/fetch-upstream.sh" "$MCU_BUILD"
	echo "== applying pinned printer MCU patch queue =="
	"$MCU_REPO_DIR/scripts/apply-patches.sh" "$MCU_BUILD"

	echo "== building Ender-3 V3 KE printer MCU candidate twice =="
	build_mcu_target "$MCU_BUILD" "$GENERATED_ARTIFACTS/ke/pass1" "$MCU_METADATA_VERSION" "$MCU_REPO_DIR/configs/ender3-v3-ke.defconfig"
	build_mcu_target "$MCU_BUILD" "$GENERATED_ARTIFACTS/ke/pass2" "$MCU_METADATA_VERSION" "$MCU_REPO_DIR/configs/ender3-v3-ke.defconfig"
	cmp -s "$GENERATED_ARTIFACTS/ke/pass1/klipper.bin" "$GENERATED_ARTIFACTS/ke/pass2/klipper.bin" || {
		echo "FATAL: Ender-3 V3 KE printer MCU raw klipper.bin is not reproducible across two builds" >&2
		exit 1
	}

	cp "$GENERATED_ARTIFACTS/ke/pass2/klipper.bin" "$GENERATED_ARTIFACTS/klipper.bin"
	cp "$GENERATED_ARTIFACTS/ke/pass2/klipper-creality.bin" "$GENERATED_ARTIFACTS/klipper-creality.bin"
	cp "$GENERATED_ARTIFACTS/ke/pass2/klipper.elf" "$GENERATED_ARTIFACTS/klipper.elf"
	cp "$GENERATED_ARTIFACTS/ke/pass2/klipper.config" "$GENERATED_ARTIFACTS/klipper.config"

	echo "== building Ender-3 V3 SE printer MCU candidate twice =="
	build_mcu_target "$MCU_BUILD" "$GENERATED_ARTIFACTS/se/pass1" "003" "$SE_CONFIG"
	build_mcu_target "$MCU_BUILD" "$GENERATED_ARTIFACTS/se/pass2" "003" "$SE_CONFIG"
	cmp -s "$GENERATED_ARTIFACTS/se/pass1/klipper.bin" "$GENERATED_ARTIFACTS/se/pass2/klipper.bin" || {
		echo "FATAL: Ender-3 V3 SE printer MCU raw klipper.bin is not reproducible across two builds" >&2
		exit 1
	}

	cp "$GENERATED_ARTIFACTS/se/pass2/klipper.bin" "$GENERATED_ARTIFACTS/klipper-v3-se-raw.bin"
	cp "$GENERATED_ARTIFACTS/se/pass2/klipper-creality.bin" "$GENERATED_ARTIFACTS/Ender3V3SE_klipper.bin"
	cp "$GENERATED_ARTIFACTS/se/pass2/klipper.elf" "$GENERATED_ARTIFACTS/klipper-v3-se.elf"
	cp "$GENERATED_ARTIFACTS/se/pass2/klipper.config" "$GENERATED_ARTIFACTS/klipper-v3-se.config"

	echo "== building Ender-3 V2 Neo printer MCU candidate twice =="
	build_mcu_target "$MCU_BUILD" "$GENERATED_ARTIFACTS/neo/pass1" "none" "$NEO_CONFIG"
	build_mcu_target "$MCU_BUILD" "$GENERATED_ARTIFACTS/neo/pass2" "none" "$NEO_CONFIG"
	cmp -s "$GENERATED_ARTIFACTS/neo/pass1/klipper.bin" "$GENERATED_ARTIFACTS/neo/pass2/klipper.bin" || {
		echo "FATAL: Ender-3 V2 Neo printer MCU raw klipper.bin is not reproducible across two builds" >&2
		exit 1
	}

	cp "$GENERATED_ARTIFACTS/neo/pass2/klipper.bin" "$GENERATED_ARTIFACTS/Ender3V2Neo_klipper.bin"
	cp "$GENERATED_ARTIFACTS/neo/pass2/klipper.elf" "$GENERATED_ARTIFACTS/klipper-v2-neo.elf"
	cp "$GENERATED_ARTIFACTS/neo/pass2/klipper.config" "$GENERATED_ARTIFACTS/klipper-v2-neo.config"
fi

echo "== validating packaged Ender-3 V3 KE printer MCU candidate =="
python3 "$MCU_REPO_DIR/tools/creality_validator.py" target \
	"$ARTIFACTS/klipper-creality.bin" \
	"$ARTIFACTS/klipper.elf" \
	"$ARTIFACTS/klipper.config" \
	> "$ARTIFACTS/validator-report.txt.tmp"
mv "$ARTIFACTS/validator-report.txt.tmp" "$ARTIFACTS/validator-report.txt"
cat "$ARTIFACTS/validator-report.txt"

echo "== validating packaged Ender-3 V3 SE printer MCU candidate =="
python3 "$MCU_REPO_DIR/tools/creality_validator.py" format \
	"$ARTIFACTS/Ender3V3SE_klipper.bin" \
	--expect-type mcu0

# Assert that generated images agree with expected metadata versions.
INSPECTED_VERSION=$(python3 "$MCU_REPO_DIR/tools/creality_flash.py" inspect \
	"$ARTIFACTS/klipper-creality.bin" |
	sed -n "s/^type=b'mcu0' version=b'\\([0-9][0-9][0-9]\\)'.*/\\1/p")
[ "$INSPECTED_VERSION" = "$MCU_METADATA_VERSION" ] || {
	echo "FATAL: packaged KE MCU metadata version is '$INSPECTED_VERSION', expected '$MCU_METADATA_VERSION'" >&2
	exit 1
}

SE_INSPECTED_VERSION=$(python3 "$MCU_REPO_DIR/tools/creality_flash.py" inspect \
	"$ARTIFACTS/Ender3V3SE_klipper.bin" |
	sed -n "s/^type=b'mcu0' version=b'\\([0-9][0-9][0-9]\\)'.*/\\1/p")
[ "$SE_INSPECTED_VERSION" = "003" ] || {
	echo "FATAL: packaged SE MCU metadata version is '$SE_INSPECTED_VERSION', expected '003'" >&2
	exit 1
}

# Keep the runtime identity gate coupled to the configured hardware target.
# The upstream flasher has an exact default allow-list; fail the build if a
# future pinned repository changes that default without a manifest review.
python3 - "$MCU_REPO_DIR/tools/creality_flash.py" "$MCU_EXPECTED_HW_ID" <<'PY'
import re
import sys

source = open(sys.argv[1], encoding="utf-8").read()
expected = sys.argv[2]
match = re.search(r'DEFAULT_ALLOWED_HW_IDS\s*=\s*\(([^)]*)\)', source)
if not match or re.findall(r'"([^"]+)"', match.group(1)) != [expected]:
    raise SystemExit("FATAL: upstream flasher default hardware allow-list does not match MCU_EXPECTED_HW_ID")
PY

if [ "$MCU_REBUILD" -eq 1 ]; then
	rm -rf "$MCU_CACHE"
	mkdir -p "$MCU_CACHE"
	for artifact in klipper.bin klipper-creality.bin klipper.elf klipper.config validator-report.txt Ender3V3SE_klipper.bin Ender3V2Neo_klipper.bin; do
		cp "$GENERATED_ARTIFACTS/$artifact" "$MCU_CACHE/$artifact"
	done
	printf '%s\n' "$MCU_FINGERPRINT" > "$MCU_CACHE_FINGERPRINT"
fi

# 1. Stage KE MCU firmware to rootfs overlay (for auto-upgrade)
MCU_DEST="$OVERLAY/opt/rosetteos/mcu"
rm -rf "$MCU_DEST"
mkdir -p "$MCU_DEST/tools"
cp "$ARTIFACTS/klipper-creality.bin" "$MCU_DEST/"
cp "$ARTIFACTS/klipper.bin" "$MCU_DEST/"
cp "$ARTIFACTS/klipper.elf" "$MCU_DEST/"
cp "$ARTIFACTS/klipper.config" "$MCU_DEST/"
cp "$ARTIFACTS/validator-report.txt" "$MCU_DEST/"
for tool in creality_flash.py creality_validator.py creality_packer.py \
	stage4_first_flash.py; do
	cp "$MCU_REPO_DIR/tools/$tool" "$MCU_DEST/tools/$tool"
done
find "$MCU_DEST" -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true

MCU_IMAGE_SHA256=$(sha256sum "$MCU_DEST/klipper-creality.bin" | awk '{print $1}')
MCU_SOURCE_COMMIT=$(git -C "$MCU_REPO_DIR" rev-parse HEAD)
{
	echo "image=klipper-creality.bin"
	echo "image_sha256=$MCU_IMAGE_SHA256"
	echo "metadata_version=$MCU_METADATA_VERSION"
	echo "expected_hw_id=$MCU_EXPECTED_HW_ID"
	echo "repository=$MCU_REPO"
	echo "repository_commit=$MCU_SOURCE_COMMIT"
	echo "upstream_klipper_sha=$MCU_UPSTREAM_SHA"
} > "$MCU_DEST/manifest.env"

echo "== printer MCU artifacts staged at $MCU_DEST (sha256 $MCU_IMAGE_SHA256) =="

# 2. Stage Ender-3 V3 SE & V2 Neo MCU firmwares exclusively to build artifacts (excluded from rootfs overlay)
IMAGE_ARTIFACTS_DIR="$REPO_ROOT/artifacts/buildroot-halley5-v30-image"
mkdir -p "$IMAGE_ARTIFACTS_DIR"
cp "$ARTIFACTS/Ender3V3SE_klipper.bin" "$IMAGE_ARTIFACTS_DIR/Ender3V3SE_klipper.bin"
SE_IMAGE_SHA256=$(sha256sum "$IMAGE_ARTIFACTS_DIR/Ender3V3SE_klipper.bin" | awk '{print $1}')
echo "== Ender-3 V3 SE MCU firmware staged at $IMAGE_ARTIFACTS_DIR/Ender3V3SE_klipper.bin (sha256 $SE_IMAGE_SHA256, excluded from rootfs) =="

cp "$ARTIFACTS/Ender3V2Neo_klipper.bin" "$IMAGE_ARTIFACTS_DIR/Ender3V2Neo_klipper.bin"
NEO_IMAGE_SHA256=$(sha256sum "$IMAGE_ARTIFACTS_DIR/Ender3V2Neo_klipper.bin" | awk '{print $1}')
echo "== Ender-3 V2 Neo MCU firmware staged at $IMAGE_ARTIFACTS_DIR/Ender3V2Neo_klipper.bin (sha256 $NEO_IMAGE_SHA256, excluded from rootfs) =="
