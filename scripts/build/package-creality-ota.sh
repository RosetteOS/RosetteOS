#!/bin/sh
#
# Packages RosetteOS into stock CrealityOS-compatible encrypted 7z OTA (.img) files.
# Generates firmware updates for:
#   - Ender-3 V3 KE (Target F005)
#   - Creality Nebula Smart Kit / Nebula Pad (Target NEBULA)
#
# Usage: sh scripts/build/package-creality-ota.sh [output-dir] [target] [version]
#

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
ARTIFACT_DIR="$REPO_ROOT/artifacts/buildroot-halley5-v30-image"

OUTPUT_DIR="${1:-$ARTIFACT_DIR}"
TARGET="${2:-all}"
VERSION="${3:-}"

# Source dependency pins if present, allowing environment overrides
_OVERRIDE_OTA_VER="${CREALITY_OTA_VERSION:-}"
_OVERRIDE_KE_ZERO_SHA="${CREALITY_KE_ZERO_BIN_SHA256:-}"
_OVERRIDE_NEBULA_ZERO_SHA="${CREALITY_NEBULA_ZERO_BIN_SHA256:-}"
MANIFEST="$REPO_ROOT/manifests/dependencies.conf"
if [ -f "$MANIFEST" ]; then
	. "$MANIFEST"
fi
[ -n "$_OVERRIDE_OTA_VER" ] && CREALITY_OTA_VERSION="$_OVERRIDE_OTA_VER"
[ -n "$_OVERRIDE_KE_ZERO_SHA" ] && CREALITY_KE_ZERO_BIN_SHA256="$_OVERRIDE_KE_ZERO_SHA"
[ -n "$_OVERRIDE_NEBULA_ZERO_SHA" ] && CREALITY_NEBULA_ZERO_BIN_SHA256="$_OVERRIDE_NEBULA_ZERO_SHA"

if [ -z "$VERSION" ]; then
	VERSION="${CREALITY_OTA_VERSION:-1.1.0.34}"
fi

KERNEL_IMAGE="${KERNEL_IMAGE:-$ARTIFACT_DIR/xImage}"
ROOTFS_IMAGE="${ROOTFS_IMAGE:-$ARTIFACT_DIR/rootfs.squashfs}"

if [ ! -f "$KERNEL_IMAGE" ]; then
	echo "FATAL: kernel image not found at $KERNEL_IMAGE" >&2
	exit 1
fi

if [ ! -f "$ROOTFS_IMAGE" ]; then
	echo "FATAL: rootfs image not found at $ROOTFS_IMAGE" >&2
	exit 1
fi

# Ensure 7z or py7zr is available
if ! command -v 7z >/dev/null 2>&1; then
	if ! python3 -c "import py7zr" >/dev/null 2>&1; then
		if command -v apt-get >/dev/null 2>&1; then
			echo "Installing p7zip-full for OTA packaging..."
			apt-get update -qq && apt-get install -y -qq p7zip-full
		elif command -v pip3 >/dev/null 2>&1; then
			pip3 install --quiet py7zr || true
		fi
	fi
fi

# Function to fetch and verify zero asset
ensure_zero_bin() {
	_target_name="$1"
	_dest_file="$2"
	_url="$3"
	_expected_sha="$4"

	if [ -f "$_dest_file" ]; then
		_actual_sha=$(sha256sum "$_dest_file" | awk '{print $1}')
		if [ -z "$_expected_sha" ] || [ "$_actual_sha" = "$_expected_sha" ]; then
			return 0
		else
			echo "WARN: Checksum mismatch on $_dest_file, re-fetching..."
		fi
	fi

	echo "== Fetching $_target_name RTOS firmware from $_url =="
	mkdir -p "$(dirname "$_dest_file")"
	if command -v curl >/dev/null 2>&1; then
		curl -fSL --retry 3 --retry-delay 2 "$_url" -o "$_dest_file"
	elif command -v wget >/dev/null 2>&1; then
		wget -q --tries=3 "$_url" -O "$_dest_file"
	else
		python3 -c "
import urllib.request
urllib.request.urlretrieve('$_url', '$_dest_file')
"
	fi

	if [ -n "$_expected_sha" ]; then
		_actual_sha=$(sha256sum "$_dest_file" | awk '{print $1}')
		if [ "$_actual_sha" != "$_expected_sha" ]; then
			echo "FATAL: $_target_name checksum mismatch: expected $_expected_sha, got $_actual_sha" >&2
			exit 1
		fi
	fi
}

KE_ZERO_PATH="${KE_ZERO_BIN:-$REPO_ROOT/assets/zero.bin}"
NEBULA_ZERO_PATH="${NEBULA_ZERO_BIN:-$REPO_ROOT/assets/zero_nebula.bin}"

case "$TARGET" in
	ke|all)
		ensure_zero_bin "Ender-3 V3 KE" "$KE_ZERO_PATH" \
			"${CREALITY_KE_ZERO_BIN_URL:-https://github.com/RosetteOS/Recovery/raw/main/assets/zero.bin}" \
			"${CREALITY_KE_ZERO_BIN_SHA256:-2a6b8fcdc7acb73eb7c0fe660906c94989b9f1fb2a3436f3c897766e18dfc340}"
		;;
esac

case "$TARGET" in
	nebula|all)
		ensure_zero_bin "Nebula Pad" "$NEBULA_ZERO_PATH" \
			"${CREALITY_NEBULA_ZERO_BIN_URL:-https://github.com/RosetteOS/Recovery/raw/main/assets/zero_nebula.bin}" \
			"${CREALITY_NEBULA_ZERO_BIN_SHA256:-f0ab5db5120c8d69d9094e115df6943b62ed7b0fceaa3f09edfee85a64997b88}"
		;;
esac

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR=$(cd "$OUTPUT_DIR" && pwd)

echo "== Packaging RosetteOS Stock CrealityOS OTA Firmware (${TARGET}) v${VERSION} =="
echo "   Output Directory: $OUTPUT_DIR"
echo "   Kernel:           $KERNEL_IMAGE"
echo "   RootFS:           $ROOTFS_IMAGE"

PACKER_SCRIPT="$SCRIPT_DIR/lib/pack_creality_ota.py"
if [ ! -f "$PACKER_SCRIPT" ]; then
	echo "FATAL: pack_creality_ota.py not found at $PACKER_SCRIPT" >&2
	exit 1
fi

EXTRA_ARGS=""
if [ "$TARGET" = "ke" ] && [ -n "${KE_ZERO_BIN:-}" ]; then
	EXTRA_ARGS="--zero-bin $KE_ZERO_PATH"
elif [ "$TARGET" = "nebula" ] && [ -n "${NEBULA_ZERO_BIN:-}" ]; then
	EXTRA_ARGS="--zero-bin $NEBULA_ZERO_PATH"
fi

python3 "$PACKER_SCRIPT" \
	--target "$TARGET" \
	--ximage "$KERNEL_IMAGE" \
	--rootfs "$ROOTFS_IMAGE" \
	--output-dir "$OUTPUT_DIR" \
	--version "$VERSION" \
	$EXTRA_ARGS

echo "OK   Stock CrealityOS OTA packaging complete in $OUTPUT_DIR"
