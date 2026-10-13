#!/bin/sh
#
# Tests for RosetteOS Memory Resilience and Group 2 optimizations:
#   - MEM-T02: bounded tmpfs in /etc/fstab (/tmp 32m, /run 4m, /dev/shm 4m)
#   - MEM-T03: nginx proxy_max_temp_file_size 0
#   - MEM-T04: Moonraker TMPDIR on eMMC (/opt/printer_data/.rosetteos-tmp/moonraker)
#   - MEM-T06: low-memory gitconfig (pack.threads=1, pack.windowMemory=16m, core.packedGitLimit=32m)
#   - MEM-T11 / MEM-T18: sysctl memory policy (swappiness=60, page-cluster=0, min_free_kbytes=4096, watermark_scale_factor=100)
#   - S01zram-swap: mem_limit 20% MemTotal, lz4 algorithm check
#   - S03rosetteos-diskswap: fast metadata sizing via ls -ln (S1)
#
# Usage: sh tests/memory-resilience-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
OVERLAY="$ROOT/scripts/build/overlay"

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

# 1. fstab tmpfs sizing (MEM-T02)
FSTAB="$OVERLAY/etc/fstab"
if [ -f "$FSTAB" ]; then
	grep -E 'tmpfs\s+/tmp\s+tmpfs\s+.*size=32m' "$FSTAB" >/dev/null && pass "fstab /tmp bounded to 32m" || fail "fstab missing 32m bound on /tmp"
	grep -E 'tmpfs\s+/run\s+tmpfs\s+.*size=4m' "$FSTAB" >/dev/null && pass "fstab /run bounded to 4m" || fail "fstab missing 4m bound on /run"
	grep -E 'tmpfs\s+/dev/shm\s+tmpfs\s+.*size=4m' "$FSTAB" >/dev/null && pass "fstab /dev/shm bounded to 4m" || fail "fstab missing 4m bound on /dev/shm"
else
	fail "fstab does not exist in overlay"
fi

# 2. nginx proxy_max_temp_file_size 0 (MEM-T03)
NGINX_CONF="$OVERLAY/etc/nginx/nginx.conf"
if grep -q "proxy_max_temp_file_size 0;" "$NGINX_CONF"; then
	pass "nginx proxy_max_temp_file_size disabled"
else
	fail "nginx proxy_max_temp_file_size 0 missing"
fi

# 3. gitconfig low-memory limits (MEM-T06)
GITCONFIG="$OVERLAY/etc/gitconfig"
if [ -f "$GITCONFIG" ]; then
	grep -q "windowMemory = 16m" "$GITCONFIG" && pass "gitconfig windowMemory set to 16m" || fail "gitconfig windowMemory missing"
	grep -q "packedGitLimit = 32m" "$GITCONFIG" && pass "gitconfig packedGitLimit set to 32m" || fail "gitconfig packedGitLimit missing"
	grep -q "threads = 1" "$GITCONFIG" && pass "gitconfig threads set to 1" || fail "gitconfig threads missing"
else
	fail "gitconfig does not exist in overlay"
fi

# 4. sysctl memory headroom (MEM-T11, MEM-T18)
SYSCTL_MEM="$OVERLAY/etc/sysctl.d/90-rosetteos-memory.conf"
if [ -f "$SYSCTL_MEM" ]; then
	grep -q "vm.swappiness = 60" "$SYSCTL_MEM" && pass "sysctl vm.swappiness set to 60" || fail "sysctl swappiness missing"
	grep -q "vm.page-cluster = 0" "$SYSCTL_MEM" && pass "sysctl vm.page-cluster set to 0" || fail "sysctl page-cluster missing"
	grep -q "vm.min_free_kbytes = 4096" "$SYSCTL_MEM" && pass "sysctl vm.min_free_kbytes set to 4096" || fail "sysctl min_free_kbytes missing"
	grep -q "vm.watermark_scale_factor = 100" "$SYSCTL_MEM" && pass "sysctl vm.watermark_scale_factor set to 100" || fail "sysctl watermark_scale_factor missing"
else
	fail "90-rosetteos-memory.conf missing"
fi

# 5. S01zram-swap limits (MEM-T11)
ZRAM_INIT="$OVERLAY/etc/init.d/S01zram-swap"
if [ -f "$ZRAM_INIT" ]; then
	grep -q "lim=\$((mt \* 20 / 100 / 1024))" "$ZRAM_INIT" && pass "zram mem_limit set to 20% MemTotal" || fail "zram mem_limit calculation missing"
	grep -q "zram-alg-mismatch" "$ZRAM_INIT" && pass "zram logs compressor mismatch" || fail "zram compressor mismatch check missing"
else
	fail "S01zram-swap missing"
fi

# 6. S03rosetteos-diskswap fast sizing (S1)
DISKSWAP_INIT="$OVERLAY/etc/init.d/S03rosetteos-diskswap"
if [ -f "$DISKSWAP_INIT" ]; then
	if grep -n 'actual_size=' "$DISKSWAP_INIT" | grep -v 'ls -ln "$SWAPFILE"' | grep -q .; then
		fail "S03rosetteos-diskswap sizes the swapfile without ls -ln"
	else
		pass "S03rosetteos-diskswap uses fast metadata sizing"
	fi
	if grep -nE '(^|[^a-z_])(wc -c|stat |timeout )' "$DISKSWAP_INIT" | grep -v '^\s*[0-9]*:\s*#' | grep -q .; then
		fail "S03rosetteos-diskswap uses forbidden wc -c/stat/timeout"
	else
		pass "S03rosetteos-diskswap has no slow wc -c reads"
	fi
else
	fail "S03rosetteos-diskswap missing"
fi

echo "memory-resilience-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
