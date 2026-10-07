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

# Full tree migration: Migrates the active config tree from immutable seeds
# $1=ROSETTEOS_ROOT $2=SEEDS_DIR $3=BACKUP_DIR
rosetteos_migrate_config_tree() {
	rosetteos_root="${1:-/usr/data/rosetteos}"
	seeds_dir="${2:-/opt/rosetteos-seeds}"
	config_dir="$rosetteos_root/printer_data/config"
	seed_config_dir="$seeds_dir/printer_data-config"
	backup_dir="${3:-$rosetteos_root/backups/printer_config/pre-migration-$(date -u +%Y%m%dT%H%M%SZ)}"

	if [ ! -d "$config_dir" ] || [ ! -f "$config_dir/printer.cfg" ]; then
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
	temp_migrated="$config_dir/printer.cfg.migrated.$$"
	if rosetteos_migrate_printer_cfg "$config_dir/printer.cfg" "$template_cfg" "$temp_migrated"; then
		mv "$temp_migrated" "$config_dir/printer.cfg"
		echo "rosetteos-config-migrate: successfully migrated printer.cfg (active profile: $active_profile)"
	else
		rm -f "$temp_migrated"
		echo "rosetteos-config-migrate: ERROR migrating printer.cfg - preserving existing file" >&2
		return 1
	fi

	# 6. Ensure printer_profiles symlink exists
	[ -e "$config_dir/printer_profiles" ] || ln -sfn "$rosetteos_root/printer_profiles" "$config_dir/printer_profiles"

	return 0
}
