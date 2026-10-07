# Rosette / RosetteOS Rebrand Plan

## Goal

Make Rosette the project brand and RosetteOS the operating system name across
the firmware and the connected AppStore, GuppyScreen, System, and DarKE
repositories. There has been no release, so the new identity is the only
supported identity; do not add OpenKE compatibility aliases, fallback names, or
migration paths solely to preserve an OpenKE-era identifier.

## Phases

1. **Workspace and branch setup — complete**
   - Rename the local firmware checkout to `RosetteOS/`.
   - Create and check out `rosetteos-rebrand` in each repository being changed.
   - Update workspace guidance to use the new directory name.

2. **Source and runtime identity — complete**
   - Rename current project-owned commands, paths, service names, environment
     variables, package identifiers, build symbols, and device-tree identifiers.
   - Update active source, configuration, app catalog, and user-facing docs.
   - Remove obsolete OpenKE-only compatibility aliases and migration/fallback
     paths where they exist; retain unrelated upstream compatibility behavior.

3. **Cross-repository consistency and validation — in progress**
   - Search active files for stale project-owned OpenKE identifiers and broken
     paths between repositories.
   - Regenerate only artifacts that are outputs of a reproducible build; do not
     edit historical provenance to make it appear to describe a RosetteOS
     build.
   - Run the relevant offline suites and build verification, then document any
     checks that require hardware or external services.

4. **Repository and publication follow-through — pending**
   - Review canonical repository URLs, organization ownership, CI image
     publication, and digest pins before publishing anything.
   - Build and qualify a RosetteOS image before promoting generated artifacts
     or release metadata.

## Current constraints

- Changes are being made on `rosetteos-rebrand` in each touched repository.
- Historical notes and build records may mention OpenKE when they describe the
  actual past; they must remain clearly historical and must not be used as
  current commands, paths, or supported identity.
- All five repositories pass `git diff --check`. Active source searches show
  no OpenKE runtime identifiers; remaining matches are historical records,
  generated build outputs, or this plan's scope statement.
- The AppStore VNC and OctoApp packages and catalog were regenerated so their
  current archives, paths, and checksums match the RosetteOS metadata.
- Tests, firmware builds, and hardware checks have not been run.
- Do not claim build or hardware validation until it has been run.
