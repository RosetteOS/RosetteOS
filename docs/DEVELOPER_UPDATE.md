# Updating an existing RosetteOS install

This assumes RosetteOS (or legacy NebulaOS) is already installed and booted. If it isn't yet, start with
`docs/DEVELOPER_INSTALL_FROM_STOCK.md`.

RosetteOS updates operate on two main levels: system image updates (via SWUpdate, USB, or manual slot flashing) and mutable application component updates (via Moonraker).

## Klipper and Moonraker updates — this works today

Klipper and Moonraker (the checkouts under `/usr/data/nebulaos/apps/{klipper,moonraker}`) update
through Moonraker's own update manager — the same "Update" button you'd normally see in Mainsail.
Nothing special here; it's the standard Klipper/Moonraker update flow. Neither one is pinned to a
specific commit, so they just track their branch tip.

This does **not** touch the kernel, the rootfs, or GuppyScreen. GuppyScreen in particular has no
update-manager entry at all — it ships baked into the squashfs image and only changes when you
flash a whole new build (see below). It also never touches your actual `printer.cfg`, macros, or
`moonraker.conf` — those live in a completely separate spot that this update path doesn't go near.

**If an update goes wrong**, there's a small background service (`nebulaos-update-supervisor.sh`)
that watches for it. It polls every 20 seconds, and if it sees a commit change, it runs a health
check — first that the files are actually there and importable, then that the whole printer stack
(Moonraker, Klipper, the MCU) actually comes up healthy. If that fails, it resets back to the last
known-good commit and restarts the service directly, rather than going through Moonraker's own API
(since a bad Moonraker update might have broken Moonraker itself). If even *that* fails, it falls
back to the untouched factory copy baked into the squashfs, and leaves things locked there until a
person clears it — it won't keep flip-flopping on its own.

We found two real bugs testing this on actual hardware: a false-positive rollback that fired too
soon after a restart (fixed with a small grace period), and some stale bookkeeping that could hide
a factory-fallback event from the next check (also fixed). It's been retested clean since.

One thing this doesn't handle yet: Moonraker's Python virtualenv isn't independently versioned or
rolled back. If a bad update's `requirements.txt` change ran a `pip install` before things broke,
resetting the source code with `git reset --hard` won't undo that. Still an open item.

## Updating the whole OS image

### Option A: SWUpdate (.swu) via GuppyScreen or LAN OTA (Recommended)
RosetteOS includes native SWUpdate integration. Updates are packaged as dual-slot `.swu` CPIO archives and can be installed:
- **Directly on the touchscreen**: Via GuppyScreen's Update Panel from a connected USB flash drive or network OTA feed.
- **Over local LAN**: Using `scripts/dev/serve-update.sh` to serve updates directly to printers on your local network.
- **Safety**: Includes automated pre-flight checks blocking updates if a print is running or heaters are energized.

### Option B: Manual developer slot flash
For low-level development, you can still flash raw kernel and rootfs images into the inactive slot:

```
build new xImage + rootfs.squashfs + build-manifest.txt
        |
scp to the device
        |
independent sha256sum check
        |
flash-spare-slot.sh --check-only   (confirms target slot is inactive)
        |
flash-spare-slot.sh                (writes + MD5 read-back verification)
        |
flip the marker, reboot
        |
same boot sequence as install (S00/S04/S5x/S99 - see A_B_SLOT_MODEL.md)
```

The automated OTA flow originally designed under NebulaOS (`docs/NEBULAOS_OTA_FLOW.md`) is now realized through RosetteOS's SWUpdate and GuppyScreen architecture.

## Related docs

- `docs/A_B_SLOT_MODEL.md` — the slot/marker mechanics behind the whole-image update path
- `docs/NEBULAOS_UPDATE_AND_ROLLBACK_DESIGN.md` — the full engineering writeup and test record for the component-update path
- `docs/NEBULAOS_UPDATE_OWNERSHIP.md` — which component owns which update path, and why GuppyScreen doesn't have one
- `docs/DEVELOPER_RECOVERY.md` — what to do if an update leaves the device unhealthy
