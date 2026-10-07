#!/bin/sh
#
# RosetteOS addition (USB/webcam stock-parity mission, 2026-07-26): mount/
# unmount a USB mass-storage device under Moonraker's own gcodes root, so
# its files show up in GuppyScreen (and Mainsail/Fluidd) through the exact
# same file-listing path any other gcode already uses - see
# /etc/udev/rules.d/91-usb-gcode-media.rules for why this is the real
# integration point for this UI (GuppyScreen has no USB-media concept of
# its own; it only ever lists whatever Moonraker's /server/files/gcodes/
# API reports).
#
# Invoked by udev on add/remove of a real USB block device (sd[a-z] or
# sd[a-z][0-9] - never the internal eMMC, which is mmcblk0 and matched by
# neither pattern). $1 is the kernel device name (e.g. "sda" or "sda1");
# ACTION is exported by udev itself.

set -u

DEV="$1"
DESTBASE=/opt/printer_data/gcodes/USB
MOUNTPOINT="$DESTBASE/$DEV"

log() {
	echo "usb-gcode-media: $*" >&2
}

already_mounted() {
	grep -q "^/dev/$DEV " /proc/mounts
}

do_mount() {
	# A partitioned drive fires an add event for the whole-disk node AND
	# each partition node - mounting the raw whole-disk node in that case
	# would just expose the partition table, not a real filesystem, and
	# race with the real partition's own add event. Skip it; the
	# partition node(s) will mount themselves.
	if [ -d "/sys/block/$DEV" ]; then
		for part in "/sys/block/$DEV/$DEV"[0-9]*; do
			[ -d "$part" ] || continue
			log "$DEV has partitions, not mounting the whole-disk node"
			return 0
		done
	fi

	if already_mounted; then
		log "$DEV already mounted, skipping"
		return 0
	fi

	mkdir -p "$MOUNTPOINT" || { log "could not create $MOUNTPOINT"; return 1; }

	# Prefer read-write (matches stock's own real auto_mount_udisk.sh,
	# which mounts "-o sync" - not read-only - since its whole point is a
	# browsable, usable removable drive, not just a read-only import
	# source). Fall back to read-only if the filesystem/media itself
	# refuses write access (e.g. a write-protected card, or a filesystem
	# whose kernel driver here is read-only-only) rather than failing
	# outright.
	if mount -t auto -o rw,sync,noatime,nosuid,nodev,noexec "/dev/$DEV" "$MOUNTPOINT" 2>/dev/null; then
		log "$DEV mounted read-write at $MOUNTPOINT"
		return 0
	fi
	if mount -t auto -o ro,noatime,nosuid,nodev,noexec "/dev/$DEV" "$MOUNTPOINT" 2>/dev/null; then
		log "$DEV mounted read-only at $MOUNTPOINT (read-write failed)"
		return 0
	fi

	log "failed to mount $DEV (unrecognized or unsupported filesystem)"
	rmdir "$MOUNTPOINT" 2>/dev/null
	return 1
}

do_unmount() {
	already_mounted || { log "$DEV not mounted, nothing to do"; rmdir "$MOUNTPOINT" 2>/dev/null; return 0; }

	# The device node is already gone by the time a "remove" event fires
	# (this runs after the kernel has torn it down), so a normal umount
	# can hang waiting on a device that will never respond - lazy-unmount
	# so GuppyScreen/Moonraker's view of the directory clears immediately
	# even if some underlying cleanup is still pending.
	umount -l "$MOUNTPOINT" 2>/dev/null
	rmdir "$MOUNTPOINT" 2>/dev/null
	log "$DEV unmounted from $MOUNTPOINT"
}

case "${ACTION:-}" in
	add)
		do_mount
		;;
	remove)
		do_unmount
		;;
	*)
		log "unhandled ACTION='${ACTION:-}' for $DEV"
		;;
esac
