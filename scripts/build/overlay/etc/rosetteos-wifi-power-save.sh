#!/bin/sh
# NebulaOS Wi-Fi power-save qualification mode (pre-qualification mission
# Phase A5, 2026-07-31 - see docs/NEBULAOS_CAMERA_USB_RT_SOURCE_ANALYSIS.md
# sec 18.8/18.17 for the source-grounded rationale).
#
# NebulaOS's Wi-Fi chip (Cypress CYW43438, mainline brcmfmac) runs its
# default firmware PM_FAST 802.11 power-save mode unmodified today (no
# explicit override anywhere in this project) - brcmfmac has no dedicated
# module parameter for this, the only real control surface is the
# standard nl80211/iw `set power_save` path. This is NOT yet a production
# decision either way (see the mission's own fixed-decisions list) - this
# is a controlled qualification mode for later hardware A/B testing
# (Phase B4), never applied unless an explicit experimental marker is
# present.
#
# Variants:
#   P0 (default/absent marker) - current firmware default (PM_FAST), no
#       override applied at all. This is what every build ships until a
#       real hardware A/B test selects otherwise.
#   P1 - `iw dev wlan0 set power_save off` applied at boot.
#
# Marker file lives under the persistent partition's maintenance area,
# never in normal user-facing configuration - this is an experimental
# qualification control, not a shipped feature, until Phase B7 freezes a
# decision.

ROSETTEOS_WIFI_PS_MARKER="${ROSETTEOS_WIFI_PS_MARKER:-/usr/data/rosetteos/maintenance/wifi-power-save-mode}"

# Prints the currently-requested mode (P0 or P1) - P0 if the marker is
# absent or contains anything else unrecognized (fail safe to the
# production default, never fail open into an unintended experimental
# state).
rosetteos_wifi_ps_requested_mode() {
	marker="${1:-$ROSETTEOS_WIFI_PS_MARKER}"
	if [ -f "$marker" ]; then
		mode=$(cat "$marker" 2>/dev/null)
		case "$mode" in
			P1) printf 'P1'; return 0 ;;
		esac
	fi
	printf 'P0'
}

# Prints the real, currently-effective power-save state for an interface,
# as reported by the kernel itself (not just the requested marker) - "on",
# "off", or "unknown" if the interface doesn't exist or iw can't be run.
rosetteos_wifi_ps_effective_state() {
	iface="${1:-wlan0}"
	out=$(iw dev "$iface" get power_save 2>/dev/null) || {
		printf 'unknown'
		return 1
	}
	case "$out" in
		*"Power save: on"*) printf 'on' ;;
		*"Power save: off"*) printf 'off' ;;
		*) printf 'unknown'; return 1 ;;
	esac
}

# Applies the requested mode to the given interface. Idempotent (safe to
# call every boot, and safe to call more than once per boot) - never
# blocks: `iw` either returns promptly or this function's own caller is
# expected to not depend on its exit code for anything boot-critical.
# Logs success/failure either way, never blocks boot on either outcome.
rosetteos_wifi_ps_apply() {
	iface="${1:-wlan0}"
	requested=$(rosetteos_wifi_ps_requested_mode)
	case "$requested" in
		P1)
			if iw dev "$iface" set power_save off 2>/dev/null; then
				echo "rosetteos-wifi-power-save: P1 applied - power_save off on $iface"
				return 0
			fi
			echo "rosetteos-wifi-power-save: P1 requested but 'iw dev $iface set power_save off' failed - leaving firmware default in effect" >&2
			return 1
			;;
		*)
			echo "rosetteos-wifi-power-save: P0 (default) - no override applied on $iface"
			return 0
			;;
	esac
}

