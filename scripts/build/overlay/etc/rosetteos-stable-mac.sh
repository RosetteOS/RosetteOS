#!/bin/sh
# NebulaOS stable per-device Wi-Fi MAC address derivation (pre-qualification
# mission Phase A3, 2026-07-31 - see docs/NEBULAOS_CAMERA_USB_RT_SOURCE_
# ANALYSIS.md sec 18.11 for the root cause this fixes).
#
# Real bug this exists to fix: the shipped brcmfmac43430-sdio.txt NVRAM
# carries generic, byte-identical-to-stock placeholder MAC-address fields
# (macaddr and il0macaddr, see that file's own lines 12/49). Mainline
# brcmfmac has its own hardcoded detection for exactly that known-bad
# template value (brcmf_default_mac_address in common.c) and, when it
# fires, generates a genuinely random MAC on every single boot - a
# real, source-proven explanation for this project's own documented
# DHCP/IP-address drift across reboots.
#
# Why not fix this at the kernel/devicetree level instead: mainline
# brcmfmac does support a standard nvmem-cells/local-mac-address DT
# override (eth_platform_get_mac_address(), firmware.c) that would be
# resolved before this problem ever occurs - but this board's only
# candidate hardware source for a per-chip value, the X2000 SoC's
# `efuse@13540000` node, has no driver bound to its actual compatible
# string ("ingenic,x2000-efuse" - the only in-tree efuse driver,
# jz4780-efuse.c, matches "ingenic,jz4780-efuse" only) and defines no
# nvmem-cells at all. Wiring that up would require assuming both a
# driver-compatibility match and a specific unique-ID byte offset within
# the efuse's memory map, neither of which is confirmed anywhere in this
# repo or verifiable without live hardware - exactly the kind of
# speculative pin/hardware assumption this project's own established
# safety discipline (see docs/PIN_OWNERSHIP_MAP.md's BT GPIO example)
# says not to wire up blind. A devicetree/bootloader fixup was rejected
# for the same reason: unverifiable without hardware in Mode A.
#
# What this uses instead: the eMMC's own CID (Card IDentification)
# register - a real, JEDEC-standard, factory-programmed 128-bit register
# already exposed by mainline's generic MMC core with zero kernel/DT
# changes needed (MMC_DEV_ATTR(cid, ...), drivers/mmc/core/mmc.c). It's a
# property of the physical eMMC chip itself, not the OS/rootfs, so it is
# identical across A/B rootfs/kernel slot switches, application updates,
# and rollback - exactly the stability this needs - and is available as
# soon as /sys is mounted, long before this script ever runs (you can't
# boot userspace at all without the eMMC already having been probed,
# since it IS the root storage).
#
# Why override wlan0's MAC in userspace instead of "before brcmfmac
# probes": brcmfmac is compiled in and probes during kernel boot, before
# any userspace script can run at all - genuinely impossible to beat from
# userspace. What actually matters for network identity is the MAC in
# effect when the interface is brought up and starts sending real
# traffic (DHCP discover, association), not whatever the kernel briefly
# held immediately after probe - so this overrides it via the completely
# standard `ip link set address` mechanism while the interface is down,
# before wpa_supplicant/DHCP ever run. No kernel, devicetree, or
# bootloader change needed.
#
# Sourced by S01wifi. Also sourced directly by
# tests/rosetteos-stable-mac-tests.sh so there is exactly one copy of this
# logic, never a second one to drift out of sync.

ROSETTEOS_MAC_SEED_FILE="${ROSETTEOS_MAC_SEED_FILE:-/usr/data/rosetteos/wifi-mac-seed}"
ROSETTEOS_MAC_DOMAIN="rosetteos-wifi-mac-v1"

# Reads the eMMC's real, factory-programmed CID register if the kernel
# exposes it and it looks genuinely programmed (32 hex chars, not all
# zero). Prints nothing and returns non-zero if unavailable/implausible -
# callers must fall back, never trust a suspicious value.
rosetteos_read_hardware_identifier() {
	cid_path=""
	for candidate in /sys/class/mmc_host/mmc0/mmc0:*/cid /sys/block/mmcblk0/device/cid; do
		if [ -f "$candidate" ]; then
			cid_path="$candidate"
			break
		fi
	done
	[ -n "$cid_path" ] || return 1
	cid=$(cat "$cid_path" 2>/dev/null)
	case "$cid" in
		''|*[!0-9a-fA-F]*) return 1 ;;
	esac
	[ ${#cid} -ge 32 ] || return 1
	case "$cid" in
		00000000000000000000000000000000*) return 1 ;;
	esac
	printf '%s' "$cid"
}

# Fallback identifier when no usable hardware identifier exists: a real
# random value generated once and persisted, so every subsequent boot
# reuses the same fallback rather than a fresh one each time (a fresh
# value every boot would just reproduce the exact bug this is fixing).
# Never a single hardcoded fallback shared across every install.
rosetteos_read_or_create_fallback_identifier() {
	seed_file="$1"
	if [ -f "$seed_file" ]; then
		fallback=$(cat "$seed_file" 2>/dev/null)
		case "$fallback" in
			''|*[!0-9a-fA-F]*) : ;;
			*)
				printf '%s' "$fallback"
				return 0
				;;
		esac
	fi
	fallback=$(head -c 32 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n')
	[ -n "$fallback" ] || return 1
	mkdir -p "$(dirname "$seed_file")" 2>/dev/null
	printf '%s' "$fallback" > "$seed_file" 2>/dev/null || return 1
	printf '%s' "$fallback"
}

# Core derivation: identifier string -> a properly-constrained MAC.
# Domain-separated SHA-256, not a raw truncation - so this can never
# collide with some unrelated use of the same physical identifier, and
# the output has no structurally-guessable relationship to the input.
# Locally-administered bit set, multicast bit cleared, on the first byte.
rosetteos_derive_mac_from_identifier() {
	identifier="$1"
	[ -n "$identifier" ] || return 1
	hash12=$(printf '%s:%s' "$ROSETTEOS_MAC_DOMAIN" "$identifier" | sha256sum | cut -c1-12)
	[ ${#hash12} -eq 12 ] || return 1
	first_hex=$(printf '%s' "$hash12" | cut -c1-2)
	rest_hex=$(printf '%s' "$hash12" | cut -c3-12)
	first_dec=$(( 0x$first_hex ))
	first_dec=$(( (first_dec | 2) & 254 ))
	first_fixed=$(printf '%02x' "$first_dec")
	rest_colon=$(printf '%s' "$rest_hex" | sed 's/\(..\)/\1:/g')
	rest_colon=${rest_colon%:}
	printf '%s:%s' "$first_fixed" "$rest_colon"
}

# Full orchestration: derive and apply a stable MAC to the given
# interface (default wlan0). Safe to call even if it fails - always
# leaves the interface administratively up on exit, and never touches
# the interface at all if no identifier can be produced at all.
rosetteos_stabilize_iface_mac() {
	iface="${1:-wlan0}"
	identifier=$(rosetteos_read_hardware_identifier)
	if [ -z "$identifier" ]; then
		identifier=$(rosetteos_read_or_create_fallback_identifier "$ROSETTEOS_MAC_SEED_FILE")
	fi
	if [ -z "$identifier" ]; then
		echo "rosetteos-stable-mac: no hardware or fallback identifier available - leaving $iface's kernel-assigned MAC as-is" >&2
		return 1
	fi
	mac=$(rosetteos_derive_mac_from_identifier "$identifier")
	if [ -z "$mac" ]; then
		echo "rosetteos-stable-mac: derivation failed - leaving $iface's kernel-assigned MAC as-is" >&2
		return 1
	fi
	ip link set dev "$iface" down 2>/dev/null
	if ip link set dev "$iface" address "$mac" 2>/dev/null; then
		ip link set dev "$iface" up 2>/dev/null
		echo "rosetteos-stable-mac: $iface MAC stabilized to $mac"
		return 0
	fi
	echo "rosetteos-stable-mac: failed to apply $mac to $iface - leaving kernel-assigned MAC as-is" >&2
	ip link set dev "$iface" up 2>/dev/null
	return 1
}

