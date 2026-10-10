#!/bin/sh
#
# Generates a unified changelog combining RosetteOS system commits
# and GuppyScreen UI commits.
#
# Queries the GitHub API directly for GuppyScreen commits (using GUPPYSCREEN_PIN
# from dependencies.conf), with graceful fallback to local checkouts.
#
# Usage: sh scripts/build/lib/generate-changelog.sh [output-file] [sys-count] [guppy-count]
#

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)

OUTPUT_FILE="${1:-}"
SYS_COUNT="${2:-10}"
GUPPY_COUNT="${3:-10}"

python3 - "$REPO_ROOT" "$SYS_COUNT" "$GUPPY_COUNT" "$OUTPUT_FILE" <<'PYEOF'
import sys
import os
import subprocess
import json
import urllib.request
import re

repo_root = sys.argv[1]
sys_count = int(sys.argv[2])
guppy_count = int(sys.argv[3])
output_file = sys.argv[4] if len(sys.argv) > 4 else ""

lines = []

# 1. RosetteOS System Commits
lines.append("### RosetteOS System")
try:
    # Ensure git safe.directory does not reject checkouts
    subprocess.run(["git", "config", "--global", "--add", "safe.directory", "*"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    sys_log = subprocess.check_output(
        ["git", "-C", repo_root, "log", f"-n{sys_count}", "--pretty=format:• %s"],
        text=True, stderr=subprocess.DEVNULL
    ).strip()
    if sys_log:
        lines.append(sys_log)
    else:
        lines.append("• RosetteOS System Firmware Release")
except Exception:
    lines.append("• RosetteOS System Firmware Release")

lines.append("")

# 2. GuppyScreen UI Commits
manifest_path = os.path.join(repo_root, "manifests", "dependencies.conf")
guppy_repo = "RosetteOS/GuppyScreen"
guppy_pin = ""

if os.path.isfile(manifest_path):
    with open(manifest_path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            if line.startswith("GUPPYSCREEN_REPO="):
                val = line.split("=", 1)[1].strip().strip("\"'")
                m = re.search(r"github\.com[/:]([^/]+/[^/.]+)", val)
                if m:
                    guppy_repo = m.group(1).rstrip(".git")
            elif line.startswith("GUPPYSCREEN_PIN="):
                guppy_pin = line.split("=", 1)[1].strip().strip("\"'")

guppy_commits = []

# Method A: Direct GitHub REST API query
try:
    url = f"https://api.github.com/repos/{guppy_repo}/commits?per_page={guppy_count}"
    if guppy_pin:
        url += f"&sha={guppy_pin}"

    headers = {
        "User-Agent": "RosetteOS-Build",
        "Accept": "application/vnd.github.v3+json"
    }
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"

    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=10) as resp:
        data = json.loads(resp.read().decode("utf-8"))
        if isinstance(data, list):
            for item in data:
                commit_obj = item.get("commit", {})
                msg = commit_obj.get("message", "").split("\n")[0].strip()
                if msg:
                    guppy_commits.append(f"• {msg}")
except Exception:
    pass

# Method B: GitHub CLI (gh) if API request failed
if not guppy_commits:
    try:
        cmd = ["gh", "api", f"repos/{guppy_repo}/commits?per_page={guppy_count}"]
        if guppy_pin:
            cmd = ["gh", "api", f"repos/{guppy_repo}/commits?sha={guppy_pin}&per_page={guppy_count}"]
        output = subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL)
        data = json.loads(output)
        if isinstance(data, list):
            for item in data:
                msg = item.get("commit", {}).get("message", "").split("\n")[0].strip()
                if msg:
                    guppy_commits.append(f"• {msg}")
    except Exception:
        pass

# Method C: Local git checkout fallback (vendor/guppyscreen or ../GuppyScreen)
if not guppy_commits:
    for cand in [os.path.join(repo_root, "vendor", "guppyscreen"), os.path.join(repo_root, "..", "GuppyScreen")]:
        if os.path.isdir(os.path.join(cand, ".git")):
            try:
                g_log = subprocess.check_output(
                    ["git", "-C", cand, "log", f"-n{guppy_count}", "--pretty=format:• %s"],
                    text=True, stderr=subprocess.DEVNULL
                ).strip()
                if g_log:
                    guppy_commits = g_log.split("\n")
                    break
            except Exception:
                pass

if guppy_commits:
    lines.append("### GuppyScreen UI")
    lines.extend(guppy_commits)
    lines.append("")

result_text = "\n".join(lines).strip() + "\n"

if output_file:
    os.makedirs(os.path.dirname(os.path.abspath(output_file)), exist_ok=True)
    with open(output_file, "w", encoding="utf-8") as f:
        f.write(result_text)
else:
    sys.stdout.write(result_text)
PYEOF
