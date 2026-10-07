# NebulaOS Ender-3 V3 KE Factory `printer_data/config` Seed

**Status: Implemented and live-qualified, 2026-07-29.** See `docs/NEBULAOS_MOONRAKER_UPDATE_AND_CAMERA_ANALYSIS.md` §31 for the full root-cause narrative; this document is the focused reference for the seed itself - what it contains, why, and how it is verified.

## 1. The problem this closes

A genuinely wiped `/usr/data/nebulaos/printer_data/config` left Klipper and Moonraker crash-looping forever - neither `printer.cfg` nor `moonraker.conf` existed anywhere reachable at boot. The only code that had ever created these files was a one-time migration from a legacy `/usr/data/rosetteos/printer_data` path, removed in an earlier closure mission. Every prior "fresh boot" qualification in this project's history had, without anyone realizing it, relied on that migration's leftover files still being present - nobody had ever actually deleted them before. Full detail: the analysis doc referenced above.

## 2. What ships, and where

The tracked source of truth remains `scripts/build/overlay/opt/printer_data/config/`:

```text
printer.cfg             - real Ender-3 V3 KE hardware wiring (pins, kinematics, heaters, bltouch)
frontend-controls.cfg   - standard virtual_sdcard/pause_resume/display_status (mainline print-controls
                          mission, 2026-07-29 - see docs/NEBULAOS_FRONTEND_PRINT_CONTROLS.md)
moonraker.conf          - corrected NebulaOS Moonraker config (reserved update_manager sections, no config-owned webcam)
songs.conf              - GuppyScreen startup jingle definitions
GuppyScreen/            - GuppyScreen's own base config + Python helper scripts
```

This is unchanged by the 2026-07-29 fix - it already existed, already ships at the immutable `/opt/printer_data/config/` path, and already had its calibration-data policy decided (§3 below) well before this finding. What changed is that `04-cross-compile-app-stack.sh` now *also* copies this exact same tracked content into a second, dedicated immutable location:

```text
/opt/nebulaos-seeds/printer_data-config/
```

This second copy exists because `/opt/printer_data/config` is not actually reliable as a seed *source* at runtime: `S01persistent-datastore` bind-mounts the persistent `printer_data` directory over `/opt/printer_data` unconditionally, very early in boot (a deliberate "genuine fallback, not just an early seed," per that script's own comment). By the time anything later in boot might read `/opt/printer_data/config/printer.cfg`, it is already looking at the persistent copy - which is exactly what needs seeding in the first place. `/opt/nebulaos-seeds/` is never subject to any bind mount, the same reason `klipper.tar.gz`/`moonraker.tar.gz` already live there rather than being read out of `/opt/klipper`/`/opt/moonraker`.

## 3. Calibration-data policy (already in place, predates this fix)

`printer.cfg`'s own header documents this in detail; summarized here for reference:

- **Removed and never shipped:** the real device's `SAVE_CONFIG` block (`bed_mesh`/`input_shaper`/`axis_twist_compensation` calibration data, TMC autotune) - all measured against a different kernel/firmware combination, and not something a fresh install should silently inherit.
- **Kept as real, physical-hardware values:** stepper pins, kinematics, heater PID values (`pid_Kp`/`pid_Ki`/`pid_Kd` for both extruder and bed), `pressure_advance`. These describe the physical printer or its heater response, not a stale spatial calibration - a wrong PID value causes temperature overshoot, not a nozzle-into-bed collision, so reusing a real measured value here is a reasonable default rather than a safety risk.
- **One deliberate, explicit safety default:** `bltouch`'s `z_offset: 0`. This option is *required* for Klipper to parse the `[bltouch]` section at all (`9332aa2`, found live during an earlier mission) - omitting it entirely breaks Klipper's ability to start, which is worse than shipping an explicit value. `0` is the correct fresh-install default specifically because it cannot cause the nozzle to crash into the bed (unlike a stale negative value would risk); `PROBE_CALIBRATE` must still be run before real printing to get this physical printer's true value.

## 4. Build-time verification

Three checks in `04-cross-compile-app-stack.sh` refuse to package a bad seed, failing the build outright rather than shipping something broken:

1. `printer.cfg` and `moonraker.conf` must both exist in the tracked source.
2. No real `SAVE_CONFIG` block (`^#\*# <---------------------- SAVE_CONFIG`) may be present.
3. No option may be present but syntactically blank - checked with a continuation-aware pass (a bare `key:` followed by an indented line is a legitimate multi-line list value, e.g. `moonraker.conf`'s own `trusted_clients`/`cors_domains`; a bare `key:` followed by anything else, or end of file, is genuinely blank and would fail Klipper's or Moonraker's own config parser).

`06-verify.sh` independently re-checks all of the above against the actual built `rootfs.ext2` (not just the tracked source), plus that `S02nebulaos-namespace` contains the seeding logic and `S05nebulaos-activate` validates against the real required files rather than just the `config` directory.

Mainline print-controls mission (2026-07-29) added a fourth check, shared via `scripts/build/lib/validate-frontend-controls.sh` with `tests/nebulaos-frontend-controls-validation-tests.sh`: `frontend-controls.cfg` must exist and be included from `printer.cfg`, and the resolved include closure must define `virtual_sdcard`/`pause_resume`/`display_status` exactly once each (no missing, no duplicate, no recursive `rename_existing` chains), with `virtual_sdcard`'s `path` matching the canonical `/opt/printer_data/gcodes`. Full detail: `docs/NEBULAOS_FRONTEND_PRINT_CONTROLS.md`.

## 5. Runtime seeding logic

`S02nebulaos-namespace`'s `seed_printer_data_config()`, marker-guarded identically to `S57nebulaos-camera-seed`'s already-qualified pattern:

```text
marker present                       -> do nothing, ever (respects user deletion)
printer.cfg AND moonraker.conf exist -> record marker retroactively, touch nothing
seed source incomplete               -> log error, no marker, safe to retry next boot
otherwise                            -> copy from /opt/nebulaos-seeds/printer_data-config/,
                                         verify both files landed, then write the marker
```

`S05nebulaos-activate`'s `printer_data` activation now checks `config/printer.cfg config/moonraker.conf` (both required files), not just the `config` directory - a wiped persistent copy is correctly rejected rather than bind-mounted empty over the immutable defaults.

## 6. Test coverage

`tests/nebulaos-printerdata-seed-tests.sh` (10 cases, offline, sources `S02nebulaos-namespace` directly against fixture directories):

```text
fresh namespace: printer.cfg/moonraker.conf/songs.conf/GuppyScreen all seeded
fresh namespace: seed marker written
marker present: user-deleted printer.cfg is not recreated
existing real config: content untouched byte-for-byte, marker recorded retroactively
incomplete seed source: no marker written, clear error logged
partial destination: missing file completed from the seed
repeated boot: marker unchanged, no reseed
```

## 7. Live evidence

A genuinely wiped `/usr/data/nebulaos` (everything except the WiFi config, so remote access survived the reboot), rebuilt image, reflashed via the full documented safety sequence, one boot, zero manual intervention:

```text
printer_data/config/: printer.cfg, moonraker.conf, songs.conf, GuppyScreen  (all present)
printer-data-config-seeded.json: {"seeded_at": "1970-01-01T00:00:10Z", "result": "seeded_from_immutable_defaults"}
klipper:   is_valid=true, current_hash==remote_hash, state=ready
moonraker: is_valid=true, current_hash==remote_hash
mainsail:  is_valid=true, static UI serving (200)
camera:    database-seeded fresh (new uid, correct defaults)
ota marker: kernel -> kernel2 (S99confirm-good passed)
klippy.log / moonraker.log: zero FileNotFoundError
```

Repeated again for the mainline print-controls mission (2026-07-29), same wipe scope, same one-boot/zero-manual-intervention discipline - this time also confirming `frontend-controls.cfg` reseeds correctly and `virtual_sdcard`/`print_stats`/`pause_resume`/`display_status` all report clean idle state on the freshly-seeded config, not carried over from any prior live edit. Full evidence: `docs/NEBULAOS_FRONTEND_PRINT_CONTROLS.md` §6.

The marker's own `1970-01-01T00:00:10Z` timestamp - taken before NTP had ever run - is itself evidence the seeding happened genuinely early in boot, with no dependency on network time.

## 8. Addendum: proving the seeded config is actually visible/editable through Mainsail (2026-07-29)

A follow-up report described Mainsail's Config Files page as showing an
empty `config` folder despite Klipper running - potentially a much more
serious variant of this document's own topic (a split-brain architecture
where Klipper, Moonraker, and Mainsail each resolve to a different
config directory). Investigated directly against the live device:
`S01persistent-datastore`'s bind mount, `S55klipper`/`S56moonraker`'s
launch arguments, and Moonraker's own `/server/files/roots`/`files/list`
all independently agree on the exact same canonical
`/opt/printer_data/config` path this document already describes - proven
at the inode level, not just by comparing directory listings. No
filesystem or activation-sequence change was needed; the architecture
this document already documents was already correct. Full investigation,
editability proof, and the new build-time regression guards added to
catch a future divergence: `docs/NEBULAOS_FRONTEND_PRINT_CONTROLS.md` §7.
