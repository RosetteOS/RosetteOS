#!/bin/sh
#
# Offline tests for RosetteOS SWUpdate package generation and configuration.
# Validates sw-description structure, hardware compatibility tags, CPIO member
# order, SHA256 hash correctness, and configuration files (/etc/hwrevision, /etc/swupdate.cfg).
#
# Usage: sh tests/swupdate-package-tests.sh
#

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
PACKAGE_SWU_SCRIPT="$REPO_ROOT/scripts/build/package-swu.sh"
HWREVISION_FILE="$REPO_ROOT/scripts/build/overlay/etc/hwrevision"
SWUPDATE_CFG_FILE="$REPO_ROOT/scripts/build/overlay/etc/swupdate.cfg"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/swupdate-tests.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

echo "=== Test 1: Config and Identity Files ==="

if [ -f "$HWREVISION_FILE" ]; then
    pass "/etc/hwrevision exists in overlay"
    if grep -q "^nebula-pad[[:space:]]\+1\.0" "$HWREVISION_FILE"; then
        pass "/etc/hwrevision specifies nebula-pad 1.0"
    else
        fail "/etc/hwrevision does not match expected format 'nebula-pad 1.0'"
    fi
else
    fail "/etc/hwrevision missing at $HWREVISION_FILE"
fi

if [ -f "$SWUPDATE_CFG_FILE" ]; then
    pass "/etc/swupdate.cfg exists in overlay"
    if grep -q 'nebula-pad = "1.0"' "$SWUPDATE_CFG_FILE"; then
        pass "/etc/swupdate.cfg matches board identifier"
    else
        fail "/etc/swupdate.cfg missing board identifier"
    fi
else
    fail "/etc/swupdate.cfg missing at $SWUPDATE_CFG_FILE"
fi

SW_VERSIONS_FILE="$REPO_ROOT/scripts/build/overlay/etc/sw-versions"
if [ -f "$SW_VERSIONS_FILE" ]; then
    pass "/etc/sw-versions exists in overlay"
    if grep -q "^rosetteos[[:space:]]\+" "$SW_VERSIONS_FILE"; then
        pass "/etc/sw-versions declares rosetteos component version"
    else
        fail "/etc/sw-versions malformed"
    fi
else
    fail "/etc/sw-versions missing at $SW_VERSIONS_FILE"
fi

ROSETTEOS_VERSION_FILE="$REPO_ROOT/scripts/build/overlay/etc/rosetteos-version"
if [ -f "$ROSETTEOS_VERSION_FILE" ]; then
    pass "/etc/rosetteos-version exists in overlay"
else
    fail "/etc/rosetteos-version missing at $ROSETTEOS_VERSION_FILE"
fi

OS_RELEASE_FILE="$REPO_ROOT/scripts/build/overlay/etc/os-release"
if [ -f "$OS_RELEASE_FILE" ]; then
    pass "/etc/os-release exists in overlay"
    if grep -q 'NAME="RosetteOS"' "$OS_RELEASE_FILE"; then
        pass "/etc/os-release specifies RosetteOS system identity"
    else
        fail "/etc/os-release missing RosetteOS name"
    fi
else
    fail "/etc/os-release missing at $OS_RELEASE_FILE"
fi

echo "=== Test 2: Package Generation with Mock Fixtures ==="

MOCK_KERNEL="$WORK/mock_xImage"
MOCK_ROOTFS="$WORK/mock_rootfs.squashfs"
OUT_DIR="$WORK/out"

echo "MOCK_KERNEL_DATA_12345" > "$MOCK_KERNEL"
echo "MOCK_ROOTFS_DATA_67890" > "$MOCK_ROOTFS"

KERNEL_IMAGE="$MOCK_KERNEL" ROOTFS_IMAGE="$MOCK_ROOTFS" \
    sh "$PACKAGE_SWU_SCRIPT" "$OUT_DIR" "test-1.2.3" > "$WORK/build.log" 2>&1

SWU_FILE="$OUT_DIR/rosetteos-update-test-1.2.3.swu"

if [ -f "$SWU_FILE" ]; then
    pass "package-swu.sh generated $SWU_FILE"
else
    fail "package-swu.sh failed to generate .swu package ($(cat "$WORK/build.log"))"
fi

echo "=== Test 3: CPIO Archive Structure & Member Order ==="

MEMBERS=$(cpio -it < "$SWU_FILE" 2>/dev/null)
FIRST_MEMBER=$(echo "$MEMBERS" | head -n1)

if [ "$FIRST_MEMBER" = "sw-description" ]; then
    pass "sw-description is strictly the first member in CPIO archive"
else
    fail "sw-description is not the first member (found: $FIRST_MEMBER)"
fi

for expected in "sw-description" "changelog.txt" "xImage" "rootfs.squashfs" "postinstall.sh"; do
    if echo "$MEMBERS" | grep -q "^${expected}$"; then
        pass "CPIO archive contains $expected"
    else
        fail "CPIO archive missing member $expected"
    fi
done

echo "=== Test 4: sw-description Content & Checksums ==="

EXTRACT_DIR="$WORK/extracted"
mkdir -p "$EXTRACT_DIR"
(cd "$EXTRACT_DIR" && cpio -id < "$SWU_FILE" 2>/dev/null)

SW_DESC="$EXTRACT_DIR/sw-description"

if [ -f "$SW_DESC" ]; then
    pass "sw-description extracted successfully"

    if grep -q 'version = "test-1.2.3";' "$SW_DESC"; then
        pass "sw-description contains expected version test-1.2.3"
    else
        fail "sw-description missing expected version"
    fi

    if grep -q 'hardware-compatibility:[[:space:]]*\[[[:space:]]*"1\.0"[[:space:]]*\];' "$SW_DESC"; then
        pass "sw-description declares hardware-compatibility 1.0"
    else
        fail "sw-description missing expected hardware-compatibility"
    fi

    if grep -q 'installed-directly = true;' "$SW_DESC"; then
        pass "sw-description sets installed-directly = true; for direct partition streaming"
    else
        fail "sw-description missing installed-directly = true;"
    fi

    if grep -q 'device = "/dev/mmcblk0p5";' "$SW_DESC" && grep -q 'device = "/dev/mmcblk0p7";' "$SW_DESC"; then
        pass "sw-description targets /dev/mmcblk0p5 and /dev/mmcblk0p7 for slot1"
    else
        fail "sw-description missing slot1 partition targets"
    fi

    if grep -q 'device = "/dev/mmcblk0p6";' "$SW_DESC" && grep -q 'device = "/dev/mmcblk0p8";' "$SW_DESC"; then
        pass "sw-description targets /dev/mmcblk0p6 and /dev/mmcblk0p8 for slot2"
    else
        fail "sw-description missing slot2 partition targets"
    fi

    EXPECTED_KERNEL_SHA=$(sha256sum "$MOCK_KERNEL" | awk '{print $1}')
    EXPECTED_ROOTFS_SHA=$(sha256sum "$MOCK_ROOTFS" | awk '{print $1}')
    EXPECTED_POSTINSTALL_SHA=$(sha256sum "$EXTRACT_DIR/postinstall.sh" | awk '{print $1}')

    if grep -q "$EXPECTED_KERNEL_SHA" "$SW_DESC"; then
        pass "sw-description contains correct kernel SHA256"
    else
        fail "sw-description kernel SHA256 mismatch"
    fi

    if grep -q "$EXPECTED_ROOTFS_SHA" "$SW_DESC"; then
        pass "sw-description contains correct rootfs SHA256"
    else
        fail "sw-description rootfs SHA256 mismatch"
    fi

    if grep -q "$EXPECTED_POSTINSTALL_SHA" "$SW_DESC"; then
        pass "sw-description contains correct postinstall.sh SHA256"
    else
        fail "sw-description postinstall.sh SHA256 mismatch"
    fi

    if grep -q 'changelog = "' "$SW_DESC"; then
        pass "sw-description contains changelog attribute"
    else
        fail "sw-description missing changelog attribute"
    fi

    if [ -f "$EXTRACT_DIR/changelog.txt" ]; then
        pass "changelog.txt extracted from SWU archive"
    else
        fail "changelog.txt missing from extracted SWU"
    fi
else
    fail "failed to extract sw-description from .swu archive"
fi

echo "=== Test 5: Post-Install Script Dual-Slot Target ==="

if [ -f "$EXTRACT_DIR/postinstall.sh" ]; then
    if grep -q 'ota:kernel2' "$EXTRACT_DIR/postinstall.sh" && \
       grep -q 'ota:kernel' "$EXTRACT_DIR/postinstall.sh"; then
        pass "postinstall.sh handles both slot1 (ota:kernel) and slot2 (ota:kernel2)"
    else
        fail "postinstall.sh missing slot1/slot2 boot marker handling"
    fi

    if grep -q 'mmcblk0p3.*mmcblk0p4' "$EXTRACT_DIR/postinstall.sh"; then
        pass "postinstall.sh populates partition 4 (rtos2) from partition 3 (rtos)"
    else
        fail "postinstall.sh missing rtos2 sync logic"
    fi

    if grep -q 'preinst' "$EXTRACT_DIR/postinstall.sh"; then
        pass "postinstall.sh filters preinst hooks"
    else
        fail "postinstall.sh missing preinst filtering"
    fi

    if grep -q '\.pending_whats_new' "$EXTRACT_DIR/postinstall.sh"; then
        pass "postinstall.sh writes .pending_whats_new for first-boot changelog display"
    else
        fail "postinstall.sh missing .pending_whats_new marker creation"
    fi
else
    fail "postinstall.sh missing from archive"
fi

echo "=== Test 6: Pre-flight Safety Interlocks ==="

if [ -f "$EXTRACT_DIR/postinstall.sh" ]; then
    if grep -q 'print_stats' "$EXTRACT_DIR/postinstall.sh" && grep -q 'heater_bed' "$EXTRACT_DIR/postinstall.sh"; then
        pass "postinstall.sh queries Moonraker for print and heater states"
    else
        fail "postinstall.sh missing Moonraker safety interlocks"
    fi

    if grep -q 'Refusing to overwrite active running system' "$EXTRACT_DIR/postinstall.sh"; then
        pass "postinstall.sh includes active boot slot collision guard"
    else
        fail "postinstall.sh missing active boot slot collision guard"
    fi

    if grep -q 'Cannot safely write to a mounted partition' "$EXTRACT_DIR/postinstall.sh"; then
        pass "postinstall.sh includes mounted partition guard"
    else
        fail "postinstall.sh missing mounted partition guard"
    fi

    # Execute preinst in mock idle environment
    if sh "$EXTRACT_DIR/postinstall.sh" preinst slot2 > "$WORK/preinst.log" 2>&1; then
        pass "postinstall.sh preinst succeeds in safe environment"
    else
        fail "postinstall.sh preinst failed in safe environment ($(cat "$WORK/preinst.log"))"
    fi
fi

echo "=== Test 7: Custom Changelog Passing ==="

CUSTOM_CL_TEXT="• Feature A: High-speed input shaping\n• Feature B: Filament runout detection"
KERNEL_IMAGE="$MOCK_KERNEL" ROOTFS_IMAGE="$MOCK_ROOTFS" \
    sh "$PACKAGE_SWU_SCRIPT" "$OUT_DIR" "test-cl-7.8.9" "$CUSTOM_CL_TEXT" > "$WORK/build_cl.log" 2>&1

CUSTOM_SWU="$OUT_DIR/rosetteos-update-test-cl-7.8.9.swu"
if [ -f "$CUSTOM_SWU" ]; then
    pass "package-swu.sh generated custom changelog SWU"
    CL_EXTRACT_DIR="$WORK/cl_extracted"
    mkdir -p "$CL_EXTRACT_DIR"
    (cd "$CL_EXTRACT_DIR" && cpio -id < "$CUSTOM_SWU" 2>/dev/null)
    if grep -q "Feature A: High-speed input shaping" "$CL_EXTRACT_DIR/changelog.txt"; then
        pass "changelog.txt contains custom changelog content"
    else
        fail "changelog.txt does not contain expected custom changelog content"
    fi
    if grep -q "Feature A: High-speed input shaping" "$CL_EXTRACT_DIR/sw-description"; then
        pass "sw-description contains custom changelog string"
    else
        fail "sw-description does not contain expected custom changelog string"
    fi
else
    fail "package-swu.sh failed to generate custom changelog package"
fi

echo ""
echo "=========================================="
echo "SWUpdate Tests: $PASS passed, $FAIL failed"
echo "=========================================="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
