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

### H3 · `EOS1VImportAdapter.buildDateTimeOriginal` creates `DateFormatter` instances per row

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

### M4 · Static `DateFormatter`s use `TimeZone.current` — fragile across timezone changes

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
| H1 | `ImportCoordinator` | Sync disk I/O on `@MainActor` blocks UI | 🔴 |
| H2 | `GPXImportAdapter` | `<time>` before `<ele>` corrupts timestamp | 🔴 |
| H3 | `EOS1VImportAdapter` | `DateFormatter` allocated per row | 🔴 |
| M1 | `ExifToolCSVExportService` | Blocking synchronous export | 🟡 |
| M2 | `EOS1VImportAdapter` | Hardcoded lens inference writes wrong metadata | 🟡 |
| M3 | `CSVImportAdapter` | Regex recompiled per GPS field | 🟡 |
| M4 | Both CSV/GPX adapters | Static `DateFormatter` bakes in timezone at launch | 🟡 |
| M5 | `ImportConflictResolver` | Silent last-write-wins on field collision | 🟡 |
| L1 | `EOS1VImportAdapter` | Unused `extensionProbeOrder` candidates array | 🔵 |
| L2 | `CSVImportAdapter` | Tag descriptor index rebuilt per parse | 🔵 |
| L3 | `CSVSupport` | `normalizedHeader` regex re-parsed every call | 🔵 |
| L4 | `ImportMatcher` | Row-parity target ordering undocumented | 🔵 |
| L5 | `GPXImportAdapter` | Non-deterministic nearest-point on ties | 🔵 |
| L6 | `CSVSupport` | Encoding detection ambiguity (CP1252 vs UTF-8) | 🔵 |
