# Prompt — Independent Review of Ledger's Xcode Project Setup and Modernization Plan

Replace every `<PLACEHOLDER>` before use. Give this prompt to a current frontier-capability coding
model with read-only shell access to the complete repository. Do not use a plain chat model that
cannot inspect files and run commands — this review is worthless without direct file inspection.

---

You are performing an independent, adversarial review of how a shipping macOS application's Xcode
project is structured, and of a proposed plan to modernize it.

The owner's standard is explicit: **the project should be an exemplary example of how Apple
recommends setting up a modern native Mac app in Xcode today.** Not "acceptable", not "works" —
exemplary. Judge against current Apple guidance and current Xcode conventions, not against what was
normal several years ago.

This is a read-only review. Do not modify any file, do not commit, do not run the release script,
and do not push. You may build and run tests.

## Expected state

- repository: `<ABSOLUTE_LEDGER_REPOSITORY_PATH>`
- sibling packages: `<ABSOLUTE_SHAREDUI_REPOSITORY_PATH>` (and `Librarian`, `Ripcord` alongside)
- branch: `<BRANCH>`
- commit: `<FULL_COMMIT>`
- host: macOS `<MACOS_VERSION>`, Xcode `<XCODE_VERSION>` (`xcode-select -p` → `<TOOLCHAIN_PATH>`)
- build command: `xcodebuild build -workspace <ABSOLUTE_SHAREDUI_REPOSITORY_PATH>/SharedUI.xcworkspace -scheme Ledger -configuration Debug`
- test command: `xcodebuild test -workspace <ABSOLUTE_SHAREDUI_REPOSITORY_PATH>/SharedUI.xcworkspace -scheme Ledger -skip-testing:LedgerUITests`

Note on the test command: `LedgerUITests` is skipped deliberately. It raises an OS automation-consent
dialog, runs no automation, and reports environmental failures unrelated to the code. Treat its
failures as noise. Also note the run emits no `Executed N tests` summary — verify tests actually ran
by counting `^Test case '.*' passed` lines rather than trusting the exit code.

## Start with read-only orientation

```sh
git rev-parse --show-toplevel
git log --oneline -1
git branch --show-current
git status --short
git submodule status
```

## Read these first, completely

1. `docs/xcode-project-modernization-plan-2026-09.md` — the plan under review
2. `Package.swift`, `Config/Base.xcconfig`, `Config/Ledger-Info.plist`, `Config/Ledger.entitlements`
3. `Ledger.xcodeproj/project.pbxproj`
4. `../SharedUI/SharedUI.xcworkspace/contents.xcworkspacedata`
5. `.github/workflows/release.yml` and `scripts/build/`, `scripts/release/`
6. `.git/hooks/pre-commit`

## Your task, in two parts

### Part 1 — Form your own verdict first, before critiquing the plan

Answer the owner's original question independently: **does anything about this project's setup fail
to meet "a clean, simple, native Xcode Mac app as Apple recommends"?** Derive your findings from the
files. Do this before reading the plan's findings closely, so your answer is not anchored by it.

Cover at least:

- Project format and modernity: `objectVersion`, `compatibilityVersion`, and whether targets use
  `PBXFileSystemSynchronizedRootGroup` or hand-enumerated `PBXFileReference` entries.
- Whether the same sources are described by more than one build system, and what that costs.
- Build settings hygiene: xcconfig vs pbxproj-embedded settings; per-target inconsistencies in
  `SWIFT_VERSION`, `MACOSX_DEPLOYMENT_TARGET`, `SWIFT_STRICT_CONCURRENCY`, sandboxing flags.
- Dependency management: local vs remote SPM references, path portability, submodule use.
- Script build phases: correctness, incrementality, declared inputs/outputs, sandboxing.
- Signing, entitlements, hardened runtime, notarization, and where each is actually applied.
- Workspace/project structure and portability to another machine or a fresh clone.
- Anything a fresh clone on a different Mac would fail to build, and why.

Then state plainly: **which of these are genuine deviations from Apple best practice, and which are
defensible deliberate choices?** The app deliberately disables the sandbox, ships outside the Mac
App Store via Sparkle, and is AppKit-first with SwiftUI leaf views. Do not report deliberate product
decisions as defects — but do say so if you think one is wrong.

### Part 2 — Review the plan

Only now assess `docs/xcode-project-modernization-plan-2026-09.md` against your own findings.

1. **Did it miss anything you found?** Highest-value output of this review.
2. **Did it report anything that is not actually a problem**, or overstate a severity?
3. **Is the phasing sound?** Particularly: is it safe to convert to synchronized folders before or
   after deleting `Package.swift`, and are the verification gates sufficient to catch a silent
   change in target membership or resource placement?
4. **Answer the plan's own five open questions** (end of that document), especially whether
   `Package.swift` should be deleted outright or `ExifEditCore` promoted to a local SPM package.
5. **Is the cross-branch strategy right?** The plan proposes re-performing the migration
   independently on each of five branches rather than cherry-picking a pbxproj rewrite. Challenge it.
6. **Are the claimed-safe deletions actually safe?** The plan asserts nothing consumes
   `Package.swift` and that the `pre-commit` hook is redundant with the `Set Build Number` build
   phase. Verify both yourself rather than accepting them.

## Standards of evidence

- **Verify, do not infer.** If you claim a setting has an effect, show the command and output. If
  you claim a file is unused, show the search that establishes it.
- Where you and the plan disagree, say so explicitly and show why.
- Distinguish "violates Apple guidance" from "I would do it differently" and label each.
- Cite specific files and line numbers.
- If a finding is a matter of taste with no authoritative Apple position, say that rather than
  presenting it as a rule.
- A verdict of "the plan is fine" is acceptable **only** if you did the independent pass in Part 1
  first and can name what you checked. Confirming the work looks plausible is not the job; finding
  what is wrong with it is.

## Deliverable

A single markdown report:

1. **Verdict** — one paragraph: is this project exemplary today, and would it be after the plan?
2. **Independent findings** — your Part 1 table, ranked by severity, each with file/line evidence.
3. **Delta against the plan** — what it missed, overstated, or got wrong.
4. **Answers to the five open questions.**
5. **Recommended plan changes** — concrete edits to the phasing, gates, or scope.
6. **Anything you could not verify** and what access you would need.
