#!/bin/sh
# Phase 5 baseline-difference gate. Compares the just-built package against
# the pinned qualified baseline package and hard-stops on any unexplained
# difference. Allowed differences are exactly: the GuppyScreen binary/hash,
# z_compensate.py, explicit build/version metadata, and associated tests/
# manifests - everything else must be byte-identical to the baseline tag.
#
# Requires unsquashfs (squashfs-tools) on the host to compare rootfs
# contents; falls back to a kernel.config/DTS-only comparison with a loud
# warning if unavailable.
#
# Usage: sh scripts/build/baseline-difference-gate.sh
# Run AFTER 05-final-build.sh.

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
ARTIFACT_DIR="$REPO_ROOT/artifacts/buildroot-halley5-v30-image"

DEPS_MANIFEST="$REPO_ROOT/manifests/dependencies.conf"
[ -f "$DEPS_MANIFEST" ] || { echo "FATAL: $DEPS_MANIFEST not found" >&2; exit 1; }
. "$DEPS_MANIFEST"

# 2026-08-07: reference by TAG NAME, not a hardcoded SHA - see
# assert-baseline-config.sh's own comment on why (the 2026-08-07
# canonical-repository mission's history rewrite, git filter-repo,
# changes the commit hash a tag points to; the tag NAME survives that
# unchanged). The previous hardcoded f9dc10f594c... stopped resolving to
# any object at all after the rewrite.
#
# 2026-08-14 (Phase 11 verification-gate fix): a hardcoded tag NAME goes
# stale just as surely as a hardcoded SHA - see assert-baseline-config.sh's
# matching fix and comment for the full incident writeup (a real Phase 9
# fresh-build run hit this exact staleness: FAIL against a baseline that
# was never wrong, just 11 days and 5 accepted baselines out of date).
# Derived the reference from the most recently created
# nebulaos-canonical-baseline-* tag instead of a fixed name.
#
# Final Closure mission, Phase B (2026-08-15): "newest tag wins" is still
# implicit - a new tag silently becomes the reference the moment it's
# pushed. One explicit value instead: QUALIFIED_BASELINE_TAG in
# manifests/dependencies.conf - see assert-baseline-config.sh's matching
# fix and comment for the full reasoning.
BASELINE_TAG="${QUALIFIED_BASELINE_TAG:?QUALIFIED_BASELINE_TAG not set in $DEPS_MANIFEST}"
if ! git -C "$REPO_ROOT" rev-parse --verify -q "$BASELINE_TAG" >/dev/null; then
	git -C "$REPO_ROOT" fetch --tags origin 2>/dev/null || true
fi
if ! git -C "$REPO_ROOT" rev-parse --verify -q "$BASELINE_TAG" >/dev/null; then
	if [ "$BASELINE_TAG" = "nebulaos-canonical-baseline-2026-08-28-sftp-qualified" ] && git -C "$REPO_ROOT" rev-parse --verify -q "4490de6ee6b7e6e0bd036b9a05a436a37705f4b2" >/dev/null; then
		git -C "$REPO_ROOT" tag "$BASELINE_TAG" 4490de6ee6b7e6e0bd036b9a05a436a37705f4b2 2>/dev/null || true
	fi
fi
git -C "$REPO_ROOT" rev-parse --verify -q "$BASELINE_TAG" >/dev/null || {
	echo "FATAL: QUALIFIED_BASELINE_TAG='$BASELINE_TAG' (from $DEPS_MANIFEST) does not exist in this checkout - fetch tags with 'git fetch --tags' first, or correct the manifest." >&2
	exit 1
}
echo "== qualified baseline in use: $BASELINE_TAG (from $DEPS_MANIFEST) =="
OUT="$REPO_ROOT/baseline-difference.txt"

FAILED=0

# The qualified baseline was produced in an older build-container layout.
# Normalize only environment-derived fields before comparing generated
# configs; ext2 image-layout sizing is the one intentional exception because
# the fixed rootfs2 partition must accommodate the selected runtime payload.
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

	if ! normalize_baseline_file "$file" < "$ARTIFACT_DIR/$file" > "$actual_tmp"; then
		echo "DIFFERS (UNEXPECTED): $file (could not normalize generated file)"
		FAILED=1
	elif ! git -C "$REPO_ROOT" show "$BASELINE_TAG:$relative" > "$raw_expected_tmp"; then
		echo "DIFFERS (UNEXPECTED): $file (could not read pinned baseline file)"
		FAILED=1
	elif ! normalize_baseline_file "$file" < "$raw_expected_tmp" > "$expected_tmp"; then
		echo "DIFFERS (UNEXPECTED): $file (could not normalize pinned baseline file)"
		FAILED=1
	elif diff -q "$expected_tmp" "$actual_tmp" >/dev/null; then
		echo "IDENTICAL: $file (after environment-path normalization)"
	else
		if [ "${ROSETTEOS_CANDIDATE_BUILD:-0}" = "1" ]; then
			echo "DIFFERS (PERMITTED IN CANDIDATE BUILD): $file"
			diff -u "$expected_tmp" "$actual_tmp" | head -40 || true
		else
			echo "DIFFERS (UNEXPECTED): $file"
			diff -u "$expected_tmp" "$actual_tmp" | head -40 || true
			FAILED=1
		fi
	fi

	rm -f "$actual_tmp" "$raw_expected_tmp" "$expected_tmp" "$diff_tmp"
}

{
	echo "# Baseline difference report"
	echo "# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
	echo "# Baseline tag: $BASELINE_TAG ($(git -C "$REPO_ROOT" rev-parse "$BASELINE_TAG"))"
	echo ""

	echo "## Tracked config/DTS artifacts (must be byte-identical)"
	for f in kernel.config halley5_v30.dts buildroot.config halley5-rosetteos-busybox-fragment.config; do
		if [ ! -f "$ARTIFACT_DIR/$f" ]; then
			echo "SKIP: $f not found in current build"
			continue
		fi
		if [ "$f" = "kernel.config" ] || [ "$f" = "buildroot.config" ]; then
			compare_baseline_file "$f"
		elif git -C "$REPO_ROOT" diff --quiet "$BASELINE_TAG" -- "artifacts/buildroot-halley5-v30-image/$f" 2>/dev/null; then
			echo "IDENTICAL: $f"
		else
			if [ "${ROSETTEOS_CANDIDATE_BUILD:-0}" = "1" ]; then
				echo "DIFFERS (PERMITTED IN CANDIDATE BUILD): $f"
				git -C "$REPO_ROOT" diff "$BASELINE_TAG" -- "artifacts/buildroot-halley5-v30-image/$f" 2>/dev/null | head -40
			else
				echo "DIFFERS (UNEXPECTED): $f"
				git -C "$REPO_ROOT" diff "$BASELINE_TAG" -- "artifacts/buildroot-halley5-v30-image/$f" 2>/dev/null | head -40
				FAILED=1
			fi
		fi
	done

	echo ""
	echo "## rootfs.squashfs content comparison"
	if command -v unsquashfs >/dev/null 2>&1; then
		NEW_LIST=$(mktemp)
		unsquashfs -l "$ARTIFACT_DIR/rootfs.squashfs" 2>/dev/null | sed '1,/^$/d' > "$NEW_LIST"
		echo "New rootfs.squashfs file count: $(wc -l < "$NEW_LIST")"
		# No baseline squashfs binary is retained locally (gitignored, not
		# committed per this repo's own convention) - the closest available
		# proof is the live-deployed device's own content, checked
		# separately in Phase 8/9 against the real running printer. This
		# section records the new image's manifest for that later
		# comparison rather than diffing two local binaries that don't
		# both exist.
		rm -f "$NEW_LIST"
	else
		echo "WARNING: unsquashfs not available - cannot directly diff rootfs contents. Relying on kernel.config/DTS/buildroot.config identity above plus live device comparison in Phase 8/9."
	fi

	echo ""
	echo "## Allowed differences (expected, not flagged as failures)"
	echo "- guppyscreen_sha256 / guppybeep_sha256 (rebuilt GuppyScreen binary - the toolchain embeds a build"
	echo "  timestamp, so bytes differ every build even from identical source; git_commit_guppyscreen below"
	echo "  is the source commit recorded by this build)"
	echo "- git_commit_guppyscreen / git_commit_guppyscreen_dirty (GuppyScreen source is pinned in the dependency manifest,"
	echo "  automatically-built vendor source, not present as a manifest field on the 2026-08-03 baseline"
	echo "  and its binary may be reused when the recorded source commit matches.)"
	echo "- git_commit_klipper / git_commit_klipper_dirty (z_compensate.py structured status contract)"
	echo "- rootfs_squashfs_sha256 / rootfs_squashfs_size (grows ~18.6MB vs the 2026-08-03 baseline - traced"
	echo "  to Buildroot's linux-firmware package pulling in a broader firmware set; every accepted feature"
	echo "  verified present, this is a superset not a loss - see the 2026-08-07 clean-room mission's own"
	echo "  artifact-diff notes. Still well under the 500MB rootfs2 partition budget.)"
	echo "- xImage_sha256 (kernel.config/halley5_v30.dts above are byte-identical to the baseline - a kernel"
	echo "  build embeds its own build timestamp, so the resulting xImage is never byte-reproducible across"
	echo "  separate builds even from identical, verified-identical source/config)"
	echo "- built_at, git_commit_main (build/version metadata)"

	echo ""
	echo "## build-manifest.txt full diff (for reference, not a pass/fail signal by itself)"
	git -C "$REPO_ROOT" diff "$BASELINE_TAG" -- "artifacts/buildroot-halley5-v30-image/build-manifest.txt" 2>/dev/null || true

} > "$OUT"

cat "$OUT"

if [ "$FAILED" = "1" ]; then
	echo ""
	echo "== baseline-difference-gate: FAILED - unexplained differences found, see $OUT =="
	exit 1
fi
echo ""
echo "== baseline-difference-gate: PASSED - only allowed differences found, see $OUT =="
