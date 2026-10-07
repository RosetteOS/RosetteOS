#!/bin/sh
#
# Shared maintenance-safety gate for S04rosetteos-factory-seed and
# S04rosetteos-migrate - both perform the exact same memory/IO-heavy work
# that must never run while a print is active, concurrently with a real
# update, or without memory-resilience swap active, and previously
# duplicated the identical gate logic independently in each script.
#
# Final Baseline Closure mission (2026-08-08): extracted into one shared
# file specifically because a real bug was found live in the duplicated
# logic - fixing it once here, rather than needing the identical fix
# applied twice (and risking the two copies drifting apart, exactly the
# failure class this project's own conventions exist to avoid - see
# scripts/build/lib/make-seed-archive.sh's own header for the same
# reasoning applied to a build-time shared function).
#
# Real bug found live during the Virgin Flash + Verification mission
# (2026-08-08): a stale update-transaction lock file, left over from
# BEFORE a persistent-state reset (an off-device backup + reset to
# simulate a virgin install), silently blocked every subsequent boot's
# factory-seed/migrate forever - neither script, nor anything else, ever
# cleared a stale lock, so the block was permanent until someone noticed
# and deleted it by hand.
#
# Fix is deliberately narrow. On a genuinely UNSEEDED namespace
# ($APPS/klipper/.git absent - i.e. seed_git_app has never once
# completed here), an update-transaction lock is PROVABLY irrelevant:
# this project's real update mechanism (/etc/rosetteos-update-
# supervisor.sh) only ever creates a lock while updating an app that has
# ALREADY been seeded - if the app has never been seeded at all, no real
# update could ever have legitimately created this lock, so it can only
# be leftover debris and is safe to clear automatically. On an
# ALREADY-seeded namespace, a lock is left exactly as blocking as
# before - that case can genuinely mean a real, recent, failed update
# that rosetteos-update-supervisor.sh's own comments document as
# deliberately needing human review before retrying ("a human must clear
# $LOCKDIR/$name.lock") - this fix must never bypass that case, and does
# not.
#
# Callers must already have their own log() function defined and their
# own $APPS/$LOCKDIR variables set before sourcing this file - this gate
# calls log() and reads those variables directly rather than taking them
# as parameters, so every existing log line keeps its own script's
# established "S04rosetteos-factory-seed: ..." / "S04rosetteos-migrate: ..."
# prefix unchanged.
maintenance_gate_ok() {
	active=$(wget -q -O - --timeout=3 'http://127.0.0.1:7125/printer/objects/query?print_stats' 2>/dev/null)
	case "$active" in
		*'"state":"printing"'*|*'"state":"paused"'*)
			log "BLOCKED: a print is active - refusing this boot (will retry next boot)"
			return 1
			;;
	esac

	if [ -d "$LOCKDIR" ] && [ -n "$(ls -A "$LOCKDIR" 2>/dev/null)" ]; then
		if [ ! -e "$APPS/klipper/.git" ]; then
			log "found an update-transaction lock, but $APPS/klipper has never been seeded (no .git present) - no real update could ever have legitimately created this lock for an app that has never existed here. Clearing it as leftover debris, not a real in-flight or failed update."
			rm -rf "$LOCKDIR"
			mkdir -p "$LOCKDIR"
		else
			log "BLOCKED: an update transaction lock is present - refusing to run concurrently with an update"
			return 1
		fi
	fi

	if [ -z "${SKIP_SWAP_CHECK:-}" ] && ! grep -qE '^(/dev/zram0|.*/system/swapfile) ' /proc/swaps 2>/dev/null; then
		log "BLOCKED: no memory-resilience swap active (neither zram nor the RosetteOS disk swap file) - refusing to proceed"
		return 1
	fi

	return 0
}
