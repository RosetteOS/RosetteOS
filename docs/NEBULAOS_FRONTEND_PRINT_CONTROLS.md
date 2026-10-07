# NebulaOS Frontend Print Controls — Restoring Standard Klipper Print State

Mission: "Autonomous Completion Mission: Restore Standard Klipper Print
Controls, Fix Mainsail Phantom Print State, and Requalify the Ender-3 V3 KE
Release" (2026-07-29). Builds on
[NEBULAOS_MOONRAKER_UPDATE_AND_CAMERA_ANALYSIS.md](NEBULAOS_MOONRAKER_UPDATE_AND_CAMERA_ANALYSIS.md)
and does not move or reopen tag `nebulaos-offline-firstboot-updates-camera-complete-2026-07-29`.

## 1. The defect

Mainsail reported these config-closure warnings on every boot, and showed a
phantom `0 / 0`, `0 seconds left` print state even with no print active:

```
virtual_sdcard is not defined in config.
pause_resume is not defined in config.
gcode_macro pause is not defined in config.
gcode_macro resume is not defined in config.
gcode_macro cancel_print is not defined in config.
display_status is not defined in config.
```

## 2. Live evidence gathered (read-only, no motion/heating)

Queried directly against the running device over SSH/HTTP, no G-code
executed, no macro invoked, nothing homed or heated:

- `/printer/objects/list` — confirmed `virtual_sdcard`, `print_stats`,
  `pause_resume`, `display_status`, `exclude_object` are genuinely absent
  from the live Klipper object list (not a Mainsail-only rendering issue).
- `/server/info` — Moonraker's own `missing_klippy_requirements` field
  independently confirms the same three: `["display_status", "pause_resume",
  "virtual_sdcard"]`.
- `/printer/gcode/help` — confirmed no `PAUSE`/`RESUME`/`CANCEL_PRINT`
  command registered at all.
- `/server/job_queue/status` → `{"queued_jobs": [], "queue_state": "paused"}`
  and `/server/history/list?limit=3` → `{"count": 0, "jobs": []}` — Moonraker
  itself holds no queued or historical job. This rules out a genuine stale
  job as the cause of the `0/0` display; it is Mainsail's own frontend
  fallback rendering for a printer that has never reported real
  `virtual_sdcard`/`print_stats` objects to key off of, not a second,
  independent bug in Moonraker's job state.
- `webhooks.state: ready`, `idle_timeout.state: Idle`,
  `toolhead.homed_axes: ""` — the printer is genuinely idle and unhomed;
  nothing about the underlying machine state is itself wrong.

## 3. Config closure audit

`/opt/printer_data/config/printer.cfg` had exactly one `[include ...]` line
(`GuppyScreen/guppy_cmd.cfg`). Searched that file and `printer.cfg` itself
for `virtual_sdcard|pause_resume|display_status|PAUSE|RESUME|CANCEL_PRINT|
rename_existing|exclude_object` — zero matches. The gap is real, not a
naming mismatch or a shadowed duplicate: these objects/commands were never
defined anywhere in this project's factory config at all.

| Function | Current source | Present | Used by Mainsail | Used by GuppyScreen | Hardware-specific | Keep/replace |
|---|---|---|---|---|---|---|
| `virtual_sdcard` | none | No | Yes (progress/job state) | Yes (`virtual_sdcard/progress`) | No | Add: native `[virtual_sdcard]` |
| `pause_resume` | none | No | Yes (pause/resume UI state) | Yes (`pause_resume/is_paused`) | No | Add: native `[pause_resume]` |
| `display_status` | none | No | Yes (progress bar/M117) | No (uses `print_stats`) | No | Add: native `[display_status]` |
| `print_stats` | none (auto-loaded by `virtual_sdcard`) | No | Yes (`print_stats/*`) | Yes (`print_stats/*`) | No | Auto-loaded, no explicit section needed |
| `PAUSE` | none | No | Yes | Yes (literal `PAUSE` string in binary) | No | Native `pause_resume.py` command, no macro override |
| `RESUME` | none | No | Yes | Yes (literal `RESUME` string in binary) | No | Native `pause_resume.py` command, no macro override |
| `CANCEL_PRINT` | none | No | Yes | Yes (literal `CANCEL` string in binary) | No | Native `pause_resume.py` command, no macro override |

No duplicate or conflicting macro names exist anywhere in the closure.

## 4. Source-precedence evaluation (mandatory 4-level order)

**Level 1 — native mainline Klipper components.** Read the actual source of
this exact fork's extras at `/opt/klipper/klippy/extras/` (not assumed from
memory or another Klipper version):

- `virtual_sdcard.py`: constructor takes one required option, `path`
  (`config.get('path')`), and one optional Jinja template option,
  `on_error_gcode` (loaded via `gcode_macro.load_template`, defaulting to
  `TURN_OFF_HEATERS` if any heater exists). **`on_error_gcode: CANCEL_PRINT`
  is confirmed supported** by this fork — it is rendered through the same
  `gcode_macro` template mechanism as any other macro option, not a
  hardcoded string. It also auto-loads `print_stats` itself
  (`self.printer.load_object(config, 'print_stats')`), so `[print_stats]`
  needs no separate config section.
- `pause_resume.py`: takes one optional option, `recover_velocity` (default
  `50.0`). It registers `PAUSE`, `RESUME`, `CLEAR_PAUSE`, and `CANCEL_PRINT`
  **itself**, directly, with no macro layer required. Read in full:
  - `PAUSE`: if printing from virtual SD, pauses it (`do_pause()`, which
    just stops the SD work timer — no motion); otherwise just marks paused.
    Runs `SAVE_GCODE_STATE NAME=PAUSE_STATE`. No lift, no heater change, no
    homing.
  - `RESUME`: runs `RESTORE_GCODE_STATE NAME=PAUSE_STATE MOVE=1` (moving
    only back to the exact position/state that was saved at pause time —
    not an arbitrary or unconditional move), then resumes the SD timer if
    it was SD-paused. No re-homing, no heater restoration beyond whatever
    the saved state already held.
  - `CANCEL_PRINT`: cancels the virtual-SD file if active
    (`virtual_sdcard.do_cancel()`, which closes the file and calls
    `print_stats.note_cancel()` — no heaters touched, no motion), then
    clears the pause flags. Does not delete the G-code file itself, does
    not touch Moonraker's history (that's Moonraker's own concern via job
    completion callbacks, unaffected by this change).
- `display_status.py`: takes **no config options at all**. Registers `M73`,
  `M117`, and `SET_DISPLAY_TEXT`.

Conclusion: Level 1 alone fully covers every object and command in the
defect list, with safe, minimal, non-destructive default behavior that
already satisfies every safety constraint in this mission (no automatic
homing, no hidden heating, no unconditional movement, no unsafe Z lift).

**Level 2 — official Mainsail-built configuration.** No internet access was
used. The only locally pinned reference tied to the Mainsail/Klipper
installer ecosystem already vendored in this repo is
`vendor/kiauh/kiauh/components/klipper/assets/printer.cfg` (`mainsail-crew`'s
own KIAUH installer, also vendored at `vendor/kiauh/`). Its entire relevant
content is:

```
[virtual_sdcard]
path: %GCODES_DIR%
on_error_gcode: CANCEL_PRINT
```

This is the same convention Level 1 already arrived at independently
(`on_error_gcode: CANCEL_PRINT`), and — notably — it does **not** define
custom `PAUSE`/`RESUME`/`CANCEL_PRINT` macro overrides either. The widely
known community `mainsail-config` repository does define fancier
`rename_existing`-based macros (retract, park, conditional heater-off), but
that repository is not vendored anywhere in this project, and fetching it
at runtime would violate this mission's explicit no-internet-dependency
requirement. Given Level 1 already safely satisfies every named object and
command, and the one config genuinely available locally confirms the same
minimal approach, no such macro wrapping is added.

**Level 3 — GuppyScreen compatibility.** `strings` against the shipped
`/opt/guppyscreen/guppyscreen` binary confirms it reads the standard object
paths (`pause_resume/is_paused`, `print_stats/*`, `virtual_sdcard/progress`)
and issues the standard command names — a literal pattern string
`PRINT|SDCARD|PAUSE|RESUME|CANCEL|EXCLUDE_OBJECT|M24|M25|M73` is present in
the binary. GuppyScreen requires no behavior beyond what Level 1 supplies;
no GuppyScreen-specific compatibility file is added.

**Level 4 — Creality Ender-3 V3 KE fallback macros.** Not required. Nothing
in the defect list is hardware-specific (bed clearance, load-cell interlock,
etc.) — every missing piece is a standard Klipper object/command with no
Creality-only behavior involved.

## 5. Decision record

Implement exactly, and only:

```ini
[virtual_sdcard]
path: /opt/printer_data/gcodes
on_error_gcode: CANCEL_PRINT

[pause_resume]

[display_status]
```

in a new dedicated file, `frontend-controls.cfg`, included from
`printer.cfg`. `print_stats`, `PAUSE`, `RESUME`, and `CANCEL_PRINT` all come
for free from `virtual_sdcard`/`pause_resume` themselves — no explicit
`[print_stats]` section and no `gcode_macro` overrides are added. This is
the complete, single, reviewed source of truth for all six named
objects/commands: 100% Level 1 (native mainline Klipper), independently
corroborated by the one real Level 2 reference available locally. No Level
3 or Level 4 additions were needed or made.

`/opt/printer_data/gcodes` matches this project's already-seeded canonical
G-code directory (confirmed present, populated, and shared with stock via
the same physical partition) — not a placeholder or `~`-relative path.

### 5.1 Correction (2026-07-29, live user report): the "no macros needed" conclusion was incomplete

After deploying the fix above, the device owner reported Mainsail still
showing:

```
gcode_macro pause is not defined in config.
gcode_macro resume is not defined in config.
gcode_macro cancel_print is not defined in config.
```

Live investigation confirmed the root cause: Mainsail's frontend checks
**`configfile.settings`** (the raw parsed config sections) directly for
literal `gcode_macro pause`/`gcode_macro resume`/`gcode_macro cancel_print`
keys - it does not infer their presence from whether the `PAUSE`/`RESUME`/
`CANCEL_PRINT` *commands* already work at runtime via `pause_resume.py`.
Querying `configfile.settings` on the live device confirmed no such keys
existed, even though the commands themselves were already registered and
fully functional. Moonraker's own `missing_klippy_requirements` stayed
empty throughout - this is specifically a Mainsail frontend expectation,
not a Klipper/Moonraker-level "missing requirement."

The original Level 1/Level 2 analysis (native `pause_resume.py` already
implements these commands safely, matching the one real local reference)
remains correct about *functional* behavior, but incomplete about what
Mainsail's own UI actually checks for. Fixed with three minimal,
pure-pass-through macros added to `frontend-controls.cfg`:

```ini
[gcode_macro PAUSE]
rename_existing: BASE_PAUSE
gcode:
  BASE_PAUSE

[gcode_macro RESUME]
rename_existing: BASE_RESUME
gcode:
  BASE_RESUME

[gcode_macro CANCEL_PRINT]
rename_existing: BASE_CANCEL_PRINT
gcode:
  BASE_CANCEL_PRINT
```

Each macro does nothing but call straight through to the renamed native
command - zero added behavior, so every safety property already
established (no unsafe Z lift, no heater changes, no homing) is preserved
exactly; only the *presence* of the config section changes, not what
actually happens when `PAUSE`/`RESUME`/`CANCEL_PRINT` run. Confirmed live
after redeploying: `configfile.settings` now contains `gcode_macro pause`/
`gcode_macro resume`/`gcode_macro cancel_print`; `gcode/help` shows
`BASE_PAUSE: Renamed builtin of 'PAUSE'` (and the same for `RESUME`/
`CANCEL_PRINT`), proving Klipper's `rename_existing` mechanism correctly
wrapped the native implementation rather than replacing it; idle state
(`virtual_sdcard.is_active=false`, `print_stats.state=standby`,
`pause_resume.is_paused=false`) and `missing_klippy_requirements: []`
stayed clean throughout.

`scripts/build/lib/validate-frontend-controls.sh`'s closure validator was
updated to make these three macro sections **required** (previously
optional, 0-1 occurrences allowed) - a future rebuild that dropped them
would now fail the build, not just reintroduce a live warning.

The user also reported the `GuppyScreen` folder specifically still not
showing content in Mainsail's file browser, even though every other file
now displays correctly. Live investigation found the backend already
fully correct here too: `GuppyScreen/guppy_cmd.cfg` and every file under
`GuppyScreen/scripts/` are listed by `/server/files/list?root=config`
with normal `rw` permissions, and the directory's own filesystem
permissions (`drwxr-xr-x`) are unremarkable. No backend or architectural
cause was found - this looks like a Mainsail frontend navigation/
rendering matter specific to that one nested folder, not a data problem,
consistent with this document's own §7 Case E conclusion.

## 6. Live qualification evidence (2026-07-29)

Every step below ran against the real Ender-3 V3 KE / Nebula Pad device, no
motion/heating/homing performed at any point.

- **One-time live correction (dev printer, before rebuild)**: read-only
  safety check first (heaters at target 0, `idle_timeout.state: Idle`,
  `toolhead.homed_axes: ""`, no queued/history jobs) confirmed the machine
  was safe to touch. Full backup taken of `printer.cfg`, `moonraker.conf`,
  `GuppyScreen/`, the Moonraker SQLite database, both logs, and the
  pre-fix warning evidence. `frontend-controls.cfg` deployed and the
  include line added atomically; Klipper restarted alone (no Moonraker
  restart needed - it detected the reconnect on its own). Result: Klipper
  `ready`, `missing_klippy_requirements: []`, `PAUSE`/`RESUME`/
  `CANCEL_PRINT`/`CLEAR_PAUSE` all registered, `virtual_sdcard.is_active:
  false`, `print_stats.state: standby`, `pause_resume.is_paused: false` -
  checked at the API level, not just "the warning panel looks empty."
- **Full clean rebuild**: `04-cross-compile-app-stack.sh` ran the new
  print-control closure validator for real against the tracked overlay
  source and passed (`virtual_sdcard`/`pause_resume`/`display_status`
  each defined exactly once, correct path, no duplicate or circular
  macros). `05-final-build.sh` produced a clean `rootfs.squashfs`.
  `06-verify.sh` reported **zero MISS lines** across the entire packaged
  image, including every new print-control check and the already-shipped
  `uv4l-mjpeg` camera default (confirmed directly inside the packaged
  `/usr/libexec/nebulaos-seed-camera`).
- **Safe reflash**: booted to stock, qualified `flash-spare-slot.sh`
  preflight reported `SAFE TO FLASH` (target slot 2 inactive), real write
  independently md5-verified for both `xImage` and `rootfs.squashfs`, OTA
  marker flipped as its own separate step, reboot as its own separate
  step. Booted successfully on the new image (`root=/dev/mmcblk0p8`,
  kernel build timestamp matching the rebuild).
- **Genuine empty-namespace requalification**: wiped
  `/usr/data/nebulaos/{apps,backups,envs,guppyscreen,maintenance,
  printer_data,system,updates}` (keeping only `wpa_supplicant.conf` and
  the separately-mounted shared-gcodes partition, exactly as required),
  one offline reboot. Result: `printer_data/config` - including
  `frontend-controls.cfg` - reseeded entirely from the immutable factory
  seed with no restored/carried-over files; zero `FileNotFoundError` in
  `klippy.log`; `missing_klippy_requirements: []` and `warnings: []`;
  `virtual_sdcard`/`print_stats`/`pause_resume`/`display_status` all
  clean; the 48 shared G-code files survived untouched; the database
  camera freshly re-seeded with the correct `uv4l-mjpeg` service from
  scratch (not carried over from the earlier live edit).
- **Non-motion integration check**: Mainsail's static UI served (`200`),
  GuppyScreen's process alive with an active websocket connection, all 72
  registered G-code commands including the six print-control ones present
  with no conflicts. The only log noise present (a pre-existing, unrelated
  gcode-file metadata quirk; empty `guppyscreen`/`fluidd` database
  namespaces on a brand-new database; one early-boot JSON-RPC race before
  Klipper's connection was established) was reviewed and is unrelated to
  this fix.
- **Persistence**: a plain reboot (same slot, no marker change) left the
  seed marker timestamp unchanged - proving no unwanted re-seed - and
  every print-control object still clean. A static check of
  `nebulaos-update-supervisor.sh` confirms its rollback logic only ever
  touches `printer_data/logs/*.log`, never `printer_data/config` -
  printer configuration was never part of, and remains outside of,
  application rollback.

## 7. Addendum: Mainsail "Config Files" folder reported empty (2026-07-29)

A follow-up report described `Mainsail -> Machine -> Config Files -> config`
appearing empty despite Klipper running normally. Investigated as a
possible split-brain configuration architecture (Klipper/Moonraker/
Mainsail resolving to different directories) - the most serious of the
listed possible causes, and release-blocking if true.

### 7.1 Read-only evidence gathered against the live device

- **Mounts**: `/dev/mmcblk0p10 on /opt/printer_data type ext4` and a
  second, separate mount at `/opt/printer_data/gcodes` for the
  stock-shared G-code partition. The `ext4`/device label shown for
  `/opt/printer_data` is expected for a `mount --bind` (BusyBox's `mount`
  reports the underlying source filesystem type for a bind mount, not
  `none`), matching `S01persistent-datastore`'s own
  `mount --bind "$PDATA" /opt/printer_data` exactly.
- **Directory listings**: `/opt/printer_data/config` and
  `/usr/data/nebulaos/printer_data/config` show byte-identical content
  (`printer.cfg`, `moonraker.conf`, `frontend-controls.cfg`, `songs.conf`,
  `GuppyScreen/`) - confirmed later at the inode level (§7.2).
- **Process command lines**, read directly from `ps`/`/proc/<pid>/cmdline`,
  not assumed: Klipper is `klippy.py /opt/printer_data/config/printer.cfg
  -a ... -l ...`; Moonraker is `moonraker.py -d /opt/printer_data -c
  /opt/printer_data/config/moonraker.conf -l ... -u ...`. Both already
  targeted the canonical paths.
- **Moonraker's own `/server/files/roots`** (queried both directly on
  port 7125 and through nginx's proxy on port 80 - the exact path a real
  browser uses) reported `{"name":"config","path":"/opt/printer_data/config","permissions":"rw"}`
  correctly, alongside `gcodes`/`logs`/`config_examples`/`docs`.
- **Moonraker's own `/server/files/list?root=config`** (both paths) listed
  every expected file with `rw` permissions - `printer.cfg`,
  `moonraker.conf`, `frontend-controls.cfg`, `songs.conf`, the full
  `GuppyScreen/` tree, and `.moonraker.conf.bkp`.
- **nginx's error log was empty and its access log showed no prior
  `files/list`/`files/roots` request at all** before this investigation's
  own `curl` calls - meaning no browser session had actually exercised
  this endpoint against this device during the current session.

### 7.2 Case-by-case elimination (per the mission's own classification)

- **Case A** (files only in the persistent backing path, not the runtime
  view) - ruled out: identical content confirmed at the **inode level**
  (`ls -i` showed the same inode number, e.g. `306007`, for a test file
  created under both `/opt/printer_data/config/` and
  `/usr/data/nebulaos/printer_data/config/` - they are the same file via
  the bind mount, not two copies that happened to match).
- **Case B** (Moonraker's registered root points elsewhere) - ruled out:
  `/server/files/roots` reports exactly `/opt/printer_data/config`.
- **Case C** (Klipper reads a different location - split-brain) - ruled
  out: the real process command line proves `printer.cfg`'s path matches
  Moonraker's config root exactly.
- **Case D** (correct root, but Moonraker cannot read it) - ruled out: a
  full create/read/edit/delete cycle through the real file-manager API
  (§7.3) succeeded end to end.
- **Case E** (frontend cache/state, backend already correct) - the only
  remaining explanation. Every code path a real browser would use
  (through nginx's reverse proxy on port 80, matching `location ~
  ^/(printer|api|access|machine|server)/` in the shipped `nginx.conf`)
  returns the correct data with no errors logged anywhere. Per the
  mission's own instruction not to alter filesystem architecture once the
  API is already proven correct, no architectural change was made. If a
  user still sees an empty Config Files panel after this, the standard
  remedy for a stale PWA frontend (Mainsail ships a service worker,
  `sw.js`/`workbox-*.js`) is a hard refresh or clearing that site's stored
  data in the browser - this is a frontend-state question, not a
  filesystem or Moonraker configuration one.

### 7.3 Editability proof (harmless test file, through the real API)

Performed through Moonraker's actual `/server/files/upload` and
`/server/files/config/<path>` endpoints - the same ones Mainsail's editor
uses - never a direct filesystem write:

```text
create  _mission_editability_test.cfg  -> 201, listed immediately after
read    GET the file back              -> exact content returned
edit    re-upload with new content     -> 201, re-read confirms the change
delete  DELETE the file                -> 200, gone from both
                                           /opt/printer_data/config and
                                           /usr/data/nebulaos/printer_data/config
inode   identical (306007) on both paths throughout - one canonical file,
        never two divergent copies
```

A second check edited an **existing** file (`songs.conf`, chosen
specifically because it is unrelated to the print-controls fix itself):
appended a harmless comment, confirmed it landed on both paths, then
reverted it and confirmed the SHA-256 hash matched the pre-edit original
exactly (`235d2f25de78a26f7eed5c932f6fc095aee670f951ce05599ae5ecba3bc90af5`)
- proving both that edits persist and that this test left no lasting
change.

### 7.4 `SAVE_CONFIG` destination proof (source inspection, no calibration)

Read `configfile.py` directly rather than assuming behavior from another
Klipper version: `cmd_SAVE_CONFIG` resolves its target with
`cfgname = self.printer.get_start_args()['config_file']` - the exact same
value Klipper was launched with (confirmed via the real process command
line, §7.1) - then writes to a same-directory `_autosave.cfg` temp file
and atomically `os.rename()`s it into place, after first backing up the
original with a timestamp suffix. `SAVE_CONFIG` provably targets the same
canonical, bind-mounted, persistent file every other check in this
section already confirmed - no physical calibration was run to test this.

### 7.5 Build-time regression guards added

`06-verify.sh` gained new checks (no runtime code needed to change - the
architecture was already correct in the tracked source, matching the live
device exactly): `S55klipper`'s `CONFIG` and `S56moonraker`'s
`DATAPATH`/`CONFIG` literal values, `S01persistent-datastore`'s bind-mount
line and persistent backing root, no obsolete `/usr/data/rosetteos` or
`/opt/rosetteos` path reference in either service's init script (a bare
mention of the historical "RosetteOS" project name in a comment is fine and
does not fail this check), and no `[file_manager]` override in
`moonraker.conf` that could let the config root diverge from `-d`'s
default. Re-run against the already-built Phase 11 artifacts (no rebuild
needed, since nothing shippable changed): all six new checks pass, and
the full run remains at zero `MISS` lines overall.

### 7.6 Why no second wipe-and-reboot qualification was performed

Nothing in the actual shipped image changed as a result of this
addendum - `S01persistent-datastore`, `S55klipper`, `S56moonraker`, and
`moonraker.conf` were all found already correct and were not modified;
only a new host-side build verification check was added, which does not
affect runtime behavior. The live evidence in §7.1-7.4 was gathered
against the device in the exact state Phase 13's genuine empty-namespace
wipe test left it in (confirmed unmodified since, other than the harmless,
fully-reverted editability test above, by Phase 15's own persistence
check showing the seed marker timestamp unchanged). Repeating the wipe
purely to re-observe a config-visibility outcome that provably has not
changed would not add evidence, so it was not done. Any future change to
`S01persistent-datastore`/`S55klipper`/`S56moonraker`/`moonraker.conf`
should re-run this section's live checks before trusting them again.
