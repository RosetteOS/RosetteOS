# WiFi firmware redistribution notice

Two independent sources, both fetched and hash-verified automatically by
`scripts/build/00-fetch-vendor-sources.sh` — neither is committed as a
binary in this repo.

- `brcmfmac43430-sdio.txt` — board-specific NVRAM/calibration data,
  integrated directly into the repository under `scripts/build/overlay/lib/firmware/brcm/`.
- `brcmfmac43430-sdio.bin` / `brcmfmac43430-sdio.clm_blob` — Cypress/
  Broadcom (now Infineon) CYW43430 firmware image + matching CLM blob,
  fetched directly from Infineon's own public upstream repo at build time.

## Board NVRAM (`brcmfmac43430-sdio.txt`)

**Provenance**: extracted read-only from the vendor-installed firmware on a
real, physically-owned Creality Ender-3 V3 KE unit's stock filesystem
(`/lib/firmware/wifi_bcm/nvram_azw372.txt`), then renamed to the filename
mainline Linux's `brcmfmac` driver requests for this exact hardware. See
`docs/NEBULAOS_RELEASE_ARTIFACT_PROVENANCE.md` for the extraction method and
SHA-256 verification against the stock device.

**License status**: no license file, EULA, or copyright header accompanies
this file anywhere on the source device. It is board-calibration data,
functionally identical in kind to the NVRAM every other CYW43430/CYW43438-
equipped device already redistributes as a practical necessity for the
hardware to function at all. **This redistribution is a deliberate,
explicit decision by the repository owner** (recorded 2026-08-07, NebulaOS
Canonical Repository + Baseline mission), not a claim that formal written
permission from Cypress/Broadcom was obtained. Unrelated to which `.bin`/
CLM firmware build is running — this file stays byte-identical regardless
(confirmed unchanged, live, across the 2026-08-09 `.125` promotion below).

**Verification**:

| File | SHA-256 |
|---|---|
| `nebulaos-wifi-firmware-1.0.0.tar.gz` (release archive) | `20c22ee2e3b7469b1240f991457e7217d3b1c8d858595754582e4f097311b08c` |
| `brcmfmac43430-sdio.txt` | `78fee458ab69c0a66ea462f6d6769e15b36f73582693f4dbb5a0e8e8be3cfb0a` |

## Firmware + CLM (`brcmfmac43430-sdio.bin`, `brcmfmac43430-sdio.clm_blob`)

**2026-08-09: promoted to `7.45.98.125` (Infineon build, FWID
`01-f420b81d`)**, replacing the previous `7.46.58.13` control firmware,
after successful hardware qualification — see
`docs/NEBULAOS_WIFI_125_ENGINEERING_TEST.md`'s "Correction" section for the
full live-verification evidence.

**Provenance**: fetched directly from `github.com/Infineon/ifx-linux-
firmware` (Infineon's own public, canonical distribution repo for this
firmware family), tag `release-v5.10.9-2022_0909`, pinned to that tag's own
dereferenced commit `4334275b5801bcf5256c3101395e7bc983ce640d` (not a
moving branch/tag ref) by
`scripts/firmware/fetch-cyw43430-wifi-firmware.sh`. Unlike the NVRAM above,
this is not a redistribution of this project's own extracted copy — it is a
direct build-time fetch from the original publisher's own repo, the same
pattern already used elsewhere in this build for `v4l-utils`/`wireless-
regdb`.

**License status**: covered by a single top-level `LICENCE` file in that
repo — the Cypress Wireless Connectivity Devices Driver End User License
Agreement, which explicitly grants "a non-exclusive, non-transferable
license... to reproduce and distribute the Software in object code form...
solely for use in connection with Cypress integrated circuit products." The
Nebula Pad's real CYW43430 chip squarely qualifies. This is the same
license family already accepted for this build's CLM handling prior to the
promotion (linux-firmware's `LICENCE.cypress`, byte-comparable terms).

**Verification**:

| File | SHA-256 |
|---|---|
| `firmware/cyfmac43430-sdio.bin` | `82ed67a211877efa47aff4aab83d6d2d1ccf3d5d0f5c396df97f292ade01de9e` |
| `firmware/cyfmac43430-sdio.clm_blob` | `1dbe1a396b68786bb189b7c255318ae546fd2e9d15f70ccc8ecbdc52b6cd4c47` |
| `LICENCE` | `3a892759b73e8b459f1a750954b316118b0061fd9d1868d11fa258c104ee7e0c` |

`scripts/firmware/fetch-cyw43430-wifi-firmware.sh` downloads and verifies
all three hashes automatically on every build — a mismatch or download
failure aborts the build immediately, before any expensive step runs.

## History

The previous `7.46.58.13` control firmware (extracted the same way the
NVRAM above still is, from the same physical device) was published as part
of the same `wifi-firmware-1.0.0` release archive. That `.bin` is retired
as of this promotion — the archive itself is unchanged (still the NVRAM's
source), but its `.bin` content is no longer fetched or used by
`00-fetch-vendor-sources.sh`. `scripts/build/fetch-wifi-firmware.sh` (the
live-extraction tool that originally produced it) has been removed along
with it; the extraction method remains documented in
`docs/NEBULAOS_RELEASE_ARTIFACT_PROVENANCE.md` for historical reference.
