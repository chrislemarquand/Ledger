# Ledger: Xcode, SharedUI, and local release modernization

Date: 2026-09-15  
Status: Developer handoff; implementation has not started under this plan.

This document consolidates the independent Xcode-project review and the subsequent SharedUI/publishing review. It supersedes the recommendations in [the original modernization plan](xcode-project-modernization-plan-2026-09.md), including its incorrect findings and deletion-safety claims.

## 1. Outcome and owner requirements

Make Ledger an exemplary modern native Mac app project, with predictable local development and a reliable, explicit release process.

The owner's release policy is mandatory:

- All application development, builds, tests, signing, notarization, and packaging run locally.
- Release binaries are uploaded to GitHub only through an explicit invocation of the local publishing script.
- Ordinary commits, pushes, tags, and SharedUI edits must not trigger remote application builds or tests.
- GitHub hosts completed release artifacts. If GitHub Pages requires an Action, that Action may deploy an already-generated feed/site payload only. It must not compile, sign, notarize, or regenerate the application or its update artifacts.
- This policy concerns build artifacts and remote execution; it does not prohibit normal source-control pushes.
- The release script must enforce its checks, rather than depend on the owner remembering a checklist.

Preserve these deliberate choices:

- AppKit-first application shell, SwiftUI leaf views, and MainMenu.xib.
- Unsandboxed application, Developer ID distribution, and Sparkle updates outside the Mac App Store.
- Local SharedUI development across Ledger, Librarian, and Ripcord.
- Existing runtime architecture unless a separately identified correctness fix requires a small change.

App sandboxing and build-script sandboxing are different settings. The application decision does not justify disabling build-script sandboxing everywhere.

## 2. Evidence baseline and limits

The independent review examined Ledger branch `v1.4`, commit `5c84b176191d872f6111253a12fca020f3e1280c`, on macOS 27.0 (26A428), Xcode 27.0 (27A266a), with `/Applications/Xcode.app/Contents/Developer` selected.

Observed results:

| Check | Result |
| --- | --- |
| Workspace Debug build | Passed |
| Workspace unit tests, skipping LedgerUITests | 222 distinct `Test case '…' passed` lines; zero failed lines |
| `swift test --parallel --filter BatchRenameServiceTests` | All 31 selected tests completed successfully |
| Workspace Release build | Passed |
| Release `codesign -dvv` | `flags=0x10002(adhoc,runtime)` |
| Release `codesign --verify --deep --strict` | Passed; this does not establish Developer ID/Gatekeeper acceptance |
| Bundled ExifTool | 13.55, copied from local Homebrew |

SharedUI was at `6ca7607b54253c8485d3965fb38628a5c153c043`, on `feature/hierarchical-browsing`, with uncommitted changes. These builds therefore establish behavior of that local working tree, not reproducibility from committed inputs alone.

At handoff-document creation, Ledger also has pre-existing uncommitted app/project changes, including removal of WelcomeCoordinator.swift. Do not overwrite, stash, discard, or incorporate those changes without coordinating their ownership. Refresh inventories and results against the implementation baseline; the counts below are historical evidence, not permanent constants.

No release script, notarization submission, upload, commit, or push was executed during the review. UI automation was deliberately skipped. GitHub repository protection and environment settings were not inspected.

## 3. Findings to address

Source line numbers below refer to the reviewed baseline and may move. File links identify the evidence to inspect.

| Priority | Finding and evidence | Required response |
| --- | --- | --- |
| High | [BatchRenameServiceTests.swift](../Tests/ExifEditCoreTests/BatchRenameServiceTests.swift), 31 tests, is tracked but absent from the Xcode core-test Sources phase (`project.pbxproj`, baseline lines 896–905). | Recover these tests before removing their package owner. |
| High | [release.sh](../scripts/release/release.sh), lines 7, 15, 17, 18, 21, expands executable paths without quotes. The actual repository path contains a space. | Quote executable paths, including inside command substitutions; test paths containing spaces. |
| High | [release.yml](../.github/workflows/release.yml), line 34, clones the moving SharedUI default branch. Local builds use whatever is in `../SharedUI`. | Record and enforce an exact SharedUI revision for releases; remove remote application builds. |
| High | The release workflow does not run unit tests. It creates a public release before uploading assets and uses `--clobber` (baseline lines 132–142). | Local validation must precede publishing; upload a complete draft; prohibit replacing published binaries. |
| High | Each build receives a wall-clock build number; rerunning an old tag can create a numerically newer build of older code. No explicit release-order guard exists. | Freeze release identity at preparation; reject stale candidates and reuse artifacts on retry. |
| Medium | [Bundle ExifTool phase](../Ledger.xcodeproj/project.pbxproj), baseline lines 742–760, declares only Base.xcconfig and the output executable, while [its script](../scripts/build/bundle_exiftool.sh) reads/copies a payload and library tree. | Model actual inputs/outputs and verify incremental behavior. |
| Medium | [set_build_number.sh](../scripts/build/set_build_number.sh) mutates processed Info.plist without declared access. | Make the release build number an explicit input; avoid an undeclared post-processing mutation. |
| Medium | [release.sh](../scripts/release/release.sh) notarizes a ZIP, but never staples the enclosed app and recreates the ZIP. | Staple the app and package the final ZIP before generating its Sparkle signature/feed. |
| Medium | [SharedUI workspace](../../SharedUI/SharedUI.xcworkspace/contents.xcworkspacedata) uses absolute user paths. [SharedUI .gitignore](../../SharedUI/.gitignore), line 6, ignores its workspace resolution file. | Use relative project references and track the resolution file for the canonical workspace. |
| Medium | Root [Package.swift](../Package.swift) independently defines the same core, application, and tests as the Xcode project, with different membership/dependencies. | Establish one owner for each target; retire the duplicate app package. |
| Medium | [Dependency verification](../scripts/deps/verify_shared_ui_pin.sh) verifies a path, not a pin; [sync](../scripts/deps/sync_sharedui_local.sh) and [bump](../scripts/deps/bump_sharedui.sh) only resolve/build the package. | Replace misleading commands with explicit status, preparation, revision-selection, and verification behavior. |
| Medium | [EOS1VSessionController.swift](../Sources/Ledger/EOS1V/EOS1VSessionController.swift), baseline lines 244–268, defaults to a developer checkout and its `.venv/bin/python`. No EOS payload was found in the built app. | Document and validate external provisioning, or address delivery separately. A pinned submodule alone is not an installed runtime. |
| Low | Four native targets enumerate files. Baseline format is objectVersion 71, compatibility Xcode 16.0, upgrade checks 2700. | Adopt synchronized folders where ownership remains with Xcode; no arbitrary format-number bump. |
| Low | Swift/deployment settings are duplicated between xcconfigs and target settings. UI tests have separate Swift 5/macOS 27/team settings. | Consolidate intentional policy and review exceptions without blindly copying template flags. |
| Low | [Ledger-Info.plist](../Config/Ledger-Info.plist), line 30, uses undefined CURRENT_YEAR. Built copyright omits the year. | Supply a deliberate value and verify processed metadata. |
| Low | Local `.git/hooks/pre-commit` rewrites/stages Base.xcconfig using commit count. | Remove this local behavior and document removal for other existing clones. |

### Corrections to the original plan

- Hardened Runtime is already enabled in [Release.xcconfig](../Config/Release.xcconfig), line 4; resolved settings and the built Release signature confirm it. Do not add a redundant remediation task.
- Swift tools version 6.2 and Swift language mode 6.0 are not configuration drift. `.macOS(.v26)` and deployment target 26.0 agree.
- Swift 6 already enables complete concurrency checking; absent SWIFT_STRICT_CONCURRENCY is not a defect. New concurrency defaults are not mandatory project-format cleanup.
- Enumerated groups remain supported by Apple. Their maintenance cost is real, but they are not intrinsically a High-severity violation.
- Production Swift membership matched at the reviewed commit, but test membership did not. The old “perfect sync” claim is insufficient.
- The package is consumed by `scripts/test/run_all.sh`, `scripts/deps/*`, `scripts/release/release_check.sh`, and instructions in `docs/ARCHITECTURE.md` and `docs/RELEASE_CHECKLIST.md`. A no-consumer claim is false.
- The build-number hook and phase have different effects. The phase owns the final app number; the hook modifies source-controlled settings. Hook deletion does not propagate through Git.
- Script arrays existing in pbxproj do not prove their contents are complete.
- Synchronized folders reduce file-addition conflicts; target, setting, dependency, and exception changes can still conflict.

## 4. Target design decisions

### Core code ownership

Recommended implementation: make ExifEditCore a small local Swift package inside the Ledger repository, owning core sources and core tests. Remove the duplicate native core/core-test targets after transferring their dependencies and test coverage. The Xcode project continues to own Ledger and hosted application tests. Preserve module names where practical.

This recommendation uses an existing module boundary; it is not an Apple requirement to package every module. A native static-library target remains an acceptable fallback if package conversion exposes disproportionate integration cost. If choosing that fallback, recover all core tests in Xcode before deleting the root manifest. Record the decision in the implementation PR.

Do not retain two definitions of the same core. Do not retain a second standalone build of the full app. Check `.gitignore`: `/Packages` is currently ignored, so a new package must not accidentally become untracked.

Core currently uses Bundle.main for some behavior, including finding the app-owned ExifTool payload. Preserve that runtime contract; package extraction does not automatically imply moving resources or replacing every Bundle.main with Bundle.module.

### SharedUI development and release contract

Keep `../SharedUI` for the established local workspace. Add a tracked record of the exact SharedUI commit expected for a Ledger release, for example `Config/SharedUI.revision` containing a full commit SHA.

| Mode | Contract |
| --- | --- |
| Development | Local edits and feature branches are allowed. Display actual commit, branch, dirty state, and mismatch with the recorded revision. Do not block normal builds solely on that mismatch. |
| Accept dependency update | Developer deliberately records a new SharedUI commit after local integration checks. No automatic acceptance of whatever happens to be checked out. |
| Prepare clean environment | Provision the recorded revision into an isolated sibling layout, or refuse a mismatched/dirty existing checkout. Never auto-stash, discard changes, switch branches, or pull into someone's active checkout. |
| Release | Require the recorded commit and clean relevant repositories/submodules, including relevant untracked source files. Ignore documented generated outputs. Record exact inputs in the release manifest. |

Changing a shared component requires local build checks for affected consumer apps. Establish a local matrix command for Ledger, Librarian, and Ripcord with recorded compatible revisions. Each app may adopt a SharedUI change at a different time. Use isolated sibling layouts/worktrees for incompatible combinations rather than repeatedly switching one shared checkout beneath active Xcode sessions.

Package resolution does not select the version of a local path dependency. Use accurate command names and messages; no “synced” success based only on path existence.

### UI testing

Keep the real UI tests and repair them separately. Provide a default local unit-test plan/scheme and a distinct opt-in UI plan/scheme. Document automation consent and preference isolation. Do not delete meaningful tests merely because this machine's unattended run is blocked, and do not make UI-consent repair a prerequisite for folder migration.

## 5. Implementation phases and gates

### Phase 0 — Establish the implementation baseline

1. Coordinate existing uncommitted work; select the actual branch/revisions to change.
2. Record Ledger, SharedUI, and relevant submodule revisions and toolchain versions.
3. Parse the project as a plist and resolve full paths through groups, source phases, resources, target associations, and synchronized-folder exceptions. Do not use basename presence as proof of membership.
4. Compare every target's intended files with disk, including tests and non-Swift content.
5. Capture discovered test identities and actual built resource paths for both app and test bundles.

Historical commands, run from Ledger:

```sh
xcodebuild build -workspace "../SharedUI/SharedUI.xcworkspace" -scheme Ledger -configuration Debug
xcodebuild test -workspace "../SharedUI/SharedUI.xcworkspace" -scheme Ledger -skip-testing:LedgerUITests
xcodebuild build -workspace "../SharedUI/SharedUI.xcworkspace" -scheme Ledger -configuration Release
```

Gate: explain every difference from the reviewed baseline. Recover the 31 batch-rename cases explicitly. At the reviewed commit, expected complete unit coverage is 253 cases (222 existing + 31 recovered), not 222 forever. Preserve identities and explain additions/removals if intervening work changes the suite. A successful exit with zero discovered tests must fail validation.

### Phase 1 — Make local dependencies and workspace predictable

1. Introduce the SharedUI revision contract and local verification/preparation commands.
2. Convert workspace references to relative paths and document which sibling repositories are required for the workspace versus Ledger's standalone project.
3. Track the canonical workspace's Package.resolved; preserve Ledger's project-local Package.resolved. Check that project and workspace resolve compatible versions.
4. Document deterministic ExifTool 13.55 provisioning, or the subsequently chosen required version. Verify downloaded payloads against recorded checksums; release builds must not silently select arbitrary Homebrew installations.
5. Document optional EOS-1V Python/submodule setup and how to configure a non-default path. Decide whether that feature is supported in the release being prepared.

Gate: an isolated checkout at a different location, including a path with spaces, builds with documented inputs and without relying on the original user's home-directory contents. Verify dirty/mismatched SharedUI is reported clearly and release validation rejects it without modifying it.

### Phase 2 — Consolidate build and test ownership

1. Implement the core-package decision and restore complete test coverage.
2. Retire the duplicate app manifest and obsolete root Package.resolved when no longer applicable.
3. Migrate consumers in `scripts/deps/*`, `scripts/test/run_all.sh`, `scripts/release/release_check.sh`, and active architecture/release documentation in the same change.
4. Ensure package core tests participate in the canonical local release-validation command, even if they use a separate test invocation.
5. Ensure hosted app tests link/import the package product correctly and the app embeds resources/frameworks as before.

Gate: no obsolete executable-package consumer remains; all intended unit tests execute once in the combined validation accounting. If the native-core fallback is used, all core tests run through Xcode instead.

### Phase 3 — Modernize Xcode representation and settings

1. Convert remaining Xcode-owned source/test directories to synchronized folders, with explicit review of exclusions and resources. Do not synchronize the entire repository into an app target.
2. Do not convert native core targets only to delete them in package extraction; Phase 2 selects ownership first.
3. Consolidate duplicated Swift/deployment settings and document intentional target exceptions. Preserve working Release Hardened Runtime and signing settings.
4. Remove the local build-number pre-commit hook; document the action for existing clones. Do not create a throwaway commit just to test hook removal.
5. Fix CURRENT_YEAR and keep app metadata intentional.
6. Separate default unit tests from opt-in UI automation.

Gate: compare actual compiler input identities and built resources before/after. Expected historical app resources include `MainMenu.nib`, `Assets.car`, `AppIcon.icns`, `WhatsNewKit_WhatsNewKit.bundle`, and the ExifTool executable/library tree. The three EOS decoder fixtures were flat files in the test bundle's Resources directory. Preserve those paths or explicitly document/test intended changes. Exclude incidental `.DS_Store` and developer files.

Normalize expected differences such as build numbers, signatures, and compiler-generated metadata; do not demand byte-identical signed apps. Inspect test resources independently: EOS1VFrameDecoderTests currently reads fixtures via `#filePath`, so green tests do not prove those fixtures were bundled. Prefer a targeted bundle-resource check or repair that lookup in a separately reviewable change.

Run local Debug/Release builds and unit tests, then launch/menu/icon/image smoke checks. No format-number change is required merely to enable synchronized folders in the reviewed project.

### Phase 4 — Correct build scripts and release identity

1. Quote all executable and filesystem paths, including nested command substitutions and paths traversed in loops.
2. Make ExifTool's input payload explicit. Declare the script and required payload files plus generated outputs using suitable file lists or a build rule. Account for library additions/removals, not just the top-level executable.
3. Enable user-script sandboxing where possible; narrowly document any remaining exception. Do not introduce competing producers of processed Info.plist by simply listing it as another output.
4. Choose a valid monotonically increasing release build number once per candidate and supply it as a build input. Eliminate unconditional post-processing that overrides that release input. Normal local builds may use a stable development value; do not edit tracked metadata on every build or commit.
5. Freeze marketing version, build number, revisions, and toolchain in a local candidate manifest. Validate release order against the published feed. Account for already-shipped timestamp build numbers: do not replace them with a smaller counter that Sparkle would consider older.

Gate: first build, no-change rebuild, script edit, payload edit, added/removed library, and deleted output all behave correctly. Verify no unintended source-tree writes. Read the actual built Info.plist/signature rather than trusting only build settings. Retrying candidate preparation must not silently mint a different identity.

### Phase 5 — Replace remote builds with a local prepare/publish pipeline

The public entry point remains a local release script. It may offer preparation-only and resume modes, but the explicit publish invocation must perform or verify all prerequisites. Do not require a second ritual of manual checks that the script could enforce.

Required sequence:

1. **Preflight:** validate clean inputs, exact SharedUI revision, version/tag-to-commit relationship, dependencies, credentials, and absence of an already-published version. Acquire a local release lock.
2. **Validate locally:** run the canonical unit tests and relevant build checks. Fail on missing expected tests. Keep environment-specific UI automation in its separate opt-in gate.
3. **Build locally:** create the Release archive using the frozen candidate identity, deterministic dependency inputs, and Developer ID signing. Retain dSYM.
4. **Verify signatures:** inspect the app and nested executable signatures, actual entitlements, Hardened Runtime, and required timestamps. Preserve any required nested-component entitlements when re-signing; do not assume the app's entitlements fit every helper. Current review did not establish a nested-entitlement failure.
5. **Notarize and staple:** submit a temporary ZIP and require an explicit Accepted result; staple/validate the app; create the final distribution ZIP from that stapled app. Create/sign/notarize/staple/validate the DMG in the appropriate order.
6. **Validate finished artifacts:** verify contents, architectures, metadata, signatures, ExifTool, checksums, and notarization evidence. Smoke-test the installed candidate locally. Separately establish a clean-Mac/offline Gatekeeper acceptance procedure.
7. **Generate update metadata:** run Sparkle tooling against final immutable artifacts. Check version, build number, minimum OS, public key/signature, download URL, length, and checksum. Preserve any older feed entries needed by still-supported OS versions; do not silently replace them with only an incompatible newest release. Versioned artifact paths must not be reused for different bytes.
8. **Stage GitHub release:** create/reuse a draft tied to the exact release commit, upload all artifacts and notes, and verify remote content. Missing release notes are an error for publication, not a substitute public note saying they were not found.
9. **Publish:** make the complete draft public, verify downloadable assets, and publish the Sparkle feed last. Validate the served feed and its URLs after deployment.
10. **Record:** preserve the candidate manifest, artifact hashes, test results, toolchain/dependency versions, dSYM, and notarization submission IDs/results. Keep sensitive logs/credentials local; upload only appropriate release evidence.

Do not rebuild between preparation and publication. On retry, verify and reuse the same artifacts and identity. Never use `--clobber` to replace an already-public version with different bytes. Matching existing artifacts may be treated as completed work after verifying their hashes.

Prevent simultaneous publication and stale feed replacement. A local lock only covers one Mac; recheck remote state immediately before publishing, and serialize any Pages deployment. A failed feed deployment should be resumable using the already-published artifacts. Do not automatically delete or rewrite a successful public release as rollback. Document withdrawing a bad feed entry and issuing a corrected, newer build instead.

Retire `.github/workflows/release.yml`'s application build/sign/notarize jobs and tag-triggered publication. Remove obsolete remote signing/notarization secrets once the local path is verified and no remaining consumer needs them. Keep credentials in the local Keychain or appropriately scoped local process inputs; never write them into candidate manifests or logs. If an Action remains solely for Pages, scope its token permissions to that deployment and pin its Action dependencies to commit SHAs.

Gate: a normal source push or tag causes no remote build/test/signing work and no automatic binary publication. Explicit local publishing is the only release trigger. Validate failure/resume behavior before the first real publication.

## 6. Local release acceptance scenarios

Use isolated fixtures, mocked command adapters, or a dedicated test destination for failure-path verification. A dry run must be incapable of publishing. Do not use a production release as a test harness.

- Dirty or wrong-revision SharedUI: reject release, leave checkout untouched.
- Missing ExifTool, wrong version, or checksum mismatch: fail before signing/upload.
- Missing test suite, failed test, or zero tests: fail before publication.
- Path containing spaces: preparation and subprocess invocation work.
- Invalid notarization result, failed stapling, or invalid signature: no public release/feed update.
- Existing public version with different bytes: reject; never overwrite.
- Upload failure: release stays draft and is resumable with identical artifacts.
- Old candidate or out-of-order publication attempt: cannot replace newer feed state.
- Release published but feed deployment fails: retry only deployment of verified metadata; no rebuild.
- Served URL/signature/length mismatch: detect and report precisely; do not claim full success.
- Fresh installation/update from an existing supported release: verify actual delivery behavior, including offline ticket discovery for the stapled distribution.

## 7. Cross-branch and cross-repository rollout

At the reviewed commit, v1.4 and feature/hierarchical-browsing had identical pbxproj content; print-support, native-driver, and main differed. Native-driver and main had four native targets rather than five. Reinspect before rollout.

Use a shared migration patch/ancestry for identical projects. Prefer merging that migration into divergent branches and resolving their real differences once. Do not independently regenerate identifiers on every branch by default. A deterministic per-branch transformation is an alternative only when reviewed and demonstrably simpler. Do not claim that migration eliminates every future pbxproj conflict.

Avoid migrating maintenance main solely for visual consistency if it will later receive the migrated development branch. Coordinate branch operations with active Xcode sessions and shared checkouts.

Changes to SharedUI workspace references, resolution tracking, and shared dependency tooling belong in SharedUI's repository and require coordinated commits. Apply consumer-specific changes to Librarian/Ripcord separately; do not silently change their release processes as a side effect of Ledger work.

## 8. Completion checklist for developer handoff

- [ ] Canonical local build/test commands documented and operational.
- [ ] All intended tests accounted for; missing batch-rename tests restored.
- [ ] One build owner per source/test target; obsolete package consumers migrated.
- [ ] Synchronized folder membership and app/test resource placement verified.
- [ ] Workspace portable; applicable resolution files tracked.
- [ ] SharedUI revision contract implemented with non-destructive developer behavior.
- [ ] Deterministic dependency provisioning works on a fresh local checkout.
- [ ] Script dependency tracking, sandboxing exceptions, and version inputs validated.
- [ ] Local hook cleanup and metadata fixes documented/completed as applicable.
- [ ] Local release script prepares and publishes the same validated artifacts.
- [ ] Published versions immutable; retries and feed failures safely resumable.
- [ ] No remote application builds/tests/signing and no automatic tag-triggered binary publication.
- [ ] Release evidence and dSYMs retained; credentials excluded.
- [ ] Outstanding UI automation and EOS provisioning limitations have explicit owners and acceptance criteria.

Deliver implementation in bounded changes with concrete validation evidence. This plan does not authorize publishing a real release during implementation; exercise preparation and failure paths locally, and leave any first production publication to an explicit release request.

## 9. Standards and references

Distinguish documented guidance from engineering choices:

- Apple documents benefits of synchronized folders but still supports groups: [Managing files and folders](https://developer.apple.com/documentation/xcode/managing-files-and-folders-in-your-xcode-project).
- Apple supports local packages for modularity; extracting this particular core is a scoped design recommendation: [Organizing code with local packages](https://developer.apple.com/documentation/xcode/organizing-your-code-with-local-packages).
- Apple supports local package development alongside an app: [Developing a package in tandem](https://developer.apple.com/documentation/xcode/developing-a-swift-package-in-tandem-with-an-app).
- Apple recommends tracking applicable package resolution: [Adding package dependencies](https://developer.apple.com/documentation/xcode/adding-package-dependencies-to-your-app).
- Apple explains required script dependency declarations: [Running custom scripts](https://developer.apple.com/documentation/xcode/running-custom-scripts-during-a-build).
- Apple describes script sandboxing and build ordering: [Demystify parallelization in Xcode builds](https://developer.apple.com/videos/play/wwdc2022/110364/).
- Apple recommends stapling items and recreating ZIPs: [Customizing notarization](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).
- Apple documents build version semantics: [CFBundleVersion](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleversion). Do not import obsolete numeric-format claims without checking current documentation.
- Swift 6 enables complete concurrency checking: [Swift migration guide](https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/enabledataracesafety/).
- Sparkle documents publication/update tooling: [Sparkle documentation](https://sparkle-project.org/documentation/).
- GitHub documents deployment concurrency and immutable Action references: [Deployment controls](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/control-deployments), [Secure use](https://docs.github.com/en/actions/reference/security/secure-use).

Local-only execution is the owner's policy. Exact revision records, draft-first publication, immutable artifacts, and the branch rollout strategy are engineering recommendations supporting that policy, not claims that Apple mandates one particular Git workflow.
