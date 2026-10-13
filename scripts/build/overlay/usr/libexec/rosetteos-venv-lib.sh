#!/bin/sh
# rosetteos-venv-lib.sh - shared persistent-venv compatibility helpers.
#
# Sourced by /etc/init.d/S04rosetteos-factory-seed (which owns creating and
# replacing these environments) and by /etc/init.d/S05rosetteos-activate (which
# only decides whether to bind-mount one).
#
# Defines: venv_is_usable, recover_torn_venv, swap_venv_into_place,
# venv_validated_usable, venv_validation_key, venv_validation_reset.
#
# Callers may define log(); if they do not, a no-op stand-in is used so this
# file is safe to source from anywhere.
command -v log >/dev/null 2>&1 || log() { echo "rosetteos-venv: $1"; }

# Buildroot Python migration & persistent venv validation helpers.
venv_is_usable() {
	_viu_dir="$1"; _viu_smoke="${2:-}"

	[ -d "$_viu_dir" ] || return 1
	[ -x "$_viu_dir/bin/python3" ] || return 1

	# Run interpreter check
	"$_viu_dir/bin/python3" -c 'import sys' >/dev/null 2>&1 || {
		log "venv $_viu_dir has a bin/python3 that does not execute - reprovisioning"
		return 1
	}

	[ -f "$_viu_dir/pyvenv.cfg" ] || {
		log "venv $_viu_dir has no pyvenv.cfg - reprovisioning"
		return 1
	}

	if [ -n "$_viu_smoke" ]; then
		"$_viu_dir/bin/python3" -c "$_viu_smoke" >/dev/null 2>&1 || {
			log "venv $_viu_dir failed its import smoke test - reprovisioning"
			return 1
		}
	fi
	return 0
}

# Recover a torn replacement from a previous boot.
recover_torn_venv() {
	_rtv_dir="$1"; _rtv_smoke="${2:-}"
	[ -d "$_rtv_dir.old" ] || return 0
	if venv_is_usable "$_rtv_dir" "$_rtv_smoke"; then
		# The swap completed; .old is just leftover garbage.
		rm -rf "$_rtv_dir.old" 2>/dev/null || true
		return 0
	fi
	if venv_is_usable "$_rtv_dir.old" "$_rtv_smoke"; then
		log "recovering $_rtv_dir from $_rtv_dir.old (previous replacement was interrupted)"
		rm -rf "$_rtv_dir" 2>/dev/null || true
		if mv "$_rtv_dir.old" "$_rtv_dir"; then
			log "recovered $_rtv_dir successfully"
		else
			log "ERROR: could not restore $_rtv_dir from $_rtv_dir.old - leaving .old in place for manual recovery"
		fi
	else
		log "$_rtv_dir.old exists but is not usable by this image either - discarding it and reseeding"
		rm -rf "$_rtv_dir.old" 2>/dev/null || true
	fi
}

# Swap a verified staging directory into place without destroying the existing one first.
swap_venv_into_place() {
	_svp_dir="$1"
	# BOOT-03: a replaced environment is never vouched for by an old stamp.
	rm -f "$VENV_VALIDATION_DIR/${_svp_dir##*/}.key" 2>/dev/null || true
	rm -rf "$_svp_dir.old" 2>/dev/null || true
	if [ -e "$_svp_dir" ]; then
		if ! mv "$_svp_dir" "$_svp_dir.old"; then
			log "ERROR: could not move $_svp_dir aside - refusing to replace it, leaving the existing environment untouched"
			rm -rf "$_svp_dir.partial" 2>/dev/null || true
			return 1
		fi
	fi
	if ! mv "$_svp_dir.partial" "$_svp_dir"; then
		log "ERROR: could not move $_svp_dir.partial into place - restoring the previous environment"
		[ -d "$_svp_dir.old" ] && mv "$_svp_dir.old" "$_svp_dir"
		return 1
	fi
	rm -rf "$_svp_dir.old" 2>/dev/null || true
	return 0
}

# BOOT-03/BOOT-04: validation stamp caching to skip redundant python checks.
ROSETTEOS_ROOT="${ROSETTEOS_ROOT:-${NEBULAOS_ROOT:-/usr/data/rosetteos}}"
VENV_VALIDATION_DIR="${VENV_VALIDATION_DIR:-${SYSTEM:-$ROSETTEOS_ROOT/system}/venv-validation}"
VENV_REVALIDATE_MARKER="${VENV_REVALIDATE_MARKER:-$ROSETTEOS_ROOT/maintenance/revalidate-venvs}"
VENV_SYSTEM_PYTHON="${VENV_SYSTEM_PYTHON:-/usr/bin/python3}"
VENV_IMAGE_MANIFEST="${VENV_IMAGE_MANIFEST:-${SEEDS:-/opt/rosetteos-seeds}/seed-manifest.json}"
VENV_APPS_DIR="${VENV_APPS_DIR:-${APPS:-$ROSETTEOS_ROOT/apps}}"

_venv_git_head() {
	_vgh_g="$1/.git"
	[ -f "$_vgh_g/HEAD" ] || return 0
	read -r _vgh_h < "$_vgh_g/HEAD" 2>/dev/null || return 0
	case "$_vgh_h" in
		"ref: "*)
			_vgh_r=${_vgh_h#ref: }
			if [ -f "$_vgh_g/$_vgh_r" ]; then
				cat "$_vgh_g/$_vgh_r" 2>/dev/null
			else
				grep " $_vgh_r\$" "$_vgh_g/packed-refs" 2>/dev/null | cut -d' ' -f1
			fi
			;;
		*) echo "$_vgh_h" ;;
	esac
}

# Identity key computation using cat/ls/cksum (no interpreter start)
venv_validation_key() {
	_vvk_d="$1"
	echo "v1"
	echo "smoke=$2"
	echo "image=$(cksum < "$VENV_IMAGE_MANIFEST" 2>/dev/null)"
	echo "python=$(ls -lnL "$VENV_SYSTEM_PYTHON" 2>/dev/null)"
	echo "env=$_vvk_d"
	echo "bin=$(ls -ln "$_vvk_d/bin/python3" 2>/dev/null)"
	echo "cfg=$(cksum < "$_vvk_d/pyvenv.cfg" 2>/dev/null)"
	for _vvk_sp in "$_vvk_d"/lib/python*/site-packages; do
		[ -d "$_vvk_sp" ] || continue
		echo "sp=$_vvk_sp $(ls -lna "$_vvk_sp" 2>/dev/null | cksum)"
	done
	[ -e "$_vvk_d.old" ] && echo "old=present"
	for _vvk_a in "$VENV_APPS_DIR"/*; do
		[ -d "$_vvk_a/.git" ] || continue
		echo "app=${_vvk_a##*/} $(_venv_git_head "$_vvk_a")"
	done
}

_venv_stamp_path() {
	echo "$VENV_VALIDATION_DIR/${1##*/}.key"
}

venv_validation_reset() {
	rm -rf "$VENV_VALIDATION_DIR" 2>/dev/null || true
}

venv_validated_usable() {
	_vvu_d="$1"; _vvu_s="${2:-}"
	VENV_VALIDATION_SOURCE=
	[ -d "$_vvu_d" ] || return 1
	_vvu_stamp=$(_venv_stamp_path "$_vvu_d")
	_vvu_key=$(venv_validation_key "$_vvu_d" "$_vvu_s")
	if [ ! -e "$VENV_REVALIDATE_MARKER" ] && [ -f "$_vvu_stamp" ] \
		&& [ "$(cat "$_vvu_stamp" 2>/dev/null)" = "$_vvu_key" ]; then
		VENV_VALIDATION_SOURCE=stamp
		log "venv $_vvu_d unchanged since its last full validation - import check skipped"
		return 0
	fi
	if venv_is_usable "$_vvu_d" "$_vvu_s"; then
		VENV_VALIDATION_SOURCE=full
		if mkdir -p "$VENV_VALIDATION_DIR" 2>/dev/null \
			&& printf '%s\n' "$_vvu_key" > "$_vvu_stamp.tmp" 2>/dev/null \
			&& mv -f "$_vvu_stamp.tmp" "$_vvu_stamp" 2>/dev/null; then
			:
		else
			rm -f "$_vvu_stamp.tmp" 2>/dev/null
		fi
		return 0
	fi
	rm -f "$_vvu_stamp" "$_vvu_stamp.tmp" 2>/dev/null
	return 1
}
