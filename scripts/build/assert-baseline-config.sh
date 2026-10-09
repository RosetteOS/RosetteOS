#!/bin/sh
# Phase 2 baseline assertions (baseline-canonicalization-and-z_compensate-
# deployment mission, 2026-08-06/07). Fails loudly and immediately if any
# qualified-baseline feature is missing - "do not accept script exit status
# as proof" (the mission's own words): apply-qualified-baseline.sh exiting
# 0 only means each variant script itself didn't error, not that the
# resulting *build* actually contains what it's supposed to. This script
# checks the real, resolved artifacts instead.
#
# Two modes:
#   sh scripts/build/assert-baseline-config.sh pre-build
#     Run AFTER apply-qualified-baseline.sh, BEFORE 02/03/05 - checks the
#     vendor kernel tree's source-level state (Kconfig symbols exist, DTS
#     nodes present) so a missing patch is caught before spending build time.
#   sh scripts/build/assert-baseline-config.sh post-build
#     Run AFTER 05-final-build.sh - checks the actual resolved
#     kernel.config/halley5_v30.dts that got baked into the real image,
#     which is the only real proof anything actually compiled in.
#
# Usage: sh scripts/build/assert-baseline-config.sh <pre-build|post-build>

set -eu

MODE="${1:?usage: $0 <pre-build|post-build>}"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
SYSTEM_DIR="$REPO_ROOT/vendor/system"
ARTIFACT_DIR="$REPO_ROOT/artifacts/buildroot-halley5-v30-image"

DEPS_MANIFEST="$REPO_ROOT/manifests/dependencies.conf"
[ -f "$DEPS_MANIFEST" ] || { echo "FATAL: $DEPS_MANIFEST not found" >&2; exit 1; }
. "$DEPS_MANIFEST"

FAILED=0
check() {
	desc="$1"
	if [ "$2" = "0" ]; then
		echo "  PASS: $desc"
	else
		echo "  FAIL: $desc"
		FAILED=1
	fi
}

case "$MODE" in
pre-build)
	echo "== Phase 2 pre-build assertions (source-level) =="

	# Kconfig symbol definitions must exist somewhere in the patched kernel
	# tree - if a patch failed to apply, the symbol simply won't be defined
	# anywhere, and later feeding it into a fragment would just be silently
	# dropped by `make olddefconfig` (exactly the 2026-08-06 regression).
	grep -rlq "NEBULAOS_BACKLIGHT_FINAL_CONTROLLER" "$SYSTEM_DIR" 2>/dev/null
	check "backlight-final-controller Kconfig symbol defined in kernel tree" $?

	grep -rlq "TOUCHSCREEN_NS2009_FINAL_QUALIFICATION" "$SYSTEM_DIR" 2>/dev/null
	check "touch-final-qualification Kconfig symbol defined in kernel tree" $?

	grep -rlq "PWM_INGENIC_V2_GET_STATE" "$SYSTEM_DIR" 2>/dev/null
	check "pwm-state-readback Kconfig symbol defined in kernel tree" $?

	grep -rlq "FB_INGENIC_PAN_VSYNC_GATE" "$SYSTEM_DIR" 2>/dev/null
	check "display-vsync (DISPLAY-V1) Kconfig symbol defined in kernel tree" $?

	[ -f "$SYSTEM_DIR/kernel/kernel-6.6/module_drivers/drivers/misc/nebulaos_backlight_final_controller.c" ]
	check "nebulaos_backlight_final_controller.c driver file present" $?

	[ -f "$SYSTEM_DIR/kernel/kernel-6.6/drivers/input/touchscreen/ns2009_final_qualification.c" ]
	check "ns2009_final_qualification.c driver file present" $?

	grep -q "nebulaos_backlight_final:" "$SYSTEM_DIR/kernel/kernel-6.6/module_drivers/dts/x2000/halley5_v30.dts" 2>/dev/null
	check "nebulaos_backlight_final DT node present" $?

	msc1_block=$(sed -n '/^&msc1 {/,/^};/p' "$SYSTEM_DIR/kernel/kernel-6.6/module_drivers/dts/x2000/halley5_v30.dts" 2>/dev/null)
	echo "$msc1_block" | grep -q 'cap-sd-highspeed;'
	check "W3 cap-sd-highspeed present in &msc1" $?
	echo "$msc1_block" | grep -q 'cap-sdio-irq;'
	check "W3 cap-sdio-irq present in &msc1" $?

	# The tracked Kconfig fragment should now (post apply-qualified-baseline.sh,
	# pre 02) carry every accepted variant's marker block.
	# Standard PREEMPT baseline: CONFIG_PREEMPT_RT must NOT be selected.
	FRAGMENT="$ARTIFACT_DIR/halley5-rosetteos-fragment.config"
	if grep -q "CONFIG_PREEMPT_RT=y" "$FRAGMENT" 2>/dev/null; then
		check "CONFIG_PREEMPT_RT=y absent from tracked fragment" 1
	else
		check "CONFIG_PREEMPT_RT=y absent from tracked fragment" 0
	fi

	# 2026-08-07: wifi-roamoff-disable-variant.sh ROAMOFF1 - not a Kconfig
	# symbol (see that script's own header), so the only real source-level
	# proof is the patched module_param default itself.
	grep -qF "static int brcmf_roamoff = 1;" \
		"$SYSTEM_DIR/kernel/kernel-6.6/drivers/net/wireless/broadcom/brcm80211/brcmfmac/common.c" 2>/dev/null
	check "wifi-roamoff-disable (ROAMOFF1) patch applied to brcmfmac common.c" $?
	;;

post-build)
	echo "== Phase 2 post-build assertions (resolved artifacts) =="
	KCONFIG="$ARTIFACT_DIR/kernel.config"
	DTS="$ARTIFACT_DIR/halley5_v30.dts"

	[ -f "$KCONFIG" ] || { echo "FATAL: $KCONFIG not found - run 05-final-build.sh first" >&2; exit 1; }
	[ -f "$DTS" ] || { echo "FATAL: $DTS not found - run 05-final-build.sh first" >&2; exit 1; }

	grep -q "^CONFIG_PREEMPT=y$" "$KCONFIG"
	check "CONFIG_PREEMPT=y (standard PREEMPT baseline)" $?

	if grep -q "^CONFIG_PREEMPT_RT=y$" "$KCONFIG" 2>/dev/null; then
		check "CONFIG_PREEMPT_RT absent from resolved kernel.config" 1
	else
		check "CONFIG_PREEMPT_RT absent from resolved kernel.config" 0
	fi

	grep -q "^CONFIG_HZ=100$" "$KCONFIG"
	check "CONFIG_HZ=100" $?

	grep -q "^CONFIG_NEBULAOS_BACKLIGHT_FINAL_CONTROLLER=y$" "$KCONFIG"
	check "CONFIG_NEBULAOS_BACKLIGHT_FINAL_CONTROLLER=y (qualified backlight/PWM controller)" $?

	grep -q "^CONFIG_TOUCHSCREEN_NS2009_FINAL_QUALIFICATION=y$" "$KCONFIG"
	check "CONFIG_TOUCHSCREEN_NS2009_FINAL_QUALIFICATION=y" $?

	grep -q "^CONFIG_TOUCHSCREEN_NS2009=y$" "$KCONFIG"
	check "CONFIG_TOUCHSCREEN_NS2009=y (base driver present - polling touch retained)" $?

	# Touch must remain polling-based: the OLDER, rejected IRQ-based
	# touch-irq-variant.sh/touch-qualification-variant.sh symbols must NOT
	# be present (would mean an unintended variant got mixed in).
	if grep -q "^CONFIG_TOUCHSCREEN_NS2009_QUALIFICATION=y$" "$KCONFIG" 2>/dev/null; then
		echo "  FAIL: CONFIG_TOUCHSCREEN_NS2009_QUALIFICATION=y present - unexpected IRQ-based touch variant, baseline should be poll-only"
		FAILED=1
	else
		echo "  PASS: CONFIG_TOUCHSCREEN_NS2009_QUALIFICATION absent (touch remains polling-based)"
	fi

	grep -q "^CONFIG_PWM_INGENIC_V2_GET_STATE=y$" "$KCONFIG"
	check "CONFIG_PWM_INGENIC_V2_GET_STATE=y (PWM brightness readback)" $?

	grep -q "^CONFIG_FB_INGENIC_PAN_VSYNC_GATE=y$" "$KCONFIG"
	check "CONFIG_FB_INGENIC_PAN_VSYNC_GATE=y (DISPLAY-V1)" $?

	grep -q "nebulaos_backlight_final:" "$DTS"
	check "nebulaos_backlight_final DT node present in resolved DTS" $?

	msc1_block=$(sed -n '/^&msc1 {/,/^};/p' "$DTS")
	echo "$msc1_block" | grep -q 'cap-sd-highspeed;'
	check "W3 cap-sd-highspeed present in resolved &msc1" $?
	echo "$msc1_block" | grep -q 'cap-sdio-irq;'
	check "W3 cap-sdio-irq present in resolved &msc1" $?

	# 2026-08-07: wifi-roamoff-disable (ROAMOFF1) - not a Kconfig symbol,
	# so kernel.config can't prove it. vendor/system is not
	# deleted by the build, so the same source-level check from pre-build
	# still applies and is the only real proof available short of
	# extracting strings from the compiled kernel image.
	grep -qF "static int brcmf_roamoff = 1;" \
		"$SYSTEM_DIR/kernel/kernel-6.6/drivers/net/wireless/broadcom/brcm80211/brcmfmac/common.c" 2>/dev/null
	check "wifi-roamoff-disable (ROAMOFF1) patch present in source tree used for this build" $?

	# Byte-for-byte proof against the pinned baseline tag's own tracked
	# copies - the strongest assertion available: not "does it look right",
	# but "is it identical to what was actually qualified".
	#
	# 2026-08-07: reference by TAG NAME, not a hardcoded SHA - the 2026-08-07
	# canonical-repository mission rewrote this repo's early history to strip
	# oversized generated blobs (git filter-repo), which changes the commit
	# hash of every commit downstream of the earliest one touched, including
	# this baseline tag's own target. A hardcoded SHA silently breaks across
	# any such rewrite (hit for real: the previous hardcoded f9dc10f594c...
	# stopped resolving to any object at all in the rewritten repo, and this
	# whole check failed with a confusing FAIL instead of a clear "commit not
	# found" error). The tag name itself is stable across the rewrite - git
	# filter-repo updates what it points to, not its name.
	#
	# 2026-08-14 (Phase 11 verification-gate fix): a hardcoded tag NAME goes
	# stale just as surely as a hardcoded SHA - this check silently compared
	# against nebulaos-display-baseline-vsync-pwm-sleep-2026-08-03 (2026-08-03)
	# for 11 days while five newer nebulaos-canonical-baseline-* tags were
	# accepted (through 2026-08-14-prtouch-qualified), so kernel.config's PASS
	# broke the moment any later-accepted variant touched it - a real Phase 9
	# fresh-build run hit exactly this, correctly reporting FAIL against a
	# baseline that was never wrong, just outdated. Every individual Kconfig
	# assertion in this same script still passed; only this byte-identical
	# check against a manually-bumped reference broke.
	#
	# Fix (2026-08-14): derived the reference from the most recently created
	# nebulaos-canonical-baseline-* tag instead of one fixed name, so this
	# check never needed a manual bump as new baselines were accepted - see
	# this same comment history in baseline-difference-gate.sh.
	#
	# Final Closure mission, Phase B (2026-08-15): "newest tag wins" is
	# better than a stale hardcoded name, but still implicit - a new
	# nebulaos-canonical-baseline-* tag silently becomes this check's
	# reference the moment it's pushed, with no deliberate promotion step
	# and no record in this script's own output of which tag a given run
	# actually verified against. One explicit value instead, in
	# manifests/dependencies.conf: QUALIFIED_BASELINE_TAG. Advancing the
	# qualified baseline is now a deliberate edit to that file, in its own
	# reviewed commit - not just pushing a tag.
	BASELINE_REF="${QUALIFIED_BASELINE_TAG:?QUALIFIED_BASELINE_TAG not set in $DEPS_MANIFEST}"
	if ! git -C "$REPO_ROOT" rev-parse --verify -q "$BASELINE_REF" >/dev/null; then
		git -C "$REPO_ROOT" fetch --tags origin 2>/dev/null || true
	fi
	if ! git -C "$REPO_ROOT" rev-parse --verify -q "$BASELINE_REF" >/dev/null; then
		if [ "$BASELINE_REF" = "nebulaos-canonical-baseline-2026-08-28-sftp-qualified" ] && git -C "$REPO_ROOT" rev-parse --verify -q "4490de6ee6b7e6e0bd036b9a05a436a37705f4b2" >/dev/null; then
			git -C "$REPO_ROOT" tag "$BASELINE_REF" 4490de6ee6b7e6e0bd036b9a05a436a37705f4b2 2>/dev/null || true
		elif [ "$BASELINE_REF" = "rosetteos-canonical-baseline-2026-09-29-opkg-qualified" ] && git -C "$REPO_ROOT" rev-parse --verify -q "openke-canonical-baseline-2026-09-29-opkg-qualified" >/dev/null; then
			git -C "$REPO_ROOT" tag "$BASELINE_REF" "openke-canonical-baseline-2026-09-29-opkg-qualified" 2>/dev/null || true
		fi
	fi
	git -C "$REPO_ROOT" rev-parse --verify -q "$BASELINE_REF" >/dev/null || {
		echo "FATAL: QUALIFIED_BASELINE_TAG='$BASELINE_REF' (from $DEPS_MANIFEST) does not exist in this checkout - fetch tags with 'git fetch --tags' first, or correct the manifest." >&2
		exit 1
	}
	echo "  == qualified baseline in use: $BASELINE_REF (from $DEPS_MANIFEST) =="

	# The Phase 11 unified build environment deliberately uses one stable
	# internal checkout path (/workspace/NebulaOS-firmware). Older qualified
	# baseline artifacts were produced by the former nested container at /src,
	# so CONFIG_EXTRA_FIRMWARE_DIR is an environment path, not a functional
	# kernel setting. Normalize that one known path-bearing field before the
	# comparison. Keep every other config line strict, and print a bounded diff
	# when anything still differs so CI failures are actionable rather than a
	# bare PASS/FAIL pair. Buildroot also embeds its source-tree version and
	# host compiler capability probes in generated configs; those describe the
	# build environment rather than the qualified target configuration.
	# Ext2 image-layout sizing is payload-dependent and is normalized below; the
	# fixed rootfs2 partition still bounds the chosen values in buildroot.config.
	normalize_baseline_file() {
		file="$1"
		case "$file" in
			kernel.config)
				sed -E \
					-e 's#^(CONFIG_EXTRA_FIRMWARE_DIR=)"[^"]*"$#\1"/__NEBULAOS_CANONICAL_FIRMWARE_DIR__"#' \
					-e 's#^(CONFIG_CC_VERSION_TEXT="[^"]*[(]Buildroot )[^)]*([)].*)$#\1__NEBULAOS_BUILDER_VERSION__\2#'
				;;
			buildroot.config)
				sed -E \
					-e 's|^# Buildroot .* Configuration$|# Buildroot __NEBULAOS_BUILDER_VERSION__ Configuration|' \
					-e '/^BR2_TARGET_ROOTFS_EXT2_(SIZE|INODES|RESBLKS)=/d' \
					-e '/^(# )?BR2_HOST_GCC_AT_LEAST_[0-9]+(=y| is not set)$/d'
				;;
			*)
				cat
				;;
		esac
	}

	compare_baseline_file() {
		file="$1"
		relative="artifacts/buildroot-halley5-v30-image/$file"
		actual_tmp=$(mktemp)
		raw_expected_tmp=$(mktemp)
		expected_tmp=$(mktemp)
		diff_tmp=$(mktemp)

		if ! normalize_baseline_file "$file" < "$REPO_ROOT/$relative" > "$actual_tmp"; then
			echo "  FAIL: could not normalize generated $file"
			FAILED=1
		elif ! git -C "$REPO_ROOT" show "$BASELINE_REF:$relative" > "$raw_expected_tmp"; then
			echo "  FAIL: could not read $file from pinned baseline tag $BASELINE_REF"
			FAILED=1
		elif ! normalize_baseline_file "$file" < "$raw_expected_tmp" > "$expected_tmp"; then
			echo "  FAIL: could not normalize $file from pinned baseline tag $BASELINE_REF"
			FAILED=1
		elif diff -u "$expected_tmp" "$actual_tmp" > "$diff_tmp"; then
			echo "  PASS: $file matches pinned baseline tag $BASELINE_REF after environment-path normalization"
		else
			if [ "${ROSETTEOS_CANDIDATE_BUILD:-0}" = "1" ]; then
				echo "  WARN: $file differs from pinned baseline tag $BASELINE_REF (candidate build allowed diff):"
				sed -n '1,160p' "$diff_tmp"
			else
				echo "  FAIL: $file differs from pinned baseline tag $BASELINE_REF"
				sed -n '1,160p' "$diff_tmp"
				FAILED=1
			fi
		fi

		rm -f "$actual_tmp" "$raw_expected_tmp" "$expected_tmp" "$diff_tmp"
	}

	for f in kernel.config halley5_v30.dts buildroot.config; do
		compare_baseline_file "$f"
	done
	;;
*)
	echo "unknown mode '$MODE' - must be pre-build or post-build" >&2
	exit 1
	;;
esac

if [ "$FAILED" = "1" ]; then
	echo "== Phase 2 assertions: FAILED - refusing to proceed =="
	exit 1
fi
echo "== Phase 2 assertions: all PASSED =="
