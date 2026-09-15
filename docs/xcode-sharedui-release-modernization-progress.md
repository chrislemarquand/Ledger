# Xcode/SharedUI/Release Modernization — Progress Tracker

Companion to `xcode-sharedui-release-modernization-plan-2026-09.md`, which remains the source of
truth for scope, method, and exit-gate wording. This file is the resumable state: what's done,
what's next, and why anything was rejected or deferred. Update it in the same session as the work
it describes — a new session should be able to resume from this file alone, without re-explaining
anything to the user (their explicit preference: don't re-consult except when something breaks).

**Current position:** Plan approved 2026-09-15. Phases 0–4 complete, all verified (build/test
green throughout, `scripts/release/release_check.sh` passes end-to-end). **Paused here
deliberately, on the user's instruction — Phase 5 (local prepare/publish pipeline) not started.**
It's the highest-risk phase and has real "requires the user" stops (real notarization/Sparkle
signing, GitHub secrets, the first production publish) — pick it up in a later session, resuming
from this file.

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

**Status: complete, 2026-09-15. Zero drift from the recorded baseline.**

- Debug build: `** BUILD SUCCEEDED **` (one benign, unrelated `CoreSimulator is out of date`
  warning from the recent Xcode 27 install — irrelevant to this Mac-only app, not investigated
  further).
- Test run: 222 passed, 0 failed (`^Test case '.*' passed` count). `BatchRenameServiceTests` cases
  confirmed absent from the run — the known gap, not a new failure.
- Release build: `** BUILD SUCCEEDED **`.
- Structural pbxproj parse (via `plutil -convert xml1` → `plistlib`, not grep): confirmed exactly 5
  `PBXNativeTarget`s with the recorded Sources-phase counts — `Ledger` 82, `ExifEditCore` 8,
  `ExifEditCoreTests` 4, `ExifEditMacTests` 6, `LedgerUITests` synchronized (0 manual entries, as
  expected). `LedgerUITests`' `PBXFileSystemSynchronizedRootGroup` path confirmed as `LedgerUITests`.
- Disk-vs-project membership sweep across all four Swift source/test directories: `Sources/Ledger`
  (82/82), `Sources/ExifEditCore` (8/8), and `Tests/LedgerTests` (6/6) are in perfect sync.
  `Tests/ExifEditCoreTests` has 5 files on disk vs. 4 wired into the project —
  `BatchRenameServiceTests.swift` is the sole, confirmed discrepancy. No other drift found anywhere.

**Gate met:** every difference from the reviewed baseline explained (there was exactly one, already
known); test run was non-zero and its count matched exactly.

## Phase 1 — Predictable dependencies and workspace

**Status: in progress, 2026-09-15.**

Done and verified for real (not just written):
- `Config/SharedUI.revision` added (currently empty — see finding below for why).
- `scripts/deps/verify_shared_ui_pin.sh` rewritten: reports branch/HEAD/dirty state and pin
  match/mismatch informationally by default (exit 0); a new `--require-pin-match` flag hard-fails
  on dirty or mismatched state, for Phase 5's release-time use. **Also fixed a pre-existing,
  unrelated bug while in this file:** it called `rg` (ripgrep), which isn't installed on this
  machine at all outside this session's own shell shims — the script has been silently broken
  for the user in an ordinary Terminal. Replaced both calls with portable `grep -E`.
- `scripts/deps/sync_sharedui_local.sh` rewritten to only resolve+build against whatever's
  currently checked out, decoupled from `bump_sharedui.sh` — it no longer touches the pin at all
  (previously it called `bump_sharedui.sh` internally, which — once `bump` became the deliberate
  re-pin command — would have silently re-pinned on every sync, exactly the "automatic acceptance"
  the plan doc says never to do). Verified: ran successfully against the real dirty checkout,
  confirmed `Config/SharedUI.revision` unchanged after.
- `scripts/deps/bump_sharedui.sh` rewritten into the deliberate "record a new accepted revision"
  command: refuses on a dirty SharedUI tree, accepts an optional explicit ref, otherwise pins
  current HEAD. Verified: correctly refused against the real dirty checkout, revision file
  untouched.
- New `scripts/deps/prepare_sharedui_worktree.sh`: provisions the recorded revision into an
  isolated `git worktree`, never touching `../SharedUI`. Verified: created a real isolated
  worktree, confirmed the real `../SharedUI` was untouched (still on its dirty branch).
- `docs/RELEASE_CHECKLIST.md`, `docs/DEPENDENCY_POLICY.md`, `docs/Engineering Baseline.md`
  (Ledger's copy — **Librarian has its own separate copy of this file, not touched, now stale
  relative to this contract; flagged as an open item below, out of scope for this repo's work**)
  updated to describe the new contract and fix a real doc/script mismatch found in passing:
  `RELEASE_CHECKLIST.md` told the user to run `bump_sharedui.sh <version>`, but the script (even
  before this rewrite) explicitly rejected any argument at all — the documented command never
  actually worked.

**Real finding that changes the picture (2026-09-15): Ledger's `v1.4` HEAD cannot currently build
against any committed SharedUI revision — only against SharedUI's uncommitted working tree.**
Discovered by actually testing the Phase 1 gate for real, not by inspection: cloned Ledger into an
isolated space-containing path and built it against a `git worktree` of SharedUI's `main`
(`beb4a5b`, my first choice of initial pin). It failed:
`value of type 'SharedGalleryCollectionView' has no member 'onFirstResponderStatusChanged'`
(`Sources/Ledger/BrowserIconView.swift:165`, `BrowserFilmstripViewController.swift:174` — both
live, unconditional call sites). Traced the symbol: it exists in **zero** commits on either
SharedUI branch (`git show 6ca7607:...` → 0 matches, `git show main:...` → 0 matches) — only in
SharedUI's *live, uncommitted* working-tree edits (3 matches there). So the dependency this build
actually needs has never been committed anywhere in SharedUI. `sync_sharedui_local.sh` succeeding
minutes earlier against the real `../SharedUI` only worked because that dirty working tree happens
to carry the fix — a fresh clone or CI would fail immediately.

Consequence: `Config/SharedUI.revision` is deliberately left **empty** rather than pinned to a
value I know is wrong (`beb4a5b`) or a value that can't be pinned (uncommitted work has no SHA).
Recording a plausible-looking but broken value would be worse than recording nothing — the verify
script already reports "no recorded revision yet" cleanly rather than treating that as an error.

This elevates the existing blocking dependency from a hygiene preference to a hard requirement:
**a clean `v1.4` branch in SharedUI, with the current uncommitted work (which the
`onFirstResponderStatusChanged` fix is part of) actually committed, must exist before
`Config/SharedUI.revision` can hold a real, correct value.** Nothing else in Phase 1 depends on
this — the scripts and worktree tooling above are all verified working — but the pin itself stays
empty until that happens.

**Update, same day: unblocked and completed.** The user confirmed the SharedUI WIP was genuinely
v1.4 work (traced with evidence: Ledger's consuming commit `47e3a83` is an ancestor of `v1.4`; the
SharedUI Roadmap entry is explicitly labeled "v1.4 Phase 4.3, 2026-09-02" — not
`feature/hierarchical-browsing`-specific, just incidentally sitting on that checkout) and asked to
commit it to a matching `v1.4` branch there.

Done: cut SharedUI `v1.4` from `feature/hierarchical-browsing`'s HEAD (`6ca7607`), committed the
real source WIP as `03c3ce6` (`feature/hierarchical-browsing` itself confirmed untouched/clean
afterward), leaving two untracked build byproducts (`build/` — SwiftPM's precompiled-module scratch
dir, not `.build/`; a 0-byte `default.profraw`) uncommitted as expected. Then, since Phase 1's
SharedUI-side blocker was now gone, did that work too in the same pass: gitignored `build/` and
`*.profraw`, removed the `.gitignore` rule that was hiding the canonical workspace's own
`Package.resolved` and tracked the real file (it additionally pins GRDB and Sparkle beyond what
each project's own resolution records), and fixed `SharedUI.xcworkspace/contents.xcworkspacedata`'s
three `absolute:` refs to `group:` (relative). Committed as `76431c0`.

**Verified, not assumed:** `xcodebuild -list` on the fixed workspace resolves all three sibling
projects' schemes correctly; `xcodebuild build -scheme Ledger` succeeds against it. Then ran
Ledger's `bump_sharedui.sh` for real — it reported SharedUI clean at `76431c0` and pinned it.
Finally ran the actual Phase 1 gate end-to-end for real: a disposable Ledger clone at a
space-containing path (`/…/isolated test 2/Ledger`), building against an isolated `git worktree` of
SharedUI at exactly the pinned commit (no dependency on either developer's real checkout) — **`swift
build` succeeded.** All scratch clones/worktrees cleaned up afterward; `git worktree prune` confirms
none remain.

**Phase 1 is now complete.** Not yet done, deferred (not blocking): deterministic ExifTool
provisioning (checksum-pinned download) and EOS-1V dev-path documentation — both were always
lower-priority items within this phase; picking them up in Phase 4 alongside the related build-script
work makes more sense than doing them in isolation now.

## Phase 2 — Consolidate build/test ownership + retire "ExifEdit" codename

**Status: complete, 2026-09-15.** Decision: extracted `ExifEditCore` as a real local package
(`LedgerCore/`) per the plan's default — no need to fall back to keeping it a native target.

**Hard sequencing rule honored and verified, not just followed on paper:** `git mv`'d
`Sources/ExifEditCore` → `LedgerCore/Sources/LedgerCore` and `Tests/ExifEditCoreTests` →
`LedgerCore/Tests/LedgerCoreTests` (the untracked-in-Xcode `BatchRenameServiceTests.swift` moved
along with everything else in that directory — SPM auto-discovers all files, no manual wiring
needed, unlike the old pbxproj). Wrote `LedgerCore/Package.swift`, ran `swift test --parallel`
standalone **before touching the Xcode project at all**: 49 tests, 31 of them
`BatchRenameServiceTests`, 0 failures, exit 0. Only after that passed did anything get deleted.

Codename retirement done in the same pass, per the plan's rename table:
- `ExifEditEngine` → `MetadataEditEngine`, `ExifEditError` → `MetadataEditError` (renamed via
  targeted regex across `LedgerCore/`, `Sources/Ledger/`, `Tests/LedgerTests/` — 44 files touched).
- Root `Package.swift`/`Package.resolved` deleted entirely (not narrowed) — confirmed nothing else
  needed them: `Ledger.xcodeproj` already had its own direct `XCLocalSwiftPackageReference` to
  SharedUI, independent of the root manifest (verified via `plutil`-parsed inspection before
  deleting anything), so nothing about the app build depended on it.
- `Ledger.xcodeproj/project.pbxproj`: removed the `ExifEditCore`/`ExifEditCoreTests` native
  targets and every object referencing them (build phases, build files, file references, target
  dependencies + container item proxies, build configs, group entries — done via a scripted,
  assertion-guarded removal pass, not manual editing) — 5 native targets → 3
  (`Ledger`, `LedgerTests`, `LedgerUITests`). Added `LedgerCore` as a new
  `XCLocalSwiftPackageReference`, wired into both `Ledger` and the renamed `LedgerTests` target.
  Renamed `ExifEditMacTests` → `LedgerTests` (its path was already `Tests/LedgerTests` — this
  fixed an existing name/path mismatch, not created one) and `PRODUCT_MODULE_NAME` from
  `ExifEditMac` → `Ledger` (so `@testable import Ledger` now says what it means). Verified after
  every edit: `plutil -lint` plus a full dangling-reference scan (walk every object, confirm every
  24-hex-char ID resolves) — caught and fixed one real dangling reference
  (`libExifEditCore.a in Frameworks` in the `Ledger` target's own Frameworks phase, missed on the
  first removal pass) before it could reach a build attempt.
- Migrated every real consumer found in Phase 0 verification: `scripts/test/run_all.sh` now runs
  `swift test --parallel` inside `LedgerCore/` (the only SPM-testable thing left) instead of a
  root package that no longer exists; `scripts/deps/verify_shared_ui_pin.sh` redesigned to check
  the Xcode project's own package reference instead of a `Package.swift` that's gone;
  `scripts/release/release_check.sh`'s `Package.swift` existence check repointed at
  `LedgerCore/Package.swift`; `docs/ARCHITECTURE.md` rewritten to describe the new one-owner
  structure; `docs/RELEASE_CHECKLIST.md`/`docs/DEPENDENCY_POLICY.md` already didn't need further
  change here (Phase 1 already updated their `Package.swift`-adjacent content).
- Two more `ExifEdit`-named live values found and fixed, verified safe first: a hardcoded
  `"ExifEdit/Backups"` fallback path in `BackupManager`'s default constructor (confirmed dead in
  production — every real app call site explicitly passes `AppBrand.currentSupportDirectoryURL()`
  instead) and an internal `NotificationCenter` name string (confirmed only ever referenced via
  its Swift constant, never as a raw string, everywhere in the codebase).
- **Deliberately left untouched, and must stay that way:** `AppBrand.legacyDisplayNames =
  ["Logbook", "ExifEditMac"]` in `AppModel.swift` — this is live migration data identifying past
  app names' support directories for real existing users, not a stale codename. Renaming it would
  break migration for anyone who actually used the app under that old name.

**Verified end-to-end, not just per-piece:**
- `xcodebuild build` — succeeded, first attempt after the full pbxproj surgery.
- `xcodebuild test -skip-testing:LedgerUITests` — 204 passed, 0 failed (down from 222, exactly
  the 18 tests that used to be `ExifEditCoreTests` and now live in `LedgerCore`).
- `LedgerCore`'s own `swift test --parallel` — 49 passed, 0 failed.
- **204 + 49 = 253 — exactly the plan's own predicted total (222 existing + 31 recovered).**
- Full sweep for remaining `ExifEdit` in every `.swift`/`.sh`/`.yml`/`.pbxproj`/`.xcconfig`/
  `.plist`/`.xcscheme` file: clean except the one deliberate `legacyDisplayNames` exception above.
- Ran `scripts/release/release_check.sh` — the actual local release-validation pipeline —
  end-to-end for real. Found and fixed one more pre-existing bug while doing so, unrelated to this
  phase's own scope: it never passed `-skip-testing:LedgerUITests`, so it always failed on that
  known-broken bundle regardless of anything else; fixed, then the whole pipeline reported
  "Release checks passed." Also fixed four more latent `rg`-not-installed bugs in that same
  script (same class of bug as Phase 1's `verify_shared_ui_pin.sh` fix) — these safety checks
  (missing-test-bundle detection, new-warning detection, S0/S1 backlog blockers) had likely never
  actually fired on this machine before now.

## Phase 3 — Modernize Xcode representation

**Status: complete, 2026-09-15.** Converted the two remaining hand-enumerated targets to
synchronized folders. All 3 native targets are now synchronized (matching `LedgerUITests`, which
already was) — the "new file needs a manual pbxproj entry" rule this initiative set out to
eliminate is now actually gone, not just reduced.

**Approach found simpler than expected:** rather than creating brand-new group objects and
rewiring parents, the existing `Ledger` `PBXGroup` (already correctly placed, already named
`Ledger`, already `path = Ledger`) was converted **in place** — `isa` changed from `PBXGroup` to
`PBXFileSystemSynchronizedRootGroup`, its ~85 file children replaced with
`explicitFileTypes = {}; explicitFolders = ();` (mirroring `LedgerUITests`'s own working example
exactly). Its parent's `children` list needed no change at all, since the object ID never changed.
`LedgerTests` had no dedicated subgroup (its files sat as flat children of the shared "Tests"
group, alongside the now-removed `ExifEditCoreTests` files) — added one new synchronized root
group there instead.

Removed: all 85 `Ledger`-group file references + build files (Sources: 82, Resources: 3) and the
4 subgroup objects (`Import`, `ImportUI`, `EOS1V`, `EOS1V/Decode` — synchronized groups recurse
into subdirectories automatically, no manual subgroup declarations needed at all); all 9
`LedgerTests` file references + build files (6 source, 3 fixture resources). Cleared both targets'
Sources/Resources build-phase `files` lists to empty, matching the synchronized pattern. Removed
two stray untracked `.DS_Store` files under `Sources/Ledger` first, to eliminate any ambiguity
about what the synchronized group would pick up (confirmed not tracked in git, safe to delete).

**Verified against the actual real risk, not just a successful build** — the plan's own stated
concern was resources landing in the wrong place, so:
- Snapshotted the full built `Ledger.app` bundle's file list (550 files) *before* the conversion,
  rebuilt after, diffed: **zero differences.** Every file in exactly the same place.
- Explicitly confirmed by name: `AppIcon.icns`, `Assets.car`, `MainMenu.nib`, and the ExifTool
  executable are all present in the rebuilt app.
- The plan doc specifically warned that `EOS1VFrameDecoderTests` reads its fixtures via
  `#filePath` (the *source* file's disk location), so a green test there proves nothing about
  whether fixtures were actually bundled correctly — verified this claim directly (grep confirmed
  `#filePath` is really what's used), then checked the **built `LedgerTests.xctest` bundle's
  `Contents/Resources/` directory itself**, independent of the test result: all 3 fixture files
  (`ese1-roll-00-023.csv`, `session-expected.csv`, `session-raw.txt`) genuinely present.
- Full rebuild + test run after: `xcodebuild build` succeeds; `xcodebuild test
  -skip-testing:LedgerUITests` → 204 passed/0 failed, same count as Phase 2 (no regression from
  the structural change); `LedgerCore`'s own suite still 49/0. 204 + 49 = 253, unchanged.

Also done in this phase, per its remaining checklist items:
- Removed the local `.git/hooks/pre-commit` build-number rewriter (documented in Phase 1/2's
  findings as redundant with the build-number script phase). This is local-only and cannot
  propagate via git — **if you have another clone of this repo, delete
  `.git/hooks/pre-commit` there too.**
- Fixed `CURRENT_YEAR`: `Config/Ledger-Info.plist`'s `NSHumanReadableCopyright` used a
  `$(CURRENT_YEAR)` Xcode build-setting token that was never defined anywhere (Xcode has no
  date-substitution mechanism of its own), so the built copyright silently substituted to nothing.
  Fixed via the same script-phase mechanism already trusted for `CFBundleVersion`
  (`set_build_number.sh` now also writes the real current year into the processed Info.plist),
  per the plan's explicit instruction not to add a second undeclared-output phase. Verified
  directly against the real built `Info.plist`: `Copyright © 2026 Chris Le Marquand`.
- **Deliberately NOT touched:** `LedgerUITests`'s diverging settings (`SWIFT_VERSION = 5.0`,
  `MACOSX_DEPLOYMENT_TARGET = 27.0`, explicit `ENABLE_USER_SCRIPT_SANDBOXING = YES`). Normalizing
  these now would be premature — the plan's own open question ("repair or delete?") for this
  target hasn't been answered yet, and aligning settings on a target that might get deleted is
  wasted (or wrong) effort. Revisit once that decision is made.
- Default unit-test gate vs. opt-in UI automation: already the established convention
  (`-skip-testing:LedgerUITests`) — nothing new needed here, just confirmed still correct.

**Note on the plan's own Phase 3 gate wording:** it says to compare against "the historical
resource list" including `WhatsNewKit_WhatsNewKit.bundle` — that bundle **is** still present in
the built `LedgerTests.xctest` (confirmed while checking the fixture files above), inherited
transitively through `SharedUI` (which still depends on WhatsNewKit for Librarian's own welcome
screen — a decision explicitly deferred in this project's own history, not something Phase 3
changed). Ledger's own app code no longer uses WhatsNewKit directly (removed separately, commit
`c3d2e02`), but the resource still ships as a side effect of linking SharedUI at all. Not a defect
introduced here; flagging for awareness only.

## Phase 4 — Build scripts and release identity

**Status: complete, 2026-09-15.**

- **`scripts/release/release.sh`**: quoted all 5 unquoted `$ROOT_DIR`-prefixed executable
  invocations (lines 7, 15, 17, 18, 21 in the reviewed baseline). Verified the bug was real, not
  theoretical, with a standalone reproduction against this repo's own space-containing path:
  unquoted form fails with `No such file or directory` (word-split at the space); quoted form
  correctly executes as one command and reaches the script's own `NOTARY_PROFILE` precondition
  check.
- **Bundle ExifTool script phase**: the declared `inputPaths`/`outputPaths` (one xcconfig in, one
  binary out) never matched what the script actually reads/writes (multiple possible source
  trees, a whole recursively-copied-and-pruned Perl lib directory) — so Xcode's incremental engine
  could silently skip a real payload change. Fixed by marking the phase `alwaysOutOfDate = 1`
  (matching "Set Build Number"'s own existing precedent) and clearing the now-misleading partial
  path declarations, rather than trying to statically enumerate an unenumerable tree. Documented
  the reasoning directly in `bundle_exiftool.sh`.
- **User-script sandboxing**: tested for real, not assumed — flipped `Base.xcconfig`'s
  `ENABLE_USER_SCRIPT_SANDBOXING` to `YES` and rebuilt. **Fails immediately and more
  fundamentally than expected**: the sandbox denies even reading the script file itself
  (`Sandbox: bash deny(1) file-read-data .../scripts/build/bundle_exiftool.sh`) before the script
  gets anywhere near Vendor/Homebrew paths. Xcode's script-phase sandbox only grants read access
  to declared `inputPaths`/`SCRIPT_INPUT_FILE_N` and a fixed ancestor-directory allowlist, not to
  a script file an inline `shellScript` execs by path — so enabling this would need reworking how
  the script is invoked, not just declaring its real inputs/outputs. Reverted, with the real error
  message recorded directly in `Base.xcconfig`'s own comment so this isn't re-attempted blind.
- **`set_build_number.sh`**: now accepts an optional `RELEASE_BUILD_NUMBER` env var, falling back
  to the existing wall-clock value when unset — verified both paths (override resolves correctly;
  a real build with it unset still produces a normal wall-clock `CFBundleVersion`). The actual
  monotonic-vs-published-feed check is **deliberately left for Phase 5**: it needs real feed data
  and a release-candidate context that doesn't exist yet at the plain-script level — building it
  here in isolation would be orphaned code with nothing to wire it into.
- New `scripts/release/write_candidate_manifest.sh`: writes a local, git-ignored
  `build/release-candidate.json` recording marketing version, build number, the Ledger
  commit/branch/dirty-state, the recorded `Config/SharedUI.revision`, and toolchain version — the
  candidate-identity record Phase 5's pipeline will consume. Verified it runs and produces a
  correctly-populated real record against the current repo state.

**Verified end-to-end after all of the above:** `xcodebuild build` succeeds; `xcodebuild test
-skip-testing:LedgerUITests` → 204/0; the full `scripts/release/release_check.sh` pipeline itself
→ "Release checks passed." again.

## Phase 5 — Local prepare/publish pipeline

Status: not started. Highest-risk phase — see plan doc's "requires the user directly" list before touching credentials, real notarization, or GitHub secrets.

## Cross-branch rollout

Status: deferred. Which of `main`/`feature/print-support`/`feature/hierarchical-browsing`/`feature/eos1v-native-driver` are still active enough to be worth migrating is an open question for the user, to raise when this phase is actually reached — not decided yet.

## Decision log

- 2026-09-15 — `Config/SharedUI.revision` initial value — **left empty, not pinned to `beb4a5b`
  (SharedUI `main`) as originally planned** — found by real isolated-build testing that Ledger's
  `v1.4` HEAD needs `onFirstResponderStatusChanged` on `SharedGalleryCollectionView`, which exists
  in no SharedUI commit at all, only in `feature/hierarchical-browsing`'s uncommitted work. See
  Phase 1 section above for full detail.
- 2026-09-15 — found and fixed a pre-existing, unrelated bug in `verify_shared_ui_pin.sh`: it used
  `rg` (ripgrep), not installed on this machine outside the session's own shell shims. Replaced
  with `grep -E`. Not part of the reviewed baseline's findings; caught by actually running the
  script rather than only reading it.
- 2026-09-15 — found a real, pre-existing doc/script mismatch: `docs/RELEASE_CHECKLIST.md`
  documented `bump_sharedui.sh <version>`, which the script always rejected (even before this
  session's rewrite). Fixed the doc to match the script's real (and now redesigned) interface.

## Open items requiring the user

- [x] ~~Commit SharedUI's `feature/hierarchical-browsing` WIP to a matching `v1.4` branch~~ — done
  2026-09-15, see Phase 1 above.
- [ ] Librarian has its own separate copy of `docs/Engineering Baseline.md`, now stale relative to
  the SharedUI revision-pin contract established here. Out of scope for this repo's work — flagging
  for awareness, not fixing.
- [ ] (Deferred, not urgent) Confirm which branches are still active for the eventual cross-branch rollout.
- [ ] (Phase 5, not yet reached) Remove now-unused GitHub Actions secrets once `release.yml`'s remote build/sign/notarize jobs are retired.
- [ ] (Phase 5, not yet reached) Be present for the one deliberate real notarization/Sparkle-signing dry run, and for the first real production publish whenever that's separately requested.

## Environment notes (as of this record)

- Ledger: branch `v1.4`, commit `816cf76` (Phase 0) → Phase 1 → Phase 2 commits on top, clean.
- Unit test count after Phase 3: still 253 total (204 via `xcodebuild test`, 49 via `swift test`
  in `LedgerCore/`) — unchanged from Phase 2, confirming the structural change introduced no
  regression. `LedgerUITests` still deliberately skipped.
- All 3 native targets now use synchronized folders. `.git/hooks/pre-commit` removed locally.
- SharedUI: branch `v1.4` (new, cut from `feature/hierarchical-browsing`'s `6ca7607`), commit
  `76431c0`, clean. `feature/hierarchical-browsing` itself confirmed untouched at `6ca7607`.
- `Config/SharedUI.revision`: `76431c08e2e72f8e689fbbb00e01e219c311e9ec`.
- macOS 27.0 (26A428), Xcode 27.0 (27A266a), `xcode-select -p` → `/Applications/Xcode.app/Contents/Developer`.
- Unit test count at last full run: 222 passing (excludes the 31 `BatchRenameServiceTests`, not yet recovered; excludes `LedgerUITests`, deliberately skipped).
