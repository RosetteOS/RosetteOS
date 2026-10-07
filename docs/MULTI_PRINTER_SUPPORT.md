# Multi-Printer Support & Nebula Smart Kit Profile Architecture

RosetteOS is engineered around the **Creality Nebula Pad** hardware platform (Ingenic XBurst2 X2000 MIPS SoC). While the **Creality Ender-3 V3 KE** serves as the initial development baseline and reference target, it is designed to support **all 3D printers compatible with Creality's Nebula Smart Kit**.

RosetteOS provides built-in multi-printer support for running the Nebula Pad across multiple printer models with automatic hardware configuration, calibration state preservation, and GUI/CLI profile switching.

---

## 1. Feature Support Matrix by Model

The table below summarizes the hardware, motion kinematics, probing systems, and pin configurations across all supported printer profiles:

| Feature / Subsystem | Ender-3 V3 KE | Ender-3 V3 SE | Ender-3 V2 Neo | Ender-3 S1 | Ender-3 V2 | Ender-3 Pro | Ender-3 (Base) |
|---|---|---|---|---|---|---|---|
| **Profile ID** | `creality-ender3-v3-ke` | `creality-ender3-v3-se` | `creality-ender3-v2-neo` | `creality-ender3-s1` | `creality-ender3-v2` | `creality-ender3-pro` | `creality-ender3` |
| **Print Volume (X×Y×Z)** | 220 × 220 × 240 mm | 220 × 220 × 250 mm | 220 × 220 × 250 mm | 220 × 220 × 270 mm | 220 × 220 × 250 mm | 220 × 220 × 250 mm | 220 × 220 × 250 mm |
| **Max Velocity** | 500 mm/s | 300 mm/s | 300 mm/s | 300 mm/s | 300 mm/s | 300 mm/s | 300 mm/s |
| **Max Acceleration** | 8000 mm/s² | 4000 mm/s² | 3000 mm/s² | 3000 mm/s² | 3000 mm/s² | 3000 mm/s² | 3000 mm/s² |
| **Max Z Velocity / Accel** | 30 mm/s (500 mm/s²) | 30 mm/s (300 mm/s²) | 10 mm/s (100 mm/s²) | 15 mm/s (200 mm/s²) | 10 mm/s (100 mm/s²) | 10 mm/s (100 mm/s²) | 10 mm/s (100 mm/s²) |
| **Extruder Type** | Direct Drive (Sprite-style) | Direct Drive | Bowden Extruder | Sprite Direct Drive | Bowden Extruder | Bowden Extruder | Bowden Extruder |
| **Extruder Rotation Dist** | 7.53 mm | 7.53 mm | 32.473 mm | 7.50 mm | 32.473 mm | 32.473 mm | 32.473 mm |
| **Retraction Defaults** | 0.8 mm @ 40 mm/s | 0.8 mm @ 40 mm/s | 5.0 mm @ 45 mm/s | 0.8 mm @ 40 mm/s | 5.0 mm @ 45 mm/s | 5.0 mm @ 45 mm/s | 5.0 mm @ 45 mm/s |
| **Hotend Max Temp** | 300 °C | 260 °C | 260 °C | 260 °C | 260 °C | 260 °C | 260 °C |
| **Bed Max Temp** | 100 °C | 110 °C | 110 °C | 100 °C | 110 °C | 110 °C | 110 °C |
| **MCU Architecture** | GD32F303 Cortex-M4 | GD32F303 Cortex-M4 | STM32F103 Cortex-M3 | STM32F103 / F401 | STM32F103 / GD32F301 | STM32F103 / GD32F301 | STM32F103 / GD32F301 |
| **MCU Clock Speed** | 120 MHz | 120 MHz | 72 MHz | 72 MHz / 84 MHz | 72 MHz | 72 MHz | 72 MHz |
| **Bootloader Offset** | 12 KiB (`0x8003000`) | 28 KiB (`0x8007000`) | 28 KiB (`0x8007000`) | 28 KiB (`0x8007000`) | 28 KiB (`0x8007000`) | 28 KiB (`0x8007000`) | 28 KiB (`0x8007000`) |
| **Serial Connection** | `USART2` (`PA2`/`PA3`) | `USART2` (`PA2`/`PA3`) | `USART3` (`PB11`/`PB10`) | `USART1` (`PA10`/`PA9`) / USB | `USART3` / `USART1` / USB | `USART3` / `USART1` / USB | `USART3` / `USART1` / USB |
| **Baud Rate** | 230400 | 230400 | 230400 | 230400 | 230400 | 230400 | 230400 |
| **Bootloader Header** | `mcu0_001_G32` | `mcu0_003_000` | Raw binary | Raw binary | Raw binary | Raw binary | Raw binary |
| **Z-Probing System** | CR-Touch + Load Cell | CR-Touch + Load Cell | CR-Touch (`[bltouch]`) | CR-Touch (`[bltouch]`) | Physical Z-Endstop | Physical Z-Endstop | Physical Z-Endstop |
| **Probe Offset (X, Y)** | X: -24, Y: -20 mm | X: -24, Y: -20 mm | X: -45, Y: -10 mm | X: -30, Y: -40 mm | N/A (Endstop on PA7) | N/A (Endstop on PA7) | N/A (Endstop on PA7) |
| **Bed Mesh Matrix** | 9 × 9 Bicubic | 9 × 9 Bicubic | 9 × 9 Bicubic | 9 × 9 Bicubic | Manual / Mesh | Manual / Mesh | Manual / Mesh |
| **Filament Runout** | Switch (`PC15`) | Switch (`PC15`) | Optional / None | Switch (`PC15`) | Optional / None | Optional / None | Optional / None |
| **Stepper Drivers** | TMC2208 UART | TMC2208 UART | Standalone A4988/TMC | Standalone A4988/TMC | Standalone A4988/TMC | Standalone A4988/TMC | Standalone A4988/TMC |
| **MCU Die Temp Sensor** | Supported (`nebulaos_temperature_mcu`) | Supported (`nebulaos_temperature_mcu`) | Disabled | Disabled | Disabled | Disabled | Disabled |
| **Nozzle Wiper Routine** | `[z_compensate]` Active | `[z_compensate]` Active | N/A | N/A | N/A | N/A | N/A |
| **Pre-built Firmware** | Built into Rootfs | Build Artifact & Package | Build Artifact & Package | Ready for Defconfig | Ready for Defconfig | Ready for Defconfig | Ready for Defconfig |

---

## 2. Configuration Subsystems & Modular Layering

The configuration structure is organized into universal and model-specific layers:

### Layer 1: Universal Base (`RosetteOS_Settings.cfg`)
Included by **every** printer profile. Contains universal print acceleration, adaptive meshing, macro hooks, and platform compatibility:
- `[nebulaos_compat]`: Host-side compatibility preflight verifying Klipper symbol consistency and sensor driver registrations.
- `[include Macros/Adaptive_Meshing.cfg]`: Computes a localized bed mesh around the actual sliced objects rather than probing the whole bed.
- `[include Macros/Line_Purge.cfg]`: Adaptive purge line generated directly next to the object start point.
- `[include Macros/Smart_Park.cfg]`: Parks toolhead above the first print object before nozzle heating.
- `[include Macros/Printer_Profile.cfg]`: Exposes `SET_PRINTER_PROFILE` and `LIST_PRINTER_PROFILES` macros to Mainsail/Fluidd.
- `[include GuppyScreen/guppy_cmd.cfg]`: GuppyScreen event dispatcher hooks.
- `[include frontend-controls.cfg]`: Standard virtual SD card and pause/resume G-code wrappers.

### Layer 2: V3 Series Hardware (`V3_Settings.cfg`)
Included exclusively by **Ender-3 V3 KE** and **Ender-3 V3 SE**:
- `[temperature_sensor mcu_temp]`: GD32F303 internal die temperature monitoring.
- `[z_compensate]`: Automated nozzle heating, silicone wiper scrubbing, and optical-vs-strain-gauge delta calculation.
- `[nebulaos_z_offset_probe]`: 24-bit HX711 differential ADC strain-gauge load cell driver (`dout_pin: PC6`, `sclk_pin: PA4`).

### Layer 3: Model-Specific Config (`printer.cfg`)
Defines the physical kinematics, stepper pinouts, direction inversions, step rotation distances, endstop inversions, heater PID tuning, and fan PWM controls unique to each printer.

---

## 3. Profile Management & State Persistence

### Directory Layout
- **Factory Default Seeds**: `/opt/nebulaos-seeds/printer_profiles/<profile-id>/` (Immutable squashfs overlay)
- **User Live Configurations**: `/usr/data/rosetteos/printer_profiles/<profile-id>/` (Mutable persistent flash)
- **Active System Config**: `/usr/data/rosetteos/printer_data/config/` (Bound to `/opt/printer_data/config`)
- **Historical Backups**: `/usr/data/rosetteos/backups/printer_config/`

### State Preservation Flow
1. When switching away from Profile A:
   - The current `printer.cfg` (including all `SAVE_CONFIG` blocks, calibrated Z-offsets, bed meshes, and PID values) is saved to `/usr/data/rosetteos/printer_profiles/<Profile-A>/printer.cfg`.
   - A timestamped backup is recorded under `/usr/data/rosetteos/backups/printer_config/`.
2. When switching to Profile B:
   - If Profile B was previously calibrated by the user, its saved configuration and calibrations are restored.
   - If Profile B has never been used, it is seeded from factory defaults (`/opt/nebulaos-seeds/printer_profiles/<Profile-B>/`).
   - If non-KE profiles are selected, `mcu-auto-upgrade.disabled` is written to prevent serial contention during boot.
3. Mainsail / Fluidd File Manager Integration:
   - `/usr/data/rosetteos/printer_profiles/` is linked directly inside the Moonraker config root (`/opt/printer_data/config/printer_profiles`), allowing users to browse, download, and back up all printer profiles directly through the web UI.

---

## 4. First-Boot Experience & Profile Selection

1. **Automatic Touch Calibration**:
   - On the very first boot of a fresh installation, the screen displays the 4-point touch calibration.
2. **Auto-Display Model Selection**:
   - Immediately upon completing the touch calibration, GuppyScreen automatically opens the **"Select Printer Model"** panel.
3. **USB Drive Auto-Provisioning**:
   - If a USB flash drive containing an `rosetteos-profile.txt` file (e.g. `creality-ender3-v3-se`) is plugged in during first boot, `S02nebulaos-namespace` automatically activates that model profile.

---

## 5. Command-Line Interface (`rosetteos-profile`)

```sh
# List all active/enabled profiles
rosetteos-profile list

# List all available profiles including generic templates
rosetteos-profile list --all

# Output profiles in structured JSON format (for APIs & GuppyScreen)
rosetteos-profile list --json

# Show currently active profile
rosetteos-profile get

# Switch to a different printer model and restart Klipper
rosetteos-profile set creality-ender3-v3-se --restart

# Reset a profile to clean factory defaults (discarding user calibrations)
rosetteos-profile set creality-ender3-v3-se --clean --restart
```

---

## 6. Bed Tramming & Screw Leveling Geometry

Different printer models use different bed leveling mechanics. The table below details how manual and probe-assisted bed tramming are configured per model:

| Model Profile | Bed Construction | Manual Bed Screws (`[bed_screws]`) | Probe Screw Tilt (`[screws_tilt_adjust]`) | Screw Thread | Leveling Mechanism |
|---|---|---|---|---|---|
| **Ender-3 V3 KE** | Rigid Spacers (Fixed Bed) | N/A (Factory Rigid Spacers) | N/A | N/A | Fully automated via CR-Touch + load cell nozzle contact |
| **Ender-3 V3 SE** | Rigid Spacers (Fixed Bed) | N/A (Factory Rigid Spacers) | N/A | N/A | Automated via CR-Touch + bed strain gauge |
| **Ender-3 V2 Neo** | 4 Corner Thumb Knobs | S1: (30,25), S2: (200,25)<br>S3: (200,195), S4: (30,195) | S1: (70,35), S2: (240,35)<br>S3: (240,205), S4: (70,205) | `CW-M4` | Assisted via `SCREWS_TILT_CALCULATE` + 9×9 Bed Mesh |
| **Ender-3 S1** | 4 Corner Thumb Knobs | S1: (25,33), S2: (202,33)<br>S3: (202,202), S4: (25,202) | S1: (55,73), S2: (232,73)<br>S3: (232,230), S4: (55,230) | `CW-M4` | Assisted via `SCREWS_TILT_CALCULATE` + 9×9 Bed Mesh |
| **Ender-3 V2** | 4 Corner Thumb Knobs | S1: (30,20), S2: (200,20)<br>S3: (200,200), S4: (30,200) | N/A (Requires probe upgrade) | `CW-M4` | Manual 4-corner nozzle feeler gauge / paper test |
| **Ender-3 Pro** | 4 Corner Thumb Knobs | S1: (30,20), S2: (200,20)<br>S3: (200,200), S4: (30,200) | N/A (Requires probe upgrade) | `CW-M4` | Manual 4-corner nozzle feeler gauge / paper test |
| **Ender-3 (Base)** | 4 Corner Thumb Knobs | S1: (30,20), S2: (200,20)<br>S3: (200,200), S4: (30,200) | N/A (Requires probe upgrade) | `CW-M4` | Manual 4-corner nozzle feeler gauge / paper test |

### How to Use Screws Tilt Adjust on V2 Neo & S1:
1. Home all axes (`G28`).
2. Run `SCREWS_TILT_CALCULATE` from the Mainsail console or GuppyScreen.
3. Klipper probes the bed directly above each of the four adjustment screws and outputs the exact adjustment needed for each knob relative to the base reference screw:
   - Example output: `front right screw : x=240.0, y=35.0, z=0.125 : adjust CW 01:15`
   - Turn the knob in the direction and amount indicated (e.g. Clockwise 1 full turn and 15 minutes / quarter turn).
4. Re-run `SCREWS_TILT_CALCULATE` until all four corners are within ±0.02 mm tolerance.

---

## 7. Per-Printer Enabled `[...]` Sections Comparison Matrix

The matrix below details every Klipper configuration section and whether it is enabled directly (`printer.cfg`), conditionally via hardware includes (`V3_Settings.cfg`), or globally via the base stack (`RosetteOS_Settings.cfg`) across all supported printer profiles:

| Section Name | Functional Category | V3 KE | V3 SE | V2 Neo | S1 | V2 | Pro | Base | Rationale / Hardware Dependency |
|---|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|---|
| **`[printer]`** | Motion Limits | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | Kinematics, max velocity, acceleration, and cruise ratio |
| **`[mcu]`** | Serial Comms | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | Serial port `/dev/ttyS1` @ 230400 baud |
| **`[stepper_x]`** | Axis Kinematics | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | X-axis step/dir pins, rotation distance, endstops |
| **`[stepper_y]`** | Axis Kinematics | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | Y-axis step/dir pins, rotation distance, endstops |
| **`[stepper_z]`** | Axis Kinematics | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | Z-axis leadscrew pitch (`rotation_distance: 8`) |
| **`[tmc2208 stepper_x]`** | Stepper Drivers | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | UART software current control (`PB12`) |
| **`[tmc2208 stepper_y]`** | Stepper Drivers | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | UART software current control (`PB13`) |
| **`[tmc2208 stepper_z]`** | Stepper Drivers | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | UART software current control (`PB14`) |
| **`[safe_z_home]`** | Homing Logic | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ | Centers probe for Z homing (Physical endstops on V2/Pro/Base) |
| **`[bltouch]`** | Bed Probing | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ | CR-Touch probe pinouts & offset calibration |
| **`[bed_mesh]`** | Leveling Matrix | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | Adaptive & full-bed height compensation |
| **`[bed_screws]`** | Bed Tramming | ❌ | ❌ | ✅ | ✅ | ✅ | ✅ | ✅ | Manual 4-corner bed leveling screw nozzle coordinates |
| **`[screws_tilt_adjust]`** | Bed Tramming | ❌ | ❌ | ✅ | ✅ | ❌ | ❌ | ❌ | CR-Touch probe-assisted screw leveling calculations |
| **`[temperature_sensor mcu_temp]`** | Telemetry | ✅ *(V3)* | ✅ *(V3)* | ❌ | ❌ | ❌ | ❌ | ❌ | GD32F303 internal die temperature sensor |
| **`[z_compensate]`** | Auto Calibration | ✅ *(V3)* | ✅ *(V3)* | ❌ | ❌ | ❌ | ❌ | ❌ | Automated nozzle silicone wipe & strain gauge Z-offset |
| **`[nebulaos_z_offset_probe]`** | Load Cell Driver | ✅ *(V3)* | ✅ *(V3)* | ❌ | ❌ | ❌ | ❌ | ❌ | 24-bit HX711 bed strain gauge ADC (`PA4`/`PC6`) |
| **`[extruder]`** | Hotend & Feed | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | Stepper pins, gear ratio, PID tuning, max temp |
| **`[heater_bed]`** | Heated Bed | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | Bed thermistor, MOSFET pin, PID parameters |
| **`[verify_heater extruder]`** | Safety Thermal | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | Thermal runaway detection & timer thresholds |
| **`[verify_heater heater_bed]`** | Safety Thermal | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | Bed thermal runaway monitoring |
| **`[fan]`** | Cooling Control | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | Toolhead part cooling fan PWM (`PA0`) |
| **`[heater_fan nozzle_fan]`** | Cooling Control | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | Heatsink fan automatic 60 °C trigger (`PC1` or `PC0`) |
| **`[output_pin MainBoardFan]`** | Cooling Control | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | Mainboard enclosure cooling fan (`!PB1`) |
| **`[filament_switch_sensor filament_sensor]`** | Safety Sensors | ✅ | ✅ | ❌ | ✅ | ❌ | ❌ | ❌ | Mechanical runout switch (`PC15`) |
| **`[firmware_retraction]`** | G-code Tuning | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | Hardware retraction (G10/G11) parameters |
| **`[input_shaper]`** | Resonance Filter | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | Ringing / ghosting reduction shaper filter slots |
| **`[skew_correction]`** | Geometry Tuning | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | XY/XZ/YZ frame squareness compensation |
| **`[exclude_object]`** | Slicer Object Cancel | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | Cancels individual failed parts during a multi-part print |
| **`[respond]`** | G-code Logging | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | Standard `M118` / `RESPOND` message delivery |
| **`[include RosetteOS_Settings.cfg]`** | Universal Stack | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | Global macros, adaptive meshing, line purge, profile API |
| **`[include V3_Settings.cfg]`** | Modular Hardware | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | Loads V3 strain gauge, z_compensate, and mcu_temp |
| **`[nebulaos_compat]`** | Platform Driver | ✅ *(Base)* | ✅ *(Base)* | ✅ *(Base)* | ✅ *(Base)* | ✅ *(Base)* | ✅ *(Base)* | ✅ *(Base)* | Preflight symbol validation and hardware sensor bridge |
| **`[virtual_sdcard]`** | Print Execution | ✅ *(Base)* | ✅ *(Base)* | ✅ *(Base)* | ✅ *(Base)* | ✅ *(Base)* | ✅ *(Base)* | ✅ *(Base)* | Fast binary file streaming from `/opt/printer_data/gcodes` |
| **`[pause_resume]`** | State Handling | ✅ *(Base)* | ✅ *(Base)* | ✅ *(Base)* | ✅ *(Base)* | ✅ *(Base)* | ✅ *(Base)* | ✅ *(Base)* | G-code execution state pause / resume buffers |
| **`[display_status]`** | GUI Status | ✅ *(Base)* | ✅ *(Base)* | ✅ *(Base)* | ✅ *(Base)* | ✅ *(Base)* | ✅ *(Base)* | ✅ *(Base)* | Progress tracking and M73 display status hooks |

*Legend: ✅ = Enabled directly in `printer.cfg` | ✅ *(V3)* = Enabled via `V3_Settings.cfg` | ✅ *(Base)* = Enabled via `RosetteOS_Settings.cfg` | ❌ = Not present / unsupported on this hardware model.*
