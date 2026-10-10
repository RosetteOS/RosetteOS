#!/bin/sh
#
# RosetteOS Printer Config Migration & Versioning Engine
#
# Intelligently migrates Klipper and Moonraker configuration across OTA SWUpdates
# and firmware upgrades while strictly preserving:
#   1. All user calibration data in #*# <--- SAVE_CONFIG ---> (Z-offset, Bed Mesh, PID tunes, Input Shaper)
#   2. Option conflict invariants (auto-comments out baseline values in target template matching SAVE_CONFIG)
#   3. User-created custom macro files in macros/
#   4. Rollback safety (creates timestamped snapshot in backups/printer_config/ before modifying)
#

set -u

# Core function: Migrate a single printer.cfg by transplanting the SAVE_CONFIG block
# and commenting out conflicting baseline options in the target template.
#
# Usage: rosetteos_migrate_printer_cfg <old_cfg> <template_cfg> <out_cfg>
rosetteos_migrate_printer_cfg() {
	old_file="$1"
	template_file="$2"
	out_file="$3"

	if [ ! -f "$template_file" ]; then
		echo "ERROR: template file not found: $template_file" >&2
		return 1
	fi

	if [ ! -f "$old_file" ]; then
		# No existing config - just copy the template
		cp -a "$template_file" "$out_file"
		return 0
	fi

	# Check if existing file has a SAVE_CONFIG block
	if ! grep -q "^#\*# <---------------------- SAVE_CONFIG ---------------------->" "$old_file" 2>/dev/null; then
		# No SAVE_CONFIG block - template is applied directly
		cp -a "$template_file" "$out_file"
		return 0
	fi

	# Extract SAVE_CONFIG block and parse overridden sections and keys
	# awk script processes the template and comments out matching options
	awk '
	BEGIN {
		in_save_config = 0
		save_config_text = ""
		cur_override_section = ""
		in_template_save_config = 0
	}
	# Pass 1: Read the old config and extract SAVE_CONFIG block + map overrides
	FILENAME == ARGV[1] {
		if ($0 ~ /^#\*# <---------------------- SAVE_CONFIG ---------------------->/) {
			in_save_config = 1
		}
		if (in_save_config) {
			save_config_text = save_config_text $0 "\n"
			# Strip "#*# " prefix for parsing
			line = $0
			sub(/^#\*[#[:space:]]*/, "", line)
			if (line ~ /^\[[[:space:]]*[^]]+[[:space:]]*\]/) {
				sec = line
				sub(/^\[[[:space:]]*/, "", sec)
				sub(/[[:space:]]*\].*$/, "", sec)
				cur_override_section = tolower(sec)
			} else if (cur_override_section != "" && line ~ /^[a-zA-Z0-9_]+[[:space:]]*[:=]/) {
				key = line
				sub(/[[:space:]]*[:=].*$/, "", key)
				key = tolower(key)
				overrides[cur_override_section "::" key] = 1
			}
		}
		next
	}
	# Pass 2: Read template and comment out options overridden in SAVE_CONFIG
	FILENAME == ARGV[2] {
		if ($0 ~ /^#\*# <---------------------- SAVE_CONFIG ---------------------->/) {
			in_template_save_config = 1
		}
		if (in_template_save_config) {
			next
		}

		line = $0
		if (line ~ /^\[[[:space:]]*[^]]+[[:space:]]*\]/) {
			sec = line
			sub(/^\[[[:space:]]*/, "", sec)
			sub(/[[:space:]]*\].*$/, "", sec)
			current_template_section = tolower(sec)
			print line
			next
		}

		# Check if current line defines an option in current_template_section
		if (current_template_section != "" && line ~ /^[[:space:]]*[a-zA-Z0-9_]+[[:space:]]*[:=]/) {
			key = line
			sub(/^[[:space:]]*/, "", key)
			sub(/[[:space:]]*[:=].*$/, "", key)
			key_lower = tolower(key)
			lookup = current_template_section "::" key_lower
			if (lookup in overrides) {
				# Comment out with "# " (NEVER "#*#" in the regular body, which Klipper treats as corruption)
				print "# " line
				next
			}
		}

		print line
	}
	END {
		if (save_config_text != "") {
			# Ensure a newline before SAVE_CONFIG block if needed
			printf "\n%s", save_config_text
		}
	}
	' "$old_file" "$template_file" > "$out_file"

	return 0
}

# Core function: Migrate moonraker.conf by reconciling template sections (such as [zeroconf]),
# preserving all user-added sections (apps, timelapse, spoolman), rewriting legacy paths,
# and safely ensuring required local network and mDNS CORS authorization.
#
# Usage: rosetteos_migrate_moonraker_conf <old_conf> <template_conf> <out_conf>
rosetteos_migrate_moonraker_conf() {
	old_file="$1"
	template_file="$2"
	out_file="$3"

	if [ ! -f "$template_file" ]; then
		echo "ERROR: template file not found: $template_file" >&2
		return 1
	fi

	if [ ! -f "$old_file" ]; then
		cp -a "$template_file" "$out_file"
		return 0
	fi

	py_bin=""
	for cand in python3 /usr/bin/python3 /usr/data/rosetteos/envs/moonraker/bin/python3 /usr/data/rosetteos/envs/klipper/bin/python3; do
		if command -v "$cand" >/dev/null 2>&1; then
			py_bin="$cand"
			break
		elif [ -x "$cand" ]; then
			py_bin="$cand"
			break
		fi
	done

	if [ -n "$py_bin" ]; then
		"$py_bin" - "$old_file" "$template_file" "$out_file" <<'PYEOF'
import sys
import re

old_path = sys.argv[1]
tpl_path = sys.argv[2]
out_path = sys.argv[3]

with open(old_path, 'r', encoding='utf-8', errors='replace') as f:
    old_content = f.read()

with open(tpl_path, 'r', encoding='utf-8', errors='replace') as f:
    template_content = f.read()

old_content = old_content.replace('\r\n', '\n')
template_content = template_content.replace('\r\n', '\n')

old_content = old_content.replace('/usr/data/nebulaos', '/usr/data/rosetteos')
old_content = old_content.replace('/usr/data/openke', '/usr/data/rosetteos')

def parse_sections(text):
    sections = []
    curr = {'header': None, 'name': None, 'lines': []}
    for line in text.splitlines(keepends=True):
        m = re.match(r'^\s*\[\s*([^]]+)\s*\]', line)
        if m:
            if curr['name'] is not None or curr['lines']:
                sections.append(curr)
            curr = {'header': line, 'name': m.group(1).strip(), 'lines': []}
        else:
            curr['lines'].append(line)
    if curr['name'] is not None or curr['lines']:
        sections.append(curr)
    return sections

old_secs = parse_sections(old_content)
tpl_secs = parse_sections(template_content)

old_sec_names = {}
for s in old_secs:
    if s['name']:
        old_sec_names[s['name'].strip().lower()] = s

for idx, t_sec in enumerate(tpl_secs):
    if not t_sec['name']:
        continue
    t_name = t_sec['name'].strip().lower()
    if t_name not in old_sec_names:
        inserted = False
        for prev_idx in range(idx - 1, -1, -1):
            prev_name = tpl_secs[prev_idx]['name']
            if prev_name and prev_name.strip().lower() in old_sec_names:
                for o_idx, o_sec in enumerate(old_secs):
                    if o_sec['name'] and o_sec['name'].strip().lower() == prev_name.strip().lower():
                        new_sec = {
                            'header': t_sec['header'],
                            'name': t_sec['name'],
                            'lines': list(t_sec['lines'])
                        }
                        if o_sec['lines'] and not o_sec['lines'][-1].endswith('\n'):
                            o_sec['lines'][-1] += '\n'
                        if not o_sec['lines'] or o_sec['lines'][-1].strip() != '':
                            o_sec['lines'].append('\n')
                        old_secs.insert(o_idx + 1, new_sec)
                        old_sec_names[t_name] = new_sec
                        inserted = True
                        break
                if inserted:
                    break
        if not inserted:
            auth_idx = None
            for o_idx, o_sec in enumerate(old_secs):
                if o_sec['name'] and o_sec['name'].strip().lower() == 'authorization':
                    auth_idx = o_idx
                    break
            new_sec = {
                'header': t_sec['header'],
                'name': t_sec['name'],
                'lines': list(t_sec['lines'])
            }
            if auth_idx is not None:
                old_secs.insert(auth_idx, new_sec)
            else:
                old_secs.append(new_sec)
            old_sec_names[t_name] = new_sec

if 'server' in old_sec_names:
    sec = old_sec_names['server']
    sec_text = ''.join(sec['lines'])
    if not re.search(r'^\s*klippy_uds_address\s*:', sec_text, re.MULTILINE):
        sec['lines'].append('klippy_uds_address: /opt/printer_data/comms/klippy.sock\n')

if 'machine' in old_sec_names:
    sec = old_sec_names['machine']
    new_lines = []
    has_provider = False
    for l in sec['lines']:
        if re.match(r'^\s*provider\s*:', l):
            new_lines.append('provider: supervisord_cli\n')
            has_provider = True
        else:
            new_lines.append(l)
    if not has_provider:
        new_lines.append('provider: supervisord_cli\n')
    sec_text = ''.join(new_lines)
    if not re.search(r'^\s*validate_service\s*:', sec_text, re.MULTILINE):
        new_lines.append('validate_service: False\n')
    if not re.search(r'^\s*validate_config\s*:', sec_text, re.MULTILINE):
        new_lines.append('validate_config: False\n')
    sec['lines'] = new_lines

if 'file_manager' in old_sec_names:
    sec = old_sec_names['file_manager']
    sec_text = ''.join(sec['lines'])
    if not re.search(r'^\s*enable_object_processing\s*:', sec_text, re.MULTILINE):
        sec['lines'].append('enable_object_processing: True\n')

if 'update_manager' in old_sec_names:
    sec = old_sec_names['update_manager']
    sec_text = ''.join(sec['lines'])
    if not re.search(r'^\s*enable_auto_refresh\s*:', sec_text, re.MULTILINE):
        sec['lines'].append('enable_auto_refresh: False\n')
    if not re.search(r'^\s*enable_system_updates\s*:', sec_text, re.MULTILINE):
        sec['lines'].append('enable_system_updates: False\n')

if 'update_manager mainsail' in old_sec_names:
    sec = old_sec_names['update_manager mainsail']
    sec_text = ''.join(sec['lines'])
    if not re.search(r'^\s*path\s*:', sec_text, re.MULTILINE):
        sec['lines'].append('path: /usr/data/rosetteos/apps/mainsail\n')

if 'authorization' in old_sec_names:
    sec = old_sec_names['authorization']
    lines = sec['lines']
    new_lines = []
    i = 0
    while i < len(lines):
        line = lines[i]
        if re.match(r'^\s*trusted_clients\s*:', line):
            new_lines.append(line)
            i += 1
            clients = []
            while i < len(lines) and (lines[i].startswith(' ') or lines[i].startswith('\t') or lines[i].strip() == '' or lines[i].strip().startswith('#')):
                stripped = lines[i].strip()
                if stripped and not stripped.startswith('#'):
                    clients.append(stripped)
                new_lines.append(lines[i])
                i += 1
            for rc in ['127.0.0.1', '192.168.0.0/16', '10.0.0.0/8']:
                if rc not in clients:
                    new_lines.append(f' {rc}\n')
            continue
        elif re.match(r'^\s*cors_domains\s*:', line):
            new_lines.append(line)
            i += 1
            domains = []
            while i < len(lines) and (lines[i].startswith(' ') or lines[i].startswith('\t') or lines[i].strip() == '' or lines[i].strip().startswith('#')):
                stripped = lines[i].strip()
                if stripped and not stripped.startswith('#'):
                    domains.append(stripped)
                new_lines.append(lines[i])
                i += 1
            for rd in ['http://*.local', 'http://*.lan']:
                if rd not in domains:
                    new_lines.append(f' {rd}\n')
            continue
        else:
            new_lines.append(line)
            i += 1
    sec['lines'] = new_lines

output = []
for s in old_secs:
    if s['header']:
        output.append(s['header'])
    output.extend(s['lines'])

res = ''.join(output)
res = re.sub(r'\n{3,}', '\n\n', res)

with open(out_path, 'w', encoding='utf-8') as f:
    f.write(res)
PYEOF
		rc=$?
		if [ $rc -ne 0 ]; then
			echo "rosetteos-config-migrate: ERROR running python moonraker migration" >&2
			return $rc
		fi
	else
		sed -e 's|/usr/data/nebulaos|/usr/data/rosetteos|g' \
		    -e 's|/usr/data/openke|/usr/data/rosetteos|g' "$old_file" > "$out_file"
		if ! grep -q "^\s*\[zeroconf\]" "$out_file"; then
			if grep -q "^\s*\[server\]" "$out_file"; then
				awk '/^\[server\]/{print; print "\n[zeroconf]"; next}1' "$out_file" > "$out_file.tmp" && mv "$out_file.tmp" "$out_file"
			else
				printf "\n[zeroconf]\n" >> "$out_file"
			fi
		fi
	fi

	return 0
}

# Full tree migration: Migrates the active config tree from immutable seeds
# $1=ROSETTEOS_ROOT $2=SEEDS_DIR $3=BACKUP_DIR
rosetteos_migrate_config_tree() {
	rosetteos_root="${1:-/usr/data/rosetteos}"
	seeds_dir="${2:-/opt/rosetteos-seeds}"
	config_dir="$rosetteos_root/printer_data/config"
	seed_config_dir="$seeds_dir/printer_data-config"
	backup_dir="${3:-$rosetteos_root/backups/printer_config/pre-migration-$(date -u +%Y%m%dT%H%M%SZ)}"

	if [ ! -d "$config_dir" ]; then
		# Nothing to migrate
		return 0
	fi

	mkdir -p "$backup_dir"
	echo "rosetteos-config-migrate: backing up current config to $backup_dir"
	cp -a "$config_dir/." "$backup_dir/"

	# 1. Update/seed managed system macro files (macros/*.cfg)
	if [ -d "$seed_config_dir/macros" ]; then
		mkdir -p "$config_dir/macros"
		for m in "$seed_config_dir/macros"/*.cfg; do
			[ -f "$m" ] || continue
			mname=$(basename "$m")
			cp -a "$m" "$config_dir/macros/$mname"
		done
	fi

	# 2. Update/seed managed hardware files (hardware/*.cfg)
	if [ -d "$seed_config_dir/hardware" ]; then
		mkdir -p "$config_dir/hardware"
		for h in "$seed_config_dir/hardware"/*.cfg; do
			[ -f "$h" ] || continue
			hname=$(basename "$h")
			cp -a "$h" "$config_dir/hardware/$hname"
		done
	fi

	# 3. Update GuppyScreen helper scripts & cmds
	if [ -d "$seed_config_dir/GuppyScreen" ]; then
		mkdir -p "$config_dir/GuppyScreen/scripts"
		cp -a "$seed_config_dir/GuppyScreen/." "$config_dir/GuppyScreen/"
	fi

	# 4. Seed user.cfg ONLY if it does not exist (never overwrite existing user.cfg)
	if [ ! -f "$config_dir/user.cfg" ] && [ -f "$seed_config_dir/user.cfg" ]; then
		cp -a "$seed_config_dir/user.cfg" "$config_dir/user.cfg"
	fi

	# 5. Determine base template for active printer profile
	active_profile="creality-ender3-v3-ke"
	if [ -f "$rosetteos_root/system/active-profile.json" ]; then
		cand=$(grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' "$rosetteos_root/system/active-profile.json" | head -1 | cut -d'"' -f4)
		[ -n "$cand" ] && active_profile="$cand"
	fi

	template_cfg="$seed_config_dir/printer.cfg"
	if [ -f "$seeds_dir/printer_profiles/$active_profile/printer.cfg" ]; then
		template_cfg="$seeds_dir/printer_profiles/$active_profile/printer.cfg"
	fi

	# 5. Migrate printer.cfg with SAVE_CONFIG block transplantation
	if [ -f "$config_dir/printer.cfg" ] && [ -f "$template_cfg" ]; then
		temp_migrated="$config_dir/printer.cfg.migrated.$$"
		if rosetteos_migrate_printer_cfg "$config_dir/printer.cfg" "$template_cfg" "$temp_migrated"; then
			mv "$temp_migrated" "$config_dir/printer.cfg"
			echo "rosetteos-config-migrate: successfully migrated printer.cfg (active profile: $active_profile)"
		else
			rm -f "$temp_migrated"
			echo "rosetteos-config-migrate: ERROR migrating printer.cfg - preserving existing file" >&2
			return 1
		fi
	fi

	# 6. Migrate moonraker.conf
	template_moonraker="$seed_config_dir/moonraker.conf"
	if [ -f "$template_moonraker" ]; then
		temp_migrated_mr="$config_dir/moonraker.conf.migrated.$$"
		if rosetteos_migrate_moonraker_conf "$config_dir/moonraker.conf" "$template_moonraker" "$temp_migrated_mr"; then
			mv "$temp_migrated_mr" "$config_dir/moonraker.conf"
			echo "rosetteos-config-migrate: successfully migrated moonraker.conf"
		else
			rm -f "$temp_migrated_mr"
			echo "rosetteos-config-migrate: ERROR migrating moonraker.conf - preserving existing file" >&2
			return 1
		fi
	fi

	# 7. Ensure printer_profiles symlink exists
	[ -e "$config_dir/printer_profiles" ] || ln -sfn "$rosetteos_root/printer_profiles" "$config_dir/printer_profiles"

	return 0
}
