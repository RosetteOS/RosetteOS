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
	baseline-difference.txt; do
	[ -f "$PKG_DIR/$f" ] && assets="$assets $PKG_DIR/$f"
done

# shellcheck disable=SC2086
gh release create "$TAG" $assets \
	--title "$TAG" \
	--notes "RosetteOS deployment package for $TAG, built from commit $LOCAL_TAG_COMMIT. Verify downloaded assets with: sha256sum -c SHA256SUMS. See DEPLOYMENT_INSTRUCTIONS.md for the full flash procedure - never write the stock slot."

echo "== release $TAG published =="
gh release view "$TAG"
