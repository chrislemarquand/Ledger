# EOS-1V roll metadata: a Ledger-owned overlay on immutable camera data

Status: **parked** (2026-08-30) — planned but not implemented. Tracked in
`docs/Roadmap.md` under v2.2+.

## Context

Right now Ledger's EOS-1V feature has exactly one piece of persisted local
state: `EOS1VDeletedRollsStore` (a bare, unversioned JSON `Set<String>` of
"deleted" roll IDs). Everything else — `EOS1VFilmRoll`/`EOS1VFrameRecord` —
is rebuilt from scratch from eos1v-serial's CSV on every download and never
touched again.

The goal is to build past that single-purpose tombstone into a real,
general local database for this feature, on top of an explicit principle:
**the camera's data is always the immutable source of truth.** New rolls
appear over time; old ones are never amended on the camera. Ledger should be
free to let the user attach and edit its own information on top — starting
with Title/Remarks (mirroring the Windows XP app's own per-roll fields,
seen in Canon's real "EOS-1V Memory" detail window) — and, per explicit
clarification during planning, **any field** should ultimately be editable,
not just title/remarks or a date/time correction. The one hard rule: raw,
unedited camera data must always remain exportable exactly as today, so the
"Export Original…" guarantee never depends on what's in Ledger's own
database.

Research into the existing codebase (`Sources/ExifEditCore/Domain.swift`,
`BackupManager.swift`) confirmed Ledger has no database engine anywhere and
no existing "original vs. user-edited" overlay concept to reuse — its main
library is files-on-disk edited destructively (with a backup) via exiftool.
The one directly reusable pattern is the schema-versioned JSON-envelope
file store used for app-level persisted data, seen in `LensProfiles.swift`
(`FileLensProfileStore`) and `Presets.swift` — atomic temp-file-then-replace
writes, a `schemaVersion` field, and a protocol for DI. That pattern (not a
new database, and not the more primitive `EOS1VDeletedRollsStore` shape) is
what the new roll-metadata store should mirror.

## Data model

New file `Sources/Ledger/EOS1V/EOS1VRollMetadataStore.swift`:

```swift
struct EOS1VRollMetadata: Codable, Equatable {
    var title: String = ""
    var remarks: String = ""
    var isDeleted: Bool = false
    /// Roll-level overrides, keyed by EOS1VFilmRoll field name
    /// ("loadedDate", "loadedTime" — id/frames are never overridable).
    var rollFieldOverrides: [String: String] = [:]
    /// Per-frame overrides: frame number -> field name -> override value.
    var frameFieldOverrides: [String: [String: String]] = [:]
}

protocol EOS1VRollMetadataStoreProtocol {
    func loadAll() throws -> [String: EOS1VRollMetadata]
    func saveAll(_ metadata: [String: EOS1VRollMetadata]) throws
}

struct FileEOS1VRollMetadataStore: EOS1VRollMetadataStoreProtocol {
    // Mirrors FileLensProfileStore exactly: Envelope{schemaVersion, rolls},
    // atomic temp-file + replaceItemAt, file "roll-metadata.json".
}
```

Every field on `EOS1VFrameRecord`/`EOS1VFilmRoll` is already a `String`
(confirmed by reading both structs), so a generic string-keyed override
dictionary can represent an edit to *any* field with no per-field plumbing.
This directly satisfies "it should be possible to edit any field."

**One-time migration**: on first `loadAll()`, if `roll-metadata.json` doesn't
exist yet, read the legacy `deleted-rolls.json` (if present) and seed
`isDeleted = true` entries from it. The old file is left on disk afterwards,
untouched and unused — no need to delete it. `EOS1VDeletedRollsStore.swift`
is then deleted from the repo.

**Correction from the original version of this plan**: `Ledger.xcodeproj` is
a real Xcode project with explicit `PBXFileReference`/`PBXBuildFile`
membership in `project.pbxproj` (verified when `EOS1VFramePreviewViewController.swift`
was removed and `EOS1VRollDetailSheetView.swift` added for the read-only
sheet redesign below) — a `Package.swift` also exists alongside it, but it
builds a separate `ExifEditCore`/`ExifEditMac` product, not the `Ledger`
scheme built via `SharedUI.xcworkspace`. So adding or removing any file
under `Sources/Ledger/EOS1V/` for this plan needs a matching
`project.pbxproj` edit (new `PBXFileReference` + `PBXBuildFile` + group +
Sources-phase entries, following the existing `A10001D*`/`A10001E*` ID
pattern), not just dropping the file on disk.

**Applying overrides** (same file, or a small extension alongside the
structs in `EOS1VSessionController.swift`): change `EOS1VFrameRecord`'s and
`EOS1VFilmRoll`'s stored properties from `let` to `var` (still simple value
structs, no behavior change) so a static `[String: WritableKeyPath<...>]`
table can drive generic field application:

```swift
extension EOS1VFrameRecord {
    private static let overridableFields: [String: WritableKeyPath<EOS1VFrameRecord, String>] = [
        "focalLength": \.focalLength, "maxAperture": \.maxAperture, "tv": \.tv, /* …all fields except id/frameNumber */
    ]
    func applying(_ overrides: [String: String]) -> EOS1VFrameRecord {
        var copy = self
        for (field, value) in overrides {
            if let kp = Self.overridableFields[field] { copy[keyPath: kp] = value }
        }
        return copy
    }
}

extension EOS1VFilmRoll {
    func effectiveFrames(applying metadata: EOS1VRollMetadata) -> [EOS1VFrameRecord] {
        frames.map { frame in
            guard let overrides = metadata.frameFieldOverrides[frame.frameNumber] else { return frame }
            return frame.applying(overrides)
        }
    }
    func effectiveLoadedDate(applying metadata: EOS1VRollMetadata) -> String {
        metadata.rollFieldOverrides["loadedDate"] ?? loadedDate
    }
    func effectiveLoadedTime(applying metadata: EOS1VRollMetadata) -> String {
        metadata.rollFieldOverrides["loadedTime"] ?? loadedTime
    }
}
```

## Session controller (`EOS1VSessionController.swift`)

Replace `deletedRollIDs: Set<String>` + `EOS1VDeletedRollsStore` with:

```swift
@Published private(set) var rollMetadata: [String: EOS1VRollMetadata] = [:]
private let metadataStore: EOS1VRollMetadataStoreProtocol

func metadata(for rollID: String) -> EOS1VRollMetadata {
    rollMetadata[rollID] ?? EOS1VRollMetadata()
}

func updateMetadata(for rollID: String, _ mutate: (inout EOS1VRollMetadata) -> Void) {
    var entry = rollMetadata[rollID] ?? EOS1VRollMetadata()
    mutate(&entry)
    rollMetadata[rollID] = entry
    try? metadataStore.saveAll(rollMetadata)
}
```

`markRollDeleted`/`restoreRoll` become one-line wrappers around
`updateMetadata` so their existing call sites in `EOS1VShootingViewController`
don't need to change. Init loads via `metadataStore.loadAll()` (with the
migration handled inside the store, as above).

## CSV export (`EOS1VRollCSVExporter.swift`)

Add a `metadata: EOS1VRollMetadata = EOS1VRollMetadata()` parameter to
`canonCSV(for:recordedItemNames:metadata:)`. Inside:
- Header row: replace the hardcoded `"Title", ""` and the blank Remarks row
  with `metadata.title` / `metadata.remarks`.
- Use `roll.effectiveLoadedDate(applying: metadata)` /
  `effectiveLoadedTime(applying:)` in place of `roll.loadedDate/loadedTime`.
- Iterate `roll.effectiveFrames(applying: metadata)` instead of `roll.frames`
  for the per-frame rows.

Calling with the default empty `EOS1VRollMetadata()` reproduces exactly
today's byte-for-byte output — this is what "Export Original…" always uses,
by construction, regardless of what's in the metadata store.

## Shooting Data tab (`EOS1VShootingViewController.swift`)

- Split the current single `exportButton` into two buttons, both enabled
  under the same "≥1 selected" rule as today:
  - **"Export Original…"** — always calls `canonCSV` with a fresh, empty
    `EOS1VRollMetadata()`, never reads `session.rollMetadata`. This is the
    permanent raw-data guarantee.
  - **"Export…"** — calls `canonCSV` with `session.metadata(for: roll.id)`
    for each roll, producing the Ledger-enriched output.
- Update `deleteOrRestoreSelectedRolls`/`updateButtonStates`/
  `rebuildVisibleRolls` to read `session.metadata(for: roll.id).isDeleted`
  instead of `session.deletedRollIDs.contains`.
- Add a **Title** column to the roll table (reading `session.metadata(for:
  roll.id).title`), matching the Windows XP main list, which already shows
  this column.

## Roll detail sheet (`EOS1VRollDetailSheetView.swift`)

**Update 2026-08-30**: the read-only half of this redesign already shipped,
ahead of the metadata/editing work below. `EOS1VFramePreviewViewController`
(the old AppKit two-column `EOS1VRowsViewController` sheet) was replaced
with `EOS1VRollDetailSheetView` — a SwiftUI `View` (header info block +
`Table`-based multi-column frame grid, matching Canon's own per-roll window)
presented from `EOS1VShootingViewController` via `NSHostingController` +
`presentAsSheet(_:)`, mirroring the existing `LensProfileManagerSheet`
pattern from `SettingsWindowController`. It's read-only — no editing wired
up yet. What's described below is the remaining work: making that same view
editable once the metadata store exists.

Editing work still to do, on top of the now-existing `EOS1VRollDetailSheetView`:

- **Header block**: editable Title and Remarks text fields; editable Loaded
  Date / Loaded Time fields; read-only Film ID, Frame count, ISO (DX).
  Editing a header field calls `session.updateMetadata(for: roll.id) { ... }`
  directly (title/remarks) or into `rollFieldOverrides` (loaded date/time).
- **Frame grid**: a real multi-column `NSTableView` — one row per frame, one
  column per `EOS1VFrameRecord` field (Frame No., Focal length, Max.
  aperture, Tv, Av, ISO (M), Exposure compensation, Flash exposure
  compensation, Flash mode, Metering mode, Shooting mode, Film advance, AF
  mode, Date, Time, Multiple exposure, Battery date, Battery time),
  horizontally scrollable — replacing the current name/value list. Frame No.
  is read-only (it's the join key into `frameFieldOverrides`); every other
  column is an editable text cell. Committing an edit calls
  `session.updateMetadata(for: roll.id) { $0.frameFieldOverrides[frameNumber,
  default: [:]][field] = newValue }`.
- Still presented via `presentAsSheet(_:)`, matching the existing
  AppKit-sheet decision for this screen (not a separate window, not a
  SwiftUI bridge).
- Out of scope for this pass, flagged for later rather than assumed away:
  a "reset to camera value" affordance and visually marking edited cells.
  The data model already supports both (an override is just an entry to
  remove from the dictionary, and "has an override" is a cheap lookup) —
  this plan only wires up entry, not those refinements.

## Files touched

- New: `EOS1VRollMetadataStore.swift`
- Deleted: `EOS1VDeletedRollsStore.swift` (superseded; SPM package, no
  project-membership file to edit)
- Edited: `EOS1VSessionController.swift`, `EOS1VRollCSVExporter.swift`,
  `EOS1VShootingViewController.swift`, `EOS1VFramePreviewViewController.swift`
- Untouched: `eos1v-serial` entirely; `EOS1VFilmRoll`/`EOS1VFrameRecord`'s
  parsing from eos1v-serial's CSV (still rebuilt fresh from the camera on
  every download, never mutated by anything in this plan).

## Verification (when this is picked back up)

- Compile-only check via the established `xcodebuild`-through-`SharedUI.xcworkspace`
  bypass pattern used throughout the EOS-1V UI work (never launching the
  app from an agent session — build/test in Xcode directly).
- Manual test: download a roll, open its detail sheet, edit Title/
  Remarks/Loaded Date/a frame field, close and reopen the sheet — edits
  persist; "Export Original…" is still byte-identical to today's output;
  "Export…" includes the edited values; mark a roll deleted, quit and
  relaunch Ledger, confirm it's still hidden; if an old
  `deleted-rolls.json` still exists on disk, confirm those rolls show as
  deleted after this update (migration correctness).
