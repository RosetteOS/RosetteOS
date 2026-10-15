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
MANIFEST="$REPO_ROOT/manifests/dependencies.conf"
if [ -f "$MANIFEST" ]; then
	# shellcheck source=manifests/dependencies.conf disable=SC1091
	. "$MANIFEST"
fi
[ -n "$_OVERRIDE_OTA_VER" ] && CREALITY_OTA_VERSION="$_OVERRIDE_OTA_VER"

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
		if [ "$(id -u)" -eq 0 ] && command -v apt-get >/dev/null 2>&1; then
			echo "Installing p7zip-full for OTA packaging..."
			apt-get update -qq && apt-get install -y -qq p7zip-full
		elif command -v python3 >/dev/null 2>&1; then
			echo "Installing py7zr (user site) for OTA packaging..."
			python3 -m pip install --user --no-warn-script-location --quiet py7zr || pip3 install --quiet py7zr || true
		fi
	fi
fi

KE_ZERO_PATH="${KE_ZERO_BIN:-$REPO_ROOT/assets/zero.bin}"
NEBULA_ZERO_PATH="${NEBULA_ZERO_BIN:-$REPO_ROOT/assets/zero_nebula.bin}"

case "$TARGET" in
	ke|all)
		if [ ! -f "$KE_ZERO_PATH" ]; then
			echo "FATAL: Ender-3 V3 KE RTOS firmware not found at $KE_ZERO_PATH" >&2
			exit 1
		fi
		;;
esac

case "$TARGET" in
	nebula|all)
		if [ ! -f "$NEBULA_ZERO_PATH" ]; then
			echo "FATAL: Nebula Pad RTOS firmware not found at $NEBULA_ZERO_PATH" >&2
			exit 1
		fi
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

# shellcheck disable=SC2086
python3 "$PACKER_SCRIPT" \
	--target "$TARGET" \
	--ximage "$KERNEL_IMAGE" \
	--rootfs "$ROOTFS_IMAGE" \
	--output-dir "$OUTPUT_DIR" \
	--version "$VERSION" \
	$EXTRA_ARGS

echo "OK   Stock CrealityOS OTA packaging complete in $OUTPUT_DIR"
