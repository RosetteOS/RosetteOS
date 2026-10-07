# NebulaOS Display Live Qualification Plan

Companion to [NEBULAOS_DISPLAY_OS_HARDWARE_ANALYSIS.md](NEBULAOS_DISPLAY_OS_HARDWARE_ANALYSIS.md)
and [NEBULAOS_DISPLAY_OFFLINE_IMPLEMENTATION_PLAN.md](NEBULAOS_DISPLAY_OFFLINE_IMPLEMENTATION_PLAN.md).
This document originally defined what happens **after** explicit user confirmation to begin
powered-on work. **Update (2026-08-01, powered-on follow-on mission)**: the read-only portion of
this plan has now been executed - see `docs/NEBULAOS_DISPLAY_LIVE_READ_ONLY_REPORT.md` for full
results. The printer was contacted via read-only SSH only (no writes, no flash, no reboot, no
register writes). The one remaining write test (HT-09, spare-slot deployment) has **not** been
executed and still requires explicit user confirmation before proceeding - see the updated test
status table below.

## Ordering principle

Every test below is READ-ONLY (or spare-slot-only, reversible) until explicitly marked
otherwise. Read-only tests should run before any write/flash test, since several of them
(HT-01, HT-02) directly inform whether a later prototype (DISPLAY-B1) is even electrically
plausible before any engineering time is spent flashing it.

## Test matrix - status after the 2026-08-01 read-only sweep

See `build-work/display-analysis/hardware-test-matrix.tsv` for the full machine-readable
version. Status column added after the powered-on follow-on mission's read-only sweep (full
detail: `NEBULAOS_DISPLAY_LIVE_READ_ONLY_REPORT.md`).

1. **HT-01 (backlight electrical, READ-ONLY)** - **NOT CLOSED**: this kernel's debugfs GPIO/
   pinctrl interfaces are absent (a genuine capability gap, confirmed live), so GPC-0/GPC-22's
   raw pin state could not be read this session. Confirmed instead: zero PWM channels are
   currently exported/active (`pwmchip0` has `npwm=16`, none in use), and `/sys/class/
   backlight/` is empty. Still gates DISPLAY-B1's readiness - see prototype readiness doc.
2. **HT-02 (panel reset polarity, READ-ONLY)** - **NOT ATTEMPTED** this session (same debugfs
   GPIO gap would apply).
3. **HT-07 (stock DPU enablement mechanism, READ-ONLY)** - **NOT ATTEMPTED** (requires booting
   to the stock slot specifically, out of scope for this session's custom-slot investigation).
4. **HT-06 (boot handoff visual continuity, READ-ONLY, UART passive capture)** - **NOT
   ATTEMPTED**: requires physical UART setup and a natural cold boot; explicitly out of scope
   for a remote read-only SSH session (no reboot may be agent-triggered).
5. **HT-10 (panel timing live re-confirmation, READ-ONLY)** - **CONFIRMED**: kernel boot log
   independently shows `mode->refresh: 60, mode->pixclock: 92962, rate: 10756800`, matching
   `panel-timing-comparison.txt`'s computed pixclock exactly.
6. **HT-03 (DPU underrun/overrun rate, READ-ONLY)** - **PARTIALLY DONE**: the DPU/vsync IRQ rate
   itself was measured live (~60.3Hz over 10s, see HT-04-adjacent note below) - the specific
   underrun/overrun *counters* were not separately exposed (no DPU debugfs node exists on this
   kernel) so their live rate under real UI load remains unmeasured.
7. **HT-04 (pan-display/vsync tearing, READ-ONLY, visual only)** - **NOT ATTEMPTED** (requires
   watching the live screen during rapid content changes - not done via SSH alone). The
   underlying DPU IRQ was confirmed firing at the expected rate (~60.3Hz measured, IRQ 39/
   "lcdc-1"), which is a prerequisite fact for this test but not the visual observation itself.
8. **HT-05 (touch poll latency, READ-ONLY)** - **PARTIALLY DONE**: confirmed via the full live
   `/proc/interrupts` table that touch has zero dedicated IRQ lines anywhere in the system today
   (poll-only, system-wide check, not just the GPIO79-specific one) - directly relevant to
   TOUCH-I1's premise. The specific tap-to-response latency measurement was not performed.
9. **HT-08 (PREEMPT_RT display jitter, READ-ONLY)** - **PARTIALLY DONE**: confirmed
   `/sys/kernel/realtime=1` and `CONFIG_PREEMPT_RT=y` are live on the currently-running image
   (this **is** the NEBULAOS-ALPHA-MAX-RT deployment, still running) - the specific DPU IRQ
   thread scheduling-latency measurement under composer-restart load was not performed.
10. **HT-09 (DISPLAY-B1 validation, WRITE - spare slot only, reversible)** - **NOT PERFORMED**,
    still requires explicit user confirmation. HT-01 has not yet confirmed the electrical path
    is plausible (see above), so this remains gated per its own original condition.

**New, additional finding not in the original HT list**: the kernel boot log line
`rosetteos_panel: invalid gpio vdd_en: -2` independently corroborates (from an entirely different
angle - the boot log, not static DTS inspection) that no `vdd_en`/backlight-adjacent GPIO
resolves in this DT, reinforcing HT-01's relevance.

## Acceptance criteria

A candidate from `candidate-ranking.tsv` may only move from its current
priority/DEFER/REJECT classification to "approved for production" if:
- Its corresponding hardware test(s) above have run and produced a result consistent with the
  candidate's premise (e.g. DISPLAY-B1 requires HT-01 to show GPC-0/GPC-22 are real,
  controllable pins, and HT-09 to show the prototype actually changes physical brightness).
- The change does not regress any of the alpha-baseline's existing proven-working behavior
  (RGB565 wire format, touch GPIO fix, panel timing) - re-run the existing GUI/touch live
  validation steps from `GUI_WORKSTREAM_HANDOFF.md` after any display-path change, not just the
  new test.
- Any change to the active/production slot is deployed via the project's existing
  `flash-spare-slot.sh` + stock-detour workflow ([[project_nebulaos_prequalification_mission]]),
  never a direct in-place edit of a running system.

## Focused test guides for future testing

Written for whichever candidate the user selects first. None of these have been executed - see
the status table above for what has and has not happened so far.

### DISPLAY-B1 test guide

Requires, in order: backlight device appears under `/sys/class/backlight/` after deployment;
`brightness` file is writable; `actual_brightness` reflects a real, meaningful value (not a
fixed/ignored stub); writing `0` visibly turns the backlight off; writing a nonzero value
restores it; identify the minimum visible brightness level and the level where flicker (if any)
first appears; identify the practical maximum useful level; verify no polarity surprise (higher
number = brighter, not inverted); cycle through ~100 brightness transitions watching for any
instability; test across both a warm reboot and a cold boot; confirm no white/black flash
regression and no panel-reset behavior change versus the current baseline. Start with
conservative (mid-range) values, per the mission's own instruction - never jump straight to
extremes on first contact with real hardware.

### DISPLAY-V1 test guide

Capture baseline page-flip behavior first (before deploying this variant) as a point of
comparison. A standalone framebuffer diagnostic test-pattern program cycling through all 3
buffers is the right tool here - GuppyScreen source changes are explicitly not required or
in scope. Compare visible tearing with the variant on vs. off during rapid content changes;
measure `FBIOPAN_DISPLAY` call latency before/after; confirm `FBIO_WAITFORVSYNC` behavior is
unaffected; watch the new debugfs/diagnostic counters (`pan_vsync_gated_count`,
`pan_vsync_timeout_count`, `pan_vsync_invalid_count`) under real use - a healthy result is mostly
gated counts with rare, non-escalating timeouts; check DPU underrun counts are not worse than
baseline; if the RT experimental image is used, watch for IRQ-thread scheduling behavior under
combined camera/Wi-Fi/USB load; run at least 5000 page-flip cycles; confirm the GUI otherwise
behaves normally throughout.

### TOUCH-I1 test guide

Watch the new debugfs counters (`/sys/kernel/debug/ns2009_ts/{irq_count,irq_active,
irq_storm_triggered}`) from first boot: `irq_active=true` with `irq_count` advancing on real
touches and remaining reasonable (not runaway) while idle is the expected healthy signature; if
`irq_storm_triggered` ever flips, the IRQ path disabled itself as designed - the poll continues
unaffected, so this is a soft-fail signal, not a functional failure, but worth recording.
Compare touch latency and coordinate-reporting correctness against the current baseline; confirm
release detection remains reliable; confirm CPU usage is not worse (should be equal or better,
since the poll cadence is unchanged and the IRQ path only adds sparse, event-driven work); test
edge-of-screen accuracy, rapid repeated taps, long presses, and drag gestures; run at least 1000
touch-down/release cycles; test across a warm reboot. Explicitly do NOT enable any display-wake
behavior during this test - none exists in this prototype and none should be added ad hoc.

## Future A/B variants (S0-S7)

Reserved for a future, separately-authorized live qualification mission, once DISPLAY-B1's
basic electrical viability (HT-01/HT-09) is confirmed:

| Variant | Description | Depends on |
|---|---|---|
| S0 | Today's baseline - no backlight control, current blanking/vsync/touch behavior unchanged | none |
| S1 | DISPLAY-B1 backlight-class + DT integration only | HT-01 plausible |
| S2 | S1 + a real calibrated brightness table (replacing the placeholder 0-15 linear table) | S1 deployed + HT-09 pass + real dimming-curve measurement |
| S3 | S1 + backlight-only blanking (scanout/panel stay active, only backlight gates) | S1 deployed |
| S4 | S3 + deep display powerdown (real panel_ops->disable() GPIO-level reset-hold on blank) | S3 deployed + a demonstrated power/thermal need |
| S5 | Auto vsync-gate before FBIOPAN_DISPLAY (**now DISPLAY-V1** - built, compile-tested, packaged, READY_FOR_ISOLATED_DEPLOYMENT) | HT-04 confirms visible tearing (not yet run - see status table) |
| S6 | IRQ-driven touch pen-down (**now TOUCH-I1** - built, compile-tested, BLOCKED_PENDING_HARDWARE_PROOF pending GPIO79 trigger confirmation) | HT-05 confirms a real latency/power benefit (not yet run) |
| S7 | Combined S1+S3+S5+S6 - a fully realized "OS uses the display to its practical potential" variant, only after each constituent has been independently validated | S1, S3, S5, S6 all individually proven |

S1 (DISPLAY-B1) and now S5/S6 (DISPLAY-V1/TOUCH-I1) all have compile-only prototypes prepared
(see the offline implementation plan and prototype readiness doc); S2-S4/S7 remain design
placeholders pending their stated dependencies. **DISPLAY-V1 is additionally packaged and ready
for spare-slot deployment** - see the prototype readiness doc.

## Explicit stop condition

**Update (2026-08-01)**: the read-only portion of this plan has now been executed - see the
status table above and `NEBULAOS_DISPLAY_LIVE_READ_ONLY_REPORT.md` for full results. Several
read-only tests remain not-attempted (HT-02, HT-04, HT-06, HT-07, and the specific latency/
jitter measurements in HT-05/HT-08/HT-03) and can be picked up in a future session using the
same read-only tooling (`scripts/qa/display-live-capture.sh`).

**No write/flash test has been performed.** HT-09 (the only write test in this entire plan, and
the only thing separating any of the three prototypes from a real hardware verdict) still
requires explicit user confirmation before proceeding - this applies specifically to deploying
DISPLAY-V1 (the one READY candidate) to a spare slot for its own live qualification.
