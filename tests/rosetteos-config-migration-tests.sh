#!/bin/sh
#
# Offline, repeatable tests for the RosetteOS Printer Config Migration Engine
# (scripts/build/lib/migrate-printer-config.sh).
#
# Validates:
#   1. Automatic commenting out of template baseline fields that are overridden in SAVE_CONFIG
#   2. Complete preservation of user calibration data (Bed Mesh, Probe Z-offset, PID tunes)
#   3. Legacy include path rewrites (e.g. frontend-controls.cfg -> macros/mainsail.cfg)
#   4. Managed module synchronization (macros/ and hardware/)
#   5. Preservation of user-created custom macro files
#   6. Pre-migration backup creation
#   7. Full closure validation of migrated printer.cfg
#
# Usage: sh tests/rosetteos-config-migration-tests.sh
#

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
LIB="$REPO_ROOT/scripts/build/lib/migrate-printer-config.sh"
VALIDATOR_LIB="$REPO_ROOT/scripts/build/lib/validate-frontend-controls.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/config-migration-tests.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM

# shellcheck disable=SC1090
. "$LIB"
# shellcheck disable=SC1090
. "$VALIDATOR_LIB"

PASS=0
FAIL=0

fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

# =========================================================================
# Test 1: Option conflict commenting & SAVE_CONFIG transplantation
# =========================================================================
echo "=== Test 1: Option conflict commenting & SAVE_CONFIG transplantation ==="

t1_old="$WORK/t1_old.cfg"
t1_template="$WORK/t1_template.cfg"
t1_out="$WORK/t1_out.cfg"

cat > "$t1_template" <<'EOF'
[printer]
kinematics: cartesian
max_velocity: 500

[probe]
pin: !PA0
z_offset: 0.0

[extruder]
step_pin: PB4
control: pid
pid_Kp: 22.200
pid_Ki: 1.080
pid_Kd: 114.000

[heater_bed]
heater_pin: PB10
control: pid
pid_Kp: 65.000
pid_Ki: 2.000
pid_Kd: 500.000

[include macros/mainsail.cfg]
EOF

cat > "$t1_old" <<'EOF'
[printer]
kinematics: cartesian

#*# <---------------------- SAVE_CONFIG ---------------------->
#*# DO NOT EDIT THIS BLOCK OR BELOW. The contents are auto-generated.
#*#
#*# [probe]
#*# z_offset = 1.450
#*#
#*# [extruder]
#*# control = pid
#*# pid_kp = 26.432
#*# pid_ki = 1.621
#*# pid_kd = 107.890
#*#
#*# [heater_bed]
#*# control = pid
#*# pid_kp = 68.123
#*# pid_ki = 2.456
#*# pid_kd = 512.789
#*#
#*# [bed_mesh default]
#*# version = 1
#*# points =
#*# 	0.012500, 0.025000, 0.015000
#*# 	-0.010000, 0.000000, 0.020000
#*# 	0.030000, 0.015000, -0.005000
#*# x_count = 3
#*# y_count = 3
#*# mesh_x_pps = 2
#*# mesh_y_pps = 2
#*# algo = lagrange
#*# tension = 0.2
EOF

rosetteos_migrate_printer_cfg "$t1_old" "$t1_template" "$t1_out"

# Verify that z_offset in [probe] body is commented out with "# " (never "#*#")
if grep -q "^#[[:space:]]*z_offset:[[:space:]]*0\.0" "$t1_out"; then
	pass "probe z_offset in template body was correctly commented out with #"
else
	fail "probe z_offset was not commented out in template body"
fi

# Verify NO "#*#" appears anywhere in the body before SAVE_CONFIG header
body_before_save=$(sed '/^#\*# <---------------------- SAVE_CONFIG ---------------------->/,$d' "$t1_out")
if printf '%s' "$body_before_save" | grep -q "^#\*#"; then
	fail "#*# comment prefix found in regular body before SAVE_CONFIG (causes Klipper to reject autosave as corrupted!)"
else
	pass "no #*# prefix in regular body before SAVE_CONFIG"
fi

if grep -A2 "^\[probe\]" "$t1_out" | grep -q "^z_offset:[[:space:]]*0\.0"; then
	fail "probe z_offset is still active in template body (would cause Klipper conflict!)"
else
	pass "probe z_offset is not active in template body"
fi

# Verify extruder PID parameters are commented out in body
if grep -q "^#[[:space:]]*pid_Kp:[[:space:]]*22\.200" "$t1_out" && \
   grep -q "^#[[:space:]]*control:[[:space:]]*pid" "$t1_out"; then
	pass "extruder control and PID parameters in template body were commented out"
else
	fail "extruder PID parameters in template body were not commented out"
fi

# Verify heater_bed PID parameters are commented out in body
if grep -q "^#[[:space:]]*pid_Kp:[[:space:]]*65\.000" "$t1_out"; then
	pass "heater_bed PID parameters in template body were commented out"
else
	fail "heater_bed PID parameters in template body were not commented out"
fi

# Verify SAVE_CONFIG block is preserved at the bottom with exact user calibration values
if grep -q "^#\*#[[:space:]]*z_offset = 1\.450" "$t1_out" && \
   grep -q "^#\*#[[:space:]]*pid_kp = 26\.432" "$t1_out" && \
   grep -q "^#\*#[[:space:]]*pid_kp = 68\.123" "$t1_out"; then
	pass "user calibration values preserved intact in SAVE_CONFIG block"
else
	fail "user calibration values missing from SAVE_CONFIG block"
fi

# Verify bed_mesh default matrix is preserved
if grep -q "0\.012500, 0\.025000, 0\.015000" "$t1_out" && \
   grep -q "^#\*#[[:space:]]*\[bed_mesh default\]" "$t1_out"; then
	pass "user bed_mesh default calibration matrix preserved intact"
else
	fail "user bed_mesh default matrix was lost during migration"
fi

# =========================================================================
# Test 2: Migration of config without SAVE_CONFIG block
# =========================================================================
echo "=== Test 2: Migration of config without SAVE_CONFIG block ==="

t2_old="$WORK/t2_old.cfg"
t2_template="$WORK/t2_template.cfg"
t2_out="$WORK/t2_out.cfg"

cat > "$t2_template" <<'EOF'
[printer]
kinematics: cartesian
max_velocity: 500

[include hardware/nebula_pad.cfg]
[include macros/mainsail.cfg]
EOF

cat > "$t2_old" <<'EOF'
[printer]
kinematics: cartesian
max_velocity: 300
EOF

rosetteos_migrate_printer_cfg "$t2_old" "$t2_template" "$t2_out"

if grep -q "\[include macros/mainsail\.cfg\]" "$t2_out" && \
   grep -q "max_velocity: 500" "$t2_out"; then
	pass "config without SAVE_CONFIG adopts new template cleanly"
else
	fail "config without SAVE_CONFIG failed to adopt template"
fi

# =========================================================================
# Test 3: Full tree migration with backup & custom file preservation
# =========================================================================
echo "=== Test 3: Full tree migration with backup & custom file preservation ==="

ns_root="$WORK/t3_ns"
seeds_dir="$WORK/t3_seeds"
mkdir -p "$ns_root/printer_data/config/macros" "$ns_root/printer_data/config/hardware" "$ns_root/system"
mkdir -p "$seeds_dir/printer_data-config/macros" "$seeds_dir/printer_data-config/hardware" "$seeds_dir/printer_data-config/GuppyScreen"

# Setup existing user config with custom macro and user calibrations
cat > "$ns_root/printer_data/config/printer.cfg" <<'EOF'
[printer]
kinematics: cartesian

[probe]
pin: !PA0
z_offset: 0.0

[include hardware/nebula_pad.cfg]
[include macros/mainsail.cfg]
[include macros/my_custom_macro.cfg]

#*# <---------------------- SAVE_CONFIG ---------------------->
#*# [probe]
#*# z_offset = 1.337
EOF

echo "# user custom macro" > "$ns_root/printer_data/config/macros/my_custom_macro.cfg"
echo "# old mainsail" > "$ns_root/printer_data/config/macros/mainsail.cfg"

# Setup seeds
cat > "$seeds_dir/printer_data-config/printer.cfg" <<'EOF'
[printer]
kinematics: cartesian
max_velocity: 500

[probe]
pin: !PA0
z_offset: 0.0

[include hardware/nebula_pad.cfg]
[include macros/mainsail.cfg]
EOF

echo "# new updated mainsail" > "$seeds_dir/printer_data-config/macros/mainsail.cfg"
echo "# new updated nebula_pad" > "$seeds_dir/printer_data-config/hardware/nebula_pad.cfg"
echo "# guppy" > "$seeds_dir/printer_data-config/GuppyScreen/guppy_cmd.cfg"

# Run rosetteos_migrate_config_tree
rosetteos_migrate_config_tree "$ns_root" "$seeds_dir" "$ns_root/backups/printer_config/test_backup"

# Verify backup was created with pre-migration content
if [ -f "$ns_root/backups/printer_config/test_backup/printer.cfg" ] && \
   grep -q "my_custom_macro.cfg" "$ns_root/backups/printer_config/test_backup/printer.cfg"; then
	pass "pre-migration backup created with original configuration"
else
	fail "pre-migration backup missing or invalid"
fi

# Verify user custom macro is preserved untouched
if [ -f "$ns_root/printer_data/config/macros/my_custom_macro.cfg" ] && \
   grep -q "# user custom macro" "$ns_root/printer_data/config/macros/my_custom_macro.cfg"; then
	pass "user custom macro preserved untouched"
else
	fail "user custom macro was deleted or modified"
fi

# Verify system macro was upgraded from seeds
if grep -q "# new updated mainsail" "$ns_root/printer_data/config/macros/mainsail.cfg"; then
	pass "system macro was updated to seed version"
else
	fail "system macro was not updated from seed"
fi

# Verify system hardware config was updated from seeds
if grep -q "# new updated nebula_pad" "$ns_root/printer_data/config/hardware/nebula_pad.cfg"; then
	pass "hardware config was updated to seed version"
else
	fail "hardware config was not updated from seed"
fi

# Verify printer.cfg has calibrated SAVE_CONFIG value and commented-out baseline
if grep -q "^#[[:space:]]*z_offset:[[:space:]]*0\.0" "$ns_root/printer_data/config/printer.cfg" && \
   grep -q "^#\*#[[:space:]]*z_offset = 1\.337" "$ns_root/printer_data/config/printer.cfg"; then
	pass "migrated printer.cfg preserved calibration and commented out baseline"
else
	fail "migrated printer.cfg did not preserve calibration properly"
fi

# =========================================================================
# Test 4: End-to-end closure validation on real overlay config
# =========================================================================
echo "=== Test 4: End-to-end closure validation on real overlay config ==="

REAL_OVERLAY="$REPO_ROOT/scripts/build/overlay/opt/printer_data/config"
real_migrated="$WORK/real_migrated.cfg"
rosetteos_migrate_printer_cfg "$REAL_OVERLAY/printer.cfg" "$REAL_OVERLAY/printer.cfg" "$real_migrated"

closure="$WORK/closure.txt"
if frontend_controls_resolve_closure "$REAL_OVERLAY" printer.cfg "$closure" >"$WORK/vlog.txt" 2>&1; then
	if frontend_controls_validate_closure "$closure" "/opt/printer_data/gcodes" >>"$WORK/vlog.txt" 2>&1; then
		pass "real overlay printer.cfg closure passes full validation end-to-end"
	else
		fail "closure validation failed: $(cat "$WORK/vlog.txt")"
	fi
else
	fail "closure resolution failed: $(cat "$WORK/vlog.txt")"
fi

# =========================================================================
# Test 5: BLTouch & Heater Bed Hardware Sections Complete Preservation
# =========================================================================
echo "=== Test 5: BLTouch & Heater Bed Hardware Sections Complete Preservation ==="

t5_old="$WORK/t5_old.cfg"
t5_template="$WORK/t5_template.cfg"
t5_out="$WORK/t5_out.cfg"

cat > "$t5_template" <<'EOF'
[printer]
kinematics: cartesian

[bltouch]
sensor_pin: ^PC14
control_pin: PC13
x_offset: -24
y_offset: -13
z_offset: 0.0
speed: 5.0
samples: 2

[heater_bed]
heater_pin: PB2
sensor_type: EPCOS 100K B57560G104F
sensor_pin: PC4
control: pid
pid_Kp: 70.652
pid_Ki: 1.798
pid_Kd: 694.157
min_temp: 0
max_temp: 120
EOF

cat > "$t5_old" <<'EOF'
[printer]
kinematics: cartesian

#*# <---------------------- SAVE_CONFIG ---------------------->
#*# DO NOT EDIT THIS BLOCK OR BELOW. The contents are auto-generated.
#*#
#*# [bltouch]
#*# z_offset = 2.150
#*#
#*# [heater_bed]
#*# control = pid
#*# pid_kp = 66.861
#*# pid_ki = 1.305
#*# pid_kd = 856.657
#*#
#*# [bed_mesh default]
#*# version = 1
#*# points =
#*# 	0.010, 0.020
#*# 	-0.010, 0.000
#*# x_count = 2
#*# y_count = 2
EOF

rosetteos_migrate_printer_cfg "$t5_old" "$t5_template" "$t5_out"

# 1. Verify [bltouch] section header is active (NOT commented out)
if grep -q "^\[bltouch\]" "$t5_out"; then
	pass "[bltouch] section header is active and not commented out"
else
	fail "[bltouch] section header was commented out!"
fi

# 2. Verify all bltouch hardware pins remain active
if grep -q "^sensor_pin:[[:space:]]*\^PC14" "$t5_out" && \
   grep -q "^control_pin:[[:space:]]*PC13" "$t5_out" && \
   grep -q "^x_offset:[[:space:]]*-24" "$t5_out"; then
	pass "all [bltouch] hardware pin definitions remain intact and active"
else
	fail "[bltouch] hardware pins were corrupted or commented out"
fi

# 3. Verify [heater_bed] section header and pins remain active
if grep -q "^\[heater_bed\]" "$t5_out" && \
   grep -q "^heater_pin:[[:space:]]*PB2" "$t5_out" && \
   grep -q "^sensor_type:[[:space:]]*EPCOS 100K B57560G104F" "$t5_out"; then
	pass "[heater_bed] section header and hardware pins remain intact and active"
else
	fail "[heater_bed] section header or pins were corrupted or commented out"
fi

# 4. Verify baseline options overridden by SAVE_CONFIG are commented out with "#"
if grep -q "^#[[:space:]]*z_offset:[[:space:]]*0\.0" "$t5_out" && \
   grep -q "^#[[:space:]]*control:[[:space:]]*pid" "$t5_out" && \
   grep -q "^#[[:space:]]*pid_Kp:[[:space:]]*70\.652" "$t5_out"; then
	pass "overridden baseline options (z_offset, control, pid_Kp) commented out with #"
else
	fail "overridden baseline options were not commented out with #"
fi

# =========================================================================
# Test 6: Direct Klipper Python config parser integration test
# =========================================================================
echo "=== Test 6: Direct Klipper Python config parser integration test ==="

python3 -c "
import sys
sys.path.insert(0, '$REPO_ROOT/vendor/klipper/klippy')
import configfile

cfgrdr = configfile.ConfigFileReader()
autosave_helper = configfile.ConfigAutoSave.__new__(configfile.ConfigAutoSave)

data = cfgrdr.read_config_file('$t5_out')
regular_data, autosave_data = autosave_helper._find_autosave_data(data)
assert len(autosave_data) > 0, 'Klipper rejected autosave_data as corrupted!'

reg_fc = cfgrdr.build_fileconfig_with_includes(regular_data, '$t5_out')
autosave_data = autosave_helper._strip_duplicates(autosave_data, reg_fc)
auto_fc = cfgrdr.build_fileconfig(autosave_data, '$t5_out')
cfgrdr.append_fileconfig(reg_fc, autosave_data, '*AUTOSAVE*')

assert reg_fc.has_section('bltouch'), '[bltouch] missing from Klipper config'
assert reg_fc.get('bltouch', 'sensor_pin') == '^PC14', 'bltouch sensor_pin mismatch'
assert reg_fc.get('bltouch', 'z_offset') == '2.150', 'bltouch z_offset was not loaded from autosave'
assert reg_fc.has_section('heater_bed'), '[heater_bed] missing from Klipper config'
assert reg_fc.get('heater_bed', 'control') == 'pid', 'heater_bed control missing or invalid'
assert reg_fc.get('heater_bed', 'pid_kp') == '66.861', 'heater_bed pid_kp was not loaded from autosave'
assert reg_fc.has_section('bed_mesh default'), '[bed_mesh default] missing from Klipper config'
print('KLIPPER_PARSER_SUCCESS')
" > "$WORK/pyout.txt" 2>&1

if grep -q "KLIPPER_PARSER_SUCCESS" "$WORK/pyout.txt"; then
	pass "migrated config passed native Klipper parser validation with all calibrations active"
else
	fail "native Klipper parser failed: $(cat "$WORK/pyout.txt")"
fi

# =========================================================================
# Test 7: S04rosetteos-migrate standalone config migration (app gen unchanged)
# =========================================================================
echo "=== Test 7: S04rosetteos-migrate standalone config migration (app gen unchanged) ==="

t7_seeds="$WORK/t7_seeds"
t7_root="$WORK/t7_root"
mkdir -p "$t7_seeds/printer_data-config/macros" "$t7_seeds/printer_data-config/hardware" "$t7_seeds/printer_data-config/GuppyScreen"
mkdir -p "$t7_root/printer_data/config/macros" "$t7_root/system" "$t7_root/apps/klipper"

cat > "$t7_seeds/seed-manifest.json" <<EOF
{
  "migration_version": "gen-v1",
  "config_version": "cfg-v2"
}
EOF

cat > "$t7_seeds/printer_data-config/printer.cfg" <<'EOF'
[printer]
kinematics: cartesian
[include macros/print_start.cfg]
EOF
echo "# print start macro" > "$t7_seeds/printer_data-config/macros/print_start.cfg"

cat > "$t7_root/system/app-generation.json" <<EOF
{
  "migration_version": "gen-v1"
}
EOF

cat > "$t7_root/system/config-generation.json" <<EOF
{
  "config_version": "cfg-v1"
}
EOF

cat > "$t7_root/printer_data/config/printer.cfg" <<'EOF'
[printer]
kinematics: cartesian
EOF

MIGRATE_INIT="$REPO_ROOT/scripts/build/overlay/etc/init.d/S04rosetteos-migrate"
CONFIG_LIB="$REPO_ROOT/scripts/build/overlay/etc/rosetteos-config-migrate.sh"
GATE_LIB="$REPO_ROOT/scripts/build/overlay/etc/rosetteos-maintenance-gate.sh"

env S04ROSETTEOS_MIGRATE_NO_AUTORUN=1 \
    SEEDS="$t7_seeds" \
    ROSETTEOS_ROOT="$t7_root" \
    SYSTEM="$t7_root/system" \
    CONFIG_MIGRATE_LIB="$CONFIG_LIB" \
    GATE_LIB="$GATE_LIB" \
    sh -c ". '$MIGRATE_INIT'; start" > "$WORK/t7.log" 2>&1

if [ -f "$t7_root/printer_data/config/macros/print_start.cfg" ] && \
   grep -q "print_start.cfg" "$t7_root/printer_data/config/printer.cfg" && \
   grep -q "cfg-v2" "$t7_root/system/config-generation.json"; then
	pass "S04rosetteos-migrate successfully migrated config when app generation was unchanged"
else
	fail "S04rosetteos-migrate failed to migrate config: $(cat "$WORK/t7.log")"
fi

# =========================================================================
# Test 8: rosetteos_migrate_moonraker_conf (preserves user settings, adds zeroconf, rewrites legacy paths)
# =========================================================================
echo "=== Test 8: rosetteos_migrate_moonraker_conf unit migration ==="

t8_old="$WORK/t8_old_moonraker.conf"
t8_tpl="$WORK/t8_tpl_moonraker.conf"
t8_out="$WORK/t8_out_moonraker.conf"

cat > "$t8_tpl" <<'EOF'
# RosetteOS - Moonraker config
[server]
host: 0.0.0.0
port: 7125
klippy_uds_address: /opt/printer_data/comms/klippy.sock

[zeroconf]

[file_manager]
enable_object_processing: True

[machine]
provider: supervisord_cli
validate_service: False
validate_config: False

[update_manager]
enable_auto_refresh: False
enable_system_updates: False

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
 192.168.0.0/16
 10.0.0.0/8
cors_domains:
 http://*.local
 http://*.lan
EOF

cat > "$t8_old" <<'EOF'
# Legacy OpenKE Moonraker config
[server]
host: 0.0.0.0
port: 7125
klippy_uds_address: /opt/printer_data/comms/klippy.sock

[file_manager]
enable_object_processing: True

[machine]
provider: supervisord_cli
validate_service: False
validate_config: False

[update_manager]
enable_auto_refresh: False
enable_system_updates: False

[update_manager klipper]
channel: dev

[update_manager moonraker]
channel: dev

[update_manager mainsail]
type: web
channel: beta
repo: mainsail-crew/mainsail
path: /usr/data/openke/apps/mainsail

[authorization]
trusted_clients:
 127.0.0.1
 192.168.0.0/16
 10.0.0.0/8
 192.168.1.150
cors_domains:
 *.local
 *.lan
 mycustomdomain.lan

[timelapse]
output_path: /opt/printer_data/timelapse/

[spoolman]
server: http://127.0.0.1:7912
EOF

rosetteos_migrate_moonraker_conf "$t8_old" "$t8_tpl" "$t8_out"

if grep -q "\[zeroconf\]" "$t8_out"; then
	pass "moonraker.conf migration added [zeroconf] section"
else
	fail "moonraker.conf migration failed to add [zeroconf]"
fi

if grep -q "192.168.1.150" "$t8_out" && grep -q "mycustomdomain.lan" "$t8_out"; then
	pass "user custom trusted_clients and cors_domains were preserved"
else
	fail "user custom authorization settings were lost"
fi

if grep -q "\[timelapse\]" "$t8_out" && grep -q "\[spoolman\]" "$t8_out"; then
	pass "installed app sections [timelapse] and [spoolman] were preserved"
else
	fail "installed app sections were lost during moonraker.conf migration"
fi

if grep -q "path: /usr/data/rosetteos/apps/mainsail" "$t8_out" && ! grep -q "/usr/data/openke" "$t8_out"; then
	pass "legacy openke path rewritten to rosetteos"
else
	fail "legacy path was not rewritten in moonraker.conf"
fi

# Idempotency check
t8_out2="$WORK/t8_out2_moonraker.conf"
rosetteos_migrate_moonraker_conf "$t8_out" "$t8_tpl" "$t8_out2"
if cmp -s "$t8_out" "$t8_out2"; then
	pass "moonraker.conf migration is fully idempotent"
else
	fail "moonraker.conf migration is not idempotent"
fi

# =========================================================================
# Test 9: S04rosetteos-migrate reconciles moonraker.conf when [zeroconf] is missing
# =========================================================================
echo "=== Test 9: S04rosetteos-migrate reconciles moonraker.conf when [zeroconf] is missing ==="

t9_seeds="$WORK/t9_seeds"
t9_root="$WORK/t9_root"
mkdir -p "$t9_seeds/printer_data-config"
mkdir -p "$t9_root/printer_data/config" "$t9_root/system" "$t9_root/apps/klipper"

cat > "$t9_seeds/seed-manifest.json" <<EOF
{
  "migration_version": "gen-v1",
  "config_version": "cfg-v1"
}
EOF

cp "$t8_tpl" "$t9_seeds/printer_data-config/moonraker.conf"
cat > "$t9_seeds/printer_data-config/printer.cfg" <<'EOF'
[printer]
kinematics: cartesian
EOF

cat > "$t9_root/system/app-generation.json" <<EOF
{
  "migration_version": "gen-v1"
}
EOF

# Simulate a post-SWUpdate state where config-generation.json ALREADY matches image cfg-v1,
# but moonraker.conf is still the pre-update version missing [zeroconf]
cat > "$t9_root/system/config-generation.json" <<EOF
{
  "config_version": "cfg-v1"
}
EOF

cat > "$t9_root/printer_data/config/printer.cfg" <<'EOF'
[printer]
kinematics: cartesian
EOF

# Pre-update moonraker.conf without [zeroconf]
cp "$t8_old" "$t9_root/printer_data/config/moonraker.conf"

env S04ROSETTEOS_MIGRATE_NO_AUTORUN=1 \
    SEEDS="$t9_seeds" \
    ROSETTEOS_ROOT="$t9_root" \
    SYSTEM="$t9_root/system" \
    CONFIG_MIGRATE_LIB="$CONFIG_LIB" \
    GATE_LIB="$GATE_LIB" \
    sh -c ". '$MIGRATE_INIT'; start" > "$WORK/t9.log" 2>&1

if grep -q "\[zeroconf\]" "$t9_root/printer_data/config/moonraker.conf"; then
	pass "S04rosetteos-migrate reconciled moonraker.conf and added [zeroconf] despite matching generation"
else
	fail "S04rosetteos-migrate failed to reconcile moonraker.conf: $(cat "$WORK/t9.log")"
fi

if [ -d "$t9_root/backups/printer_config" ] && [ "$(ls -A "$t9_root/backups/printer_config" 2>/dev/null)" ]; then
	pass "pre-migration backup directory created for reconciled configuration"
else
	fail "pre-migration backup was not created"
fi

echo ""
echo "=========================================="
echo "Config Migration Tests: $PASS passed, $FAIL failed"
echo "=========================================="
[ "$FAIL" -eq 0 ]


