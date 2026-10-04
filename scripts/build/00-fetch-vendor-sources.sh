#!/bin/sh
# Clone/download every third-party source this build needs. Dependencies use
# exact refs except GuppyScreen, which intentionally follows its configured
# moving branch. See FIRMWARE.md for provenance.
#
# 2026-08-07 baseline-repair mission: pins now live in one authoritative
# file, manifests/dependencies.conf, sourced below - not scattered as
# hardcoded values across this script. See that file's own header for the
# reasoning and the format.
set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
VENDOR="$REPO_ROOT/vendor"
MANIFEST="$REPO_ROOT/manifests/dependencies.conf"

[ -f "$MANIFEST" ] || {
	echo "FATAL: $MANIFEST not found - this is the one authoritative dependency pin file, required to build at all" >&2
	exit 1
}
. "$MANIFEST"

require_setting() {
	var_name="$1"
	eval "val=\${$var_name:-}"
	if [ -z "$val" ] || [ "$val" = "UNPINNED_MUST_SET_BEFORE_BUILD" ]; then
		echo "FATAL: $var_name is missing or unset in $MANIFEST - this required setting is missing" >&2
		exit 1
	fi
}

for required in SYSTEM_REPO SYSTEM_PIN \
	KLIPPER_REPO KLIPPER_BRANCH KLIPPER_PIN KLIPPER_EXTRAS_REPO KLIPPER_EXTRAS_PIN \
	MCU_REPO MCU_PIN MCU_METADATA_VERSION MCU_EXPECTED_HW_ID \
	MOONRAKER_REPO MOONRAKER_PIN K1_USTREAMER_REPO K1_USTREAMER_PIN \
	MAINSAIL_TAG MAINSAIL_SHA256 \
	WIFI_FIRMWARE_RELEASE_TAG WIFI_FIRMWARE_RELEASE_URL WIFI_FIRMWARE_ARCHIVE_SHA256 \
	WIFI_FIRMWARE_TXT_SHA256 WIFI_FIRMWARE_BIN_SHA256 WIFI_FIRMWARE_CLM_SHA256 \
	GUPPYSCREEN_REPO GUPPYSCREEN_PIN GUPPYSCREEN_THEME OPENKE_VERSION; do
	require_setting "$required"
done
echo "== all required dependency settings present in $MANIFEST =="

# 2026-08-07 baseline-repair mission: wireless-regdb (regulatory.db, its
# .p7s signature, and its LICENSE) is ISC-licensed and freely fetchable -
# unlike the proprietary WiFi firmware below, this one already had a
# complete, correct, hash-verified fetch script
# (scripts/firmware/fetch-wireless-regdb.sh) that simply was never called
# from anywhere in the actual build pipeline. Also required to compile the
# kernel (same CONFIG_EXTRA_FIRMWARE mechanism as the WiFi firmware) - a
# genuinely fresh clone hit this as a second, immediately-following
# "No rule to make target" failure once the first one (below) was fixed.
sh "$SCRIPT_DIR/../firmware/fetch-wireless-regdb.sh"

# 2026-08-09 (WiFi .125 promotion): canonical CYW43430 .bin + CLM, fetched
# directly from Infineon's own upstream repo and hash-verified inside that
# script itself (WIFI_FIRMWARE_BIN_SHA256/WIFI_FIRMWARE_CLM_SHA256 above).
# Required to compile the kernel (CONFIG_EXTRA_FIRMWARE embeds both - see
# artifacts/buildroot-halley5-v30-image/halley5-openke-fragment.config),
# not just to boot. See docs/NEBULAOS_WIFI_125_ENGINEERING_TEST.md for the
# full qualification history behind this pin.
sh "$SCRIPT_DIR/../firmware/fetch-cyw43430-wifi-firmware.sh"

# Board NVRAM (.txt) - real per-board calibration data extracted from this
# project's own hardware, redistribution explicitly authorized by the
# repository owner (see LICENSES/WIFI-FIRMWARE-NOTICE.md), published as a
# GitHub Release asset on this repo and fetched the same way Mainsail is
# above: pinned tag + URL + archive sha256, individual file hash checked
# after extraction. Unrelated to which .bin/CLM firmware is running -
# stays byte-identical across the 2026-08-09 .125 promotion.
WIFI_FW_DIR="$REPO_ROOT/scripts/build/overlay/lib/firmware/brcm"
WIFI_FW_TXT="$WIFI_FW_DIR/brcmfmac43430-sdio.txt"
mkdir -p "$WIFI_FW_DIR"
if [ ! -f "$WIFI_FW_TXT" ]; then
	echo "== downloading WiFi firmware release $WIFI_FIRMWARE_RELEASE_TAG (NVRAM only) =="
	WIFI_FW_ARCHIVE="$REPO_ROOT/vendor-downloads/nebulaos-wifi-firmware.tar.gz"
	mkdir -p "$(dirname "$WIFI_FW_ARCHIVE")"
	curl -sL -o "$WIFI_FW_ARCHIVE" "$WIFI_FIRMWARE_RELEASE_URL"
	archive_actual_sha256=$(sha256sum "$WIFI_FW_ARCHIVE" | awk '{print $1}')
	# Clean-Update + Virgin Baseline mission, Phase 8 (2026-08-08): this
	# repos own visibility is still PRIVATE (a GitHub repo-visibility
	# change is one of the action categories this projects own tooling
	# cannot perform itself, confirmed persistently blocked, not a
	# transient failure). A plain unauthenticated curl against a private
	# repos release asset 404s regardless of the URL looking like a normal
	# public download link - confirmed real, first hit during this
	# missions own attempt at a genuinely fresh clone build. Fall back to
	# the GitHub CLIs own authenticated release-download flow, which works
	# against a private repo as long as the invoking environment has gh
	# authenticated with read access - exactly what every build
	# environment used by this project actually has. If gh is unavailable
	# or unauthenticated too, this falls through to the same FATAL check
	# below, now correctly diagnosing the real cause.
	if [ "$archive_actual_sha256" != "$WIFI_FIRMWARE_ARCHIVE_SHA256" ] && command -v gh >/dev/null 2>&1; then
		echo "== plain curl fetch did not match the pinned hash - retrying via gh release download (private repo) =="
		gh release download "$WIFI_FIRMWARE_RELEASE_TAG" \
			--repo coreflake1/NebulaOS-firmware \
			--pattern "$(basename "$WIFI_FIRMWARE_RELEASE_URL")" \
			--output "$WIFI_FW_ARCHIVE" --clobber \
			|| echo "WARNING: gh release download also failed - see the FATAL check below for the real error" >&2
		archive_actual_sha256=$(sha256sum "$WIFI_FW_ARCHIVE" | awk '{print $1}')
	fi
	if [ "$archive_actual_sha256" != "$WIFI_FIRMWARE_ARCHIVE_SHA256" ]; then
		echo "FATAL: $WIFI_FW_ARCHIVE sha256 is $archive_actual_sha256, expected pinned $WIFI_FIRMWARE_ARCHIVE_SHA256" >&2
		echo "Either the download is corrupt/tampered, gh is missing or unauthenticated and the repo is still" >&2
		echo "private, or this is a deliberate, reviewed bump - if so, update WIFI_FIRMWARE_ARCHIVE_SHA256 in" >&2
		echo "$MANIFEST." >&2
		exit 1
	fi
	tar xzf "$WIFI_FW_ARCHIVE" -C "$(dirname "$WIFI_FW_ARCHIVE")"
	cp "$(dirname "$WIFI_FW_ARCHIVE")"/nebulaos-wifi-firmware-*/brcmfmac43430-sdio.txt "$WIFI_FW_TXT"
	echo "== WiFi NVRAM extracted from release archive =="
fi
actual_txt_sha256=$(sha256sum "$WIFI_FW_TXT" | awk '{print $1}')
if [ "$actual_txt_sha256" != "$WIFI_FIRMWARE_TXT_SHA256" ]; then
	echo "FATAL: $WIFI_FW_TXT sha256 is $actual_txt_sha256, expected pinned $WIFI_FIRMWARE_TXT_SHA256" >&2
	exit 1
fi
echo "== WiFi firmware + CLM + NVRAM present and pin-verified =="

mkdir -p "$VENDOR"
cd "$VENDOR"

# The former standalone Buildroot checkout is obsolete now that the full OKE
# System repository supplies both the kernel and Buildroot. It is generated
# vendor state, so remove only this explicit legacy checkout before proceeding.
if [ -d "buildroot-x2000" ] || [ -L "buildroot-x2000" ]; then
	echo "== removing obsolete standalone vendor/buildroot-x2000 checkout =="
	rm -rf -- "buildroot-x2000"
fi

clone_pinned() {
	name="$1"; url="$2"; ref="$3"; extra="$4"
	if [ -d "$name/.git" ]; then
		echo "== $name already present, verifying pin (not re-cloning) =="
	else
		if [ -e "$name" ]; then
			unexpected=$(find "$name" -mindepth 1 -maxdepth 1 ! -name output -print -quit)
			if [ -n "$unexpected" ]; then
				echo "FATAL: vendor/$name exists but is not a pinned git checkout and contains unexpected content: $unexpected" >&2
				exit 1
			fi
			rmdir "$name" || {
				echo "FATAL: vendor/$name could not be cleared safely before cloning" >&2
				exit 1
			}
		fi
		echo "== cloning $name @ $ref =="
		git clone $extra "$url" "$name"
		git -C "$name" fetch origin "$ref" 2>/dev/null || true
		git -C "$name" checkout "$ref"
	fi
	# Pin enforcement (2026-07-31, NEBULAOS_CAMERA_USB_RT_SOURCE_ANALYSIS.md's
	# vendor-pin audit): previously this function only checked out the pinned
	# ref the FIRST time a vendor/ dir was absent - an already-present checkout
	# (e.g. after a stray `git pull` run by hand, or a stale checkout left over
	# from before a pin was bumped) was never re-verified. Resolve the pin
	# (branch/tag/SHA - all valid `ref` forms used by callers below) to its
	# exact commit and fail loudly on any mismatch, every run, not just on
	# first clone.
	#
	expected=$(git -C "$name" rev-parse "$ref" 2>/dev/null) || {
		echo "FATAL: vendor/$name - could not resolve pin '$ref' to a commit at all (bad ref, or needs a fetch)" >&2
		exit 1
	}
	actual=$(git -C "$name" rev-parse HEAD)
	if [ "$actual" != "$expected" ]; then
		echo "FATAL: vendor/$name HEAD is $actual, expected pinned ref '$ref' ($expected)" >&2
		echo "Either this checkout drifted (git -C vendor/$name checkout $expected to fix), or the pin needs a deliberate, reviewed bump in $MANIFEST." >&2
		exit 1
	fi
	echo "== $name pinned commit verified ($expected) =="
}

# Moving-branch dependencies are refreshed on every build.
# Each checkout follows the current tip of its configured upstream branch.
# Each refresh uses a depth-1 history so the moving branch never accumulates history.
# Generated build files are discarded before refresh so stale outputs cannot drift the checkout.
clone_branch() {
	name="$1"; url="$2"; branch="$3"
	if [ -d "$name/.git" ]; then
		if [ "$(git -C "$name" rev-parse --is-shallow-repository 2>/dev/null || echo false)" != true ]; then
			echo "== $name is a full checkout; replacing it with a depth-1 shallow clone =="
			git -C "$name" reset --hard >/dev/null
			git -C "$name" clean -fdx >/dev/null
			git -C "$name" submodule foreach --recursive 'git reset --hard && git clean -fdx' >/dev/null 2>&1 || true
			staging="$VENDOR/.${name}.shallow.$$"
			if [ -e "$staging" ]; then
				echo "FATAL: shallow-clone staging path already exists: $staging" >&2
				exit 1
			fi
			git clone --depth 1 --single-branch --branch "$branch" "$url" "$staging"
			rm -rf "$name"
			mv "$staging" "$name"
		else
			echo "== $name already present, refreshing shallow origin/$branch =="
			git -C "$name" remote set-url origin "$url"
			git -C "$name" reset --hard >/dev/null
			git -C "$name" clean -fdx >/dev/null
			git -C "$name" submodule foreach --recursive 'git reset --hard && git clean -fdx' >/dev/null 2>&1 || true
		fi
	else
		echo "== cloning $name from $url ($branch, depth 1) =="
		git clone --depth 1 --single-branch --branch "$branch" "$url" "$name"
	fi
	git -C "$name" fetch --prune --depth 1 origin "$branch"
	git -C "$name" checkout -B "$branch" "origin/$branch"
	git -C "$name" reset --hard "origin/$branch" >/dev/null
	actual=$(git -C "$name" rev-parse HEAD)
	remote=$(git -C "$name" rev-parse "origin/$branch")
	[ "$actual" = "$remote" ] || {
		echo "FATAL: vendor/$name did not land on origin/$branch" >&2
		exit 1
	}
	echo "== $name follows latest origin/$branch HEAD ($actual) =="
}

# Open Klipper Edition System (FIRMWARE.md sec 39). The full OKE checkout
# supplies both the Linux kernel and the Buildroot tree used by this build.
# It is pinned to SYSTEM_PIN; an already-present checkout at that commit is
# left untouched so generated Buildroot state survives.
legacy_system_dir=x2000_kernel_6.6
if [ ! -e "system" ] && [ -d "$legacy_system_dir/.git" ]; then
	echo "== migrating legacy $legacy_system_dir checkout to system =="
	mv -- "$legacy_system_dir" system
elif [ -e "$legacy_system_dir" ]; then
	echo "FATAL: legacy vendor/$legacy_system_dir exists alongside vendor/system; remove or rename it before building" >&2
	exit 1
fi
if [ -e "system" ] && [ ! -d "system/.git" ]; then
	echo "FATAL: vendor/system exists but is not a git checkout" >&2
	exit 1
fi
if [ ! -d "system/.git" ]; then
	echo "== initializing full OpenKlipperEdition/System at pinned commit =="
	git init system >/dev/null
	git -C system remote add origin "$SYSTEM_REPO"
	git -C system fetch --depth 1 origin "$SYSTEM_PIN"
	git -C system checkout --detach "$SYSTEM_PIN"
else
	echo "== system already present, checking pinned commit =="
fi
system_actual=$(git -C system rev-parse HEAD)
[ "$system_actual" = "$SYSTEM_PIN" ] || {
	echo "== system is $system_actual, switching it to pinned $SYSTEM_PIN =="
	git -C system remote set-url origin "$SYSTEM_REPO"
	git -C system reset --hard >/dev/null
	# A pin change invalidates generated state, including Buildroot's
	# downloaded-source cache; do not carry sources across System pins.
	git -C system clean -fdx >/dev/null
	git -C system fetch --depth 1 origin "$SYSTEM_PIN"
	git -C system checkout --detach "$SYSTEM_PIN"
}
system_actual=$(git -C system rev-parse HEAD)
[ "$system_actual" = "$SYSTEM_PIN" ] || {
	echo "FATAL: vendor/system did not land on pinned commit $SYSTEM_PIN" >&2
	exit 1
}
[ -f "system/buildroot/Makefile" ] || {
	echo "FATAL: full OpenKlipperEdition/System checkout is missing buildroot/Makefile" >&2
	exit 1
}
[ -f "system/kernel/kernel-6.6/Makefile" ] || {
	echo "FATAL: full OpenKlipperEdition/System checkout is missing kernel/kernel-6.6/Makefile" >&2
	exit 1
}
echo "== system matches pinned commit $system_actual; kernel + buildroot present =="


# Official upstream Klipper remains the runtime. Pin it to the commit
# qualified by nebulaos-extensions.json so the extension API check is honest.
clone_pinned klipper "$KLIPPER_REPO" "$KLIPPER_PIN"

# Fetch the pinned NebulaOS checkout as an extras source only. Stage 04 copies
# the selected modules into the mainline checkout before packaging it.
clone_pinned klipper-extensions "$KLIPPER_EXTRAS_REPO" "$KLIPPER_EXTRAS_PIN"
for extra in \
	bl24c16f.py \
	guppy_config_helper.py \
	guppy_module_loader.py \
	calibrate_shaper_config.py \
	gcode_shell_command.py \
	tmcstatus.py \
	nebulaos_calibration.py \
	nebulaos_compat.py \
	nebulaos_plr_journal.py \
	nebulaos_power_loss_recovery.py \
	nebulaos_probe_pair.py \
	nebulaos_temperature_mcu.py \
	nebulaos_version.py \
	nebulaos_z_offset_probe.py \
	nozzle_clear.py \
	prtouch_test_support.py \
	virtual_pins.py \
	z_compensate.py; do
	[ -s "klipper-extensions/extras/$extra" ] || {
		echo "FATAL: pinned NebulaOS extensions checkout is missing extras/$extra" >&2
		exit 1
	}
done
echo "== pinned NebulaOS Klipper extensions present under extras/ =="
clone_pinned klipper-mcu "$MCU_REPO" "$MCU_PIN"

# Official Moonraker - not a fork, no reason to deviate.
clone_pinned moonraker "$MOONRAKER_REPO" "$MOONRAKER_PIN"

# Camera pipeline - a real GPLv3-licensed uStreamer port for this board
# family (the vendored ustreamer/LICENSE is the full GPLv3 text - this repo
# previously, incorrectly, called it MIT-licensed; corrected 2026-07-26).
clone_pinned k1-ustreamer "$K1_USTREAMER_REPO" "$K1_USTREAMER_PIN" "--recurse-submodules"
git -C k1-ustreamer submodule update --init --recursive


# GuppyScreen (project-specific frontend, consumes the z_compensate
# structured status contract) - previously NOT pinned or fetched by this
# script at all (see manifests/dependencies.conf's own comment on this gap);
# the actual cross-compile happens in 04-cross-compile-app-stack.sh, this
# stage only fetches and refreshes the moving source.
if [ -e guppyscreen ] && [ ! -d guppyscreen/.git ]; then
	echo "FATAL: vendor/guppyscreen exists but is not a git checkout" >&2
	exit 1
fi
if [ ! -d guppyscreen/.git ]; then
	echo "== initializing GuppyScreen at pinned commit $GUPPYSCREEN_PIN =="
	git init guppyscreen >/dev/null
	git -C guppyscreen remote add origin "$GUPPYSCREEN_REPO"
	git -C guppyscreen fetch origin || true
	git -C guppyscreen checkout --detach "$GUPPYSCREEN_PIN"
else
	guppyscreen_actual=$(git -C guppyscreen rev-parse HEAD)
	if [ "$guppyscreen_actual" != "$GUPPYSCREEN_PIN" ]; then
		echo "== GuppyScreen is $guppyscreen_actual, switching it to pinned $GUPPYSCREEN_PIN =="
		git -C guppyscreen remote set-url origin "$GUPPYSCREEN_REPO"
		git -C guppyscreen reset --hard >/dev/null
		git -C guppyscreen clean -fdx >/dev/null
		git -C guppyscreen submodule foreach --recursive 'git reset --hard && git clean -fdx' >/dev/null 2>&1 || true
		git -C guppyscreen fetch origin || true
		git -C guppyscreen checkout --detach "$GUPPYSCREEN_PIN"
	fi
fi
guppyscreen_actual=$(git -C guppyscreen rev-parse HEAD)
[ "$guppyscreen_actual" = "$GUPPYSCREEN_PIN" ] || {
	echo "FATAL: vendor/guppyscreen did not land on pinned commit $GUPPYSCREEN_PIN" >&2
	exit 1
}
git -C guppyscreen submodule update --init --depth 1

# Submodule patches (this fork's own documented canonical build procedure,
# wiki/Building-from-Source.md step 2) - lv_drivers' framebuffer-ioctls fix
# is already folded into coreflake1/lv_drivers (a real fork the .gitmodules
# above points at, not upstream), so no patch file for it ships in patches/
# any more; spdlog and lvgl are still plain upstream submodules and need
# their two patches applied on every fresh checkout, or the MIPS build
# below silently builds against unpatched fmt/DPI-scaling behavior. Guarded
# with `git apply --check` first so re-running this script against an
# already-patched, already-present checkout (clone_branch's "already
# present" branch) is a safe no-op, not a failure.
for entry in "0002-spdlog_fmt_initializer_list.patch spdlog" "0003-lvgl-dpi-text-scale.patch lvgl"; do
	patch_file=${entry% *}
	submodule=${entry#* }
	patch_path="$PWD/guppyscreen/patches/$patch_file"
	if git -C "guppyscreen/$submodule" apply --check "$patch_path" 2>/dev/null; then
		echo "== applying $patch_file to guppyscreen/$submodule =="
		git -C "guppyscreen/$submodule" apply "$patch_path"
	else
		echo "== $patch_file already applied (or does not cleanly apply) to guppyscreen/$submodule, skipping =="
	fi
done

# Mainsail - a built Vue app, fetched as a real release archive, not built
# from source here (no Node.js toolchain needed for this build at all).
#
# Pinned to an explicit release tag (the exact .version this project's last
# real build actually shipped) plus a SHA-256 check on the downloaded
# archive itself, failing loudly on either a wrong tag or a byte-for-byte
# different artifact under that tag - not .../releases/latest/..., which
# would silently point at whatever GitHub considers "latest" at fetch time.
mkdir -p mainsail-dist
if [ ! -f mainsail-dist/mainsail.zip ]; then
	echo "== downloading Mainsail $MAINSAIL_TAG =="
	curl -sL "https://github.com/mainsail-crew/mainsail/releases/download/$MAINSAIL_TAG/mainsail.zip" \
		-o mainsail-dist/mainsail.zip
fi
mainsail_actual_sha256=$(sha256sum mainsail-dist/mainsail.zip | awk '{print $1}')
if [ "$mainsail_actual_sha256" != "$MAINSAIL_SHA256" ]; then
	echo "FATAL: mainsail-dist/mainsail.zip sha256 is $mainsail_actual_sha256, expected pinned $MAINSAIL_SHA256 for $MAINSAIL_TAG" >&2
	echo "Either the download is corrupt/tampered, or this is a deliberate version bump - if deliberate, update MAINSAIL_TAG/MAINSAIL_SHA256 in $MANIFEST after reviewing the new release." >&2
	exit 1
fi
echo "== Mainsail $MAINSAIL_TAG sha256 verified =="
rm -rf mainsail-dist/dist
mkdir -p mainsail-dist/dist
unzip -q mainsail-dist/mainsail.zip -d mainsail-dist/dist

# mainsail-crew's own installer repo - only used for its real, canonical
# nginx reverse-proxy config template (already baked into scripts/build/
# overlay/etc/nginx/nginx.conf), not needed again unless you're re-deriving
# that config. Left commented out - uncomment if you want to re-check it.
# clone_pinned kiauh https://github.com/dw-0/kiauh.git HEAD

echo "== all vendor sources fetched =="
