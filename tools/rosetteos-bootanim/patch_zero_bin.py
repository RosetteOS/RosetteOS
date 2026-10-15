#!/usr/bin/env python3
"""
Patch zero.bin and zero_nebula.bin with the RosetteOS custom bootloader logo (standard 0 deg landscape).
"""

import sys
import struct
import hashlib
from pathlib import Path

def patch_zero_ke(bin_path: Path, jpeg_path: Path):
    with open(jpeg_path, "rb") as f:
        jpeg_bytes = f.read()
    new_len = len(jpeg_bytes)

    data_off = 0x5e50c
    slot_end = 0x60fa0
    table_entry_off = 0x64fd0
    max_len = slot_end - data_off
    assert new_len <= max_len, f"JPEG too large for KE: {new_len} > {max_len}"

    with open(bin_path, "r+b") as f:
        # 1. Write JPEG bytes
        f.seek(data_off)
        f.write(jpeg_bytes)
        # 2. Pad remainder with zeros
        f.write(b"\x00" * (slot_end - (data_off + new_len)))
        # 3. Update size variable at 0x60fa0
        f.seek(slot_end)
        f.write(struct.pack("<I", new_len))
        # 4. Update end pointer in table entry (offset + 8)
        f.seek(table_entry_off + 8)
        new_end_ptr = 0x86000000 + data_off + new_len
        f.write(struct.pack("<I", new_end_ptr))

    # Verify
    with open(bin_path, "rb") as f:
        data = f.read()
    sz = struct.unpack("<I", data[slot_end:slot_end+4])[0]
    fields = struct.unpack("<6I", data[table_entry_off:table_entry_off+24])
    assert sz == new_len
    assert fields[0] == 0x8605e50c
    assert fields[2] == new_end_ptr
    assert data[data_off:data_off+3] == b"\xff\xd8\xff"
    assert data[data_off+new_len-2:data_off+new_len] == b"\xff\xd9"
    sha256 = hashlib.sha256(data).hexdigest()
    print(f"Patched {bin_path} successfully (size={len(data)}, SHA256={sha256})")
    return sha256

def patch_zero_nebula(bin_path: Path, jpeg_path: Path):
    with open(jpeg_path, "rb") as f:
        jpeg_bytes = f.read()
    new_len = len(jpeg_bytes)

    data_off = 0x5c3d0
    slot_end = 0x5ee64
    table_entry_off = 0x62e60
    max_len = slot_end - data_off
    assert new_len <= max_len, f"JPEG too large for Nebula: {new_len} > {max_len}"

    with open(bin_path, "r+b") as f:
        # 1. Write JPEG bytes
        f.seek(data_off)
        f.write(jpeg_bytes)
        # 2. Pad remainder with zeros
        f.write(b"\x00" * (slot_end - (data_off + new_len)))
        # 3. Update size variable at 0x5ee64
        f.seek(slot_end)
        f.write(struct.pack("<I", new_len))
        # 4. Update end pointer in table entry (offset + 8)
        f.seek(table_entry_off + 8)
        new_end_ptr = 0x86000000 + data_off + new_len
        f.write(struct.pack("<I", new_end_ptr))

    # Verify
    with open(bin_path, "rb") as f:
        data = f.read()
    sz = struct.unpack("<I", data[slot_end:slot_end+4])[0]
    fields = struct.unpack("<6I", data[table_entry_off:table_entry_off+24])
    assert sz == new_len
    assert fields[0] == 0x8605c3d0
    assert fields[2] == new_end_ptr
    assert data[data_off:data_off+3] == b"\xff\xd8\xff"
    assert data[data_off+new_len-2:data_off+new_len] == b"\xff\xd9"
    sha256 = hashlib.sha256(data).hexdigest()
    print(f"Patched {bin_path} successfully (size={len(data)}, SHA256={sha256})")
    return sha256

def main():
    repo_root = Path(__file__).resolve().parent.parent.parent
    jpeg_path = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("/tmp/rosetteos_bootlogo.jpg")
    if not jpeg_path.exists():
        print(f"Error: {jpeg_path} not found")
        sys.exit(1)

    # 1. Patch RosetteOS assets
    ke_bin = repo_root / "assets" / "zero.bin"
    nebula_bin = repo_root / "assets" / "zero_nebula.bin"
    ke_sha = patch_zero_ke(ke_bin, jpeg_path)
    nebula_sha = patch_zero_nebula(nebula_bin, jpeg_path)

    # 2. Patch Recovery repo assets if present
    recovery_root = repo_root.parent / "Recovery"
    if recovery_root.exists():
        rec_ke = recovery_root / "assets" / "zero.bin"
        rec_nebula = recovery_root / "assets" / "zero_nebula.bin"
        if rec_ke.exists():
            patch_zero_ke(rec_ke, jpeg_path)
        if rec_nebula.exists():
            patch_zero_nebula(rec_nebula, jpeg_path)

    print("\nNew Hashes for dependencies.conf:")
    print(f"CREALITY_KE_ZERO_BIN_SHA256={ke_sha}")
    print(f"CREALITY_NEBULA_ZERO_BIN_SHA256={nebula_sha}")

if __name__ == "__main__":
    main()
