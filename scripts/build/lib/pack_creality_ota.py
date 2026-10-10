#!/usr/bin/env python3
"""
RosetteOS Firmware Packager for Ender-3 V3 KE and Creality Nebula Pad.

Packages the RosetteOS kernel (xImage) and rootfs (rootfs.squashfs) along with the board-specific
RTOS firmware (zero.bin) into a stock CrealityOS-supported encrypted 7z OTA (.img) update.

CRITICAL REQUIREMENT (from /etc/ota_bin/local_ota_update.sh):
  OTA_UNZIP_FILE_NAME=${OTA_FILE_NAME%.img*}
  ota_site=${OTA_FILE_PATH}/${OTA_UNZIP_FILE_NAME}
  ota_site_config=$ota_site/ota_config.in
The top-level folder inside the 7z archive MUST EXACTLY MATCH the .img filename (minus .img),
and the version must match Creality's dotted versioning (e.g. 1.1.0.34 > 1.1.0.30).
"""

from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Dict, List, Sequence, Tuple

# Fixed hardware partition limits for X2000 Creality display boards
KERNEL_PART_MAX_BYTES = 8 * 1024 * 1024      # 8 MiB (mmcblk0p5 / mmcblk0p6)
ROOTFS_PART_MAX_BYTES = 500 * 1024 * 1024    # 500 MiB (mmcblk0p7 / mmcblk0p8)
RTOS_PART_MAX_BYTES = 4 * 1024 * 1024        # 4 MiB (mmcblk0p3 / mmcblk0p4)

CHUNK_SIZE = 1024 * 1024  # 1 MiB

DEFAULT_VERSION = "1.1.0.34"

# Target profiles
# NOTE: Filenames must follow Creality's native pattern so master-server and local_ota_update.sh
# recognize them and find the extracted ota_config.in.
TARGET_PROFILES: Dict[str, Dict[str, str]] = {
    "ke": {
        "board_name": "F005",
        "output_pattern": "Ender-3_V3_KE_F005_ota_img_V{version}.img",
        "zero_bin": "assets/zero.bin",
        "description": "Creality Ender-3 V3 KE (Target F005)",
    },
    "nebula": {
        "board_name": "NEBULA",
        "output_pattern": "NEBULA_ota_img_V{version}.img",
        "zero_bin": "assets/zero_nebula.bin",
        "description": "Creality Nebula Smart Kit / Nebula Pad (Target NEBULA)",
    },
}


def derive_creality_password(board_name: str, salt: str = "cxswfile") -> str:
    """
    Derives Creality's standard MD5-crypt password for a given board:
      mkpasswd -m md5 "${BOARD_NAME}C3_7e_bz" -S cxswfile
    Implemented in pure Python to eliminate platform dependencies.
    """
    key = f"{board_name}C3_7e_bz"
    magic = "$1$"
    pw = key.encode("utf-8")
    s = salt.encode("utf-8")

    ctx = hashlib.md5(pw + magic.encode("utf-8") + s)
    alt = hashlib.md5(pw + s + pw).digest()

    for i in range(len(pw), 0, -16):
        ctx.update(alt[: min(i, 16)])

    i = len(pw)
    while i > 0:
        if i & 1:
            ctx.update(b"\x00")
        else:
            ctx.update(pw[:1])
        i >>= 1

    digest = ctx.digest()

    for idx in range(1000):
        c = hashlib.md5()
        if idx & 1:
            c.update(pw)
        else:
            c.update(digest)
        if idx % 3:
            c.update(s)
        if idx % 7:
            c.update(pw)
        if idx & 1:
            c.update(digest)
        else:
            c.update(pw)
        digest = c.digest()

    b64 = "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

    def to64(v: int, n: int) -> str:
        ret = []
        for _ in range(n):
            ret.append(b64[v & 0x3F])
            v >>= 6
        return "".join(ret)

    res = magic + salt + "$"
    d = digest
    res += to64((d[0] << 16) | (d[6] << 8) | d[12], 4)
    res += to64((d[1] << 16) | (d[7] << 8) | d[13], 4)
    res += to64((d[2] << 16) | (d[8] << 8) | d[14], 4)
    res += to64((d[3] << 16) | (d[9] << 8) | d[15], 4)
    res += to64((d[4] << 16) | (d[10] << 8) | d[5], 4)
    res += to64(d[11], 2)
    return res


def compute_md5(path: Path) -> str:
    """Compute MD5 digest of a file in 4MB streaming chunks."""
    digest = hashlib.md5()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(4 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def compute_sha256(path: Path) -> str:
    """Compute SHA256 digest of a file in 4MB streaming chunks."""
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(4 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def split_into_chunks(src_path: Path, dest_dir: Path, base_name: str) -> Tuple[str, List[str]]:
    """
    Split payload into 1 MiB chunks per Creality OTA specification:
      <base_name>.<index:04d>.<prev_md5>
    where index 0000 uses the full file MD5 as prev_md5.
    Returns (full_file_md5, list_of_chunk_md5s).
    """
    full_md5 = compute_md5(src_path)
    chunk_md5s: List[str] = []

    with src_path.open("rb") as handle:
        index = 0
        prev_md5 = full_md5
        while True:
            data = handle.read(CHUNK_SIZE)
            if not data:
                break
            chunk_md5 = hashlib.md5(data).hexdigest()
            chunk_name = f"{base_name}.{index:04d}.{prev_md5}"
            chunk_path = dest_dir / chunk_name
            chunk_path.write_bytes(data)
            chunk_md5s.append(chunk_md5)
            prev_md5 = chunk_md5
            index += 1

    return full_md5, chunk_md5s


def verify_manifest(manifest_path: Path, ximage_path: Path, rootfs_path: Path) -> None:
    """Verify xImage and rootfs.squashfs match build-manifest.txt if present."""
    if not manifest_path.exists():
        print(f"[*] Manifest {manifest_path} not found, skipping manifest verification.")
        return

    print(f"[*] Verifying inputs against build manifest: {manifest_path}")
    manifest_data = {}
    for line in manifest_path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if "=" in line and not line.startswith("#"):
            key, val = line.split("=", 1)
            manifest_data[key.strip()] = val.strip()

    expected_ximage_size = manifest_data.get("xImage_size")
    expected_ximage_sha = manifest_data.get("xImage_sha256")
    expected_rootfs_size = manifest_data.get("rootfs_squashfs_size")
    expected_rootfs_sha = manifest_data.get("rootfs_squashfs_sha256")

    if expected_ximage_size and ximage_path.stat().st_size != int(expected_ximage_size):
        raise ValueError(
            f"xImage size mismatch: {ximage_path.stat().st_size} bytes vs expected {expected_ximage_size}"
        )
    if expected_ximage_sha:
        actual_ximage_sha = compute_sha256(ximage_path)
        if actual_ximage_sha != expected_ximage_sha:
            raise ValueError(f"xImage SHA256 mismatch: {actual_ximage_sha} != {expected_ximage_sha}")

    if expected_rootfs_size and rootfs_path.stat().st_size != int(expected_rootfs_size):
        raise ValueError(
            f"rootfs.squashfs size mismatch: {rootfs_path.stat().st_size} bytes vs expected {expected_rootfs_size}"
        )
    if expected_rootfs_sha:
        actual_rootfs_sha = compute_sha256(rootfs_path)
        if actual_rootfs_sha != expected_rootfs_sha:
            raise ValueError(
                f"rootfs.squashfs SHA256 mismatch: {actual_rootfs_sha} != {expected_rootfs_sha}"
            )

    print("  [+] Manifest verification passed: exact size & SHA256 match.")


def pack_archive(staging_root: Path, archive_name: str, output_img: Path, password: str) -> None:
    """Create encrypted 7z archive using 7z CLI (if available) or py7zr."""
    output_img.parent.mkdir(parents=True, exist_ok=True)
    if output_img.exists():
        output_img.unlink()

    has_7z = shutil.which("7z") is not None

    if has_7z:
        print("[*] Compressing encrypted 7z archive using system 7z CLI (multi-threaded)...")
        cmd = [
            "7z", "a",
            "-t7z",
            f"-p{password}",
            "-mhe=on",
            "-mx=4",
            str(output_img),
            archive_name,
        ]
        res = subprocess.run(cmd, cwd=str(staging_root.parent), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        if res.returncode != 0:
            raise RuntimeError(f"7z command failed with code {res.returncode}:\n{res.stdout}")
    else:
        print("[*] System 7z not found. Compressing using Python py7zr (single-threaded)...")
        try:
            import py7zr
        except ImportError:
            raise RuntimeError("Neither 7z CLI nor python 'py7zr' is available. Install p7zip-full or pip install py7zr.")

        with py7zr.SevenZipFile(output_img, mode="w", password=password, header_encryption=True) as zf:
            zf.writeall(staging_root, arcname=archive_name)


def verify_archive(archive_path: Path, password: str) -> None:
    """Verify archive integrity and password decryption."""
    print(f"[*] Verifying archive integrity: {archive_path}")
    has_7z = shutil.which("7z") is not None
    if has_7z:
        cmd = ["7z", "t", f"-p{password}", str(archive_path)]
        res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if res.returncode != 0:
            raise RuntimeError(f"Archive verification failed:\n{res.stderr or res.stdout}")
    else:
        import py7zr
        with py7zr.SevenZipFile(archive_path, mode="r", password=password) as zf:
            if not zf.test():
                raise RuntimeError("Archive validation failed via py7zr.")
    print("  [+] Archive verification passed: 100% valid encrypted 7z envelope.")


def build_rosetteos_ota_image(
    ximage_path: Path,
    rootfs_path: Path,
    zero_path: Path,
    manifest_path: Path | None,
    output_img: Path,
    version: str,
    password: str,
    target_desc: str = "Creality Display",
) -> Path:
    """End-to-end packaging function for RosetteOS OTA .img."""
    print("=" * 65)
    print(f" RosetteOS Firmware Packager: {target_desc}")
    print("=" * 65)

    if not ximage_path.exists():
        raise FileNotFoundError(f"xImage not found: {ximage_path}")
    if not rootfs_path.exists():
        raise FileNotFoundError(f"rootfs.squashfs not found: {rootfs_path}")
    if not zero_path.exists():
        raise FileNotFoundError(f"zero.bin (RTOS firmware) not found at {zero_path}.")

    ximage_size = ximage_path.stat().st_size
    rootfs_size = rootfs_path.stat().st_size
    zero_size = zero_path.stat().st_size

    print("[*] Partition Budget Preflight:")
    ximage_pct = (ximage_size / KERNEL_PART_MAX_BYTES) * 100
    ximage_free = (KERNEL_PART_MAX_BYTES - ximage_size) / (1024 * 1024)
    print(f"  - Kernel: {ximage_size:,} B / {KERNEL_PART_MAX_BYTES:,} B ({ximage_pct:.1f}% used, {ximage_free:.2f} MiB free)")
    if ximage_size > KERNEL_PART_MAX_BYTES:
        raise ValueError(f"xImage ({ximage_size} B) exceeds max partition size ({KERNEL_PART_MAX_BYTES} B)!")

    rootfs_pct = (rootfs_size / ROOTFS_PART_MAX_BYTES) * 100
    rootfs_free = (ROOTFS_PART_MAX_BYTES - rootfs_size) / (1024 * 1024)
    print(f"  - Rootfs: {rootfs_size:,} B / {ROOTFS_PART_MAX_BYTES:,} B ({rootfs_pct:.1f}% used, {rootfs_free:.2f} MiB free)")
    if rootfs_size > ROOTFS_PART_MAX_BYTES:
        raise ValueError(f"rootfs.squashfs ({rootfs_size} B) exceeds max partition size ({ROOTFS_PART_MAX_BYTES} B)!")

    print(f"  - RTOS:   {zero_size:,} B / {RTOS_PART_MAX_BYTES:,} B")
    if zero_size > RTOS_PART_MAX_BYTES:
        raise ValueError(f"zero.bin ({zero_size} B) exceeds max partition size ({RTOS_PART_MAX_BYTES} B)!")

    if manifest_path:
        verify_manifest(manifest_path, ximage_path, rootfs_path)

    # CRITICAL: Creality's local_ota_update.sh expects:
    #   OTA_UNZIP_FILE_NAME=${OTA_FILE_NAME%.img*}
    #   ota_site=${OTA_FILE_PATH}/${OTA_UNZIP_FILE_NAME}
    #   ota_site_config=$ota_site/ota_config.in
    # Therefore the root directory inside the archive MUST exactly equal output_img.stem!
    archive_name = output_img.name
    if archive_name.endswith(".img"):
        archive_name = archive_name[:-4]

    with tempfile.TemporaryDirectory(prefix="rosetteos_ota_stage_") as tmpdir:
        stage_dir = Path(tmpdir)
        staging_root = stage_dir / archive_name
        version_dir = staging_root / f"ota_v{version}"
        version_dir.mkdir(parents=True, exist_ok=True)

        print(f"[*] Packaging archive layout: {archive_name}/ota_v{version}/")
        print("[*] Slicing and chunking payloads (1 MiB slices):")
        print("  - Slicing xImage...")
        ximage_md5, ximage_chunk_md5s = split_into_chunks(ximage_path, version_dir, "xImage")
        print(f"    Total chunks: {len(ximage_chunk_md5s)}, Full MD5: {ximage_md5}")

        print("  - Slicing rootfs.squashfs...")
        rootfs_md5, rootfs_chunk_md5s = split_into_chunks(rootfs_path, version_dir, "rootfs.squashfs")
        print(f"    Total chunks: {len(rootfs_chunk_md5s)}, Full MD5: {rootfs_md5}")

        print("  - Slicing zero.bin...")
        zero_md5, zero_chunk_md5s = split_into_chunks(zero_path, version_dir, "zero.bin")
        print(f"    Total chunks: {len(zero_chunk_md5s)}, Full MD5: {zero_md5}")

        print("[*] Generating Creality OTA manifests and MD5 sidecars...")
        (staging_root / "ota_config.in").write_text(f"current_version={version}\n", encoding="utf-8", newline="\n")
        (version_dir / f"ota_v{version}.ok").write_bytes(b"\n")

        ota_update_lines = [
            f"ota_version={version}",
            "",
            "img_type=kernel",
            "img_name=xImage",
            f"img_size={ximage_size}",
            f"img_md5={ximage_md5}",
            "",
            "img_type=rootfs",
            "img_name=rootfs.squashfs",
            f"img_size={rootfs_size}",
            f"img_md5={rootfs_md5}",
            "",
            "img_type=rtos",
            "img_name=zero.bin",
            f"img_size={zero_size}",
            f"img_md5={zero_md5}",
            "",
        ]
        (version_dir / "ota_update.in").write_text("\n".join(ota_update_lines) + "\n", encoding="utf-8", newline="\n")

        (version_dir / f"ota_md5_xImage.{ximage_md5}").write_text("\n".join(ximage_chunk_md5s) + "\n", encoding="utf-8", newline="\n")
        (version_dir / f"ota_md5_rootfs.squashfs.{rootfs_md5}").write_text("\n".join(rootfs_chunk_md5s) + "\n", encoding="utf-8", newline="\n")
        (version_dir / f"ota_md5_zero.bin.{zero_md5}").write_text("\n".join(zero_chunk_md5s) + "\n", encoding="utf-8", newline="\n")

        pack_archive(staging_root, archive_name, output_img, password)

    verify_archive(output_img, password)

    # Compute SHA256 checksum and write sidecar
    sha256 = compute_sha256(output_img)
    sha_file = output_img.parent / f"{output_img.name}.sha256"
    sha_file.write_text(f"{sha256}  {output_img.name}\n", encoding="utf-8")

    print("=" * 65)
    print(" SUCCESS: RosetteOS OTA Image Created Successfully!")
    print(f" Target Image: {output_img}")
    print(f" Size:         {output_img.stat().st_size:,} bytes ({output_img.stat().st_size / (1024*1024):.2f} MiB)")
    print(f" SHA256:       {sha256}")
    print(f" Package Ver:  {version}")
    print("=" * 65)
    return output_img


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Package RosetteOS build artifacts into stock CrealityOS-compatible USB update (.img) packages."
    )
    parser.add_argument(
        "--target",
        choices=["ke", "nebula", "all"],
        default="ke",
        help="Target hardware profile: 'ke' (Ender-3 V3 KE), 'nebula' (Nebula Pad), or 'all' (build both) (default: ke)",
    )
    parser.add_argument(
        "--artifacts-dir",
        type=Path,
        default=None,
        help="Path to RosetteOS build artifacts directory (contains xImage, rootfs.squashfs, and build-manifest.txt)",
    )
    parser.add_argument("--ximage", type=Path, default=None, help="Explicit path to the RosetteOS xImage")
    parser.add_argument("--rootfs", type=Path, default=None, help="Explicit path to the RosetteOS rootfs.squashfs")
    parser.add_argument("--manifest", type=Path, default=None, help="Explicit path to build-manifest.txt")
    parser.add_argument(
        "--zero-bin",
        type=Path,
        default=None,
        help="Path to RTOS firmware (zero.bin). Defaults to profile asset.",
    )
    parser.add_argument(
        "--version",
        default=DEFAULT_VERSION,
        help=f"Firmware package version recognized by stock updater (default: {DEFAULT_VERSION})",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=None,
        help="Output image path (applicable when packaging a single target)",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=None,
        help="Output directory when generating images (default: artifacts directory or build/)",
    )
    parser.add_argument(
        "--password",
        default=None,
        help="Custom Creality 7z encryption password (defaults to derived per-board key)",
    )
    return parser.parse_args(argv)


def find_repo_root() -> Path:
    for p in Path(__file__).resolve().parents:
        if (p / "manifests" / "dependencies.conf").exists() or (p / ".git").exists():
            return p
    return Path(__file__).resolve().parents[2]


def resolve_zero_bin(repo_root: Path, rel_path: str) -> Path:
    candidates = [
        repo_root / rel_path,
        repo_root / "assets" / Path(rel_path).name,
        repo_root / "scripts" / "build" / rel_path,
        repo_root / "vendor-downloads" / Path(rel_path).name,
        repo_root.parent / "Recovery" / rel_path,
    ]
    for c in candidates:
        if c.is_file() and c.stat().st_size > 0:
            return c
    return repo_root / rel_path


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    repo_root = find_repo_root()

    artifacts_dir = args.artifacts_dir
    default_artifacts = repo_root / "artifacts" / "buildroot-halley5-v30-image"

    if artifacts_dir is None and (args.ximage is None or args.rootfs is None):
        if default_artifacts.exists():
            artifacts_dir = default_artifacts

    ximage = args.ximage
    rootfs = args.rootfs
    manifest = args.manifest

    if artifacts_dir:
        artifacts_dir = artifacts_dir.resolve()
        if ximage is None:
            ximage = artifacts_dir / "xImage"
        if rootfs is None:
            rootfs = artifacts_dir / "rootfs.squashfs"
        if manifest is None and (artifacts_dir / "build-manifest.txt").exists():
            manifest = artifacts_dir / "build-manifest.txt"

    if ximage is None or rootfs is None:
        print("Error: Must provide --artifacts-dir OR both --ximage and --rootfs", file=sys.stderr)
        return 1

    ximage = ximage.resolve()
    rootfs = rootfs.resolve()
    if manifest:
        manifest = manifest.resolve()

    version = args.version
    targets_to_build = ["ke", "nebula"] if args.target == "all" else [args.target]

    if args.output and len(targets_to_build) > 1:
        print("Error: --output cannot be used with --target all (use --output-dir instead).", file=sys.stderr)
        return 1

    out_dir = args.output_dir
    if out_dir is None:
        if artifacts_dir:
            out_dir = artifacts_dir
        else:
            out_dir = repo_root / "build"
    out_dir = out_dir.resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    for tgt in targets_to_build:
        profile = TARGET_PROFILES[tgt]
        board_name = profile["board_name"]
        desc = profile["description"]

        password = args.password
        if password is None:
            password = derive_creality_password(board_name)

        zero_bin = args.zero_bin
        if zero_bin is None:
            zero_bin = resolve_zero_bin(repo_root, profile["zero_bin"])
        zero_bin = zero_bin.resolve()

        output = args.output
        if output is None:
            out_filename = profile["output_pattern"].format(version=version)
            output = out_dir / out_filename
        output = output.resolve()

        try:
            build_rosetteos_ota_image(
                ximage_path=ximage,
                rootfs_path=rootfs,
                zero_path=zero_bin,
                manifest_path=manifest,
                output_img=output,
                version=version,
                password=password,
                target_desc=desc,
            )
        except Exception as exc:
            print(f"\n[!] ERROR ({tgt}): {exc}", file=sys.stderr)
            return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
