# Xcode/SharedUI/Release Modernization — Progress Tracker

Companion to `xcode-sharedui-release-modernization-plan-2026-09.md`, which remains the source of
truth for scope, method, and exit-gate wording. This file is the resumable state: what's done,
what's next, and why anything was rejected or deferred. Update it in the same session as the work
it describes — a new session should be able to resume from this file alone, without re-explaining
anything to the user (their explicit preference: don't re-consult except when something breaks).

**Current position:** Plan approved 2026-09-15. Progress tracker created. Phase 0 not yet started.

## Baseline verification (do not repeat)

Confirmed by three independent read-only verification agents on 2026-09-15, against Ledger branch
`v1.4`, commit `5c84b17` (later `c3d2e02` after an unrelated WhatsNewKit removal). Every claim in
the consolidated plan doc checked out true — exact line numbers, quoted content, and behavior all
matched. Do not re-verify these; if a future session finds one of them now false, that's drift
worth flagging, not an error in this record.

- `Tests/ExifEditCoreTests/BatchRenameServiceTests.swift` (31 tests) is tracked in git and genuinely
  absent from the Xcode `ExifEditCoreTests` target's Sources phase.
- 5 `PBXNativeTarget`s on `v1.4`: `LedgerUITests` (synchronized folder), `Ledger`, `ExifEditCore`,
  `ExifEditCoreTests`, `ExifEditMacTests` (all four of the latter hand-enumerate files). `main` and
  `feature/eos1v-native-driver` have only 4 (no `LedgerUITests`). `feature/print-support` and
  `feature/hierarchical-browsing` have 5 but are not byte-identical to v1.4 (additive per-branch
  source entries only).
- Root `Package.swift` duplicates the pbxproj's target definitions (`ExifEditCore` ↔ pbxproj
  `ExifEditCore`; `ExifEditMac`, path `Sources/Ledger` ↔ pbxproj target `Ledger`; both test targets)
  and has real consumers: `scripts/test/run_all.sh` (`exec swift test --parallel`),
  `scripts/deps/{verify_shared_ui_pin,sync_sharedui_local,bump_sharedui}.sh`,
  `scripts/release/release_check.sh` (runs **both** `swift test` and `xcodebuild test` — real
  duplication in the release-validation path itself), `docs/ARCHITECTURE.md`,
  `docs/RELEASE_CHECKLIST.md`.
- `scripts/release/release.sh` lines 7, 15, 17, 18, 21: unquoted `$ROOT_DIR`-prefixed executable
  path expansions, including inside command substitutions — breaks on a path containing a space,
  which the repo's own path (`/Users/chrislemarquand/Xcode Projects/Ledger`) literally has.
- `.github/workflows/release.yml`: zero `xcodebuild test`/`swift test` calls anywhere; clones
  SharedUI from its moving default branch, unpinned (line 34); creates the GitHub release before
  uploading assets and uses `--clobber` (lines 132–142) — a rerun can silently replace already-
  published binaries.
- `scripts/build/bundle_exiftool.sh` copies and prunes an entire ExifTool `lib` directory tree; the
  pbxproj's "Bundle ExifTool" script phase declares only one xcconfig as input and one binary path
  as output — declared I/O doesn't match actual behavior, so the phase isn't reliably incremental.
- `scripts/build/set_build_number.sh` mutates the already-processed Info.plist in place via
  PlistBuddy, with no declared output in its script phase, using wall-clock
  `date -u +%Y%m%d%H%M%S` — a rerun of an old release tag can mint a numerically *newer* build
  number than a real newer release, which Sparkle would then treat as newer.
- `release.sh` notarizes a ZIP (`ditto`'d from the `.app`) but `notarize.sh` explicitly skips
  stapling for `.zip` artifacts — the `.app` inside is never stapled, and the ZIP is never
  recreated afterward. Only the DMG (a separate artifact) gets stapled.
- `Config/Release.xcconfig` line 4 **already** sets `ENABLE_HARDENED_RUNTIME = YES`. The original,
  uncorrected audit wrongly flagged this as missing — do not re-add it or treat it as a finding.
- `Config/Ledger-Info.plist` line 30 uses `$(CURRENT_YEAR)` in the copyright string; no
  `Config/*.xcconfig` defines `CURRENT_YEAR` anywhere — the built copyright is broken/empty.
- `.git/hooks/pre-commit` rewrites `Config/Base.xcconfig`'s `CURRENT_PROJECT_VERSION` to
  `git rev-list --count HEAD + 1` and `git add`s it on every commit. Local only (not tracked in
  git, doesn't propagate to other clones); redundant with the "Set Build Number" script phase,
  which owns the real shipped `CFBundleVersion`. Removing it has no effect on already-shipped
  builds' version numbers.
- `scripts/deps/verify_shared_ui_pin.sh` checks that `Package.swift` uses a local path dependency
  (not a remote pin) and that `../SharedUI` exists with its own `Package.swift` — it prints the
  current SharedUI HEAD SHA as an info log but never compares it against a recorded/expected pin
  and never fails on mismatch. `sync_sharedui_local.sh`/`bump_sharedui.sh` only resolve + `swift
  build`; despite the name, `bump_sharedui.sh` doesn't select or pin any particular revision.
- SharedUI's own `SharedUI.xcworkspace/contents.xcworkspacedata` uses `absolute:` paths for all 3
  sibling project refs (Librarian, Ledger, Ripcord) — unopenable on another machine or fresh clone.
  SharedUI's `.gitignore` line 6 ignores `*.xcworkspace/xcshareddata/swiftpm/Package.resolved`, so
  the canonical workspace-level dependency resolution isn't tracked.
- Root `Ledger/Package.resolved` and the SharedUI-workspace-level `Package.resolved` genuinely
  differ: the workspace-level file additionally pins `grdb.swift` and `sparkle`, entirely absent
  from the root file (where they overlap, on `whatsnewkit`, the pinned version does match).
- `Sources/Ledger/EOS1V/EOS1VSessionController.swift` defaults to a persisted-or-fallback Python
  path resolving to `~/Xcode Projects/Ledger/External/eos1v-serial/.venv/bin/python` — a
  developer-machine-only path. No build script embeds any Python runtime or EOS payload into the
  built app; there is no such embedding step anywhere in `scripts/build/`.
- `docs/ARCHITECTURE.md` and `docs/RELEASE_CHECKLIST.md` are real, existing documents that
  reference `Package.swift`/`swift build`/the dual build-system setup as current, intentional
  architecture — the original (uncorrected) audit's "no consumer" claim about `Package.swift` was
  false; these count as consumers requiring migration in Phase 2.
- Ledger repo was clean at verification time (only the consolidated review doc itself was
  untracked — a prior, unrelated WelcomeCoordinator.swift removal had already been committed
  separately as `c3d2e02`).
- **SharedUI repo has its own, unrelated uncommitted work** on `feature/hierarchical-browsing`: 4
  modified Swift files (`GallerySelectionStyling.swift`, `SharedGalleryCollectionView.swift`,
  `InspectorRatingFlagView.swift`, `SettingsWindowController.swift`) plus `docs/Roadmap.md`, and
  untracked `build/` + a stray `default.profraw`. **Not ours to touch, stash, or discard.**

## Cross-repo convention adopted for this initiative

SharedUI-side changes happen on a **matching `v1.4` branch** cut in the SharedUI repo (not on its
current dirty `feature/hierarchical-browsing`), developed alongside Ledger's `v1.4`, merged into
each repo's `main` together when the initiative completes. General house convention going forward
when work spans Ledger + SharedUI: use identically-named branches in both repos. (Also saved to
persistent memory, not just here.)

**Blocking dependency for Phase 1's SharedUI-side steps only:** the user needs to commit or stash
their `feature/hierarchical-browsing` WIP before a clean `v1.4` branch can be cut in SharedUI. This
does not block Ledger-side Phase 0–4 work, which proceeds independently.

## Hard rules (see plan doc for full rationale)

- Never publish a real release — that stays an explicit, separate request even after every gate is green.
- Never touch real Apple/GitHub credentials beyond checking presence; no live notarization/Sparkle-signing done experimentally.
- Never remove GitHub Actions secrets — flag as a manual checklist item once unreferenced.
- Never switch/stash/discard a dirty working tree, in either repo.
- Never do git branch operations with Xcode open.
- Gate: `xcodebuild build/test -workspace "../SharedUI/SharedUI.xcworkspace" -scheme Ledger -skip-testing:LedgerUITests`; verify by counting `^Test case '.*' passed` lines, never by exit code alone.

## Phase 0 — Baseline

Status: not started.

## Phase 1 — Predictable dependencies and workspace

Status: not started. Ledger-side steps do not wait on SharedUI's WIP; SharedUI-side steps do (see blocking dependency above).

## Phase 2 — Consolidate build/test ownership + retire "ExifEdit" codename

Status: not started. Package-vs-native-fallback decision: not yet made (default per plan doc: extract `ExifEditCore` → `LedgerCore` as a real local package). Rename table is in the plan doc — do not re-derive it, apply it.

## Phase 3 — Modernize Xcode representation

Status: not started. Blocked on Phase 2 completing (converting-then-deleting targets is pointless churn).

## Phase 4 — Build scripts and release identity

Status: not started.

## Phase 5 — Local prepare/publish pipeline

Status: not started. Highest-risk phase — see plan doc's "requires the user directly" list before touching credentials, real notarization, or GitHub secrets.

## Cross-branch rollout

Status: deferred. Which of `main`/`feature/print-support`/`feature/hierarchical-browsing`/`feature/eos1v-native-driver` are still active enough to be worth migrating is an open question for the user, to raise when this phase is actually reached — not decided yet.

## Decision log

(Empty so far — nothing has been rejected or found broken yet. Add entries here in the
`YYYY-MM-DD — <item> — <finding>` shape this project's other progress docs use.)

## Open items requiring the user

- [ ] Commit/stash SharedUI's `feature/hierarchical-browsing` WIP, so a clean `v1.4` branch can be cut there for Phase 1's SharedUI-side steps.
- [ ] (Deferred, not urgent) Confirm which branches are still active for the eventual cross-branch rollout.
- [ ] (Phase 5, not yet reached) Remove now-unused GitHub Actions secrets once `release.yml`'s remote build/sign/notarize jobs are retired.
- [ ] (Phase 5, not yet reached) Be present for the one deliberate real notarization/Sparkle-signing dry run, and for the first real production publish whenever that's separately requested.

## Environment notes (as of this record)

- Ledger: branch `v1.4`, commit `5c84b17` → `c3d2e02` (post WhatsNewKit removal), clean.
- SharedUI: branch `feature/hierarchical-browsing`, commit `6ca7607`, dirty (see above).
- macOS 27.0 (26A428), Xcode 27.0 (27A266a), `xcode-select -p` → `/Applications/Xcode.app/Contents/Developer`.
- Unit test count at last full run: 222 passing (excludes the 31 `BatchRenameServiceTests`, not yet recovered; excludes `LedgerUITests`, deliberately skipped).
