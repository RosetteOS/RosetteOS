# Toolchains bundled in the unified build image

## GuppyScreen: Bootlin mips32el-musl (bundled directly)

- **Version:** `mips32el--musl--stable-2024.02-1` (gcc 12.3.0)
- **Source:** https://toolchains.bootlin.com/downloads/releases/toolchains/mips32el/tarballs/mips32el--musl--stable-2024.02-1.tar.bz2
- **SHA256:** `25c0b3217df1bf1a7bae2cc4f56cdeab9fec98b172bbf0b336b2e8fe41d3ee4e`
- **Why bundled directly, not built from source:** this is a pre-built, upstream-published toolchain
  release, the same one `ghcr.io/coreflake1/guppydev` (and `RosetteOS/GuppyScreen/docker/Dockerfile`)
  already use — Migration A's entire premise is preserving this exact toolchain unchanged, so it's
  copied in identically rather than re-derived.
- **Extracted to:** `/toolchains/mips32el--musl--stable-2024.02-1/`, put on `PATH` directly by the
  Dockerfile's own `ENV PATH=...` line — no wrapper script, no `CROSS_COMPILE` env var needed
  (`scripts/build-mips.sh` in `RosetteOS/GuppyScreen` already defaults `CROSS_COMPILE` to
  `mipsel-linux-` itself, matching this toolchain's own binary prefix).

## Kernel / rootfs / native apps: Buildroot's own self-bootstrapped toolchain (NOT bundled)

`mipsel-buildroot-linux-gnu-*` — built from source during
`scripts/build/03-build-kernel-and-rootfs.sh`, from the `buildroot/` subtree of the moving OKE
System checkout (`vendor/system/buildroot`). The fetched System commit is recorded in
`build-manifest.txt`. This image does not bundle it and never will — the build keeps the toolchain
traceable to that System checkout. The image only supplies the host compiler (system gcc/g++)
Buildroot itself needs to build its target toolchain.

## What pellcorp/k1-bash-build bundled that this image deliberately does NOT reproduce

Audited (Phase 11, Task 2): pellcorp's image also bundled an Ingenic `mips-gcc720-glibc229` toolchain
at `/opt/toolchains/`. Grepped every `scripts/build/*.sh` for any direct invocation of it
(`mips-linux-gnu-*`, `/opt/toolchains/mips-gcc720*`) — found none. Every kernel/rootfs/native-app
compile already goes through either Buildroot's own toolchain (above) or explicit
`PATH=.../buildroot-output/host/bin:$PATH` overrides. This toolchain was present in pellcorp's image
but never load-bearing for this project's own build — not reproduced here.
