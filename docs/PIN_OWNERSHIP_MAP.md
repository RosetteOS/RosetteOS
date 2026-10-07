# Pin Ownership Map (targeted, Phase 3A)

Part of the Nebula Pad stock-parity / board-port audit. Covers only the pins flagged as open
questions by `docs/DTB_PARITY_REPORT.md` - `i2c0`, `uart5`/`6`/`7`, `spi_gpio`, `MSC2`, plus the
already-established WiFi/BT control pins for cross-reference. A full board-wide map (every enabled
pin) is Phase 3B, not attempted here.

All data below is live evidence: `artifacts/parity/{stock,custom}/40-debugfs-gpio.txt` (GPIO claim,
direction, raw level) and `42-debugfs-pinctrl-pinmux-pins.txt` (pinctrl/alt-function claim), captured
at a comparable boot stage on each system per `scripts/parity/capture-state.sh`. Gpio numbering:
`GPA`=0-31, `GPB`=32-63, `GPC`=64-95, `GPD`=96-127, `GPE`=128-159 (`gpio-N` = bank base + offset).

| Pin | Bank/offset | Stock mux claim | Custom mux claim | Stock GPIO owner | Custom GPIO owner | Direction/level (stock) | Direction/level (custom) | Classification |
|---|---|---|---|---|---|---|---|---|
| `GPC-0` | `gpc` offset 0 (`gpio-64`) | `(MUX UNCLAIMED)` at capture time (real alt-function pin for `pwm0`, per `x2000-pinctrl.dtsi`'s `pwm0_pc`) | **Fixed**: no longer claimed by anything | `backlight_pwm0`, `in hi` | **Fixed**: gone from the live GPIO list entirely | in, hi | unclaimed | **RESOLVED** - MSC2 disabled, `72236226a`, verified live |
| `GPC-12` | `gpc` offset 12 (`gpio-76`) | No claim in stock's capture | **Fixed**: no longer claimed | (none) | **Fixed**: gone from the live GPIO list entirely | unclaimed | unclaimed | **RESOLVED** - matches stock's unclaimed state |
| `GPC-5` | `gpc` offset 5 (`gpio-69`) | `10035000.serial` function `uart5-pin` group `uart5-pc` | `(MUX UNCLAIMED)` | (none named) | (none) | muxed to uart5 alt-fn | fully unclaimed | `STOCK_ENABLED_BUT_UNUSED` |
| `GPC-6` | `gpc` offset 6 (`gpio-70`) | `10035000.serial` function `uart5-pin` group `uart5-pc` | `(MUX UNCLAIMED)` | (none named) | (none) | muxed to uart5 alt-fn | fully unclaimed | `STOCK_ENABLED_BUT_UNUSED` |
| `GPA-6` | `gpa` offset 6 | `10036000.serial` function `uart6-pin` group `uart6-pa` | `(MUX UNCLAIMED)` | (none named) | (none) | muxed to uart6 alt-fn | fully unclaimed | `STOCK_ENABLED_BUT_UNUSED` |
| `GPA-7` | `gpa` offset 7 | `10036000.serial` function `uart6-pin` group `uart6-pa` | `(MUX UNCLAIMED)` | (none named) | (none) | muxed to uart6 alt-fn | fully unclaimed | `STOCK_ENABLED_BUT_UNUSED` |
| `GPA-8` | `gpa` offset 8 | `10037000.serial` function `uart7-pin` group `uart7-pa` | `(MUX UNCLAIMED)` | (none named) | (none) | muxed to uart7 alt-fn | fully unclaimed | `STOCK_ENABLED_BUT_UNUSED` |
| `GPA-9` | `gpa` offset 9 | `10037000.serial` function `uart7-pin` group `uart7-pa` | `(MUX UNCLAIMED)` | (none named) | (none) | muxed to uart7 alt-fn | fully unclaimed | `STOCK_ENABLED_BUT_UNUSED` |
| `i2c0` pins | not resolved - no `pinctrl-0` property exists to resolve | No claim anywhere in `42-debugfs-pinctrl-pinmux-pins.txt` | n/a (not present) | (none) | n/a | fully unclaimed | n/a | `STOCK_ENABLED_BUT_UNUSED` (vendor-DT residue - no pin wiring was ever added) |
| `GPE-16` | `gpe` offset 16 (`gpio-144`) | `(MUX UNCLAIMED)` (expected - bit-banged) | n/a | `spi_gpio`, `out hi` | (none) | out, hi | n/a | `REAL_STOCK_FUNCTION` (SPI SCK or MOSI, bit-banged) |
| `GPE-17` | `gpe` offset 17 (`gpio-145`) | `(MUX UNCLAIMED)` | n/a | `spi_gpio`, `out hi` | (none) | out, hi | n/a | `REAL_STOCK_FUNCTION` |
| `GPE-18` | `gpe` offset 18 (`gpio-146`) | `(MUX UNCLAIMED)` | n/a | `spi_gpio`, `in hi` | (none) | in, hi | n/a | `REAL_STOCK_FUNCTION` (likely MISO) |
| `GPE-21` | `gpe` offset 21 (`gpio-149`) | `(MUX UNCLAIMED)` | n/a | `spi2.0` (chip-select), `out hi` | (none) | out, hi | n/a | `REAL_STOCK_FUNCTION` - named child device confirms a real, bound SPI peripheral exists |
| `GPA-1` | `gpa` offset 1 (`gpio-1`) | (unnamed on stock in this capture format for GPA - see note) | `wifi_bt_power_regula` | `bt_wifi_power`, `out lo` | `out lo, ACTIVE LOW` | out, lo | out, lo (correctly annotated active-low) | `PARITY_CONFIRMED` - shared WiFi/BT rail, same raw electrical state, cross-referenced against this project's own earlier fix (kernel fork history) |
| `GPD-4` | `gpd` offset 4 (`gpio-100`) | `wlan_reg_on`, `out hi` | `wlan-reg-on`, `out hi` | out, hi | out, hi | out, hi | out, hi | `PARITY_CONFIRMED` |
| `GPD-5` | `gpd` offset 5 (`gpio-101`) | `bt_reg_on`, `out hi` | **not present in custom's capture at all** | out, hi | (none) | out, hi | unclaimed | **New finding, see below** |

## New finding: stock has a dedicated `bt_reg_on` pin custom never claims

Stock's live GPIO dump shows **two separate** reg-on pins: `GPD-4` (`wlan_reg_on`) and `GPD-5`
(`bt_reg_on`), both driven `out hi`. Custom's WiFi work (this project's own, extensively documented
`WL_REG_ON` investigation) only ever identified and drove `GPD-4`. `GPD-5`/`bt_reg_on` does not
appear anywhere in custom's debugfs GPIO capture - it's not claimed by anything.

This is a real, previously-unknown difference, surfaced by this audit rather than the original WiFi
bring-up work (which was scoped to WiFi only, and succeeded without ever needing this pin - the
combo chip's BT side apparently doesn't require its own reg-on toggle to at least power up, since
custom's WiFi works fine without ever touching `GPD-5`). It may explain part of why BT doesn't work
on custom beyond the already-documented `uart3`/`i2c4` pin-sharing conflict - even if the UART pins
were freed up, BT might still need this dedicated enable line raised.

**Follow-up (bounded, read-only investigation, no pin driven on stock)**: on the same real, working
stock device, `rfkill list` shows a real, unblocked `bluetooth` entry (not soft/hard blocked), and
`ps` shows live kernel worker threads `btudpwork` and `btfwwork` (Broadcom BT firmware-loading
workqueues) actively running. `bt_reg_on` was `out hi` at every point checked, from early boot
through steady state - no toggling observed (though this session's captures were all snapshots, not
a continuous scope trace).

**Classification: `BT_POWER_REQUIRED` (high confidence, not 100% proven).** The combination of a
real rfkill device, live BT firmware-loading kernel threads, and a steadily-high dedicated GPIO is
strong, converging evidence that raising `GPD-5` is a real precondition for BT power, independent of
`PA01` (the shared rail) and `WL_REG_ON`. **Not implemented on custom in this pass** - per the safety
rules, this needs correct polarity, power/reset ordering, delay requirements, and UART association
worked out as a real, separate feature proposal before any pin is driven, not just copying stock's
raw-HIGH value blind.

## `uart1` (printer MCU link) - fixed and verified

Not in this map's original scope, but found during the same audit and fixed before this document
was finalized: `uart1` claimed a 4-pin group (`GPC-21..24`) where stock only claims 2
(`GPC-23`/`24`), and `GPC-21` was simultaneously claimed by `lcd_vdd_en` as a plain GPIO output - a
real, active conflict, not hypothetical. Fixed in kernel fork commit `970bd6b83` (new board-local
`uart1_pc_txrx` group, `gpc 23-24` only) and verified live: `GPC-21`/`GPC-22` now read
`(MUX UNCLAIMED)`, `lcd_vdd_en` is `GPC-21`'s sole owner, `uart1` claims only `GPC-23`/`24`. Full
details: `docs/PRINTER_MAINBOARD_PRECONNECTION_CHECKLIST.md`.

## `uart1` register-level, clock, and protocol equivalence proof (Phase B, software-only, 2026-07-23)

Printer-port parity audit, software-only equivalence pass. Method: `devmem`/`/dev/mem` MMIO peeks,
`stty -F /dev/ttyS1 -a` (opens and queries termios without transmitting arbitrary data), and
`/sys/class/tty/ttyS1/*` sysfs attributes, captured on both stock and custom in the same physical
session (reboot cycle between captures, marker-verified each time). No mainboard connected for
either capture.

**MMIO/clock/driver identity** (`/sys/class/tty/ttyS1/*`) - bit-for-bit identical on both systems:

| Attribute | Stock | Custom | Equal? |
|---|---|---|---|
| `uartclk` | `150000000` | `150000000` | YES |
| `irq` | `54` | `54` | YES |
| `iomem_base` | `0x10031000` | `0x10031000` | YES |
| `io_type` | `2` | `2` | YES |
| `type` | `1` | `1` | YES |
| `line` | `1` | `1` | YES |

**UART register values** (`devmem`, standard 16550 offsets from base `0x10031000`):

| Register | Offset | Stock raw (cold, pre-any-open-by-us) | Custom raw (cold, before `stty`) | Custom raw (after `stty -F /dev/ttyS1 -a`) | Meaning | Equivalent? |
|---|---|---|---|---|---|---|
| IER | `+0x04` | `0x00000000` | `0x00000000` | (not re-read) | interrupts masked, idle | YES |
| LCR | `+0x0C` | `0x00000013` | `0x00000000` | `0x00000013` | 8 data bits / 1 stop / no parity | YES once opened - see note below |
| MCR | `+0x10` | `0x00000000` | `0x00000000` | (not re-read) | modem control idle, no RTS asserted | YES |
| LSR | `+0x14` | (not captured) | `0x00000060` | (not re-read) | THRE+TEMT set - clock genuinely running, TX FIFO empty | consistent |

**Note on the stock LCR value being pre-set:** stock's `0x00000013` was already present *before we
touched anything* on that boot. Root cause found in Phase D (below): `/etc/init.d/S13mcu_update`
runs `mcu_util -i /dev/ttyS1 -c` (a handshake attempt) automatically at boot, which opens the port
and programs the same 8N1 framing our own `stty` query produced on custom. This is not a
driver-default - it's evidence stock's own boot sequence already exercises this exact UART, for the
exact same purpose we're auditing it for.

**Pin-controller ownership** (`/sys/kernel/debug/pinctrl/*/pinmux-pins`, `/sys/kernel/debug/gpio`):

| Pin | Stock | Custom (post-fix) | Equivalent? |
|---|---|---|---|
| `GPC-23` (pin 87) | `10031000.serial (GPIO UNCLAIMED) function uart1-pin group uart1-pc` | `10031000.serial (GPIO UNCLAIMED) function uart1-pin group uart1-pc-txrx` | YES - same device/function, group name is our own more specific rename |
| `GPC-24` (pin 88) | same pattern as `GPC-23` | same pattern as `GPC-23` | YES |
| `GPC-21` (pin 85) | `(MUX UNCLAIMED)`; GPIO owner `lcd_power_en`, captured `in lo` | `(MUX UNCLAIMED)`; GPIO owner `lcd_vdd_en`, captured `out hi` | Same purpose/pin, not claimed by `uart1` on either - **EXPECTED_DIFFERENCE** on direction/level (different boot-sequence timing/naming, not a `uart1` concern, tracked separately, not a printer-port signal) |
| `GPC-22` (pin 86) | `(MUX UNCLAIMED)`; GPIO owner `backlight_pwm0`, `out lo` | fully unclaimed (`MUX UNCLAIMED`, `GPIO UNCLAIMED`) | Neither claimed by `uart1` - **EXPECTED_DIFFERENCE**, not a printer-port signal, noted for a future LCD-parity pass, out of scope here |

**Voltage domain - resolved definitively, no reboot needed.** `pinctrl-ingenic.c`
(`module_drivers/drivers/pinctrl/pinctrl-ingenic.c:1966-1992`) only ever reads two DT voltage
properties by hardcoded name: `ingenic,gpa_voltage` (bank A) and `ingenic,gpe_msc_voltage` (bank
E/MSC). There is no code path anywhere in this driver that reads a `gpc_voltage` property for any
bank. This means `GPC`'s I/O voltage is a fixed hardware characteristic on this SoC, not a
DT/software-configurable one - **stock and custom cannot differ here by construction**, since
neither system's devicetree has any mechanism to set it differently. Custom's own DTB confirms this:
`ingenic,gpa_voltage = 0x00000002` (`GPIO_VOLTAGE_3V3`) is the *only* voltage property present under
`/proc/device-tree/apb/pinctrl@10010000/`, and `GPC` has no such property node at all.

**Conclusion:** `uart1`'s SoC-level identity (clock, IRQ, MMIO base, register semantics, pin-mux
ownership, voltage-domain determinism) is fully equivalent between stock and custom. This closes the
"voltage domain" and "printer UART pinmux/idle-level" gate criteria in
`docs/PRINTER_MAINBOARD_PRECONNECTION_CHECKLIST.md` without any physical instrument.

## MSC2 disable - fixed and verified

Kernel fork commit `72236226a` disables `&msc2`. Verified live: `mmc2` no longer appears under
`/sys/bus/mmc/devices` (only `mmc0`/`mmc1`), `GPC-0` and `GPC-12` no longer appear anywhere in the
GPIO claim list, `mmc0`/`mmc1` probe identically to before, and the pre-existing
`gpiod_set_value_cansleep: invalid GPIO (errorpointer)` warnings are unchanged - confirming they
were never MSC2-related.

## `GPD-4`/`GPD-5` also claimed by BAIC4 audio - real two-device conflict, root-caused, not fixed

Boot-cleanup mission Phase 3A/3B (2026-07-23): the `ingenic_gpio_request: GP:GPD ... gpio functions
has redefinition` warning with a full kernel backtrace, present in every boot log since the first
capture, was root-caused via temporary instrumentation (kernel fork `41598d0b3`, reverted
`8d4756c62` once the finding was confirmed - see `docs/BOOT_WARNING_AUDIT.md`).

**The mechanism**: `pinctrl-ingenic.c` tracks pin ownership in a per-bank `used_pins_bitmap` two
different ways - once inside `ingenic_gpio_request()` (the plain-GPIO consumer path, e.g.
`devm_gpiod_get_optional()`), and independently inside the pinmux-group-parsing path
(`jzgc->used_pins_bitmap |= grp->pinmux_bitmap;`, fired whenever ANY device's `pinctrl-N` property
references a group covering that bank - not gated behind any conflict check at all). Only the first
path prints a warning; the second silently sets the same bits.

**The conflict**: `&as_be_baic` (a real, enabled, successfully-probing audio device - confirmed live:
`as-baic 134d5000.as-baic: baic platform probe success`) sets `pinctrl-0 = <&baic4_pd>;`
(`halley5_v30.dts:721-724`). `baic4_pd`'s own definition is `ingenic,pinmux = <&gpd 2 5>;`
(`x2000-pinctrl.dtsi:576`) - covering `GPD-2` through `GPD-5`, which **includes `GPD-4`/`GPD-5`**,
the exact same pins already documented above as `wlan_reg_on`/`bt_reg_on`. `as_be_baic` probes early
(around the same window as the display/audio subsystem, well before `msc1`'s own probe), marking
`GPD-4`/`GPD-5` "used" via the pinmux-group path. When `msc1`'s `sdhci_ingenic_probe()` later
acquires `wlan-reg-on-gpios` (`&gpd 4 ...`, `halley5_v30.dts:513`) as a plain GPIO, it finds the bit
already set and prints the warning + backtrace - confirmed directly via instrumented logging:
`ROSETTEOS-DIAG: SECOND/CONFLICTING request for GPD-4 (global gpio 100)`, immediately followed by
`wlan-reg-on -> acquired` (the underlying `pinctrl_gpio_request()` call happens regardless of the
warning and succeeds every time).

**Classification: `REAL_TWO_DEVICE_PIN_CONFLICT`** (not a bookkeeping false-positive, not a duplicate
request from the same device) - the SoC's own pin multiplexer genuinely offers `GPD-4`/`GPD-5` as
either plain GPIO or part of BAIC4's audio group, and this board's DTS references both uses on
different nodes. Both currently work (WiFi/BT reg-on GPIOs end up correctly acquired; `as_be_baic`
probes successfully) - this is presently a noisy-but-harmless warning, not a functional break, unlike
the earlier `uart1`/`lcd_vdd_en` conflict this project already fixed (which had a real behavioral
consequence).

**Not fixed this pass.** Disabling `&as_be_baic`'s pin claim would require positive evidence it
serves no real product audio function on this board - the project's own confirmed, working audio
path is via `icodec`/speaker (`x2000-sound sound: Sound Card successed`), a different interface, but
that doesn't by itself prove BAIC4 is unused. Per the mission's own explicit guardrails ("do not
release a pin owned by another device," "do not disable a controller until stock behavior and
product use are known"), this is documented and left alone pending a dedicated, separate
investigation into BAIC4's actual product role - not bundled into this boot-cleanup cycle.

**Update (2026-07-23, beeper/BAIC4 investigation mission): resolved as a side effect, not a direct
fix.** The separate BAIC4 audio investigation (`docs/BAIC4_AUDIO_INVESTIGATION.md`) removed
`&as_be_baic`'s `pinctrl-0 = <&baic4_pd>` claim entirely (kernel fork `cafd5986c`) once it was
confirmed the DMIC/BAIC4 DAI links were unreachable dead references, unrelated to this pin-conflict
question at the time. Verified live on the final cleanup mission's rebuilt/reflashed image
(2026-07-23): a full post-boot `dmesg` (234 lines) has **zero** matches for `redefinition`,
`used_pins_bitmap`, `GPD`, `conflict`, `already requested`, `Call Trace`, or `backtrace` - the
warning is completely gone, not merely quieter. `wlan_reg_on`/`bt_reg_on` (`GPD-4`/`GPD-5`) now claim
cleanly with no contention, and `as_be_baic` no longer touches those pins at all (confirmed via
current DTS: `&as_be_baic {};`, empty override). Classification upgraded from
`REAL_TWO_DEVICE_PIN_CONFLICT` (root-caused, not fixed) to **`RESOLVED`**.

## `GPB-2` / `Speaker_en` - real software wiring, hardware presence unconfirmed

Final cleanup mission Phase 2 (2026-07-23): `ingenic,spken-gpio = <&gpb 2 GPIO_ACTIVE_HIGH
INGENIC_GPIO_NOBIAS>;` appears twice in `halley5_v30.dts` - once on `&icodec` (line 779) and once on
the standalone `sound` node (line 812), both resolving to global GPIO 34.

**Only one of the two is live.** `CONFIG_SND_ASOC_INGENIC_ICDC_INNO=y` selects `icdc_inno.c` (v1) as
the compiled codec driver; that file never reads `ingenic,spken-gpio` from its own `of_node` at all
(only the uncompiled `icdc_inno_v2.c` does). The `&icodec` node's property is dead by construction,
confirmed via source read, not inference. The `sound` node's copy of the same property **is** read,
by this board's own machine driver (`halley5_v20.c`, `CONFIG_SND_ASOC_INGENIC_HALLEY5_V20=y`), and is
the one behind the single boot-log line `Speaker enable pin(34) request ok` (confirmed in
`artifacts/parity/baseline-2026-07-23-boot-cleanup/dmesg-final-beeper-baic4-fix-part1.txt:114`,
immediately followed by `x2000-sound sound: Sound Card successed`) - no conflict, no error, no
duplicate-claim warning anywhere in the log.

`halley5_v20.c` wires this pin to a real, functional ALSA control (`SOC_SINGLE_BOOL_EXT("Speaker
Enable", 0, spken_get, spken_put)`) - this is live software, not vendor dead code like the LO_MUX
case. Live device state: `gpio-34 ( |Speaker_en ) out lo` (claimed, driven low/disabled at the time
checked; `amixer` isn't installed on the custom rootfs, so the control was inspected via `/sys/kernel/
debug/gpio`, not exercised live).

**Stock-side evidence is entirely negative but not conclusive**, because stock is a different kernel
generation (4.4.94) that may configure audio outside devicetree: stock's own live, decoded DTB
(`vendor/device-backups/stock-live-device-tree-decoded.dts`, 1726 lines) has zero `spken`/`speaker`
matches and no `sound {` node at all; stock's real rootfs (extracted from `vendor/device-backups/
nebula_system_backup.bin` via `sgdisk`+`dd`+`unsquashfs`, no root required) ships `amixer`/`aplay`/
`alsamixer` binaries but its init scripts (`S97webrtc`, `S13board_init`, `S70cx_ai_middleware`,
`S99start_app`) never invoke them. A generic reference-tree search (`vendor/x2000_kernel`, a
non-Ingenic-specific mainline-style source tree with no board-file evidence either way) was
inconclusive and added nothing.

**Classification (superseded): was `UNKNOWN_REQUIRES_PCB_EVIDENCE`, now `RESOLVED`.** At the time
this was written, the GPIO claimed cleanly with zero boot noise and no positive evidence either way.
The functional production-baseline mission (2026-07-23) resolved the underlying question directly:
Phase 1 booted the exact stock firmware and found stock never uses ALSA at all (`ALSA device list:
No soundcards found.`, empty `/proc/asound`, and stock's real production stack - Klipper/GuppyScreen
- has zero audio consumer). Phase 2 disabled the entire PCM/ALSA graph as a result, which removes
this GPIO's only live consumer (the `sound` node's `ingenic,spken-gpio` property) along with it - the
pin is no longer requested at all. Do not conflate this with the beeper; they were always provably
independent hardware paths (different GPIO banks, different subsystems, beeper bypasses ALSA/
kernel-PWM entirely via `/dev/mem`), and the beeper is completely unaffected by this disable.

## Not yet covered (Phase 3B)

This pass only covers the pins in dispute. The full board pin map (eMMC, WiFi SDIO, display, touch,
USB, camera, all UARTs/I2C/SPI, PWM, ADC, RTC, watchdog, audio, Ethernet, buttons, external
connectors) is Phase 3B, done after the high-risk items above are resolved, per the mission's own
phase ordering.
