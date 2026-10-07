# Acknowledgements

RosetteOS doesn't exist in a vacuum. It is built upon the dedicated bring-up and stabilization work originally performed under the **NebulaOS** project, as well as the broader open-source 3D printing community. This page gives credit where it's actually due, based on what's really in the repo and its history.

## NebulaOS Origins & Foundation

RosetteOS is a direct open-source fork of **NebulaOS** (`coreflake1/NebulaOS-firmware`). RosetteOS still uses all of NebulaOS's companion Klipper extensions ([`NebulaOS-klipper-extensions`](https://github.com/coreflake1/NebulaOS-klipper-extensions)), which provide vital hardware support: PRtouch strain-gauge loadcell probing, autonomous Z-offset compensation, bitbanged SPI for the ADXL345 accelerometer, EEPROM bus integration, and power-loss recovery. The Linux 6.6 kernel port, devicetree bindings, and rootfs architecture represent the deep engineering groundwork established by NebulaOS.

## Pellcorp

A meaningful amount of the groundwork for this project's build and firmware work traces back to
[Pellcorp's](https://github.com/pellcorp) Creality K1/K1-family tooling. Specifically:

- **[`pellcorp/klipper`](https://github.com/pellcorp/klipper)** — used as a reference to verify the
  sign convention in our own probe/Z-compensation code while building `z_compensate.py`.
- **[`pellcorp/k1-ustreamer`](https://github.com/pellcorp/k1-ustreamer)** — RosetteOS's camera
  pipeline is a real port of this project (`K1_USTREAMER_REPO`/`K1_USTREAMER_PIN`).
- **`pellcorp/k1-bash-build`** — for a long time, this was the actual MIPS cross-compile toolchain
  container this project's build (and GuppyScreen's) ran inside. As of the unified build environment
  work (2026-08-15), both now use RosetteOS's own build image instead — but that image bundles the
  same toolchain this container provided, and its build recipe was faithfully reconstructed from the
  original image rather than replaced with something different. We're not still using the container,
  but the groundwork it represents is still part of how this builds.
- **[`pellcorp/k1-nginx`](https://github.com/pellcorp/k1-nginx)** — GuppyScreen's vendoring scripts
  use this project's build recipe to cross-compile nginx for the K1 platform.

If you're coming from the Pellcorp/K1 side of the Creality modding world, a good chunk of what made
this project possible started there.

## GuppyScreen lineage

RosetteOS's touchscreen UI builds on:

- [`ballaswag/guppyscreen`](https://github.com/ballaswag/guppyscreen) — the original GuppyScreen project
- [`probielodan/guppyscreen`](https://github.com/probielodan/guppyscreen)
- [`prestonbrown/guppyscreen`](https://github.com/prestonbrown/guppyscreen) — source of the interactive 3D bed mesh
- [`pellcorp/grumpyscreen`](https://github.com/pellcorp/grumpyscreen) — bug fixes and improvements

## Recovery tooling

The USB recovery path documented in `docs/DEVELOPER_RECOVERY.md` and
`docs/HOW_TO_SWITCH_STOCK_AND_CUSTOM.md` only exists because of
[`ballaswag/ingenic-usbboot`](https://github.com/ballaswag/ingenic-usbboot) — genuinely couldn't
do that recovery path without it.

## The rest of the stack

- [Klipper](https://github.com/Klipper3d/klipper) and [Moonraker](https://github.com/Arksine/moonraker) — the printer firmware and API server this whole thing runs on
- [Mainsail](https://github.com/mainsail-crew/mainsail) — the web UI
- [Buildroot](https://buildroot.org/) — the base of our whole build system
- The Linux kernel, and the Ingenic X2000 SDK/BSP this board's kernel support is built from
- Creality, for the original K1/KE hardware and SDK source this project builds on top of

## License note

This page is informational — it doesn't replace or override any actual license or copyright notice.
See [`LICENSES/`](LICENSES/) for the real license terms covering this project's own code and
everything it vendors or fetches.
