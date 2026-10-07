#!/bin/sh
#
# Offline tests for Phase 1.9A (host MCU / ADXL345 / BL24C16F restoration).
#
# Validates the klipper_mcu (MACH_LINUX) build step, the S54nebulaos-host-mcu
# service, and the RosetteOS_Settings.cfg config sections - all static analysis of
# script/config text and repo state. Does NOT require the Buildroot
# toolchain, a real build, or hardware - see 06-verify.sh for the
# rootfs-content checks that do need a real built image, and
# tests/recovery-safety-tests.sh for the "zero core patches" collision
# guard this phase extends with bl24c16f.py.
#
# Usage: sh tests/host-mcu-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
BUILD_SCRIPT="$REPO_ROOT/scripts/build/04-cross-compile-app-stack.sh"
HOST_MCU_SERVICE="$REPO_ROOT/scripts/build/overlay/etc/init.d/S54rosetteos-host-mcu"
KLIPPER_SERVICE="$REPO_ROOT/scripts/build/overlay/etc/init.d/S55klipper"
PRINTER_CFG="$REPO_ROOT/scripts/build/overlay/opt/printer_data/config/printer.cfg"
NEBULA_CFG="$REPO_ROOT/scripts/build/overlay/opt/printer_data/config/hardware/nebula_pad.cfg"
EXT_BL24C16F="$REPO_ROOT/vendor/klipper-extensions/extras/bl24c16f.py"
EXT_PLR_JOURNAL="$REPO_ROOT/vendor/klipper-extensions/extras/nebulaos_plr_journal.py"
EXT_PLR="$REPO_ROOT/vendor/klipper-extensions/extras/nebulaos_power_loss_recovery.py"

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

# =========================================================================
# 1. File existence and permissions
# =========================================================================

echo "--- File existence and permissions ---"

if [ -x "$HOST_MCU_SERVICE" ]; then
    pass "S54 host-mcu exists and is executable"
else
    fail "S54 host-mcu missing or not executable at $HOST_MCU_SERVICE"
fi

if [ -f "$PRINTER_CFG" ]; then
    pass "printer.cfg exists"
else
    fail "printer.cfg does not exist at $PRINTER_CFG"
fi

if [ -f "$NEBULA_CFG" ]; then
    pass "nebula_pad.cfg exists"
else
    fail "nebula_pad.cfg does not exist at $NEBULA_CFG"
fi

if [ -f "$PRINTER_CFG" ] && grep -q "^\[include hardware/nebula_pad\.cfg\]" "$PRINTER_CFG"; then
    pass "printer.cfg includes hardware/nebula_pad.cfg"
else
    fail "printer.cfg missing [include hardware/nebula_pad.cfg]"
fi

# =========================================================================
# 2. klipper_mcu build step: correct toolchain, clean out/, real failure
#    handling - not the bare host gcc, not the GD32 ARM cross-compiler,
#    and never silently continuing on a failed build.
# =========================================================================

echo "--- klipper_mcu (MACH_LINUX) build step ---"

if [ -f "$BUILD_SCRIPT" ]; then
    BUILD_BLOCK=$(awk '/cross-compiling Klipper.s host MCU/,/^\) \|\| exit 1$/' "$BUILD_SCRIPT")

    if [ -n "$BUILD_BLOCK" ]; then
        pass "klipper_mcu build block found in 04-cross-compile-app-stack.sh"

        case "$BUILD_BLOCK" in
            *"CROSS_PREFIX=mipsel-buildroot-linux-gnu-"*)
                pass "build uses the project's mipsel-buildroot-linux-gnu- MIPS toolchain" ;;
            *)
                fail "build block does not reference CROSS_PREFIX=mipsel-buildroot-linux-gnu-" ;;
        esac

        case "$BUILD_BLOCK" in
            *"arm-none-eabi-"*)
                fail "build block references arm-none-eabi- (the GD32F303 stepper-MCU toolchain) - wrong target entirely" ;;
            *)
                pass "build block does not reference the GD32F303 (arm-none-eabi-) toolchain" ;;
        esac

        case "$BUILD_BLOCK" in
            *"rm -rf out .config"*)
                pass "build removes out/.config before building - the proven fix for Make's stale-toolchain-state hazard" ;;
            *)
                fail "build block does not clean out/.config before building - vulnerable to the demonstrated stale-toolchain-state hazard" ;;
        esac

        case "$BUILD_BLOCK" in
            *"test/configs/linuxprocess.config"*)
                pass "build uses upstream's own MACH_LINUX reference config" ;;
            *)
                fail "build does not reference test/configs/linuxprocess.config" ;;
        esac

        case "$BUILD_BLOCK" in
            *"FATAL: cross-compiling klipper_mcu"*"exit 1"*)
                pass "a failed klipper_mcu build is FATAL, not silently ignored" ;;
            *)
                fail "no FATAL/exit-1 handling found for a failed klipper_mcu build" ;;
        esac

        case "$BUILD_BLOCK" in
            *"out/klipper.elf"*)
                pass "build verifies out/klipper.elf was actually produced before proceeding" ;;
            *)
                fail "build does not verify out/klipper.elf exists before proceeding" ;;
        esac
    else
        fail "no klipper_mcu build block found in 04-cross-compile-app-stack.sh"
    fi

    case "$(cat "$BUILD_SCRIPT")" in
        *'"$OVERLAY/usr/bin/klipper_mcu"'*)
            pass "build installs the result to \$OVERLAY/usr/bin/klipper_mcu" ;;
        *)
            fail "build does not install to \$OVERLAY/usr/bin/klipper_mcu" ;;
    esac
else
    fail "04-cross-compile-app-stack.sh not found at $BUILD_SCRIPT"
fi

# =========================================================================
# 3. No post-clone patch targets vendor/klipper for this work - the whole
#    point of Phase 1.9A is compiling an EXISTING upstream build target,
#    never patching upstream source.
# =========================================================================

echo "--- No host Klipper core patch ---"

if [ -f "$BUILD_SCRIPT" ]; then
    if grep -A2 -B2 "cross-compiling Klipper.s host MCU" "$BUILD_SCRIPT" \
        | grep -qi "git apply\|patch -"; then
        fail "the klipper_mcu build step contains a patch/git-apply call - Phase 1.9A must not patch upstream Klipper"
    else
        pass "the klipper_mcu build step contains no patch/git-apply call against vendor/klipper"
    fi
else
    fail "cannot check for core patches - build script missing"
fi

# =========================================================================
# 4. Config sections - [nebulaos_compat], [mcu rpi], [adxl345],
#    [resonance_tester], [nebulaos_power_loss_recovery] in nebula_pad.cfg
#    (Phase 1.9B - NOT [bl24c16f], retired as the production EEPROM owner
#    in favor of the at24/nvmem kernel driver - see
#    accelerometer-eeprom-bus-enable-variant.sh)
# =========================================================================

echo "--- nebula_pad.cfg config sections ---"

if [ -f "$NEBULA_CFG" ]; then
    for section in "\[nebulaos_compat\]" "\[mcu rpi\]" "\[adxl345\]" "\[resonance_tester\]" "\[nebulaos_power_loss_recovery\]"; do
        if grep -q "^${section}$" "$NEBULA_CFG"; then
            pass "nebula_pad.cfg declares $section"
        else
            fail "nebula_pad.cfg is missing $section"
        fi
    done

    if grep -q "^\[bl24c16f\]$" "$NEBULA_CFG"; then
        fail "nebula_pad.cfg still declares [bl24c16f] - Phase 1.9B retired this as the production EEPROM owner"
    else
        pass "nebula_pad.cfg does not declare [bl24c16f] (retired, Phase 1.9B)"
    fi

    if grep -A3 "^\[mcu rpi\]$" "$NEBULA_CFG" | grep -q "serial: /tmp/klipper_host_mcu"; then
        pass "[mcu rpi] points at /tmp/klipper_host_mcu, matching S54nebulaos-host-mcu's socket"
    else
        fail "[mcu rpi] does not reference /tmp/klipper_host_mcu"
    fi

    if grep -A2 "^\[nebulaos_power_loss_recovery\]$" "$NEBULA_CFG" | grep -q "eeprom_path: /sys/bus/i2c/devices/2-0050/eeprom"; then
        pass "[nebulaos_power_loss_recovery] eeprom_path matches the at24 eeprom@50 DT node's sysfs path"
    else
        fail "[nebulaos_power_loss_recovery] eeprom_path does not match the expected at24 sysfs path"
    fi
else
    fail "cannot check config sections - nebula_pad.cfg missing"
fi

# =========================================================================
# 5. S54nebulaos-host-mcu service: starts klipper_mcu, correct ordering
# =========================================================================

echo "--- S54 host-mcu service behavior ---"

if [ -f "$HOST_MCU_SERVICE" ]; then
    if grep -qF -- '--exec "$KLIPPER_HOST_MCU" -- -r -I "$SOCKET"' "$HOST_MCU_SERVICE"; then
        pass "S54 host-mcu starts /usr/bin/klipper_mcu with -r -I \$SOCKET (explicit socket path)"
    else
        fail "S54 host-mcu does not start klipper_mcu with an explicit -I socket path"
    fi

    # Architecture-review requirement: the service's socket path and
    # [mcu rpi]'s serial: value must be the exact same string, not just
    # "happen to agree" - klipper_mcu's own compiled-in default already
    # matches /tmp/klipper_host_mcu, so a missing -I would not have failed
    # any functional test, only silently relied on that coincidence.
    SOCKET_IN_SERVICE=$(grep -oE '^SOCKET=.*' "$HOST_MCU_SERVICE" | cut -d= -f2)
    if [ -n "$SOCKET_IN_SERVICE" ] && [ -f "$NEBULA_CFG" ] \
        && grep -A1 "^\[mcu rpi\]$" "$NEBULA_CFG" | grep -qF "serial: $SOCKET_IN_SERVICE"; then
        pass "S54 host-mcu's \$SOCKET ($SOCKET_IN_SERVICE) exactly matches [mcu rpi]'s serial: in nebula_pad.cfg"
    else
        fail "S54 host-mcu's \$SOCKET does not match [mcu rpi]'s serial: in nebula_pad.cfg"
    fi

    if grep -q "FORCE_SHUTDOWN" "$HOST_MCU_SERVICE"; then
        pass "S54 host-mcu parks GPIOs via FORCE_SHUTDOWN before killing the process, matching stock's own shutdown handshake"
    else
        fail "S54 host-mcu does not send FORCE_SHUTDOWN before stopping"
    fi

    if [ -f "$KLIPPER_SERVICE" ]; then
        S54_NAME=$(basename "$HOST_MCU_SERVICE")
        S55_NAME=$(basename "$KLIPPER_SERVICE")
        FIRST=$(printf '%s\n%s\n' "$S54_NAME" "$S55_NAME" | sort | head -1)
        if [ "$FIRST" = "$S54_NAME" ]; then
            pass "S54 host-mcu sorts before S55klipper - host MCU is available before Klippy starts"
        else
            fail "S54 host-mcu does not sort before S55klipper"
        fi
    else
        fail "S55klipper not found - cannot verify ordering"
    fi
else
    fail "cannot check service behavior - S54 host-mcu missing"
fi

# =========================================================================
# 6. bl24c16f.py extension
# =========================================================================

echo "--- bl24c16f.py extension ---"

if [ -f "$EXT_BL24C16F" ]; then
    if grep -q "from . import bus" "$EXT_BL24C16F"; then
        pass "bl24c16f.py's only Klipper-internal dependency is the standard bus module - no core patch needed"
    else
        fail "bl24c16f.py does not import bus as expected"
    fi

    if grep -q "Eric Callahan" "$EXT_BL24C16F"; then
        pass "bl24c16f.py preserves its original author's copyright header"
    else
        fail "bl24c16f.py is missing its original copyright header"
    fi

    for cmd in EEPROM_READ EEPROM_WRITE_BYTE EEPROM_WRITE_INT EEPROM_WRITE_FLOAT; do
        if grep -q "\"$cmd\"" "$EXT_BL24C16F"; then
            pass "bl24c16f.py registers $cmd"
        else
            fail "bl24c16f.py does not register $cmd"
        fi
    done
else
    echo "SKIP: klipper-extensions not found at $EXT_BL24C16F"
fi

# =========================================================================
# 7. nebulaos_power_loss_recovery.py / nebulaos_plr_journal.py extension
# =========================================================================

echo "--- nebulaos_power_loss_recovery.py / nebulaos_plr_journal.py extension ---"

if [ -f "$EXT_PLR" ] && [ -f "$EXT_PLR_JOURNAL" ]; then
    for cmd in NEBULAOS_PLR_STATUS NEBULAOS_PLR_RESUME NEBULAOS_PLR_DISCARD; do
        if grep -q "\"$cmd\"" "$EXT_PLR"; then
            pass "nebulaos_power_loss_recovery.py registers $cmd"
        else
            fail "nebulaos_power_loss_recovery.py does not register $cmd"
        fi
    done

    if grep -q "JOURNAL_FIRST_PAGE = 1" "$EXT_PLR_JOURNAL" && grep -q "STOCK_PAGE = 0" "$EXT_PLR_JOURNAL"; then
        pass "nebulaos_plr_journal.py reserves physical page 0 for stock, journal starts at page 1"
    else
        fail "nebulaos_plr_journal.py's page layout constants do not match the expected stock-compatible layout"
    fi

    if grep -qE '(lines\.append|run_script_from_command)\("M24' "$EXT_PLR"; then
        fail "nebulaos_power_loss_recovery.py emits an M24 gcode line - this mission's resume path must never issue it automatically"
    else
        pass "nebulaos_power_loss_recovery.py never emits an M24 gcode line (no automatic motion/print resume)"
    fi
else
    echo "SKIP: klipper-extensions PLR files not found"
fi

# =========================================================================
# Summary
# =========================================================================

echo ""
echo "=========================================="
echo "Results: $PASS passed, $FAIL failed"
echo "=========================================="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
