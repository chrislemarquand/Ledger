# Import / Export Pipeline — Code Review

Reviewed: 2026-03-07
Files: `Sources/Ledger/Import/` + `ImportUI/ImportSheetView.swift`

---

## Severity Key

| Level | Meaning |
|-------|---------|
| 🔴 High | Correctness bug or significant performance/UX regression |
| 🟡 Medium | Real problem, but narrow blast radius or has a workaround |
| 🔵 Low | Code smell, dead code, or minor inconsistency |
| ✅ Fixed | Issue resolved; commit noted inline |

---

## 🔴 HIGH

### H1 · `ImportCoordinator.prepareRun` does synchronous disk I/O on `@MainActor`

**File:** `ImportCoordinator.swift:35–78`

`ImportCoordinator` is `@MainActor`. `prepareRun` calls `adapter.parse(context:)` synchronously; every adapter reads files from disk via `Data(contentsOf:)` (a blocking call). On a slow drive or large CSV this freezes the main thread and the entire UI.

Additionally, `metadataFilesNeeded` for `.referenceFolder` calls `FileManager.contentsOfDirectory` synchronously on the main thread.

```swift
// Current — blocks UI
let metadata = await metadataProvider(Array(metadataFiles))  // ← awaits, fine
let parseResult = try adapter(...).parse(context: context)   // ← synchronous disk read on MainActor
```

**Fix:** Wrap the parse in a detached task or use `await Task.detached { }.value`:

```swift
let parseResult = try await Task.detached(priority: .userInitiated) {
    try adapter(for: options.sourceKind).parse(context: context)
}.value
```

Similarly, `metadataFilesNeeded` should enumerate the folder off-actor before entering the function.

---

### H2 · `GPXTrackParser` corrupts data when `<time>` precedes `<ele>` in a track point

**File:** `GPXImportAdapter.swift:192–237`

`currentTimeText` is shared between the `ele` and `time` elements. When `</ele>` fires it saves the string and clears it; when `</time>` fires it only trims in place. If a GPX file orders the elements as `<time>…</time><ele>…</ele>` (allowed by the GPX 1.1 schema), the sequence is:

1. Time characters accumulate in `currentTimeText` → `"2026-01-01T12:00:00Z"`
2. `</time>` → `currentTimeText` trimmed but **not cleared**
3. Ele characters appended → `"2026-01-01T12:00:00Z35.0"`
4. `</ele>` → `currentEle = Double("2026-01-01T12:00:00Z35.0")` = `nil` (silently dropped), then `currentTimeText = ""`
5. `</trkpt>` → `parseTimestamp("")` = `nil` → **point is silently dropped**

Most real-world GPX files put `ele` before `time`, so this is latent rather than triggered in practice, but it's a correctness bug against the spec.

**Fix:** Use separate `currentEleText` and `currentTimeText` accumulator strings.

---

### ~~H3 · `EOS1VImportAdapter.buildDateTimeOriginal` creates `DateFormatter` instances per row~~ ✅ Fixed — `40088be`

**File:** `EOS1VImportAdapter.swift:227–244`

```swift
for format in Self.inputDateFormats {
    let formatter = DateFormatter()          // ← allocated 4× per row
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = format
    if let date = formatter.date(from: input) { ... }
}
```

`DateFormatter` is expensive to initialise (it loads locale data). With 36 EOS frames × 4 formats = up to 144 formatter allocations per import. This should use static cached formatters.

**Fix:**

```swift
private static let inputDateFormatters: [DateFormatter] = inputDateFormats.map { format in
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = format
    return f
}
```

---

## 🟡 MEDIUM

### M1 · `ExifToolCSVExportService.export` blocks the calling thread

**File:** `ExifToolCSVExportService.swift:27–48`

`export(fileURLs:destinationURL:)` is synchronous and calls `process.waitUntilExit()`. ExifTool takes O(seconds) for a large folder. The function has no `async` designation, so callers must manually ensure it runs off the main thread — easy to get wrong.

**Fix:** Make it `async throws` and use `AsyncStream` or `Task.detached`, or at minimum add a comment that it must not be called on the main actor.

---

### M2 · `EOS1VImportAdapter.inferLens` hardcodes specific lens models

**File:** `EOS1VImportAdapter.swift:417–429`

```swift
private func inferLens(focalLength: String) -> String {
    switch number {
    case 28: return "EF28mm ƒ2.8 IS USM"
    case 40: return "EF40mm ƒ2.8 STM"
    case 50: return "EF50mm ƒ1.8 STM"
    default: return "EF24-105mm ƒ4L IS USM"
    }
}
```

This writes a hardcoded lens model string for every EOS import. A 50mm frame would always get `"EF50mm ƒ1.8 STM"` regardless of the actual lens. Any user with different glass gets wrong metadata silently. The default branch (`EF24-105mm`) fires for any focal length not in the list, including 200mm telephotos.

The EOS 1V CSV does not contain lens information, so this field cannot be inferred reliably. The field should either be omitted or left for the user to fill manually.

---

### M3 · `CSVImportAdapter.parseCoordinateNumber` recompiles regex on every call

**File:** `CSVImportAdapter.swift:317`

```swift
let regex = try? NSRegularExpression(pattern: "-?\\d+(?:\\.\\d+)?")
```

This appears inside an instance method called once per GPS coordinate field per CSV row. `NSRegularExpression` compilation is non-trivial. It should be a `static let`.

The identical pattern also appears in `ReferenceImportSupport.parseCoordinateNumber` — two separate copies of the same logic with the same issue. Shared logic could live in `CSVSupport` or a `CoordinateParser` utility.

---

### ~~M4 · Static `DateFormatter`s use `TimeZone.current` — fragile across timezone changes~~ ✅ Fixed — `40088be`

**Files:** `CSVImportAdapter.swift:341`, `GPXImportAdapter.swift:130`

Both adapters have a `static let exifDateFormatter` with `formatter.timeZone = .current`. The timezone is captured once at first access. If the user changes their system timezone while the app is running (rare but possible, e.g. during travel), the formatter will continue to use the stale timezone. EXIF dates have no embedded UTC offset, so this could cause GPX matching to fail silently.

**Fix:** Use `TimeZone.current` lazily at call time rather than baking it into a static formatter. Or document the limitation.

---

### M5 · `ImportConflictResolver.mergeAssignments` silently last-write-wins on field collision

**File:** `ImportConflictResolver.swift:43–50`

When a target file appears in both `matchResult.matched` and as a resolved conflict, the fields are merged by last-write:

```swift
fieldsByTag[field.tagID] = field.value
```

The insertion order (matched rows first, then conflict resolutions) is deterministic but not obvious to callers. A conflict resolution for a target that was already matched would silently overwrite the matched fields. No warning is produced.

---

## 🔵 LOW

### L1 · `EOS1VImportAdapter.extensionProbeOrder` builds unused candidates array

**File:** `EOS1VImportAdapter.swift:290–291`

```swift
let candidates = Self.extensionProbeOrder.map { "\(rowString)\($0)" }
let fallback = candidates.first ?? "\(rowString).jpg"
```

`candidates` is built (6 strings allocated) but only `candidates.first` is ever used. The array can be eliminated:

```swift
let fallback = "\(rowString)\(Self.extensionProbeOrder[0])"
```

---

### L2 · `buildTagDescriptorIndex` is rebuilt on every `parse()` call

**File:** `CSVImportAdapter.swift:182`

The tag descriptor index is rebuilt from the catalog every time `parse` is called. The catalog doesn't change within a session. Since adapters are `struct`s they can't cache it themselves, but `ImportParseContext` could carry a pre-built index, or the index could be built once in `ImportCoordinator`.

---

### L3 · `CSVSupport.normalizedHeader` applies regex on every call

**File:** `CSVSupport.swift:133`

```swift
.replacingOccurrences(of: "[^a-z0-9]+", with: "", options: .regularExpression)
```

`normalizedHeader` is called in tight loops (once per cell per row during header matching). `replacingOccurrences(of:options:.regularExpression)` re-parses the pattern string each call. A compiled `NSRegularExpression` stored as a `static let`, or a manual character-filter loop, would be faster.

---

### L4 · `ImportMatcher` row-parity ordering is implicit and undocumented

**File:** `ImportMatcher.swift:7`

```swift
let rowOrderedTargets = targetFiles
```

The match for row-parity mode is `targetFiles[rowNumber - 1]`. The ordering of `targetFiles` — alphabetical? modification date? arbitrary? — determines which file gets which CSV row. This ordering comes from `AppModel.importTargetFiles(for:)` and is documented there, but `ImportMatcher` has no assertion or comment about the expected ordering contract. A future refactor that reorders the list could silently mis-assign rows.

---

### L5 · `GPXImportAdapter.nearestPoint` is non-deterministic on equidistant timestamps

**File:** `GPXImportAdapter.swift:118–120`

```swift
points.min(by: { abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date)) })
```

`Array.min(by:)` is not stable. If two GPX points are exactly equidistant from the capture date, the chosen point depends on Swift's sort implementation. In practice two equidistant points means a capture exactly halfway between two track points, which is uncommon. Prefer the earlier point for determinism:

```swift
points.min(by: {
    let d0 = abs($0.timestamp.timeIntervalSince(date))
    let d1 = abs($1.timestamp.timeIntervalSince(date))
    return d0 == d1 ? $0.timestamp < $1.timestamp : d0 < d1
})
```

---

### L6 · `CSVSupport.decodedString` may misidentify CP1252 as UTF-8

**File:** `CSVSupport.swift:85–100`

UTF-8 is tried before CP1252. A CP1252 file whose content happens to be valid UTF-8 (e.g., all bytes < 128, i.e., pure ASCII) will be decoded as UTF-8 — which is correct. But a CP1252 file with characters in the 0x80–0xFF range that are not valid UTF-8 will fail UTF-8, skip to CP1252, and decode correctly. The ordering is therefore safe for well-formed files. The subtle case is a file with bytes that are accidentally valid UTF-8 but semantically wrong (e.g., a CP1252 ™ U+2122 encoded as three UTF-8 bytes). This is an inherent ambiguity in encoding detection without a BOM and is difficult to resolve without heuristics.

---

## Summary Table

| # | File | Issue | Severity |
|---|------|-------|----------|
| ~~H1~~ | ~~`ImportCoordinator`~~ | ~~Sync disk I/O on `@MainActor` blocks UI~~ | ✅ |
| ~~H2~~ | ~~`GPXImportAdapter`~~ | ~~`<time>` before `<ele>` corrupts timestamp~~ | ✅ |
| ~~H3~~ | ~~`EOS1VImportAdapter`~~ | ~~`DateFormatter` allocated per row~~ | ✅ |
| ~~M1~~ | ~~`ExifToolCSVExportService`~~ | ~~Blocking synchronous export~~ | ✅ |
| ~~M2~~ | ~~`EOS1VImportAdapter`~~ | ~~Hardcoded lens inference writes wrong metadata~~ | ✅ |
| ~~M3~~ | ~~`CSVImportAdapter`~~ | ~~Regex recompiled per GPS field~~ | ✅ |
| ~~M4~~ | ~~Both CSV/GPX adapters~~ | ~~Static `DateFormatter` bakes in timezone at launch~~ | ✅ |
| ~~M5~~ | ~~`ImportConflictResolver`~~ | ~~Silent last-write-wins on field collision~~ | ✅ |
| ~~L1~~ | ~~`EOS1VImportAdapter`~~ | ~~Unused `extensionProbeOrder` candidates array~~ | ✅ |
| ~~L2~~ | ~~`CSVImportAdapter`~~ | ~~Tag descriptor index rebuilt per parse~~ | ✅ |
| ~~L3~~ | ~~`CSVSupport`~~ | ~~`normalizedHeader` regex re-parsed every call~~ | ✅ |
| ~~L4~~ | ~~`ImportMatcher`~~ | ~~Row-parity target ordering undocumented~~ | ✅ |
| ~~L5~~ | ~~`GPXImportAdapter`~~ | ~~Non-deterministic nearest-point on ties~~ | ✅ |
| ~~L6~~ | ~~`CSVSupport`~~ | ~~Encoding detection ambiguity (CP1252 vs UTF-8)~~ | ✅ (documented) |

---

## Execution Plan (Dependency-Aware)

This section translates open findings into an implementation sequence with concrete file/test touchpoints.

### PR-A · GPX correctness (`H2` + `L5`)

**Status:** ✅ Completed on 2026-03-07.

**Goal:** Fix GPX parsing correctness before broader pipeline changes.

**Code files**
- `Sources/Ledger/Import/GPXImportAdapter.swift`

**Test files**
- `Tests/LedgerTests/ImportSystemTests.swift`
- Optional: `Tests/LedgerTests/ImportMatrixTests.swift`

**Checklist**
- Split GPX parser accumulators into `currentEleText` and `currentTimeText`.
- Ensure `<time>...</time><ele>...</ele>` ordering parses correctly.
- Make `nearestPoint` deterministic on ties (prefer earlier timestamp).

**Acceptance**
- Valid GPX points are not dropped when `time` precedes `ele`.
- Tie cases yield stable results across runs.

**Completion notes**
- Implemented in `Sources/Ledger/Import/GPXImportAdapter.swift`:
  - deterministic tie-break in `nearestPoint` (earlier timestamp wins),
  - separate GPX parser accumulators for `time` and `ele`.
- Added regression tests in `Tests/LedgerTests/ImportSystemTests.swift`:
  - `testGPXImportAdapterParsesTrackPointWhenTimePrecedesEle`
  - `testGPXImportAdapterPrefersEarlierPointWhenEquidistant`
- Verified via `swift test --filter ImportSystemTests`.

---

### PR-B · Off-main-thread import/export I/O (`H1` + `M1`)

**Status:** ✅ Completed on 2026-03-07.

**Goal:** Remove UI-thread blocking from import preparation and ExifTool export.

**Code files**
- `Sources/Ledger/Import/ImportCoordinator.swift`
- `Sources/Ledger/Import/ExifToolCSVExportService.swift`
- If needed by signature changes: `Sources/Ledger/ImportUI/ImportSheetView.swift`

**Test files**
- `Tests/LedgerTests/ImportSystemTests.swift`
- `Tests/LedgerTests/ImportMatrixTests.swift` (regression run)

**Checklist**
- Move folder enumeration in `metadataFilesNeeded` off main actor.
- Run adapter parse off main actor (for file-backed adapters).
- Convert `ExifToolCSVExportService.export` to `async throws` (or enforce background execution at the API boundary).
- Update call sites to await async behavior and keep UI responsive.

**Acceptance**
- No synchronous disk read path remains on `@MainActor` in `prepareRun`.
- Export path is non-blocking by default from caller perspective.

**Completion notes**
- Implemented in `Sources/Ledger/Import/ImportCoordinator.swift`:
  - metadata file discovery runs in detached work,
  - adapter parsing runs in detached work (off `@MainActor`).
- Implemented in `Sources/Ledger/Import/ExifToolCSVExportService.swift`:
  - `export` is now `async throws`,
  - process execution and file write run via detached work.
- Updated caller in `Sources/Ledger/AppModel.swift` to await async export directly.
- Added regression test:
  - `Tests/LedgerTests/ImportSystemTests.swift` → `testExifToolCSVExportServiceRejectsEmptyInput`.
- Verified via:
  - `swift test --filter ImportSystemTests`
  - `swift test --filter ImportMatrixTests`

**Policy-compatibility note**
- This PR intentionally avoids introducing new EOS-specific metadata policy decisions.
- The off-main parse flow still goes through `ImportParseContext`, which remains the integration seam for future EOS lens policy/settings work in v1.1.

---

### PR-C · Metadata integrity policy (`M2` + `M5`)

**Status:** ✅ Completed on 2026-03-07.

**Goal:** Eliminate silent wrong metadata and define deterministic collision behavior.

**Code files**
- `Sources/Ledger/Import/EOS1VImportAdapter.swift`
- `Sources/Ledger/Import/ImportConflictResolver.swift`
- Possibly `Sources/Ledger/Import/ImportModels.swift` (if diagnostics are expanded)

**Test files**
- `Tests/LedgerTests/ImportSystemTests.swift`

**Checklist**
- Remove/disable hardcoded `inferLens` output when lens is unknown.
- Define merge precedence for field collisions (matched vs resolved conflicts).
- Emit a warning/diagnostic on overwrite instead of silent last-write behavior.

**Acceptance**
- EOS import no longer writes synthetic lens model values by focal length.
- Collision behavior is explicit, deterministic, and test-covered.

**Completion notes**
- Implemented in `Sources/Ledger/Import/EOS1VImportAdapter.swift`:
  - removed hardcoded lens inference output,
  - added `resolvedLensTag(...)` seam that currently returns `nil` (ready for future settings-driven policy and import overrides).
- Implemented in `Sources/Ledger/Import/ImportConflictResolver.swift`:
  - explicit merge warning capture on per-target/per-tag value collision,
  - deterministic precedence retained (later resolved conflict value overwrites earlier matched value),
  - warnings returned in `ImportConflictResolveResult`.
- Updated `Sources/Ledger/ImportUI/ImportSheetView.swift`:
  - status message now includes merge warning count when collisions were resolved by overwrite.
- Added regression tests in `Tests/LedgerTests/ImportSystemTests.swift`:
  - `testConflictResolverResolvedConflictOverwritesMatchedFieldWithWarning`
  - EOS parse assertion that `exif-lens` is not auto-authored.
- Verified via:
  - `swift test --filter ImportSystemTests`
  - `swift test --filter ImportMatrixTests`

**Policy-compatibility note**
- This keeps lens behavior policy-free at runtime today while preserving an adapter-level hook to read future v1.1 Settings policy (global defaults + per-import override).

---

### PR-D · Perf and cleanup batch (`M3` + `L3` + `L2` + `L1`)

**Status:** ✅ Completed on 2026-03-07.

**Goal:** Reduce repeated work in hot paths without changing behavior.

**Code files**
- `Sources/Ledger/Import/CSVImportAdapter.swift`
- `Sources/Ledger/Import/ReferenceImportSupport.swift`
- `Sources/Ledger/Import/CSVSupport.swift`
- `Sources/Ledger/Import/ImportCoordinator.swift` (if precomputing index there)
- `Sources/Ledger/Import/EOS1VImportAdapter.swift`

**Test files**
- `Tests/LedgerTests/ImportSystemTests.swift`
- `Tests/LedgerTests/ImportMatrixTests.swift` (regression run)

**Checklist**
- Promote coordinate regex to shared static compiled regex/parser.
- Avoid regex re-parsing in `normalizedHeader` (cached regex or character filter).
- Build tag descriptor index once per run/session instead of per parse.
- Remove unused `extensionProbeOrder` candidate array allocation.

**Acceptance**
- Existing behavior unchanged with lower per-row overhead.
- Shared parsing logic is centralized where practical.

**Completion notes**
- Implemented in `Sources/Ledger/Import/CSVSupport.swift`:
  - replaced `normalizedHeader` regex-based normalization with an allocation-light ASCII filter path,
  - added shared `parseCoordinateNumber(...)` with a static compiled regex,
  - added shared `buildTagDescriptorIndex(...)` utility.
- Implemented in `Sources/Ledger/Import/CSVImportAdapter.swift`:
  - switched coordinate parsing to shared `CSVSupport.parseCoordinateNumber(...)`,
  - removed adapter-local per-call regex and duplicate coordinate parser,
  - switched mapped-column descriptor lookup to context-provided prebuilt index.
- Implemented in `Sources/Ledger/Import/ReferenceImportSupport.swift`:
  - removed duplicate coordinate parser and re-used `CSVSupport.parseCoordinateNumber(...)`.
- Implemented in `Sources/Ledger/Import/ImportSourceAdapter.swift` and `Sources/Ledger/Import/ImportCoordinator.swift`:
  - added `tagDescriptorIndex` to `ImportParseContext`,
  - coordinator now precomputes descriptor index once per run and injects it into parse context.
- Implemented in `Sources/Ledger/Import/EOS1VImportAdapter.swift`:
  - removed unused `extensionProbeOrder` candidates array allocation from row selector fallback logic.
- Verified via:
  - `swift test --filter ImportSystemTests`
  - `swift test --filter ImportMatrixTests`

---

### PR-E · Contracts and documentation (`L4` + `L6`)

**Status:** ✅ Completed on 2026-03-07.

**Goal:** Lock ordering assumptions and document encoding ambiguity.

**Code files**
- `Sources/Ledger/Import/ImportMatcher.swift`
- Upstream ordering source in `AppModel.importTargetFiles(for:)`
- `Sources/Ledger/Import/CSVSupport.swift`

**Docs**
- `docs/ARCHITECTURE.md` and/or `docs/import-export-testing-matrix.md`

**Test files**
- `Tests/LedgerTests/ImportSystemTests.swift`

**Checklist**
- Add explicit row-parity ordering contract comment/assertion in matcher path.
- Ensure a test locks row-parity mapping to provided target ordering.
- Document UTF-8 vs CP1252 ambiguity and fallback strategy.

**Acceptance**
- Ordering assumptions are explicit and guarded against silent regressions.
- Encoding behavior is intentional and documented.

**Completion notes**
- Implemented in `Sources/Ledger/Import/ImportMatcher.swift`:
  - explicit row-parity ordering contract comment added (`targetFiles` order is caller-defined and preserved),
  - debug assertion added for duplicate target URLs in row-parity path.
- Implemented in `Sources/Ledger/AppModel.swift`:
  - documented that `importTargetFiles(for:)` returns stable browser-visible ordering used by row-parity matching.
- Implemented in `Sources/Ledger/Import/CSVSupport.swift`:
  - documented deterministic decoder order and explicit UTF-first behavior for ambiguous no-BOM cases.
- Implemented in `docs/import-export-testing-matrix.md`:
  - added encoding behavior note under ExifTool CSV import coverage.
- Existing row-order contract test retained:
  - `Tests/LedgerTests/ImportSystemTests.swift` → `testMatcherMapsRowParityToProvidedTargetOrder`.
- Verified via:
  - `swift test --filter ImportSystemTests`
  - `swift test --filter ImportMatrixTests`

---

### Follow-up · CSV matching simplification (post-review)

**Status:** ✅ Completed on 2026-03-07.

**Goal:** Remove user-facing CSV match mode switching while keeping deterministic behavior.

**Decision**
- CSV import now auto-selects strategy:
  - use filename matching only when `SourceFile` values are complete and uniquely map to in-scope targets,
  - otherwise fall back to row-order matching with an info warning.
- The sheet no longer exposes a CSV “Match by” toggle.

**Implemented**
- `Sources/Ledger/Import/CSVImportAdapter.swift`
  - added `effectiveMatchingStrategy(...)` and fallback diagnostics.
- `Sources/Ledger/ImportUI/ImportSheetView.swift`
  - removed CSV match-mode picker, updated copy to describe auto behavior.
- `Tests/LedgerTests/ImportSystemTests.swift`
  - added fallback regression coverage for incomplete `SourceFile` values.
- `docs/import-export-testing-matrix.md`
  - updated C4/C5 scenarios to reflect auto strategy.

**Verification**
- `swift test --filter ImportSystemTests`
- `swift test --filter ImportMatrixTests`

---

## Recommended PR Order

1. `PR-A` (GPX correctness)
2. `PR-B` (threading / async I/O)
3. `PR-C` (metadata policy)
4. `PR-D` (performance cleanup)
5. `PR-E` (contracts/docs)

## Notes

- Already fixed per this review: `H3`, `M4` (commit `40088be`).
- Highest regression risk is in `PR-B` and `PR-C`; keep those isolated from cleanup work.
