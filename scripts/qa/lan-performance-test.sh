#!/bin/sh
# NebulaOS local-LAN Wi-Fi performance test (pre-qualification mission
# Phase A9, 2026-07-31 - see docs/NEBULAOS_CAMERA_USB_RT_SOURCE_ANALYSIS.md
# sec 18.18 Stage B). Meant to be scp'd over and run directly ON the
# printer against a real LAN test host on the same network - never a
# public-internet endpoint (this project's own explicit, repeated
# requirement: NebulaOS must work, and be testable, on an internet-less
# LAN).
#
# Ping-based latency/loss/percentiles use BusyBox's own real `ping`
# applet (CONFIG_PING=y, already present) parsing its per-packet output -
# no new package needed. TCP throughput uses plain python3 (already
# present for Klipper/Moonraker, guaranteed on every image) rather than
# iperf3 (not currently packaged, and per this mission's own Phase A8
# diagnostic-tooling philosophy, a throughput tool doesn't belong baked
# into the production image either) - this needs a small matching
# receiver/sender running on the LAN test host, printed by this script's
# own --help text so the exact peer-side commands are never guessed at
# test time.
#
# Usage: lan-performance-test.sh <lan-test-host-ip> [output-file] [port]
#
# Requires a LAN test host reachable at <lan-test-host-ip> (a real
# on-the-same-network machine - a laptop, a Raspberry Pi, anything with
# python3) - this script does not, and must never, depend on internet
# reachability for any of its measurements.

set -u

HOST="${1:-}"
OUT="${2:-/usr/data/staging/benchmarks/lan-perf-$(date -u +%Y%m%dT%H%M%SZ).txt}"
PORT="${3:-52301}"
PING_COUNT=30

if [ -z "$HOST" ] || [ "$HOST" = "--help" ]; then
	cat <<EOF
usage: $0 <lan-test-host-ip> [output-file] [port]

On the LAN test host, before running this script, start a receiver for
the upload-direction throughput test:
    python3 -c "
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('0.0.0.0', $PORT)); s.listen(1)
print('waiting for upload test connection on port $PORT...')
conn, _ = s.accept()
total = 0
while True:
    chunk = conn.recv(65536)
    if not chunk: break
    total += len(chunk)
print('received', total, 'bytes')
"

For the download-direction test, run this instead on the LAN host:
    python3 -c "
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('0.0.0.0', $((PORT + 1)))); s.listen(1)
print('waiting for download test connection on port $((PORT + 1))...')
conn, _ = s.accept()
data = b'0' * 65536
for _ in range(160):  # ~10MB
    conn.sendall(data)
conn.close()
"
EOF
	exit 1
fi

mkdir -p "$(dirname "$OUT")"

# --- ping: median/P95/P99/loss, parsed from real per-packet output ------

PING_RAW=$(ping -c "$PING_COUNT" -W 2 "$HOST" 2>&1)
PING_TIMES=$(echo "$PING_RAW" | sed -n 's/.*time=\([0-9.]*\).*/\1/p')
# Tolerant of both BusyBox ping's and iputils ping's slightly different
# summary-line wording ("X packets received" vs "X received").
PING_SENT=$(echo "$PING_RAW" | sed -n 's/^\([0-9]*\) packets transmitted.*/\1/p')
PING_RECEIVED=$(echo "$PING_RAW" | grep -oE '[0-9]+ (packets )?received' | grep -oE '^[0-9]+')

if [ -n "$PING_TIMES" ]; then
	SORTED=$(echo "$PING_TIMES" | sort -n)
	N=$(echo "$SORTED" | wc -l)
	MEDIAN_LINE=$(( (N + 1) / 2 ))
	P95_LINE=$(( (N * 95 + 99) / 100 ))
	P99_LINE=$(( (N * 99 + 99) / 100 ))
	[ "$P95_LINE" -gt "$N" ] && P95_LINE="$N"
	[ "$P99_LINE" -gt "$N" ] && P99_LINE="$N"
	PING_MEDIAN=$(echo "$SORTED" | sed -n "${MEDIAN_LINE}p")
	PING_P95=$(echo "$SORTED" | sed -n "${P95_LINE}p")
	PING_P99=$(echo "$SORTED" | sed -n "${P99_LINE}p")
else
	PING_MEDIAN="n/a"
	PING_P95="n/a"
	PING_P99="n/a"
fi

if [ -n "$PING_SENT" ] && [ "$PING_SENT" -gt 0 ] 2>/dev/null; then
	PACKET_LOSS_PCT=$(( (PING_SENT - ${PING_RECEIVED:-0}) * 100 / PING_SENT ))
else
	PACKET_LOSS_PCT="n/a"
fi

# --- TCP throughput (best-effort, requires the matching peer commands
# from --help to already be running on the LAN host) ---------------------

UPLOAD_BYTES=$((10 * 1024 * 1024))
UPLOAD_RESULT="skipped (no matching receiver detected or connection failed)"
UPLOAD_T0=$(date +%s%N 2>/dev/null)
if python3 -c "
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(5)
try:
    s.connect(('$HOST', $PORT))
except Exception as e:
    sys.exit(1)
s.settimeout(None)
data = b'0' * 65536
sent = 0
target = $UPLOAD_BYTES
while sent < target:
    s.sendall(data)
    sent += len(data)
s.close()
" 2>/dev/null; then
	UPLOAD_T1=$(date +%s%N 2>/dev/null)
	if [ -n "$UPLOAD_T0" ] && [ -n "$UPLOAD_T1" ] && [ "$UPLOAD_T1" -gt "$UPLOAD_T0" ] 2>/dev/null; then
		UPLOAD_SECONDS_X1000=$(( (UPLOAD_T1 - UPLOAD_T0) / 1000000 ))
		if [ "$UPLOAD_SECONDS_X1000" -gt 0 ]; then
			UPLOAD_MBPS=$(( (UPLOAD_BYTES / 1024 / 1024) * 8000 / UPLOAD_SECONDS_X1000 ))
			UPLOAD_RESULT="${UPLOAD_MBPS} Mbps (${UPLOAD_BYTES} bytes in ${UPLOAD_SECONDS_X1000}ms)"
		fi
	fi
fi

{
	echo "RosetteOS LAN performance test - host=$HOST $(date -u +%Y%m%dT%H%M%SZ)"
	echo ""
	echo "=== ping ($PING_COUNT packets, LAN host, never a public endpoint) ==="
	echo "sent=${PING_SENT:-n/a} received=${PING_RECEIVED:-n/a} loss=${PACKET_LOSS_PCT}%"
	echo "median=${PING_MEDIAN}ms p95=${PING_P95}ms p99=${PING_P99}ms"
	echo ""
	echo "=== TCP upload throughput (device -> LAN host) ==="
	echo "$UPLOAD_RESULT"
	echo "(requires the matching python3 receiver from '$0 --help' already"
	echo " running on the LAN host - a 'skipped' result above most likely"
	echo " means that wasn't running, not that throughput was actually zero)"
	echo ""
	echo "raw ping output:"
	echo "$PING_RAW"
} > "$OUT"

echo "wrote $OUT"
