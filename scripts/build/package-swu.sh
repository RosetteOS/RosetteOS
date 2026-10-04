#!/bin/sh
#
# Builds a self-contained, verified SWUpdate package (.swu) for OpenKE.
#
# Generates a libconfig-formatted sw-description with SHA256 digests, bundles
# the kernel image (xImage -> /dev/mmcblk0p6), rootfs image (rootfs.squashfs
# -> /dev/mmcblk0p8), and post-install boot-marker script into a compliant CPIO
# archive where sw-description is strictly the first member.
#
# Usage: sh scripts/build/package-swu.sh [output-dir] [version]
#

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
ARTIFACT_DIR="$REPO_ROOT/artifacts/buildroot-halley5-v30-image"

OUTPUT_DIR="${1:-$ARTIFACT_DIR}"
VERSION="${2:-}"
CHANGELOG_ARG="${3:-}"

if [ -z "$VERSION" ]; then
	if [ -f "$REPO_ROOT/manifests/dependencies.conf" ]; then
		VERSION=$(grep -E "^OPENKE_VERSION=" "$REPO_ROOT/manifests/dependencies.conf" | cut -d= -f2 | tr -d '"' | tr -d ' ' || true)
	fi
	if [ -z "$VERSION" ] && [ -f "$ARTIFACT_DIR/build-manifest.txt" ]; then
		VERSION=$(grep -E "^openke_commit=" "$ARTIFACT_DIR/build-manifest.txt" | cut -d= -f2 | cut -c1-8 || true)
	fi
	if [ -z "$VERSION" ]; then
		VERSION=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "1.0.0")
	fi
fi

KERNEL_IMAGE="${KERNEL_IMAGE:-$ARTIFACT_DIR/xImage}"
ROOTFS_IMAGE="${ROOTFS_IMAGE:-$ARTIFACT_DIR/rootfs.squashfs}"

if [ ! -f "$KERNEL_IMAGE" ]; then
	echo "FATAL: kernel image not found at $KERNEL_IMAGE" >&2
	exit 1
fi

if [ ! -f "$ROOTFS_IMAGE" ]; then
	echo "FATAL: rootfs image not found at $ROOTFS_IMAGE" >&2
	exit 1
fi

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR=$(cd "$OUTPUT_DIR" && pwd)
WORK_DIR=$(mktemp -d "/tmp/openke-swu-build.XXXXXX")
trap 'rm -rf "$WORK_DIR"' EXIT INT TERM

echo "== Packaging OpenKE SWUpdate (.swu) v${VERSION} =="

# Prepare changelog
if [ -n "$CHANGELOG_ARG" ] && [ -f "$CHANGELOG_ARG" ]; then
	cp "$CHANGELOG_ARG" "$WORK_DIR/changelog.txt"
elif [ -n "$CHANGELOG_ARG" ]; then
	printf "%s\n" "$CHANGELOG_ARG" > "$WORK_DIR/changelog.txt"
elif [ -f "$REPO_ROOT/CHANGELOG.md" ]; then
	cp "$REPO_ROOT/CHANGELOG.md" "$WORK_DIR/changelog.txt"
else
	{
		echo "[ OpenKE System ]"
		git -C "$REPO_ROOT" log --pretty=format:"• %h %s" -n 6 2>/dev/null || echo "• OpenKE System Firmware Release v${VERSION}"
		echo ""
		GUPPY_DIR=""
		if git -C "$REPO_ROOT/vendor/guppyscreen" rev-parse --git-dir >/dev/null 2>&1; then
			GUPPY_DIR="$REPO_ROOT/vendor/guppyscreen"
		elif git -C "$REPO_ROOT/../GuppyScreen" rev-parse --git-dir >/dev/null 2>&1; then
			GUPPY_DIR="$REPO_ROOT/../GuppyScreen"
		fi
		if [ -n "$GUPPY_DIR" ]; then
			echo ""
			echo "[ GuppyScreen UI ]"
			git -C "$GUPPY_DIR" log --pretty=format:"• %h %s" -n 6 2>/dev/null || true
			echo ""
		fi
	} > "$WORK_DIR/changelog.txt"
fi

cp "$KERNEL_IMAGE" "$WORK_DIR/xImage"
cp "$ROOTFS_IMAGE" "$WORK_DIR/rootfs.squashfs"

cat > "$WORK_DIR/postinstall.sh" <<'EOF'
#!/bin/sh
# OpenKE SWUpdate post-installation script
# Pre-install (preinst): Verifies print/heater safety interlocks and target partition health.
# Post-install (postinst): Arms target boot slot (ota:kernel / ota:kernel2) and clones RTOS for Slot 2.

set -e

HOOK_ACTION="postinst"
TARGET_SLOT=""

for arg in "$@"; do
	case "$arg" in
		preinst|postinst)
			HOOK_ACTION="$arg"
			;;
		slot1|slot2)
			TARGET_SLOT="$arg"
			;;
	esac
done

# Resolve active boot slot from kernel command line
CURRENT_ROOT=$(sed -n 's/.*\broot=\(\S*\).*/\1/p' /proc/cmdline 2>/dev/null || true)
CURRENT_BOOT_SLOT=""
case "$CURRENT_ROOT" in
	*mmcblk0p7*|*rootfs1*|*by-partlabel/rootfs)
		CURRENT_BOOT_SLOT="slot1"
		;;
	*mmcblk0p8*|*rootfs2*|*by-partlabel/rootfs2)
		CURRENT_BOOT_SLOT="slot2"
		;;
esac

# If TARGET_SLOT was not passed as an argument, infer opposite of current slot
if [ -z "$TARGET_SLOT" ]; then
	if [ "$CURRENT_BOOT_SLOT" = "slot1" ]; then
		TARGET_SLOT="slot2"
	else
		TARGET_SLOT="slot1"
	fi
fi

if [ "$HOOK_ACTION" = "preinst" ]; then
	echo "== OpenKE SWUpdate Preflight Safety Checks =="

	# 1. Collision Check: Never overwrite the active running slot
	if [ -n "$CURRENT_BOOT_SLOT" ] && [ "$TARGET_SLOT" = "$CURRENT_BOOT_SLOT" ]; then
		echo "FATAL: Attempting to flash $TARGET_SLOT, but the system is currently booted from $CURRENT_BOOT_SLOT! Refusing to overwrite active running system." >&2
		exit 1
	fi

	# 2. Block Device Mount Validation
	if [ "$TARGET_SLOT" = "slot1" ]; then
		TARGET_ROOTFS="/dev/mmcblk0p7"
	else
		TARGET_ROOTFS="/dev/mmcblk0p8"
	fi

	if [ -e "$TARGET_ROOTFS" ] && grep -q "$TARGET_ROOTFS" /proc/mounts 2>/dev/null; then
		echo "FATAL: Target partition $TARGET_ROOTFS is currently mounted! Cannot safely write to a mounted partition." >&2
		exit 1
	fi

	# 3. RTOS source verification for Slot 2
	if [ "$TARGET_SLOT" = "slot2" ] && [ -e /dev/mmcblk0p3 ]; then
		if ! dd if=/dev/mmcblk0p3 of=/dev/null bs=512 count=1 2>/dev/null; then
			echo "FATAL: RTOS partition /dev/mmcblk0p3 is not readable." >&2
			exit 1
		fi
	fi

	# 4. Klipper / Moonraker Active Print and Heater Safety Interlocks
	if command -v python3 >/dev/null 2>&1; then
		python3 - <<'PYEOF'
import urllib.request
import json
import sys

try:
    req = urllib.request.urlopen("http://127.0.0.1:7125/printer/objects/query?print_stats&extruder&heater_bed", timeout=2)
    data = json.loads(req.read().decode('utf-8'))
    status = data.get("result", {}).get("status", {})

    # Safety check: Active 3D print
    pstate = status.get("print_stats", {}).get("state", "").lower()
    if pstate in ["printing", "paused", "busy"]:
        print(f"FATAL: Printer is currently active (state: '{pstate}'). Cannot flash firmware while printing!", file=sys.stderr)
        sys.exit(1)

    # Safety check: Active heater targets
    ext_target = float(status.get("extruder", {}).get("target", 0.0) or 0.0)
    bed_target = float(status.get("heater_bed", {}).get("target", 0.0) or 0.0)
    if ext_target > 0.0 or bed_target > 0.0:
        print(f"FATAL: Printer heaters are active (extruder target: {ext_target}C, bed target: {bed_target}C). Please turn off all heaters before updating firmware!", file=sys.stderr)
        sys.exit(1)

    print("OpenKE SWUpdate pre-install: Moonraker print & thermal safety checks passed.")
except Exception as e:
    # If Moonraker service is not active (e.g. maintenance mode or manual update), allow update
    print(f"OpenKE SWUpdate pre-install: Moonraker query skipped ({e})")
PYEOF
		if [ $? -ne 0 ]; then
			echo "FATAL: Preflight safety checks failed." >&2
			exit 1
		fi
	fi

	# 5. Snapshot user printer configuration before update
	if [ -d /usr/data/openke/printer_data/config ]; then
		backup_tag=$(date +%Y%m%d_%H%M%S 2>/dev/null || echo "auto")
		backup_dir="/usr/data/openke/backups/printer_config/pre_swupdate_${backup_tag}"
		mkdir -p "$backup_dir" 2>/dev/null || true
		cp -a /usr/data/openke/printer_data/config/. "$backup_dir/" 2>/dev/null || true
		echo "OpenKE SWUpdate pre-install: User configuration preserved to $backup_dir"
	fi

	echo "OpenKE SWUpdate pre-install: All preflight safety checks passed successfully."
	exit 0
fi

# Post-install Phase
echo "OpenKE SWUpdate post-install: target slot is $TARGET_SLOT"

if [ "$TARGET_SLOT" = "slot1" ]; then
	echo "Setting next boot target to Slot 1 (ota:kernel)..."
	if [ -f /etc/ota_marker.sh ]; then
		. /etc/ota_marker.sh
		write_ota_marker "ota:kernel"
	elif [ -e /dev/mmcblk0p1 ]; then
		printf 'ota:kernel\n\n' > /dev/mmcblk0p1
		dd if=/dev/zero of=/dev/mmcblk0p1 bs=1 seek=12 count=500 2>/dev/null || true
	fi
elif [ "$TARGET_SLOT" = "slot2" ]; then
	echo "Ensuring RTOS partition 4 (rtos2) is populated from partition 3 (rtos)..."
	if [ -e /dev/mmcblk0p3 ] && [ -e /dev/mmcblk0p4 ]; then
		dd if=/dev/mmcblk0p3 of=/dev/mmcblk0p4 bs=1M conv=fsync 2>/dev/null || true
	fi

	echo "Setting next boot target to Slot 2 (ota:kernel2)..."
	if [ -f /etc/ota_marker.sh ]; then
		. /etc/ota_marker.sh
		write_ota_marker "ota:kernel2"
	elif [ -e /dev/mmcblk0p1 ]; then
		printf 'ota:kernel2\n\n' > /dev/mmcblk0p1
		dd if=/dev/zero of=/dev/mmcblk0p1 bs=1 seek=13 count=499 2>/dev/null || true
	fi
fi

# Sync runtime platform markers to persistent Klipper checkout if mounted
klipper_app=""
if [ -d /usr/data/openke/apps/klipper/.git ]; then
	klipper_app="/usr/data/openke/apps/klipper"
fi
if [ -n "$klipper_app" ]; then
	echo "Syncing platform runtime markers to persistent Klipper checkout..."
	if [ -f /opt/openke-seeds/klipper-chelper-verdict.json ]; then
		cp /opt/openke-seeds/klipper-chelper-verdict.json "$klipper_app/.nebulaos-chelper-verdict.json" 2>/dev/null || true
	elif [ -f /opt/klipper/.nebulaos-chelper-verdict.json ]; then
		cp /opt/klipper/.nebulaos-chelper-verdict.json "$klipper_app/.nebulaos-chelper-verdict.json" 2>/dev/null || true
	fi
	if [ -d "$klipper_app/.git/info" ]; then
		printf '/.nebulaos-chelper-verdict.json\n' >> "$klipper_app/.git/info/exclude" 2>/dev/null || true
	fi
	if [ -f /opt/klipper/scripts/install-octopi.sh ]; then
		mkdir -p "$klipper_app/scripts"
		cp /opt/klipper/scripts/install-octopi.sh "$klipper_app/scripts/" 2>/dev/null || true
	fi
fi

# Record newly installed software version
echo "openke ${VERSION}" > /etc/sw-versions 2>/dev/null || true
echo "${VERSION}" > /etc/openke-version 2>/dev/null || true

# Write pending what's new changelog for GuppyScreen on first boot
mkdir -p /usr/data/openke 2>/dev/null || true
cat > /usr/data/openke/.pending_whats_new <<'CL_EOF'
__CHANGELOG_CONTENT__
CL_EOF

echo "OpenKE SWUpdate post-install: boot target successfully armed."
exit 0
EOF

# Substitute actual changelog content into postinstall.sh
python3 -c "
with open('$WORK_DIR/changelog.txt', 'r') as cf:
    cl = cf.read()
with open('$WORK_DIR/postinstall.sh', 'r') as pf:
    p = pf.read()
p = p.replace('__CHANGELOG_CONTENT__', cl)
with open('$WORK_DIR/postinstall.sh', 'w') as pf:
    pf.write(p)
"

chmod +x "$WORK_DIR/postinstall.sh"

KERNEL_SHA=$(sha256sum "$WORK_DIR/xImage" | awk '{print $1}')
ROOTFS_SHA=$(sha256sum "$WORK_DIR/rootfs.squashfs" | awk '{print $1}')
POSTINSTALL_SHA=$(sha256sum "$WORK_DIR/postinstall.sh" | awk '{print $1}')

# Escape changelog text for libconfig string
CHANGELOG_ESC=$(sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' "$WORK_DIR/changelog.txt" | awk '{if (NR>1) printf "\\n"; printf "%s", $0}')

cat > "$WORK_DIR/sw-description" <<EOF
software =
{
	version = "${VERSION}";
	description = "OpenKE System Firmware Update";
	changelog = "${CHANGELOG_ESC}";

	nebula-pad = {
		hardware-compatibility: [ "1.0" ];

		stable = {
			slot1 = {
				images: (
					{
						filename = "xImage";
						device = "/dev/mmcblk0p5";
						type = "raw";
						installed-directly = true;
						sha256 = "${KERNEL_SHA}";
					},
					{
						filename = "rootfs.squashfs";
						device = "/dev/mmcblk0p7";
						type = "raw";
						installed-directly = true;
						sha256 = "${ROOTFS_SHA}";
					}
				);

				scripts: (
					{
						filename = "postinstall.sh";
						type = "shellscript";
						data = "slot1";
						sha256 = "${POSTINSTALL_SHA}";
					}
				);
			};

			slot2 = {
				images: (
					{
						filename = "xImage";
						device = "/dev/mmcblk0p6";
						type = "raw";
						installed-directly = true;
						sha256 = "${KERNEL_SHA}";
					},
					{
						filename = "rootfs.squashfs";
						device = "/dev/mmcblk0p8";
						type = "raw";
						installed-directly = true;
						sha256 = "${ROOTFS_SHA}";
					}
				);

				scripts: (
					{
						filename = "postinstall.sh";
						type = "shellscript";
						data = "slot2";
						sha256 = "${POSTINSTALL_SHA}";
					}
				);
			};
		};
	};
}
EOF

SWU_NAME="openke-update-${VERSION}.swu"
SWU_OUTPUT="$OUTPUT_DIR/$SWU_NAME"

(
	cd "$WORK_DIR"
	for f in sw-description changelog.txt xImage rootfs.squashfs postinstall.sh; do
		echo "$f"
	done | cpio -ov -H crc > "$SWU_OUTPUT"
)

# Integrity checks on the generated SWU
FIRST_MEMBER=$(cpio -it < "$SWU_OUTPUT" 2>/dev/null | head -n1)
if [ "$FIRST_MEMBER" != "sw-description" ]; then
	echo "FATAL: sw-description is not the first member of $SWU_OUTPUT (found $FIRST_MEMBER)" >&2
	exit 1
fi

SWU_SHA=$(sha256sum "$SWU_OUTPUT" | awk '{print $1}')
echo "OK   Created $SWU_OUTPUT (${SWU_SHA})"
echo "${SWU_SHA}  ${SWU_NAME}" > "$OUTPUT_DIR/${SWU_NAME}.sha256"
cp "$WORK_DIR/changelog.txt" "$OUTPUT_DIR/${SWU_NAME}.changelog.txt"
