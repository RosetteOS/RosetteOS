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
# Usage: sh scripts/build/build-qualified-baseline.sh [--swu] [--ingenic] [--ota]
#
# Exits non-zero if any pin fails to resolve, any variant fails to apply,
# either assertion fails, or any build stage fails.

set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

BUILD_SWU=0
BUILD_INGENIC=0
BUILD_OTA=0
OTA_TARGET="${ROSETTEOS_OTA_TARGET:-all}"
PACKAGE_VERSION="${ROSETTEOS_PACKAGE_VERSION:-}"

usage() {
	echo "Usage: $0 [OPTIONS]"
	echo ""
	echo "Options:"
	echo "  --swu                      Package a verified SWUpdate (.swu) archive at the end of the build"
	echo "  --ingenic                  Package a verified Ingenic USB Cloner (.ingenic) archive at the end of the build"
	echo "  --ota                      Package stock CrealityOS-compatible OTA (.img) updates at the end of the build"
	echo "  --ota-target <target>      Target profile for --ota: ke, nebula, or all (default: all; implies --ota)"
	echo "  --all, --release           Package all deployment formats (.swu, .ingenic, and .img OTA)"
	echo "  --version <ver>            Override package version string for generated deployment archives"
	echo "  -h, --help                 Display this help message and exit"
}

while [ $# -gt 0 ]; do
	case "$1" in
		--swu)
			BUILD_SWU=1
			shift
			;;
		--ingenic)
			BUILD_INGENIC=1
			shift
			;;
		--ota)
			BUILD_OTA=1
			shift
			;;
		--ota-target)
			[ $# -ge 2 ] || { echo "FATAL: --ota-target requires a value (ke, nebula, or all)" >&2; exit 1; }
			OTA_TARGET="$2"
			BUILD_OTA=1
			shift 2
			;;
		--ota-target=*)
			OTA_TARGET="${1#*=}"
			BUILD_OTA=1
			shift
			;;
		--all|--release)
			BUILD_SWU=1
			BUILD_INGENIC=1
			BUILD_OTA=1
			shift
			;;
		--version)
			[ $# -ge 2 ] || { echo "FATAL: --version requires a value" >&2; exit 1; }
			PACKAGE_VERSION="$2"
			shift 2
			;;
		--version=*)
			PACKAGE_VERSION="${1#*=}"
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			echo "FATAL: unknown argument: $1" >&2
			usage >&2
			exit 1
			;;
	esac
done
[ "${ROSETTEOS_BUILD_SWU:-0}" = "1" ] && BUILD_SWU=1
[ "${ROSETTEOS_BUILD_INGENIC:-0}" = "1" ] && BUILD_INGENIC=1
[ "${ROSETTEOS_BUILD_OTA:-0}" = "1" ] && BUILD_OTA=1
if [ "${ROSETTEOS_BUILD_ALL:-0}" = "1" ]; then
	BUILD_SWU=1
	BUILD_INGENIC=1
	BUILD_OTA=1
fi

case "$OTA_TARGET" in
	ke|nebula|all) ;;
	*)
		echo "FATAL: invalid --ota-target '$OTA_TARGET' (expected: ke, nebula, or all)" >&2
		exit 1
		;;
esac

REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
ARTIFACT_DIR="$REPO_ROOT/artifacts/buildroot-halley5-v30-image"
BUILD_START_TS=$(date +%s)
STAGE_TIMINGS=""

format_duration() {
	_secs="$1"
	_mins=$((_secs / 60))
	_rem=$((_secs % 60))
	if [ "$_mins" -gt 0 ]; then
		printf "%dm %02ds" "$_mins" "$_rem"
	else
		printf "%ds" "$_rem"
	fi
}

run_stage() {
	_label="$1"
	shift
	echo "=== build-qualified-baseline: $_label ==="
	_stage_start=$(date +%s)
	"$@"
	_stage_end=$(date +%s)
	_stage_elapsed=$((_stage_end - _stage_start))
	_stage_fmt=$(format_duration "$_stage_elapsed")
	echo "=== [done in $_stage_fmt] $_label ==="
	STAGE_TIMINGS="${STAGE_TIMINGS}${_label}|${_stage_fmt}
"
}

print_artifact_row() {
	_file="$1"
	[ -f "$_file" ] || return 0
	_name=$(basename "$_file")
	_size=$(du -h "$_file" 2>/dev/null | awk '{print $1}')
	_sha=$(sha256sum "$_file" 2>/dev/null | awk '{print $1}')
	printf "  %-38s  %8s  %s\n" "$_name" "$_size" "$_sha"
}

print_build_summary() {
	_total_end=$(date +%s)
	_total_elapsed=$((_total_end - BUILD_START_TS))
	_total_fmt=$(format_duration "$_total_elapsed")

	echo ""
	echo "================================================================================"
	echo "                      ROSETTEOS BUILD SUMMARY"
	echo "================================================================================"
	echo "Stage Timings:"
	printf "%s" "$STAGE_TIMINGS" | while IFS='|' read -r _s_label _s_time; do
		[ -n "$_s_label" ] || continue
		printf "  %-58s %10s\n" "$_s_label" "$_s_time"
	done
	echo "  ----------------------------------------------------------------------"
	printf "  %-58s %10s\n" "Total Build Time" "$_total_fmt"
	echo ""
	echo "Artifacts ($ARTIFACT_DIR):"
	printf "  %-38s  %8s  %s\n" "FILE" "SIZE" "SHA256"
	echo "  ------------------------------------------------------------------------------"
	print_artifact_row "$ARTIFACT_DIR/xImage"
	print_artifact_row "$ARTIFACT_DIR/rootfs.squashfs"
	if [ "$BUILD_SWU" -eq 1 ]; then
		for _f in "$ARTIFACT_DIR"/*.swu; do
			[ -f "$_f" ] && print_artifact_row "$_f"
		done
	fi
	if [ "$BUILD_INGENIC" -eq 1 ]; then
		for _f in "$ARTIFACT_DIR"/*.ingenic; do
			[ -f "$_f" ] && print_artifact_row "$_f"
		done
	fi
	if [ "$BUILD_OTA" -eq 1 ]; then
		for _f in "$ARTIFACT_DIR"/*.img; do
			[ -f "$_f" ] && print_artifact_row "$_f"
		done
	fi
	echo "================================================================================"
}

run_stage "00 - fetching required vendor sources" \
	sh "$SCRIPT_DIR/00-fetch-vendor-sources.sh"

run_stage "baseline - composing all 9 accepted kernel variants" \
	sh "$SCRIPT_DIR/apply-qualified-baseline.sh"

run_stage "assert - pre-build assertions (source-level)" \
	sh "$SCRIPT_DIR/assert-baseline-config.sh" pre-build

run_stage "01 - applying kernel patches" \
	sh "$SCRIPT_DIR/01-apply-kernel-patches.sh"

run_stage "02 - configuring buildroot" \
	sh "$SCRIPT_DIR/02-configure-buildroot.sh"

run_stage "03 - building kernel and rootfs" \
	sh "$SCRIPT_DIR/03-build-kernel-and-rootfs.sh"

run_stage "04 - cross-compiling app stack" \
	sh "$SCRIPT_DIR/04-cross-compile-app-stack.sh"

run_stage "05 - final build assembly" \
	sh "$SCRIPT_DIR/05-final-build.sh"

run_stage "06 - verifying build output" \
	sh "$SCRIPT_DIR/06-verify.sh"

run_stage "assert - post-build assertions (resolved artifacts)" \
	sh "$SCRIPT_DIR/assert-baseline-config.sh" post-build

echo "=== build-qualified-baseline: complete and composition-verified ==="
if [ "$BUILD_SWU" -eq 1 ]; then
	run_stage "package - SWUpdate (.swu)" \
		sh "$SCRIPT_DIR/package-swu.sh" "" "$PACKAGE_VERSION"
fi

if [ "$BUILD_INGENIC" -eq 1 ]; then
	run_stage "package - Ingenic cloner (.ingenic)" \
		sh "$SCRIPT_DIR/package-ingenic.sh" "" "$PACKAGE_VERSION"
fi

if [ "$BUILD_OTA" -eq 1 ]; then
	run_stage "package - Stock CrealityOS OTA (.img, target: $OTA_TARGET)" \
		sh "$SCRIPT_DIR/package-creality-ota.sh" "" "$OTA_TARGET" "$PACKAGE_VERSION"
fi

print_build_summary

if [ "$BUILD_SWU" -eq 0 ] && [ "$BUILD_INGENIC" -eq 0 ] && [ "$BUILD_OTA" -eq 0 ]; then
	echo "Package it with: ./build.sh --all, ./build.sh --swu, ./build.sh --ingenic, or ./build.sh --ota"
fi
