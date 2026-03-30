# Performance / Lightweighting Review

Current branch review focused on runtime performance, memory usage, and shipped binary size.

## Summary

The highest-ROI opportunities are:

1. Reduce inspector preview cache pressure.
2. Prevent full-resolution fallback images from entering the shared thumbnail cache.
3. Strip the release binary.
4. Cut repeated work in batch rename preview generation.

## Findings

### 1. Inspector preview cache is too aggressive

Relevant code:

- [Sources/Ledger/AppModel.swift](/Users/chrislemarquand/Xcode Projects/Ledger/Sources/Ledger/AppModel.swift#L556)
- [Sources/Ledger/AppModel.swift](/Users/chrislemarquand/Xcode Projects/Ledger/Sources/Ledger/AppModel.swift#L623)
- [Sources/Ledger/AppModel+MetadataPipeline.swift](/Users/chrislemarquand/Xcode Projects/Ledger/Sources/Ledger/AppModel+MetadataPipeline.swift#L126)
- [Sources/Ledger/AppModel+MetadataPipeline.swift](/Users/chrislemarquand/Xcode Projects/Ledger/Sources/Ledger/AppModel+MetadataPipeline.swift#L377)
- [Sources/Ledger/AppModel+MetadataPipeline.swift](/Users/chrislemarquand/Xcode Projects/Ledger/Sources/Ledger/AppModel+MetadataPipeline.swift#L439)
- [Sources/Ledger/AppModel+MetadataPipeline.swift](/Users/chrislemarquand/Xcode Projects/Ledger/Sources/Ledger/AppModel+MetadataPipeline.swift#L490)

Notes:

- `inspectorPreviewImages` stores `NSImage` instances in a second in-memory cache alongside the shared thumbnail cache.
- Folder preloading walks many files and promotes them into this cache.
- `maxInspectorPreviewCacheEntries` is set to `600`.
- Preview targets are `700px` / `1400px`, which is large enough for decoded image memory to grow quickly.
- Because `inspectorPreviewImages` is `@Published`, every write can also trigger broader UI work than a private cache would.

Likely impact:

- High resident memory usage on large folders.
- More UI churn than necessary during background preview warmup.

Recommended changes:

- Reduce the cap sharply, likely into the `20` to `50` range.
- Stop bulk preloading whole folders and restrict warmup to the current selection and nearby items.
- Move preview caching out of `@Published` state into a private cache such as `NSCache` or a non-published store.

### 2. Thumbnail fallback can cache full-resolution images

Relevant code:

- [Sources/Ledger/ThumbnailService.swift](/Users/chrislemarquand/Xcode Projects/Ledger/Sources/Ledger/ThumbnailService.swift#L239)
- [Sources/Ledger/ThumbnailService.swift](/Users/chrislemarquand/Xcode Projects/Ledger/Sources/Ledger/ThumbnailService.swift#L305)
- [Sources/Ledger/ThumbnailService.swift](/Users/chrislemarquand/Xcode Projects/Ledger/Sources/Ledger/ThumbnailService.swift#L330)

Notes:

- If ImageIO thumbnail generation and Quick Look both fail, the code falls back to `NSImage(contentsOf:)`.
- That image is then stored in the shared thumbnail cache.
- For large RAW or JPEG files, that fallback may represent a full decode rather than a bounded thumbnail.

Likely impact:

- Shared thumbnail cache can hold unexpectedly large images.
- Memory use becomes much less predictable on troublesome files.

Recommended changes:

- Remove `NSImage(contentsOf:)` from the cacheable thumbnail path.
- If a fallback decode is still needed, downsample it explicitly before caching.
- Prefer a file icon fallback instead of caching a potentially full-resolution image.

### 3. Release binary is not being stripped

Relevant code:

- [Config/Release.xcconfig](/Users/chrislemarquand/Xcode Projects/Ledger/Config/Release.xcconfig#L1)
- [Ledger.xcodeproj/project.pbxproj](/Users/chrislemarquand/Xcode Projects/Ledger/Ledger.xcodeproj/project.pbxproj#L625)

Measured locally:

- Release executable built via `swift build -c release`: `5.7M`
- Same executable after `strip -S -x`: `2.6M`

Notes:

- Release is configured with `DEBUG_INFORMATION_FORMAT = dwarf-with-dsym`.
- Project settings still show `COPY_PHASE_STRIP = NO` for Release.

Likely impact:

- The shipped product is materially larger than necessary.

Recommended changes:

- Enable stripping for shipped release builds.
- Keep the dSYM for symbolication, but do not ship the extra symbol data in the app binary.

### 4. Batch rename preview recomputes too much work

Relevant code:

- [Sources/Ledger/BatchRenameSheetView.swift](/Users/chrislemarquand/Xcode Projects/Ledger/Sources/Ledger/BatchRenameSheetView.swift#L83)
- [Sources/Ledger/AppModel+Actions.swift](/Users/chrislemarquand/Xcode Projects/Ledger/Sources/Ledger/AppModel+Actions.swift#L591)
- [Sources/Ledger/AppModel+Actions.swift](/Users/chrislemarquand/Xcode Projects/Ledger/Sources/Ledger/AppModel+Actions.swift#L645)
- [Sources/ExifEditCore/BatchRenameService.swift](/Users/chrislemarquand/Xcode Projects/Ledger/Sources/ExifEditCore/BatchRenameService.swift#L13)
- [Sources/ExifEditCore/BatchRenameService.swift](/Users/chrislemarquand/Xcode Projects/Ledger/Sources/ExifEditCore/BatchRenameService.swift#L236)
- [Sources/ExifEditCore/BatchRenameService.swift](/Users/chrislemarquand/Xcode Projects/Ledger/Sources/ExifEditCore/BatchRenameService.swift#L265)

Notes:

- The sheet recalculates preview on every pattern change.
- `renameFilesForBatchRename` sorts the inputs.
- `BatchRenameService.buildPlan` sorts the same list again.
- Date token handling creates `DateFormatter` instances inside per-file work.

Likely impact:

- More CPU work than necessary on large folders.
- Typing into the rename UI will scale poorly with folder size.

Recommended changes:

- Debounce preview recomputation.
- Pass already-sorted files into the service or sort in exactly one layer.
- Reuse `DateFormatter` instances per assessment instead of creating them per file.

## Suggested order

1. Inspector preview cache policy.
2. Thumbnail fallback behavior.
3. Release stripping.
4. Batch rename preview optimization.

## Validation notes

This review was based on source inspection plus a local `swift build -c release` measurement of the package executable. It did not include Instruments profiling or an Xcode archive of the full `.app` bundle.
