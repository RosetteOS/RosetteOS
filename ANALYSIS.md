# prtouch_v2 protocol + algorithm analysis

Source: `reference/prtouch_v2_wrapper.py` (host, 2202 lines, **read completely, start to finish**)
+ `reference/prtouch_v2.c` (MCU firmware, 793 lines, **also read completely**), both real Creality
GPLv3 source from
[`CrealityOfficial/K1_Series_Klipper@e09f36e6`](https://github.com/CrealityOfficial/K1_Series_Klipper/commit/e09f36e6ada60e5467b0bef731a96263b5d8095b).
Command signatures confirmed byte-for-byte matching our own KE's compiled `prtouch_v2_wrapper.so`
via `strings` (see `project_mainline_klipper_ke_separate.md` in the RosetteOS memory for that
device-side forensics). Analysis done 2026-07-18, printer mid-print throughout, zero device writes.

This revision supersedes an earlier draft that drew conclusions from strategic excerpts rather than
the full files. The complete read changed the actual conclusion (see §4) - not just added detail.

## 1. Complete wire protocol (verbatim, both sides)

### Config commands (sent once via `add_config_cmd`, host -> MCU, text-mode)

| Command | Host format (Python `%`-literal) | MCU format (`DECL_COMMAND`) |
|---|---|---|
| `config_step_prtouch` | `oid=%d step_cnt=%d swap_pin=%s sys_time_duty=%u` | `oid=%c step_cnt=%c swap_pin=%u sys_time_duty=%u` |
| `add_step_prtouch` | `oid=%d index=%d dir_pin=%s step_pin=%s dir_invert=%d step_invert=%d` | `oid=%c index=%c dir_pin=%u step_pin=%u dir_invert=%c step_invert=%c` |
| `config_pres_prtouch` | `oid=%d use_adc=%d pres_cnt=%d swap_pin=%s sys_time_duty=%u` | `oid=%c use_adc=%c pres_cnt=%c swap_pin=%u sys_time_duty=%u` |
| `add_pres_prtouch` | `oid=%d index=%d clk_pin=%s sda_pin=%s` | `oid=%c index=%c clk_pin=%u sda_pin=%u` |

### Runtime commands (`lookup_command`/`lookup_query_command`, binary-encoded, sent repeatedly)

| Command | Format | Paired response |
|---|---|---|
| `read_swap_prtouch` | `oid=%c` | `result_read_swap_prtouch oid=%c sta=%c` |
| `start_step_prtouch` | `oid=%c dir=%c send_ms=%c step_cnt=%u step_us=%u acc_ctl_cnt=%u low_spd_nul=%c send_step_duty=%c auto_rtn=%c` | (async `result_run_step_prtouch`) |
| `manual_get_steps` | `oid=%c index=%c` | `result_manual_get_steps oid=%c index=%c tri_time=%u tick0..3=%u step0..3=%u` |
| `write_swap_prtouch` | `oid=%c sta=%c` | `resault_write_swap_prtouch oid=%c` (sic) |
| `read_pres_prtouch` | `oid=%c acq_ms=%u cnt=%u` | `result_read_pres_prtouch oid=%c tick=%u ch0..3=%i` |
| `start_pres_prtouch` | `oid=%c tri_dir=%c acq_ms=%c send_ms=%c need_cnt=%c tri_hftr_cut=%u tri_lftr_k1=%u min_hold=%u max_hold=%u` | (async `result_run_pres_prtouch`) |
| `deal_avgs_prtouch` | `oid=%c base_cnt=%c` | `result_deal_avgs_prtouch oid=%c ch0..3=%i` |
| `manual_get_pres` | `oid=%c index=%c` | `resault_manual_get_pres oid=%c index=%c tri_time=%u tri_chs=%c buf_cnt=%u tick_0..1=%u ch0_0..ch3_1=%i` (sic) |

Two oid channels, `step_oid`/`pres_oid`, run concurrently during a probe.

## 2. The MCU firmware does its own independent step generation - this is the key finding the earlier draft missed

Reading `prtouch_v2.c` completely (not just its `DECL_COMMAND`/`sendf` lines) surfaces something the
Python-only read couldn't: **the actual Z-axis stepping during a probe cycle is generated entirely
inside the MCU firmware, by a bespoke timer callback, completely outside Klipper's normal stepper
motion-queue/trapq system.**

- `command_start_step_prtouch` (line 280) arms a raw hardware timer (`step_cfg.time`, `sched_add_timer`)
  whose callback, `prtouch_event()` (line 199), directly toggles the Z step GPIO
  (`gpio_out_toggle_noirq`) on every tick, using a 256-entry sigmoid lookup table
  (`sigmoid_ary`, line 133) baked into the firmware to shape accel/decel - its own complete,
  self-contained motion-ramp implementation.
- This is a *pulse count + timing* command (`step_cnt`, `step_us`, `acc_ctl_cnt`), not a queued
  kinematic move. Klipper's normal `stepper.c` step-compression/trapq motion planner is not involved
  at all during a probe - the MCU is told "toggle this pin N times at this timing profile" directly.
- Meanwhile `prtouch_pres_task()` (line 738) independently samples the load-cell/piezo channels
  (bit-banged HX711-style 24-bit shift-in for strain gauges, `gpio_adc_sample` for piezo/ADC boards)
  on every scheduler tick, applies the exact same high-pass/low-pass filter math the host's
  `cal_tri_data()` uses on its own copy of the data (`filter_datas_prtouch`, line 453), and evaluates
  a trigger condition (`check_pres_tri_prtouch`, line 535) *on the MCU itself* - not host-side - to
  set `write_swap_sta(1)` (a real-time signal line back to the step side) the instant a trigger fires.
  Both tasks are multiplexed cooperatively under one `prtouch_task()` (line 789) called every
  scheduler tick.
- `read_pres_prtouch()` (line 398) is a genuine dual-mode sensor driver: bit-banged clocked shift-in
  for strain-gauge HX711-style boards (24 clock pulses, sign-extended 24-bit twos-complement), or
  `gpio_adc_sample`/`gpio_adc_read` for piezo/ADC-based boards - selected by the `use_adc` config flag.

**Why this matters for the design question:** the earlier draft framed this as "Option A: replicate
Creality's approach" vs. "Option B: reimplement using mainline's safer `trsync`-backed triggering."
That framing assumed the *host* could choose to wire this MCU up through Klipper's standard
`home_start`/`home_wait`/`trsync` endstop interface instead of the stub methods Creality wrote. Having
now read the firmware, that's not actually available as a choice: `trsync`'s whole job is to
synchronize an **already-queued kinematic move's** step generation with a trigger signal at the MCU
level. There is no such queued move here to synchronize - the MCU has no command that says "step the Z
axis via the normal kinematic stepper queue, but stop early if this pin fires." It only has this
bespoke, poll-driven, timer-generated pulse-train command. A `trsync`-integrated version would require
new MCU firmware capability that doesn't exist today - i.e. exactly the reflash this whole
investigation is trying to avoid.

## 3. Host-side confirms the same shape: no standard endstop wrapper, by necessity not by shortcut

```python
def home_start(self, print_time, sample_time, sample_count, rest_time, triggered=True):
    return True
def home_wait(self, home_end_time):
    return True
def query_endstop(self, print_time):
    return False
def probe_prepare(self, hmove):
    pass
def probe_finish(self, hmove):
    pass
```

These stubs aren't a corner Creality cut - they're the only correct implementation given what the
firmware actually offers. The real logic lives in `run_step_prtouch()` (line 1157, fully read): send
`start_step_prtouch` + `start_pres_prtouch` concurrently, poll both response FIFOs every 10ms until
full or timeout, call `cal_tri_data()` to convert the two buffers into a trigger Z position, retry
with self-correcting Z-zero tracking on a no-trigger, and average/median over `pro_cnt` (default 3)
consistent samples within `probe_min_3err` tolerance. `ck_and_raise_error()` always lifts Z 5mm via a
direct step command before raising, as a physical safety courtesy even without `trsync`.

## 4. Full algorithm map (now completely read, not sampled)

- **`cal_tri_data()`** (line 666) - the real calibration math. Picks the nearest bed corner sensor
  channel geometrically (`get_valid_ch`, distance from current XY to each of 4 mesh corners),
  z-score-filters outlier samples, applies the same high-pass/low-pass filter as the firmware
  (redundant/parallel computation, not just a firmware mirror), then does something clever to locate
  the trigger index: normalizes the filtered curve to [0,1], computes the tilt angle between first and
  last sample via `atan`, rotates the whole series by `-angle` (sin/cos transform) to flatten out slow
  drift, and takes the *minimum* of the rotated series as the trigger index. Step position at that tick
  is linearly interpolated between the two nearest step-buffer samples. Final Z = `start_pos_z -
  (start_step - out_step) * mm_per_step + oft_z`. Averaged across however many corner channels were
  valid.
- **`env_self_check()`** (line 812, 285 lines) - a genuine 5-stage sensor self-test run before every
  `G28 Z`: (1) sync/swap-pin GPIO round-trip check, (2) read-timing/sample-rate check via
  `deal_avgs_prtouch`+`read_pres_prtouch`, (3) constant-value check (catches a disconnected sensor
  reading a frozen value), (4) noise-too-big check (catches external interference/vibration), (5) a
  physical shake test - `quick_shake_motor` jitters the bed and the code verifies the sensor's
  measured standard deviation actually rises, with a real Z-probe fallback confirmation if the shake
  result is ambiguous, and up to 2 retries before raising a real error code.
- **`run_G28_Z()`** (line 1586, 183 lines) - full Z-homing: cool-down wait if configured, environment
  self-check (aborts homing if it fails), a coarse probe loop (fast 1.2-2x-speed down-move, retried
  until 3 consecutive coarse reads agree within 2mm, capped at a configurable max-tries with a real
  error code on timeout, periodic re-shake every 5 tries), then (if `accurate=True`) a precision probe
  + independent confirmation re-probe, retried up to 2 times if they disagree by >1mm.
- **`run_G29_Z()`/`run_re_g29s()`/`bed_mesh_post_proc()`/`correct_bed_mesh_data()`** - full mesh-scan
  integration: per-point probing during `BED_MESH_CALIBRATE` with a per-point tuning-parameter ramp
  across the whole mesh (`tri_min_hold_ALL`/`tri_max_hold_ALL` arrays indexed by scan position), a
  **step-loss detection pass** at the very end of a mesh scan (returns to the home point and checks the
  probed Z reads back near zero - if not, the entire mesh is considered corrupted by lost steps and is
  either re-run from scratch or raises `PR_ERR_CODE_HAVE_LOST_STEP`), an outlier-point re-probe pass
  (each mesh point's Z is checked against its 4 neighbors' slope; points that look physically
  implausible are re-probed individually), and tilt/center normalization math.
- **`clear_nozzle()`** (line 1512) - a real nozzle-wipe cycle: heats bed/nozzle to configured temps,
  probes two randomized XY points on the wipe pad to find local Z height at each (handles
  out-of-range probes by forcing a Z-reference reset), drags the nozzle between them at wipe temp,
  then cools and repeats.
- **10 real gcode commands** (`cmd_*`, lines 1915-2201) all read - `READ_PRES`, `TEST_SWAP`,
  `DEAL_AVGS`, `NOZZLE_CLEAR`, `CHECK_BED_MESH`, `START_STEP_PRTOUCH`, `PRTOUCH_READY`,
  `SAFE_MOVE_Z`, `ACCURATE_HOME_Z`, `SAFE_DOWN_Z`, `TRIG_TEST`, `TRIG_BED_TEST` (a real diagnostic
  that logs per-point trigger repeatability to a CSV on the filesystem), `SELF_CHECK_PRTOUCH`,
  `TEST_PRTH` (empty/commented-out debug scratch command, not active).

## 5. `z_compensate` - confirmed genuinely unavailable, not just "not found yet"

Searched (2026-07-18, via `gh api search/code` and `search/commits` across the entire
`CrealityOfficial` GitHub org, not just the K1 repo where `prtouch_v2` turned up):

- `klippy/extras/z_compensate.py` exists in **both** `CrealityOfficial/Ender-3_V3_KE_Klipper` (our
  own printer's line) and `CrealityOfficial/CR-10SE_Klipper` - but in both cases it's an 11-line shim
  that just does `from . import z_compensate_wrapper` and instantiates
  `ZCompensateInitWrapper(config)`. The real logic is in `z_compensate_wrapper`, shipped **only** as
  `z_compensate_wrapper.cpython-38-mipsel-linux-gnu.so` - a compiled binary, same as what's on our own
  KE.
- No repo in the org (checked `K1_Series_Klipper`, `K2_Series_Klipper`, `Hi_Klipper`, and a
  cross-org commit-message search for "z_compensate") has ever published real source for this module,
  unlike `prtouch_v2` which got a dedicated "open prtouch_v1 and prtouch_v2 source code" commit in the
  K1 repo. `z_thermal_adjust` (which does turn up in commit search) is an unrelated, genuinely upstream
  Klipper feature (frame-coupled temperature Z compensation) - not the same thing.
- Conclusion: unlike prtouch_v2, `z_compensate`'s actual algorithm is closed. Anything driving it would
  have to be reverse-engineered from the compiled `.so` directly (Python bytecode/binary analysis) - a
  meaningfully different, harder task than what was done here. Not started; flagging as a separate,
  harder sub-problem, not assuming it's needed for a first cut (prtouch_v2's own Z-homing/bed-mesh
  path may be sufficient on its own - `z_compensate` reads as a secondary fine-tune layer on top, not
  a hard requirement in `printer.cfg`).

## 6. The actual, now-informed design decision

Given the firmware constraint in §2, there is really one real option for a no-reflash path, not two:

**Replicate Creality's exact command sequence and algorithm.** This is not "the unsafe shortcut" -
it's the only mechanism the existing, unreflashed firmware supports. A trsync-integrated,
mainline-standard endstop implementation is not achievable against this firmware without new MCU
capability - i.e., without the SWD reflash this entire investigation exists to avoid. So the practical
scope for `klippy_extras/` is: **a clean, from-scratch host-side Klipper extra that speaks the exact
protocol documented in §1, replicates the calibration math in §4, and can be reasoned about/tested
independently of Creality's specific code shape** - not a mainline-safety redesign (that's a different
project, gated on the reflash path already documented in the RosetteOS memory), and not a verbatim port
of Creality's Python either (their code has real quirks - global mutable state, `time.sleep`-driven
polling loops via `reactor.pause`, debug-print scaffolding, a UDP waveform-streaming feature - worth
leaving out of a clean rewrite even while keeping the same wire protocol and math).

The one open safety question worth being explicit about: since Z motion during a probe is a raw,
non-interruptible MCU-side pulse train (not a Klipper-queued move), the *only* real safety net against
a stuck/non-triggering sensor is the firmware's own step-count limit (it stops after `step_cnt` pulses
regardless of trigger) plus the host's max-tries/timeout loops. That's exactly the same safety
envelope Creality's own shipped code operates under today, on this same hardware - so a faithful
reimplementation carries the same real-world risk profile already accepted by every stock KE running
this firmware, no better and no worse.

## 7. Scope, confirmed against the real printer (2026-07-18, read-only SSH, printer idle)

Checked what actually runs in production, not just what prtouch_v2 exposes:

- **`gcode_macro.cfg`'s real `G29` macro** (the one a real bed-mesh calibration runs) is
  `G28` -> `BED_MESH_CALIBRATE` -> save - stock Klipper only, using the `probe` object (BLTouch).
  **`prtouch_v2`'s own `run_G28_Z`/`run_G29_Z`/`bed_mesh_post_proc` are never invoked in real
  production on this printer** - confirmed not just inferred. That entire ~500-line chunk of the
  file we read doesn't need porting.
- **The real per-print auto-Z-offset routine** lives in `klippy/extras/custom_macro.py`
  (plaintext, stock-adjacent, not compiled - read in full) - its `CX_PRINT_LEVELING_CALIBRATION`
  command is what the app actually triggers before a print with leveling calibration on: `G28` ->
  heat nozzle/bed -> `CRTENSE_NOZZLE_CLEAR HOT_START_TEMP=.. HOT_RUB_TEMP=.. BED_ADDTEMP=..` ->
  `Z_OFFSET_CALIBRATION` -> cool down -> `G28 Z` -> `BED_MESH_CALIBRATE` -> `CXSAVE_CONFIG`. Both
  `CRTENSE_NOZZLE_CLEAR` and `Z_OFFSET_CALIBRATION` are registered by `z_compensate_wrapper.so` -
  the closed module - not by `prtouch_v2`.
- **The important discovery**: `strings` on `z_compensate_wrapper.so` shows it registers **no**
  `config_*`/`create_oid`/`add_config_cmd` calls of its own - it does `lookup_object` and directly
  references `prtouch_v2`, `run_step_prtouch`, `start_step_prtouch_cmd`, `write_swap_prtouch_cmd`,
  `read_swap_prtouch_cmd` by name. **`z_compensate` is a thin orchestration layer on top of
  `prtouch_v2`'s own primitives, not a second independent MCU protocol.** Its own `[z_compensate]`
  config keys in `printer.cfg` (`clr_noz_start_x/y`, `clr_noz_len_x/y`, `pa_clr_dis_mm_x/y`) match
  `prtouch_v2`'s own `clear_nozzle()` parameter names exactly - strong evidence
  `CRTENSE_NOZZLE_CLEAR` is `prtouch_v2.clear_nozzle()` (already fully read, §4) called with
  different temperature args, not separate logic. `bl_offset: 0,27` in `[z_compensate]` matches
  `[bltouch]`'s own `y_offset: 27` exactly, consistent with `Z_OFFSET_CALIBRATION` touch-probing at
  the same physical point BLTouch already homed, offset by the nozzle-to-probe-tip distance, then
  reconciling the two readings.

**Net effect on scope**: the real, user-facing feature (per-print auto-Z-offset) is buildable from
primitives we've already read completely (`run_step_prtouch`, `cal_tri_data`, `clear_nozzle`,
`env_self_check`, the MCU protocol) plus one new, small, well-scoped piece of orchestration logic
(touch-probe at the BLTouch-homed point adjusted by `bl_offset`, diff against the current probe
`z_offset`, apply via - almost certainly - stock Klipper's own `Z_OFFSET_APPLY_PROBE`, which also
turned up in the `z_compensate_wrapper.so` strings). Not a verbatim port of closed code (impossible,
we don't have it) - a fresh, small design on solid, fully-understood ground. This is meaningfully
less work than "port all 2202 lines," and doesn't require reverse-engineering the compiled
`z_compensate_wrapper.so` at all.

## 8. Not yet done (next real steps, not started)

- No code written yet in `klippy_extras/` - this file is analysis only, as scoped.
- `z_compensate_wrapper.so` reverse-engineering (see §5) - separate, harder, not assumed necessary
  for a first working prtouch_v2 replacement.
- Deciding exact module boundaries/API surface for the from-scratch rewrite mentioned in §6 - not
  started, should happen as its own step once this analysis is reviewed.
