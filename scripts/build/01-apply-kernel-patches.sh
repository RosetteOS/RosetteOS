#!/bin/sh
# Verify this project's kernel-source changes (touch DT wiring, the new
# display panel driver, the new Bluetooth H5 Broadcom vendor extension,
# WiFi/BT/display Kconfig, the ported NS2009 driver, the binder.h build fix)
# are present in the checked-out kernel tree.
#
# FIRMWARE.md sec 39: these changes used to be applied here at build time from
# patches/x2000_kernel_6.6-rosetteos.patch. They're now carried by the requested
# Open Klipper Edition System `OKE` checkout, and 00-fetch-vendor-sources.sh
# verifies it against the pinned commit,
# so there's nothing left to apply here. This script stays as stage "01" (kept
# numbered/in-sequence on purpose, so existing docs/muscle-memory still work)
# purely as a sanity check that the fork's content actually landed correctly.
set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
SYSTEM_DIR="$REPO_ROOT/vendor/system"
DEPS_MANIFEST="$REPO_ROOT/manifests/dependencies.conf"

[ -f "$DEPS_MANIFEST" ] || { echo "FATAL: $DEPS_MANIFEST not found" >&2; exit 1; }
# shellcheck source=/dev/null
. "$DEPS_MANIFEST"

if [ ! -d "$SYSTEM_DIR/.git" ]; then
	echo "vendor/system not found - run 00-fetch-vendor-sources.sh first" >&2
	exit 1
fi

cd "$SYSTEM_DIR"

# Defense in depth: stage 00 verified the checkout, but verify here that the
# build is still at the pinned commit before composing the accepted variants.
ACTUAL_SHA=$(git rev-parse HEAD)
# shellcheck disable=SC2153
if [ "$ACTUAL_SHA" != "$SYSTEM_PIN" ]; then
	echo "vendor/system HEAD is $ACTUAL_SHA, expected pinned commit $SYSTEM_PIN - re-run 00-fetch-vendor-sources.sh" >&2
	exit 1
fi

echo "== confirming pinned OKE HEAD ($ACTUAL_SHA) real changes are present =="
test -f kernel/kernel-6.6/drivers/input/touchscreen/ns2009.c
test -f kernel/kernel-6.6/module_drivers/drivers/video/fbdev/ingenic/displays/panel-rosetteos-general-480x272.c
grep -q "rosetteos,bcm4343x-bt" kernel/kernel-6.6/drivers/bluetooth/hci_h5.c
grep -q "ns2009@48" kernel/kernel-6.6/module_drivers/dts/x2000/halley5_v30.dts
# Ensure USB_DWC2_SOF_FILTER is selectable when operating in dual-role mode
DWC2_KCONFIG="kernel/kernel-6.6/drivers/usb/dwc2/Kconfig"
if [ -f "$DWC2_KCONFIG" ] && grep -q "depends on USB_DWC2_HOST$" "$DWC2_KCONFIG"; then
	echo "== patching DWC2 SOF_FILTER to support USB_DWC2_DUAL_ROLE =="
	sed -i 's/depends on USB_DWC2_HOST$/depends on USB_DWC2_HOST || USB_DWC2_DUAL_ROLE/' "$DWC2_KCONFIG"
fi

# Ensure OTG controller runs in dual-role (otg) mode so CDC-ACM gadget (g_serial) binds to UDC
HALLEY5_DTS="kernel/kernel-6.6/module_drivers/dts/x2000/halley5_v30.dts"
if [ -f "$HALLEY5_DTS" ] && grep -q 'dr_mode = "host";' "$HALLEY5_DTS"; then
	echo "== patching &otg dr_mode to otg in $HALLEY5_DTS =="
	sed -i '/&otg {/,/};/ s/dr_mode = "host";/dr_mode = "otg";/' "$HALLEY5_DTS"
fi

echo "== kernel source verified =="
