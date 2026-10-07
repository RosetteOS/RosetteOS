# RosetteOS Firmware

This repository builds **RosetteOS**, a custom, fully open-source Linux + Klipper distribution for the **Creality Nebula Pad** hardware platform — featuring a real Linux 6.6 kernel, upstream Klipper, Moonraker, Mainsail, and a dedicated GuppyScreen touchscreen interface, replacing stock firmware binary blobs with clean, auditable code. Rosette is the project name; RosetteOS is the operating system.

While the **Creality Ender-3 V3 KE** serves as our primary reference implementation and development baseline, RosetteOS is architected with a modular multi-printer profile system. The project's vision and roadmap is to **support all 3D printers that Creality's Nebula Smart Kit supports** (including the Ender-3 V3 SE, Ender-3 V2, Ender-3 V2 Neo, Ender-3 S1, Ender-3 Pro, Ender-3 Base, CR-10 SE, and other models driven by the Nebula Pad).

**RosetteOS continues the open-source work of [NebulaOS](https://github.com/coreflake1/NebulaOS-firmware) and uses NebulaOS's Klipper extensions** ([`NebulaOS-klipper-extensions`](https://github.com/coreflake1/NebulaOS-klipper-extensions)). These extensions provide critical host-side hardware integration — including PRtouch loadcell probing, autonomous Z-compensation, power-loss recovery (PLR), and sensor support.

If you want to build the whole OS, this is the repo you want. The full RosetteOS/System
OKE checkout supplies both the kernel and Buildroot; official upstream Klipper plus all of NebulaOS's Klipper extensions and RosetteOS/GuppyScreen supply the application stack. The build refreshes moving sources, verifies immutable inputs, and puts the whole thing together into a verified flashable image.

```
RosetteOS/System ─┐
Mainline Klipper + extras ┼─►  RosetteOS  ─►  final rootfs + kernel + SWUpdate package
GuppyScreen (OKE) ───────┘   (this repo)
```

- [`RosetteOS/System`](https://github.com/RosetteOS/System) — full OKE checkout providing Linux 6.6 (`kernel/kernel-6.6`) and Buildroot (`buildroot/`)
- [`Klipper`](https://github.com/Klipper3d/klipper) — official upstream Klipper runtime (`master` branch)
- [`NebulaOS-klipper-extensions`](https://github.com/coreflake1/NebulaOS-klipper-extensions) — all of NebulaOS's companion Klipper extensions powering hardware integration (`prtouch_v2`, `z_compensate`, `nebulaos_power_loss_recovery`, `nebulaos_compat`)
- [`GuppyScreen`](https://github.com/RosetteOS/GuppyScreen) — touchscreen UI
- [Firmware releases](https://github.com/RosetteOS/RosetteOS/releases) — firmware releases and SWUpdate packages

The build records every external input in `manifests/dependencies.conf`. Immutable sources are
pinned by exact commit, tag, archive hash, or container digest. The kernel and Buildroot use the pinned RosetteOS/System commit, while mainline Klipper uses the upstream commit qualified by the pinned extensions manifest; the hardware extras source is pinned separately, and GuppyScreen follows
RosetteOS/GuppyScreen. The exact fetched commits are recorded in
`build-manifest.txt`. The build reuses `vendor/system` when it matches `SYSTEM_PIN`, refreshes the
remaining moving checkout, and does not use unrelated local clones sitting next to this repo.

## Building it

```sh
git clone https://github.com/RosetteOS/RosetteOS.git
cd RosetteOS
./build.sh
```

That's genuinely it. `build.sh` pulls one build container
(`ghcr.io/rosetteos/rosetteos-build`, digest-pinned) and runs the whole pipeline inside it —
fetches every dependency, applies the 8 accepted kernel variants, builds the kernel/rootfs/app
stack, and checks the result actually looks right. You need Docker or Podman and not much else —
no `apt-get install` beforehand, no nested containers, nothing weird.

Budget ~15GB of disk and a few hours on a normal machine. It needs the network the whole time,
since everything gets fetched and hash-checked as it goes.

RosetteOS uses official upstream Klipper with host-side extras copied into its
`klippy/extras/` directory during the build. Printer configuration remains in the tracked overlay
(`printer.cfg`, `frontend-controls.cfg`, and `moonraker.conf`); there is no separate runtime injection
step. The webcam pipeline remains the pinned
[`pellcorp/k1-ustreamer`](https://github.com/pellcorp/k1-ustreamer) integration.

If you want to see what's actually happening under the hood, `build.sh` runs these in order
(details in `scripts/build/README.md`):

```sh
cd scripts/build
./00-fetch-vendor-sources.sh
./01-apply-kernel-patches.sh
./02-configure-buildroot.sh
./03-build-kernel-and-rootfs.sh
./04-cross-compile-app-stack.sh
./05-final-build.sh
./06-verify.sh
```

When it's done, you'll have `xImage`, `rootfs.ext2`, and `rootfs.squashfs` in
`artifacts/buildroot-halley5-v30-image/`, plus `build-manifest.txt` (records exactly what went
into this build) and `kernel.config`. `rootfs.ext2` is configured as a 500 MiB filesystem so the
complete application stack fits reliably; `rootfs.squashfs` is the compressed deployment image.
GuppyScreen's compiled binary shows up separately in
`artifacts/guppyscreen-mips/`. The last stage sanity-checks that everything is real, correctly
architected MIPS32 output — it's not claiming byte-for-byte reproducibility between two separate
builds (timestamps and a few build-path strings will differ), just that the same code went in and
came out right.

## Don't build the other three repos on their own

Cloning the kernel, Klipper, or GuppyScreen repository by itself and trying to build it will not
produce a working printer image — none of those repositories contains the complete board image. This
repo fetches the kernel, mainline Klipper plus the hardware extensions, GuppyScreen, Moonraker, the retained
`k1-ustreamer` webcam stack, Buildroot, and the tracked overlay, then assembles the
flashable result.

## How reproducible is this, really

Immutable inputs in `manifests/dependencies.conf` are exact commits, tags, archive hashes, or
digests and are checked on every run. The pinned System, mainline Klipper, and GuppyScreen commits
are recorded in `build-manifest.txt`; the hardware extras source is checked against its
manifest pin. The 8
kernel variants we build on top of the OKE branch (PREEMPT_RT,
a WiFi SDIO IRQ priority fix, VSYNC-gated display panning, a pinctrl ownership fix, the final
backlight controller, PWM state readback, the final touch driver, and disabling WiFi roaming) live
as small, order-independent scripts under `scripts/build/`, applied by
`scripts/build/apply-qualified-baseline.sh`.

## Project history and hardware scope

RosetteOS continues the open-source work of **NebulaOS** (`coreflake1/NebulaOS-firmware`), maintaining and advancing its modern Linux and Klipper stack under the [`RosetteOS`](https://github.com/RosetteOS) organization.

RosetteOS continues to rely on **NebulaOS's Klipper extensions** ([`NebulaOS-klipper-extensions`](https://github.com/coreflake1/NebulaOS-klipper-extensions)), preserving compatibility with the hardware's strain-gauge loadcells, auto Z-offset calibration routines, and EEPROM state. It builds on this foundation with dual-slot SWUpdate streaming upgrades, refined UI workflows, and system resilience.

### Hardware Scope & Nebula Smart Kit Printer Roadmap

Rather than being limited to the Ender-3 V3 KE, RosetteOS is designed around the **Creality Nebula Pad** hardware platform (MIPS Ingenic XBurst2 X2000 SoC). It plans to support the complete family of printers compatible with the **Creality Nebula Smart Kit**:

- **Primary Reference Baseline**: **Creality Ender-3 V3 KE** — fully tested and validated hardware baseline, including PRtouch strain-gauge loadcells, auto Z-offset calibration (`z_compensate`), bed tilt calculation, and ADXL345 resonance testing.
- **Nebula Smart Kit Family Roadmap**:
  - **Ender-3 V3 SE** (GD32F303 MCU, CR-Touch + strain-gauge auto-Z)
  - **Ender-3 V2 Neo** (STM32F103 MCU, CR-Touch probe-assisted tramming)
  - **Ender-3 S1** (STM32F103 / STM32F401 MCU, Sprite direct drive + CR-Touch)
  - **Ender-3 V2 / Ender-3 Pro / Ender-3 Base** (v4.2.2 / v4.2.7 silent boards, physical endstops or optional BLTouch)
  - **CR-10 SE** and other Creality machines powered by or upgraded with the Nebula Pad.

RosetteOS features a native CLI tool (`rosetteos-profile`) and modular configuration seed layer to switch between printer configurations while preserving user calibrations. See [`docs/MULTI_PRINTER_SUPPORT.md`](docs/MULTI_PRINTER_SUPPORT.md) for complete hardware matrices and profile usage.

## If you're setting one of these up yourself

Beyond just building, this repo is also where we keep the docs for installing, updating, and
recovering an actual device — written for developers who already have SSH/root on their printer,
not as a polished installer walkthrough:

- [`docs/MULTI_PRINTER_SUPPORT.md`](docs/MULTI_PRINTER_SUPPORT.md) — multi-printer support matrix, Nebula Smart Kit roadmap, and profile architecture
- [`docs/A_B_SLOT_MODEL.md`](docs/A_B_SLOT_MODEL.md) — how the dual-slot A/B partition layout works
- [`docs/DEVELOPER_INSTALL_FROM_STOCK.md`](docs/DEVELOPER_INSTALL_FROM_STOCK.md) — putting RosetteOS on a printer for the first time
- [`docs/DEVELOPER_UPDATE.md`](docs/DEVELOPER_UPDATE.md) — updating a printer that's already running RosetteOS
- [`docs/DEVELOPER_RECOVERY.md`](docs/DEVELOPER_RECOVERY.md) — what to do if something goes wrong
- [`docs/HOW_TO_SWITCH_STOCK_AND_CUSTOM.md`](docs/HOW_TO_SWITCH_STOCK_AND_CUSTOM.md) — flipping between stock and RosetteOS day to day
- [`docs/BUILD_PROVENANCE.md`](docs/BUILD_PROVENANCE.md) — figuring out exactly what produced a given build
- [`docs/NEBULAOS_FRONTEND_PRINT_CONTROLS.md`](docs/NEBULAOS_FRONTEND_PRINT_CONTROLS.md) — the upstream-Klipper frontend configuration closure
- [`docs/NEBULAOS_BUILD_ENVIRONMENT.md`](docs/NEBULAOS_BUILD_ENVIRONMENT.md) — what's actually in the build container
- [`ACKNOWLEDGEMENTS.md`](ACKNOWLEDGEMENTS.md) — the upstream projects, NebulaOS roots, and prior work this stands on

The other repos (kernel, Klipper, GuppyScreen) all link back here instead of keeping their own copies of this documentation — this is the
one place it's kept up to date.

## History

This repo used to be a broader research workspace called `ke-mainline-klipper`. That history —
hardware bring-up notes, root-cause writeups, the mission-by-mission log — is still here, in
[`docs/HISTORY.md`](docs/HISTORY.md) and the rest of `docs/`. `FIRMWARE.md` is the long-form
technical reference for the build internals, if you want the deep version of any of this.

## License

See [`LICENSES/`](LICENSES/) for this project's own code and everything it vendors or fetches.
