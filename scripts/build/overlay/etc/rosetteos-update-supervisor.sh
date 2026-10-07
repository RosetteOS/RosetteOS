#!/bin/sh
#
# NebulaOS mutable-runtime mission, Phase 8: rollback orchestration and
# transaction state machine (docs/NEBULAOS_UPDATE_AND_ROLLBACK_DESIGN.md).
#
# Real constraint found while implementing this (not present in the design
# draft): this Moonraker version's update_manager (git_deploy.py/
# app_deploy.py, confirmed directly against vendor/moonraker source) has NO
# pre/post-update command hook at all - it performs fetch, checkout,
# venv/requirement sync, and service restart entirely on its own the moment
# a user clicks "update" in Mainsail, with no way for external code to run
# in between "new version staged" and "new version activated". The design
# doc's Stage 1 (pre-activation) / Stage 2 (post-activation) split is
# therefore collapsed here into a single post-hoc validation that runs
# after Moonraker has already restarted the affected service - this script
# is an independent poller, not a Moonraker plugin, specifically so it
# keeps working even if a bad update breaks Moonraker itself.
#
# Detection: git's own HEAD commit is polled per component. A change from
# the last-recorded value means "an update just happened" (via Moonraker's
# own update flow, or a manual git operation - this script does not care
# which). Rollback restores the previous known-good commit via
# `git reset --hard`, which needs no separate pre-update backup step for
# the source tree itself - git's own history/reflog already holds it,
# which is why known_good_commit is tracked here rather than snapshotting
# whole directory copies.
#
# Restart safety: never restarts a service while a print is active/paused
# (read-only Moonraker query, checked immediately before every restart -
# same printer-safety invariant as every other disruptive action in this
# project) - a deferred restart just waits and rechecks rather than
# skipping validation outright.
#
# NebulaOS mutable-runtime closure mission (2026-07-27), Phase D: Moonraker
# source and virtualenv are now one versioned release unit, not two
# independently-rolled-back things. Real gap this closes: Moonraker's own
# app_deploy.py._update_python_requirements() installs into the EXISTING
# venv in place whenever a commit changes requirements.txt - a plain
# `git reset --hard` on the source alone does nothing to undo whatever pip
# already did to the venv. Rather than re-implementing Moonraker's own
# in-place venv update logic (real risk of fighting/duplicating it), this
# supervisor instead maintains its own full backup of the venv, refreshed
# every time a (source, venv) pairing is confirmed healthy together, and
# always restores BOTH halves together on rollback - since only one paired
# backup ever exists at a time and both halves are always reset in the same
# step, there is no code path that can produce a mismatched pair.

ROSETTEOS_ROOT="${ROSETTEOS_ROOT:-/usr/data/rosetteos}"
HEALTHCHECK="${HEALTHCHECK:-/etc/rosetteos-healthcheck.sh}"
LOCKDIR="$ROSETTEOS_ROOT/updates/locks"
MOONRAKER_URL="http://127.0.0.1:7125"
MOONRAKER_ENV="$ROSETTEOS_ROOT/envs/moonraker"
MOONRAKER_ENV_BACKUP="$ROSETTEOS_ROOT/backups/moonraker/last-known-good-env"
POLL_INTERVAL=20
STABILIZE_SAMPLES=6
STABILIZE_INTERVAL=10
RESTART_GRACE_PERIOD=25

log() {
	echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) rosetteos-update-supervisor: $1"
}

# $1=component name -> echoes: path|init_script|opt_path|pidfile
component_info() {
	case "$1" in
		klipper)
			echo "$ROSETTEOS_ROOT/apps/klipper|/etc/init.d/S55klipper|/opt/klipper|/var/run/klippy.pid"
			;;
		moonraker)
			echo "$ROSETTEOS_ROOT/apps/moonraker|/etc/init.d/S56moonraker|/opt/moonraker|/var/run/moonraker.pid"
			;;
		mainsail)
			echo "$ROSETTEOS_ROOT/apps/mainsail||/usr/share/mainsail|"
			;;
	esac
}

state_file() {
	echo "$ROSETTEOS_ROOT/updates/$1/state.json"
}

read_state_field() {
	# $1=component $2=field
	f=$(state_file "$1")
	[ -e "$f" ] || return 0
	sed -n "s/.*\"$2\": *\"\([^\"]*\)\".*/\1/p" "$f" | head -1
}

write_state() {
	# $1=component $2=known_good $3=last_seen $4=state $5=reason
	f=$(state_file "$1")
	tmp="$f.tmp.$$"
	now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	{
		echo "{"
		echo "  \"component\": \"$1\","
		echo "  \"known_good_commit\": \"$2\","
		echo "  \"last_seen_commit\": \"$3\","
		echo "  \"state\": \"$4\","
		echo "  \"last_transition_at\": \"$now\","
		echo "  \"last_failure_reason\": \"$5\""
		echo "}"
	} > "$tmp"
	mv "$tmp" "$f"
}

# Read-only query, never combined with a restart in the same step - a
# printing/paused state means "wait", not "skip validation".
print_is_active() {
	stats=$(wget -q -O - --timeout=5 "$MOONRAKER_URL/printer/objects/query?print_stats=state" 2>/dev/null)
	case "$stats" in
		*'"state":"printing"'*|*'"state":"paused"'*) return 0 ;;
		*) return 1 ;;
	esac
}

# Waits (bounded) for any active print to finish before a disruptive
# restart - never forces a restart mid-print.
wait_for_print_idle() {
	tries=0
	while print_is_active; do
		tries=$((tries + 1))
		if [ "$tries" -ge 90 ]; then
			log "print still active after $((tries * 10))s - deferring restart, will re-check next poll cycle"
			return 1
		fi
		sleep 10
	done
	return 0
}

# Real bug found live (Moonraker paired-rollback test, 2026-07-27): a
# genuinely pre-existing race in this project's own init scripts -
# S55klipper/S56moonraker's own `restart() { stop; start; }` calls stop
# and start back-to-back with zero delay. BusyBox's start-stop-daemon's
# start step detects the OLD process (still genuinely mid-graceful-
# shutdown, not yet exited - confirmed live: "python3 is already
# running", moonraker down entirely for 3.5+ minutes afterward) and
# silently refuses to launch a new one. Using the combined "restart"
# action never gave this project's own fail-fast health checks anything
# to actually detect - not a false positive that time, a real missed
# restart. Splitting stop/start with an explicit wait for genuine process
# exit in between avoids the race entirely; not modifying
# S55klipper/S56moonraker's own frozen restart action itself, since
# normal (non-rollback, lower-I/O-contention) restarts elsewhere in this
# project have never hit this race in practice - only this supervisor's
# own restart calls need the fix.
safe_stop_start() {
	# $1=component
	info=$(component_info "$1")
	init_script=$(echo "$info" | cut -d'|' -f2)
	pidfile=$(echo "$info" | cut -d'|' -f4)
	"$init_script" stop
	if [ -n "$pidfile" ]; then
		tries=0
		while [ -f "$pidfile" ] && [ -d "/proc/$(cat "$pidfile" 2>/dev/null)" ] 2>/dev/null; do
			tries=$((tries + 1))
			if [ "$tries" -ge 20 ]; then
				log "$1: old process still not exited after ${tries}s - proceeding with start anyway"
				break
			fi
			sleep 1
		done
	fi
	"$init_script" start
}

restart_component() {
	# $1=component
	info=$(component_info "$1")
	init_script=$(echo "$info" | cut -d'|' -f2)
	wait_for_print_idle || return 1
	log "$1: restarting via $init_script"
	safe_stop_start "$1"
	# Real bug found live (first rollback test, 2026-07-26): Klipper
	# legitimately takes 15-25s to reconnect to the MCU and reach
	# klippy_state=ready after a process restart (confirmed repeatedly
	# elsewhere in this project's own qualification logs) - sampling
	# stage2 immediately mistook "still connecting" for "broken" and
	# triggered a false-positive rollback failure straight into
	# factory-fallback. This grace period must elapse before the
	# caller's first stage2 sample.
	sleep "$RESTART_GRACE_PERIOD"
	return 0
}

# Real bug found live (Moonraker paired-rollback test, 2026-07-27): even
# with restart_component's fixed grace period, a restart immediately
# following a venv restore (real extra disk I/O from cp -a on top of the
# git reset) sometimes needed longer than the grace period + first sample
# to reach ready - moonraker.log showed a completely clean startup and
# "Klippy ready" moments after the poller had already given up and gone to
# factory-fallback. A fixed grace period can't account for variable extra
# load from whatever the rollback itself just did. Splits stabilization
# into two phases: first, tolerantly POLL (not fail-fast) for the system
# to become ready at all within a generous bound; only once it has been
# seen ready at least once do subsequent samples fail fast - a check
# failing AFTER a prior success is a real, new problem (e.g. crashed right
# after starting), not startup variance, and should still be caught
# quickly.
wait_for_initial_ready() {
	tries=0
	max_tries=18
	while [ "$tries" -lt "$max_tries" ]; do
		"$HEALTHCHECK" stage2 && return 0
		tries=$((tries + 1))
		sleep 10
	done
	return 1
}

# Confirms health STAYS true for a short window after first becoming
# ready - fails fast on any bad sample here, since by this point the
# system has already proven it can start; a failure now is a real
# regression, not startup timing.
stabilized_stage2() {
	wait_for_initial_ready || return 1
	i=0
	while [ "$i" -lt "$STABILIZE_SAMPLES" ]; do
		sleep "$STABILIZE_INTERVAL"
		if ! "$HEALTHCHECK" stage2; then
			return 1
		fi
		i=$((i + 1))
	done
	return 0
}

# Preserves the failed commit + relevant logs under backups/<name>/failed-*
# per the mission's own "never silently discard evidence" requirement -
# never overwrites a previous failed-<timestamp> directory.
preserve_failure_evidence() {
	# $1=component $2=failed_commit $3=reason
	name="$1"; failed_commit="$2"; reason="$3"
	ts=$(date -u +%Y%m%dT%H%M%SZ)
	dir="$ROSETTEOS_ROOT/backups/$name/failed-$ts"
	mkdir -p "$dir"
	{
		echo "failed_commit=$failed_commit"
		echo "reason=$reason"
		echo "detected_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	} > "$dir/metadata.txt"
	case "$name" in
		klipper) cp /opt/printer_data/logs/klippy.log "$dir/" 2>/dev/null ;;
		moonraker) cp /opt/printer_data/logs/moonraker.log "$dir/" 2>/dev/null ;;
		mainsail)
			cp /var/log/nginx/mainsail-error.log "$dir/" 2>/dev/null
			cp "$ROSETTEOS_ROOT/apps/mainsail/release_info.json" "$dir/" 2>/dev/null
			;;
	esac
	log "$name: failure evidence preserved at $dir"
}

# Removes the bind mount, exposing the pristine immutable /opt/<app> copy
# underneath for the rest of this boot, and leaves the update lock in place
# so S05rosetteos-activate stays on immutable on every future boot too, until
# a human clears it - never silently re-attempts the same broken version.
factory_fallback() {
	# $1=component
	info=$(component_info "$1")
	opt_path=$(echo "$info" | cut -d'|' -f3)
	log "$1: falling back to factory/immutable copy at $opt_path (both new and previous versions failed validation)"
	if awk -v t="$opt_path" '$2==t {found=1} END{exit !found}' /proc/mounts; then
		umount "$opt_path" 2>/dev/null
	fi
	init_script=$(echo "$info" | cut -d'|' -f2)
	# Mainsail has no managed service (static files served directly by
	# nginx, no restart needed for the fallback content to take effect) -
	# component_info's mainsail entry deliberately leaves this field empty.
	[ -n "$init_script" ] || return 0
	wait_for_print_idle
	safe_stop_start "$1"
}

# NebulaOS mutable-runtime closure mission (2026-07-27), Phase C: Mainsail
# rollback. Real constraint confirmed against vendor/moonraker's own
# net_deploy.py: unlike git (where history/reflog gives a "previous version"
# for free), NetDeploy._extract_release() does `shutil.rmtree(self.path)`
# on every update with NO backup of its own - the previous release's files
# are simply gone once Moonraker's update() runs. This supervisor must
# therefore maintain its own independent snapshot of the last-known-healthy
# release, taken proactively (whenever a version is confirmed healthy), so
# there is something real to restore from after the fact - not reactively
# after detecting a bad update, by which point the old files no longer
# exist on disk at all.
#
# Detection uses release_info.json's own "version" field (written by
# Moonraker's net_deploy for a real update) rather than a git commit -
# falls back to a content hash of index.html for the offline factory seed,
# which ships without a release_info.json at all.
#
# No service restart is needed for activation/rollback - nginx serves
# whatever static files are currently on disk, so a directory swap alone is
# the entire "restart" for this component.

MAINSAIL_BACKUP="$ROSETTEOS_ROOT/backups/mainsail/last-known-good"

mainsail_version() {
	path="$1"
	if [ -f "$path/release_info.json" ]; then
		sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$path/release_info.json" | head -1
	else
		sha256sum "$path/index.html" 2>/dev/null | cut -d' ' -f1
	fi
}

# Discards any leftover .staging/.old directories from an interrupted
# snapshot/restore (device power-loss or reboot mid-operation) - both names
# are, by construction, never the live/active copy, so removing them on
# supervisor startup is always safe. Mirrors the mission's own required
# "discard incomplete staging" boot-recovery behavior. Covers both Mainsail
# and the Moonraker paired-venv backup, since both use the same
# atomic_directory_replace() staging/old naming convention.
cleanup_stale_staging() {
	rm -rf "$ROSETTEOS_ROOT/apps/mainsail.staging" "$ROSETTEOS_ROOT/apps/mainsail.old" \
		"$MAINSAIL_BACKUP.staging" "$MAINSAIL_BACKUP.old" \
		"$MOONRAKER_ENV.staging" "$MOONRAKER_ENV.old" \
		"$MOONRAKER_ENV_BACKUP.staging" "$MOONRAKER_ENV_BACKUP.old"
}

# Atomic-ish swap: build the full copy in a .staging sibling first, then
# two directory renames (each a single, near-instant syscall) to cut over -
# a process killed at any point before the first rename leaves the
# original completely untouched; killed between the two renames leaves the
# original moved aside as .old (recoverable) with the new copy already live.
# Not a true atomic transaction (a reader could observe a brief window with
# neither name present between the two renames), an accepted, documented
# tradeoff for a local dev-printer UI, not a highly concurrent service.
atomic_directory_replace() {
	# $1=new content source dir  $2=final target dir
	src="$1"; dst="$2"
	staging="$dst.staging"
	old="$dst.old"
	rm -rf "$staging" "$old"
	mkdir -p "$(dirname "$staging")"
	cp -a "$src" "$staging"
	if [ -e "$dst" ]; then
		mv "$dst" "$old"
	fi
	mv "$staging" "$dst"
	rm -rf "$old"
}

mainsail_snapshot_to_backup() {
	path="$ROSETTEOS_ROOT/apps/mainsail"
	[ -d "$path" ] || return 0
	atomic_directory_replace "$path" "$MAINSAIL_BACKUP"
}

# Real bug found live (Mainsail rollback retest, 2026-07-27): restoring the
# backup INTO $ROSETTEOS_ROOT/apps/mainsail via atomic_directory_replace
# renames that directory away and creates a new one at the same name - but
# S05rosetteos-activate's bind mount (/usr/share/mainsail) was established
# against the ORIGINAL directory's inode, which Linux keeps valid at its
# new (renamed-away) location rather than "following" the name back to
# whatever now occupies the old path. nginx kept serving the stale,
# now-unlinked old content the whole time, while direct inspection of the
# path by name showed the freshly-restored good content - stage2-mainsail's
# real HTTP check correctly saw broken/stale content and correctly failed,
# it was atomic_directory_replace's rename semantics that were wrong for a
# path with an active bind mount sourced from it. Klipper/Moonraker's own
# git reset --hard never hits this because it rewrites file content INSIDE
# the same directory/inode, never renaming the directory itself - only
# Mainsail's restore path (the only user of atomic_directory_replace on an
# actively bind-mounted source) needed this fix.
remount_mainsail_bind() {
	target=/usr/share/mainsail
	if awk -v t="$target" '$2==t {found=1} END{exit !found}' /proc/mounts; then
		umount "$target" 2>/dev/null
	fi
	mount --bind "$ROSETTEOS_ROOT/apps/mainsail" "$target"
}

# A first live test looked like a transient WiFi-blip false positive
# (single failed wget sample right after an atomic directory swap) - the
# real cause, found on a second reproduction, was the bind-mount desync
# documented above at remount_mainsail_bind(), now fixed at the source.
# Kept as a real, if now mostly redundant, defense: nginx serves static
# files with no restart/reload needed, so a few quick retries cost nothing
# if an actual transient hiccup ever does occur.
stabilized_stage2_mainsail() {
	i=0
	while [ "$i" -lt 3 ]; do
		"$HEALTHCHECK" stage2-mainsail && return 0
		sleep 3
		i=$((i + 1))
	done
	return 1
}

validate_mainsail() {
	name="mainsail"
	path="$ROSETTEOS_ROOT/apps/mainsail"
	new_version=$(mainsail_version "$path")
	known_good=$(read_state_field "$name" known_good_commit)

	mkdir -p "$LOCKDIR"
	: > "$LOCKDIR/$name.lock"
	write_state "$name" "$known_good" "$new_version" "validating" ""

	log "$name: new version detected ($new_version) - validating"

	# Real bug found live (2026-07-27): this same desync also affects a
	# genuine Mainsail update via Moonraker's own net_deploy.py, which does
	# the same shutil.rmtree()+mkdir() on this bind-mount's source
	# directory - a Linux bind mount stays pinned to the original inode
	# regardless of what happens to the path used to create it, so nginx
	# would otherwise keep serving stale pre-update content indefinitely
	# (invisible to any HTTP-based health check, since the check itself
	# would only ever see the OLD content) until a reboot happened to
	# re-run S05rosetteos-activate. Remounting here, on every detected
	# version change and before any health check runs, makes the check
	# actually test what was just installed - not what used to be there.
	remount_mainsail_bind

	stage1_ok=true
	"$HEALTHCHECK" stage1 "$name" "$path" || stage1_ok=false

	if [ "$stage1_ok" = "true" ] && stabilized_stage2_mainsail; then
		log "$name: new version $new_version passed full validation - recording as known-good"
		write_state "$name" "$new_version" "$new_version" "healthy" ""
		mainsail_snapshot_to_backup
		rm -f "$LOCKDIR/$name.lock"
		return
	fi

	reason="stage2_failed"
	[ "$stage1_ok" = "true" ] || reason="stage1_failed"
	log "$name: $reason on new version $new_version - restoring from last-known-good backup"
	preserve_failure_evidence "$name" "$new_version" "$reason"

	if [ ! -d "$MAINSAIL_BACKUP" ]; then
		log "$name: no backup exists yet (first-ever validation failed) - going straight to factory-fallback"
		preserve_failure_evidence "$name" "$known_good" "no_backup_available"
		factory_fallback "$name"
		write_state "$name" "$known_good" "$known_good" "factory-fallback" "${reason}:$new_version;no_backup_available"
		return
	fi

	atomic_directory_replace "$MAINSAIL_BACKUP" "$path"
	remount_mainsail_bind
	if "$HEALTHCHECK" stage1 "$name" "$path" && stabilized_stage2_mainsail; then
		log "$name: restored backup re-validated healthy"
		write_state "$name" "$known_good" "$known_good" "rolled-back" "${reason}:$new_version"
		rm -f "$LOCKDIR/$name.lock"
	else
		preserve_failure_evidence "$name" "$known_good" "stage2_failed_after_restore"
		factory_fallback "$name"
		write_state "$name" "$known_good" "$known_good" "factory-fallback" "${reason}:$new_version;previous_also_unhealthy"
	fi
}

poll_mainsail_once() {
	name="mainsail"
	path="$ROSETTEOS_ROOT/apps/mainsail"
	[ -f "$path/index.html" ] || return 0

	current=$(mainsail_version "$path")
	[ -z "$current" ] && return 0

	last_seen=$(read_state_field "$name" last_seen_commit)
	if [ -z "$last_seen" ]; then
		# First observation this boot - bootstrap state and take the first
		# backup snapshot, matching klipper/moonraker's own bootstrap
		# behavior (whatever is running now was already proven at boot).
		write_state "$name" "$current" "$current" "healthy" ""
		mainsail_snapshot_to_backup
		log "$name: bootstrapped state at $current"
		return 0
	fi

	state=$(read_state_field "$name" state)
	if [ -e "$LOCKDIR/$name.lock" ] && [ "$state" = "factory-fallback" ]; then
		return 0
	fi
	if [ "$current" != "$last_seen" ] && [ "$state" != "validating" ]; then
		validate_mainsail
	fi
}

# Snapshots the current Moonraker venv as the new last-known-good pairing
# partner. Only called immediately after the SOURCE at this same commit has
# already passed full validation, so "the venv currently on disk" is by
# definition the one that was just proven to work with this exact source.
moonraker_snapshot_env() {
	[ -d "$MOONRAKER_ENV" ] || return 0
	atomic_directory_replace "$MOONRAKER_ENV" "$MOONRAKER_ENV_BACKUP"
}

# Restores the paired venv backup. Returns 1 (without restoring anything)
# if no backup exists yet - caller must treat this the same as Mainsail's
# "no backup available" case and go straight to factory-fallback rather
# than restart Moonraker against a half-reset pairing.
moonraker_restore_env() {
	[ -d "$MOONRAKER_ENV_BACKUP" ] || return 1
	atomic_directory_replace "$MOONRAKER_ENV_BACKUP" "$MOONRAKER_ENV"
	return 0
}

validate_component() {
	# $1=component. Runs after a HEAD change was already detected.
	name="$1"
	info=$(component_info "$name")
	path=$(echo "$info" | cut -d'|' -f1)
	new_commit=$(git -C "$path" rev-parse HEAD 2>/dev/null)
	known_good=$(read_state_field "$name" known_good_commit)

	mkdir -p "$LOCKDIR"
	: > "$LOCKDIR/$name.lock"
	write_state "$name" "$known_good" "$new_commit" "validating" ""

	log "$name: new commit detected ($new_commit) - validating"

	if ! "$HEALTHCHECK" stage1 "$name" "$path"; then
		log "$name: stage1 FAILED on new commit $new_commit - reverting to $known_good"
		preserve_failure_evidence "$name" "$new_commit" "stage1_failed"
		if [ "$name" = "moonraker" ] && ! moonraker_restore_env; then
			log "$name: no paired venv backup exists yet - going straight to factory-fallback rather than restore a mismatched pair"
			preserve_failure_evidence "$name" "$known_good" "no_env_backup_available"
			factory_fallback "$name"
			write_state "$name" "$known_good" "$known_good" "factory-fallback" "stage1_failed:$new_commit;no_env_backup_available"
			return
		fi
		git -C "$path" reset --hard "$known_good" >/dev/null 2>&1
		restart_component "$name"
		if stabilized_stage2; then
			log "$name: reverted version re-validated healthy"
			write_state "$name" "$known_good" "$known_good" "rolled-back" "stage1_failed:$new_commit"
			rm -f "$LOCKDIR/$name.lock"
		else
			preserve_failure_evidence "$name" "$known_good" "stage2_failed_after_stage1_rollback"
			factory_fallback "$name"
			# last_seen_commit must reflect the persistent repo's ACTUAL
			# current HEAD (known_good, since it was reset above), not
			# new_commit - real bug found live: recording new_commit here
			# left state.json out of sync with git's real state, so the
			# very next poll saw current(known_good) != last_seen(new_commit)
			# and mistook the already-failed-over state for a fresh update,
			# re-triggering validation and eventually overwriting this
			# factory-fallback state with a false "healthy" while /opt/klipper
			# was still the unmounted immutable copy, not the persistent one.
			write_state "$name" "$known_good" "$known_good" "factory-fallback" "stage1_failed:$new_commit;previous_also_unhealthy"
		fi
		return
	fi

	if stabilized_stage2; then
		log "$name: new commit $new_commit passed full validation - recording as known-good"
		write_state "$name" "$new_commit" "$new_commit" "healthy" ""
		# Snapshot the venv as the new paired backup ONLY after the source
		# at this exact commit has already been proven healthy together
		# with whatever is currently on disk in the venv - this is what
		# makes the pairing atomic: both halves are always captured (and
		# later restored) as a single unit, so there is no code path that
		# can record source commit A paired with a venv snapshot that
		# actually belongs to a different commit.
		[ "$name" = "moonraker" ] && moonraker_snapshot_env
		rm -f "$LOCKDIR/$name.lock"
		return
	fi

	log "$name: stage2 FAILED on new commit $new_commit - reverting to $known_good"
	preserve_failure_evidence "$name" "$new_commit" "stage2_failed"
	if [ "$name" = "moonraker" ] && ! moonraker_restore_env; then
		log "$name: no paired venv backup exists yet - going straight to factory-fallback rather than restore a mismatched pair"
		preserve_failure_evidence "$name" "$known_good" "no_env_backup_available"
		factory_fallback "$name"
		write_state "$name" "$known_good" "$known_good" "factory-fallback" "stage2_failed:$new_commit;no_env_backup_available"
		return
	fi
	git -C "$path" reset --hard "$known_good" >/dev/null 2>&1
	restart_component "$name"
	if stabilized_stage2; then
		log "$name: reverted version re-validated healthy"
		write_state "$name" "$known_good" "$known_good" "rolled-back" "stage2_failed:$new_commit"
		rm -f "$LOCKDIR/$name.lock"
	else
		preserve_failure_evidence "$name" "$known_good" "stage2_failed_after_stage2_rollback"
		factory_fallback "$name"
		write_state "$name" "$known_good" "$known_good" "factory-fallback" "stage2_failed:$new_commit;previous_also_unhealthy"
	fi
}

# Real bug found live 2026-07-28: Moonraker's own machine.py
# restart_moonraker_service() is how Moonraker "restarts itself" for its
# own reserved update_manager slot (used by both a real self-update and
# Recover) - it calls do_service_action("restart", "moonraker") and
# swallows any exception (`except Exception: pass`, confirmed directly
# against vendor/moonraker's own source). moonraker.conf's [machine]
# section sets `provider: supervisord_cli`, but this Buildroot image has
# no supervisord daemon at all (no binary running, no config, nothing in
# any init.d script) - BusyBox init + this project's own S## scripts are
# used instead. `supervisorctl restart moonraker` therefore always fails,
# silently, and moonraker stays dead. The git-HEAD-delta detection below
# is this supervisor's only other restart trigger, and a Recover that
# fixes a dirty tree without moving HEAD (an entirely normal case) never
# produces a delta - live-reproduced exactly this way: Moonraker stayed
# dead for the rest of the boot with nothing left to notice. This is an
# independent liveness check with no git dependency at all, specifically
# to close that gap.
ensure_moonraker_alive() {
	if [ -e "$LOCKDIR/moonraker.lock" ]; then
		# A validation/rollback for moonraker is already in flight and will
		# handle its own restart - restarting it out from under that logic
		# here would race with it.
		return 0
	fi
	info=$(component_info moonraker)
	pidfile=$(echo "$info" | cut -d'|' -f4)
	if [ -f "$pidfile" ] && [ -d "/proc/$(cat "$pidfile" 2>/dev/null)" ] 2>/dev/null; then
		return 0
	fi
	log "moonraker: process not running (pidfile stale or missing) - restarting independent of any git change"
	wait_for_print_idle || return 0
	init_script=$(echo "$info" | cut -d'|' -f2)
	"$init_script" start
}

poll_once() {
	ensure_moonraker_alive
	for name in klipper moonraker; do
		info=$(component_info "$name")
		path=$(echo "$info" | cut -d'|' -f1)
		[ -d "$path/.git" ] || continue

		current=$(git -C "$path" rev-parse HEAD 2>/dev/null)
		[ -z "$current" ] && continue

		last_seen=$(read_state_field "$name" last_seen_commit)
		if [ -z "$last_seen" ]; then
			# First observation this boot - bootstrap state without
			# triggering validation. Whatever is running now was already
			# proven at boot by S99confirm-good/the existing readiness
			# checks; there is no legitimate "known good" reference to
			# compare against yet other than this.
			write_state "$name" "$current" "$current" "healthy" ""
			[ "$name" = "moonraker" ] && moonraker_snapshot_env
			log "$name: bootstrapped state at $current"
			continue
		fi

		state=$(read_state_field "$name" state)
		# factory-fallback is a deliberate terminal state (design doc sec
		# 3.1 step 5: "never silently succeed on a degraded configuration")
		# - belt-and-suspenders against ever re-triggering validation here
		# even if state.json's commit bookkeeping were ever wrong again:
		# a human must clear $LOCKDIR/$name.lock (and re-run
		# S05rosetteos-activate or reboot) to re-enable the persistent copy.
		if [ -e "$LOCKDIR/$name.lock" ] && [ "$state" = "factory-fallback" ]; then
			continue
		fi

		# Real gap found live (2026-07-27): on a device whose moonraker
		# state.json already existed from before this paired-venv backup
		# mechanism shipped, last_seen_commit was never empty, so the
		# bootstrap branch above (which is the only other place
		# moonraker_snapshot_env() is called outside a successful
		# validation) never ran even once - leaving the paired backup
		# permanently missing until the next real commit change. Self-heal
		# opportunistically: if healthy with no pending change, take the
		# snapshot now rather than waiting indefinitely for one.
		if [ "$name" = "moonraker" ] && [ "$state" = "healthy" ] && [ ! -d "$MOONRAKER_ENV_BACKUP" ]; then
			log "$name: no paired venv backup yet on an already-healthy install - snapshotting now"
			moonraker_snapshot_env
		fi

		if [ "$current" != "$last_seen" ] && [ "$state" != "validating" ]; then
			validate_component "$name"
		fi
	done

	poll_mainsail_once
}

loop() {
	log "starting (poll interval ${POLL_INTERVAL}s)"
	cleanup_stale_staging
	while true; do
		poll_once
		sleep "$POLL_INTERVAL"
	done
}

case "$1" in
	loop)
		loop
		;;
	poll-once)
		poll_once
		;;
	*)
		echo "usage: $0 loop|poll-once" >&2
		exit 2
		;;
esac
