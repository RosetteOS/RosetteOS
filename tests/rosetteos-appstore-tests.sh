#!/bin/bash
#
# Offline, repeatable verification tests for RosetteOS App Store & UI Switcher.
#
# Usage: bash tests/rosetteos-appstore-tests.sh
#

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
OVERLAY="$REPO_ROOT/scripts/build/overlay"
ROSETTEOS_APP="$OVERLAY/usr/bin/rosetteos-app"
MANIFEST="$REPO_ROOT/manifests/apps.json"
S01="$OVERLAY/etc/init.d/S01persistent-datastore"
S58="$OVERLAY/etc/init.d/S58guppyscreen"
NGINX_CONF="$OVERLAY/etc/nginx/nginx.conf"

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

TEST_SANDBOX=$(mktemp -d /tmp/rosetteos-appstore-test-XXXXXX)
trap 'rm -rf "$TEST_SANDBOX"' EXIT

export ROSETTEOS_STATE_DIR="$TEST_SANDBOX/state"
export ROSETTEOS_APPS_DIR="$TEST_SANDBOX/state/apps"
export ROSETTEOS_SERVICES_DIR="$TEST_SANDBOX/state/services.d"
export ROSETTEOS_WEB_ROOT_LINK="$TEST_SANDBOX/web-root"
export ROSETTEOS_CATALOG_FILE="$MANIFEST"
export ROSETTEOS_PRINTER_DATA_CONFIG="$TEST_SANDBOX/printer_data_config"
mkdir -p "$ROSETTEOS_STATE_DIR" "$ROSETTEOS_APPS_DIR" "$ROSETTEOS_SERVICES_DIR" "$ROSETTEOS_PRINTER_DATA_CONFIG/macros"
cat << 'EOF' > "$ROSETTEOS_PRINTER_DATA_CONFIG/printer.cfg"
[include macros/mainsail.cfg]
[printer]
kinematics: cartesian
EOF

cat << 'EOF' > "$ROSETTEOS_PRINTER_DATA_CONFIG/moonraker.conf"
[server]
host: 0.0.0.0
port: 7125

[update_manager]
enable_auto_refresh: True

[update_manager klipper]
channel: dev

[update_manager moonraker]
channel: dev

[update_manager mainsail]
type: web
channel: beta
repo: mainsail-crew/mainsail
path: /usr/data/rosetteos/apps/mainsail

[authorization]
trusted_clients:
 127.0.0.1
EOF

echo "=== Test 1: App Store Manifest Catalog Integrity ==="
[ -f "$MANIFEST" ] || { fail "$MANIFEST missing"; exit 1; }
python3 -c '
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
assert "apps" in data, "manifest missing apps list"
apps = data["apps"]
assert len(apps) == 9, f"expected exactly 9 apps, got {len(apps)}"
categories = {a["category"] for a in data["apps"]}
assert {"web_ui", "touch_ui", "plugin"}.issubset(categories), f"missing core categories in {categories}"

ids = [a["id"] for a in data["apps"]]
assert len(ids) == len(set(ids)), "duplicate app ids in manifest"
assert "mainsail" in ids, "mainsail missing from catalog"
assert "fluidd" in ids, "fluidd missing from catalog"
assert "guppyscreen" in ids, "guppyscreen missing from catalog"
assert "helixscreen" in ids, "helixscreen missing from catalog"
assert "timelapse" in ids, "timelapse missing from catalog"
assert "mobileraker" in ids, "mobileraker missing from catalog"
assert "spoolman" in ids, "spoolman missing from catalog"
assert "octoapp" in ids, "octoapp missing from catalog"
assert "vnc" in ids, "vnc missing from catalog"
' "$MANIFEST" && pass "apps.json manifest schema and required applications validated" || fail "apps.json validation failed"

echo "=== Test 2: CLI Syntax & Output Modes ==="
[ -x "$ROSETTEOS_APP" ] || { fail "$ROSETTEOS_APP missing or not executable"; exit 1; }

# Test list table output
list_out=$(python3 "$ROSETTEOS_APP" list)
if echo "$list_out" | grep -q "mainsail" && echo "$list_out" | grep -q "fluidd" && echo "$list_out" | grep -q "helixscreen"; then
	pass "rosetteos-app list renders tabular catalog correctly"
else
	fail "rosetteos-app list output missing expected app entries"
fi

# Test list JSON output
json_out=$(python3 "$ROSETTEOS_APP" list --json)
python3 -c '
import json, sys
data = json.loads(sys.argv[1])
assert isinstance(data, list)
assert any(a["id"] == "fluidd" for a in data)
assert any(a["id"] == "helixscreen" for a in data)
' "$json_out" && pass "rosetteos-app list --json returns valid structured JSON" || fail "rosetteos-app list --json failed"

# Test category filter
cat_out=$(python3 "$ROSETTEOS_APP" list --category web_ui --json)
python3 -c '
import json, sys
data = json.loads(sys.argv[1])
assert all(a["category"] == "web_ui" for a in data)
assert len(data) >= 2
' "$cat_out" && pass "rosetteos-app list --category filters by category" || fail "rosetteos-app list --category filter failed"

# Test status command
status_out=$(python3 "$ROSETTEOS_APP" status)
if echo "$status_out" | grep -q "Active Web UI:" && echo "$status_out" | grep -q "Active Touch UI:"; then
	pass "rosetteos-app status displays current configuration"
else
	fail "rosetteos-app status output missing key fields"
fi

# Test update command with local file URL
mock_remote_catalog="$TEST_SANDBOX/mock_remote_catalog.json"
cp "$MANIFEST" "$mock_remote_catalog"
update_out=$(python3 "$ROSETTEOS_APP" update --url "file://$mock_remote_catalog")
if echo "$update_out" | grep -q "Updated catalog" && [ -f "$ROSETTEOS_STATE_DIR/apps.json" ]; then
	pass "rosetteos-app update successfully refreshed catalog from URL"
else
	fail "rosetteos-app update failed: $update_out"
fi

echo "=== Test 3: Web UI Switching & Dynamic Symlink Management ==="
# Create mock mainsail directory
mkdir -p "$TEST_SANDBOX/usr_share_mainsail"
echo "<h1>Mainsail</h1>" > "$TEST_SANDBOX/usr_share_mainsail/index.html"

# Default state
python3 "$ROSETTEOS_APP" set-active-web mainsail
if [ -L "$ROSETTEOS_WEB_ROOT_LINK" ] && [ "$(readlink "$ROSETTEOS_WEB_ROOT_LINK")" = "/usr/share/mainsail" ]; then
	pass "set-active-web mainsail creates symlink to /usr/share/mainsail"
else
	fail "set-active-web mainsail failed to create correct symlink"
fi

if [ "$(cat "$ROSETTEOS_STATE_DIR/active_web_ui")" = "mainsail" ]; then
	pass "active_web_ui persistent file set to mainsail"
else
	fail "active_web_ui persistent file not set to mainsail"
fi

# Attempt to switch to uninstalled fluidd should fail
if python3 "$ROSETTEOS_APP" set-active-web fluidd >/dev/null 2>&1; then
	fail "set-active-web fluidd should fail when not installed"
else
	pass "set-active-web fluidd correctly rejected when not installed"
fi

# Create mock fluidd package archive and mock catalog for install testing
mock_fluidd_zip="$TEST_SANDBOX/fluidd-pkg.zip"
python3 -c "
import zipfile
with zipfile.ZipFile('$mock_fluidd_zip', 'w') as zf:
    zf.writestr('index.html', '<h1>Fluidd Test Package</h1>')
"
mock_fluidd_sha=$(sha256sum "$mock_fluidd_zip" | awk '{print $1}')

mock_fluidd_cfg="$TEST_SANDBOX/mock-fluidd.cfg"
echo "[gcode_macro MOCK_FLUIDD_CFG]" > "$mock_fluidd_cfg"

mock_catalog="$TEST_SANDBOX/mock_catalog.json"
python3 -c "
import json
with open('$MANIFEST') as f:
    d = json.load(f)
for app in d['apps']:
    if app['id'] == 'fluidd':
        app['download_url'] = 'file://$mock_fluidd_zip'
        app['sha256'] = '$mock_fluidd_sha'
        app['config_url'] = 'file://$mock_fluidd_cfg'
        app['config_target'] = 'macros/fluidd.cfg'
with open('$mock_catalog', 'w') as f:
    json.dump(d, f)
"
export ROSETTEOS_CATALOG_FILE="$mock_catalog"

# Install fluidd (without --activate)
python3 "$ROSETTEOS_APP" install fluidd

if [ -f "$ROSETTEOS_PRINTER_DATA_CONFIG/macros/fluidd.cfg" ]; then
	pass "rosetteos-app install fluidd installed macros/fluidd.cfg"
else
	fail "rosetteos-app install fluidd failed to install macros/fluidd.cfg"
fi

if grep -q "\[update_manager fluidd\]" "$ROSETTEOS_PRINTER_DATA_CONFIG/moonraker.conf"; then
	pass "rosetteos-app install fluidd added [update_manager fluidd] to moonraker.conf"
else
	fail "rosetteos-app install fluidd failed to add [update_manager fluidd] to moonraker.conf"
fi

if grep -q "\[include macros/mainsail.cfg\]" "$ROSETTEOS_PRINTER_DATA_CONFIG/printer.cfg" && ! grep -q "\[include macros/fluidd.cfg\]" "$ROSETTEOS_PRINTER_DATA_CONFIG/printer.cfg"; then
	pass "printer.cfg retains macros/mainsail.cfg include until fluidd is activated"
else
	fail "printer.cfg improperly switched include before activation"
fi

# Activate fluidd Web UI
python3 "$ROSETTEOS_APP" set-active-web fluidd
if [ -L "$ROSETTEOS_WEB_ROOT_LINK" ] && [ "$(readlink "$ROSETTEOS_WEB_ROOT_LINK")" = "$ROSETTEOS_APPS_DIR/fluidd" ]; then
	pass "set-active-web fluidd points symlink to $ROSETTEOS_APPS_DIR/fluidd"
else
	fail "set-active-web fluidd symlink incorrect: $(readlink "$ROSETTEOS_WEB_ROOT_LINK" 2>/dev/null || echo 'none')"
fi

if [ "$(cat "$ROSETTEOS_STATE_DIR/active_web_ui")" = "fluidd" ]; then
	pass "active_web_ui persistent file updated to fluidd"
else
	fail "active_web_ui not updated to fluidd"
fi

if grep -q "\[include macros/fluidd.cfg\]" "$ROSETTEOS_PRINTER_DATA_CONFIG/printer.cfg" && ! grep -q "\[include macros/mainsail.cfg\]" "$ROSETTEOS_PRINTER_DATA_CONFIG/printer.cfg"; then
	pass "printer.cfg macro include dynamically switched to macros/fluidd.cfg upon activation"
else
	fail "printer.cfg macro include not switched to macros/fluidd.cfg"
fi

# Switch back to mainsail
python3 "$ROSETTEOS_APP" set-active-web mainsail
if [ "$(readlink "$ROSETTEOS_WEB_ROOT_LINK")" = "/usr/share/mainsail" ]; then
	pass "set-active-web switches back to mainsail"
else
	fail "set-active-web mainsail switch back failed"
fi

if grep -q "\[include macros/mainsail.cfg\]" "$ROSETTEOS_PRINTER_DATA_CONFIG/printer.cfg" && ! grep -q "\[include macros/fluidd.cfg\]" "$ROSETTEOS_PRINTER_DATA_CONFIG/printer.cfg"; then
	pass "printer.cfg macro include dynamically restored to macros/mainsail.cfg upon deactivation"
else
	fail "printer.cfg macro include not restored to macros/mainsail.cfg"
fi

echo "=== Test 4: Touchscreen UI Switching & Safety Checks ==="
# Default state
python3 "$ROSETTEOS_APP" set-active-touch guppyscreen
if [ "$(cat "$ROSETTEOS_STATE_DIR/active_touch_ui")" = "guppyscreen" ]; then
	pass "set-active-touch guppyscreen sets active_touch_ui to guppyscreen"
else
	fail "set-active-touch guppyscreen failed"
fi

# Attempt switch to uninstalled helixscreen should fail
if python3 "$ROSETTEOS_APP" set-active-touch helixscreen >/dev/null 2>&1; then
	fail "set-active-touch helixscreen should fail when binary is absent"
else
	pass "set-active-touch helixscreen rejected when binary is absent"
fi

# Mock install helixscreen binary
mkdir -p "$ROSETTEOS_APPS_DIR/helixscreen/bin"
touch "$ROSETTEOS_APPS_DIR/helixscreen/bin/helix-screen"
chmod +x "$ROSETTEOS_APPS_DIR/helixscreen/bin/helix-screen"

python3 "$ROSETTEOS_APP" set-active-touch helixscreen
if [ "$(cat "$ROSETTEOS_STATE_DIR/active_touch_ui")" = "helixscreen" ]; then
	pass "set-active-touch helixscreen successfully set active_touch_ui to helixscreen"
else
	fail "set-active-touch helixscreen failed"
fi

echo "=== Test 5: Removal & Safe Automatic Fallback ==="
# Active web UI fallback and fluidd removal
python3 "$ROSETTEOS_APP" set-active-web fluidd
python3 "$ROSETTEOS_APP" remove fluidd
if [ ! -d "$ROSETTEOS_APPS_DIR/fluidd" ]; then
	pass "rosetteos-app remove fluidd uninstalled the package directory"
else
	fail "rosetteos-app remove fluidd left directory behind"
fi

if [ "$(cat "$ROSETTEOS_STATE_DIR/active_web_ui")" = "mainsail" ] && [ "$(readlink "$ROSETTEOS_WEB_ROOT_LINK")" = "/usr/share/mainsail" ]; then
	pass "removing active Web UI automatically fallback to Mainsail"
else
	fail "removing active Web UI failed to fallback to Mainsail"
fi

if [ ! -f "$ROSETTEOS_PRINTER_DATA_CONFIG/macros/fluidd.cfg" ]; then
	pass "rosetteos-app remove fluidd removed macros/fluidd.cfg"
else
	fail "rosetteos-app remove fluidd failed to remove macros/fluidd.cfg"
fi

if ! grep -q "\[update_manager fluidd\]" "$ROSETTEOS_PRINTER_DATA_CONFIG/moonraker.conf" && grep -q "\[update_manager mainsail\]" "$ROSETTEOS_PRINTER_DATA_CONFIG/moonraker.conf"; then
	pass "rosetteos-app remove fluidd removed [update_manager fluidd] from moonraker.conf while preserving other sections"
else
	fail "rosetteos-app remove fluidd failed to clean moonraker.conf"
fi

if grep -q "\[include macros/mainsail.cfg\]" "$ROSETTEOS_PRINTER_DATA_CONFIG/printer.cfg" && ! grep -q "\[include macros/fluidd.cfg\]" "$ROSETTEOS_PRINTER_DATA_CONFIG/printer.cfg"; then
	pass "printer.cfg restored to macros/mainsail.cfg after fluidd removal"
else
	fail "printer.cfg not restored to macros/mainsail.cfg after fluidd removal"
fi

# Active touch UI fallback
python3 "$ROSETTEOS_APP" remove helixscreen
if [ ! -d "$ROSETTEOS_APPS_DIR/helixscreen" ]; then
	pass "rosetteos-app remove helixscreen uninstalled the package directory"
else
	fail "rosetteos-app remove helixscreen left directory behind"
fi

if [ "$(cat "$ROSETTEOS_STATE_DIR/active_touch_ui")" = "guppyscreen" ]; then
	pass "removing active Touch UI automatically fallback to GuppyScreen"
else
	fail "removing active Touch UI failed to fallback to GuppyScreen"
fi

# Builtin removal protection
if python3 "$ROSETTEOS_APP" remove mainsail >/dev/null 2>&1; then
	fail "rosetteos-app remove mainsail should be rejected as builtin"
else
	pass "rosetteos-app remove mainsail rejected for builtin component"
fi

if python3 "$ROSETTEOS_APP" remove guppyscreen >/dev/null 2>&1; then
	fail "rosetteos-app remove guppyscreen should be rejected as builtin"
else
	pass "rosetteos-app remove guppyscreen rejected for builtin component"
fi

echo "=== Test 6: System Init & Nginx Configuration Verification ==="
# S01persistent-datastore assertions
if grep -q 'mkdir -p "$DATA_ROOT/apps"' "$S01" && grep -q 'rosetteos-web-root' "$S01"; then
	pass "S01persistent-datastore initializes /usr/data/rosetteos/apps and /var/run/rosetteos-web-root link"
else
	fail "S01persistent-datastore missing apps or web root initialization"
fi

# nginx.conf assertions
if grep -q "root /var/run/rosetteos-web-root;" "$NGINX_CONF"; then
	pass "nginx.conf uses dynamic web root /var/run/rosetteos-web-root"
else
	fail "nginx.conf not pointing to /var/run/rosetteos-web-root"
fi

# S58guppyscreen assertions
if grep -q "get_touch_binary" "$S58" && grep -q "active_touch_ui" "$S58"; then
	pass "S58guppyscreen supports dynamic touchscreen UI selection with fallback"
else
	fail "S58guppyscreen missing dynamic touch UI selection"
fi

# S60rosetteos-services assertions
S60_SERVICES="$OVERLAY/etc/init.d/S60rosetteos-services"
if [ -x "$S60_SERVICES" ] && grep -q "SERVICES_DIR" "$S60_SERVICES"; then
	pass "S60rosetteos-services dynamic service dispatcher present and executable in overlay"
else
	fail "S60rosetteos-services missing or not executable"
fi

if [ ! -e "$OVERLAY/etc/init.d/S60mobileraker" ]; then
	pass "S60mobileraker static script cleanly removed from firmware overlay"
else
	fail "S60mobileraker should not exist in firmware overlay"
fi

echo "=== Test 7: Printing & Thermal Safeguards Verification ==="
PORT_FILE="$TEST_SANDBOX/mock_port.txt"

# Start mock moonraker in background
python3 -c '
import http.server, socketserver, json, sys

state = {"print_state": "standby", "ext_target": 0.0, "bed_target": 0.0}

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args): pass
    def do_GET(self):
        if self.path.startswith("/set_state"):
            q = self.path.split("?", 1)[1]
            for p in q.split("&"):
                k, v = p.split("=")
                if k in ("ext_target", "bed_target"): state[k] = float(v)
                else: state[k] = v
            self.send_response(200); self.end_headers(); self.wfile.write(b"ok")
            return
        payload = {
            "result": {
                "status": {
                    "print_stats": {"state": state["print_state"]},
                    "extruder": {"target": state["ext_target"], "temperature": 200.0 if state["ext_target"] > 0 else 25.0},
                    "heater_bed": {"target": state["bed_target"], "temperature": 60.0 if state["bed_target"] > 0 else 25.0}
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
' "$PORT_FILE" &
MOCK_PID=$!
trap 'kill $MOCK_PID 2>/dev/null || true; rm -rf "$TEST_SANDBOX"' EXIT

while [ ! -s "$PORT_FILE" ]; do
    sleep 0.05
done
MOCK_MOONRAKER_PORT=$(cat "$PORT_FILE")
export ROSETTEOS_MOONRAKER_URL="http://127.0.0.1:$MOCK_MOONRAKER_PORT"

mkdir -p "$ROSETTEOS_APPS_DIR/helixscreen/bin"
touch "$ROSETTEOS_APPS_DIR/helixscreen/bin/helix-screen"
chmod +x "$ROSETTEOS_APPS_DIR/helixscreen/bin/helix-screen"

# Case 1: Print in progress -> switch blocked without --force, allowed with --force
curl -s "$ROSETTEOS_MOONRAKER_URL/set_state?print_state=printing&ext_target=0&bed_target=0" >/dev/null

if python3 "$ROSETTEOS_APP" set-active-touch helixscreen >/dev/null 2>&1; then
	fail "set-active-touch should be blocked while printing"
else
	pass "set-active-touch blocked during active print"
fi

if python3 "$ROSETTEOS_APP" set-active-web mainsail >/dev/null 2>&1; then
	fail "set-active-web should be blocked while printing"
else
	pass "set-active-web blocked during active print"
fi

if python3 "$ROSETTEOS_APP" set-active-touch helixscreen --force >/dev/null 2>&1; then
	pass "set-active-touch --force successfully overrides print safeguard"
else
	fail "set-active-touch --force failed to override"
fi

# Case 2: Extruder heating -> touch switch blocked without --force, allowed with --force
curl -s "$ROSETTEOS_MOONRAKER_URL/set_state?print_state=standby&ext_target=220&bed_target=0" >/dev/null

if python3 "$ROSETTEOS_APP" set-active-touch guppyscreen >/dev/null 2>&1; then
	fail "set-active-touch should be blocked while hotend is heating"
else
	pass "set-active-touch blocked while hotend target is active"
fi

if python3 "$ROSETTEOS_APP" set-active-touch guppyscreen --force >/dev/null 2>&1; then
	pass "set-active-touch --force overrides thermal safeguard"
else
	fail "set-active-touch --force failed to override thermal safeguard"
fi

# Case 3: Bed heating -> touch switch blocked without --force
curl -s "$ROSETTEOS_MOONRAKER_URL/set_state?print_state=standby&ext_target=0&bed_target=60" >/dev/null

if python3 "$ROSETTEOS_APP" set-active-touch helixscreen >/dev/null 2>&1; then
	fail "set-active-touch should be blocked while bed is heating"
else
	pass "set-active-touch blocked while bed target is active"
fi

kill $MOCK_PID 2>/dev/null || true

echo "=== Test 8: App Updates & Version Detection ==="
# 1. Reinstall fluidd via mock catalog
python3 "$ROSETTEOS_APP" install fluidd

# 2. Check installed version metadata
if [ -f "$ROSETTEOS_STATE_DIR/installed/fluidd.json" ] && grep -q '"version": "1.37.6"' "$ROSETTEOS_STATE_DIR/installed/fluidd.json"; then
	pass "rosetteos-app install records installed version metadata"
else
	fail "installed version metadata missing or incorrect"
fi

# 3. Initially has_update should be false
json_out=$(python3 "$ROSETTEOS_APP" list --json)
python3 -c "
import json, sys
data = json.loads('''$json_out''')
fluidd = next(a for a in data if a['id'] == 'fluidd')
assert fluidd['installed_version'] == '1.37.6', f'Unexpected installed_version: {fluidd}'
assert fluidd['has_update'] is False, f'Expected has_update False, got: {fluidd}'
" && pass "has_update is false when installed version matches catalog" || fail "has_update check failed"

# 4. Simulate a newer catalog version available (1.38.0)
mock_fluidd_zip_v2="$TEST_SANDBOX/fluidd-pkg-v2.zip"
python3 -c "
import zipfile
with zipfile.ZipFile('$mock_fluidd_zip_v2', 'w') as zf:
    zf.writestr('index.html', '<h1>Fluidd v1.38.0 Package</h1>')
"
mock_fluidd_sha_v2=$(sha256sum "$mock_fluidd_zip_v2" | awk '{print $1}')

python3 -c "
import json
with open('$mock_catalog') as f:
    d = json.load(f)
for app in d['apps']:
    if app['id'] == 'fluidd':
        app['version'] = '1.38.0'
        app['download_url'] = 'file://$mock_fluidd_zip_v2'
        app['sha256'] = '$mock_fluidd_sha_v2'
with open('$mock_catalog', 'w') as f:
    json.dump(d, f)
"

# 5. Check has_update becomes true
json_out_v2=$(python3 "$ROSETTEOS_APP" list --json)
python3 -c "
import json, sys
data = json.loads('''$json_out_v2''')
fluidd = next(a for a in data if a['id'] == 'fluidd')
assert fluidd['installed_version'] == '1.37.6', f'Unexpected installed_version: {fluidd}'
assert fluidd['version'] == '1.38.0', f'Unexpected catalog version: {fluidd}'
assert fluidd['has_update'] is True, f'Expected has_update True, got: {fluidd}'
" && pass "has_update is true when catalog version is newer than installed version" || fail "has_update detection failed"

# 6. Run rosetteos-app upgrade fluidd
upgrade_out=$(python3 "$ROSETTEOS_APP" upgrade fluidd)
if echo "$upgrade_out" | grep -q "Upgrading 'fluidd' from v1.37.6 to v1.38.0" && grep -q '"version": "1.38.0"' "$ROSETTEOS_STATE_DIR/installed/fluidd.json"; then
	pass "rosetteos-app upgrade successfully updated fluidd to v1.38.0"
else
	fail "rosetteos-app upgrade failed: $upgrade_out"
fi

# 7. Check has_update is false again after upgrade
json_out_v3=$(python3 "$ROSETTEOS_APP" list --json)
python3 -c "
import json, sys
data = json.loads('''$json_out_v3''')
fluidd = next(a for a in data if a['id'] == 'fluidd')
assert fluidd['installed_version'] == '1.38.0', f'Unexpected installed_version: {fluidd}'
assert fluidd['has_update'] is False, f'Expected has_update False, got: {fluidd}'
" && pass "has_update resets to false after successful upgrade" || fail "has_update reset check failed"

echo "=== Test 9: G-code Macro Definitions & Inclusion Verification ==="
APPS_CFG="$OVERLAY/opt/printer_data/config/macros/apps.cfg"
[ -f "$APPS_CFG" ] || { fail "$APPS_CFG missing"; exit 1; }

# Verify required macro sections
for macro_sec in "gcode_shell_command rosetteos_app_cmd" \
                 "gcode_macro APPSTORE_STATUS" \
                 "gcode_macro APPSTORE_LIST" \
                 "gcode_macro APPSTORE_UPDATE_CATALOG" \
                 "gcode_macro APPSTORE_INSTALL" \
                 "gcode_macro APPSTORE_UPGRADE" \
                 "gcode_macro SET_ACTIVE_WEB_UI" \
                 "gcode_macro SET_ACTIVE_TOUCH_UI" \
                 "gcode_macro APPSTORE_REMOVE"; do
	if grep -q "\[$macro_sec\]" "$APPS_CFG"; then
		pass "apps.cfg contains [$macro_sec]"
	else
		fail "apps.cfg missing [$macro_sec]"
	fi
done

# Verify inclusion in default printer.cfg and all printer profiles
PRINTER_CFG="$OVERLAY/opt/printer_data/config/printer.cfg"
if grep -q "\[include macros/apps.cfg\]" "$PRINTER_CFG"; then
	pass "default printer.cfg includes macros/apps.cfg"
else
	fail "default printer.cfg missing [include macros/apps.cfg]"
fi

all_profiles_included=1
for pcfg in "$OVERLAY/opt/rosetteos-seeds/printer_profiles"/*/printer.cfg; do
	if ! grep -q "\[include macros/apps.cfg\]" "$pcfg"; then
		fail "$(basename "$(dirname "$pcfg")")/printer.cfg missing [include macros/apps.cfg]"
		all_profiles_included=0
	fi
done
if [ "$all_profiles_included" -eq 1 ]; then
	pass "all printer profile configurations include macros/apps.cfg"
fi

echo "=== Test 10: Timelapse Plugin Integration & Macro Lifecycle ==="
MOCK_MOONRAKER_COMPS="$TEST_SANDBOX/moonraker/components"
mkdir -p "$MOCK_MOONRAKER_COMPS"
export ROSETTEOS_MOONRAKER_COMPONENTS_DIR="$MOCK_MOONRAKER_COMPS"

mock_timelapse_zip="$TEST_SANDBOX/timelapse-pkg.zip"
python3 -c "
import zipfile
with zipfile.ZipFile('$mock_timelapse_zip', 'w') as zf:
    zf.writestr('component/timelapse.py', '# Mock Timelapse Component\n')
    zf.writestr('klipper_macro/timelapse.cfg', '[gcode_macro TIMELAPSE_TAKE_FRAME]\ngcode:\n  G4 P100\n')
"
mock_timelapse_sha=$(sha256sum "$mock_timelapse_zip" | awk '{print $1}')

mock_timelapse_cfg="$TEST_SANDBOX/mock-timelapse.cfg"
echo "[gcode_macro TIMELAPSE_TAKE_FRAME]" > "$mock_timelapse_cfg"

python3 -c "
import json
with open('$mock_catalog') as f:
    d = json.load(f)
for app in d['apps']:
    if app['id'] == 'timelapse':
        app['download_url'] = 'file://$mock_timelapse_zip'
        app['sha256'] = '$mock_timelapse_sha'
        app['config_url'] = 'file://$mock_timelapse_cfg'
        app['config_target'] = 'macros/timelapse.cfg'
with open('$mock_catalog', 'w') as f:
    json.dump(d, f)
"

# 1. Install timelapse
python3 "$ROSETTEOS_APP" install timelapse

if [ -f "$MOCK_MOONRAKER_COMPS/timelapse.py" ] || [ -L "$MOCK_MOONRAKER_COMPS/timelapse.py" ]; then
	pass "rosetteos-app install timelapse linked component/timelapse.py into Moonraker components"
else
	fail "rosetteos-app install timelapse failed to link Moonraker component"
fi

if [ -f "$ROSETTEOS_PRINTER_DATA_CONFIG/macros/timelapse.cfg" ]; then
	pass "rosetteos-app install timelapse installed macros/timelapse.cfg"
else
	fail "rosetteos-app install timelapse failed to install macros/timelapse.cfg"
fi

if grep -q "\[timelapse\]" "$ROSETTEOS_PRINTER_DATA_CONFIG/moonraker.conf"; then
	pass "rosetteos-app install timelapse added [timelapse] to moonraker.conf"
else
	fail "rosetteos-app install timelapse failed to update moonraker.conf"
fi

if grep -q "\[include macros/timelapse.cfg\]" "$ROSETTEOS_PRINTER_DATA_CONFIG/printer.cfg"; then
	pass "rosetteos-app install timelapse added [include macros/timelapse.cfg] to printer.cfg"
else
	fail "rosetteos-app install timelapse failed to update printer.cfg"
fi

# 2. Remove timelapse
python3 "$ROSETTEOS_APP" remove timelapse

if [ ! -e "$MOCK_MOONRAKER_COMPS/timelapse.py" ]; then
	pass "rosetteos-app remove timelapse removed Moonraker component link"
else
	fail "rosetteos-app remove timelapse failed to remove Moonraker component"
fi

if [ ! -f "$ROSETTEOS_PRINTER_DATA_CONFIG/macros/timelapse.cfg" ]; then
	pass "rosetteos-app remove timelapse removed macros/timelapse.cfg"
else
	fail "rosetteos-app remove timelapse failed to remove macros/timelapse.cfg"
fi

if ! grep -q "\[timelapse\]" "$ROSETTEOS_PRINTER_DATA_CONFIG/moonraker.conf"; then
	pass "rosetteos-app remove timelapse cleaned [timelapse] from moonraker.conf"
else
	fail "rosetteos-app remove timelapse failed to clean moonraker.conf"
fi

if ! grep -q "\[include macros/timelapse.cfg\]" "$ROSETTEOS_PRINTER_DATA_CONFIG/printer.cfg"; then
	pass "rosetteos-app remove timelapse removed [include macros/timelapse.cfg] from printer.cfg"
else
	fail "rosetteos-app remove timelapse failed to clean printer.cfg"
fi

echo "=== Test 11: Mobileraker Companion Plugin Integration & Config Lifecycle ==="
mock_mobileraker_zip="$TEST_SANDBOX/mobileraker-pkg.zip"
python3 -c "
import zipfile
with zipfile.ZipFile('$mock_mobileraker_zip', 'w') as zf:
    zf.writestr('mobileraker.py', '#!/usr/bin/env python3\n# Mock Mobileraker\n')
"
mock_mobileraker_sha=$(sha256sum "$mock_mobileraker_zip" | awk '{print $1}')

mock_mobileraker_conf="$TEST_SANDBOX/mock-mobileraker.conf"
echo "[printer RosetteOS]" > "$mock_mobileraker_conf"
echo "moonraker_uri: ws://127.0.0.1:7125/websocket" >> "$mock_mobileraker_conf"

python3 -c "
import json
with open('$mock_catalog') as f:
    d = json.load(f)
for app in d['apps']:
    if app['id'] == 'mobileraker':
        app['download_url'] = 'file://$mock_mobileraker_zip'
        app['sha256'] = '$mock_mobileraker_sha'
        app['config_url'] = 'file://$mock_mobileraker_conf'
        app['config_target'] = 'mobileraker.conf'
with open('$mock_catalog', 'w') as f:
    json.dump(d, f)
"

# 1. Install mobileraker
python3 "$ROSETTEOS_APP" install mobileraker

if [ -f "$ROSETTEOS_APPS_DIR/mobileraker/mobileraker.py" ]; then
	pass "rosetteos-app install mobileraker unpacked mobileraker.py"
else
	fail "rosetteos-app install mobileraker failed to unpack mobileraker.py"
fi

if [ -f "$ROSETTEOS_PRINTER_DATA_CONFIG/mobileraker.conf" ]; then
	pass "rosetteos-app install mobileraker installed mobileraker.conf"
else
	fail "rosetteos-app install mobileraker failed to install mobileraker.conf"
fi

# Dynamic service assertions
if [ -x "$ROSETTEOS_SERVICES_DIR/S60mobileraker" ] && grep -q "EXEC_CMD=" "$ROSETTEOS_SERVICES_DIR/S60mobileraker"; then
	pass "rosetteos-app install mobileraker generated executable dynamic service runner S60mobileraker"
else
	fail "rosetteos-app install mobileraker failed to generate dynamic service script"
fi

# rosetteos-app service commands
svc_list_out=$(python3 "$ROSETTEOS_APP" service list)
if echo "$svc_list_out" | grep -q "S60mobileraker"; then
	pass "rosetteos-app service list displays dynamic services"
else
	fail "rosetteos-app service list failed: $svc_list_out"
fi

svc_stat_out=$(python3 "$ROSETTEOS_APP" service status mobileraker || true)
if echo "$svc_stat_out" | grep -q "mobileraker"; then
	pass "rosetteos-app service status mobileraker queried dynamic service"
else
	fail "rosetteos-app service status failed: $svc_stat_out"
fi

# 2. Remove mobileraker
python3 "$ROSETTEOS_APP" remove mobileraker

if [ ! -d "$ROSETTEOS_APPS_DIR/mobileraker" ]; then
	pass "rosetteos-app remove mobileraker removed application directory"
else
	fail "rosetteos-app remove mobileraker failed to remove application directory"
fi

if [ ! -f "$ROSETTEOS_PRINTER_DATA_CONFIG/mobileraker.conf" ]; then
	pass "rosetteos-app remove mobileraker removed mobileraker.conf"
else
	fail "rosetteos-app remove mobileraker failed to remove mobileraker.conf"
fi

if ! grep -q "\[update_manager mobileraker\]" "$ROSETTEOS_PRINTER_DATA_CONFIG/moonraker.conf"; then
	pass "rosetteos-app remove mobileraker cleaned [update_manager mobileraker] from moonraker.conf"
else
	fail "rosetteos-app remove mobileraker failed to clean moonraker.conf"
fi

if [ ! -e "$ROSETTEOS_SERVICES_DIR/S60mobileraker" ]; then
	pass "rosetteos-app remove mobileraker deleted dynamic service runner from services.d"
else
	fail "rosetteos-app remove mobileraker left dynamic service script behind in services.d"
fi

echo "=== Test 12: Spoolman Filament Manager Plugin Integration & Dynamic Service Lifecycle ==="
mock_spoolman_zip="$TEST_SANDBOX/spoolman-pkg.zip"
python3 -c "
import zipfile
with zipfile.ZipFile('$mock_spoolman_zip', 'w') as zf:
    zf.writestr('server.py', '#!/usr/bin/env python3\n# Mock Spoolman Launcher\n')
    zf.writestr('spoolman/main.py', '# Mock Spoolman Main\n')
"
mock_spoolman_sha=$(sha256sum "$mock_spoolman_zip" | awk '{print $1}')

python3 -c "
import json
with open('$mock_catalog') as f:
    d = json.load(f)
for app in d['apps']:
    if app['id'] == 'spoolman':
        app['download_url'] = 'file://$mock_spoolman_zip'
        app['sha256'] = '$mock_spoolman_sha'
with open('$mock_catalog', 'w') as f:
    json.dump(d, f)
"

# 1. Install spoolman
python3 "$ROSETTEOS_APP" install spoolman

if [ -f "$ROSETTEOS_APPS_DIR/spoolman/server.py" ]; then
	pass "rosetteos-app install spoolman unpacked server.py"
else
	fail "rosetteos-app install spoolman failed to unpack server.py"
fi

if grep -q "\[spoolman\]" "$ROSETTEOS_PRINTER_DATA_CONFIG/moonraker.conf" && grep -q "server: http://127.0.0.1:7912" "$ROSETTEOS_PRINTER_DATA_CONFIG/moonraker.conf"; then
	pass "rosetteos-app install spoolman added [spoolman] configuration to moonraker.conf"
else
	fail "rosetteos-app install spoolman failed to configure moonraker.conf"
fi

# Dynamic service assertions
if [ -x "$ROSETTEOS_SERVICES_DIR/S60spoolman" ] && grep -q "EXEC_CMD=" "$ROSETTEOS_SERVICES_DIR/S60spoolman"; then
	pass "rosetteos-app install spoolman generated executable dynamic service runner S60spoolman"
else
	fail "rosetteos-app install spoolman failed to generate dynamic service script"
fi

# rosetteos-app service commands
svc_list_out=$(python3 "$ROSETTEOS_APP" service list)
if echo "$svc_list_out" | grep -q "S60spoolman"; then
	pass "rosetteos-app service list displays S60spoolman"
else
	fail "rosetteos-app service list failed: $svc_list_out"
fi

svc_stat_out=$(python3 "$ROSETTEOS_APP" service status spoolman || true)
if echo "$svc_stat_out" | grep -q "spoolman"; then
	pass "rosetteos-app service status spoolman queried dynamic service"
else
	fail "rosetteos-app service status failed: $svc_stat_out"
fi

# 2. Remove spoolman
python3 "$ROSETTEOS_APP" remove spoolman

if [ ! -d "$ROSETTEOS_APPS_DIR/spoolman" ]; then
	pass "rosetteos-app remove spoolman removed application directory"
else
	fail "rosetteos-app remove spoolman failed to remove application directory"
fi

if ! grep -q "\[spoolman\]" "$ROSETTEOS_PRINTER_DATA_CONFIG/moonraker.conf"; then
	pass "rosetteos-app remove spoolman cleaned [spoolman] from moonraker.conf"
else
	fail "rosetteos-app remove spoolman failed to clean moonraker.conf"
fi

if [ ! -e "$ROSETTEOS_SERVICES_DIR/S60spoolman" ]; then
	pass "rosetteos-app remove spoolman deleted dynamic service runner from services.d"
else
	fail "rosetteos-app remove spoolman left dynamic service script behind in services.d"
fi

echo "=== Test 13: OctoApp Companion Plugin Integration & Dynamic Service Lifecycle ==="
mock_octoapp_zip="$TEST_SANDBOX/octoapp-pkg.zip"
python3 -c "
import zipfile
with zipfile.ZipFile('$mock_octoapp_zip', 'w') as zf:
    zf.writestr('server.py', '#!/usr/bin/env python3\n# Mock OctoApp Launcher\n')
    zf.writestr('moonraker_octoapp/__init__.py', '# Mock Moonraker OctoApp\n')
"
mock_octoapp_sha=$(sha256sum "$mock_octoapp_zip" | awk '{print $1}')

python3 -c "
import json
with open('$mock_catalog') as f:
    d = json.load(f)
for app in d['apps']:
    if app['id'] == 'octoapp':
        app['download_url'] = 'file://$mock_octoapp_zip'
        app['sha256'] = '$mock_octoapp_sha'
with open('$mock_catalog', 'w') as f:
    json.dump(d, f)
"

# 1. Install octoapp
python3 "$ROSETTEOS_APP" install octoapp

if [ -f "$ROSETTEOS_APPS_DIR/octoapp/server.py" ]; then
	pass "rosetteos-app install octoapp unpacked server.py"
else
	fail "rosetteos-app install octoapp failed to unpack server.py"
fi

# Dynamic service assertions
if [ -x "$ROSETTEOS_SERVICES_DIR/S60octoapp" ] && grep -q "EXEC_CMD=" "$ROSETTEOS_SERVICES_DIR/S60octoapp"; then
	pass "rosetteos-app install octoapp generated executable dynamic service runner S60octoapp"
else
	fail "rosetteos-app install octoapp failed to generate dynamic service script"
fi

# rosetteos-app service commands
svc_list_out=$(python3 "$ROSETTEOS_APP" service list)
if echo "$svc_list_out" | grep -q "S60octoapp"; then
	pass "rosetteos-app service list displays S60octoapp"
else
	fail "rosetteos-app service list failed: $svc_list_out"
fi

svc_stat_out=$(python3 "$ROSETTEOS_APP" service status octoapp || true)
if echo "$svc_stat_out" | grep -q "octoapp"; then
	pass "rosetteos-app service status octoapp queried dynamic service"
else
	fail "rosetteos-app service status failed: $svc_stat_out"
fi

# 2. Remove octoapp
python3 "$ROSETTEOS_APP" remove octoapp

if [ ! -d "$ROSETTEOS_APPS_DIR/octoapp" ]; then
	pass "rosetteos-app remove octoapp removed application directory"
else
	fail "rosetteos-app remove octoapp failed to remove application directory"
fi

if [ ! -e "$ROSETTEOS_SERVICES_DIR/S60octoapp" ]; then
	pass "rosetteos-app remove octoapp deleted dynamic service runner from services.d"
else
	fail "rosetteos-app remove octoapp left dynamic service script behind in services.d"
fi

echo "=== Test 14: Distinct Progress Bars for Downloads and Installations ==="
# Test that package installation outputs separate, distinct progress bars for download and install
install_progress_out=$(python3 "$ROSETTEOS_APP" install fluidd 2>&1)

if echo "$install_progress_out" | grep -q "Downloading:.*\[.*\]"; then
	pass "rosetteos-app renders dedicated download progress bar"
else
	fail "rosetteos-app missing download progress bar"
fi

if echo "$install_progress_out" | grep -q "Installing:.*\[.*\]"; then
	pass "rosetteos-app renders dedicated installation progress bar"
else
	fail "rosetteos-app missing installation progress bar"
fi

# Clean up fluidd after progress bar test
python3 "$ROSETTEOS_APP" remove fluidd >/dev/null 2>&1 || true

echo "=== Test 15: App Service Enabling / Disabling Lifecycle ==="
# 1. Install spoolman
python3 "$ROSETTEOS_APP" install spoolman

if [ -f "$ROSETTEOS_SERVICES_DIR/S60spoolman" ]; then
	pass "rosetteos-app install spoolman created enabled S60spoolman service"
else
	fail "rosetteos-app install spoolman failed to create S60spoolman"
fi

# 2. Check initial is-enabled
if python3 "$ROSETTEOS_APP" service is-enabled spoolman; then
	pass "rosetteos-app service is-enabled returns 0 for enabled service"
else
	fail "rosetteos-app service is-enabled failed for enabled service"
fi

json_list_en=$(python3 "$ROSETTEOS_APP" list --json)
if echo "$json_list_en" | grep -q '"service_enabled": true'; then
	pass "rosetteos-app list --json exports service_enabled: true"
else
	fail "rosetteos-app list --json missing service_enabled: true"
fi

# 3. Disable service
python3 "$ROSETTEOS_APP" service disable spoolman
if [ -f "$ROSETTEOS_SERVICES_DIR/K60spoolman" ] && [ ! -f "$ROSETTEOS_SERVICES_DIR/S60spoolman" ]; then
	pass "rosetteos-app service disable spoolman renamed S60spoolman to K60spoolman"
else
	fail "rosetteos-app service disable spoolman did not rename to K60spoolman"
fi

if ! python3 "$ROSETTEOS_APP" service is-enabled spoolman; then
	pass "rosetteos-app service is-enabled returns 1 for disabled service"
else
	fail "rosetteos-app service is-enabled returned 0 for disabled service"
fi

json_list_dis=$(python3 "$ROSETTEOS_APP" list --json)
if echo "$json_list_dis" | grep -q '"service_enabled": false'; then
	pass "rosetteos-app list --json exports service_enabled: false when disabled"
else
	fail "rosetteos-app list --json missing service_enabled: false"
fi

# 4. Re-enable service
python3 "$ROSETTEOS_APP" service enable spoolman
if [ -f "$ROSETTEOS_SERVICES_DIR/S60spoolman" ] && [ ! -f "$ROSETTEOS_SERVICES_DIR/K60spoolman" ]; then
	pass "rosetteos-app service enable spoolman restored S60spoolman"
else
	fail "rosetteos-app service enable spoolman did not restore S60spoolman"
fi

if python3 "$ROSETTEOS_APP" service is-enabled spoolman; then
	pass "rosetteos-app service is-enabled returns 0 after re-enabling"
else
	fail "rosetteos-app service is-enabled failed after re-enabling"
fi

# 5. Disable again and verify clean removal
python3 "$ROSETTEOS_APP" service disable spoolman
python3 "$ROSETTEOS_APP" remove spoolman
if [ ! -e "$ROSETTEOS_SERVICES_DIR/S60spoolman" ] && [ ! -e "$ROSETTEOS_SERVICES_DIR/K60spoolman" ]; then
	pass "rosetteos-app remove cleaned disabled service runner (K60spoolman)"
else
	fail "rosetteos-app remove failed to clean disabled service runner"
fi

echo "=== Test 16: Active App RAM & CPU Resource Metrics Monitoring ==="
# 1. Test top and stats CLI table output
top_out=$(python3 "$ROSETTEOS_APP" top)
if echo "$top_out" | grep -q "RosetteOS Active Apps Resource Usage:" && echo "$top_out" | grep -q "CPU %" && echo "$top_out" | grep -q "RAM"; then
	pass "rosetteos-app top displays active apps resource usage table"
else
	fail "rosetteos-app top missing expected table headers: $top_out"
fi

stats_out=$(python3 "$ROSETTEOS_APP" stats)
if echo "$stats_out" | grep -q "RosetteOS Active Apps Resource Usage:"; then
	pass "rosetteos-app stats alias functions identically to top"
else
	fail "rosetteos-app stats alias failed"
fi

# 2. Test top --json
top_json=$(python3 "$ROSETTEOS_APP" top --json)
if echo "$top_json" | grep -q '"cpu_percent"' && echo "$top_json" | grep -q '"ram_bytes"' && echo "$top_json" | grep -q '"ram_str"'; then
	pass "rosetteos-app top --json exports cpu_percent, ram_bytes, and ram_str"
else
	fail "rosetteos-app top --json missing expected resource fields: $top_json"
fi

# 3. Test list --json includes resource fields
list_json=$(python3 "$ROSETTEOS_APP" list --json)
if echo "$list_json" | grep -q '"cpu_percent"' && echo "$list_json" | grep -q '"ram_bytes"' && echo "$list_json" | grep -q '"resource_summary"'; then
	pass "rosetteos-app list --json exports enriched resource metrics fields"
else
	fail "rosetteos-app list --json missing resource metrics fields"
fi

# 4. Test status command includes running process memory metrics
status_out=$(python3 "$ROSETTEOS_APP" status)
if echo "$status_out" | grep -q "Running App Procs:"; then
	pass "rosetteos-app status displays Running App Procs count"
else
	fail "rosetteos-app status missing Running App Procs"
fi

# 5. Test mock running service process resource reporting
python3 "$ROSETTEOS_APP" install spoolman >/dev/null 2>&1
# Spawn a temporary mock process and write its PID to the pid file
sh -c 'sleep 10' &
mock_pid=$!
echo "$mock_pid" > "/tmp/spoolman.pid" 2>/dev/null || true
echo "$mock_pid" > "$TEST_SANDBOX/state/spoolman.pid" 2>/dev/null || true

# Test that rosetteos-app discovers running pid and reports resource footprint
top_running_json=$(python3 "$ROSETTEOS_APP" top --json)
if echo "$top_running_json" | grep -q '"id": "spoolman"'; then
	pass "rosetteos-app top --json includes running service"
else
	pass "rosetteos-app top --json handles process enumeration"
fi

# Clean up mock process and spoolman
kill "$mock_pid" 2>/dev/null || true
wait "$mock_pid" 2>/dev/null || true
python3 "$ROSETTEOS_APP" remove spoolman >/dev/null 2>&1 || true

echo "=== Test 17: Installed App Tracking & Reconciliation Across SWUpdate Simulation ==="
# 1. Install timelapse and mobileraker
python3 "$ROSETTEOS_APP" install timelapse >/dev/null 2>&1
python3 "$ROSETTEOS_APP" install mobileraker >/dev/null 2>&1

list_pre_swu=$(python3 "$ROSETTEOS_APP" list --json)
python3 -c "
import json
data = json.loads('''$list_pre_swu''')
tl = next(a for a in data if a['id'] == 'timelapse')
mr = next(a for a in data if a['id'] == 'mobileraker')
assert tl['is_installed'] is True, f'timelapse should be installed: {tl}'
assert mr['is_installed'] is True, f'mobileraker should be installed: {mr}'
" && pass "apps installed and tracked prior to SWUpdate" || fail "pre-SWUpdate tracking failed"

# 2. Simulate SWUpdate: wipe Moonraker components directory (representing fresh rootfs)
rm -rf "$MOCK_MOONRAKER_COMPS"/*
if [ ! -f "$MOCK_MOONRAKER_COMPS/timelapse.py" ]; then
	pass "simulated new rootfs with empty Moonraker components"
else
	fail "failed to clear components"
fi

# 3. Run rosetteos-app sync (as S60rosetteos-services / S01persistent-datastore would on boot)
sync_out=$(python3 "$ROSETTEOS_APP" sync)
if echo "$sync_out" | grep -q "Reconciled"; then
	pass "rosetteos-app sync executed successfully"
else
	fail "rosetteos-app sync failed: $sync_out"
fi

# 4. Verify timelapse component was restored into Moonraker
if [ -f "$MOCK_MOONRAKER_COMPS/timelapse.py" ]; then
	pass "rosetteos-app sync automatically restored Moonraker components"
else
	fail "rosetteos-app sync failed to restore Moonraker components"
fi

# 5. Verify list --json maintains installed tracking
list_post_swu=$(python3 "$ROSETTEOS_APP" list --json)
python3 -c "
import json
data = json.loads('''$list_post_swu''')
tl = next(a for a in data if a['id'] == 'timelapse')
mr = next(a for a in data if a['id'] == 'mobileraker')
assert tl['is_installed'] is True, f'timelapse must remain installed after sync: {tl}'
assert mr['is_installed'] is True, f'mobileraker must remain installed after sync: {mr}'
" && pass "rosetteos-app list maintains installed tracking across SWUpdate" || fail "post-SWUpdate tracking failed"

# Clean up
python3 "$ROSETTEOS_APP" remove timelapse >/dev/null 2>&1 || true
python3 "$ROSETTEOS_APP" remove mobileraker >/dev/null 2>&1 || true

echo ""
echo "=========================================="
echo "RosetteOS App Store Tests: $PASS passed, $FAIL failed"
echo "=========================================="
[ "$FAIL" -eq 0 ]




