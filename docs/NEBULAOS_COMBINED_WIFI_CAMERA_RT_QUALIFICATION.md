# NebulaOS Combined Wi-Fi / Camera / PREEMPT_RT Qualification Runbook

Pre-qualification mission Phase A13 (2026-07-31). This is the Mode B
(printer powered on) runbook - every command below is exact, every
threshold is defined in advance (see
`docs/NEBULAOS_QUALIFICATION_ACCEPTANCE_CRITERIA.md`, Phase A10). Do not
improvise steps during live testing; if something here doesn't match
reality, stop and reconcile before proceeding, per this project's own
established safety discipline.

**Before starting any step in this runbook**: confirm the printer is
powered on and reachable, and re-read
`reference_device_access` conventions (SSH root/`rosetteos` on custom,
`Creality2023` on stock, DHCP IP drifts every reboot, dropbear host key
regenerates every boot). Every state-changing device action below follows
the two-invocation rule: a read-only query first, review, then a separate
invocation for the actual state change.

## 1. Initial read-only baseline

Before touching anything, capture the unmodified, currently-flashed
image's own real behavior:

```
ssh root@<printer-ip> 'cat /proc/cmdline'                          # confirm active slot
ssh root@<printer-ip> 'uname -a'                                    # kernel version/build
ssh root@<printer-ip> 'cat /sys/class/net/wlan0/address'            # current MAC (pre-fix, likely different every boot)
ssh root@<printer-ip> 'iw dev wlan0 link'                           # current association
ssh root@<printer-ip> 'cat /var/run/nebulaos-boot-timing.log'       # if this image predates Phase A9, this will be absent - expected
scp scripts/qa/production-benchmark.sh root@<printer-ip>:/tmp/
ssh root@<printer-ip> 'sh /tmp/production-benchmark.sh baseline-unmodified /usr/data/staging/benchmarks unknown unknown unknown 1'
```

Do not change anything based on this step alone - it exists purely so
every later comparison has a real "before" reference.

## 2. First-boot venv validation (carried over from the prior production-
optimization mission - still the one open item from Phase 11/12 of that
mission)

Requires a genuinely wiped NebulaOS application namespace. **Back up
persistent state first** (this is a real, destructive-adjacent operation
on `/usr/data/nebulaos` - never skip the backup):

```
ssh root@<printer-ip> 'tar -cf /usr/data/staging/pre-wipe-backup.tar /usr/data/nebulaos' # read-only backup step
# --- separate invocation for the actual wipe ---
ssh root@<printer-ip> 'rm -rf /usr/data/nebulaos && reboot'
```

After reboot, measure: Klipper venv readiness, Moonraker venv readiness,
combined first-boot readiness, and confirm the fallback path (deliberately
corrupt the seed archive first, on a *second* wipe cycle, to prove
`S04nebulaos-factory-seed`'s fallback to `python3 -m venv` still produces
a usable system) - see the prior mission's own Phase 11 notes for the
measured ~59s-per-venv baseline this either confirms or improves on.

## 3. Stable-MAC validation (Phase A3)

```
ssh root@<printer-ip> 'cat /sys/class/net/wlan0/address'   # record MAC #1
ssh root@<printer-ip> 'reboot'
# wait for the device to come back (fresh subnet rescan + dropbear banner
# verification, per this project's own "never trust a stale IP across a
# reboot" lesson - do not poll a cached IP)
ssh root@<new-ip> 'cat /sys/class/net/wlan0/address'        # must match MAC #1
```

Repeat for 5 warm reboots + 3 cold boots total. Also test across an A/B
slot switch (cycle to the other OTA slot and back) and confirm the MAC
survives that too (both slots share the same physical eMMC, so this
should hold by construction - confirm it actually does).

**Accept/reject**: per `NEBULAOS_QUALIFICATION_ACCEPTANCE_CRITERIA.md`'s
Stable Wi-Fi MAC section.

## 4. Wi-Fi power-save A/B (Phase A5)

```
# P0 (baseline, already the default - no marker needed)
ssh root@<printer-ip> '/usr/libexec/nebulaos-wifi-power-save status'
scp scripts/qa/lan-performance-test.sh root@<printer-ip>:/tmp/
ssh root@<printer-ip> 'sh /tmp/lan-performance-test.sh <lan-test-host-ip> /usr/data/staging/benchmarks/p0-lan.txt'

# --- separate invocation to switch to P1 ---
ssh root@<printer-ip> '/usr/libexec/nebulaos-wifi-power-save enable-experiment'
ssh root@<printer-ip> '/usr/libexec/nebulaos-wifi-power-save verify'   # confirm it actually took effect
ssh root@<printer-ip> 'sh /tmp/lan-performance-test.sh <lan-test-host-ip> /usr/data/staging/benchmarks/p1-lan.txt'

# revert back to P0 before moving on to the next test
ssh root@<printer-ip> '/usr/libexec/nebulaos-wifi-power-save disable-experiment'
```

**Accept/reject**: per the criteria doc's Wi-Fi power-save section.

## 5. SDIO W0/W1/W2/W3 comparison (Phase A4)

This is the one candidate that requires a real kernel rebuild + reflash
per variant - budget real time for this, and never skip straight to W3.

For each variant in order **W0, W1, W2, (only if both W1 and W2 pass) W3**:

```
sh scripts/build/wifi-sdio-variant.sh <variant>     # host-side, applies the DT change
sh scripts/build/00-fetch-vendor-sources.sh && \
sh scripts/build/01-apply-kernel-patches.sh && \
sh scripts/build/02-configure-buildroot.sh && \
sh scripts/build/03-build-kernel-and-rootfs.sh && \
sh scripts/build/04-cross-compile-app-stack.sh && \
sh scripts/build/05-final-build.sh && \
sh scripts/build/06-verify.sh
sh scripts/build/package-variant-artifacts.sh <variant>
```

Then, ON the device (read-only check, review, then real write - never
skip the `--check-only` pass):

```
scp build-work/deploy-packages/<variant>-<ts>/{xImage,rootfs.squashfs,build-manifest.txt} root@<printer-ip>:/usr/data/staging/
ssh root@<printer-ip> 'sh /tmp/flash-spare-slot.sh --check-only /usr/data/staging/xImage /usr/data/staging/rootfs.squashfs /usr/data/staging/build-manifest.txt'
# review the check-only output carefully before proceeding
ssh root@<printer-ip> 'sh /tmp/flash-spare-slot.sh /usr/data/staging/xImage /usr/data/staging/rootfs.squashfs /usr/data/staging/build-manifest.txt'
# --- separate invocation: flip the OTA marker and reboot into the new slot ---
```

Measure everything listed in
`NEBULAOS_CAMERA_USB_RT_SOURCE_ANALYSIS.md` sec 18.18 Stage A (module/
firmware identity, RSSI, bitrate, retry stats) plus Stage B (association/
DHCP/SSH/Moonraker timing via the new `S02nebulaos-boot-timing` log,
ping percentiles and TCP throughput via `lan-performance-test.sh`).

**Accept/reject**: per the criteria doc's SDIO variants section - reject
immediately on any enumeration failure, association instability, new
dmesg SDIO/MMC error, or reliability regression across 5 warm + 3 cold
boots, before even considering whether it measurably helped.

## 6. Camera C0/C1/C2 comparison (Phase A7)

No rebuild needed - purely runtime marker switches:

```
# C1 (1080p15) - SUPERSEDED (camera quality presets mission, 2026-08-04):
# S50webcam no longer reads camera-fps-mode/C1 at all - the commands below
# are dead, kept only as a historical record of what this qualification
# pass actually ran. The fps-only marker was replaced by
# camera-quality-mode (LOW/MED/HIGH - see camera-quality.cfg's
# SET_CAMERA_QUALITY_LOW/MED/HIGH macros, the current end-user-facing
# interface). None of the three presets reproduce "1080p @ 15fps" exactly
# (LOW/MED are uncapped-fps at 640x480/1280x720, HIGH is the qualified
# 1920x1080 @ 30fps default) - see S50webcam's own header comment for why
# LOW/MED deliberately don't request a capped fps. A real C1-equivalent
# retest, if ever needed, should write "HIGH" to
# /usr/data/nebulaos/maintenance/camera-quality-mode after confirming
# whether a capped-1080p15 preset is still wanted, not resurrect this
# marker.
ssh root@<printer-ip> 'mkdir -p /usr/data/nebulaos/maintenance && echo C1 > /usr/data/nebulaos/maintenance/camera-fps-mode && /etc/init.d/S50webcam restart'
# measure, then revert:
ssh root@<printer-ip> 'rm -f /usr/data/nebulaos/maintenance/camera-fps-mode && /etc/init.d/S50webcam restart'

# C2 (idle pause)
ssh root@<printer-ip> 'mkdir -p /usr/data/nebulaos/maintenance && echo C2 > /usr/data/nebulaos/maintenance/camera-idle-mode && /etc/init.d/S51nebulaos-camera-idle-controller restart'
```

For C2, run the mission's own required repetition counts: 100 pause/
resume cycles (view the stream, let it idle past the grace period,
repeat), 20 `S50webcam restart` cycles, 20 USB-storage insert/remove
cycles, 5 warm reboots, 3 cold boots, a request immediately after boot,
a request after a long idle period, and multiple simultaneous viewers.
Explicitly check GuppyScreen's own camera panel (source-unavailable, so
this can only be confirmed live) and Mainsail's camera panel throughout.

**Accept/reject**: per the criteria doc's camera sections.

## 7. Combined Wi-Fi and camera tests

Run each frozen-candidate combination together (not just each in
isolation): the selected Wi-Fi configuration + each camera mode, all
under one Mainsail client + camera stream + Moonraker WebSocket traffic +
GuppyScreen active + a USB storage read, per
`NEBULAOS_CAMERA_USB_RT_SOURCE_ANALYSIS.md` sec 18.18 Stage D.

## 8. Final Wi-Fi/camera selection

Record the decision explicitly - a real table, not an impression:

| Area | Final selection | Justifying measurement |
|---|---|---|
| Stable MAC | | |
| SDIO variant | | |
| Wi-Fi power save | | |
| Wi-Fi boot wait | | |
| Camera active mode | | |
| Camera idle mode | | |

Then **freeze**: rebuild once with exactly the selected combination
(`wifi-sdio-variant.sh <selected>`, the selected camera/power-save
markers baked into the overlay defaults if they're being promoted from
experimental to production - see "Phase 9: freeze" below for what
"baked in" should mean precisely), and do not touch these again except
to fix a qualification failure.

## 9. PREEMPT versus PREEMPT_RT (Phase A8)

Only after step 8's freeze. Build R0 and R1 from the *exact* same frozen
Wi-Fi/camera configuration:

```
sh scripts/build/preempt-variant.sh R0   # (or confirm already R0)
# ... full 00-06 pipeline, package as B0-frozen ...
sh scripts/build/preempt-variant.sh R1
# ... full 00-06 pipeline, package as B4 ...
```

Flash and measure both per the criteria doc's PREEMPT_RT section -
`cyclictest` (Phase A8's diagnostic tooling, not part of the production
image - build a separate diagnostic rootfs or install it manually over
SSH for this test only), idle CPU, context switches, DWC2 IRQ-thread
behavior, camera frame continuity, Wi-Fi packet loss/latency, MCU/UART
stability, boot time. **Reject before any physical print test** if any
rejection criterion trips.

## 10. Final configuration freeze

Once R0 or R1 is selected, this is the last configuration change of the
whole mission - no new optimization experiments, no unrelated refactors,
no dependency upgrades from this point on. Only fixes for qualification
failures may still land.

## 11. Production Phases 13-17

Per the mission's own text:

- **Phase 13**: clean production build with `NEBULAOS_REQUIRE_CLEAN_TREE=1`
  (Phase A2's own gate) from the frozen, fully-committed source; zero
  unexpected `06-verify.sh` MISS lines; final SquashFS/kernel-config/DTB/
  manifest all inspected directly (`unsquashfs -l`, not just a clean
  verify run - this project's own "never trust exit 0 alone" rule).
- **Phase 14**: safe A/B deployment via the exact `flash-spare-slot.sh`
  sequence used throughout this runbook (read-only check, review, real
  write, separate OTA marker flip, separate reboot).
- **Phase 15**: complete qualification - non-motion (Klipper/MCU/
  Moonraker/Mainsail/GuppyScreen/camera/Wi-Fi/SSH/USB storage/persistent
  identities) then physical (homing/mesh/heating/extrusion/pause/resume/
  cancel/a complete controlled test print), with the selected camera mode
  + Mainsail + GuppyScreen + USB storage all active during the print.
- **Phase 16**: update/rollback/persistence verification across ordinary
  reboot, cold boot, fresh namespace, offline first boot, app updates,
  rollback, A/B rootfs/kernel switch, camera/Wi-Fi/Dropbear identity
  persistence, printer config/database persistence.
- **Phase 17**: update every doc this mission touched (this runbook,
  `NEBULAOS_CAMERA_USB_RT_SOURCE_ANALYSIS.md`,
  `NEBULAOS_PRODUCTION_OPTIMIZATION_IMPLEMENTATION.md`, `FIRMWARE.md`)
  with the actual final decisions and measurements, then tag:
  `nebulaos-production-optimized-<actual-completion-date>`.

## Mandatory stop conditions (reproduced from the mission text - do not
proceed past any of these without stopping and reconciling first)

Source or running-image provenance cannot be reconciled; a vendor pin
remains moving or ambiguous; an A/B pair differs in more than the
intended variable; the stable-MAC design could duplicate addresses
across printers; a unit-specific MAC enters the factory image; Wi-Fi
fails to enumerate; SDIO CRC/timeout/firmware-reset errors increase;
association or DHCP becomes unreliable; camera resume is unreliable;
GuppyScreen loses camera compatibility; USB storage hotplug regresses;
PREEMPT_RT causes camera frame loss or excessive DWC2 IRQ-thread
overhead; Klipper MCU statistics regress; UART errors increase; boot
time regresses materially with no compensating benefit; the active
rootfs/kernel slot would be flashed; fallback/rollback is endangered; a
controlled print cannot complete safely.
