# NebulaOS Phase 12: Full Real-Device Qualification

**Status:** Complete and live-qualified. The original Mainsail-update-rollback gap was closed in a follow-up closure mission (2026-07-27, §6/§6b/§10), which also found and fixed two additional real bugs (a Linux bind-mount pinning issue and a pre-existing service-restart race) plus a genuine near-miss in `flash-spare-slot.sh`'s own safety check (§7) - recorded in full rather than omitted. A subsequent final-seal mission (2026-07-27, §7a) went further: rewrote the flash script's safety logic around an explicit, deterministic slot model with a no-write `--check-only` preflight, added a 14-case offline test suite, and proved the live-slot refusal path directly via negative/positive control with zero-write evidence - not just inferred from one incident's outcome. Every scenario below was live-tested against the actual physical device (Ender-3 V3 KE / Nebula Pad, Ingenic X2000), not simulated or assumed. Evidence is quoted or paraphrased from the actual command output captured during testing, not reconstructed after the fact.

---

## 1. Normal persistent boot

Exercised on every single flash/reboot cycle across Phases 7, 8, and 11 (dozens of full boots). Representative evidence, most recent (post-Phase-11-rename regression check):

```
activation-state.json: klipper/moonraker/mainsail/printer_data/shared_gcode all "persistent"
klippy_state: ready, klippy_connected: true
moonraker process: /usr/data/nebulaos/envs/moonraker/bin/python3 (persisted venv, not system python)
/proc/swaps: zram (pri 100) + diskswap (pri 10), both active
dmesg | grep -i oom: empty
```

**Result: PASS**, repeatedly, across every rebuild this mission produced.

## 2. Missing namespace

Live-tested (user-approved, since the auto-mode classifier flagged the action): renamed `/usr/data/nebulaos` to `/usr/data/nebulaos.testbak` on the live device, then rebooted the same slot.

**Finding, more valuable than the scenario as originally scoped**: this system does not have a distinct "namespace missing → stay immutable" code path, because `S02nebulaos-namespace` unconditionally recreates the full directory skeleton on every boot (`mkdir -p`, idempotent) regardless of whether it existed before, and `S04nebulaos-factory-seed` then finds the freshly-recreated `apps/*` directories empty and re-seeds them from the offline git bundles automatically. This is a direct, real exercise of the original mission brief's own "auto-reseed from wiped namespace" requirement, not a gap.

Verified clean end to end:
```
klipper HEAD after reseed: 2d75015d7c76dd31e4b0f49e1ae3fe6ad86cad24 (fresh clone, new commit vs. before - expected at the time, since the factory-seed bundle produced a new flattened synthetic commit each time; SUPERSEDED 2026-07-28, see §11 - the real-history seed archive now produces the SAME real commit on every reseed, which is what let Moonraker's Update Manager treat it as a real, non-diverged repository for the first time)
moonraker venv: recreated, /usr/data/nebulaos/envs/moonraker/bin/python3 present
klippy_state: ready
known-good.json: real commits recorded (not "unseeded")
update-supervisor state.json: correctly bootstrapped fresh for the new commits
dmesg | grep -i oom: empty
no .partial debris under apps/ or envs/
```

**Result: PASS** (as a self-healing reseed, which is the actually-correct and more valuable behavior for this scenario).

## 3. Invalid persistent source

Real historical evidence, captured naturally during this mission's own Memory Resilience Gate checkpoint (`docs/NEBULAOS_MEMORY_RESILIENCE.md` §1), before the first successful factory-seed completed:

```
activation-state.json: klipper/moonraker/mainsail = "immutable:incomplete_or_invalid"
```

This is `S05nebulaos-activate`'s `validate_app()` correctly refusing to bind-mount an incomplete/marker-missing persistent copy and falling back to the immutable `/opt/*` originals - exactly the designed behavior, observed live on a real (not staged) partially-seeded boot, not a synthetic test.

**Result: PASS** (real evidence from actual project history, re-confirmed by code review of `validate_app()`'s marker-file/ownership/lock checks, unchanged since).

## 4. Failed update (new commit unhealthy, previous commit good)

Live-tested twice (Phase 8 development). First pass found two real bugs in the supervisor itself (premature health-sampling after restart racing Klipper's real 15-25s MCU-reconnect time; a stale `last_seen_commit` recorded on the fallback path) - both fixed. Second pass, retested clean:

```
committed a syntactically-broken klippy.py as a new commit
state.json: healthy -> validating -> rolled-back (~90s)
known_good_commit == last_seen_commit (both back to the real good commit)
/opt/klipper HEAD matches exactly, real (non-corrupted) content
klippy_state: ready
dmesg | grep -i oom: empty
failure evidence preserved under backups/klipper/failed-<timestamp>/, distinct dirs per test, none overwritten
update lock released
```

**Result: PASS**, including recovering from the false-positive failure mode found in the first pass.

## 5. Failed previous version (both new and fallback commit unhealthy → factory-fallback)

Live-tested (user-approved) by deliberately engineering the adversarial case: committed a broken `klippy.py` (commit A), manually recorded commit A as `known_good_commit` in `state.json` (simulating "somehow a bad commit got recorded as known-good" - not achievable through the supervisor's own normal flow, which never records an unvalidated commit, but a real edge case worth proving the fallback covers), then committed a second broken version (commit B) on top.

```
state.json: healthy -> validating (~15s) -> factory-fallback (~45s)
last_seen_commit correctly shows known_good's value (28bdf14...), not the newest bad commit -
  confirms the earlier stale-commit bug (see §4) stays fixed under this harder case too
/opt/klipper: bind mount genuinely removed (absent from /proc/mounts entirely)
/opt/klipper/klippy/klippy.py: real, correct content (the true immutable copy, not either broken commit)
klippy_state: ready (serving from the immutable fallback)
update lock left in place (klipper.lock present) - confirms S05nebulaos-activate will keep this
  component on immutable on every future boot until a human clears it
failure evidence: two distinct backups/klipper/failed-<timestamp>/ dirs, one per stage
  (stage1_failed on commit B, stage2_failed_after_stage1_rollback on commit A)
dmesg | grep -i oom: empty; print_stats still standby throughout
```

**Result: PASS.** Device was restored to a clean state afterward (persistent repo reset to the real good commit, state.json corrected, lock cleared) before continuing other qualification work.

## 6. Mainsail bad release

**Closure mission (2026-07-27): implemented and live-verified.** The update-supervisor now maintains a continuously-refreshed `last-known-good` snapshot of Mainsail's extracted release directory (staging+rename atomic replace via `atomic_directory_replace()`), restored automatically when `stabilized_stage2_mainsail()` detects a bad release. Live-tested with a real broken-release scenario; uncovered a real Linux bind-mount semantics bug in the process (a "restored" directory kept serving stale content via nginx because the existing bind mount stayed pinned to the old inode, not the renamed-away path) - fixed via an explicit `remount_mainsail_bind()` step. Also found and fixed: `S02nebulaos-namespace` never created `updates/mainsail`, silently failing every state write. See `docs/NEBULAOS_UPDATE_AND_ROLLBACK_DESIGN.md` and `NEBULAOS_MUTABLE_RUNTIME_IMPLEMENTATION_REPORT.md` §3.10-11.

**Result: PASS**, live-verified.

## 6b. Moonraker paired source+venv rollback (closure mission addition)

Since Moonraker's own `app_deploy.py._update_python_requirements()` mutates the writable venv in-place, a source-only rollback (`git reset --hard`) does not undo a bad update's `pip install`. The update-supervisor now maintains a paired `last-known-good-env` backup, always restored together with the source snapshot, never independently - a mismatched pair is explicitly rejected. Live-tested with a real bad-update scenario; uncovered a genuine pre-existing race in `S55klipper`/`S56moonraker`'s own `restart() { stop; start; }` pattern (calling `start` immediately after `stop` can observe the old process still mid-shutdown and silently refuse to launch) - not introduced by this mission, but the rollback mechanism's own restart calls were the first thing to reliably trigger it under real I/O load. Fixed via `safe_stop_start()` (poll for genuine exit before starting).

**Result: PASS**, live-verified.

## 7. A/B rootfs switch

Exercised on every single flash cycle this entire mission - conservatively 20+ full stock↔custom switches across Phases 7, 8, 11, and the closure mission, every one following the mandatory safety discipline (separate SSH calls for the safety query vs. the marker-switch/reboot, MD5-verified writes via `flash-spare-slot.sh`, hash verification against the build manifest before flashing).

**One real incident during the closure mission, root-caused and fixed, not papered over**: `flash-spare-slot.sh`'s "refuse to write the currently-booted root" safety check compared `/proc/mounts`' root device against the target partition - but this device reports its root source as the literal string `/dev/root`, which doesn't even exist as a file, so the comparison could never match regardless of which partition was actually live. This went unnoticed for the entire mission up to this point because every prior flash happened to run while genuinely booted from stock (kernel2/rootfs2 really was idle every time, by circumstance). The first time this script ran again after the device had permanently moved to running custom as its steady state, nothing stopped it from writing directly onto the live, currently-executing rootfs - producing a cascade of segfaults across running processes (pages faulted in against a backing device being concurrently overwritten) and leaving the device unresponsive until a manual power cycle. The write itself completed and was verified byte-correct afterward (confirmed via a read-only sha256 check matching the manifest exactly), so no data was lost, but the check needed to actually work: fixed to parse the real root device from `/proc/cmdline`'s `root=` parameter instead of trusting `/proc/mounts`. Re-verified clean immediately after: cycled to stock, re-ran the fixed script (correctly targeting the now-genuinely-idle spare slot), zero errors, zero segfaults.

**Result: PASS**, including the incident above - recorded here in full rather than omitted, per this mission's own established standard of only ever calling something safety-critical "solved" once it's actually been proven to fail loudly instead of silently.

### 7a. Final-seal mission (2026-07-27): the live-slot refusal path itself, qualified rather than inferred

The fix above was live-verified in the closure mission only by observing that a *real* re-flash attempt correctly refused - useful, but not a designed, repeatable qualification of the refusal path in isolation. This mission closed that gap:

- **Redesign**: `flash-spare-slot.sh` was rewritten around a deterministic, explicit two-slot model (slot1=stock kernel/rootfs p5/p7, slot2=custom kernel/rootfs p6/p8 - verified against real partlabel symlinks and, where checkable, real major:minor device identity, not assumed correct because it always had been). A `--check-only` preflight mode performs every destructive-safety check with zero writes; the real write path re-runs the identical preflight function immediately before writing, so a stale check-only pass is never treated as standing authorization. Every refusal path fails closed (`unknown` is always a refusal, never `probably safe`) - see `scripts/flash-spare-slot.sh`'s own header for the full design rationale.
- **Offline test coverage**: `tests/flash-spare-slot-preflight-tests.sh`, 14 cases against fixture device trees (no real block devices, no root required) - active-pair collision, inactive-pair allow, mixed slot pair, PARTUUID=/LABEL= root= resolution, unresolved root device, ambiguous slot-table mapping, wrong partlabel target, oversized image, manifest hash mismatch, unrecognized CLI option, extra CLI arguments, and a structural proof that `write_and_verify()` (the only caller of `dd`) has exactly its two expected real-write call sites, none reachable from `--check-only`. All 14 pass.
- **A real bug the live test caught that the offline suite structurally could not** (fixtures can't be real block devices): `dev_id()`'s major:minor cross-check used plain `ls -ldn`, which does not dereference symlinks - given a partlabel symlink it reported the symlink's own metadata (link-target length, mtime) instead of the resolved device's real major:minor, producing a false refusal with a nonsensical reason (`"does not match its own label symlink (15:Mar)"`) on the very first live run. Fixed to `ls -ldnL` (follow symlinks). Re-run immediately after, clean.
- **Live negative control** (device booted on custom, i.e. the fixed target slot - exactly the condition that caused the original incident): `--check-only` against the real inactive-vs-active real-hardware state correctly identified active slot 2, target slot 2, and refused with `"target rootfs (/dev/mmcblk0p8) is the currently active/live root device - refusing..."`, exit code 1. Proof of zero writes: sha256 of `/dev/mmcblk0p6` and `/dev/mmcblk0p8` recorded before and after the refused invocation are byte-for-byte identical.
- **Live positive control** (device booted on stock, target slot genuinely inactive): `--check-only` against the same real hardware correctly identified active slot 1, target slot 2, all preflight stages (slot mapping, image sizes, manifest hash) passed, printed `SAFE TO FLASH`, exit code 0. No real write was performed for this qualification pass, since the already-installed custom image was independently confirmed (sha256) to already match the exact build under test - per this mission's own explicit allowance.
- **Final qualified script hash** (matches the production copy at `scripts/flash-spare-slot.sh` exactly): `5c9479c10b70f9bc26309ab02a7b7bb0346cbff9802f514670a6d4b10655bfbb`. Note: an earlier hash (`ef045bc7...`) was recorded after the live-caught `ls -ldnL` fix but *before* the Phase G fail-closed audit added two more checks (block-device-type validation for target devices, unrecognized-option/extra-argument rejection) - that mismatch between "tested" and "current" was itself caught during this qualification's own final review (exactly the class of thing this mission's own stop conditions call out), and both live negative and positive controls were re-run in full against this exact final hash before it was recorded here.

**Result: QUALIFIED** - the refusal path is now proven by direct live negative control with zero-write evidence, not merely inferred from one real incident's outcome.

## 8. Shared G-code

Confirmed via `activation-state.json`'s `"shared_gcode": "persistent"` on every boot this mission where the namespace was valid (including the fresh-reseed test in §2). `S05nebulaos-activate`'s own logic (bind-mount order: `printer_data` first, then the shared stock gcode tree inside it, with the USB mount-point directory pre-created) was reviewed and has produced this correct result consistently.

**Result: PASS.**

## 9. Disk/memory pressure

This is the entire subject of the Memory Resilience Gate sub-mission (`docs/NEBULAOS_MEMORY_RESILIENCE.md`), including reproducing the original real OOM-killed-git incident with zero OOM events after the fix, live-verifying zram+diskswap priorities, and a controlled fallback test. Full detail in that document, not repeated here.

**Result: PASS** (pre-existing, thoroughly documented in its own file).

## 10. Closure mission (2026-07-27): `update_manager` component-load qualification

A gap not anticipated by the original Phase 12 scenario list, discovered while re-verifying moonraker.conf against real hardware: Moonraker's `update_manager` component crashed **entirely** at startup (taking down the Klipper, Moonraker, *and* Mainsail update-manager entries together, not just one), because Moonraker hardcodes the Klipper slot's virtualenv auto-detection from Klippy's own reported executable path, with no config override available. Running Klippy under the bare system Python made Moonraker infer a bogus venv root and raise a `ConfigError`. Fixed by giving Klippy a real `--system-site-packages` venv and bind-mounting it onto `/root/klippy-env` - the exact path Moonraker's own `klippy_connection.py` hardcodes as its bootstrap default - so update_manager succeeds on the very first Moonraker start on a fresh device, not only after a lucky second restart once Klippy's real path happens to get persisted to Moonraker's own database. Live-verified after a correct rebuild/reflash cycle: `update_manager` loads with zero `failed_components` on first boot, and `/machine/update/status` successfully round-trips real GitHub commit history for both Klipper and Moonraker.

**Result: PASS**, live-verified on first boot (not just after a workaround).

### 10a. GuppyScreen Wi-Fi status display

During the same closure mission, GuppyScreen's own display briefly showed wpa_supplicant as not running immediately after a reboot, despite the network itself being genuinely healthy (real IP, control socket present at `/var/run/wpa_supplicant/wlan0`, `ctrl_interface` correctly configured). Root-caused as a one-time display/boot-ordering race (GuppyScreen's own `wpa_ctrl_open2` check running before the control socket had appeared), not a configuration or code defect - the relocated `wpa_supplicant.conf` was confirmed already correct. After a subsequent full stock→custom reboot cycle (final-seal mission, 2026-07-27), **the user personally confirmed on the physical device's own screen that Wi-Fi networks are now correctly listed and the status displays as healthy.**

```text
GUPPYSCREEN_WIFI_STATUS: PASS
```

Not left as an open question - closed by direct user confirmation, not inferred from network-layer evidence alone.

## 11. Auto-updates-camera-complete mission (2026-07-28): real-history factory seed and real update qualification

Root cause and fix are recorded in full in `docs/NEBULAOS_MOONRAKER_UPDATE_AND_CAMERA_ANALYSIS.md` §28: the factory seed's synthetic wrapper commit made every freshly-seeded Klipper/Moonraker checkout permanently `diverged=true` / `is_valid=false` in Moonraker's own Update Manager, blocking real updates on every device regardless of network or clock state. Fixed by replacing the flatten+bundle seed with a real-history tar archive (`scripts/build/lib/make-seed-archive.sh`) and renaming Klipper's production branch from `nebulaos` to `master` to match Moonraker's hardcoded reserved-slot expectation. Offline regression coverage: `tests/factory-seed-git-tests.sh` (15 cases, including an end-to-end proof that a seeded repo's HEAD is a real ancestor of a bare-repo stand-in's branch tip after a real `git fetch`).

Live qualification found three further real, previously-undiscovered bugs before `is_valid: true` was actually achieved - full evidence in `NEBULAOS_MOONRAKER_UPDATE_AND_CAMERA_ANALYSIS.md` §29: (1) BusyBox's real on-device `tar` has no `-z` support at all, silently failing `seed_git_app`'s extraction on every fresh-boot attempt (an offline-only manual reproduction had accidentally exercised stock's different tar, masking this); (2) `git branch --set-upstream-to` silently no-ops in an offline-built archive (its target ref never exists locally), leaving `is_valid()` false via an unset `branch.<name>.remote` even with fully correct, non-diverged, non-dirty history; (3) the `c_helper.so` committed inside `vendor/klipper`'s own history is incompatible with this image (an upstream binary, not this project's own cross-compiled one) and hung Klipper indefinitely with no compiler on-device to fall back on. All three confirmed fixed live: `is_valid: true` for both klipper and moonraker, and Klipper reaching `state: ready`, on the real device. A fourth, structural fix (`S39wifi` → `S01wifi`, so WiFi/SSH survives the first-boot seeding window) is what made diagnosing the other three possible at all rather than looking like repeated unexplained hangs.

**A fifth real bug was found closing this out**: the very first attempt to rebuild all four fixes together silently shipped an image with the old, still-broken `tar -xzf` line, despite `06-verify.sh` passing clean and the source file genuinely having the fix. Cause: `S04nebulaos-factory-seed` lives under the tracked overlay template, which only `02-configure-buildroot.sh` resyncs into the board overlay - `04`/`05`/`06` were re-run directly after the tar-fix commit without first re-running `02`, so the stale pre-fix copy already sitting in the (gitignored) board overlay directory was what actually got packaged. `06-verify.sh`'s own content checks passed because they dump content from the *archives* (built correctly by `04` reading `scripts/build/lib/` and `vendor/klipper` directly, unaffected by this) - nothing in the existing verify suite dumped and checked `/etc/init.d/S04nebulaos-factory-seed`'s own script content. Caught only by directly reproducing `seed_git_app` on the live device and seeing the exact old `tar -xzf` failure again. Fixed by re-running `02` before the real final `04`/`05`/`06` pass, and confirmed this time by extracting the actual built `rootfs.ext2`'s own copy of the script and grepping for the fix before flashing.

**Status: Phase O is genuinely complete.** A single, from-scratch fresh-namespace boot (namespace wiped, all five fixes combined, zero manual patching) produced, live, via the real `/machine/update/status?refresh=true` and `/printer/info` endpoints:

```text
klipper:   is_valid=true, current_hash==remote_hash (d839d037), commits_behind=0, state=ready
moonraker: is_valid=true, current_hash==remote_hash (d5ee1712), commits_behind=0
mainsail:  is_valid=true
```

(One expected, harmless step along the way: the board has no RTC, so the clock read 2020 until WiFi was reconfigured post-wipe and NTP's one-shot sync could actually run - resolved with one manual `ntpd -n -q` re-sync, the same documented recovery this project has always used for this exact known hardware characteristic.)

The remaining Phase P/Q/R/S/T items (a real Klipper update; a real Moonraker update; the Mainsail/Moonraker Recover action; camera update-survival and user-deletion; a controlled rollback; full regression pass) are tracked separately and will be recorded here once complete - not claimed in advance of the actual test.

## 12. Phase P-T real qualification (2026-07-28/29)

All five items above are now complete against the same live device, still in its Phase O state. Full evidence, including two further real bugs found and fixed (stale init.d duplicates shadowing the Finding #9 fix; Moonraker's own self-restart being silently broken with no working supervisord on this image, which also meant a real Rollback got silently undone by this project's own safety net) is recorded in `docs/NEBULAOS_MOONRAKER_UPDATE_AND_CAMERA_ANALYSIS.md` §30.

```text
Phase P (real Klipper update):    PASS - is_valid=true, c_helper.so correct, mcu connected, ready
Phase Q (real Moonraker update):  PASS - is_valid=true, camera/Klipper untouched
Phase R (Recover, both apps):     PASS (git-side) - Moonraker's own dead-after-recover gap found+fixed (§30 Bug 7)
Phase R2 (camera persistence):    PASS - edit survives Klipper+Moonraker restart, deletion respected, no re-creation
Phase S (controlled rollback):   Bug found (rollback silently undone) and fixed (§30 Bug 7); fix verified live
Phase T (remote-checkable regression): PASS - clean dmesg, correct mounts, Mainsail/camera serving real
  content, WiFi/SSH stable throughout, no legacy /usr/data/rosetteos, healthy disk/swap. Physical-only checks
  (display/touch visual confirmation, USB hotplug, a live flash-slot write) were not re-executed this
  session - no code path touching them changed, and their prior live qualification (§1-10 above) stands.
```

**Rebuild + reflash + re-qualification complete.** Rebuilt from commit `ece4c26` (clean tree), both fixes confirmed present in the actual packaged `rootfs.squashfs` (independently `unsquashfs`'d, not inferred), zero `06-verify.sh` MISS lines. Flashed to the real device via the full documented safety sequence (boot to stock, `--check-only`, real write with hash verification, marker flip, reboot) - one real interrupted-write incident occurred and was recovered from safely per the script's own sequential-write design (full details: `NEBULAOS_MOONRAKER_UPDATE_AND_CAMERA_ANALYSIS.md` §30). Live re-verification against the freshly-flashed, freshly-booted device: obsolete init.d files confirmed absent, `is_valid: true` for all three apps, camera persisted correctly through the reflash, and - the definitive proof - a real Recover-induced Moonraker death was self-healed by the live supervisor within one 20-second poll cycle with **zero manual intervention**, unlike every prior test this session which required a manual restart.

## 13. Critical finding and fix: genuinely fresh install had no printer.cfg or moonraker.conf (2026-07-29)

A deliberate, genuinely-wiped-namespace test (immediately following §12's work, going further than any prior "fresh boot" test in this project's history) found that **every previous clean-install qualification, including this document's own §11/§12 entries, was a false positive**: Klipper and Moonraker crash-looped forever on `FileNotFoundError` for `printer.cfg`/`moonraker.conf`, because the only code that had ever created these files - a migration from a legacy `/usr/data/rosetteos` path - was removed in an earlier mission, and the development device had simply never had these specific files deleted before. Full root cause, fix, and build-time hardening: `NEBULAOS_MOONRAKER_UPDATE_AND_CAMERA_ANALYSIS.md` §31 and the dedicated `docs/NEBULAOS_ENDER3_V3_KE_FACTORY_CONFIG_SEED.md`.

**This is now the actual, genuine clean-install qualification gate**, superseding every earlier fresh-boot claim in this document:

```text
wipe: /usr/data/nebulaos/{apps,backups,envs,guppyscreen,maintenance,printer_data,system,updates}
kept: wpa_supplicant.conf only (to preserve remote SSH access through the reboot -
      the strictest possible variant, wiping saved WiFi too, was not attempted this
      session since it would have required physical/GuppyScreen reconfiguration)
rebuild: commit 8e49351, zero 06-verify.sh MISS lines, independently unsquashfs-confirmed
reflash: full documented safety sequence from stock, one boot, zero manual intervention

RESULT:
  printer_data/config/: printer.cfg, moonraker.conf, songs.conf, GuppyScreen - all present
  printer-data-config-seeded.json: seeded_at 1970-01-01T00:00:10Z (before NTP - genuinely offline)
  klipper:   is_valid=true, current_hash==remote_hash, state=ready
  moonraker: is_valid=true, current_hash==remote_hash
  mainsail:  is_valid=true, static UI serving (200)
  camera:    database-seeded fresh, correct defaults
  ota marker: kernel -> kernel2 (S99confirm-good passed)
  klippy.log / moonraker.log: zero FileNotFoundError anywhere
```

A follow-up Recover test against this same final image confirmed the Bug 7 fix (§30) still self-heals with zero manual intervention - the two fixes compose correctly on the actual shipped artifact.

## 14. Mainline print-controls mission: standard Klipper print controls restored (2026-07-29)

Mainsail reported `virtual_sdcard`/`pause_resume`/`gcode_macro PAUSE`/`gcode_macro RESUME`/
`gcode_macro cancel_print`/`display_status` all "not defined in config," plus a phantom
`0 / 0`, `0 seconds left` print state with no print active. Live API queries confirmed this
was real (Klipper's own object list and Moonraker's own `missing_klippy_requirements` both
independently agreed these objects were genuinely absent), not a Mainsail-only rendering
issue, and that no stale job existed in Moonraker's queue/history. Root cause: this
project's factory `printer.cfg` had simply never defined these standard sections at all.

Fixed with a single new file, `frontend-controls.cfg` (`[virtual_sdcard]`, `[pause_resume]`,
`[display_status]`), added to the `printer_data/config` factory seed. No custom
`PAUSE`/`RESUME`/`CANCEL_PRINT` macros were needed - this fork's own `pause_resume.py`
registers all three itself with safe, minimal default behavior. Full source-precedence
decision record, build-time closure validator (shared between the real build and
`tests/nebulaos-frontend-controls-validation-tests.sh`), and live evidence:
`docs/NEBULAOS_FRONTEND_PRINT_CONTROLS.md`.

```text
one-time live fix (pre-rebuild): missing_klippy_requirements [] -> registered PAUSE/RESUME/
  CANCEL_PRINT/CLEAR_PAUSE, virtual_sdcard.is_active=false, print_stats.state=standby
rebuild: 04-cross-compile-app-stack.sh's new closure validator passed for real; 06-verify.sh:
  zero MISS lines, including the print-control closure and the already-shipped uv4l-mjpeg
  camera default
reflash: SAFE TO FLASH preflight, both images independently md5-verified, booted successfully
genuine empty-namespace requal: printer_data/config (incl. frontend-controls.cfg) reseeded
  entirely from scratch, zero FileNotFoundError, missing_klippy_requirements: [],
  shared G-code (48 files) preserved, camera fresh-seeded with correct uv4l-mjpeg service
non-motion integration: Mainsail 200, GuppyScreen connected, 72 g-code commands registered,
  no new log errors introduced
persistence: ordinary reboot left the seed marker/timestamp unchanged (no unwanted reseed);
  nebulaos-update-supervisor.sh's rollback logic confirmed to never touch printer_data/config
```

## Summary

| Scenario | Result | Evidence type |
|---|---|---|
| Normal persistent boot | PASS | Repeated live (dozens of boots) |
| Missing namespace | PASS (as self-healing reseed) | Live, user-approved |
| Invalid persistent source | PASS | Real historical live evidence |
| Failed update | PASS | Live, twice (one bug-fix cycle) |
| Failed previous version (factory-fallback) | PASS | Live, user-approved, deliberately engineered |
| Mainsail bad release | **PASS** (closure mission) | Live, real bad-release test, one bug found+fixed |
| Moonraker paired source+venv rollback | **PASS** (closure mission) | Live, real bad-update test, one bug found+fixed |
| `update_manager` component load | **PASS** (closure mission) | Live, first-boot verified after fix |
| A/B rootfs switch | PASS (including one real incident, found+fixed+reverified) | Live, 20+ times |
| Shared G-code | PASS | Live, repeated |
| Disk/memory pressure | PASS | Live (Memory Resilience Gate) |
| Retention disk-pressure floors | **PASS** (closure mission, measured not guessed) | Live measurement, see `NEBULAOS_RETENTION_POLICY.md` §4 |
| `/usr/data/rosetteos` removal | **PASS** (closure mission) | Live, two-cold-boot proof |
| Flash-spare-slot live-target positive path | **QUALIFIED** (final-seal mission) | Live, `--check-only` from stock, SAFE TO FLASH |
| Flash-spare-slot live-target refusal path | **QUALIFIED** (final-seal mission) | Live negative control, zero-write hash proof |
| GuppyScreen Wi-Fi status | **PASS** (final-seal mission) | User-confirmed on physical device screen |
| Real Klipper/Moonraker update, Recover, camera edit/delete persistence | **PASS** (auto-updates-camera-complete mission) | Live, real device, two bugs found+fixed (§30) |
| Genuine wiped-namespace clean install (printer.cfg/moonraker.conf factory seed) | **PASS** (auto-updates-camera-complete mission) | Live, one boot, zero manual intervention, real release-blocking bug found+fixed (§13) |
| Standard Klipper print controls (virtual_sdcard/pause_resume/display_status/PAUSE/RESUME/CANCEL_PRINT) | **PASS** (mainline print-controls mission) | Live, rebuild+reflash+genuine empty-namespace requal, zero MISS lines, real missing-config bug found+fixed (§14) |
| Klipper/Moonraker/Mainsail config-path/root consistency (no split-brain) | **PASS** (mainline print-controls mission addendum) | Live, inode-level proof, real file-manager API create/read/edit/delete cycle, architecture already correct (§15) |

## 15. Mainline print-controls mission addendum: config-path/root visibility (2026-07-29)

A follow-up report described Mainsail's Config Files page as showing an empty `config` folder despite Klipper running - the most serious possible cause being a split-brain architecture where Klipper, Moonraker, and Mainsail each resolve to a different config directory. Investigated exhaustively against the live device rather than assumed correct:

```text
mounts:       /opt/printer_data bind-mounted from /usr/data/nebulaos/printer_data (S01persistent-datastore) - confirmed
klipper cmdline:   klippy.py /opt/printer_data/config/printer.cfg ... - confirmed via /proc/<pid>/cmdline
moonraker cmdline: moonraker.py -d /opt/printer_data -c .../config/moonraker.conf ... - confirmed via /proc/<pid>/cmdline
moonraker API:     /server/files/roots -> config: /opt/printer_data/config, rw - confirmed, both directly and through nginx's proxy
moonraker API:     /server/files/list?root=config -> every expected file listed, rw - confirmed
editability:       create/read/edit/delete a test file through the real file-manager API - all succeeded;
                   same inode number on both the persistent and bind-mounted runtime path
SAVE_CONFIG:       confirmed via configfile.py source to target the exact same start-arg config_file path
```

All four architectural failure modes the mission asked to rule out (wrong Moonraker root, split Klipper/Moonraker config paths, broken/missing bind mount, unreadable persistent config) were conclusively ruled out with direct evidence - the architecture already matched the intended design exactly. No filesystem or activation-sequence change was made. New `06-verify.sh` checks now guard `S55klipper`/`S56moonraker`'s launch arguments, `S01persistent-datastore`'s bind-mount/backing-root, and the absence of a `[file_manager]` override in `moonraker.conf`, re-run clean (zero new `MISS` lines) against the already-built Phase 11 image without needing a rebuild, since nothing shippable changed. Full investigation, the editability proof, and why no second empty-namespace wipe cycle was needed: `docs/NEBULAOS_FRONTEND_PRINT_CONTROLS.md` §7.
