#!/bin/sh
# The one documented command to reproduce the current qualified RosetteOS
# baseline from a fresh clone:
#
#   git clone https://github.com/RosetteOS/RosetteOS.git
#   cd RosetteOS
#   ./build.sh [--swu] [--ingenic] [--ota]
#
# Pass `--swu` to package a verified SWUpdate (.swu) archive at the end
# of the build:
#   ./build.sh --swu
#
# Pass `--ingenic` to package a verified Ingenic USB Cloner (.ingenic)
# archive at the end of the build:
#   ./build.sh --ingenic
#
# Pass `--ota` to package stock CrealityOS-compatible OTA (.img) updates
# at the end of the build:
#   ./build.sh --ota
#
# Fetches every pinned dependency (kernel, Klipper, GuppyScreen, Moonraker,
# Buildroot, ustreamer, Mainsail, wireless-regdb, WiFi firmware - see
# manifests/dependencies.conf), composes all 9 accepted baseline variants,
# builds the kernel/rootfs/app-stack, and verifies the result against the
# accepted-baseline assertions - scripts/build/build-qualified-baseline.sh
# does the actual sequencing; this is a thin, host-dependency-aware wrapper
# around it, not a reimplementation.
#
# Phase 11 (2026-08-15, unified-build-environment migration): this used to
# have two modes - run directly on a host with git/curl/etc already
# installed, or `--containerized` to get those from a thin wrapper image
# that then launched TWO MORE nested containers (pellcorp/k1-bash-build,
# ghcr.io/coreflake1/guppydev) via the host's own Docker socket for the
# actual work. That nested-container design is gone. There is now exactly
# ONE container, pinned by digest in manifests/dependencies.conf
# (BUILD_IMAGE_REPO/BUILD_IMAGE_DIGEST) - it already contains every host
# build tool the 00-06 pipeline needs (see build-env/Dockerfile), so
# nothing here or inside those stages ever calls `docker`/`apt-get` again.
#
# Requires on the host: Docker or Podman, and nothing else - not even git,
# since the container itself is what clones/builds everything once it's
# running with this checkout mounted in.
#
# Does NOT reuse any existing vendor/, build-work/, or artifacts/ state by
# itself - run this against a genuinely fresh clone for a real clean-room
# result (an already-populated vendor/ is convenient for iteration but
# defeats the point of using this script to prove reproducibility).
#
# Exits non-zero if any pin fails to resolve, any variant fails to apply,
# either baseline assertion fails, or any build stage fails - this script
# propagates the container's real exit status, it does not swallow it.

set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

BUILD_SWU=0
BUILD_INGENIC=0
BUILD_OTA=0
OTA_TARGET="${ROSETTEOS_OTA_TARGET:-all}"
CREALITY_OTA_VER_ARG=""
PACKAGE_VERSION="${ROSETTEOS_PACKAGE_VERSION:-}"
FORCE_PULL=0

usage() {
	echo "Usage: $0 [OPTIONS]"
	echo ""
	echo "Options:"
	echo "  --swu                           Package a verified SWUpdate (.swu) archive at the end of the build"
	echo "  --ingenic                       Package a verified Ingenic USB Cloner (.ingenic) archive at the end of the build"
	echo "  --ota                           Package stock CrealityOS-compatible OTA (.img) updates at the end of the build"
	echo "  --ota-target <target>           Target profile for --ota: ke, nebula, or all (default: all; implies --ota)"
	echo "  --creality-ota-version <ver>    Override Creality OTA envelope version (requires --ota, --ota-target, or --all)"
	echo "  --all, --release                Package all deployment formats (.swu, .ingenic, and .img OTA)"
	echo "  --version <ver>                 Override RosetteOS package version string (.swu and .ingenic)"
	echo "  --pull                          Force pulling the build environment container image even if cached locally"
	echo "  -h, --help                      Display this help message and exit"
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
		--creality-ota-version)
			[ $# -ge 2 ] || { echo "FATAL: --creality-ota-version requires a value (e.g. 1.1.0.34)" >&2; exit 1; }
			CREALITY_OTA_VER_ARG="$2"
			shift 2
			;;
		--creality-ota-version=*)
			CREALITY_OTA_VER_ARG="${1#*=}"
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
		--pull)
			FORCE_PULL=1
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
[ "${ROSETTEOS_PULL:-0}" = "1" ] && FORCE_PULL=1

if [ -n "$CREALITY_OTA_VER_ARG" ] && [ "$BUILD_OTA" -ne 1 ]; then
	echo "FATAL: --creality-ota-version is only accepted when building a Creality OTA image (--ota, --ota-target, or --all)" >&2
	exit 1
fi

case "$OTA_TARGET" in
	ke|nebula|all) ;;
	*)
		echo "FATAL: invalid --ota-target '$OTA_TARGET' (expected: ke, nebula, or all)" >&2
		exit 1
		;;
esac

MANIFEST="$SCRIPT_DIR/manifests/dependencies.conf"
[ -f "$MANIFEST" ] || { echo "FATAL: $MANIFEST not found" >&2; exit 1; }
. "$MANIFEST"
[ -n "$CREALITY_OTA_VER_ARG" ] && CREALITY_OTA_VERSION="$CREALITY_OTA_VER_ARG"

: "${BUILD_IMAGE_REPO:?FATAL: BUILD_IMAGE_REPO not set in $MANIFEST}"
: "${BUILD_IMAGE_DIGEST:?FATAL: BUILD_IMAGE_DIGEST not set in $MANIFEST}"
IMAGE_REF="${BUILD_IMAGE_REPO}@${BUILD_IMAGE_DIGEST}"

ENGINE=""
for candidate in docker podman; do
	command -v "$candidate" >/dev/null 2>&1 && { ENGINE="$candidate"; break; }
done
[ -n "$ENGINE" ] || {
	echo "FATAL: neither docker nor podman found on this host - one of them is required to run the pinned build environment ($IMAGE_REF)." >&2
	exit 1
}

if [ "$FORCE_PULL" -eq 1 ] || ! "$ENGINE" image inspect "$IMAGE_REF" >/dev/null 2>&1; then
	echo "== build.sh: pulling pinned build environment $IMAGE_REF (engine: $ENGINE) =="
	"$ENGINE" pull "$IMAGE_REF"
else
	echo "== build.sh: using cached pinned build environment $IMAGE_REF (engine: $ENGINE; pass --pull to force) =="
fi

# ROSETTEOS_REPO_ROOT: fixed container-internal mount point, deliberately
# NOT the host's own checkout path.
#
# Final Closure mission, Phase C (2026-08-15): this used to mount the
# checkout at the SAME absolute path inside the container as outside it
# (-v "$SCRIPT_DIR:$SCRIPT_DIR"), reasoned at the time as avoiding a path
# boundary crossing. That reasoning missed a real consequence, found by
# the Phase 9 vs Phase 11 artifact comparison: the host's own checkout
# path (which varies - different developers, different clone locations,
# even the same developer's own repeated test directories in this
# session) leaks straight into the build. CONFIG_EXTRA_FIRMWARE_DIR
# embedded it directly; GuppyScreen's binary carried ~770KB of diff
# traced to embedded absolute build-path strings, purely because the
# container saw a different host path on every separate clone. Two
# builds of byte-identical source, in the byte-identical image, produced
# different output for a reason that has nothing to do with the product.
#
# Mounting at one fixed internal path instead - regardless of where the
# user actually cloned this repo on the host - means every build sees the
# identical internal path, so anything that embeds it (Kconfig strings,
# __FILE__/assert() macros, debug info) embeds the same bytes every time.
# Every script under scripts/build/ already derives its own location via
# `SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)` rather than a hardcoded
# path, so this needs no changes anywhere else - they'll all resolve to
# ROSETTEOS_REPO_ROOT automatically once the working directory is set here.
# Output files stay on the host exactly as before: a bind mount is a
# transparent, two-way passthrough regardless of which internal path it's
# mounted at, so anything the container writes under ROSETTEOS_REPO_ROOT
# still lands at $SCRIPT_DIR on the host.
ROSETTEOS_REPO_ROOT=/workspace/RosetteOS
# -e HOME=/tmp: an arbitrary host UID has no /etc/passwd entry inside the
# container, so HOME defaults to "/" (not writable by this UID) - confirmed
# live this would break any tool that wants to write a cache/config file
# (pip's download cache, git's config lookup). /tmp is writable by anyone
# and doesn't need to persist across runs.
# No -it: found live running this in the background (nohup, no attached
# terminal) - `-t` fails outright ("cannot attach stdin to a TTY-enabled
# container because stdin is not a terminal") when there's no real TTY, and
# this build never actually needs interactive stdin either way. Plain `-i`
# without `-t` would still block waiting on stdin in a backgrounded/piped
# invocation with none available - dropping both is correct for a batch
# build, not just a workaround.
# Default to candidate build mode when building against a candidate container tag
CANDIDATE_DEFAULT=0
[ -n "$BUILD_IMAGE_CANDIDATE_TAG" ] && CANDIDATE_DEFAULT=1

BUILD_CMD="sh scripts/build/build-qualified-baseline.sh"
[ "$BUILD_SWU" -eq 1 ] && BUILD_CMD="$BUILD_CMD --swu"
[ "$BUILD_INGENIC" -eq 1 ] && BUILD_CMD="$BUILD_CMD --ingenic"
if [ "$BUILD_OTA" -eq 1 ]; then
	BUILD_CMD="$BUILD_CMD --ota --ota-target $OTA_TARGET"
	[ -n "$CREALITY_OTA_VER_ARG" ] && BUILD_CMD="$BUILD_CMD --creality-ota-version $CREALITY_OTA_VER_ARG"
fi
if [ -n "$PACKAGE_VERSION" ]; then
	BUILD_CMD="$BUILD_CMD --version $PACKAGE_VERSION"
fi

exec "$ENGINE" run --rm \
	--user "$(id -u):$(id -g)" \
	-e HOME=/tmp \
	-e ROSETTEOS_REPO_ROOT="$ROSETTEOS_REPO_ROOT" \
	-e ROSETTEOS_CANDIDATE_BUILD="${ROSETTEOS_CANDIDATE_BUILD:-$CANDIDATE_DEFAULT}" \
	-e ROSETTEOS_OTA_TARGET="$OTA_TARGET" \
	-e CREALITY_OTA_VERSION="${CREALITY_OTA_VERSION:-}" \
	-e ROSETTEOS_PACKAGE_VERSION="$PACKAGE_VERSION" \
	-e FORCE_UNSAFE_CONFIGURE=1 \
	-v "$SCRIPT_DIR:$ROSETTEOS_REPO_ROOT" \
	-w "$ROSETTEOS_REPO_ROOT" \
	"$IMAGE_REF" \
	"$BUILD_CMD"
