#!/bin/sh
#
# Builds a verified Ingenic USB Cloner package (.ingenic) for RosetteOS.
# Replaces Slot 1 (or Slot 2) payloads in the base template with the newly
# built kernel (xImage) and rootfs (rootfs.squashfs).
#
# Usage: sh scripts/build/package-ingenic.sh [output-dir] [version] [slot] [base-template]
#

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
ARTIFACT_DIR="$REPO_ROOT/artifacts/buildroot-halley5-v30-image"

OUTPUT_DIR="${1:-$ARTIFACT_DIR}"
VERSION="${2:-}"
SLOT="${3:-slot1}"
BASE_TEMPLATE_ARG="${4:-}"

# Source dependency pins if present, allowing environment overrides
_OVERRIDE_INGENIC_SHA="${INGENIC_TEMPLATE_SHA256:-}"
_OVERRIDE_INGENIC_URL="${INGENIC_TEMPLATE_URL:-}"
MANIFEST="$REPO_ROOT/manifests/dependencies.conf"
if [ -f "$MANIFEST" ]; then
	. "$MANIFEST"
fi
[ -n "$_OVERRIDE_INGENIC_SHA" ] && INGENIC_TEMPLATE_SHA256="$_OVERRIDE_INGENIC_SHA"
[ -n "$_OVERRIDE_INGENIC_URL" ] && INGENIC_TEMPLATE_URL="$_OVERRIDE_INGENIC_URL"

if [ -z "$VERSION" ]; then
	if [ -n "${ROSETTEOS_VERSION:-}" ]; then
		VERSION="$ROSETTEOS_VERSION"
	elif [ -f "$ARTIFACT_DIR/build-manifest.txt" ]; then
		VERSION=$(grep -E "^rosetteos_commit=" "$ARTIFACT_DIR/build-manifest.txt" | cut -d= -f2 | cut -c1-8 || true)
	fi
	if [ -z "$VERSION" ]; then
		VERSION=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "1.0.0")
	fi
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

# Locate base Ingenic template
TEMPLATE_FILE=""
EXPECTED_SHA="${INGENIC_TEMPLATE_SHA256:-5388b16810e51c8233d6ee978b5b4a09347a4c9a4a516d3c5bf8c686e6783f3c}"
TEMPLATE_URL="${INGENIC_TEMPLATE_URL:-https://github.com/RosetteOS/Recovery/raw/main/Ender-3_V3_KE_1.1.0.12.ingenic}"

if [ -n "$BASE_TEMPLATE_ARG" ] && [ -f "$BASE_TEMPLATE_ARG" ]; then
	TEMPLATE_FILE="$BASE_TEMPLATE_ARG"
elif [ -f "$REPO_ROOT/vendor-downloads/Ender-3_V3_KE_1.1.0.12.ingenic" ]; then
	TEMPLATE_FILE="$REPO_ROOT/vendor-downloads/Ender-3_V3_KE_1.1.0.12.ingenic"
elif [ -f "$ARTIFACT_DIR/Ender-3_V3_KE_1.1.0.12.ingenic" ]; then
	TEMPLATE_FILE="$ARTIFACT_DIR/Ender-3_V3_KE_1.1.0.12.ingenic"
elif [ -f "$REPO_ROOT/../Recovery/Ender-3_V3_KE_1.1.0.12.ingenic" ]; then
	TEMPLATE_FILE="$REPO_ROOT/../Recovery/Ender-3_V3_KE_1.1.0.12.ingenic"
fi

if [ -z "$TEMPLATE_FILE" ] || [ ! -f "$TEMPLATE_FILE" ]; then
	echo "== Ingenic template not found locally; downloading from $TEMPLATE_URL =="
	DOWNLOAD_DIR="$REPO_ROOT/vendor-downloads"
	mkdir -p "$DOWNLOAD_DIR"
	DOWNLOAD_TARGET="$DOWNLOAD_DIR/Ender-3_V3_KE_1.1.0.12.ingenic"

	if command -v curl >/dev/null 2>&1; then
		curl -fSL --retry 3 --retry-delay 2 "$TEMPLATE_URL" -o "$DOWNLOAD_TARGET"
	elif command -v wget >/dev/null 2>&1; then
		wget -q --tries=3 "$TEMPLATE_URL" -O "$DOWNLOAD_TARGET"
	else
		python3 -c "
import urllib.request, sys
urllib.request.urlretrieve('$TEMPLATE_URL', '$DOWNLOAD_TARGET')
"
	fi
	TEMPLATE_FILE="$DOWNLOAD_TARGET"
fi

# Verify template checksum
ACTUAL_SHA=$(sha256sum "$TEMPLATE_FILE" | awk '{print $1}')
if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
	echo "FATAL: Ingenic base template $TEMPLATE_FILE checksum mismatch: expected $EXPECTED_SHA, got $ACTUAL_SHA" >&2
	exit 1
fi

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR=$(cd "$OUTPUT_DIR" && pwd)

INGENIC_NAME="Ender-3_V3_KE_1.1.0.12-${VERSION}.ingenic"
OUTPUT_PATH="$OUTPUT_DIR/$INGENIC_NAME"

echo "== Packaging RosetteOS Ingenic Cloner Package (${SLOT}) v${VERSION} =="
echo "   Template: $TEMPLATE_FILE"
echo "   Kernel:   $KERNEL_IMAGE"
echo "   RootFS:   $ROOTFS_IMAGE"
echo "   Output:   $OUTPUT_PATH"

REBUILD_SCRIPT="$SCRIPT_DIR/lib/rebuild_ingenic.py"
if [ ! -f "$REBUILD_SCRIPT" ]; then
	echo "FATAL: rebuild_ingenic.py not found at $REBUILD_SCRIPT" >&2
	exit 1
fi

case "$SLOT" in
	slot1)
		python3 "$REBUILD_SCRIPT" \
			"$TEMPLATE_FILE" \
			"$OUTPUT_PATH" \
			--root1 "$ROOTFS_IMAGE" \
			--kernel1 "$KERNEL_IMAGE"
		;;
	slot2)
		python3 "$REBUILD_SCRIPT" \
			"$TEMPLATE_FILE" \
			"$OUTPUT_PATH" \
			--root2 "$ROOTFS_IMAGE" \
			--kernel2 "$KERNEL_IMAGE"
		;;
	*)
		echo "FATAL: unknown slot target: $SLOT (must be slot1 or slot2)" >&2
		exit 1
		;;
esac

if [ ! -f "$OUTPUT_PATH" ]; then
	echo "FATAL: failed to create $OUTPUT_PATH" >&2
	exit 1
fi

INGENIC_SHA=$(sha256sum "$OUTPUT_PATH" | awk '{print $1}')
echo "OK   Created $OUTPUT_PATH (${INGENIC_SHA})"
echo "${INGENIC_SHA}  ${INGENIC_NAME}" > "$OUTPUT_DIR/${INGENIC_NAME}.sha256"
