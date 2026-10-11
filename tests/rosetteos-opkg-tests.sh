#!/bin/sh
#
# Offline, repeatable verification tests for RosetteOS Package Manager (opkg / Entware integration).
#
# Usage: bash tests/rosetteos-opkg-tests.sh
#

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
OVERLAY="$REPO_ROOT/scripts/build/overlay"
CONFIG_FILE="$REPO_ROOT/artifacts/buildroot-halley5-v30-image/buildroot.config"

PASS=0
FAIL=0

pass() {
	echo "PASS: $1"
	PASS=$((PASS + 1))
}

fail() {
	echo "FAIL: $1"
	FAIL=$((FAIL + 1))
}

echo "=== Test 1: Buildroot Package Manager Configuration ==="
[ -f "$CONFIG_FILE" ] || { fail "buildroot.config missing"; exit 1; }

if grep -q "^BR2_PACKAGE_OPKG=y$" "$CONFIG_FILE"; then
	pass "BR2_PACKAGE_OPKG=y is enabled"
else
	fail "BR2_PACKAGE_OPKG is not enabled in buildroot.config"
fi

if grep -q "^BR2_PACKAGE_LIBARCHIVE=y$" "$CONFIG_FILE"; then
	pass "BR2_PACKAGE_LIBARCHIVE=y is enabled"
else
	fail "BR2_PACKAGE_LIBARCHIVE is not enabled in buildroot.config"
fi

if grep -q "^BR2_PACKAGE_LIBCURL=y$" "$CONFIG_FILE" && grep -q "^BR2_PACKAGE_OPENSSL=y$" "$CONFIG_FILE"; then
	pass "libcurl and OpenSSL are enabled for HTTPS repository downloads"
else
	fail "libcurl or OpenSSL is not enabled in buildroot.config"
fi

echo "=== Test 2: opkg.conf Configuration and Architecture ==="
OPKG_CONF="$OVERLAY/etc/opkg.conf"
[ -f "$OPKG_CONF" ] || { fail "$OPKG_CONF missing"; exit 1; }

if grep -q "dest root /" "$OPKG_CONF"; then
	pass "opkg.conf defines root destination"
else
	fail "opkg.conf missing dest root declaration"
fi

if ! grep -q "dest opt /opt" "$OPKG_CONF"; then
	pass "opkg.conf omits redundant dest opt (avoids /opt//opt path duplication on read-only SquashFS)"
else
	fail "opkg.conf still contains redundant dest opt /opt"
fi

if grep -q "arch mipsel-3.4" "$OPKG_CONF" && grep -q "arch mipsel" "$OPKG_CONF"; then
	pass "opkg.conf declares mipsel-3.4 and mipsel architecture priorities matching Entware feed"
else
	fail "opkg.conf missing mipsel-3.4 or mipsel architecture definitions"
fi

if grep -q "src/gz entware http://bin.entware.net/mipselsf-k3.4" "$OPKG_CONF"; then
	pass "opkg.conf configures Entware mipselsf repository feed"
else
	fail "opkg.conf missing Entware repository feed"
fi

if grep -q "option overlay_root /usr/data" "$OPKG_CONF" && grep -q "option force_space 1" "$OPKG_CONF"; then
	pass "opkg.conf configures overlay_root and force_space for SquashFS read-only root"
else
	fail "opkg.conf missing overlay_root or force_space options"
fi

if [ -L "$OVERLAY/etc/opkg/opkg.conf" ]; then
	pass "/etc/opkg/opkg.conf symlink correctly points to /etc/opkg.conf"
else
	fail "/etc/opkg/opkg.conf symlink missing"
fi

echo "=== Test 3: /opt Symlinks & Persistent Storage Layout ==="
for dir in bin sbin lib etc share var; do
	target=$(readlink "$OVERLAY/opt/$dir" 2>/dev/null || echo "")
	if [ "$target" = "/usr/data/opt/$dir" ]; then
		pass "/opt/$dir correctly symlinks to /usr/data/opt/$dir"
	else
		fail "/opt/$dir does not symlink to /usr/data/opt/$dir (got: '$target')"
	fi
done

tmp_target=$(readlink "$OVERLAY/opt/tmp" 2>/dev/null || echo "")
if [ "$tmp_target" = "/tmp" ]; then
	pass "/opt/tmp correctly symlinks to /tmp"
else
	fail "/opt/tmp does not symlink to /tmp (got: '$tmp_target')"
fi

echo "=== Test 4: Environment Profile Integration ==="
PROFILE_SH="$OVERLAY/etc/profile.d/10-rosetteos-opkg.sh"
[ -f "$PROFILE_SH" ] || { fail "$PROFILE_SH missing"; exit 1; }

if grep -q 'export PATH="/opt/bin:/opt/sbin:/usr/data/rosetteos/bin:$PATH"' "$PROFILE_SH"; then
	pass "10-rosetteos-opkg.sh exports /opt/bin and /opt/sbin in PATH"
else
	fail "10-rosetteos-opkg.sh missing PATH export"
fi

if grep -q 'export LD_LIBRARY_PATH="/opt/lib' "$PROFILE_SH"; then
	pass "10-rosetteos-opkg.sh exports /opt/lib in LD_LIBRARY_PATH"
else
	fail "10-rosetteos-opkg.sh missing LD_LIBRARY_PATH export"
fi

echo "=== Test 5: Persistent Storage Initialization (S01persistent-datastore) ==="
S01="$OVERLAY/etc/init.d/S01persistent-datastore"
[ -f "$S01" ] || { fail "$S01 missing"; exit 1; }

if grep -q "mkdir -p /usr/data/opt/bin" "$S01" && grep -q "/usr/data/opt/var/lib/opkg" "$S01"; then
	pass "S01persistent-datastore initializes /usr/data/opt directories and opkg database path"
else
	fail "S01persistent-datastore does not initialize /usr/data/opt structure"
fi

if grep -q "ld-linux.so.2" "$S01"; then
	pass "S01persistent-datastore provides dynamic linker compatibility link"
else
	fail "S01persistent-datastore missing dynamic linker compatibility link"
fi

echo ""
echo "=========================================="
echo "RosetteOS Package Manager Tests: $PASS passed, $FAIL failed"
echo "=========================================="
[ "$FAIL" -eq 0 ]
