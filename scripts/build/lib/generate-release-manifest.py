#!/usr/bin/env python3
"""
Generate a GuppyScreen-compatible releases.json manifest from an SWU package.
"""

import argparse
import hashlib
import json
import os
import subprocess
import sys


def compute_sha256(filepath: str) -> str:
    h = hashlib.sha256()
    with open(filepath, "rb") as f:
        while chunk := f.read(65536):
            h.update(chunk)
    return h.hexdigest()


def get_git_info(repo_root: str):
    try:
        short_sha = subprocess.check_output(
            ["git", "-C", repo_root, "rev-parse", "--short", "HEAD"],
            text=True
        ).strip()
    except Exception:
        short_sha = "unknown"

    try:
        commit_date = subprocess.check_output(
            ["git", "-C", repo_root, "log", "-1", "--format=%cd", "--date=iso-strict"],
            text=True
        ).strip()
    except Exception:
        commit_date = ""

    return short_sha, commit_date


def main():
    parser = argparse.ArgumentParser(description="Generate RosetteOS release manifest")
    parser.add_argument("--swu", required=True, help="Path to SWU package")
    parser.add_argument("--output", required=True, help="Output path for releases.json")
    parser.add_argument("--channel", default="nightly", help="Release channel (nightly/stable)")
    parser.add_argument("--tag", default="nightly", help="Release tag name (e.g. nightly or v1.0.0)")
    parser.add_argument("--repo", default="RosetteOS/RosetteOS", help="GitHub repo (owner/repo)")
    parser.add_argument("--changelog", help="Path to changelog.txt")
    parser.add_argument("--version", help="Explicit version string")

    args = parser.parse_args()

    if not os.path.isfile(args.swu):
        print(f"FATAL: SWU file not found at {args.swu}", file=sys.stderr)
        sys.exit(1)

    repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
    short_sha, commit_date = get_git_info(repo_root)

    swu_sha = compute_sha256(args.swu)
    swu_size = os.path.getsize(args.swu)
    swu_filename = os.path.basename(args.swu)

    version = args.version
    if not version:
        if args.channel == "nightly":
            version = f"nightly-{short_sha}"
        else:
            version = "1.0.0"

    changelog_text = ""
    if args.changelog and os.path.isfile(args.changelog):
        with open(args.changelog, "r", encoding="utf-8") as f:
            changelog_text = f.read().strip()

    download_url = f"https://github.com/{args.repo}/releases/download/{args.tag}/{swu_filename}"

    manifest = {
        "channel": args.channel,
        "releases": [
            {
                "version": version,
                "type": args.channel,
                "filename": swu_filename,
                "url": download_url,
                "sha256": swu_sha,
                "size_bytes": swu_size,
                "release_notes": f"RosetteOS {args.channel.capitalize()} Build ({short_sha}) {commit_date}".strip(),
                "changelog": changelog_text
            }
        ]
    }

    os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2)

    print(f"OK: Wrote release manifest to {args.output} (version {version}, sha256 {swu_sha})")


if __name__ == "__main__":
    main()
