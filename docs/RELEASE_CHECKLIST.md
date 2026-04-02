# Release Checklist

## 1. Preflight

- Confirm branch is up to date with `main`.
- Confirm release target versions are set in source and changelog.

## 2. Quality Gates

Run in order:

```bash
./scripts/deps/verify_shared_ui_pin.sh
xcodebuild -resolvePackageDependencies -project Ledger.xcodeproj -scheme Ledger
./scripts/release/release_check.sh
```

Release checks must pass with no Swift warnings.

For SharedUI updates, use:

```bash
./scripts/deps/bump_sharedui.sh <version>
```

## 2.1 v1.2 Streamlining Gate

- Review and execute applicable items from `docs/v1.2-performance-streamlining-plan.md` before final RC/tag.
- Minimum recommended pre-ship set:
  - ExifTool payload pruning validation
  - Release stripping enabled and verified
  - Inspector preview cache cap/warmup policy verification

Current status (2026-04-03):
- ExifTool Brotli test payload prune: implemented.
- Release strip settings: implemented and verified (smaller Release binary).
- Inspector preview cache/warmup policy: implemented.
- Thumbnail fallback downsample path: implemented.
- Batch rename CPU/latency pass (sort dedupe, formatter caching, debounce): implemented.
- Remaining streamlining gate item: run explicit smoke/perf sanity pass after these runtime changes.

### 2.2 Required Smoke for Streamlining Changes (Phases 1-3)

Run this on the exact RC commit before tag:

- Build/package sanity:
  - [ ] Build local Release app (signed or unsigned path).
  - [ ] Record sizes:
    - [ ] `du -sh <Ledger.app>`
    - [ ] `ls -lh <Ledger.app>/Contents/MacOS/Ledger`
    - [ ] `du -sh <Ledger.app>/Contents/Resources/exiftool`
  - [ ] Confirm stripped Release binary + dSYM coexist.
- ExifTool payload sanity:
  - [ ] Verify pruned path is absent:
    - [ ] `<Ledger.app>/Contents/Resources/exiftool/bin/lib/darwin-thread-multi-2level/IO/Compress/Brotli/tests`
- Runtime functional sanity:
  - [ ] Metadata read on sample folder.
  - [ ] Metadata write/apply and restore.
  - [ ] Import flow and ExifTool CSV export.
- Runtime performance sanity:
  - [ ] Large-folder selection sweep (list + gallery) with inspector visible.
  - [ ] Confirm inspector preview responsiveness under rapid navigation.
  - [ ] Batch Rename fast typing test (preview remains responsive).
  - [ ] Batch Rename edge pass: collision, no-op, extension override, restore.

## 3. Git and Tag

- Commit release metadata updates.
- Create annotated tag (example):

```bash
git tag -a v1.1.1 -m "Ledger v1.1.1"
```

- Push branch and tag.

## 4. Artifacts (Signed/Notarized)

Set env vars:

```bash
export DEVELOPMENT_TEAM="YOUR_TEAM_ID"
export DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (YOUR_TEAM_ID)"
export NOTARY_PROFILE="YOUR_NOTARY_PROFILE"
```

Build notarized artifacts:

```bash
./scripts/release/release.sh
```

## 5. Publish

- Create GitHub release from the pushed tag.
- Attach built artifacts and release notes.
