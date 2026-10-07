# Component update ownership

2026-08-07/08, Clean-Update + Virgin Baseline mission, Phase 2. One
explicit owner per component - no component may have two independent
paths that can each change what's actually running, since that's exactly
the class of bug Phase 1 found and fixed for Klipper.

## Klipper

**Owner: canonical Git repo + Moonraker's reserved updater, unified.**

- Canonical source: `coreflake1/NebulaOS-klipper`, `master` branch (see
  `docs/NEBULAOS_UPDATER_AUDIT.md` for the branch-unification fix).
- Build time: `manifests/dependencies.conf`'s `KLIPPER_PIN` fetches this
  exact commit into the squashfs's factory-seed archive.
- Run time: Moonraker's reserved `[update_manager klipper]` slot updates
  the *persistent* checkout in place, tracking whichever branch it's on -
  now the same `master` the build pins, so both paths agree.
- **Persistent checkout must be clean.** Enforced going forward by Phase 3's
  migration system (this document doesn't implement that machinery itself,
  it just states the requirement each owner is responsible for).

## GuppyScreen

**Owner: NebulaOS firmware/release only. No independent updater exists,
and none should be added without a deliberate future mission.**

- Canonical source: `RosetteOS/GuppyScreen`, `OKE` branch,
  refreshed to the latest branch tip on each build; the fetched SHA is recorded in the build manifest.
- Served from `/opt/guppyscreen` - **immutable, squashfs-resident**, not
  persistent-data-backed. A new image ships a new binary automatically;
  there is nothing for a live updater to manage.
- No `[update_manager guppyscreen]` section exists in `moonraker.conf`,
  confirmed deliberate (that file's own comment already states this).
  **This document formalizes it as a standing rule, not just a current
  fact**: do not add a live GuppyScreen updater unless a future mission
  explicitly decides GuppyScreen should become persistent-data-backed
  (mirroring Klipper's model) - doing so silently, without also changing
  where the binary is served from, would recreate exactly the
  two-owners problem this phase exists to prevent.
- Found during this audit, noted as inert cruft, **not currently a
  conflict**: `/usr/data/helper-script/files/guppy-screen/guppy-update.sh`
  and sibling paths (`/usr/data/guppyscreen/`, `/usr/data/guppy-webrtc-
  stage/`, `/usr/data/guppyify-backup/`) are leftovers from a pre-NebulaOS-
  namespace provisioning era (SimpleAF/Creality-installer-style helper
  scripts), outside `$NEBULAOS_ROOT` entirely. Nothing in the current
  tracked build overlay references them (confirmed by grep) - they are
  dormant, not wired into any init script/cron/supervisor entry. Not
  cleaned up this mission (out of scope: this phase is about *active*
  update paths, not general persistent-partition archaeology), but
  flagged here so a future reader doesn't mistake their presence for a
  live, competing update mechanism.

## Kernel / rootfs / NebulaOS itself

**Owner: the NebulaOS package updater only** (`scripts/flash-spare-
slot.sh` + the OTA-marker mechanism) - **never** an ordinary `git pull`
replacing the running OS.

- This was already true before this mission - `flash-spare-slot.sh`'s
  entire design (fixed target slot, mandatory preflight, byte-verified
  write, separate deliberate marker-flip step) exists specifically to be
  the *only* way the running kernel/rootfs changes. There is no git
  checkout of kernel or Buildroot source anywhere on the live device -
  the full `vendor/system` OKE System checkout (including its `buildroot/` subtree) is build-host-
  only, gitignored, never shipped to the printer.
- Formalized here as a standing rule for the same reason as GuppyScreen's
  entry above: any future convenience script that tries to "quick-patch"
  the running kernel/rootfs via anything other than this flow would
  recreate the two-owners problem.

## Mainsail

**Owner: intentionally dual, by ecosystem convention - not a bug, but
documented as a deliberate exception to the "one owner" rule.**

See `docs/NEBULAOS_UPDATER_AUDIT.md`'s own Mainsail section for the full
detail. Unlike the three components above, Mainsail is a third-party web
UI, not NebulaOS-owned application code - letting Moonraker's own web-
updater track upstream `beta` releases independently of the build's pin is
standard practice across the whole Klipper-firmware ecosystem, and Mainsail
drifting to a newer release cannot silently lose an *accepted NebulaOS
feature* the way Klipper branch drift could (there is no NebulaOS-authored
code in Mainsail to lose). Left as-is.
