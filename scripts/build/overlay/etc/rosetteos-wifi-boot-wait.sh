#!/bin/sh
# NebulaOS Wi-Fi boot-association-wait qualification mode (pre-
# qualification mission Phase A6, 2026-07-31 - see docs/NEBULAOS_CAMERA_
# USB_RT_SOURCE_ANALYSIS.md sec 18.11/18.17 for the source-grounded
# rationale).
#
# S01wifi's current, real, already-hardware-proven behavior is a fixed
# `sleep 2` between launching wpa_supplicant and bringing the interface
# up for DHCP. The source analysis found this plausible-but-unverified -
# not proven load-bearing, not proven arbitrary either - so this is an
# EXPERIMENTAL alternative for later A/B testing, not a replacement:
# every build still defaults to the exact original fixed-sleep behavior
# unless an explicit marker opts into the event-driven path.
#
# Variants:
#   fixed (default/marker absent) - today's real, hardware-proven
#       `sleep 2` behavior, byte-for-byte unchanged.
#   event-driven - polls wpa_cli's own status for wpa_state=COMPLETED,
#       up to a bounded timeout, so a fast association doesn't wait the
#       full fixed delay and a slow one doesn't get cut short at 2s.
#
# Never depends on internet reachability (only queries wpa_supplicant's
# own local control socket via wpa_cli). Never starts a second
# wpa_supplicant or udhcpc - this only affects how long S01wifi waits
# before its own existing single `ifup wlan0` call, which itself remains
# completely unchanged either way.

ROSETTEOS_WIFI_BOOT_WAIT_MARKER="${ROSETTEOS_WIFI_BOOT_WAIT_MARKER:-/usr/data/rosetteos/maintenance/wifi-boot-wait-mode}"
ROSETTEOS_WIFI_BOOT_WAIT_TIMEOUT="${ROSETTEOS_WIFI_BOOT_WAIT_TIMEOUT:-10}"
ROSETTEOS_WIFI_BOOT_WAIT_MIN="${ROSETTEOS_WIFI_BOOT_WAIT_MIN:-1}"

# Prints the requested mode ("fixed" or "event-driven") - fails safe to
# "fixed" (today's real, proven behavior) if the marker is absent or
# contains anything unrecognized.
rosetteos_wifi_boot_wait_requested_mode() {
	marker="${1:-$ROSETTEOS_WIFI_BOOT_WAIT_MARKER}"
	if [ -f "$marker" ]; then
		mode=$(cat "$marker" 2>/dev/null)
		case "$mode" in
			event-driven) printf 'event-driven'; return 0 ;;
		esac
	fi
	printf 'fixed'
}

# Polls `wpa_cli -i <iface> status` for wpa_state=COMPLETED, once per
# second, for up to ROSETTEOS_WIFI_BOOT_WAIT_TIMEOUT seconds total,
# always waiting at least ROSETTEOS_WIFI_BOOT_WAIT_MIN seconds first
# (mirrors the fixed path's own minimum settle time before DHCP is even
# attempted). Returns 0 as soon as association completes, 1 if the
# timeout is reached without ever seeing COMPLETED - either way the
# caller proceeds to `ifup` immediately afterward, exactly like the
# fixed path already does today.
rosetteos_wifi_wait_for_association_event_driven() {
	iface="${1:-wlan0}"
	elapsed=0
	while [ "$elapsed" -lt "$ROSETTEOS_WIFI_BOOT_WAIT_MIN" ]; do
		sleep 1
		elapsed=$((elapsed + 1))
	done
	while [ "$elapsed" -lt "$ROSETTEOS_WIFI_BOOT_WAIT_TIMEOUT" ]; do
		status=$(wpa_cli -i "$iface" status 2>/dev/null)
		case "$status" in
			*wpa_state=COMPLETED*)
				echo "rosetteos-wifi-boot-wait: association completed after ${elapsed}s"
				return 0
				;;
		esac
		sleep 1
		elapsed=$((elapsed + 1))
	done
	echo "rosetteos-wifi-boot-wait: association not confirmed within ${ROSETTEOS_WIFI_BOOT_WAIT_TIMEOUT}s, proceeding to ifup anyway" >&2
	return 1
}

# Orchestration: waits using whichever mode is currently requested.
# Callers should always proceed to their own next step (ifup) regardless
# of this function's return value, exactly matching the fixed path's own
# unconditional behavior today.
rosetteos_wifi_boot_wait() {
	iface="${1:-wlan0}"
	requested=$(rosetteos_wifi_boot_wait_requested_mode)
	case "$requested" in
		event-driven)
			rosetteos_wifi_wait_for_association_event_driven "$iface"
			;;
		*)
			sleep 2
			;;
	esac
}

