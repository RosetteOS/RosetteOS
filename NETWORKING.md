# USB-ethernet adapter compatibility

Track 2 of this workspace (see `README.md`). Motivation: WiFi reliability on this printer is poor
(user's words: "wifi sucks") - a working USB-ethernet adapter would sidestep that entirely. This
investigation is separate from the mainline-Klipper/load-cell track (track 1) but shares the same
underlying platform, so findings here (SoC identity, kernel module mechanism, storage layout) are
useful background for both. All findings below came from **read-only** SSH investigation of the
real, idle printer (2026-07-18) - zero writes made.

**"How hard to build our own full firmware/OS" has its own, more thorough answer now: see
`FIRMWARE.md`** - it supersedes §6 below after reviewing the official Ingenic vendor documentation
already sitting in the RosetteOS workspace's `docs hw/` directory (not reviewed when §6 was first
written) and confirming the real OS (Buildroot, not Ubuntu) directly on the device. §6 is kept
below for the session-by-session record but `FIRMWARE.md` is the current, complete answer with an
actual phased gameplan.

## 1. The adapter itself - detected fine, just no driver

`lsusb` on the printer shows the adapter enumerates correctly at the USB level:

```
Bus 001 Device 003: ID 0b95:1790 ASIX Electronics Corp. AX88179 Gigabit Ethernet
```

Full descriptor read-out (manufacturer "ASIX", product "AX88179B", serial number) - the USB
connection itself is not the problem. But `ip -brief link show` only lists `lo` and `wlan0` - no
network interface exists for it, because no `ax88179_178a`/`usbnet`/`asix` kernel driver is loaded
or present on disk (`find / -iname '*ax88*' -o -iname '*asix*'` - nothing).

## 2. The kernel DOES support loadable modules - corrects an earlier wrong assumption in this same session

Initially assumed (wrongly) that this device runs a monolithic kernel with no module-loading
support, based on `/lib/modules/` not existing and a too-narrow `lsmod | grep net` coming up empty.
That was a mistake - plain `lsmod`/`cat /proc/modules` shows **14 real, loaded, custom kernel
modules**, all `(O)` (out-of-tree) tagged:

```
soc_watchdog, soc_efuse, ns2009_touch, lcd_general_480x272, hci_uart_h5_kernel_4_4_94, cywdhd,
soc_dtrng, soc_msc, soc_fb, soc_fb_layer_mixer, soc_rotator, pwm_backlight, soc_pwm, soc_gpio,
soc_i2c, soc_utils, rmem_manager, utils
```

They live in `/module_driver/*.ko`, each paired with a matching `NAME.sh` init script (that's how
they get (re)loaded at boot - `insmod` itself only affects the current session, nothing persists
across a reboot unless a script like these does it). This is a real, important risk-reducer:
**testing a candidate driver via `insmod` is not a permanent change** - worst case on a bad module
is a hang requiring a manual power cycle, not lasting damage, since nothing auto-persists an
`insmod` unless we deliberately add an init script for it (which we would only do once something is
confirmed working).

Build fingerprint extracted directly via `strings` on an existing `.ko` (no `modinfo` available in
this busybox environment, so read the ELF string table directly):

```
vermagic=4.4.94 SMP preempt mod_unload MIPS32_R2 32BIT
```

Checked for `CONFIG_MODVERSIONS` (per-symbol CRC-checked ABI matching, which would make building a
compatible module far harder): `strings *.ko | grep -c '^__crc_'` returned **0** across the sample
checked - modversions is off, so only this coarse vermagic string needs to match, not per-symbol
CRCs. Meaningfully lowers the bar for building a loadable third-party module.

## 3. Exact hardware identified: Ingenic X2000 (XBurst II, MIPS32R2)

`/proc/cpuinfo` and `dmesg` give a precise, previously-unconfirmed identification:

```
system type            : xburst2-based
machine                 : ingenic,x2000_module_base
cpu model                : Ingenic XBurst@II.V2 V0.0  FPU V0.0
isa                      : mips1 mips2 mips32r2
```

Also visible in `dmesg`: `rtc-ingenic`, `ingenic watchdog probe success` - consistent, real Ingenic
SoC BSP driver naming (`soc_fb`, `soc_rotator`, `rmem_manager`, etc. are characteristic Ingenic BSP
module names, not Creality inventions). `cywdhd.ko` is Cypress/Broadcom's proprietary WiFi+BT
combo "dhd" (Dongle Host Driver) - matches the `dmesg` WiFi bring-up lines seen earlier ("DHD:
dongle ram size...").

**Why this matters**: Ingenic is a real, identifiable vendor with a real community
([`Ingenic-community`](https://github.com/Ingenic-community) on GitHub publishes kernel source
trees for their SoCs), and mainline Linux gained proper X2000/X2000E support as of Linux 5.10 (per
[Phoronix](https://www.phoronix.com/news/Ingenic-X2000-Linux-5.10)). Vendor SoC BSPs typically pin
one specific kernel version per chip generation and licensees (Creality here) build on top of that
exact version without upgrading it - which would explain why this device still runs a kernel
numbered `4.4.94`. **Not yet confirmed, but a real, concrete lead**: Ingenic-community's published
kernel source may be for this same BSP-era kernel version, which would give a genuine, much better
starting point for building a compatible `ax88179_178a`/`usbnet` module than reverse-engineering
blind. This is the single most useful unresolved thread from this session.

Also confirmed: `/proc/kallsyms` is fully populated on this device (56,256 real symbol addresses,
nothing hidden or stripped) - a real, usable resource for resolving kernel symbol
addresses/exports even without an exact source match, a legitimate and commonly-used embedded-Linux
technique (comparable to what router/IP-camera hacking communities do against vendor kernels with
no public source).

## 4. Storage layout (relevant to "build our own OS", section 6 below)

`/proc/mtd` is empty - this device does **not** use raw NOR/NAND flash with classic MTD
partitioning. Storage is eMMC-based:

```
mmcblk0boot0/boot1/rpmb  - 4 MiB each, standard eMMC boot partitions
mmcblk0: p1 p2 p3 p4 p5 p6 p7 p8 p9 p10  - GPT-partitioned main storage
```

Root filesystem is a read-only squashfs (`dmesg`: "VFS: Mounted root (squashfs filesystem)
readonly on device 179:7") - classic embedded pattern: read-only base image + a separate writable
partition (where `/usr/data` - printer_data, Moonraker config, our own RosetteOS install - actually
lives). Which of the 10 GPT partitions holds what (kernel, squashfs rootfs, writable data, possibly
an A/B redundant pair for safe updates) has **not** been mapped in detail - worth doing before any
real flashing work, not yet done.

**Not yet checked, and important before any real flashing attempt**: whether this SoC's factory
mask-ROM recovery/download mode (Ingenic chips typically support a "USB boot"/recovery mode for
reflashing via a PC tool if the on-board bootloader is damaged, similar in spirit to Allwinner's FEL
mode or Rockchip's maskrom mode) is actually accessible on this specific board, or whether Creality
has locked it via eFuses. The `soc_efuse` kernel module being loaded confirms eFuse-based
provisioning is in active use here for *something* - unknown whether that includes disabling
recovery mode. **This is the single biggest unknown standing between "safe to experiment with
rootfs" and "real risk of an unrecoverable brick" for anything beyond simple `insmod` testing.**

## 5. Recommended next steps for the ethernet adapter specifically (not started)

1. Check whether `Ingenic-community`'s published kernel source matches this device's exact BSP
   version (`4.4.94`) closely enough to build a vermagic-compatible module - the real unlock if it
   pans out.
2. If that doesn't pan out, consider building a generic `usbnet.ko` + `asix.ko` (or `ax88179_178a.ko`
   specifically) against a from-scratch-configured 4.4.94 MIPS32R2 kernel tree (Ingenic or generic
   MIPS defconfig, patched to match the vermagic string) - lower-confidence path, more trial and
   error, but the coarse-only vermagic check (no MODVERSIONS) makes it plausible.
3. Test via `insmod` on the real device - genuinely low-risk per section 2 above (session-only,
   worst case is a hang + power cycle), but still do this only when the printer is idle/not
   mid-print, and only after the user is aware an attempt is happening.
4. If it works, add an init script matching Creality's own `/module_driver/*.sh` pattern for
   persistence across reboots.

**Cheaper alternative worth checking first, since the actual goal is "reliable networking" not
specifically "this exact USB adapter"**: RosetteOS memory already has two *confirmed-working* WiFi
reliability fixes from earlier sessions - disabling Bluetooth/WiFi radio-coexistence interference,
and disabling WiFi power-save (`project_wifi_instability.md`, `project_wifi_powersave.md`). Live
check this session found Bluetooth processes (`btudpwork`/`btfwwork`) currently running and no fix
script visible on disk - those fixes may have lapsed. Worth confirming and reapplying before
investing in the much bigger ethernet-driver project, since it might resolve the underlying
complaint for a fraction of the effort.

## 6. "How hard would it be to build our own complete firmware package, including the OS?"

Asked directly by the user after this investigation. Answer, broken into pieces by actual
difficulty/risk rather than as one lump "hard" or "easy" - see the chat transcript for the full
reasoning; summarized here for durability:

**Already effectively solved / low risk**: replacing userspace on top of the existing kernel and
bootloader. RosetteOS has *already* proven this repeatedly - a working MIPS cross-compilation
toolchain, and multiple real vendored/rebuilt packages (Pillow, streaming-form-data, nginx,
Moonraker itself - see the RosetteOS memory's `project_remaining_vendored_binaries.md` and
`project_nginx_selfbuild_proof.md`). SimpleAF is real-world proof the *whole* userspace stack
(Klipper fork, Moonraker, UI) can be swapped out this way, on this exact device, without touching
kernel or bootloader.

**Moderate, real, scoped work**: adding kernel *modules* on top of the existing kernel - exactly
the ethernet adapter problem above. Bounded risk (session-only testing, no bootloader/kernel image
changes), bounded effort (one driver, one matching source tree needed), genuinely achievable.

**Much harder, real board-bring-up work**: replacing the *kernel itself* with something newer
(a fresher Ingenic-community fork, or genuine mainline Linux, which only gained X2000 support in
5.10). This is not a userspace swap - it means re-doing this specific board's device tree, display
driver, touchscreen driver, and WiFi/BT driver (the `cywdhd` blob is Cypress/Broadcom proprietary;
mainline's open `brcmfmac` may or may not support the exact same chip - unconfirmed) against a
kernel with zero existing support for this specific board. This is comparable in scope to a real
postmarketOS/LineageOS-style device port - realistically weeks to months of dedicated work even for
someone experienced with this exact toolchain, with real per-step brick risk, and it isn't clear the
juice is worth the squeeze: Klipper doesn't need a modern kernel to run well, and the concrete
benefit (better out-of-box USB driver support) is exactly the narrower, cheaper problem already
being solved directly in section 5 above.

**Not recommended at all, no real payoff**: replacing the *bootloader* too. Adds real brick risk
(a broken bootloader is the hardest thing to recover from, and it's unconfirmed whether this
board's factory recovery mode is even accessible - section 4) for no benefit this project actually
needs; the vendor bootloader booting a kernel we've customized further up the stack is a
completely normal, low-risk pattern (again, exactly SimpleAF's own approach).

**Overall recommendation**: don't scope this as "build our own OS" as a single project. The real,
valuable, achievable pieces are (a) what SimpleAF already does (userspace swap, already proven
elsewhere) plus our own probe module (track 1), and (b) targeted kernel-module additions like the
ethernet driver (track 2) - both bounded, both low-to-moderate risk. A full custom kernel+bootloader
rebuild is a real, large, separate endeavor with a much weaker cost/benefit case for this specific
printer, and shouldn't be conflated with the two tracks that actually deliver end-user value here.
