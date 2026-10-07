#!/bin/sh
# Run this INSIDE a built/pulled rosetteos-build image to confirm its tooling
# matches what scripts/build/00-06 actually needs. Fails loudly (non-zero
# exit) on the first missing/wrong tool rather than limping on with a
# confusing failure deep into a real build.
#
# Usage (from the host):
#   docker run --rm -v "$PWD:$PWD" -w "$PWD" <image> \
#     sh build-env/verify-environment.sh

set -u
FAILED=0

need() {
	# name, command to run, optional grep pattern the output must contain
	name="$1"; shift
	cmd="$1"; shift
	pattern="${1:-}"
	out=$($cmd 2>&1)
	rc=$?
	if [ "$rc" != "0" ] && [ -z "$pattern" ]; then
		echo "MISSING: $name ($cmd failed, exit $rc)"
		FAILED=1
		return
	fi
	if [ -n "$pattern" ] && ! echo "$out" | grep -q "$pattern"; then
		echo "MISMATCH: $name - expected to find '$pattern' in: $out"
		FAILED=1
		return
	fi
	echo "OK: $name -> $(echo "$out" | head -1)"
}

echo "=== Host build tools ==="
need "gcc"                  "gcc --version"
need "g++"                  "g++ --version"
need "make"                 "make --version"
need "cmake"                "cmake --version"
need "python3"               "python3 --version"
need "git"                  "git --version"
need "dtc"                   "dtc --version"
need "mksquashfs"            "mksquashfs -version"
need "debugfs (e2fsprogs)"   "debugfs -V"
need "autoreconf"            "autoreconf --version"
need "pkg-config"            "pkg-config --version"
need "bison"                 "bison --version"
need "flex"                  "flex --version"

echo ""
echo "=== Migration A: GuppyScreen's Bootlin mips32el-musl toolchain ==="
# Deliberately NOT on the image's global PATH (see build-env/Dockerfile's
# own comment on GUPPYSCREEN_TOOLCHAIN_BIN for why - its own bundled
# autoreconf/automake would otherwise shadow the system ones v4l2-ctl's
# build needs). Checked via GUPPYSCREEN_TOOLCHAIN_BIN directly instead of
# via PATH lookup.
if [ -z "${GUPPYSCREEN_TOOLCHAIN_BIN:-}" ]; then
	echo "MISSING: GUPPYSCREEN_TOOLCHAIN_BIN not set in this image's environment"
	FAILED=1
elif [ ! -x "$GUPPYSCREEN_TOOLCHAIN_BIN/mipsel-linux-gcc" ]; then
	echo "MISSING: $GUPPYSCREEN_TOOLCHAIN_BIN/mipsel-linux-gcc not found or not executable"
	FAILED=1
else
	need "mipsel-linux-gcc (Bootlin)" "$GUPPYSCREEN_TOOLCHAIN_BIN/mipsel-linux-gcc --version" "Buildroot"
fi

echo ""
echo "=== Deliberately NOT expected here (Buildroot builds these itself) ==="
if command -v mipsel-buildroot-linux-gnu-gcc >/dev/null 2>&1; then
	echo "NOTE: mipsel-buildroot-linux-gnu-gcc found on PATH - only expected AFTER a real build has" \
	     "run Stage 03 and put vendor/system/buildroot/output/host/bin on PATH; if this is a fresh" \
	     "image with no build yet, that's unexpected."
else
	echo "OK: mipsel-buildroot-linux-gnu-gcc correctly absent (bootstrapped at build time, not baked in)"
fi

echo ""
if [ "$FAILED" = "1" ]; then
	echo "== verify-environment: FAILED - see MISSING/MISMATCH lines above =="
	exit 1
fi
echo "== verify-environment: all checks passed =="
