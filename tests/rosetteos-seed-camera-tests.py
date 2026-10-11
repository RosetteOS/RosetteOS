#!/usr/bin/env python3
#
# Offline, repeatable tests for
# scripts/build/overlay/usr/libexec/nebulaos-seed-camera (final Moonraker
# update/camera implementation mission, 2026-07-27). Imports the actual
# production module directly (no parallel copy of the logic) and exercises
# run() with fake fetch/post/sleep callables and a temp-directory marker
# path - no real Moonraker, no real device, no real network, ever.
#
# Usage: python3 tests/rosetteos-seed-camera-tests.py

from __future__ import annotations

import importlib.machinery
import importlib.util
import json
import os
import shutil
import sys
import tempfile

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
MODULE_PATH = os.path.join(
    SCRIPT_DIR, "..", "scripts", "build", "overlay", "usr", "libexec", "rosetteos-seed-camera"
)


def _load_module():
    loader = importlib.machinery.SourceFileLoader("rosetteos_seed_camera", MODULE_PATH)
    spec = importlib.util.spec_from_loader("rosetteos_seed_camera", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


cam = _load_module()

PASS = 0
FAIL = 0


def check(desc, condition, detail=""):
    global PASS, FAIL
    if condition:
        print(f"PASS: {desc}")
        PASS += 1
    else:
        print(f"FAIL: {desc}" + (f" ({detail})" if detail else ""))
        FAIL += 1


class FakeMoonraker:
    """A tiny, deterministic stand-in for Moonraker's webcam API - a list
    of webcam dicts that fetch()/post() operate against, plus counters so
    tests can assert exactly how many times each was called (proving "no
    API mutation" where required)."""

    def __init__(self, webcams=None, available=True):
        self.webcams = list(webcams or [])
        self.available = available
        self.get_calls = 0
        self.post_calls = 0
        self._next_uid = 1

    def fetch(self, path):
        self.get_calls += 1
        if not self.available:
            raise ConnectionError("moonraker not reachable")
        assert path == "/server/webcams/list"
        return json.dumps({"result": {"webcams": self.webcams}})

    def post(self, path, payload):
        self.post_calls += 1
        assert path == "/server/webcams/item"
        entry = dict(payload)
        entry["uid"] = f"fake-uid-{self._next_uid}"
        self._next_uid += 1
        entry["source"] = "database"
        self.webcams.append(entry)
        return json.dumps({"result": {"webcam": entry}})


def with_marker_dir(fn):
    d = tempfile.mkdtemp(prefix="camera-seed-test-")
    try:
        return fn(os.path.join(d, "system", "default-camera-seeded.json"))
    finally:
        shutil.rmtree(d, ignore_errors=True)


def run_cam(marker_path, moon, retry_attempts=3, retry_delay=0):
    logs = []
    rc = cam.run(
        fetch=moon.fetch,
        post=moon.post,
        marker_path=marker_path,
        log=logs.append,
        retry_attempts=retry_attempts,
        retry_delay=retry_delay,
        sleep=lambda _s: None,
    )
    return rc, logs


# --- Test 1: marker exists, no cameras - no API mutation, camera not recreated ---
def test_marker_exists_no_cameras():
    def body(marker_path):
        os.makedirs(os.path.dirname(marker_path), exist_ok=True)
        with open(marker_path, "w") as f:
            json.dump({"seeded_at": "x", "result": "created", "uid": "u1"}, f)
        moon = FakeMoonraker(webcams=[])
        rc, logs = run_cam(marker_path, moon)
        check("marker exists + no cameras: rc==0", rc == 0)
        check("marker exists + no cameras: no GET calls", moon.get_calls == 0, f"got {moon.get_calls}")
        check("marker exists + no cameras: no POST calls", moon.post_calls == 0, f"got {moon.post_calls}")

    with_marker_dir(body)


# --- Test 2: marker exists, camera exists - no API mutation ---
def test_marker_exists_camera_exists():
    def body(marker_path):
        os.makedirs(os.path.dirname(marker_path), exist_ok=True)
        with open(marker_path, "w") as f:
            json.dump({"seeded_at": "x", "result": "created", "uid": "u1"}, f)
        moon = FakeMoonraker(webcams=[{"source": "database", "uid": "u1", "name": "Nebula"}])
        rc, logs = run_cam(marker_path, moon)
        check("marker exists + camera exists: rc==0", rc == 0)
        check("marker exists + camera exists: no GET calls", moon.get_calls == 0)
        check("marker exists + camera exists: no POST calls", moon.post_calls == 0)

    with_marker_dir(body)


# --- Test 3: marker absent, API unavailable - bounded retry, no marker, safe exit ---
def test_marker_absent_api_unavailable():
    def body(marker_path):
        moon = FakeMoonraker(webcams=[], available=False)
        rc, logs = run_cam(marker_path, moon, retry_attempts=3, retry_delay=0)
        check("API unavailable: rc==1", rc == 1)
        check("API unavailable: attempted exactly retry_attempts GETs", moon.get_calls == 3, f"got {moon.get_calls}")
        check("API unavailable: no POST calls", moon.post_calls == 0)
        check("API unavailable: no marker written", not os.path.exists(marker_path))
        check("API unavailable: failure logged", any("unavailable" in line or "never became available" in line for line in logs))

    with_marker_dir(body)


# --- Test 4: marker absent, no cameras - one camera created, verified, marker written ---
def test_marker_absent_no_cameras_creates():
    def body(marker_path):
        moon = FakeMoonraker(webcams=[])
        rc, logs = run_cam(marker_path, moon)
        check("no cameras: rc==0", rc == 0)
        check("no cameras: exactly one POST", moon.post_calls == 1, f"got {moon.post_calls}")
        check("no cameras: exactly one camera now exists", len(moon.webcams) == 1)
        check("no cameras: marker written", os.path.exists(marker_path))
        with open(marker_path) as f:
            marker = json.load(f)
        check("no cameras: marker result is 'created'", marker.get("result") == "created")
        check("no cameras: marker records a uid", bool(marker.get("uid")))

    with_marker_dir(body)


# --- Test 5: marker absent, database camera already exists - adopt, no duplicate ---
def test_marker_absent_database_camera_exists():
    def body(marker_path):
        moon = FakeMoonraker(
            webcams=[{"source": "database", "uid": "existing-uid", "name": "SomeOtherName"}]
        )
        rc, logs = run_cam(marker_path, moon)
        check("db camera exists: rc==0", rc == 0)
        check("db camera exists: no POST (no duplicate)", moon.post_calls == 0)
        check("db camera exists: still exactly one camera", len(moon.webcams) == 1)
        with open(marker_path) as f:
            marker = json.load(f)
        check(
            "db camera exists: marker result is adopted",
            marker.get("result") == "existing-database-camera-adopted",
        )
        check("db camera exists: marker references the existing uid", marker.get("uid") == "existing-uid")

    with_marker_dir(body)


# --- Test 6: marker absent, config camera exists - refuse, no success marker ---
def test_marker_absent_config_camera_exists():
    def body(marker_path):
        moon = FakeMoonraker(webcams=[{"source": "config", "name": "Nebula"}])
        rc, logs = run_cam(marker_path, moon)
        check("config camera exists: rc==1", rc == 1)
        check("config camera exists: no POST", moon.post_calls == 0)
        check("config camera exists: no marker written", not os.path.exists(marker_path))
        check("config camera exists: logged clearly", any("config-sourced" in line for line in logs))

    with_marker_dir(body)


# --- Test 7: creation POST succeeds but verification finds no camera - failure, no marker ---
def test_creation_reports_success_but_verification_empty():
    def body(marker_path):
        moon = FakeMoonraker(webcams=[])

        def post_but_dont_actually_add(path, payload):
            moon.post_calls += 1
            return json.dumps({"result": {"webcam": {}}})  # POST "succeeds" but nothing was added

        logs = []
        rc = cam.run(
            fetch=moon.fetch,
            post=post_but_dont_actually_add,
            marker_path=marker_path,
            log=logs.append,
            retry_attempts=3,
            retry_delay=0,
            sleep=lambda _s: None,
        )
        check("verification empty: rc==1", rc == 1)
        check("verification empty: no marker written", not os.path.exists(marker_path))
        check(
            "verification empty: logged as unverified",
            any("no matching database camera" in line for line in logs),
        )

    with_marker_dir(body)


# --- Test 8: creation POST succeeds but wrong source/service/URLs - failure, no marker ---
def test_creation_wrong_fields():
    def body(marker_path):
        moon = FakeMoonraker(webcams=[])

        def post_wrong_service(path, payload):
            moon.post_calls += 1
            entry = dict(payload)
            entry["uid"] = "bad-uid"
            entry["source"] = "database"
            entry["service"] = "not-a-real-service"  # wrong on purpose
            moon.webcams.append(entry)
            return json.dumps({"result": {"webcam": entry}})

        logs = []
        rc = cam.run(
            fetch=moon.fetch,
            post=post_wrong_service,
            marker_path=marker_path,
            log=logs.append,
            retry_attempts=3,
            retry_delay=0,
            sleep=lambda _s: None,
        )
        check("wrong fields: rc==1", rc == 1)
        check("wrong fields: no marker written", not os.path.exists(marker_path))

    with_marker_dir(body)


# --- Test 9: repeated invocation leaves exactly one camera ---
def test_repeated_invocation_no_duplicate():
    def body(marker_path):
        moon = FakeMoonraker(webcams=[])
        rc1, _ = run_cam(marker_path, moon)
        rc2, _ = run_cam(marker_path, moon)
        check("repeated invocation: both runs succeed", rc1 == 0 and rc2 == 0)
        check("repeated invocation: exactly one POST total", moon.post_calls == 1, f"got {moon.post_calls}")
        check("repeated invocation: exactly one camera", len(moon.webcams) == 1)

    with_marker_dir(body)


# --- Test 10: user deletes camera after marker exists - not recreated ---
def test_user_deletion_not_recreated():
    def body(marker_path):
        moon = FakeMoonraker(webcams=[])
        rc1, _ = run_cam(marker_path, moon)
        check("deletion test: initial create succeeded", rc1 == 0)
        # user deletes the camera through Mainsail/API - moon.webcams now empty
        moon.webcams = []
        moon.post_calls = 0
        moon.get_calls = 0
        rc2, logs2 = run_cam(marker_path, moon)
        check("deletion test: second run rc==0 (marker present, no-op)", rc2 == 0)
        check("deletion test: no GET after deletion (marker short-circuits)", moon.get_calls == 0)
        check("deletion test: no POST after deletion (camera not recreated)", moon.post_calls == 0)
        check("deletion test: camera list still empty", len(moon.webcams) == 0)

    with_marker_dir(body)


# --- Test 11: an interrupted/partial marker write never produces a false-complete state ---
def test_interrupted_marker_write_leaves_no_false_complete_state():
    def body(marker_path):
        os.makedirs(os.path.dirname(marker_path), exist_ok=True)
        # Simulate an interruption mid-write: only the .partial file exists,
        # the real marker path does not.
        with open(marker_path + ".partial", "w") as f:
            f.write('{"seeded_at": "x", "result": "cre')  # deliberately truncated
        check(
            "interrupted write: real marker path does not exist",
            not os.path.exists(marker_path),
        )
        check(
            "interrupted write: read_marker() ignores the stray .partial file",
            cam.read_marker(marker_path) is None,
        )
        # A subsequent real run must proceed as if never seeded (not treat
        # the stray .partial as a completed marker).
        moon = FakeMoonraker(webcams=[])
        rc, logs = run_cam(marker_path, moon)
        check("interrupted write: subsequent run creates the camera normally", rc == 0)
        check("interrupted write: real marker now exists and is valid JSON", os.path.exists(marker_path))
        with open(marker_path) as f:
            json.load(f)  # must not raise

    with_marker_dir(body)


# --- Test 12: malformed API response fails safely ---
def test_malformed_api_response():
    def body(marker_path):
        def fetch_garbage(path):
            return "not json at all {{{"

        logs = []
        rc = cam.run(
            fetch=fetch_garbage,
            post=lambda *_a, **_k: (_ for _ in ()).throw(AssertionError("post should never be called")),
            marker_path=marker_path,
            log=logs.append,
            retry_attempts=2,
            retry_delay=0,
            sleep=lambda _s: None,
        )
        check("malformed response: rc==1", rc == 1)
        check("malformed response: no marker written", not os.path.exists(marker_path))
        check(
            "malformed response: logged as unavailable/malformed",
            any("malformed JSON" in line or "never became available" in line for line in logs),
        )

    with_marker_dir(body)


def main():
    test_marker_exists_no_cameras()
    test_marker_exists_camera_exists()
    test_marker_absent_api_unavailable()
    test_marker_absent_no_cameras_creates()
    test_marker_absent_database_camera_exists()
    test_marker_absent_config_camera_exists()
    test_creation_reports_success_but_verification_empty()
    test_creation_wrong_fields()
    test_repeated_invocation_no_duplicate()
    test_user_deletion_not_recreated()
    test_interrupted_marker_write_leaves_no_false_complete_state()
    test_malformed_api_response()

    print()
    print(f"=== {PASS} passed, {FAIL} failed ===")
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
