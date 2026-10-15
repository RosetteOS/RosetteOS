#!/bin/sh
#
# Offline tests for RosetteOS Factory Reset service (S58factoryreset)
# and CLI tool (rosetteos-factory-reset).
#
# Usage: sh tests/factory-reset-tests.sh
#

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
SERVICE_SCRIPT="$REPO_ROOT/scripts/build/overlay/etc/init.d/S58factoryreset"
CLI_SCRIPT="$REPO_ROOT/scripts/build/overlay/usr/sbin/rosetteos-factory-reset"
MOCK_PID=""
WORK=$(mktemp -d "${TMPDIR:-/tmp}/factory-reset-tests.XXXXXX")
trap 'kill "$MOCK_PID" 2>/dev/null || true; rm -rf "$WORK"' EXIT INT TERM

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

# --- Test 1: Executable and presence checks ---
echo "=== Test 1: Executable and presence checks ==="
if [ -x "$SERVICE_SCRIPT" ]; then
	pass "S58factoryreset is executable"
else
	fail "S58factoryreset is not executable"
fi

if [ -x "$CLI_SCRIPT" ]; then
	pass "rosetteos-factory-reset is executable"
else
	fail "rosetteos-factory-reset is not executable"
fi

# --- Test 2: CLI help and non-interactive safeguard ---
echo "=== Test 2: CLI help and non-interactive safeguard ==="
if sh "$CLI_SCRIPT" --help | grep -q "Usage: rosetteos-factory-reset"; then
	pass "rosetteos-factory-reset --help prints usage"
else
	fail "rosetteos-factory-reset --help failed"
fi

if ( sh "$CLI_SCRIPT" </dev/null >/dev/null 2>&1 ); then
	fail "rosetteos-factory-reset without --confirm should fail non-interactively"
else
	pass "rosetteos-factory-reset refuses non-interactive run without --confirm"
fi

# --- Test 3: S58factoryreset start with no USB flag (normal boot) ---
echo "=== Test 3: Normal boot (no USB emergency flag) ==="
T3_USB="$WORK/t3_usb"
mkdir -p "$T3_USB"

T3_OUT=$(USB_SEARCH_PATHS="$T3_USB" DO_REBOOT=0 sh "$SERVICE_SCRIPT" start)
rc=$?
if [ $rc -eq 0 ] && [ -z "$T3_OUT" ]; then
	pass "S58factoryreset start with no USB flag returns 0 cleanly with no action"
else
	fail "S58factoryreset start did not handle absence of flag cleanly (rc=$rc)"
fi

# --- Test 4: S58factoryreset start with USB emergency flag ---
echo "=== Test 4: USB emergency factory reset flag consumption ==="
T4_USB="$WORK/t4_usb"
mkdir -p "$T4_USB/sda1"
touch "$T4_USB/sda1/emergency_factory_reset"

MOCK_EEPROM="$WORK/t4_eeprom"
MOCK_OVERLAY="$WORK/t4_overlay.img"
MOCK_OTA="$WORK/t4_ota.bin"
MOCK_DATA="$WORK/t4_data.img"
MOCK_MOUNT="$WORK/t4_mnt"
mkdir -p "$MOCK_MOUNT"

# Prepare mock files
dd if=/dev/urandom of="$MOCK_EEPROM" bs=128 count=32 2>/dev/null
dd if=/dev/zero of="$MOCK_OVERLAY" bs=1M count=2 2>/dev/null
dd if=/dev/zero of="$MOCK_DATA" bs=1M count=4 2>/dev/null
printf "ota:kernel\n" > "$MOCK_OTA"

USB_SEARCH_PATHS="$T4_USB" \
DEV_EEPROM="$MOCK_EEPROM" \
DEV_OVERLAY="$MOCK_OVERLAY" \
DEV_OTA="$MOCK_OTA" \
DEV_DATA="$MOCK_DATA" \
DATA_MOUNT="$MOCK_MOUNT" \
DO_REBOOT=0 \
DO_SWAPOFF=0 \
DO_SERVICE_STOP=0 \
sh "$SERVICE_SCRIPT" start > "$WORK/t4.log" 2>&1

if [ ! -f "$T4_USB/sda1/emergency_factory_reset" ] && [ -f "$T4_USB/sda1/emergency_factory_reset.old" ]; then
	pass "USB emergency_factory_reset flag was consumed and renamed to .old"
else
	fail "USB emergency_factory_reset flag was not properly renamed"
fi

# --- Test 5: External configs reset (EEPROM, OTA marker, Overlay) ---
echo "=== Test 5: External configurations reset ==="
# Check EEPROM was zeroed
non_zero_count=$(od -An -vtu1 "$MOCK_EEPROM" | tr -s ' ' '\n' | grep -v '^0$' | grep -c '^[0-9]' || true)
if [ "$non_zero_count" -eq 0 ]; then
	pass "I2C EEPROM PLR journal was cleared with zeroes"
else
	fail "I2C EEPROM PLR journal still contains non-zero bytes"
fi

# Check OTA marker points to kernel2
ota_val=$(cat "$MOCK_OTA" 2>/dev/null | tr -d '\r\n')
if [ "$ota_val" = "ota:kernel2" ]; then
	pass "OTA boot marker is verified to active RosetteOS slot (ota:kernel2)"
else
	fail "OTA boot marker has unexpected value: $ota_val"
fi

# --- Test 6: Data partition formatting ---
echo "=== Test 6: Data partition formatting ==="
if grep -q "formatting data partition" "$WORK/t4.log"; then
	pass "Data partition format routine was triggered"
else
	fail "Data partition formatting step was not logged"
fi

if grep -q "=== FACTORY RESET COMPLETE ===" "$WORK/t4.log"; then
	pass "Factory reset finished successfully"
else
	fail "Factory reset did not reach completion banner"
fi

# --- Test 7: CLI invocation of reset ---
echo "=== Test 7: CLI invocation via rosetteos-factory-reset --confirm ==="
T7_DATA="$WORK/t7_data.img"
T7_EEPROM="$WORK/t7_eeprom"
T7_OTA="$WORK/t7_ota.bin"
dd if=/dev/urandom of="$T7_EEPROM" bs=128 count=32 2>/dev/null
dd if=/dev/zero of="$T7_DATA" bs=1M count=4 2>/dev/null
echo "test" > "$T7_OTA"

FACTORY_RESET_SCRIPT="$SERVICE_SCRIPT" \
DEV_EEPROM="$T7_EEPROM" \
DEV_OVERLAY="/dev/null" \
DEV_OTA="$T7_OTA" \
DEV_DATA="$T7_DATA" \
DATA_MOUNT="$WORK/t7_mnt" \
DO_REBOOT=0 \
DO_SWAPOFF=0 \
DO_SERVICE_STOP=0 \
sh "$CLI_SCRIPT" --confirm > "$WORK/t7.log" 2>&1
rc=$?

if [ $rc -eq 0 ] && grep -q "=== FACTORY RESET COMPLETE ===" "$WORK/t7.log"; then
	pass "rosetteos-factory-reset --confirm executed factory reset cleanly"
else
	fail "rosetteos-factory-reset --confirm failed (rc=$rc)"
fi

# --- Test 8: Print and thermal safety safeguards ---
echo "=== Test 8: Print and thermal safety safeguards ==="
MOCK_PORT_FILE="$WORK/mock_moonraker_port"
python3 -c '
import http.server, socketserver, json, sys

state = {"state": "printing", "ext_temp": 25.0, "ext_target": 0.0, "bed_temp": 25.0, "bed_target": 0.0}

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args): pass
    def do_GET(self):
        if self.path.startswith("/set_state"):
            q = self.path.split("?", 1)[1]
            for p in q.split("&"):
                k, v = p.split("=")
                if k in ("ext_temp", "ext_target", "bed_temp", "bed_target"): state[k] = float(v)
                else: state[k] = v
            self.send_response(200); self.end_headers(); self.wfile.write(b"ok")
            return
        payload = {
            "result": {
                "status": {
                    "print_stats": {"state": state["state"]},
                    "extruder": {"target": state["ext_target"], "temperature": state["ext_temp"]},
                    "heater_bed": {"target": state["bed_target"], "temperature": state["bed_temp"]}
                }
            }
        }
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(payload).encode())

with socketserver.TCPServer(("127.0.0.1", 0), Handler) as httpd:
    port = httpd.server_address[1]
    with open(sys.argv[1], "w") as f:
        f.write(str(port))
    httpd.serve_forever()
' "$MOCK_PORT_FILE" &
MOCK_PID=$!

waited=0
while [ ! -s "$MOCK_PORT_FILE" ]; do
	sleep 0.05
	waited=$((waited + 1))
	if [ "$waited" -gt 60 ]; then
		fail "Mock Moonraker server failed to start within 3s"
		break
	fi
done
M_PORT=$(cat "$MOCK_PORT_FILE")
MOCK_URL="http://127.0.0.1:$M_PORT"

# 8a: Print active -> blocked without --force
if ROSETTEOS_MOONRAKER_URL="$MOCK_URL" FACTORY_RESET_SCRIPT="$SERVICE_SCRIPT" \
   DEV_EEPROM="$T7_EEPROM" DEV_OVERLAY="/dev/null" DEV_OTA="$T7_OTA" DEV_DATA="$T7_DATA" \
   DATA_MOUNT="$WORK/t7_mnt" DO_REBOOT=0 DO_SWAPOFF=0 DO_SERVICE_STOP=0 sh "$CLI_SCRIPT" --confirm >/dev/null 2>&1; then
	fail "rosetteos-factory-reset should be blocked while printing"
else
	pass "rosetteos-factory-reset blocked while printing"
fi

# 8b: Print active -> allowed with --force
if ROSETTEOS_MOONRAKER_URL="$MOCK_URL" FACTORY_RESET_SCRIPT="$SERVICE_SCRIPT" \
   DEV_EEPROM="$T7_EEPROM" DEV_OVERLAY="/dev/null" DEV_OTA="$T7_OTA" DEV_DATA="$T7_DATA" \
   DATA_MOUNT="$WORK/t7_mnt" DO_REBOOT=0 DO_SWAPOFF=0 DO_SERVICE_STOP=0 sh "$CLI_SCRIPT" --confirm --force >/dev/null 2>&1; then
	pass "rosetteos-factory-reset --force overrides active print guard"
else
	fail "rosetteos-factory-reset --force failed to override active print guard"
fi

# 8c: Standby but hotend hot (> 60C) -> blocked without --force
curl -s "$MOCK_URL/set_state?state=standby&ext_temp=75.0&ext_target=0&bed_temp=25.0&bed_target=0" >/dev/null
if ROSETTEOS_MOONRAKER_URL="$MOCK_URL" FACTORY_RESET_SCRIPT="$SERVICE_SCRIPT" \
   DEV_EEPROM="$T7_EEPROM" DEV_OVERLAY="/dev/null" DEV_OTA="$T7_OTA" DEV_DATA="$T7_DATA" \
   DATA_MOUNT="$WORK/t7_mnt" DO_REBOOT=0 DO_SWAPOFF=0 DO_SERVICE_STOP=0 sh "$CLI_SCRIPT" --confirm >/dev/null 2>&1; then
	fail "rosetteos-factory-reset should be blocked while hotend is hot (75C)"
else
	pass "rosetteos-factory-reset blocked while hotend is hot (75C)"
fi

# 8d: Standby but bed hot (> 55C) -> blocked without --force
curl -s "$MOCK_URL/set_state?state=standby&ext_temp=25.0&ext_target=0&bed_temp=65.0&bed_target=0" >/dev/null
if ROSETTEOS_MOONRAKER_URL="$MOCK_URL" FACTORY_RESET_SCRIPT="$SERVICE_SCRIPT" \
   DEV_EEPROM="$T7_EEPROM" DEV_OVERLAY="/dev/null" DEV_OTA="$T7_OTA" DEV_DATA="$T7_DATA" \
   DATA_MOUNT="$WORK/t7_mnt" DO_REBOOT=0 DO_SWAPOFF=0 DO_SERVICE_STOP=0 sh "$CLI_SCRIPT" --confirm >/dev/null 2>&1; then
	fail "rosetteos-factory-reset should be blocked while bed is hot (65C)"
else
	pass "rosetteos-factory-reset blocked while bed is hot (65C)"
fi

# 8e: Thermal override with --force
if ROSETTEOS_MOONRAKER_URL="$MOCK_URL" FACTORY_RESET_SCRIPT="$SERVICE_SCRIPT" \
   DEV_EEPROM="$T7_EEPROM" DEV_OVERLAY="/dev/null" DEV_OTA="$T7_OTA" DEV_DATA="$T7_DATA" \
   DATA_MOUNT="$WORK/t7_mnt" DO_REBOOT=0 DO_SWAPOFF=0 DO_SERVICE_STOP=0 sh "$CLI_SCRIPT" --confirm --force >/dev/null 2>&1; then
	pass "rosetteos-factory-reset --force overrides thermal safeguard"
else
	fail "rosetteos-factory-reset --force failed to override thermal safeguard"
fi

kill "$MOCK_PID" 2>/dev/null || true
MOCK_PID=""

echo ""
echo "Summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
