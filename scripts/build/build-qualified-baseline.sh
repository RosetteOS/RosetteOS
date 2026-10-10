#!/bin/sh
# Repository + Canonical Baseline Repair mission, Phase 7 (2026-08-07): the
# single documented command that reproduces the current qualified NebulaOS
# production baseline (tag nebulaos-wifi-camera-irq-fix-2026-08-04, plus the
# non-tagged accepted work since it - GuppyScreen/z_compensate, see
# docs/NEBULAOS_QUALIFIED_BASELINE_VARIANT_AUDIT.md) from nothing but this
# checkout, the pinned manifest, and the network.
#
# Deliberately the smallest thing that fits this repo's existing conventions
# - it just sequences the pipeline stages already used individually all
# along, in the order they must run, with the baseline-composition and
# assertion steps at the points that actually matter:
#
#   00-fetch-vendor-sources.sh    fetch every required source (fails loudly on
#                                  any unpushed/unresolvable pin - see
#                                  manifests/dependencies.conf)
#   apply-qualified-baseline.sh   compose all 9 accepted kernel variants
#   assert-baseline-config.sh pre-build   fail fast if a variant's source-
#                                  level change didn't actually land, before
#                                  spending build time
#   01 -> 06                      the existing numbered pipeline, unchanged
#   assert-baseline-config.sh post-build  prove the resolved artifact
#                                  actually contains what was composed
#
# This does NOT reuse any existing vendor/, build-work/, or artifacts/
# state - run it against a genuinely fresh clone (a dirty/reused checkout
# defeats the entire point of a clean-room build; 00-fetch-vendor-sources.sh
# will happily reuse an already-present vendor/ directory if one exists,
# which is convenient for iteration but not what this script is for).
#
# Usage: sh scripts/build/build-qualified-baseline.sh [--swu] [--ingenic]
#
# Exits non-zero if any pin fails to resolve, any variant fails to apply,
# either assertion fails, or any build stage fails.

set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

BUILD_SWU=0
BUILD_INGENIC=0
for arg in "$@"; do
	case "$arg" in
		--swu)
			BUILD_SWU=1
			;;
		--ingenic)
			BUILD_INGENIC=1
			;;
		-h|--help)
			echo "Usage: $0 [--swu] [--ingenic]"
			echo ""
			echo "Options:"
			echo "  --swu        Package a verified SWUpdate (.swu) archive at the end of the build"
			echo "  --ingenic    Package a verified Ingenic USB Cloner (.ingenic) archive at the end of the build"
			echo "  -h, --help   Display this help message and exit"
			exit 0
			;;
		*)
			echo "FATAL: unknown argument: $arg" >&2
			echo "Usage: $0 [--swu] [--ingenic]" >&2
			exit 1
			;;
	esac
done
[ "${ROSETTEOS_BUILD_SWU:-0}" = "1" ] && BUILD_SWU=1
[ "${ROSETTEOS_BUILD_INGENIC:-0}" = "1" ] && BUILD_INGENIC=1

echo "=== build-qualified-baseline: fetching every required source ==="
sh "$SCRIPT_DIR/00-fetch-vendor-sources.sh"

echo "=== build-qualified-baseline: composing all 9 accepted kernel variants ==="
sh "$SCRIPT_DIR/apply-qualified-baseline.sh"

echo "=== build-qualified-baseline: pre-build assertions (source-level) ==="
sh "$SCRIPT_DIR/assert-baseline-config.sh" pre-build

echo "=== build-qualified-baseline: running the build pipeline ==="
sh "$SCRIPT_DIR/01-apply-kernel-patches.sh"
sh "$SCRIPT_DIR/02-configure-buildroot.sh"
sh "$SCRIPT_DIR/03-build-kernel-and-rootfs.sh"
sh "$SCRIPT_DIR/04-cross-compile-app-stack.sh"
sh "$SCRIPT_DIR/05-final-build.sh"
sh "$SCRIPT_DIR/06-verify.sh"

echo "=== build-qualified-baseline: post-build assertions (resolved artifacts) ==="
sh "$SCRIPT_DIR/assert-baseline-config.sh" post-build

echo "=== build-qualified-baseline: complete and composition-verified ==="
if [ "$BUILD_SWU" -eq 1 ]; then
	echo "=== build-qualified-baseline: packaging SWUpdate (.swu) ==="
	sh "$SCRIPT_DIR/package-swu.sh"
fi

if [ "$BUILD_INGENIC" -eq 1 ]; then
	echo "=== build-qualified-baseline: packaging Ingenic cloner (.ingenic) ==="
	sh "$SCRIPT_DIR/package-ingenic.sh"
fi

if [ "$BUILD_SWU" -eq 0 ] && [ "$BUILD_INGENIC" -eq 0 ]; then
	echo "Package it with: sh scripts/build/package-deployment.sh, sh scripts/build/package-swu.sh, or sh scripts/build/package-ingenic.sh"
fi
