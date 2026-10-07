#!/bin/sh
#
# Multi-printer profile management and validation tests for RosetteOS / NebulaOS.
# Tests profile repository integrity, rosetteos-profile CLI, per-printer state preservation,
# bidirectional config restoration, and S02nebulaos-namespace first-boot USB provisioning.
#
# Usage: sh tests/rosetteos-multi-printer-profile-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
PROFILE_MGR="$REPO_ROOT/scripts/build/overlay/usr/bin/rosetteos-profile"
PROFILES_SRC="$REPO_ROOT/scripts/build/overlay/opt/rosetteos-seeds/printer_profiles"
S02_SCRIPT="$REPO_ROOT/scripts/build/overlay/etc/init.d/S02rosetteos-namespace"

WORK=$(mktemp -d "/tmp/multi-printer-tests.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM

PASS=0
FAIL=0

fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

echo "=== Test 1: Validate profile repository and required models ==="
if [ ! -d "$PROFILES_SRC" ]; then
    fail "Profiles directory missing: $PROFILES_SRC"
else
    pass "Profiles directory exists"
fi

for model in "creality-ender3-v3-ke" "creality-ender3-v3-se" "creality-ender3-s1" "creality-ender3-v2-neo" "creality-ender3-v2" "creality-ender3-pro" "creality-ender3"; do
    if [ ! -d "$PROFILES_SRC/$model" ]; then
        fail "Profile directory for $model missing"
    elif [ ! -f "$PROFILES_SRC/$model/profile.json" ]; then
        fail "profile.json for $model missing"
    elif [ ! -f "$PROFILES_SRC/$model/printer.cfg" ]; then
        fail "printer.cfg for $model missing"
    else
        pass "Profile $model has valid profile.json and printer.cfg"
    fi
done

echo "=== Test 2: Test rosetteos-profile list and get ==="
ROSETTEOS_PROFILES_SEEDS="$PROFILES_SRC" \
ROSETTEOS_USER_PROFILES="$WORK/user_profiles" \
ROSETTEOS_SYSTEM_DIR="$WORK/system" \
ROSETTEOS_CONFIG_DIR="$WORK/config" \
ROSETTEOS_BACKUP_DIR="$WORK/backups" \
ROSETTEOS_ACTIVE_MARKER="$WORK/system/active-profile.json" \
python3 "$PROFILE_MGR" list --json > "$WORK/list.json" 2>/dev/null

if [ ! -s "$WORK/list.json" ]; then
    fail "rosetteos-profile list --json returned empty output"
else
    count=$(grep -c '"id":' "$WORK/list.json")
    if [ "$count" -eq 3 ]; then
        pass "rosetteos-profile list returned $count enabled profiles (V3 KE, V3 SE, and V2 Neo)"
    else
        fail "rosetteos-profile list returned $count profiles (expected 3 enabled)"
    fi
fi

# Test --all flag
ROSETTEOS_PROFILES_SEEDS="$PROFILES_SRC" \
ROSETTEOS_USER_PROFILES="$WORK/user_profiles" \
ROSETTEOS_SYSTEM_DIR="$WORK/system" \
ROSETTEOS_CONFIG_DIR="$WORK/config" \
ROSETTEOS_BACKUP_DIR="$WORK/backups" \
ROSETTEOS_ACTIVE_MARKER="$WORK/system/active-profile.json" \
python3 "$PROFILE_MGR" list --all --json > "$WORK/list_all.json" 2>/dev/null

all_count=$(grep -c '"id":' "$WORK/list_all.json")
if [ "$all_count" -ge 7 ]; then
    pass "rosetteos-profile list --all returned all $all_count profiles"
else
    fail "rosetteos-profile list --all returned only $all_count profiles (expected >= 7)"
fi

ROSETTEOS_PROFILES_SEEDS="$PROFILES_SRC" \
ROSETTEOS_USER_PROFILES="$WORK/user_profiles" \
ROSETTEOS_SYSTEM_DIR="$WORK/system" \
ROSETTEOS_CONFIG_DIR="$WORK/config" \
ROSETTEOS_BACKUP_DIR="$WORK/backups" \
ROSETTEOS_ACTIVE_MARKER="$WORK/system/active-profile.json" \
python3 "$PROFILE_MGR" get --json > "$WORK/current.json" 2>/dev/null

if grep -q '"id": "creality-ender3-v3-ke"' "$WORK/current.json"; then
    pass "Default active profile correctly reports creality-ender3-v3-ke"
else
    fail "Default active profile did not report creality-ender3-v3-ke"
fi

echo "=== Test 3: Bidirectional Profile State Preservation & Restoration ==="
mkdir -p "$WORK/config"
echo "# KE Customized Calibration (z_offset = 1.950)" > "$WORK/config/printer.cfg"

# Switch KE -> SE
ROSETTEOS_PROFILES_SEEDS="$PROFILES_SRC" \
ROSETTEOS_USER_PROFILES="$WORK/user_profiles" \
ROSETTEOS_SYSTEM_DIR="$WORK/system" \
ROSETTEOS_CONFIG_DIR="$WORK/config" \
ROSETTEOS_BACKUP_DIR="$WORK/backups" \
ROSETTEOS_ACTIVE_MARKER="$WORK/system/active-profile.json" \
python3 "$PROFILE_MGR" set creality-ender3-v3-se --quiet

if grep -q 'Ender-3 V3 SE' "$WORK/config/printer.cfg"; then
    pass "Applied Ender-3 V3 SE configuration to printer.cfg"
else
    fail "printer.cfg was not updated with Ender-3 V3 SE content"
fi

if [ -f "$WORK/user_profiles/creality-ender3-v3-ke/printer.cfg" ]; then
    pass "Saved KE customized config to user profile slot"
else
    fail "KE customized config was not saved to user profile slot"
fi

backup_count=$(ls -1 "$WORK/backups"/printer.cfg.* 2>/dev/null | wc -l)
if [ "$backup_count" -ge 1 ]; then
    pass "Created historical timestamped backup ($backup_count found)"
else
    fail "No backup file was created during profile switch"
fi

# Customize SE config
echo "# SE Customized Calibration (z_offset = -0.320)" >> "$WORK/config/printer.cfg"

# Switch SE -> KE (Should restore customized KE config!)
ROSETTEOS_PROFILES_SEEDS="$PROFILES_SRC" \
ROSETTEOS_USER_PROFILES="$WORK/user_profiles" \
ROSETTEOS_SYSTEM_DIR="$WORK/system" \
ROSETTEOS_CONFIG_DIR="$WORK/config" \
ROSETTEOS_BACKUP_DIR="$WORK/backups" \
ROSETTEOS_ACTIVE_MARKER="$WORK/system/active-profile.json" \
python3 "$PROFILE_MGR" set creality-ender3-v3-ke --quiet

if grep -q 'z_offset = 1.950' "$WORK/config/printer.cfg"; then
    pass "Successfully restored previous custom KE configuration on switch back"
else
    fail "Failed to restore custom KE configuration on switch back"
fi

if grep -q 'z_offset = -0.320' "$WORK/user_profiles/creality-ender3-v3-se/printer.cfg"; then
    pass "SE customized configuration safely saved to user profile slot"
else
    fail "SE customized configuration was not preserved"
fi

echo "=== Test 4: S02rosetteos-namespace First-Boot USB Override ==="
NS_WORK="$WORK/ns_test"
mkdir -p "$NS_WORK/usr/data/rosetteos" "$NS_WORK/boot"
echo "creality-ender3-v3-se" > "$NS_WORK/boot/rosetteos-profile.txt"

(
    export ROSETTEOS_ROOT="$NS_WORK/usr/data/rosetteos"
    export PRINTER_DATA_CONFIG_SEED="$REPO_ROOT/scripts/build/overlay/opt/printer_data/config"
    export PRINTER_DATA_CONFIG_MARKER="$ROSETTEOS_ROOT/system/printer-data-config-seeded.json"
    export PRINTER_PROFILES_SEED="$PROFILES_SRC"
    export PRINTER_PROFILES_MARKER="$ROSETTEOS_ROOT/system/printer-profiles-seeded.json"
    export S02ROSETTEOS_NAMESPACE_NO_AUTORUN=1
    . "$S02_SCRIPT"
    start
) >/dev/null 2>&1

if [ -f "$NS_WORK/usr/data/rosetteos/printer_data/config/printer.cfg" ]; then
    pass "S02 seeded initial printer_data/config successfully"
else
    fail "S02 failed to seed initial printer_data/config"
fi

if [ -f "$NS_WORK/usr/data/rosetteos/system/active-profile.json" ]; then
    pass "S02 created active-profile.json metadata"
else
    fail "S02 missing active-profile.json metadata"
fi

if [ -f "$NS_WORK/usr/data/rosetteos/printer_profiles/creality-ender3-v3-ke/profile.json" ]; then
    pass "S02 seeded printer_profiles repository successfully"
else
    fail "S02 failed to seed printer_profiles repository"
fi

echo "=== Test 5: Safety Interlocks & Print-in-Progress Protection ==="
# Start a lightweight mock Moonraker server returning state: printing
python3 -c "
import http.server, socketserver, json

class MockHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-type', 'application/json')
        self.end_headers()
        resp = {'result': {'status': {'print_stats': {'state': 'printing'}}}}
        self.wfile.write(json.dumps(resp).encode())
    def log_message(self, format, *args):
        pass

class ReusableTCPServer(socketserver.TCPServer):
    allow_reuse_address = True

with ReusableTCPServer(('127.0.0.1', 0), MockHandler) as httpd:
    port = httpd.server_address[1]
    with open('$WORK/mock_port.txt', 'w') as f:
        f.write(str(port))
    httpd.serve_forever()
" >/dev/null 2>&1 &
MOCK_PID=$!

python3 -c "
import time, os
for _ in range(50):
    if os.path.exists('$WORK/mock_port.txt'):
        break
    time.sleep(0.05)
"
MOCK_PORT=$(cat "$WORK/mock_port.txt")

# Try switching profile while print is active -> should fail
ROSETTEOS_PROFILES_SEEDS="$PROFILES_SRC" \
ROSETTEOS_USER_PROFILES="$WORK/user_profiles" \
ROSETTEOS_SYSTEM_DIR="$WORK/system" \
ROSETTEOS_CONFIG_DIR="$WORK/config" \
ROSETTEOS_BACKUP_DIR="$WORK/backups" \
ROSETTEOS_ACTIVE_MARKER="$WORK/system/active-profile.json" \
ROSETTEOS_MOONRAKER_PORT="$MOCK_PORT" \
python3 "$PROFILE_MGR" set creality-ender3-v3-se > "$WORK/interlock.log" 2>&1
SWITCH_STATUS=$?

if [ "$SWITCH_STATUS" -ne 0 ] && grep -q "Cannot switch printer profile while a print is actively in progress" "$WORK/interlock.log"; then
    pass "Safety interlock successfully blocked profile switch during active print"
else
    fail "Safety interlock failed to block profile switch during active print"
fi

# Try switching with --force -> should succeed
ROSETTEOS_PROFILES_SEEDS="$PROFILES_SRC" \
ROSETTEOS_USER_PROFILES="$WORK/user_profiles" \
ROSETTEOS_SYSTEM_DIR="$WORK/system" \
ROSETTEOS_CONFIG_DIR="$WORK/config" \
ROSETTEOS_BACKUP_DIR="$WORK/backups" \
ROSETTEOS_ACTIVE_MARKER="$WORK/system/active-profile.json" \
ROSETTEOS_MOONRAKER_PORT="$MOCK_PORT" \
python3 "$PROFILE_MGR" set creality-ender3-v3-se --force --quiet > "$WORK/force.log" 2>&1
FORCE_STATUS=$?

if [ "$FORCE_STATUS" -eq 0 ]; then
    pass "Safety interlock --force flag successfully bypassed print check when requested"
else
    fail "Safety interlock --force failed to permit profile switch"
fi

# Stop mock server
kill "$MOCK_PID" 2>/dev/null || true
wait "$MOCK_PID" 2>/dev/null || true

echo "=== Test 6: MCU Architecture Warning Display ==="
ROSETTEOS_PROFILES_SEEDS="$PROFILES_SRC" \
ROSETTEOS_USER_PROFILES="$WORK/user_profiles" \
ROSETTEOS_SYSTEM_DIR="$WORK/system" \
ROSETTEOS_CONFIG_DIR="$WORK/config" \
ROSETTEOS_BACKUP_DIR="$WORK/backups" \
ROSETTEOS_ACTIVE_MARKER="$WORK/system/active-profile.json" \
python3 "$PROFILE_MGR" set creality-ender3-v2-neo > "$WORK/mcu_warning.log" 2>&1

if grep -q "Mainboard MCU Architecture Change Detected" "$WORK/mcu_warning.log" && grep -q "Ender3V2Neo_klipper.bin" "$WORK/mcu_warning.log"; then
    pass "MCU architecture change notice and flashing guidance displayed correctly"
else
    fail "MCU architecture change notice was not displayed"
fi

echo "================================================="
echo "Multi-Printer Profile Tests Completed: $PASS passed, $FAIL failed"
echo "================================================="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
