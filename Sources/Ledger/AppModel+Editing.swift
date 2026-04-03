import AppKit
import ExifEditCore
import Foundation
import SharedUI

@MainActor
extension AppModel {
    func valueForTag(_ tag: EditableTag) -> String {
        draftValues[tag] ?? ""
    }

    func updateValue(_ value: String, for tag: EditableTag) {
        let currentValue = draftValues[tag] ?? ""
        if currentValue == value {
            return
        }

        let currentTrimmed = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let incomingTrimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if currentTrimmed == incomingTrimmed {
            // Focus transitions in NSTextField can emit whitespace-equivalent reassignments.
            // Treat these as no-ops to avoid transient staged-edit dots.
            return
        }

        let previousState = currentPendingEditState()
        draftValues[tag] = value
        trackPendingEdit(value, for: tag, source: .manual)
        // Coalesce undo entries within a continuous text-field edit session.
        // Only push on the first keystroke in a field; subsequent keystrokes in the
        // same field are folded in. endUndoCoalescing() is called from InspectorView
        // when focus leaves the field, allowing the next edit to push its own entry.
        if undoCoalescingTagID != tag.id {
            registerMetadataUndoIfNeeded(previous: previousState)
            undoCoalescingTagID = tag.id
        }
        notifyInspectorDidChange()
    }

    func endUndoCoalescing() {
        undoCoalescingTagID = nil
    }

    @discardableResult
    func undoLastMetadataEdit() -> Bool {
        undoCoalescingTagID = nil
        guard let previousState = metadataUndoStack.popLast() else { return false }
        let currentState = currentPendingEditState()
        metadataRedoStack.append(currentState)
        applyPendingEditState(previousState)
        setStatusMessage("Undid metadata edit.", autoClearAfterSuccess: true)
        return true
    }

    @discardableResult
    func redoLastMetadataEdit() -> Bool {
        undoCoalescingTagID = nil
        guard let nextState = metadataRedoStack.popLast() else { return false }
        let currentState = currentPendingEditState()
        metadataUndoStack.append(currentState)
        applyPendingEditState(nextState)
        setStatusMessage("Redid metadata edit.", autoClearAfterSuccess: true)
        return true
    }

    private func makeEditSessionSnapshot(for tag: EditableTag) -> EditSessionSnapshot {
        let selected = Array(selectedFileURLs)
        var stagedValues: [URL: StagedEditRecord] = [:]
        for fileURL in selected {
            if let staged = pendingEditsByFile[fileURL]?[tag] {
                stagedValues[fileURL] = staged
            }
        }
        return EditSessionSnapshot(
            tag: tag,
            draftValue: valueForTag(tag),
            selectedFileURLs: selected,
            stagedValuesByFile: stagedValues
        )
    }

    func restoreEditSession(_ snapshot: EditSessionSnapshot) {
        draftValues[snapshot.tag] = snapshot.draftValue

        for fileURL in snapshot.selectedFileURLs {
            if let staged = snapshot.stagedValuesByFile[fileURL] {
                var map = pendingEditsByFile[fileURL] ?? [:]
                map[snapshot.tag] = staged
                pendingEditsByFile[fileURL] = map
            } else {
                pendingEditsByFile[fileURL]?[snapshot.tag] = nil
                if pendingEditsByFile[fileURL]?.isEmpty == true {
                    pendingEditsByFile[fileURL] = nil
                }
            }
        }

        recalculateInspectorState()
    }

    func beginEditSessionSnapshotIfNeeded(for tag: EditableTag) {
        guard editSessionSnapshotsByTagID[tag.id] == nil else { return }
        editSessionSnapshotsByTagID[tag.id] = makeEditSessionSnapshot(for: tag)
    }

    func editSessionSnapshot(forTagID tagID: String) -> EditSessionSnapshot? {
        editSessionSnapshotsByTagID[tagID]
    }

    func removeEditSessionSnapshot(forTagID tagID: String) {
        editSessionSnapshotsByTagID[tagID] = nil
    }

    func clearEditSessionSnapshots() {
        editSessionSnapshotsByTagID.removeAll()
    }

    func editableTag(forID id: String) -> EditableTag? {
        activeEditableTagsByID[id]
    }

    func parseEditableDateValue(_ raw: String) -> Date? {
        parseDate(raw)
    }

    func formatEditableDateValue(_ date: Date) -> String {
        Self.exifDateFormatter.string(from: date)
    }

    var mixedOverrideCount: Int {
        activeEditableTags.reduce(0) { count, tag in
            guard isMixedValue(for: tag) else { return count }
            let current = draftValues[tag]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return current.isEmpty ? count : count + 1
        }
    }

    var needsMixedValueConfirmation: Bool {
        selectedFileURLs.count > 1 && mixedOverrideCount > 0
    }

    func isDateTimeTag(_ tag: EditableTag) -> Bool {
        switch tag.id {
        case "datetime-modified", "datetime-digitized", "datetime-created":
            return true
        default:
            return false
        }
    }

    func isBooleanTag(_ tag: EditableTag) -> Bool {
        tag.id == "xmp-copyright-status"
    }

    func dateValueForTag(_ tag: EditableTag) -> Date? {
        guard isDateTimeTag(tag) else { return nil }
        let raw = valueForTag(tag).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        return parseDate(raw)
    }

    func updateDateValue(_ date: Date, for tag: EditableTag) {
        guard isDateTimeTag(tag) else { return }
        let nextValue = Self.exifDateFormatter.string(from: date)
        let currentValue = draftValues[tag]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if currentValue == nextValue {
            return
        }
        if let currentDate = parseDate(currentValue),
           abs(currentDate.timeIntervalSince(date)) < 0.5
        {
            return
        }
        updateValue(nextValue, for: tag)
    }

    func clearDateValue(for tag: EditableTag) {
        guard isDateTimeTag(tag) else { return }
        updateValue("", for: tag)
    }

    func hasPendingChange(for tag: EditableTag) -> Bool {
        selectedFileURLs.contains { url in
            pendingEditsByFile[url]?[tag] != nil
        }
    }

    func hasPendingEdits(for fileURL: URL) -> Bool {
        !(pendingEditsByFile[fileURL]?.isEmpty ?? true) || !effectiveImageOperations(for: fileURL).isEmpty
    }

    func hasAnyPendingChanges(for fileURL: URL) -> Bool {
        hasPendingEdits(for: fileURL) || pendingRenameByFile[fileURL] != nil
    }

    func hasPendingImageEdits(for fileURL: URL) -> Bool {
        !effectiveImageOperations(for: fileURL).isEmpty
    }

    func displayImageForCurrentStagedState(_ image: NSImage, fileURL: URL) -> NSImage {
        let ops = effectiveImageOperations(for: fileURL)
        guard !ops.isEmpty else { return image }
        return Self.applyImageOperations(ops, to: image) ?? image
    }

    func displayAspectRatioForCurrentStagedState(_ aspectRatio: CGFloat?, fileURL: URL) -> CGFloat? {
        guard let aspectRatio, aspectRatio > 0 else { return aspectRatio }
        let ops = effectiveImageOperations(for: fileURL)
        guard !ops.isEmpty else { return aspectRatio }
        let rotateCount = ops.reduce(0) { partial, op in
            switch op {
            case .rotateLeft90:
                return partial + 1
            case .flipHorizontal:
                return partial
            }
        }
        guard rotateCount % 2 != 0 else { return aspectRatio }
        return 1.0 / aspectRatio
    }

    func listColumnValue(for fileURL: URL, columnID: String, fallbackItem: BrowserItem?) -> String {
        switch columnID {
        case ListColumnDefinition.idName:
            if let proposed = pendingRenameByFile[fileURL] {
                return proposed
            }
            return fallbackItem?.name ?? fileURL.lastPathComponent
        case ListColumnDefinition.idCreated:
            if let date = fallbackItem?.createdAt {
                return Self.listDateFormatter.string(from: date)
            }
            return "—"
        case ListColumnDefinition.idModified:
            if let date = fallbackItem?.modifiedAt {
                return Self.listDateFormatter.string(from: date)
            }
            return "—"
        case ListColumnDefinition.idSize:
            if let size = fallbackItem?.sizeBytes, size >= 0 {
                return Self.byteCountFormatter.string(fromByteCount: Int64(size))
            }
            return "—"
        case ListColumnDefinition.idKind:
            if let kind = fallbackItem?.kind, !kind.isEmpty {
                return kind
            }
            return "—"
        case ListColumnDefinition.idDimensions:
            if let (w, h) = imagePixelDimensions(for: fileURL) {
                return "\(w) × \(h)"
            }
            return "—"
        case ListColumnDefinition.idRating:
            let raw = metadataStringValue(for: fileURL, keys: ["Rating"])
            return raw == "0" ? "—" : raw
        case ListColumnDefinition.idMake:
            return metadataStringValue(for: fileURL, keys: ["Make"])
        case ListColumnDefinition.idModel:
            return metadataStringValue(for: fileURL, keys: ["Model"])
        case ListColumnDefinition.idLens:
            return metadataStringValue(for: fileURL, keys: ["LensModel", "Lens"])
        case ListColumnDefinition.idAperture:
            return metadataAperture(for: fileURL)
        case ListColumnDefinition.idShutter:
            return metadataShutter(for: fileURL)
        case ListColumnDefinition.idISO:
            return metadataISO(for: fileURL)
        case ListColumnDefinition.idFocal:
            return metadataFocalLength(for: fileURL)
        case ListColumnDefinition.idDateTaken:
            return metadataDateTaken(for: fileURL)
        case ListColumnDefinition.idTitle:
            return metadataStringValue(for: fileURL, keys: ["Title"])
        case ListColumnDefinition.idDescription:
            return metadataStringValue(for: fileURL, keys: ["Description", "Caption-Abstract"])
        case ListColumnDefinition.idKeywords:
            return metadataStringValue(for: fileURL, keys: ["Subject", "Keywords"])
        case ListColumnDefinition.idCopyright:
            return metadataStringValue(for: fileURL, keys: ["Copyright"])
        case ListColumnDefinition.idCreator:
            return metadataStringValue(for: fileURL, keys: ["Creator", "Artist"])
        default:
            return "—"
        }
    }

    func knownKeywords() -> [String] {
        var seen = Set<String>()
        for snapshot in metadataByFile.values {
            for field in snapshot.fields where field.key == "Subject" || field.key == "Keywords" {
                for keyword in field.value.components(separatedBy: ", ") {
                    let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { seen.insert(trimmed) }
                }
            }
        }
        return seen.sorted()
    }

    private func metadataStringValue(for fileURL: URL, keys: [String]) -> String {
        guard let snapshot = metadataByFile[fileURL] else { return "—" }
        for key in keys {
            if let value = snapshot.fields.first(where: { $0.key == key })?.value {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return "—"
    }

    private func metadataAperture(for fileURL: URL) -> String {
        let raw = metadataStringValue(for: fileURL, keys: ["FNumber", "Aperture"])
        guard raw != "—" else { return raw }
        if raw.lowercased().hasPrefix("f/") { return raw }
        return "f/\(raw)"
    }

    private func metadataShutter(for fileURL: URL) -> String {
        let raw = metadataStringValue(for: fileURL, keys: ["ExposureTime", "ShutterSpeedValue"])
        guard raw != "—" else { return raw }
        // ExifTool commonly returns "1/250" directly
        if raw.contains("/") { return "\(raw) s" }
        guard let value = Double(raw) else { return raw }
        if value >= 1.0 {
            let formatted = value.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int(value))
                : String(format: "%.1f", value)
            return "\(formatted) s"
        } else if value > 0 {
            let denominator = Int((1.0 / value).rounded())
            return "1/\(denominator) s"
        }
        return raw
    }

    private func metadataISO(for fileURL: URL) -> String {
        let raw = metadataStringValue(for: fileURL, keys: ["ISO"])
        guard raw != "—" else { return raw }
        if let d = Double(raw), d >= 0, d.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(d))
        }
        return raw
    }

    private func metadataFocalLength(for fileURL: URL) -> String {
        let raw = metadataStringValue(for: fileURL, keys: ["FocalLength"])
        guard raw != "—" else { return raw }
        if raw.lowercased().contains("mm") { return raw }
        if let d = Double(raw) {
            if d.truncatingRemainder(dividingBy: 1) == 0 {
                return "\(Int(d)) mm"
            }
            return "\(raw) mm"
        }
        return raw
    }

    private func metadataDateTaken(for fileURL: URL) -> String {
        let raw = metadataStringValue(for: fileURL, keys: ["DateTimeOriginal", "CreateDate"])
        guard raw != "—" else { return raw }
        if let date = Self.exifDateFormatter.date(from: raw) {
            return Self.listDateFormatter.string(from: date)
        }
        return raw
    }

    func imagePixelDimensions(for fileURL: URL) -> (Int, Int)? {
        guard let snapshot = metadataByFile[fileURL] else { return nil }
        let widthKeys: Set<String> = ["ImageWidth", "ExifImageWidth", "PixelXDimension"]
        let heightKeys: Set<String> = ["ImageHeight", "ExifImageHeight", "PixelYDimension"]

        let width = snapshot.fields
            .first(where: { widthKeys.contains($0.key) })
            .flatMap { parseDimensionValue($0.value) }
        let height = snapshot.fields
            .first(where: { heightKeys.contains($0.key) })
            .flatMap { parseDimensionValue($0.value) }

        guard let width, let height, width > 0, height > 0 else { return nil }
        return (width, height)
    }

    private func parseDimensionValue(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let direct = Int(trimmed), direct > 0 {
            return direct
        }
        if let number = Double(trimmed), number.isFinite {
            let rounded = Int(number.rounded())
            return rounded > 0 ? rounded : nil
        }
        let ns = trimmed as NSString
        if let match = try? NSRegularExpression(pattern: "\\d+")
            .firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)) {
            let candidate = ns.substring(with: match.range)
            if let parsed = Int(candidate), parsed > 0 {
                return parsed
            }
        }
        return nil
    }

    func pickerOptions(for tag: EditableTag) -> [PickerOption]? {
        let base: [PickerOption]

        switch tag.id {
        case "exif-exposure-program":
            base = [
                .init(value: "0", label: "Unknown"),
                .init(value: "1", label: "Manual"),
                .init(value: "2", label: "Program AE"),
                .init(value: "3", label: "Aperture Priority"),
                .init(value: "4", label: "Shutter Priority"),
                .init(value: "5", label: "Creative"),
                .init(value: "6", label: "Action"),
                .init(value: "7", label: "Portrait"),
                .init(value: "8", label: "Landscape")
            ]
        case "exif-flash":
            base = [
                .init(value: "0", label: "No Flash (Did Not Fire)"),
                .init(value: "1", label: "Fired"),
                .init(value: "5", label: "Fired, No Return"),
                .init(value: "7", label: "Fired, Return Detected"),
                .init(value: "9", label: "On, Did Not Fire"),
                .init(value: "13", label: "On, No Return"),
                .init(value: "15", label: "On, Return Detected"),
                .init(value: "16", label: "Off"),
                .init(value: "24", label: "Auto, Did Not Fire"),
                .init(value: "25", label: "Auto, Fired"),
                .init(value: "29", label: "Auto, Fired, No Return"),
                .init(value: "31", label: "Auto, Fired, Return Detected"),
                .init(value: "32", label: "No Flash Function"),
                .init(value: "65", label: "Fired, Red-Eye Reduction"),
                .init(value: "69", label: "Fired, Red-Eye, No Return"),
                .init(value: "71", label: "Fired, Red-Eye, Return Detected"),
                .init(value: "73", label: "On, Red-Eye, Did Not Fire"),
                .init(value: "77", label: "On, Red-Eye, No Return"),
                .init(value: "79", label: "On, Red-Eye, Return Detected"),
                .init(value: "89", label: "Auto, Fired, Red-Eye"),
                .init(value: "93", label: "Auto, Fired, Red-Eye, No Return"),
                .init(value: "95", label: "Auto, Fired, Red-Eye, Return Detected")
            ]
        case "exif-metering-mode":
            base = [
                .init(value: "0", label: "Unknown"),
                .init(value: "1", label: "Average"),
                .init(value: "2", label: "Center-Weighted Average"),
                .init(value: "3", label: "Spot"),
                .init(value: "4", label: "Multi-Spot"),
                .init(value: "5", label: "Multi-Segment"),
                .init(value: "6", label: "Partial"),
                .init(value: "255", label: "Other")
            ]
        case "xmp-copyright-status":
            base = [
                .init(value: "True", label: "Copyrighted"),
                .init(value: "False", label: "Public Domain / No Copyright")
            ]
        default:
            return nil
        }

        return base
    }

    func isMixedValue(for tag: EditableTag) -> Bool {
        selectedFileURLs.count > 1 && mixedTags.contains(tag)
    }

    var pendingEditedFileCount: Int {
        let metadataOrImagePending = Set(
            browserItems
                .map(\.url)
                .filter { hasAnyPendingChanges(for: $0) }
        )
        let renamedPending = Set(pendingRenameByFile.keys)
        return metadataOrImagePending.union(renamedPending).count
    }

    func stageImageOperation(_ operation: StagedImageOperation, for fileURL: URL) {
        let previousState = currentPendingEditState()
        var ops = pendingImageOpsByFile[fileURL] ?? []
        ops.append(operation)
        let normalized = Self.normalizeStagedImageOperations(ops)
        if normalized.isEmpty {
            pendingImageOpsByFile[fileURL] = nil
        } else {
            pendingImageOpsByFile[fileURL] = normalized
        }

        removeStagedQuickLookPreviewFile(for: fileURL)
        // Bump the display token so the gallery reconfigures visible cells with the updated
        // software transform, without clearing the thumbnail pipeline cache or triggering an
        // async re-fetch. The cache is invalidated after the operation is applied to disk.
        stagedOpsDisplayToken &+= 1
        recalculateInspectorState(forceNotify: true)
        registerMetadataUndoIfNeeded(previous: previousState)
    }

    private func startStagedQuickLookPreviewGeneration(for sourceURL: URL, operations: [StagedImageOperation]) {
        guard !operations.isEmpty else { return }
        guard !stagedQuickLookPreviewGenerationInFlight.contains(sourceURL) else { return }
        stagedQuickLookPreviewGenerationInFlight.insert(sourceURL)
        Task { [weak self] in
            guard let self else { return }
            let previewURL = await Task.detached(priority: .userInitiated) { [sourceURL] in
                AppModel.generateStagedQuickLookPreviewFile(sourceURL: sourceURL, operations: operations)
            }.value

            stagedQuickLookPreviewGenerationInFlight.remove(sourceURL)
            guard !effectiveImageOperations(for: sourceURL).isEmpty else {
                if let previewURL {
                    try? FileManager.default.removeItem(at: previewURL)
                }
                return
            }
            if let previewURL {
                removeStagedQuickLookPreviewFile(for: sourceURL)
                stagedQuickLookPreviewFiles[sourceURL] = previewURL
                QuickLookPreviewController.shared.refreshIfVisible(model: self)
            }
        }
    }

    private nonisolated static func generateStagedQuickLookPreviewFile(sourceURL: URL, operations: [StagedImageOperation]) -> URL? {
        let previewsDirectory = AppBrand.currentSupportDirectoryURL()
            .appendingPathComponent("QuickLookPreviews", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: previewsDirectory, withIntermediateDirectories: true)
            let ext = sourceURL.pathExtension.isEmpty ? "jpg" : sourceURL.pathExtension
            let name = "\(UUID().uuidString).\(ext)"
            let generatedURL = previewsDirectory.appendingPathComponent(name, isDirectory: false)
            try FileManager.default.copyItem(at: sourceURL, to: generatedURL)

            for operation in operations {
                let arguments: [String]
                switch operation {
                case .rotateLeft90:
                    arguments = ["-r", "-90", generatedURL.path]
                case .flipHorizontal:
                    arguments = ["--flip", "horizontal", generatedURL.path]
                }
                try runSipsSync(arguments: arguments)
            }
            return generatedURL
        } catch {
            return nil
        }
    }

    private nonisolated static func runSipsSync(arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        process.arguments = arguments
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrText = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "sips exited with code \(process.terminationStatus)"
            throw NSError(
                domain: "\(AppBrand.identifierPrefix).QuickLookPreview",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: stderrText]
            )
        }
    }

    func effectiveImageOperations(for fileURL: URL) -> [StagedImageOperation] {
        Self.normalizeStagedImageOperations(pendingImageOpsByFile[fileURL] ?? [])
    }

    static func normalizeStagedImageOperations(_ operations: [StagedImageOperation]) -> [StagedImageOperation] {
        guard !operations.isEmpty else { return [] }
        let transform = operations.reduce(ImageTransformMatrix.identity) { partial, op in
            let opMatrix: ImageTransformMatrix = switch op {
            case .rotateLeft90:
                .rotateLeft90
            case .flipHorizontal:
                .flipHorizontal
            }
            // Operations are applied in-order to the image.
            return opMatrix.multiplied(by: partial)
        }
        return canonicalImageOperationMap[transform] ?? operations
    }

    static let canonicalImageOperationMap: [ImageTransformMatrix: [StagedImageOperation]] = {
        let candidates: [StagedImageOperation] = [.rotateLeft90, .flipHorizontal]
        var bestByTransform: [ImageTransformMatrix: [StagedImageOperation]] = [.identity: []]
        var queue: [[StagedImageOperation]] = [[]]

        while !queue.isEmpty {
            let current = queue.removeFirst()
            if current.count >= 4 { continue }

            for op in candidates {
                let next = current + [op]
                let transform = next.reduce(ImageTransformMatrix.identity) { partial, step in
                    let opMatrix: ImageTransformMatrix = switch step {
                    case .rotateLeft90:
                        .rotateLeft90
                    case .flipHorizontal:
                        .flipHorizontal
                    }
                    return opMatrix.multiplied(by: partial)
                }
                if bestByTransform[transform] == nil {
                    bestByTransform[transform] = next
                    queue.append(next)
                }
            }
        }

        return bestByTransform
    }()

    static func applyStagedImageOperations(_ operations: [StagedImageOperation], to fileURL: URL) async throws {
        guard !operations.isEmpty else { return }
        for operation in operations {
            switch operation {
            case .rotateLeft90:
                try await runSips(arguments: ["-r", "-90", fileURL.path], errorDomain: "\(AppBrand.identifierPrefix).Rotate")
            case .flipHorizontal:
                try await runSips(arguments: ["--flip", "horizontal", fileURL.path], errorDomain: "\(AppBrand.identifierPrefix).Flip")
            }
        }
    }

    private nonisolated static func applyImageOperations(_ operations: [StagedImageOperation], to image: NSImage) -> NSImage? {
        var current = image
        for operation in operations {
            guard let next = transformedImage(current, operation: operation) else { return nil }
            current = next
        }
        return current
    }

    private nonisolated static func transformedImage(_ image: NSImage, operation: StagedImageOperation) -> NSImage? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let outputSize: NSSize
        switch operation {
        case .rotateLeft90:
            outputSize = NSSize(width: size.height, height: size.width)
        case .flipHorizontal:
            outputSize = size
        }

        let output = NSImage(size: outputSize)
        output.lockFocus()
        guard let context = NSGraphicsContext.current?.cgContext else {
            output.unlockFocus()
            return nil
        }
        context.interpolationQuality = .high
        switch operation {
        case .rotateLeft90:
            // Counterclockwise 90deg (true "Rotate Left")
            context.translateBy(x: outputSize.width, y: 0)
            context.rotate(by: .pi / 2)
            image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1.0)
        case .flipHorizontal:
            context.translateBy(x: outputSize.width, y: 0)
            context.scaleBy(x: -1, y: 1)
            image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1.0)
        }
        output.unlockFocus()
        return output
    }

    private nonisolated static func writeImage(_ image: NSImage, to fileURL: URL) throws {
        guard let rep = NSBitmapImageRep(data: image.tiffRepresentation ?? Data()) else {
            throw NSError(
                domain: "\(AppBrand.identifierPrefix).ImageOps",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not render transformed image."]
            )
        }

        let ext = fileURL.pathExtension.lowercased()
        let type: NSBitmapImageRep.FileType = {
            switch ext {
            case "jpg", "jpeg":
                return .jpeg
            case "png":
                return .png
            case "tif", "tiff":
                return .tiff
            case "gif":
                return .gif
            case "bmp":
                return .bmp
            default:
                return .jpeg
            }
        }()

        var properties: [NSBitmapImageRep.PropertyKey: Any] = [:]
        if type == .jpeg {
            properties[.compressionFactor] = 0.98
        }
        guard let data = rep.representation(using: type, properties: properties) else {
            throw NSError(
                domain: "\(AppBrand.identifierPrefix).ImageOps",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Could not encode transformed image."]
            )
        }
        try data.write(to: fileURL, options: .atomic)
    }

    private static func runSips(arguments: [String], errorDomain: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
            process.arguments = arguments

            let stderrPipe = Pipe()
            process.standardError = stderrPipe

            process.terminationHandler = { proc in
                let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrText = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else if !stderrText.isEmpty {
                    continuation.resume(throwing: NSError(
                        domain: errorDomain,
                        code: Int(proc.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: stderrText]
                    ))
                } else {
                    continuation.resume(throwing: NSError(
                        domain: errorDomain,
                        code: Int(proc.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: "sips exited with code \(proc.terminationStatus)."]
                    ))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func trackPendingEdit(_ value: String, for tag: EditableTag, source: StagedEditSource) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedURLs = selectedFileURLs
        guard !selectedURLs.isEmpty else { return }

        for fileURL in selectedURLs {
            let savedValue: String? = {
                guard let snapshot = availableSnapshot(for: fileURL) else { return nil }
                return normalizedDisplayValue(snapshot, for: tag)
            }()

            if let savedValue, savedValue == trimmed {
                pendingEditsByFile[fileURL]?[tag] = nil
            } else if savedValue == nil, trimmed.isEmpty {
                pendingEditsByFile[fileURL]?[tag] = nil
            } else {
                var map = pendingEditsByFile[fileURL] ?? [:]
                map[tag] = StagedEditRecord(value: trimmed, source: source, updatedAt: Date())
                pendingEditsByFile[fileURL] = map
            }

            if pendingEditsByFile[fileURL]?.isEmpty == true {
                pendingEditsByFile[fileURL] = nil
            }
        }
    }

    func stageEdit(_ value: String, for tag: EditableTag, fileURLs: [URL], source: StagedEditSource) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fileURLs.isEmpty else { return }

        for fileURL in fileURLs {
            let savedValue: String? = {
                guard let snapshot = availableSnapshot(for: fileURL) else { return nil }
                return normalizedDisplayValue(snapshot, for: tag)
            }()

            if let savedValue, savedValue == trimmed {
                pendingEditsByFile[fileURL]?[tag] = nil
            } else if savedValue == nil, trimmed.isEmpty {
                pendingEditsByFile[fileURL]?[tag] = nil
            } else {
                var map = pendingEditsByFile[fileURL] ?? [:]
                map[tag] = StagedEditRecord(value: trimmed, source: source, updatedAt: Date())
                pendingEditsByFile[fileURL] = map
            }

            if pendingEditsByFile[fileURL]?.isEmpty == true {
                pendingEditsByFile[fileURL] = nil
            }
        }
    }

    func selectFile(_ fileURL: URL, modifiers: NSEvent.ModifierFlags, in orderedItems: [BrowserItem]) {
        let commandPressed = modifiers.contains(.command)
        let shiftPressed = modifiers.contains(.shift)
        let previousSelection = selectedFileURLs

        if shiftPressed {
            applyRangeSelection(to: fileURL, additive: commandPressed, in: orderedItems)
        } else if commandPressed {
            if selectedFileURLs.contains(fileURL) {
                selectedFileURLs.remove(fileURL)
            } else {
                selectedFileURLs.insert(fileURL)
            }
            selectionAnchorURL = fileURL
            selectionFocusURL = fileURL
        } else {
            selectedFileURLs = [fileURL]
            selectionAnchorURL = fileURL
            selectionFocusURL = fileURL
        }

        guard selectedFileURLs != previousSelection else { return }
        selectionChanged()
    }

    private func toggleSelection(for fileURL: URL, additive: Bool) {
        var modifiers = NSEvent.ModifierFlags()
        if additive {
            modifiers.insert(.command)
        }
        selectFile(fileURL, modifiers: modifiers, in: filteredBrowserItems)
    }

    func clearSelection() {
        guard !selectedFileURLs.isEmpty else { return }
        selectedFileURLs.removeAll()
        selectionAnchorURL = nil
        selectionFocusURL = nil
        selectionChanged()
    }

    func setSelectionFromList(_ urls: Set<URL>, focusedURL: URL?) {
        guard urls != selectedFileURLs else { return }
        selectedFileURLs = urls

        if urls.isEmpty {
            selectionAnchorURL = nil
            selectionFocusURL = nil
        } else if let focusedURL, urls.contains(focusedURL) {
            if urls.count == 1 {
                selectionAnchorURL = focusedURL
            } else if let anchor = selectionAnchorURL {
                if !urls.contains(anchor) {
                    selectionAnchorURL = focusedURL
                }
            } else {
                selectionAnchorURL = focusedURL
            }
            selectionFocusURL = focusedURL
        } else if urls.count == 1, let only = urls.first {
            selectionAnchorURL = only
            selectionFocusURL = only
        } else {
            let fallback = urls.sorted(by: { $0.path < $1.path }).first
            if let anchor = selectionAnchorURL, !urls.contains(anchor) {
                selectionAnchorURL = fallback
            } else if selectionAnchorURL == nil {
                selectionAnchorURL = fallback
            }
            if let focus = selectionFocusURL, !urls.contains(focus) {
                selectionFocusURL = fallback
            } else if selectionFocusURL == nil {
                selectionFocusURL = fallback
            }
        }

        selectionChanged()
    }

    func moveSelectionInList(direction: SharedUI.MoveCommandDirection, extendingSelection: Bool = false) {
        let items = filteredBrowserItems
        guard !items.isEmpty else { return }

        let delta: Int
        switch direction {
        case .up:
            delta = -1
        case .down:
            delta = 1
        case .left, .right:
            return
        }

        if extendingSelection {
            moveRangeSelection(in: items, delta: delta)
        } else {
            moveSingleSelection(in: items, delta: delta)
        }
    }

    func moveSelectionInGallery(direction: SharedUI.MoveCommandDirection, extendingSelection: Bool = false) {
        let items = filteredBrowserItems
        guard !items.isEmpty else { return }

        let delta: Int
        switch direction {
        case .left:
            delta = -1
        case .right:
            delta = 1
        case .up:
            delta = -galleryColumnCount
        case .down:
            delta = galleryColumnCount
        }

        if extendingSelection {
            moveRangeSelection(in: items, delta: delta)
        } else {
            moveSingleSelection(in: items, delta: delta)
        }
    }

    func isInspectorSectionCollapsed(_ section: String) -> Bool {
        collapsedInspectorSections.contains(section)
    }

    func toggleInspectorSection(_ section: String) {
        if collapsedInspectorSections.contains(section) {
            collapsedInspectorSections.remove(section)
        } else {
            collapsedInspectorSections.insert(section)
        }
    }

    func isSelected(_ fileURL: URL) -> Bool {
        selectedFileURLs.contains(fileURL)
    }

    func selectAllFilteredFiles() {
        let items = filteredBrowserItems
        guard !items.isEmpty else {
            clearSelection()
            return
        }

        let nextSelection = Set(items.map(\.url))
        guard nextSelection != selectedFileURLs else { return }
        selectedFileURLs = nextSelection
        selectionAnchorURL = items.first?.url
        selectionFocusURL = items.last?.url
        selectionChanged()
    }

    private func moveSingleSelection(in items: [BrowserItem], delta: Int) {
        let currentIndex = currentSelectionIndex(in: items)
        let targetIndex: Int

        if let currentIndex {
            targetIndex = min(max(currentIndex + delta, 0), items.count - 1)
        } else if delta >= 0 {
            targetIndex = 0
        } else {
            targetIndex = items.count - 1
        }

        let nextURL = items[targetIndex].url
        let nextSelection: Set<URL> = [nextURL]
        guard selectedFileURLs != nextSelection else { return }

        selectedFileURLs = nextSelection
        selectionAnchorURL = nextURL
        selectionFocusURL = nextURL
        selectionChanged()
    }

    func currentSelectionIndex(in items: [BrowserItem]) -> Int? {
        for (index, item) in items.enumerated() {
            if selectedFileURLs.contains(item.url) {
                return index
            }
        }
        return nil
    }

    private func applyRangeSelection(to fileURL: URL, additive: Bool, in items: [BrowserItem]) {
        guard let targetIndex = items.firstIndex(where: { $0.url == fileURL }) else {
            selectedFileURLs = [fileURL]
            selectionAnchorURL = fileURL
            selectionFocusURL = fileURL
            return
        }

        let anchorURL = selectionAnchorURL
            ?? items.first(where: { selectedFileURLs.contains($0.url) })?.url
            ?? fileURL

        guard let anchorIndex = items.firstIndex(where: { $0.url == anchorURL }) else {
            selectedFileURLs = [fileURL]
            selectionAnchorURL = fileURL
            selectionFocusURL = fileURL
            return
        }

        let lower = min(anchorIndex, targetIndex)
        let upper = max(anchorIndex, targetIndex)
        let rangeSelection = Set(items[lower ... upper].map(\.url))

        if additive {
            selectedFileURLs.formUnion(rangeSelection)
        } else {
            selectedFileURLs = rangeSelection
        }

        selectionAnchorURL = anchorURL
        selectionFocusURL = fileURL
    }

    private func moveRangeSelection(in items: [BrowserItem], delta: Int) {
        guard delta != 0 else { return }

        let anchorURL = selectionAnchorURL
            ?? items.first(where: { selectedFileURLs.contains($0.url) })?.url
            ?? items.first?.url
        guard let anchorURL else { return }
        guard let anchorIndex = items.firstIndex(where: { $0.url == anchorURL }) else { return }

        let focusIndex: Int
        if let focusURL = selectionFocusURL,
           let index = items.firstIndex(where: { $0.url == focusURL }) {
            focusIndex = index
        } else {
            let selectedIndexes = items.enumerated().compactMap { selectedFileURLs.contains($0.element.url) ? $0.offset : nil }
            if let edge = (delta > 0 ? selectedIndexes.max() : selectedIndexes.min()) {
                focusIndex = edge
            } else {
                focusIndex = anchorIndex
            }
        }

        let targetIndex = min(max(focusIndex + delta, 0), items.count - 1)
        let lower = min(anchorIndex, targetIndex)
        let upper = max(anchorIndex, targetIndex)
        let nextSelection = Set(items[lower ... upper].map(\.url))
        let targetURL = items[targetIndex].url

        guard selectedFileURLs != nextSelection || selectionFocusURL != targetURL else { return }

        selectedFileURLs = nextSelection
        selectionAnchorURL = anchorURL
        selectionFocusURL = targetURL
        selectionChanged()
    }

    func placeholderForTag(_ tag: EditableTag) -> String {
        // If any selected file has this tag staged to empty, do not show baseline
        // placeholder text from disk; that obscures the fact that clear is staged.
        let hasStagedClear = selectedFileURLs.contains { url in
            guard let stagedValue = pendingEditsByFile[url]?[tag]?.value else { return false }
            return stagedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if hasStagedClear {
            return ""
        }

        if let baseline = baselineValues[tag] {
            return baseline ?? "Multiple values"
        }

        return ""
    }

}
