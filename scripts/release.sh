#!/bin/sh
#
# Clean-Update + Virgin Baseline mission, Phase 7 (2026-08-08): release
# automation - the one supported way a canonical git tag becomes a
# downloadable, verifiable GitHub Release. See docs/NEBULAOS_OTA_FLOW.md
# for the full end-to-end flow this is one step of.
#
# Deliberately does NOT create or move a tag itself - tagging a canonical
# baseline is a separate, deliberate, human-reviewed decision (see that
# doc's own "who creates a tag" section), not something a release script
# should be able to do as a side effect. This only ever publishes what a
# tag already, verifiably, points at.
#
# Usage: sh scripts/release.sh <tag> [package-dir]
#   <tag>         an existing, already-pushed annotated tag
#   [package-dir] scripts/build/package-deployment.sh's own output
#                 directory; defaults to the most recently modified one
#                 under build-work/deploy-packages/
#
# Requires: gh (GitHub CLI), authenticated with release-publish access to
# this repo.

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

if [ $# -lt 1 ]; then
	echo "usage: sh scripts/release.sh <tag> [package-dir]" >&2
	exit 1
fi
TAG="$1"
PKG_DIR="${2:-}"

if [ -z "$PKG_DIR" ]; then
	# shellcheck disable=SC2012
	PKG_DIR=$(ls -dt "$REPO_ROOT"/build-work/deploy-packages/*/ 2>/dev/null | head -1 || true)
	[ -n "$PKG_DIR" ] || {
		echo "FATAL: no package directory found under build-work/deploy-packages/ - run scripts/build/package-deployment.sh first, or pass one explicitly as the second argument" >&2
		exit 1
	}
fi
PKG_DIR="${PKG_DIR%/}"

for required in xImage rootfs.squashfs build-manifest.txt SHA256SUMS DEPLOYMENT_INSTRUCTIONS.md; do
	[ -f "$PKG_DIR/$required" ] || {
		echo "FATAL: $PKG_DIR/$required missing - $PKG_DIR does not look like a complete package-deployment.sh output" >&2
		exit 1
	}
done

# The tag must already exist locally AND match what origin actually has -
# publishing a release from a tag that has not been pushed (or has
# diverged from what was pushed) would mean a fresh clone building from
# this exact tag gets something different from what the release claims to
# be, defeating the entire point of tag-anchored trust this flow depends
# on.
git -C "$REPO_ROOT" rev-parse --verify -q "refs/tags/$TAG" >/dev/null || {
	echo "FATAL: tag $TAG does not exist locally - create and push it first: git tag -a $TAG -m '...' && git push origin $TAG" >&2
	exit 1
}
LOCAL_TAG_COMMIT=$(git -C "$REPO_ROOT" rev-parse "refs/tags/$TAG^{commit}")

REMOTE_REF=$(git -C "$REPO_ROOT" ls-remote origin "refs/tags/$TAG^{}" 2>/dev/null | awk '{print $1}')
[ -n "$REMOTE_REF" ] || REMOTE_REF=$(git -C "$REPO_ROOT" ls-remote origin "refs/tags/$TAG" 2>/dev/null | awk '{print $1}')
[ -n "$REMOTE_REF" ] || {
	echo "FATAL: tag $TAG exists locally but origin has no matching ref - push it first: git push origin $TAG" >&2
	exit 1
}
if [ "$LOCAL_TAG_COMMIT" != "$REMOTE_REF" ]; then
	echo "FATAL: local tag $TAG ($LOCAL_TAG_COMMIT) does not match origin's ($REMOTE_REF) - refusing to publish a release that would not match what a fresh clone of this tag actually gets" >&2
	exit 1
fi

echo "== publishing GitHub Release $TAG from $PKG_DIR (commit $LOCAL_TAG_COMMIT) =="

assets=""
for f in xImage rootfs.squashfs build-manifest.txt SHA256SUMS DEPLOYMENT_INSTRUCTIONS.md \
	halley5_v30.dtb halley5_v30.dts halley5_v30.decompiled.dts kernel.config buildroot.config \
	baseline-difference.txt Ender3V3SE_klipper.bin Ender3V2Neo_klipper.bin; do
	[ -f "$PKG_DIR/$f" ] && assets="$assets $PKG_DIR/$f"
done

# Collect release packages (.swu, .ingenic, .img) from PKG_DIR
for ext in swu ingenic img; do
	for pkg in "$PKG_DIR"/*."$ext"; do
		[ -f "$pkg" ] && assets="$assets $pkg"
	done
done

# Also include any packages from ARTIFACT_DIR if not already in PKG_DIR
ARTIFACT_DIR="$REPO_ROOT/artifacts/buildroot-halley5-v30-image"
if [ -d "$ARTIFACT_DIR" ]; then
	for ext in swu ingenic img; do
		for pkg in "$ARTIFACT_DIR"/*."$ext"; do
			if [ -f "$pkg" ] && [ ! -f "$PKG_DIR/$(basename "$pkg")" ]; then
				assets="$assets $pkg"
			fi
		done
	done
fi

RELEASE_NOTES="RosetteOS deployment package for $TAG, built from commit $LOCAL_TAG_COMMIT.

### Distribution Assets:
- **SWUpdate Archive (.swu)**: Verified OTA update package for active RosetteOS systems.
- **CrealityOS OTA (.img)**: Stock CrealityOS update archive for seamless touch-screen upgrade.
- **Ingenic USB Cloner (.ingenic)**: Unbrick and raw flashing archive.
- **MCU Firmware (.bin)**: Pre-compiled Klipper firmware binaries for printer mainboards (Ender-3 V3 SE, Ender-3 V2 Neo).
- **Core Images**: xImage kernel and rootfs.squashfs root filesystem.

Verify downloaded assets with:
\`\`\`sh
sha256sum -c SHA256SUMS
\`\`\`
See DEPLOYMENT_INSTRUCTIONS.md for flash procedure."

# shellcheck disable=SC2086
gh release create "$TAG" $assets \
	--title "$TAG" \
	--notes "$RELEASE_NOTES"

echo "== release $TAG published =="
gh release view "$TAG"
