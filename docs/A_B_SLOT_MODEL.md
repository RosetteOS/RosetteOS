# How the A/B boot slots work

This is the raw partition layout and boot-selection mechanism the KE actually uses. It assumes
you're comfortable with SSH, root, and thinking about block devices — this isn't a consumer install
guide, it's the reference for anyone actually working on this stuff.

## The layout

```
Slot 1 (stock)              Slot 2 (custom / RosetteOS)
  mmcblk0p5  kernel            mmcblk0p6  kernel2
  mmcblk0p7  rootfs             mmcblk0p8  rootfs2
  (8 MiB / 500 MB)              (8 MiB / 500 MB - real, fixed capacities)

              mmcblk0p1  ota marker (1 MB)
                 shared, not per-slot

              mmcblk0p9  rootfs_data (300 MB, ext4, /overlay)
              mmcblk0p10 userdata    (~6 GB, ext4, /usr/data)
                 shared, not duplicated per slot - see below
```

These are two fixed physical slots, not a rotating pair. Slot 1 is Creality's stock kernel and
rootfs. Slot 2 is RosetteOS's slot (and SWUpdate supports streaming to both slot 1 and slot 2 when running in pure custom mode).

The important part: **we never overwrite the slot we're currently booted from.** That's not just a
convention, it's enforced in code (more on that below).

### `/overlay` and `/usr/data` are shared, not duplicated

`mmcblk0p9` (`/overlay`) and `mmcblk0p10` (`/usr/data`) are the same physical partitions no matter
which slot is active — they don't get a separate copy per OS. Stock and RosetteOS use their own
subdirectories underneath, so switching slots doesn't expose one OS's files to the other, and
doesn't wipe either one out. `docs/DEVELOPER_RECOVERY.md` has the full breakdown of what actually
lives where and what survives a switch.

## What a normal flash actually touches

`scripts/flash-spare-slot.sh` writes exactly two devices: `/dev/mmcblk0p6` (kernel2) and
`/dev/mmcblk0p8` (rootfs2). It only ever targets slot 2, and it will flatly refuse to run if the
slot it's about to write turns out to be the one you're currently booted from. That check happens
in the script itself, not just in a warning somewhere — see `run_preflight()` if you want to read
it.

It never touches:

- `mmcblk0p5`/`p7` (stock's kernel/rootfs) — there's no code path that writes there
- `mmcblk0p1` (the OTA marker) — that's a separate, deliberate step, covered below
- `mmcblk0p9`/`p10` (the persistent data partitions) — not this script's job
- U-Boot, the partition table, or any factory-calibration data — nothing in this repo touches those

Worth knowing why this is so locked down: an earlier version of this script had a broken check for
"what am I currently booted from," and a write ended up landing on the live, running rootfs. That
went about as well as you'd expect — cascading segfaults, needed a manual power cycle to recover.
The current script was rewritten specifically to make that impossible: it reads the real `root=`
value out of `/proc/cmdline` instead of trusting an alias, and refuses outright if the resolved
target matches the resolved active slot. If you're ever modifying this script, know that the
safety check is there because we got burned once, not because it seemed like a good idea in the
abstract.

## The OTA marker

`/dev/mmcblk0p1` is a plain 1 MB partition. Its whole job is holding one of two strings:

```
ota:kernel      (boot slot 1 / stock next)
ota:kernel2     (boot slot 2 / custom next)
```

Two different tools write it, depending which OS you're currently on — and that's intentional, not
an inconsistency:

| From | Tool |
|---|---|
| Custom (RosetteOS) | `/etc/ota_marker.sh`'s `write_ota_marker()` — RosetteOS's helper, ships as part of the rootfs |
| Stock (Creality) | `/etc/ota_bin/ota_local_method.sh`'s `local_set_next_boot_device()` — Creality's own pre-existing tool, already on stock |

If you're switching over from stock for the first time, you use stock's own tool, since RosetteOS's
helper doesn't exist there yet. Once you're running RosetteOS, its own tool takes over. Both have
been used successfully on real hardware to flip the marker and switch slots.

The part that actually reads the marker at boot time lives in the bootloader, which is vendor code
outside this repo — so we can only describe what we've observed (writing the marker and rebooting
reliably switches the boot target), not the internals of how it's read.

## What happens on first boot

```
reboot
  |
S00revert-safety   -- unconditionally sets marker to "ota:kernel" (stock),
  |                   the very first thing custom's own init runs
init sequence proceeds (S04 factory-seed/migrate, S5x services...)
  |
S99confirm-good    -- polls Moonraker's /server/info for klippy_state=="ready"
  |                   (up to 30 retries, 5s apart = 150s)
  |
  +-- success --> write_ota_marker "ota:kernel2"  (marker flipped forward)
  |
  +-- timeout ----> marker stays "ota:kernel" (stock)
                     next reboot lands on stock automatically
```

The idea is simple: the moment a RosetteOS boot starts, it assumes the worst and sets the marker
back to stock. Only once Klipper and Moonraker are actually confirmed healthy does it flip the
marker forward again. So if a RosetteOS boot ever crashes or hangs, the *next* reboot lands you back
on stock automatically — you don't need to do anything.

**One thing to be aware of:** this safety net lives inside RosetteOS's own boot sequence (inherited from its NebulaOS lineage). If the
kernel never gets far enough to even start userspace — or the rootfs fails to mount before
`/sbin/init` runs — `S00revert-safety` never gets the chance to run, and the marker just stays
wherever it already was. If it was already pointed at `ota:kernel2`, a genuinely broken kernel or
rootfs doesn't have a proven automatic way back through this mechanism — it'll just keep trying to
boot the broken slot. We haven't actually tested this specific failure case (intentionally flashing
something broken to see what happens), so treat it as the one real edge case here. If you do hit
it, `docs/DEVELOPER_RECOVERY.md` covers the actual recovery options.

## Related docs

- `docs/DEVELOPER_INSTALL_FROM_STOCK.md` — the full first-install walkthrough
- `docs/DEVELOPER_UPDATE.md` — updating an existing install
- `docs/DEVELOPER_RECOVERY.md` — what to do if something goes wrong, including the edge case above
- `docs/HOW_TO_SWITCH_STOCK_AND_CUSTOM.md` — the practical, day-to-day version of flipping slots
- `docs/NEBULAOS_OTA_FLOW.md` — the bigger picture this slot model fits into
