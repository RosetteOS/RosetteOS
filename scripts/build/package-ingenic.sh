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
MANIFEST="$REPO_ROOT/manifests/dependencies.conf"
if [ -f "$MANIFEST" ]; then
	# shellcheck source=manifests/dependencies.conf disable=SC1091
	. "$MANIFEST"
fi

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
if [ -n "$BASE_TEMPLATE_ARG" ] && [ -f "$BASE_TEMPLATE_ARG" ]; then
	TEMPLATE_FILE="$BASE_TEMPLATE_ARG"
elif [ -f "$REPO_ROOT/assets/Ender-3_V3_KE_1.1.0.12.ingenic" ]; then
	TEMPLATE_FILE="$REPO_ROOT/assets/Ender-3_V3_KE_1.1.0.12.ingenic"
elif [ -f "$REPO_ROOT/Ender-3_V3_KE_1.1.0.12.ingenic" ]; then
	TEMPLATE_FILE="$REPO_ROOT/Ender-3_V3_KE_1.1.0.12.ingenic"
elif [ -f "$ARTIFACT_DIR/Ender-3_V3_KE_1.1.0.12.ingenic" ]; then
	TEMPLATE_FILE="$ARTIFACT_DIR/Ender-3_V3_KE_1.1.0.12.ingenic"
elif [ -f "$REPO_ROOT/vendor-downloads/Ender-3_V3_KE_1.1.0.12.ingenic" ]; then
	TEMPLATE_FILE="$REPO_ROOT/vendor-downloads/Ender-3_V3_KE_1.1.0.12.ingenic"
fi

if [ -z "$TEMPLATE_FILE" ] || [ ! -f "$TEMPLATE_FILE" ]; then
	echo "FATAL: Ingenic base template not found at assets/Ender-3_V3_KE_1.1.0.12.ingenic" >&2
	exit 1
fi

# Auto-hydrate Git LFS pointer if cloned without LFS filter
if [ "$(wc -c < "$TEMPLATE_FILE")" -lt 1024 ] && { grep -q "git-lfs" "$TEMPLATE_FILE" 2>/dev/null || grep -q "^oid sha256:" "$TEMPLATE_FILE" 2>/dev/null; }; then
	echo "== $TEMPLATE_FILE is a Git LFS pointer stub; running git lfs pull =="
	(cd "$REPO_ROOT" && git lfs pull --include="assets/Ender-3_V3_KE_1.1.0.12.ingenic")
fi

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR=$(cd "$OUTPUT_DIR" && pwd)

INGENIC_NAME="${INGENIC_PACKAGE_NAME:-RosetteOS-${VERSION}.ingenic}"
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
