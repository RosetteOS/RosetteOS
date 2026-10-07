# NebulaOS Mutable Applications, Updates, Recovery, Shared G-code, and Retention — Final Implementation Report

**Mission status: Complete and live-qualified.** The four gaps this report originally left open (Mainsail update rollback, Moonraker env-versioning, retention-policy disk-pressure floors, and the legacy `/usr/data/rosetteos` runtime dependency) were closed in a follow-up closure mission (2026-07-27, see §4 for each resolution and the new `nebulaos-mutable-runtime-complete-2026-07-27` tag in §6). The original baseline tag below is left unchanged, per that mission's own explicit instruction. GuppyScreen updatability remains out of scope (deferred to a future mission, per the governing brief) and remains immutable, served from its own read-only `/opt/guppyscreen` copy.

This report is the single entry point for what shipped. Each linked document is the authoritative source for its own area; this report summarizes and cross-references rather than duplicating their content.

---

## 1. What NebulaOS is, now

Before this mission, Klipper/Moonraker/Mainsail/GuppyScreen were all baked into the read-only squashfs with zero update mechanism (`docs/NEBULAOS_MUTABLE_RUNTIME_ARCHITECTURE.md` §1.2). After this mission:

- **Klipper and Moonraker** live as real, writable git checkouts under `/usr/data/nebulaos/apps/{klipper,moonraker}`, updatable by the user through Moonraker's own Update Manager (surfaced in Mainsail's UI), each backed by a rollback-capable supervisor that reacts to a bad update automatically.
- **Moonraker** runs from its own writable Python virtualenv (`/usr/data/nebulaos/envs/moonraker`, `--system-site-packages`), not the read-only system interpreter.
- **Mainsail** updates via official beta release archives (Moonraker's `type: web` update mechanism), served from `/usr/data/nebulaos/apps/mainsail`.
- **GuppyScreen** remains immutable and out of scope, exactly as the governing brief specified.
- All of this lives under a single namespace, `/usr/data/nebulaos`, with its own layout manifest, activation-decision record, update-transaction state, and backups — never touching the shared stock partition outside that namespace except for the one deliberate exception (shared g-code).
- **Shared g-code**: `/usr/data/printer_data/gcodes` is bind-mounted inside NebulaOS's own `printer_data`, so stock and NebulaOS builds see the same file tree, with a NebulaOS-owned `USB/` mount point inside it.
- **Recovery**: immutable factory-seed copies (offline git bundles built at image-compile time) reseed the namespace automatically if it's ever wiped or found invalid, with no network dependency for the initial seed.
- **Memory resilience**: a two-layer swap (zram + a NebulaOS-owned disk swap file) plus a maintenance-safety gate and a deliberate OOM-priority hierarchy, closing a real OOM incident found live during this mission (`docs/NEBULAOS_MEMORY_RESILIENCE.md`).
- **Retention**: a namespace-restricted cleanup manager with a graduated disk-pressure response, adapted from a proven reference implementation on the same board family (`docs/NEBULAOS_RETENTION_POLICY.md`).
- **Naming**: NebulaOS branding replaces RosetteOS in new runtime/build code where it was safe and meaningful to do so, without rewriting git history or falsifying provenance comments (`docs/NEBULAOS_MUTABLE_RUNTIME_ARCHITECTURE.md` §3.8).

## 2. Phase-by-phase status

| Phase | Subject | Status | Primary reference |
|---|---|---|---|
| 1 | Investigation (build pipeline, RosetteOS naming footprint, existing mechanisms) | Complete | `NEBULAOS_MUTABLE_RUNTIME_ARCHITECTURE.md` §1 |
| 2 | Reproducibility checkpoint (toolchain ordering, overlay staleness) | Complete | `NEBULAOS_MUTABLE_RUNTIME_ARCHITECTURE.md` §3, §3.9 |
| 3 | `/usr/data/nebulaos` namespace creation and development-device cleanup | Complete | `NEBULAOS_MUTABLE_RUNTIME_ARCHITECTURE.md` §3.1-3.3; `S02nebulaos-namespace` |
| 4 | Offline factory-seed git bundles (Klipper, Moonraker) | Complete | `04-cross-compile-app-stack.sh`; `S04nebulaos-factory-seed` |
| 5 | Activation manager (bind-mount persistent-vs-immutable decisions) | Complete | `S05nebulaos-activate` |
| **Memory Resilience Gate** | zram + disk swap, OOM priorities, maintenance gate | Complete, live-qualified | `NEBULAOS_MEMORY_RESILIENCE.md` (full doc) |
| 6 | NebulaOS Klipper fork (extras committed in-tree) | Complete | `NEBULAOS_MUTABLE_RUNTIME_ARCHITECTURE.md` §2 |
| 7 | Writable Moonraker Python environment | Complete, live-qualified | `NEBULAOS_MEMORY_RESILIENCE.md` §8; `S56moonraker` |
| 8 | Update rollback orchestration + transaction state machine | Complete, live-qualified (two real bugs found and fixed) | `NEBULAOS_UPDATE_AND_ROLLBACK_DESIGN.md` §6; `nebulaos-update-supervisor.sh` |
| 9 | Retention/cleanup manager | Complete, live-qualified (floors measured; two real bugs found and fixed - closure mission) | `NEBULAOS_RETENTION_POLICY.md` |
| 10 | Moonraker `[update_manager]` configuration | Complete, live-qualified (config staleness + Klipper venv crash both found and fixed - closure mission) | `moonraker.conf`; `NEBULAOS_UPDATE_AND_ROLLBACK_DESIGN.md` §2 |
| 11 | RosetteOS → NebulaOS naming cleanup | Complete | `NEBULAOS_MUTABLE_RUNTIME_ARCHITECTURE.md` §3.8 |
| 12 | Full real-device qualification | Complete, live-qualified (all gaps closed - closure mission, 2026-07-27) | `NEBULAOS_PHASE12_QUALIFICATION.md` |
| **Closure** | RosetteOS removal, Mainsail rollback, Moonraker paired rollback, retention measurement | Complete, live-qualified | `NEBULAOS_UPDATE_AND_ROLLBACK_DESIGN.md`; `NEBULAOS_RETENTION_POLICY.md` §4-5; this report §3.10-17, §4 |

## 3. Real bugs found and fixed during this mission (live, not simulated)

Every one of these was found by testing against the real physical device, not caught by static review — recorded here as evidence of what "qualification" actually meant in practice, not a rubber stamp:

1. **No swap at all, kernel-level** — `CONFIG_SWAP` wasn't compiled in; a real `git clone` during factory-seed OOM-killed on a 208MB device with zero swap. Root-caused to the kernel config, not just missing userspace tools. (`NEBULAOS_MEMORY_RESILIENCE.md` §1-2)
2. **`swapon -p` silently no-op'd** — BusyBox's `CONFIG_FEATURE_SWAPON_PRI` wasn't enabled; the fstab `pri=` workaround also silently failed for the same reason. (`NEBULAOS_MEMORY_RESILIENCE.md` §5)
3. **`mv srcdir destdir` nesting bug** — moving a `.partial` seed directory into place nested it inside an existing destination instead of replacing it; needed two fix attempts (the first, `rmdir` first, held up in isolation but not on a real boot; the second, unconditional `rm -rf` first, held up both places). (`NEBULAOS_MEMORY_RESILIENCE.md` §6)
4. **`known-good.json` write-once guard never re-evaluated** — permanently recorded `"unseeded"` even after a later successful seed. (`NEBULAOS_MEMORY_RESILIENCE.md` §6)
5. **No NTP client at all** — clock permanently stuck at the post-reset default (not just briefly wrong at boot), permanently breaking real HTTPS certificate validation. (`NEBULAOS_MEMORY_RESILIENCE.md` §7)
6. **BusyBox `wget` has no real TLS certificate validation**, even with HTTPS support compiled in — a permanent tool limitation, now a documented policy (never rely on `wget` for HTTPS where authenticity matters; use `curl`/`git`/`python3` instead, each proven with positive and negative controls). (`NEBULAOS_MEMORY_RESILIENCE.md` §7)
7. **BusyBox `ip` has no `-json`/`-det` support at all** — Moonraker's own `machine.py` network poller failed every ~10s indefinitely; fixed by building the real `iproute2` package and disabling BusyBox's `ip` applet to remove install-order ambiguity over `/sbin/ip`. (`NEBULAOS_MEMORY_RESILIENCE.md` §8)
8. **Update-supervisor sampled health too soon after a restart**, racing Klipper's real 15-25s MCU-reconnect time and causing a false-positive rollback failure. (`NEBULAOS_UPDATE_AND_ROLLBACK_DESIGN.md` §6.4)
9. **Update-supervisor recorded a stale commit on the factory-fallback path**, causing state.json to drift out of sync with git's real state and risking a spurious re-validation loop. (`NEBULAOS_UPDATE_AND_ROLLBACK_DESIGN.md` §6.4)

**Closure mission (2026-07-27) — the same rigor applied to the four remaining gaps:**

10. **Linux bind mounts pin to the original inode, not the path name** — a "restored" Mainsail directory kept serving stale content via nginx after a directory-replace rollback, because the existing bind mount never followed the rename. A real, generally-applicable gap (affects any directory-replace operation on an active bind-mount source), not specific to this mission's own code. Fixed via an explicit remount step. (`NEBULAOS_UPDATE_AND_ROLLBACK_DESIGN.md`)
11. **`S02nebulaos-namespace`'s `create_layout()` never created `updates/mainsail`** — Mainsail's own state write silently failed every boot. Fixed by adding it to the mkdir list.
12. **A genuine pre-existing race in `S55klipper`/`S56moonraker`'s own `restart() { stop; start; }` pattern** — calling `start` immediately after `stop` can observe the old process still mid-shutdown and silently refuse to launch. Not introduced by this mission, but the rollback mechanism's own restart calls were the first thing to reliably trigger it under real I/O load. Fixed via `safe_stop_start()` (poll for genuine exit before starting) in the update-supervisor.
13. **BusyBox's `rm -f` cannot remove a directory at all** (exit 1, "is a directory") — every retention-manager deletion of a directory-based backup had silently done nothing for the entire mission, while its own log claimed success. Fixed via `rm -rf` for directories plus a post-delete existence check. (`NEBULAOS_RETENTION_POLICY.md` §5)
14. **Retention's `clean_obsolete_versions()` treated `last-known-good`/`last-known-good-env` as prunable** — the single, continuously-updated backup the rollback mechanism itself depends on, not an old version to rotate away. Fixed by scoping pruning to only `failed-*` evidence directories. (`NEBULAOS_RETENTION_POLICY.md` §5)
15. **`moonraker.conf` is seeded once at first boot and never re-synced** — the live device's actual copy had gone stale (missing `[webcam Nebula]` and all of Phase 10's `[update_manager]` sections, still headed "RosetteOS"), meaning Phase 10's design had never actually been live-verified until this closure mission caught it via `/machine/update/status` returning 404. Resolved by pushing the current source config to the device; a per-device staleness gap, not a design flaw, and not something a generic migration framework was warranted for (no deployed user base to protect).
16. **Moonraker's `update_manager` hardcodes the Klipper slot's virtualenv auto-detection from Klippy's own reported executable, with no config override available** — running Klippy under bare `/usr/bin/python3` made Moonraker infer a bogus venv root (`/usr`) and crash the *entire* update_manager component (Moonraker's and Mainsail's entries included). Fixed by giving Klippy a real `--system-site-packages` venv and bind-mounting it onto `/root/klippy-env` — the exact path Moonraker's own `klippy_connection.py` hardcodes as its bootstrap default, required for update_manager to succeed on the very first Moonraker start rather than after a lucky second restart.
17. **`flash-spare-slot.sh`'s "refuse to write the live root" safety check was dead code** — it compared `/proc/mounts`' root device against the target partition, but this device reports its root source as the literal string `/dev/root` (which doesn't even exist as a file), so the comparison could never match. Went unnoticed all mission because every prior flash happened to run while genuinely booted from stock; the first time it ran again after the device had permanently moved to running custom, nothing stopped it from overwriting the live, currently-executing rootfs — producing a cascade of segfaults across running processes and requiring a manual power cycle. The write itself completed and was verified byte-correct afterward, but the check needed to actually work: fixed to parse the real root device from `/proc/cmdline`'s `root=` parameter.

## 4. Known, honestly-scoped gaps (not silently dropped) — all four resolved by the closure mission (2026-07-27)

1. **~~Mainsail update rollback is not implemented.~~ RESOLVED.** The update-supervisor now maintains a continuously-refreshed `last-known-good` snapshot of Mainsail's extracted release directory (staging+rename atomic replace), restored automatically on a failed health check. Live-verified with a real bad-release test, including the bind-mount-desync bug this uncovered (§3.10). (`NEBULAOS_UPDATE_AND_ROLLBACK_DESIGN.md`)
2. **~~Moonraker's writable venv is not versioned independently of the source tree.~~ RESOLVED.** A paired `last-known-good-env` backup is now maintained alongside the source snapshot and always restored together, never independently — a mismatched source/venv pair is explicitly rejected. Live-verified with a real bad-update test, including the restart race-condition bug this uncovered (§3.12). (`NEBULAOS_UPDATE_AND_ROLLBACK_DESIGN.md`)
3. **~~Retention policy's disk-pressure floor values were not re-validated against real-device measurement.~~ RESOLVED.** Real measured steady-state (~466MB) and peak temporary usage (~55-80MB, Moonraker paired venv restore) confirm the original proposed 800MB/300MB floors were already well-justified, not adapted guesses. Two real retention-manager bugs found and fixed in the process (§3.13-14). (`NEBULAOS_RETENTION_POLICY.md` §4-5)
4. **~~`/usr/data/rosetteos` was deliberately left in active use.~~ RESOLVED.** The two real remaining runtime dependents (`S01persistent-datastore`'s `DATA_ROOT`, `S39wifi`'s `CONF`) were relocated to `/usr/data/nebulaos/...`, the one-time `S02` migration function was removed entirely (no deployed device population needing it), and `/usr/data/rosetteos` itself was removed and proven never recreated across two consecutive cold boots.

## 5. Frozen functionality — reconfirmed intact, not just assumed

Across every reboot/reflash cycle this mission performed (dozens), the following were reconfirmed working with zero regression: webcam (ustreamer/nginx proxy), USB gcode mounting, printer safety invariants (heater targets, print state, homed axes always queried read-only before any disruptive action), the existing whole-image A/B rootfs rollback (`S00revert-safety`/`S99confirm-good`/OTA marker), and WiFi/network connectivity.

## 6. Final known-good tags

- `nebulaos-mutable-runtime-baseline-2026-07-27` — the original baseline, left unchanged (never retagged or force-moved). Every phase in §1-3 (bugs 1-9) live-qualified against the real device on the exact image that tag's manifest describes.
- `nebulaos-mutable-runtime-complete-2026-07-27` — the closure tag, created after all four §4 gaps were resolved and live-verified, including the two additional real bugs found while doing so (§3.16-17) and their fixes. See `NEBULAOS_PHASE12_QUALIFICATION.md` for the full closure-mission qualification record.

## 7. Auto-updates-camera-complete mission addendum (2026-07-28)

18. **The factory seed's synthetic wrapper commit permanently blocked real Klipper/Moonraker updates.** `S04nebulaos-factory-seed` flattened each vendor checkout into a single synthetic orphan commit before bundling (a real `git bundle` of the shallow vendor clones fails to clone), which shared no ancestry with the real GitHub history — Moonraker's `git merge-base --is-ancestor HEAD origin/<branch>` check could therefore never pass, permanently setting `diverged=true` / `is_valid=false` on every freshly-seeded device regardless of network or clock state. A second, independent mismatch compounded it: Klipper's production branch (`nebulaos`) didn't match Moonraker's hardcoded reserved-slot `primary_branch` default (`master`), which is not configurable. Fixed by replacing the flatten+bundle seed with a real-history tar archive (preserving Klipper's real shallow boundary and Moonraker's real full history) and pushing Klipper's already-published commit as a genuine `master` branch on the same fork. Full root-cause evidence and fix details: `docs/NEBULAOS_MOONRAKER_UPDATE_AND_CAMERA_ANALYSIS.md` §28. Live qualification tracked in `NEBULAOS_PHASE12_QUALIFICATION.md` §11.

## 8. Mainline print-controls mission addendum (2026-07-29)

19. **Confirmed `S01persistent-datastore`'s `printer_data` bind mount (this document's §1.2 architecture, since relocated from the legacy `/usr/data/rosetteos` root to `/usr/data/nebulaos` per §3.8/item 4 above) still correctly backs `/opt/printer_data`, and that Klipper/Moonraker/Moonraker's own file-manager API all independently agree on `/opt/printer_data/config` as the single canonical config directory.** Prompted by a report of Mainsail's Config Files page appearing empty. Verified at the inode level (a test file created through the real Moonraker file-manager API showed the identical inode number under both the persistent path and the bind-mounted runtime path) and via the real process command lines (`ps`/`/proc/<pid>/cmdline`), not assumed from configuration alone. No architecture change was needed - everything already matched this document's own design. New build-time regression guards (`06-verify.sh`) now check `S55klipper`/`S56moonraker`'s launch arguments and `S01persistent-datastore`'s bind-mount/backing-root lines directly, so a future divergence would be caught before shipping. Full investigation: `docs/NEBULAOS_FRONTEND_PRINT_CONTROLS.md` §7.
