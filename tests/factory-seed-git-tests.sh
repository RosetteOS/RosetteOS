#!/bin/sh
#
# Offline, repeatable tests for the NebulaOS real-history factory-seed
# mechanism (auto-updates-camera-complete mission, 2026-07-28, see
# docs/NEBULAOS_MOONRAKER_UPDATE_AND_CAMERA_ANALYSIS.md). Covers both
# halves of the pipeline that replaced the old synthetic-orphan-commit
# bundle approach:
#
#   1. scripts/build/lib/make-seed-archive.sh's make_seed_archive() -
#      build-time packaging, sourced directly (shared verbatim with
#      scripts/build/04-cross-compile-app-stack.sh - no parallel copy).
#   2. scripts/build/overlay/etc/init.d/S04rosetteos-factory-seed's
#      seed_git_app() - on-device first-boot consumption, sourced with
#      S04ROSETTEOS_FACTORY_SEED_NO_AUTORUN=1 (same seam convention as
#      scripts/flash-spare-slot.sh's FLASH_SPARE_SLOT_NO_AUTORUN) and
#      SEEDS/APPS pointed at fixture directories.
#
# Never touches GitHub or a real device - every fixture is a real,
# locally-built git repository under a temp directory.
#
# Usage: sh tests/factory-seed-git-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
# Points S04rosetteos-factory-seed's own GATE_LIB override at the real,
# tracked shared gate (not the real device path /etc/rosetteos-
# maintenance-gate.sh, which does not exist on a dev machine) - the
# script sources it unconditionally at load time even though this test
# file only calls seed_git_app() directly, not the gate itself.
export GATE_LIB="$REPO_ROOT/scripts/build/overlay/etc/rosetteos-maintenance-gate.sh"
MAKE_ARCHIVE_LIB="$REPO_ROOT/scripts/build/lib/make-seed-archive.sh"
S04_SCRIPT="$REPO_ROOT/scripts/build/overlay/etc/init.d/S04rosetteos-factory-seed"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/factory-seed-git-tests.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@localhost
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@localhost

PASS=0
FAIL=0

fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

# --- Fixture builders -------------------------------------------------

# A real, non-shallow repo with two real commits on $2, remote "origin"
# pointed at $3 (a bare repo standing in for "the real GitHub remote").
build_real_repo() {
	dir="$1"; branch="$2"; origin_bare="$3"
	rm -rf "$dir"
	mkdir -p "$dir"
	git -C "$dir" init -q -b "$branch"
	echo "one" > "$dir/file.txt"
	git -C "$dir" add -A
	git -C "$dir" commit -q -m "first commit"
	echo "two" >> "$dir/file.txt"
	git -C "$dir" add -A
	git -C "$dir" commit -q -m "second commit"
	if [ -n "$origin_bare" ]; then
		git -C "$dir" remote add origin "$origin_bare"
	fi
}

# A bare repo standing in for the real GitHub remote, seeded with the
# exact same history as $1's $2 branch - so a later `git fetch origin`
# against it behaves like a real upstream fetch.
build_bare_remote() {
	bare="$1"; src="$2"; branch="$3"
	rm -rf "$bare"
	git clone -q --bare "$src" "$bare"
	git -C "$bare" symbolic-ref HEAD "refs/heads/$branch" 2>/dev/null || true
}

# A genuinely shallow clone (real .git/shallow boundary, real branch,
# real commit) of $1 at depth 1 - matches vendor/klipper's actual shape.
build_shallow_repo() {
	dir="$1"; src="$2"; branch="$3"
	rm -rf "$dir"
	git clone -q --depth 1 --branch "$branch" --single-branch "file://$src" "$dir"
}

# The OLD, now-removed approach: a single synthetic orphan commit with
# no shared ancestry with anything real - what make_seed_archive and
# seed_git_app must both now refuse to accept.
build_synthetic_orphan_repo() {
	dir="$1"; branch="$2"
	rm -rf "$dir"
	mkdir -p "$dir"
	git -C "$dir" init -q -b "$branch"
	echo "content" > "$dir/file.txt"
	git -C "$dir" add -A
	git -C "$dir" -c user.email=nebulaos@localhost -c user.name=NebulaOS \
		commit -q -m "NebulaOS factory seed snapshot of $branch @ deadbeef0000"
	git -C "$dir" remote add origin "https://example.invalid/synthetic.git"
}

# --- Part 1: make_seed_archive() (build-time packaging) ---------------

. "$MAKE_ARCHIVE_LIB"

M="$WORK/make-archive"
mkdir -p "$M"

# Test: genuine full-history repo is accepted and packaged.
build_real_repo "$M/real-src" master ""
if out=$(make_seed_archive "$M/real-src" master "https://example.invalid/real.git" "$M/real.tar.gz" 2>&1) && [ -f "$M/real.tar.gz" ]; then
	pass "genuine full-history repo is packaged successfully"
else
	fail "genuine full-history repo was rejected (unexpected): $out"
fi

# Test: genuine shallow repo is accepted and packaged (mirrors
# vendor/klipper's real shape).
build_real_repo "$M/shallow-origin" master ""
build_shallow_repo "$M/shallow-src" "$M/shallow-origin" master
if [ "$(git -C "$M/shallow-src" rev-parse --is-shallow-repository)" != "true" ]; then
	fail "test setup: shallow-src fixture is not actually shallow"
else
	if out=$(make_seed_archive "$M/shallow-src" master "https://example.invalid/shallow.git" "$M/shallow.tar.gz" 2>&1) && [ -f "$M/shallow.tar.gz" ]; then
		pass "genuine shallow repo is packaged successfully"
	else
		fail "genuine shallow repo was rejected (unexpected): $out"
	fi
fi

# Test: synthetic orphan wrapper commit is rejected.
build_synthetic_orphan_repo "$M/synthetic-src" master
rm -f "$M/synthetic.tar.gz"
if out=$(make_seed_archive "$M/synthetic-src" master "https://example.invalid/synthetic.git" "$M/synthetic.tar.gz" 2>&1); then
	fail "synthetic wrapper commit was NOT rejected"
else
	if [ ! -f "$M/synthetic.tar.gz" ] && echo "$out" | grep -q "synthetic wrapper commit"; then
		pass "synthetic wrapper commit is rejected with no archive produced"
	else
		fail "synthetic wrapper commit rejection did not behave as expected: $out"
	fi
fi

# Test: dirty working tree is rejected.
build_real_repo "$M/dirty-src" master ""
echo "uncommitted change" >> "$M/dirty-src/file.txt"
rm -f "$M/dirty.tar.gz"
if out=$(make_seed_archive "$M/dirty-src" master "https://example.invalid/dirty.git" "$M/dirty.tar.gz" 2>&1); then
	fail "dirty working tree was NOT rejected"
else
	if [ ! -f "$M/dirty.tar.gz" ] && echo "$out" | grep -q "not clean"; then
		pass "dirty working tree is rejected with no archive produced"
	else
		fail "dirty working tree rejection did not behave as expected: $out"
	fi
fi

# Test: the packaged archive's origin remote uses a full wildcard fetch
# refspec (the real bug found live: a narrow single-branch refspec
# silently breaks a later `git fetch origin` from ever populating
# origin/<branch>, reproducing the original diverged=true failure).
rm -rf "$M/refspec-check"; mkdir -p "$M/refspec-check"
tar -xf "$M/real.tar.gz" -C "$M/refspec-check"
refspec=$(git -C "$M/refspec-check" config --get remote.origin.fetch)
if [ "$refspec" = "+refs/heads/*:refs/remotes/origin/*" ]; then
	pass "packaged archive's origin remote has the full wildcard fetch refspec"
else
	fail "packaged archive's origin fetch refspec is wrong: '$refspec'"
fi

# Test: the packaged archive is on the requested branch with a clean tree.
if [ "$(git -C "$M/refspec-check" symbolic-ref --short HEAD)" = "master" ] \
	&& [ -z "$(git -C "$M/refspec-check" status --porcelain)" ]; then
	pass "packaged archive is on the expected branch with a clean tree"
else
	fail "packaged archive branch/cleanliness check failed"
fi

# Test: the packaged archive's branch has its tracking-remote config set
# directly (real bug found live: `git branch --set-upstream-to` silently
# no-ops when the target remote-tracking ref does not exist locally yet,
# which it never does in an offline-built archive - leaving
# branch.<name>.remote unset, which is exactly what Moonraker's own
# GitDeploy reads to populate git_remote; with it unset, is_valid() fails
# directly regardless of ancestry/dirty/detached state).
if [ "$(git -C "$M/refspec-check" config --get branch.master.remote)" = "origin" ] \
	&& [ "$(git -C "$M/refspec-check" config --get branch.master.merge)" = "refs/heads/master" ]; then
	pass "packaged archive's branch has its tracking-remote config set"
else
	fail "packaged archive's branch is missing tracking-remote config (branch.master.remote/merge)"
fi

# Test: sparse_exclude keeps the excluded path's real history in
# .git/objects (fsck-clean, no synthetic anything) while omitting it from
# the working tree, and git treats this as intentional sparsity rather
# than a modification - the real fix for the 1m51s live klipper
# extraction that led to two impatient hard-reboots and an incompletely
# seeded namespace.
rm -rf "$M/sparse-src" "$M/sparse-check"
build_real_repo "$M/sparse-src" master ""
mkdir -p "$M/sparse-src/lib/bigdir"
echo "large excluded content" > "$M/sparse-src/lib/bigdir/file.bin"
git -C "$M/sparse-src" add -A
git -C "$M/sparse-src" commit -q -m "add lib/ content"
if out=$(make_seed_archive "$M/sparse-src" master "https://example.invalid/sparse.git" "$M/sparse.tar.gz" "/lib/" 2>&1) && [ -f "$M/sparse.tar.gz" ]; then
	mkdir -p "$M/sparse-check"
	tar -xzf "$M/sparse.tar.gz" -C "$M/sparse-check"
	if [ ! -e "$M/sparse-check/lib/bigdir/file.bin" ] \
		&& [ -z "$(git -C "$M/sparse-check" status --porcelain)" ] \
		&& git -C "$M/sparse-check" cat-file -e "HEAD:lib/bigdir/file.bin" 2>/dev/null; then
		pass "sparse_exclude omits the path from the working tree while keeping it in real history"
	else
		fail "sparse_exclude did not behave as expected (working tree/history mismatch)"
	fi
else
	fail "make_seed_archive with sparse_exclude was unexpectedly rejected: $out"
fi

# Test: a wrong-architecture klippy/chelper/c_helper.so (e.g. a host-arch
# binary from a developer's local `make`, never the real cross-compile
# pipeline's MIPS output) is discarded from the packaged archive entirely,
# not silently shipped. Final Baseline Closure mission (2026-08-08): this
# path used to `git checkout -- ` a committed "known good" fallback, but
# the former Klipper pin untracked c_helper.so entirely (it's a generated
# build artifact, not source - see that commit's own message), so there is
# no longer a tracked version to fall back to; the fixed behavior is a
# plain `rm -f`, verified here by committing a real (tracked, so the tree
# stays clean going in) non-MIPS placeholder and confirming it never makes
# it into the packaged tar.
rm -rf "$M/wrongarch-src" "$M/wrongarch-check"
build_real_repo "$M/wrongarch-src" master ""
mkdir -p "$M/wrongarch-src/klippy/chelper"
echo "pretend host-arch binary, not real MIPS ELF" > "$M/wrongarch-src/klippy/chelper/c_helper.so"
git -C "$M/wrongarch-src" add -A
git -C "$M/wrongarch-src" -c user.email=t@l -c user.name=t commit -q -m "add wrong-arch chelper"
if out=$(make_seed_archive "$M/wrongarch-src" master "https://example.invalid/wrongarch.git" "$M/wrongarch.tar.gz" 2>&1) && [ -f "$M/wrongarch.tar.gz" ]; then
	mkdir -p "$M/wrongarch-check"
	tar -xzf "$M/wrongarch.tar.gz" -C "$M/wrongarch-check"
	if [ ! -e "$M/wrongarch-check/klippy/chelper/c_helper.so" ]; then
		pass "wrong-architecture c_helper.so is discarded, not packaged into the archive"
	else
		fail "wrong-architecture c_helper.so was packaged into the archive - should have been discarded"
	fi
else
	fail "wrong-architecture c_helper.so caused the whole archive to be unexpectedly rejected: $out"
fi

# --- Part 2: seed_git_app() (on-device first-boot consumption) --------

S="$WORK/seed-git-app"
mkdir -p "$S/seeds" "$S/apps" "$S/system" "$S/locks"

run_seed_git_app() {
	# Sources the real production script and calls its real function -
	# no reimplementation of seed_git_app's own rules.
	name="$1"; branch="$2"; origin="$3"; dirty_exclude="${4:-}"
	SEEDS="$S/seeds" APPS="$S/apps" SYSTEM="$S/system" LOCKDIR="$S/locks" \
		S04ROSETTEOS_FACTORY_SEED_NO_AUTORUN=1 \
		sh -c '. "$1"; seed_git_app "$2" "$3" "$4" "$5"' -- "$S04_SCRIPT" "$name" "$branch" "$origin" "$dirty_exclude" 2>&1
}

# Test: genuine archive with correct branch/origin is accepted.
rm -rf "$S/apps/appok"
cp "$M/real.tar.gz" "$S/seeds/appok.tar.gz"
if out=$(run_seed_git_app appok master "https://example.invalid/real.git"); rc=$?
	[ "$rc" -eq 0 ] && [ -e "$S/apps/appok/.git" ]; then
	pass "genuine archive with correct branch/origin is seeded"
else
	fail "genuine archive with correct branch/origin was rejected: $out"
fi

# Test: wrong branch is rejected, no destination left behind.
rm -rf "$S/apps/wrongbranch"
build_real_repo "$M/wrongbranch-src" notmaster ""
tar -C "$M/wrongbranch-src" -czf "$S/seeds/wrongbranch.tar.gz" .
out=$(run_seed_git_app wrongbranch master "https://example.invalid/x.git"); rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$S/apps/wrongbranch/.git" ] && [ ! -d "$S/apps/wrongbranch.partial" ]; then
	pass "wrong branch is rejected, no partial state left behind"
else
	fail "wrong branch was not correctly rejected (rc=$rc): $out"
fi

# Test: wrong origin URL is rejected.
rm -rf "$S/apps/wrongorigin"
build_real_repo "$M/wrongorigin-src" master ""
git -C "$M/wrongorigin-src" remote add origin "https://example.invalid/WRONG.git"
tar -C "$M/wrongorigin-src" -czf "$S/seeds/wrongorigin.tar.gz" .
out=$(run_seed_git_app wrongorigin master "https://example.invalid/right.git"); rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$S/apps/wrongorigin/.git" ]; then
	pass "wrong origin URL is rejected"
else
	fail "wrong origin URL was not correctly rejected (rc=$rc): $out"
fi

# Test: dirty working tree baked directly into the archive (bypassing
# make_seed_archive, which would itself have refused it) is still
# independently rejected by seed_git_app's own check.
rm -rf "$S/apps/dirtyseed"
build_real_repo "$M/dirtyseed-src" master ""
git -C "$M/dirtyseed-src" remote add origin "https://example.invalid/dirtyseed.git"
echo "uncommitted" >> "$M/dirtyseed-src/file.txt"
tar -C "$M/dirtyseed-src" -czf "$S/seeds/dirtyseed.tar.gz" .
out=$(run_seed_git_app dirtyseed master "https://example.invalid/dirtyseed.git"); rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$S/apps/dirtyseed/.git" ]; then
	pass "dirty working tree baked into the archive is independently rejected"
else
	fail "dirty archived working tree was not correctly rejected (rc=$rc): $out"
fi

# Test: real bug found live (Mode B pre-qualification, 2026-07-31) - a
# dirty klippy/chelper/c_helper.so (the one path make_seed_archive() itself
# always leaves dirty on purpose) must be tolerated when the caller passes
# it as dirty_exclude, while any OTHER dirty file in the same archive must
# still be rejected - the exclusion must not become a blanket bypass.
rm -rf "$S/apps/chelperseed"
build_real_repo "$M/chelperseed-src" master ""
git -C "$M/chelperseed-src" remote add origin "https://example.invalid/chelperseed.git"
mkdir -p "$M/chelperseed-src/klippy/chelper"
echo "pretend cross-compiled binary" > "$M/chelperseed-src/klippy/chelper/c_helper.so"
tar -C "$M/chelperseed-src" -czf "$S/seeds/chelperseed.tar.gz" .
out=$(run_seed_git_app chelperseed master "https://example.invalid/chelperseed.git" "klippy/chelper/c_helper.so"); rc=$?
if [ "$rc" -eq 0 ] && [ -e "$S/apps/chelperseed/.git" ]; then
	pass "dirty klippy/chelper/c_helper.so is tolerated when passed as dirty_exclude"
else
	fail "dirty klippy/chelper/c_helper.so was rejected even with dirty_exclude set (rc=$rc): $out"
fi

rm -rf "$S/apps/chelperseed2"
build_real_repo "$M/chelperseed2-src" master ""
git -C "$M/chelperseed2-src" remote add origin "https://example.invalid/chelperseed2.git"
mkdir -p "$M/chelperseed2-src/klippy/chelper"
echo "pretend cross-compiled binary" > "$M/chelperseed2-src/klippy/chelper/c_helper.so"
echo "unrelated uncommitted change" >> "$M/chelperseed2-src/file.txt"
tar -C "$M/chelperseed2-src" -czf "$S/seeds/chelperseed2.tar.gz" .
out=$(run_seed_git_app chelperseed2 master "https://example.invalid/chelperseed2.git" "klippy/chelper/c_helper.so"); rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$S/apps/chelperseed2/.git" ]; then
	pass "dirty_exclude does not mask an unrelated dirty file in the same archive"
else
	fail "dirty_exclude incorrectly let an unrelated dirty file through (rc=$rc): $out"
fi

# Test: a synthetic wrapper commit baked directly into the archive
# (bypassing make_seed_archive) is still independently rejected.
rm -rf "$S/apps/synthseed"
build_synthetic_orphan_repo "$M/synthseed-src" master
git -C "$M/synthseed-src" remote set-url origin "https://example.invalid/synthseed.git"
tar -C "$M/synthseed-src" -czf "$S/seeds/synthseed.tar.gz" .
out=$(run_seed_git_app synthseed master "https://example.invalid/synthseed.git"); rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$S/apps/synthseed/.git" ]; then
	pass "synthetic wrapper commit baked into the archive is independently rejected"
else
	fail "synthetic wrapper commit in archive was not correctly rejected (rc=$rc): $out"
fi

# Test: missing seed archive is rejected cleanly.
rm -rf "$S/apps/missing" "$S/seeds/missing.tar.gz"
out=$(run_seed_git_app missing master "https://example.invalid/missing.git"); rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q "seed archive missing"; then
	pass "missing seed archive is rejected cleanly"
else
	fail "missing seed archive was not correctly rejected (rc=$rc): $out"
fi

# Test: a corrupt (non-tar) archive is rejected, no partial state left.
rm -rf "$S/apps/corrupt"
echo "not a real tar file" > "$S/seeds/corrupt.tar.gz"
out=$(run_seed_git_app corrupt master "https://example.invalid/corrupt.git"); rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$S/apps/corrupt/.git" ] && [ ! -d "$S/apps/corrupt.partial" ]; then
	pass "corrupt archive is rejected, no partial state left behind"
else
	fail "corrupt archive was not correctly rejected (rc=$rc): $out"
fi

# Test: an already-seeded app (real .git present) is preserved untouched
# - seed_git_app must skip re-seeding rather than overwrite it.
rm -rf "$S/apps/existing"
mkdir -p "$S/apps/existing/.git"
echo "sentinel" > "$S/apps/existing/.git/marker-should-survive"
cp "$M/real.tar.gz" "$S/seeds/existing.tar.gz"
out=$(run_seed_git_app existing master "https://example.invalid/real.git"); rc=$?
if [ "$rc" -eq 0 ] && [ -e "$S/apps/existing/.git/marker-should-survive" ]; then
	pass "an already-seeded app is preserved untouched, not re-seeded"
else
	fail "an already-seeded app was not correctly preserved (rc=$rc): $out"
fi

# Test: end-to-end - after seeding from a genuine archive, a real fetch
# against the actual origin (a bare repo standing in for GitHub) proves
# HEAD is an ancestor of origin/<branch> - i.e. diverged=false, the exact
# condition Moonraker's own git_deploy.py checks.
rm -rf "$S/apps/ancestry"
build_real_repo "$M/ancestry-src" master ""
build_bare_remote "$M/ancestry-remote.git" "$M/ancestry-src" master
make_seed_archive "$M/ancestry-src" master "file://$M/ancestry-remote.git" "$S/seeds/ancestry.tar.gz" >/dev/null
run_seed_git_app ancestry master "file://$M/ancestry-remote.git" >/dev/null
git -C "$S/apps/ancestry" fetch -q origin
if git -C "$S/apps/ancestry" merge-base --is-ancestor HEAD origin/master; then
	pass "end-to-end: seeded HEAD is a real ancestor of origin/master (diverged=false)"
else
	fail "end-to-end: seeded HEAD is NOT an ancestor of origin/master (would reproduce diverged=true)"
fi

echo
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
