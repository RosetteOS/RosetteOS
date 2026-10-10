#!/bin/sh
#
# build_rosetteos_image.sh
#
# Generates stock-compatible CrealityOS OTA firmware (.img) directly from
# RosetteOS build artifacts. The resulting file can be placed on a FAT32 USB drive
# and flashed via the stock touchscreen UI to install RosetteOS to Slot 2.
#
# Supports:
#   - Ender-3 V3 KE (Target F005)
#   - Nebula Smart Kit / Nebula Pad (Target NEBULA)
#

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"

DEFAULT_ARTIFACTS="$SCRIPT_DIR/artifacts/buildroot-halley5-v30-image"
DEFAULT_VERSION="1.1.0.34"
DEFAULT_TARGET="ke"

ARTIFACTS_DIR="$DEFAULT_ARTIFACTS"
VERSION="$DEFAULT_VERSION"
TARGET="$DEFAULT_TARGET"
OUTPUT=""

usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Packages the RosetteOS kernel and rootfs into a stock CrealityOS-supported update .img.

Options:
  -t, --target TARGET   Target hardware profile:
                          ke      - Ender-3 V3 KE (F005) [Default]
                          nebula  - Creality Nebula Pad (NEBULA)
                          all     - Build images for both devices
  -a, --artifacts DIR   Directory containing RosetteOS build artifacts (xImage, rootfs.squashfs)
                        (Default: artifacts/buildroot-halley5-v30-image)
  -v, --version VER     Package version for Creality updater (Default: 1.1.0.34)
  -o, --output FILE     Output .img file path (single target only)
  -h, --help            Show this help message and exit

Examples:
  ./build_rosetteos_image.sh                   # Builds for Ender-3 V3 KE
  ./build_rosetteos_image.sh --target nebula   # Builds for Nebula Pad
  ./build_rosetteos_image.sh --target all      # Builds both KE and Nebula images
EOF
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        -t|--target)
            TARGET="$2"
            shift 2
            ;;
        -a|--artifacts)
            ARTIFACTS_DIR="$2"
            shift 2
            ;;
        -v|--version)
            VERSION="$2"
            shift 2
            ;;
        -o|--output)
            OUTPUT="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            ;;
    esac
done

if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 is not installed or not in PATH." >&2
    exit 1
fi

if [ ! -d "$ARTIFACTS_DIR" ]; then
    echo "ERROR: Artifacts directory not found: $ARTIFACTS_DIR" >&2
    echo "Please build RosetteOS first or specify --artifacts <dir>." >&2
    exit 1
fi

PACKER="$SCRIPT_DIR/scripts/build/lib/pack_creality_ota.py"

if [ -n "$OUTPUT" ]; then
    python3 "$PACKER" \
        --target "$TARGET" \
        --artifacts-dir "$ARTIFACTS_DIR" \
        --version "$VERSION" \
        --output "$OUTPUT"
else
    python3 "$PACKER" \
        --target "$TARGET" \
        --artifacts-dir "$ARTIFACTS_DIR" \
        --version "$VERSION"
fi
