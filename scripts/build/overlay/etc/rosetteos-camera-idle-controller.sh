#!/bin/sh
# NebulaOS camera idle-pause qualification controller (C2, pre-
# qualification mission Phase A7, 2026-07-31 - see docs/NEBULAOS_CAMERA_
# USB_RT_SOURCE_ANALYSIS.md sec 18.10/18.16-18.20 and the original camera
# analysis sec 9-10 for the source-grounded rationale).
#
# This is a distinct, independent capability from S50webcam's own
# supervisor loop (which only ever restarts a dead ustreamer process) -
# it never touches the ustreamer process itself, only its existing local
# /pause and /resume HTTP endpoints (already proven, source-confirmed to
# drive a real close()/reopen() cycle - see the camera analysis sec 9).
# Keeping this separate means a bug in this NEW, experimental controller
# can never take down the already-hardware-proven crash-recovery S50webcam
# provides.
#
# Default state (C0): DISABLED. Every build ships with the camera always
# active, exactly as it is today, until an explicit maintenance marker
# opts into C2. This file being present in the image changes nothing by
# itself.
#
# Viewer-activity signal: rather than depend on a live client-count query
# from ustreamer (unconfirmed to exist from source - see the source
# analysis's own Variant F note) or naive snapshot polling (a `?action=
# snapshot` request is a single short-lived connection that completes in
# well under a second and must NOT be mistaken for an ongoing viewer),
# this watches for ESTABLISHED TCP connections on ustreamer's own local
# listening port (127.0.0.1:8080) via /proc/net/tcp directly - no
# dependency on netstat/ss, which may not be present in this minimal
# image. A genuine MJPEG stream connection is deliberately long-lived
# (multipart, kept open for as long as the viewer watches); a snapshot's
# connection closes almost immediately. Sampling once per poll interval
# and requiring a full, uninterrupted grace period of "no connection"
# before pausing means a single stray snapshot-connection sample (if ever
# actually caught mid-request) only delays the grace countdown by one
# tick - it can never cause an incorrect pause, and the bias is always
# toward staying active longer, never toward pausing too eagerly.
#
# Resume is retried with a simple bounded linear backoff and always wins
# over pausing: a fresh viewer connection immediately zeroes the idle
# counter and drives a resume attempt, with the controller staying in
# "paused" belief (and retrying resume on the very next tick) if the
# retries are exhausted, rather than ever assuming success it can't
# confirm.
#
# Sourced by S51nebulaos-camera-idle-controller. Also sourced directly by
# tests/rosetteos-camera-idle-controller-tests.sh so there is exactly one
# copy of this logic, never a second one to drift out of sync.

ROSETTEOS_CAMERA_IDLE_MARKER="${ROSETTEOS_CAMERA_IDLE_MARKER:-/usr/data/rosetteos/maintenance/camera-idle-mode}"
ROSETTEOS_CAMERA_IDLE_PORT="${ROSETTEOS_CAMERA_IDLE_PORT:-8080}"
ROSETTEOS_CAMERA_IDLE_POLL_INTERVAL="${ROSETTEOS_CAMERA_IDLE_POLL_INTERVAL:-5}"
ROSETTEOS_CAMERA_IDLE_GRACE_SAMPLES="${ROSETTEOS_CAMERA_IDLE_GRACE_SAMPLES:-12}"
ROSETTEOS_CAMERA_IDLE_RESUME_RETRIES="${ROSETTEOS_CAMERA_IDLE_RESUME_RETRIES:-5}"
ROSETTEOS_CAMERA_IDLE_RESUME_BACKOFF_BASE="${ROSETTEOS_CAMERA_IDLE_RESUME_BACKOFF_BASE:-1}"
ROSETTEOS_CAMERA_IDLE_STATE_FILE="${ROSETTEOS_CAMERA_IDLE_STATE_FILE:-/var/run/rosetteos-camera-idle-state}"

# Prints "C2" if the marker requests it, "C0" (default, disabled)
# otherwise - fails safe to disabled on any unrecognized marker content.
rosetteos_camera_idle_requested_mode() {
	marker="${1:-$ROSETTEOS_CAMERA_IDLE_MARKER}"
	if [ -f "$marker" ] && [ "$(cat "$marker" 2>/dev/null)" = "C2" ]; then
		printf 'C2'
	else
		printf 'C0'
	fi
}

# True (exit 0) if at least one ESTABLISHED TCP connection currently
# exists on the given local port. False (exit 1) if none. Exit 2 if
# /proc/net/tcp can't be read at all (treated as "unknown" by callers,
# never silently as "no viewer").
rosetteos_camera_has_established_connection() {
	port="${1:-$ROSETTEOS_CAMERA_IDLE_PORT}"
	proc_net_tcp="${2:-/proc/net/tcp}"
	[ -r "$proc_net_tcp" ] || return 2
	port_hex=$(printf '%04X' "$port")
	awk -v port_hex="$port_hex" '
		NR > 1 {
			split($2, local, ":")
			if (local[2] == port_hex && $4 == "01") { found=1; exit }
		}
		END { exit !found }
	' "$proc_net_tcp"
}

rosetteos_camera_call_endpoint() {
	path="$1"
	curl -s -o /dev/null -w '%{http_code}' --max-time 3 \
		"http://127.0.0.1:${ROSETTEOS_CAMERA_IDLE_PORT}${path}" 2>/dev/null
}

rosetteos_camera_pause() {
	code=$(rosetteos_camera_call_endpoint /pause)
	if [ "$code" = "200" ]; then
		echo "rosetteos-camera-idle: paused (HTTP $code)" >&2
		return 0
	fi
	echo "rosetteos-camera-idle: pause request failed (HTTP ${code:-none})" >&2
	return 1
}

rosetteos_camera_resume_with_retry() {
	attempt=1
	max="$ROSETTEOS_CAMERA_IDLE_RESUME_RETRIES"
	while [ "$attempt" -le "$max" ]; do
		code=$(rosetteos_camera_call_endpoint /resume)
		if [ "$code" = "200" ]; then
			echo "rosetteos-camera-idle: resumed (HTTP $code, attempt $attempt/$max)" >&2
			return 0
		fi
		echo "rosetteos-camera-idle: resume attempt $attempt/$max failed (HTTP ${code:-none})" >&2
		sleep $((ROSETTEOS_CAMERA_IDLE_RESUME_BACKOFF_BASE * attempt))
		attempt=$((attempt + 1))
	done
	echo "rosetteos-camera-idle: resume failed after $max attempts - will retry again next tick if a viewer is still present" >&2
	return 1
}

rosetteos_camera_idle_read_state() {
	state_file="${1:-$ROSETTEOS_CAMERA_IDLE_STATE_FILE}"
	if [ -f "$state_file" ]; then
		s=$(cat "$state_file" 2>/dev/null)
		case "$s" in
			active|paused) printf '%s' "$s"; return 0 ;;
		esac
	fi
	# Unknown/missing state always defaults to "active" - the safe
	# direction on any doubt (never assume paused without proof).
	printf 'active'
}

rosetteos_camera_idle_write_state() {
	state_file="${1:-$ROSETTEOS_CAMERA_IDLE_STATE_FILE}"
	value="$2"
	mkdir -p "$(dirname "$state_file")" 2>/dev/null
	printf '%s' "$value" > "$state_file" 2>/dev/null
}

# One iteration of the idle-pause state machine. Takes the current state,
# the current consecutive-idle-sample count, and a caller-supplied
# has_viewer ("yes"/"no") - kept as explicit inputs (rather than calling
# rosetteos_camera_has_established_connection internally) specifically so
# this can be unit-tested deterministically without any real network
# state. Real side effects (pause/resume HTTP calls) still happen here,
# not in a separate pure function - tests fake `curl` on PATH the same
# way other qualification controllers in this project fake their own
# external commands. Prints the new "state idle_samples" as two
# space-separated fields on stdout.
rosetteos_camera_idle_tick() {
	state="$1"
	idle_samples="$2"
	has_viewer="$3"
	grace_samples="${4:-$ROSETTEOS_CAMERA_IDLE_GRACE_SAMPLES}"

	if [ "$has_viewer" = "yes" ]; then
		idle_samples=0
		if [ "$state" = "paused" ]; then
			if rosetteos_camera_resume_with_retry; then
				state="active"
			fi
			# On failure, state deliberately stays "paused" - the very
			# next tick (viewer still present) tries the full resume
			# sequence again from scratch, rather than assuming success.
		fi
	else
		if [ "$state" = "active" ]; then
			idle_samples=$((idle_samples + 1))
			if [ "$idle_samples" -ge "$grace_samples" ]; then
				if rosetteos_camera_pause; then
					state="paused"
				fi
				idle_samples=0
			fi
		fi
		# If already paused with no viewer, nothing to do - stays paused,
		# idle_samples stays irrelevant/reset.
	fi
	printf '%s %s' "$state" "$idle_samples"
}

# The real, long-running loop. Always resumes on the way out (graceful
# stop only - SIGKILL can't be trapped, matching this project's own
# already-documented, accepted limitation for its other supervisors), so
# stopping this controller never leaves the camera stuck paused. Falls
# back to "always active" by construction: if this process is not
# running at all, ustreamer simply stays in whatever state it was last
# told, and S50webcam's own existing supervisor already resets ustreamer
# to its default unpaused state on any ustreamer crash/restart - the
# residual risk (this controller killed via SIGKILL while ustreamer
# itself stays alive and paused) is real and is tracked as a required
# later hardware test, not silently assumed away.
rosetteos_camera_idle_run_loop() {
	state=$(rosetteos_camera_idle_read_state)
	idle_samples=0
	trap 'rosetteos_camera_resume_with_retry || true; exit 0' TERM INT
	while true; do
		conn_result=0
		rosetteos_camera_has_established_connection || conn_result=$?
		case "$conn_result" in
			0) has_viewer=yes ;;
			1) has_viewer=no ;;
			*) has_viewer=no ;;  # /proc/net/tcp unreadable - treat cautiously as no viewer, do not crash the loop
		esac
		result=$(rosetteos_camera_idle_tick "$state" "$idle_samples" "$has_viewer")
		state=${result%% *}
		idle_samples=${result##* }
		rosetteos_camera_idle_write_state "$ROSETTEOS_CAMERA_IDLE_STATE_FILE" "$state"
		sleep "$ROSETTEOS_CAMERA_IDLE_POLL_INTERVAL"
	done
}

