# Xcode Project Modernization Plan — 2026-09-15

Audit of how `Ledger.xcodeproj` and its surrounding build tooling are set up, against the stated
goal: **an exemplary, clean, simple, native Mac app project as Apple recommends structuring one
today (Xcode 27, macOS 26/27 era)**. Audit plus staged remediation proposal — no build files have
been changed yet.

Companion review prompt: `docs/xcode-project-modernization-review-prompt-2026-09.md`.

## Verdict up front

The *app* is not the problem. The rendering and interaction core is disciplined AppKit (see
`docs/v1.4-architecture-plan-2026-08.md`'s Pass 1 verdict, not re-litigated here), signing and
notarization are correct, and several things people commonly get wrong here are already right.

What is wrong is **the project's description of itself**: the same source files are declared twice,
by hand, in two competing build systems, and four of the five targets enumerate every file
individually in `project.pbxproj` when the project format already supports not doing that. Every
piece of friction in this area — "a new file is invisible to Xcode until the pbxproj is edited", "a
green `swift build` proves nothing" — is downstream of that one decision.

This is a **bounded, mechanical cleanup**, not a rewrite. Nothing in it changes a line of app code.

## How this was audited

Reproducible, read-only; a reviewer should re-run these rather than trust the findings:

```sh
# Project format and modernity
grep -m3 -E "objectVersion|compatibilityVersion|LastUpgradeCheck" Ledger.xcodeproj/project.pbxproj
grep -c "PBXFileSystemSynchronizedRootGroup" Ledger.xcodeproj/project.pbxproj
grep -c 'isa = PBXFileReference' Ledger.xcodeproj/project.pbxproj

# Which targets are synchronized vs hand-enumerated
python3 - <<'PY'
import re, pathlib
t = pathlib.Path("Ledger.xcodeproj/project.pbxproj").read_text()
for m in re.finditer(r'isa = PBXNativeTarget;(.*?)\n\t\t\};', t, re.S):
    blk = m.group(1)
    name = re.search(r'name = "?([^";\n]+)"?;', blk)
    print(name.group(1), 'synchronized=', 'fileSystemSynchronizedGroups' in blk)
PY

# Is the SPM manifest load-bearing?
grep -nE "swift build|swift test|xcodebuild" .github/workflows/release.yml
grep -rn "Ledger" ../SharedUI/Package.swift ../Librarian/Package.swift ../Ripcord/Package.swift

# Drift between disk and project
for f in $(find Sources/Ledger -name "*.swift" -exec basename {} \;); do
  grep -q "$f" Ledger.xcodeproj/project.pbxproj || echo "NOT IN PROJECT: $f"
done
```

## Findings

| # | Finding | Severity | Evidence |
|---|---------|----------|----------|
| 1 | Two parallel build definitions of the same sources: `Package.swift` and `Ledger.xcodeproj` each declare `ExifEditCore`, the app (`ExifEditMac`, path `Sources/Ledger`), and both unit-test bundles | **High** — root cause of #2's pain | `Package.swift`; 5 `PBXNativeTarget`s |
| 2 | 4 of 5 targets hand-enumerate files: 121 `PBXFileReference` / 113 `PBXBuildFile`. Only `LedgerUITests` uses `PBXFileSystemSynchronizedRootGroup` | **High** | counts above; per-target scan |
| 3 | `SharedUI.xcworkspace` refs are `absolute:/Users/chrislemarquand/...` — unopenable on any other machine, fresh clone, or CI | **Medium** | `SharedUI.xcworkspace/contents.xcworkspacedata` |
| 4 | `.git/hooks/pre-commit` rewrites and stages tracked `Config/Base.xcconfig` on every commit; redundant with the existing `Set Build Number` build phase | **Medium** | hook source; `PBXShellScriptBuildPhase` |
| 5 | `LedgerUITests` diverges on every axis: `SWIFT_VERSION = 5.0` (rest 6.0), `MACOSX_DEPLOYMENT_TARGET = 27.0` (rest 26.0), `ENABLE_USER_SCRIPT_SANDBOXING = YES` (project NO) — and the bundle does not function | **Medium** | per-config scan |
| 6 | Manifest/xcconfig drift: tools `6.2` vs `SWIFT_VERSION = 6.0`; `.macOS(.v26)` vs `MACOSX_DEPLOYMENT_TARGET = 26.0` | **Low** (symptom of #1) | `Package.swift`, `Config/Base.xcconfig` |
| 7 | Hardened runtime applied via `codesign --options runtime` in `scripts/release/archive.sh`, not the `ENABLE_HARDENED_RUNTIME` build setting — an Xcode-driven Archive would not get it | **Low** | `archive.sh:74-95` |

### Already correct — do not "clean up"

Listed explicitly so remediation does not damage them:

- `Config/*.xcconfig` as the settings source of truth, rather than settings buried in the pbxproj.
- `SharedUI` as an `XCLocalSwiftPackageReference` with a **relative** `../SharedUI` path; Sparkle as
  an `XCRemoteSwiftPackageReference`.
- Both script phases are well-formed: `Bundle ExifTool` declares `inputPaths`/`outputPaths` (so it
  is incremental); `Set Build Number` is correctly `alwaysOutOfDate = 1`.
- App sandbox disabled + Developer ID + notarization — correct for a tool that shells out to
  ExifTool and reads user-chosen folders. It does preclude the Mac App Store; that is a deliberate
  distribution choice, not a defect.
- `External/eos1v-serial` as a git submodule.
- AppKit-first shell with SwiftUI leaf islands and a `MainMenu.xib` — a deliberate architecture
  decision, out of scope here.

## Key enabling fact

**Disk and project are currently in perfect sync**: zero `.swift` files exist under
`Sources/Ledger` or `Sources/ExifEditCore` that the pbxproj does not reference. Migrating to
synchronized folders therefore cannot silently pull unexpected files into a target — the highest
risk of that migration is already measured and absent. This will not stay true indefinitely, which
argues for doing the work sooner rather than later.

## Plan

### Phase 1 — Zero-risk hygiene (independent, minutes each)

1. **Delete the `pre-commit` hook.** The `Set Build Number` build phase already writes the build
   number into the built `Info.plist`, which is what `Config/Base.xcconfig`'s own comment claims
   happens. The hook makes that comment false, makes every commit touch the xcconfig, makes build
   numbers branch-dependent (same code, different number per branch), and conflicts on every
   cross-branch cherry-pick.
   *Gate:* commit something; confirm `Base.xcconfig` is untouched and the built app's
   `CFBundleVersion` is still correct.
2. **Make the workspace portable.** Rewrite the three `absolute:` refs as `group:` relative paths.
   *Gate:* open the workspace; build `Ledger`; confirm all three projects resolve.
3. **Resolve `LedgerUITests` (finding #5).** Decide deliberately: repair it or delete it. It
   currently raises an OS automation-consent dialog, runs no automation, and reports environmental
   failures — it is a net-negative signal today. If kept, align `SWIFT_VERSION` and
   `MACOSX_DEPLOYMENT_TARGET` with the rest of the project.
   *Gate:* either the bundle runs unattended, or it is gone and `-skip-testing` is no longer needed.

### Phase 2 — Retire the duplicate build definition (finding #1)

Delete `Package.swift` and `Package.resolved`; `Ledger.xcodeproj` becomes the single definition of
what the app is.

Justification that this is safe, all verified rather than assumed:
- CI invokes only `xcodebuild`; no `swift build`/`swift test` anywhere in `release.yml`.
- No sibling project (`SharedUI`, `Librarian`, `Ripcord`) depends on Ledger's package.
- `SharedUI` reaches the app through the Xcode project's own local package reference, not through
  `Package.swift`, so the dependency survives.
- Project convention already forbids `swift build`/`swift test` for this repo.

*Gate:* clean DerivedData; `xcodebuild build` and `xcodebuild test -skip-testing:LedgerUITests`
green from a fresh clone; no reference to `Package.swift` remains in scripts, CI, or docs.

**Alternative worth the reviewer's opinion:** instead of deleting the manifest, invert the
relationship — promote `ExifEditCore` from an Xcode static-library target to a *local SPM package*
(as `SharedUI` already is), leaving the Xcode project owning only the app target. That is arguably
closer to how Apple structures a modern app with shared code, at the cost of a larger change. This
plan proposes deletion as the simpler default and explicitly asks the reviewer to judge.

### Phase 3 — Synchronized folders (finding #2)

Convert `Ledger`, `ExifEditCore`, `ExifEditCoreTests`, and `ExifEditMacTests` from enumerated file
references to `PBXFileSystemSynchronizedRootGroup`, as `LedgerUITests` already is. The project is
`objectVersion = 71` / `compatibilityVersion = Xcode 16.0`, so the format is already supported — no
project-format upgrade is required.

This deletes ~121 file references and ~113 build files, and permanently removes the "new file needs
a manual pbxproj entry" rule from the project's working practice.

Watch items:
- `MainMenu.xib`, `Assets.xcassets`, and `AppIcon.icon` live inside `Sources/Ledger` and must land
  in the **resources** phase, not sources. Verify the built bundle, not just that it compiles.
- Stray `.DS_Store` files exist under `Sources/Ledger`; confirm they are excluded.
- `Tests/LedgerTests` contains 3 non-Swift files — confirm their role and phase.

*Gate:* built `.app` bundle contents diffed against a pre-migration build — same resources, same
`Info.plist`, same embedded ExifTool; full test suite green; app launches and the menu bar, asset
catalog images, and app icon all still work.

### Phase 4 — Optional consistency polish

- Set `ENABLE_HARDENED_RUNTIME = YES` as a build setting so Xcode Archives match what
  `archive.sh` produces (finding #7). Low value while releases go through the script; cheap.
- Once `Package.swift` is gone, finding #6 resolves by construction.

## Cross-branch sequencing — the one genuinely tricky part

Five active branches carry divergent `project.pbxproj` files:

| Branch | pbxproj vs `v1.4` | `Sources/Ledger` |
|---|---|---|
| `v1.4` | — | 83 swift |
| `feature/hierarchical-browsing` | identical | 83 |
| `feature/print-support` | +32 lines | 91 |
| `feature/eos1v-native-driver` | +116 / −274 | 87 |
| `main` | +89 / −279 | 81 |

A Phase 3 migration rewrites most of that file, so it will conflict with every branch that has
pbxproj changes. Two properties make this tractable:

1. **The conflict problem is self-eliminating.** After migration, adding a file no longer touches
   the pbxproj at all, so the branches stop diverging there permanently. This is a one-time cost
   that removes a recurring one.
2. **Migration is idempotent per branch, so do not cherry-pick it.** Re-perform the conversion
   independently on each branch; each converges on an equivalent, much smaller pbxproj. Cherry-picking
   a rewrite of a file whose content differs per branch is the worst available option.

**Recommended order:** land Phases 1–3 on `v1.4` first (it is the base the v2.0 feature branches
build on), verify, then re-perform on `feature/hierarchical-browsing` (identical pbxproj — trivial),
`feature/print-support`, `feature/eos1v-native-driver`, and `main`. Alternatively, merge outstanding
feature branches first and migrate fewer branches; that is a scheduling decision, not a technical one.

## Risks

| Risk | Mitigation |
|---|---|
| Synchronized folders silently change target membership | Pre-verified zero drift between disk and pbxproj; gate is a built-bundle diff, not a successful compile |
| Resources land in the wrong build phase | Explicit bundle-contents check for `MainMenu.xib`, asset catalog, app icon, embedded ExifTool |
| Deleting `Package.swift` breaks an unknown consumer | Verified: CI, sibling packages, and the SharedUI dependency path all checked; gate is a fresh-clone build |
| pbxproj conflicts across five branches | Re-perform per branch rather than cherry-pick; conflict surface disappears afterwards |
| Build numbers change meaning when the hook is removed | Build phase already owns the real number; verify `CFBundleVersion` in a built app before and after |
| Xcode open during branch work causes stale-DerivedData failures | Project convention: no branch operations with Xcode open; clean DerivedData between phases |

## Explicitly out of scope

AppKit-vs-SwiftUI architecture; the `@Observable` migration and other `v1.4` items; app sandboxing
and Mac App Store eligibility; the Sparkle update mechanism; ExifTool bundling strategy; anything
that changes app behaviour. **This plan should not modify a single line of Swift.**

## Open questions for the reviewer

1. Phase 2: delete `Package.swift`, or invert and promote `ExifEditCore` to a local SPM package?
2. Is there a defensible reason to keep a parallel SPM manifest for an app shipped as a signed,
   notarized `.app` — tooling, indexing, CI, or otherwise — that this audit has missed?
3. `LedgerUITests`: repair or delete?
4. Does anything in the "already correct" list not actually meet current Apple guidance?
5. Is the per-branch re-perform strategy right, or is there a better way to land a pbxproj rewrite
   across five divergent branches?
