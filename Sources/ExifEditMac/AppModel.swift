import AppKit
import ExifEditCore
import Foundation
import Quartz
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    private static let galleryColumnRange = 2 ... 9

    enum BrowserViewMode: String, CaseIterable, Identifiable {
        case gallery
        case list

        var id: String { rawValue }
    }

    enum SidebarKind: Hashable {
        case recent
        case folder(URL)
    }

    enum BrowserSort: String, CaseIterable, Identifiable {
        case name
        case created
        case size
        case kind

        var id: String { rawValue }
    }

    struct SidebarItem: Identifiable, Hashable {
        let id: String
        let title: String
        let kind: SidebarKind
    }

    struct BrowserItem: Identifiable, Hashable {
        var id: URL { url }
        let url: URL
        let name: String
        let modifiedAt: Date?
        let createdAt: Date?
        let sizeBytes: Int?
        let kind: String?
    }

    struct EditableTag: Hashable, Identifiable {
        let id: String
        let namespace: MetadataNamespace
        let key: String
        let label: String
        let section: String

        static let common: [EditableTag] = [
            .init(id: "exif-make", namespace: .exif, key: "Make", label: "Make", section: "Camera"),
            .init(id: "exif-model", namespace: .exif, key: "Model", label: "Model", section: "Camera"),
            .init(id: "exif-serial", namespace: .exif, key: "SerialNumber", label: "Serial", section: "Camera"),
            .init(id: "exif-lens", namespace: .exif, key: "LensModel", label: "Lens", section: "Camera"),
            .init(id: "exif-aperture", namespace: .exif, key: "FNumber", label: "Aperture", section: "Capture"),
            .init(id: "exif-shutter", namespace: .exif, key: "ExposureTime", label: "Shutter (Exposure Time)", section: "Capture"),
            .init(id: "exif-iso", namespace: .exif, key: "ISO", label: "ISO", section: "Capture"),
            .init(id: "exif-focal", namespace: .exif, key: "FocalLength", label: "Focal Length", section: "Capture"),
            .init(id: "exif-exposure-program", namespace: .exif, key: "ExposureProgram", label: "Exposure Program", section: "Capture"),
            .init(id: "exif-flash", namespace: .exif, key: "Flash", label: "Flash", section: "Capture"),
            .init(id: "exif-metering-mode", namespace: .exif, key: "MeteringMode", label: "Metering Mode", section: "Capture"),
            .init(id: "datetime-modified", namespace: .exif, key: "ModifyDate", label: "Modified", section: "Date and Time"),
            .init(id: "datetime-digitized", namespace: .exif, key: "DateTimeDigitized", label: "Digitised", section: "Date and Time"),
            .init(id: "datetime-created", namespace: .exif, key: "DateTimeOriginal", label: "Created", section: "Date and Time"),
            .init(id: "exif-gps-lat", namespace: .exif, key: "GPSLatitude", label: "GPS Latitude", section: "Location"),
            .init(id: "exif-gps-lon", namespace: .exif, key: "GPSLongitude", label: "GPS Longitude", section: "Location"),
            .init(id: "exif-gps-alt", namespace: .exif, key: "GPSAltitude", label: "Altitude", section: "Location"),
            .init(id: "exif-gps-direction", namespace: .exif, key: "GPSImgDirection", label: "Direction", section: "Location"),
            .init(id: "xmp-title", namespace: .xmp, key: "Title", label: "Title", section: "Descriptive"),
            .init(id: "xmp-description", namespace: .xmp, key: "Description", label: "Description", section: "Descriptive"),
            .init(id: "xmp-subject", namespace: .xmp, key: "Subject", label: "Keywords", section: "Descriptive"),
            .init(id: "exif-artist", namespace: .exif, key: "Artist", label: "Artist", section: "Rights"),
            .init(id: "exif-copyright", namespace: .exif, key: "Copyright", label: "Copyright", section: "Rights"),
            .init(id: "xmp-creator", namespace: .xmp, key: "Creator", label: "Creator", section: "Rights"),
        ]
    }

    struct PickerOption: Identifiable, Hashable {
        var id: String { value }
        let value: String
        let label: String
    }

    @Published var sidebarItems: [SidebarItem] = [
        SidebarItem(id: "recent", title: "Recently Modified", kind: .recent)
    ]
    @Published var selectedSidebarID: String? = "recent"
    @Published var browserItems: [BrowserItem] = []
    @Published var browserSort: BrowserSort {
        didSet { UserDefaults.standard.set(browserSort.rawValue, forKey: Self.browserSortKey) }
    }
    @Published var selectedFileURLs: Set<URL> = []
    @Published var browserViewMode: BrowserViewMode {
        didSet { UserDefaults.standard.set(browserViewMode.rawValue, forKey: Self.browserViewModeKey) }
    }
    @Published var galleryGridLevel: Int {
        didSet { UserDefaults.standard.set(galleryGridLevel, forKey: Self.galleryGridLevelKey) }
    }
    @Published var metadataByFile: [URL: FileMetadataSnapshot] = [:]
    @Published var draftValues: [EditableTag: String] = [:]
    @Published var baselineValues: [EditableTag: String?] = [:]
    @Published var searchQuery = ""
    @Published var statusMessage = "Ready"
    @Published var lastResult: OperationResult?
    @Published var isDebugMetadataPresented = false
    @Published var exifToolTraces: [ExifToolInvocationTrace] = []
    @Published var collapsedInspectorSections: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(collapsedInspectorSections), forKey: Self.collapsedInspectorSectionsKey)
        }
    }

    @Published var sidebarWidth: CGFloat {
        didSet { UserDefaults.standard.set(sidebarWidth, forKey: Self.sidebarWidthKey) }
    }
    @Published var inspectorWidth: CGFloat {
        didSet { UserDefaults.standard.set(inspectorWidth, forKey: Self.inspectorWidthKey) }
    }

    private var quickLookSourceFrames: [URL: NSRect] = [:]
    private var quickLookTransitionImages: [URL: NSImage] = [:]

    private let engine: ExifEditEngine
    private var lastOperationID: UUID?
    private var statusResetTask: Task<Void, Never>?

    private static let sidebarWidthKey = "ui.sidebar.width"
    private static let inspectorWidthKey = "ui.inspector.width"
    private static let browserViewModeKey = "ui.browser.view.mode"
    private static let browserSortKey = "ui.browser.sort"
    private static let galleryGridLevelKey = "ui.gallery.grid.level"
    private static let galleryZoomKey = "ui.gallery.zoom"
    private static let collapsedInspectorSectionsKey = "ui.inspector.collapsed.sections"

    var galleryColumnCount: Int {
        galleryGridLevel
    }

    var canIncreaseGalleryZoom: Bool {
        galleryGridLevel > Self.galleryColumnRange.lowerBound
    }

    var canDecreaseGalleryZoom: Bool {
        galleryGridLevel < Self.galleryColumnRange.upperBound
    }

    init() {
        sidebarWidth = UserDefaults.standard.object(forKey: Self.sidebarWidthKey) as? CGFloat ?? 220
        inspectorWidth = UserDefaults.standard.object(forKey: Self.inspectorWidthKey) as? CGFloat ?? 500
        browserViewMode = BrowserViewMode(
            rawValue: UserDefaults.standard.string(forKey: Self.browserViewModeKey) ?? ""
        ) ?? .gallery
        browserSort = BrowserSort(
            rawValue: UserDefaults.standard.string(forKey: Self.browserSortKey) ?? ""
        ) ?? .name
        let storedLevel = UserDefaults.standard.integer(forKey: Self.galleryGridLevelKey)
        if storedLevel == 0 {
            // One-time fallback from legacy floating zoom persistence.
            let legacyZoom = UserDefaults.standard.double(forKey: Self.galleryZoomKey)
            if legacyZoom > 0 {
                galleryGridLevel = Self.columnCount(forLegacyZoom: CGFloat(legacyZoom))
            } else {
                galleryGridLevel = 4
            }
        } else {
            galleryGridLevel = min(max(storedLevel, Self.galleryColumnRange.lowerBound), Self.galleryColumnRange.upperBound)
        }

        let service: ExifToolServiceProtocol
        if let live = try? ExifToolService() {
            service = live
            statusMessage = "Ready"
        } else {
            service = UnavailableExifToolService()
            statusMessage = "exiftool not found. Install exiftool to edit metadata."
        }

        engine = ExifEditEngine(exifToolService: service)

        let storedCollapsed = UserDefaults.standard.stringArray(forKey: Self.collapsedInspectorSectionsKey) ?? []
        collapsedInspectorSections = Set(storedCollapsed)

        _ = NotificationCenter.default.addObserver(
            forName: .exifToolInvocationDidFinish,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let trace = notification.userInfo?["trace"] as? ExifToolInvocationTrace else { return }
            Task { @MainActor [weak self] in
                self?.appendTrace(trace)
            }
        }
    }

    func increaseGalleryZoom() {
        galleryGridLevel = max(galleryGridLevel - 1, Self.galleryColumnRange.lowerBound)
    }

    func decreaseGalleryZoom() {
        galleryGridLevel = min(galleryGridLevel + 1, Self.galleryColumnRange.upperBound)
    }

    func adjustGalleryGridLevel(by delta: Int) {
        guard delta != 0 else { return }
        let next = galleryGridLevel + delta
        galleryGridLevel = min(max(next, Self.galleryColumnRange.lowerBound), Self.galleryColumnRange.upperBound)
    }

    func openInDefaultApp(_ fileURL: URL) {
        let didOpen = NSWorkspace.shared.open(fileURL)
        if !didOpen {
            statusMessage = "Could not open \(fileURL.lastPathComponent) in the default app."
        }
    }

    func openSelectedInDefaultApp() {
        guard let url = selectedFileURLs.sorted(by: { $0.path < $1.path }).first else {
            statusMessage = "Select a file to open in the default app."
            return
        }
        openInDefaultApp(url)
    }

    func quickLookSelection() {
        let visibleItems = filteredBrowserItems
        let orderedItems = visibleItems.map(\.url)

        guard !orderedItems.isEmpty else {
            statusMessage = "No files available to preview."
            return
        }

        let focusedURL: URL?
        if let index = currentSelectionIndex(in: visibleItems), visibleItems.indices.contains(index) {
            focusedURL = visibleItems[index].url
        } else {
            focusedURL = orderedItems.first
        }

        QuickLookPreviewController.shared.present(urls: orderedItems, focusedURL: focusedURL, model: self)
    }

    func setQuickLookSourceFrame(for fileURL: URL, rectOnScreen: NSRect) {
        quickLookSourceFrames[fileURL] = rectOnScreen
    }

    func setQuickLookTransitionImage(for fileURL: URL, image: NSImage?) {
        if let image {
            quickLookTransitionImages[fileURL] = image
        } else {
            quickLookTransitionImages.removeValue(forKey: fileURL)
        }
    }

    func quickLookSourceFrame(for fileURL: URL) -> NSRect? {
        quickLookSourceFrames[fileURL]
    }

    func quickLookTransitionImage(for fileURL: URL) -> NSImage? {
        quickLookTransitionImages[fileURL]
    }

    func setSelectionFromQuickLook(_ fileURL: URL) {
        let selection: Set<URL> = [fileURL]
        guard selectedFileURLs != selection else { return }
        selectedFileURLs = selection
        selectionChanged()
    }

    func revealSelectionInFinder() {
        let urls = selectedFileURLs.sorted(by: { $0.path < $1.path })
        guard !urls.isEmpty else {
            statusMessage = "Select one or more files to reveal in Finder."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    private static func columnCount(forLegacyZoom zoom: CGFloat) -> Int {
        let legacyZoomMin = CGFloat(0.55)
        let legacyZoomMax = CGFloat(3.0)
        let clampedZoom = min(max(zoom, legacyZoomMin), legacyZoomMax)
        let normalized = (clampedZoom - legacyZoomMin) / (legacyZoomMax - legacyZoomMin)
        let reversed = 1 - normalized
        let span = CGFloat(Self.galleryColumnRange.upperBound - Self.galleryColumnRange.lowerBound)
        let raw = CGFloat(Self.galleryColumnRange.lowerBound) + reversed * span
        return Int(raw.rounded())
    }

    func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"

        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { [weak self] response in
                guard response == .OK, let folderURL = panel.url else { return }
                Task { @MainActor in
                    self?.didChooseFolder(folderURL)
                }
            }
            return
        }

        guard panel.runModal() == .OK, let folderURL = panel.url else { return }
        didChooseFolder(folderURL)
    }

    func refresh() {
        if let item = selectedSidebarItem {
            loadFiles(for: item.kind)
        }

        Task {
            await loadMetadataForSelection()
        }
    }

    func selectSidebar(id: String?) {
        selectedSidebarID = id
        guard let item = selectedSidebarItem else { return }
        loadFiles(for: item.kind)
    }

    func applyChanges() {
        let files = Array(selectedFileURLs)
        guard !files.isEmpty else {
            statusMessage = "Select at least one file to apply changes."
            return
        }

        let patches = buildPatches()
        guard !patches.isEmpty else {
            statusMessage = "No metadata changes to apply."
            return
        }

        Task {
            let operation = EditOperation(targetFiles: files, changes: patches)

            do {
                let result = try await engine.apply(operation: operation)
                lastOperationID = result.operationID
                lastResult = result
                if result.failed.isEmpty {
                    setStatusMessage(
                        "Applied changes to \(result.succeeded.count) file(s).",
                        autoClearAfterSuccess: true
                    )
                } else if result.succeeded.isEmpty {
                    let firstError = result.failed.first?.message ?? "Unknown write error."
                    statusMessage = "Failed to apply metadata changes. \(firstError)"
                } else {
                    let firstError = result.failed.first?.message ?? "Unknown write error."
                    statusMessage = "Applied to \(result.succeeded.count) file(s), failed on \(result.failed.count). \(firstError)"
                }
                await loadMetadataForSelection()
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    func restoreLastOperation() {
        guard let operationID = lastOperationID else {
            statusMessage = "No previous operation to restore."
            return
        }

        Task {
            do {
                let result = try await engine.restore(operationID: operationID)
                lastResult = result
                setStatusMessage(
                    "Restored \(result.succeeded.count) file(s).",
                    autoClearAfterSuccess: true
                )
                await loadMetadataForSelection()
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    func valueForTag(_ tag: EditableTag) -> String {
        draftValues[tag] ?? ""
    }

    func updateValue(_ value: String, for tag: EditableTag) {
        draftValues[tag] = value
    }

    func isDateTimeTag(_ tag: EditableTag) -> Bool {
        switch tag.id {
        case "datetime-modified", "datetime-digitized", "datetime-created":
            return true
        default:
            return false
        }
    }

    func dateValueForTag(_ tag: EditableTag) -> Date? {
        guard isDateTimeTag(tag) else { return nil }
        let raw = valueForTag(tag).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        return parseDate(raw)
    }

    func updateDateValue(_ date: Date, for tag: EditableTag) {
        guard isDateTimeTag(tag) else { return }
        draftValues[tag] = Self.exifDateFormatter.string(from: date)
    }

    func listColumnValue(for fileURL: URL, columnID: String, fallbackItem: BrowserItem?) -> String {
        switch columnID {
        case "name":
            return fallbackItem?.name ?? fileURL.lastPathComponent
        case "created":
            if let date = fallbackItem?.createdAt {
                return Self.listDateFormatter.string(from: date)
            }
            return "—"
        case "size":
            if let size = fallbackItem?.sizeBytes, size >= 0 {
                return Self.byteCountFormatter.string(fromByteCount: Int64(size))
            }
            return "—"
        case "kind":
            if let kind = fallbackItem?.kind, !kind.isEmpty {
                return kind
            }
            return "—"
        default:
            return "—"
        }
    }

    func pickerOptions(for tag: EditableTag) -> [PickerOption]? {
        let currentValue = valueForTag(tag).trimmingCharacters(in: .whitespacesAndNewlines)
        let base: [PickerOption]

        switch tag.id {
        case "exif-exposure-program":
            base = [
                .init(value: "0", label: "Not Defined"),
                .init(value: "1", label: "Manual"),
                .init(value: "2", label: "Program AE"),
                .init(value: "3", label: "Aperture-priority AE"),
                .init(value: "4", label: "Shutter-priority AE"),
                .init(value: "5", label: "Creative Program"),
                .init(value: "6", label: "Action Program"),
                .init(value: "7", label: "Portrait Mode"),
                .init(value: "8", label: "Landscape Mode")
            ]
        case "exif-flash":
            base = [
                .init(value: "0", label: "No Flash"),
                .init(value: "1", label: "Fired"),
                .init(value: "5", label: "Fired, Return Not Detected"),
                .init(value: "7", label: "Fired, Return Detected"),
                .init(value: "9", label: "On, Did Not Fire"),
                .init(value: "13", label: "On, Return Not Detected"),
                .init(value: "15", label: "On, Return Detected"),
                .init(value: "16", label: "Off, Did Not Fire"),
                .init(value: "24", label: "Auto, Did Not Fire"),
                .init(value: "25", label: "Auto, Fired"),
                .init(value: "29", label: "Auto, Fired, Return Not Detected"),
                .init(value: "31", label: "Auto, Fired, Return Detected"),
                .init(value: "32", label: "No Flash Function"),
                .init(value: "65", label: "Fired, Red-eye Reduction"),
                .init(value: "69", label: "Fired, Red-eye, Return Not Detected"),
                .init(value: "71", label: "Fired, Red-eye, Return Detected"),
                .init(value: "73", label: "On, Red-eye, Did Not Fire"),
                .init(value: "77", label: "On, Red-eye, Return Not Detected"),
                .init(value: "79", label: "On, Red-eye, Return Detected"),
                .init(value: "89", label: "Auto, Fired, Red-eye"),
                .init(value: "93", label: "Auto, Fired, Red-eye, Return Not Detected"),
                .init(value: "95", label: "Auto, Fired, Red-eye, Return Detected")
            ]
        case "exif-metering-mode":
            base = [
                .init(value: "0", label: "Unknown"),
                .init(value: "1", label: "Average"),
                .init(value: "2", label: "Center-weighted Average"),
                .init(value: "3", label: "Spot"),
                .init(value: "4", label: "Multi-spot"),
                .init(value: "5", label: "Multi-segment"),
                .init(value: "6", label: "Partial"),
                .init(value: "255", label: "Other")
            ]
        default:
            return nil
        }

        var options = base
        if isMixedValue(for: tag) {
            options.insert(.init(value: "", label: "Multiple Values"), at: 0)
        } else if currentValue.isEmpty {
            options.insert(.init(value: "", label: "Not Set"), at: 0)
        } else if !base.contains(where: { $0.value == currentValue }) {
            options.insert(.init(value: currentValue, label: "Unknown (\(currentValue))"), at: 0)
        }

        return options
    }

    func isMixedValue(for tag: EditableTag) -> Bool {
        baselineValues[tag] == nil
    }

    func toggleSelection(for fileURL: URL, additive: Bool) {
        let previousSelection = selectedFileURLs

        if additive {
            if selectedFileURLs.contains(fileURL) {
                selectedFileURLs.remove(fileURL)
            } else {
                selectedFileURLs.insert(fileURL)
            }
        } else {
            selectedFileURLs = [fileURL]
        }

        guard selectedFileURLs != previousSelection else { return }
        selectionChanged()
    }

    func clearSelection() {
        guard !selectedFileURLs.isEmpty else { return }
        selectedFileURLs.removeAll()
        selectionChanged()
    }

    func moveSelectionInList(direction: MoveCommandDirection) {
        let items = filteredBrowserItems
        guard !items.isEmpty else { return }

        let delta: Int
        switch direction {
        case .up:
            delta = -1
        case .down:
            delta = 1
        default:
            return
        }

        moveSingleSelection(in: items, delta: delta)
    }

    func moveSelectionInGallery(direction: MoveCommandDirection) {
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
        default:
            return
        }

        moveSingleSelection(in: items, delta: delta)
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
        selectionChanged()
    }

    private func currentSelectionIndex(in items: [BrowserItem]) -> Int? {
        for (index, item) in items.enumerated() {
            if selectedFileURLs.contains(item.url) {
                return index
            }
        }
        return nil
    }

    func placeholderForTag(_ tag: EditableTag) -> String {
        if let baseline = baselineValues[tag] {
            return baseline ?? "Multiple values"
        }

        return ""
    }

    var filteredBrowserItems: [BrowserItem] {
        let baseItems: [BrowserItem]
        if searchQuery.isEmpty {
            baseItems = browserItems
        } else {
            let query = searchQuery.lowercased()
            baseItems = browserItems.filter { $0.name.lowercased().contains(query) }
        }
        return sortBrowserItems(baseItems)
    }

    var selectedSnapshots: [FileMetadataSnapshot] {
        selectedFileURLs.compactMap { metadataByFile[$0] }
    }

    var groupedEditableTags: [(section: String, tags: [EditableTag])] {
        var result: [(section: String, tags: [EditableTag])] = []
        for tag in EditableTag.common {
            if let index = result.firstIndex(where: { $0.section == tag.section }) {
                result[index].tags.append(tag)
            } else {
                result.append((section: tag.section, tags: [tag]))
            }
        }
        return result
    }

    var metadataDebugText: String {
        guard !selectedFileURLs.isEmpty else {
            return "No files selected.\n\nSelect one or more files to inspect raw parsed metadata."
        }

        let sortedURLs = selectedFileURLs.sorted { $0.path < $1.path }
        var lines: [String] = []

        for url in sortedURLs {
            lines.append("=== \(url.path) ===")

            guard let snapshot = metadataByFile[url] else {
                lines.append("(metadata not loaded yet)")
                lines.append("")
                continue
            }

            if !snapshot.diagnostics.isEmpty {
                lines.append("Diagnostics:")
                snapshot.diagnostics.forEach { lines.append("- \($0)") }
            }

            for field in snapshot.fields.sorted(by: {
                if $0.namespace.rawValue == $1.namespace.rawValue {
                    return $0.key < $1.key
                }
                return $0.namespace.rawValue < $1.namespace.rawValue
            }) {
                lines.append("[\(field.namespace.rawValue)] \(field.key) = \(field.value)")
            }

            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    var exifToolTraceText: String {
        guard !exifToolTraces.isEmpty else {
            return "No exiftool commands captured yet.\n\nRead/write metadata to populate this log."
        }

        return exifToolTraces
            .map { trace in
                var lines: [String] = []
                lines.append("[\(Self.logTimestampFormatter.string(from: trace.timestamp))] \(trace.kind.rawValue.uppercased()) \(trace.succeeded ? "OK" : "FAIL")")
                if let filePath = trace.filePath {
                    lines.append("File: \(filePath)")
                }
                lines.append("Duration: \(String(format: "%.3fs", trace.duration))")
                lines.append("Command:")
                lines.append(shellJoinedCommand(executable: trace.executablePath, arguments: trace.arguments))
                if !trace.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lines.append("stdout:")
                    lines.append(trace.stdout)
                }
                if !trace.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lines.append("stderr:")
                    lines.append(trace.stderr)
                }
                return lines.joined(separator: "\n")
            }
            .joined(separator: "\n\n----------------------------------------\n\n")
    }

    func clearExifToolTraceLog() {
        exifToolTraces.removeAll()
    }

    var selectedSidebarItem: SidebarItem? {
        guard let selectedSidebarID else { return nil }
        return sidebarItems.first { $0.id == selectedSidebarID }
    }

    private func addFolderToSidebar(_ url: URL) {
        let id = "folder::\(url.path)"
        if !sidebarItems.contains(where: { $0.id == id }) {
            sidebarItems.append(
                SidebarItem(id: id, title: url.lastPathComponent, kind: .folder(url))
            )
        }
        selectedSidebarID = id
    }

    private func didChooseFolder(_ folderURL: URL) {
        addFolderToSidebar(folderURL)
        loadFiles(for: .folder(folderURL))
    }

    private func loadFiles(for kind: SidebarKind) {
        let urls: [URL]

        switch kind {
        case .recent:
            urls = loadRecentFiles()
        case let .folder(folder):
            urls = enumerateImages(in: folder)
        }

        browserItems = urls.map {
            let resourceValues = try? $0.resourceValues(
                forKeys: [.contentModificationDateKey, .creationDateKey, .fileSizeKey, .localizedTypeDescriptionKey]
            )
            return BrowserItem(
                url: $0,
                name: $0.lastPathComponent,
                modifiedAt: resourceValues?.contentModificationDate,
                createdAt: resourceValues?.creationDate,
                sizeBytes: resourceValues?.fileSize,
                kind: resourceValues?.localizedTypeDescription
            )
        }

        selectedFileURLs = []
        draftValues = [:]
        baselineValues = [:]
        metadataByFile = [:]
    }

    private func sortBrowserItems(_ items: [BrowserItem]) -> [BrowserItem] {
        items.sorted { lhs, rhs in
            switch browserSort {
            case .name:
                let byName = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if byName != .orderedSame { return byName == .orderedAscending }
                return lhs.url.path < rhs.url.path
            case .created:
                switch (lhs.createdAt, rhs.createdAt) {
                case let (l?, r?):
                    if l != r { return l < r }
                case (nil, nil):
                    break
                case (nil, _?):
                    return false
                case (_?, nil):
                    return true
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            case .size:
                switch (lhs.sizeBytes, rhs.sizeBytes) {
                case let (l?, r?):
                    if l != r { return l < r }
                case (nil, nil):
                    break
                case (nil, _?):
                    return false
                case (_?, nil):
                    return true
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            case .kind:
                let leftKind = lhs.kind ?? ""
                let rightKind = rhs.kind ?? ""
                let byKind = leftKind.localizedCaseInsensitiveCompare(rightKind)
                if byKind != .orderedSame { return byKind == .orderedAscending }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }

    private func loadRecentFiles() -> [URL] {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        let all = enumerateImages(in: pictures)

        return all
            .map { url in
                (
                    url,
                    (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                )
            }
            .sorted { $0.1 > $1.1 }
            .prefix(500)
            .map(\.0)
    }

    private func enumerateImages(in folder: URL) -> [URL] {
        let allowedExtensions = Set([
            "jpg", "jpeg", "tif", "tiff", "png", "heic", "heif", "dng", "arw", "cr2", "cr3", "nef", "orf", "rw2", "raf"
        ])

        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var files: [URL] = []

        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            guard allowedExtensions.contains(ext) else { continue }
            files.append(url)
        }

        return files
    }

    private func buildPatches() -> [MetadataPatch] {
        var allPatches: [MetadataPatch] = []

        for tag in EditableTag.common {
            let current = draftValues[tag]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let baseline = baselineValues[tag] ?? nil

            // Mixed-value state initializes as blank; keep it untouched unless user enters a value.
            if baseline == nil, current.isEmpty {
                continue
            }
            if baseline == current {
                continue
            }

            let normalized = normalizedWriteValue(current, for: tag)
            allPatches.append(
                MetadataPatch(
                    key: tag.key,
                    namespace: tag.namespace,
                    newValue: normalized
                )
            )

            // Keep Photos-compatible descriptive metadata in sync.
            if tag.id == "xmp-description" {
                allPatches.append(
                    MetadataPatch(
                        key: "Caption-Abstract",
                        namespace: .iptc,
                        newValue: normalized
                    )
                )
            } else if tag.id == "xmp-title" {
                allPatches.append(
                    MetadataPatch(
                        key: "ObjectName",
                        namespace: .iptc,
                        newValue: normalized
                    )
                )
            }
        }

        return allPatches
    }

    private func normalizedWriteValue(_ value: String, for tag: EditableTag) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard tag.id == "exif-shutter" else { return trimmed }
        guard !trimmed.isEmpty else { return trimmed }

        if trimmed.contains("/") {
            let parts = trimmed.split(separator: "/", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2,
                  let numerator = Double(parts[0]),
                  let denominator = Double(parts[1]),
                  denominator != 0
            else {
                return trimmed
            }

            return Self.compactDecimalString(numerator / denominator)
        }

        if let decimal = Double(trimmed) {
            return Self.compactDecimalString(decimal)
        }

        return trimmed
    }

    private func value(for tag: EditableTag, in snapshot: FileMetadataSnapshot) -> String? {
        if tag.id == "exif-gps-lat" {
            return signedGPSValue(
                valueKey: "GPSLatitude",
                refKey: "GPSLatitudeRef",
                negativeRef: "S",
                snapshot: snapshot
            )
        }
        if tag.id == "exif-gps-lon" {
            return signedGPSValue(
                valueKey: "GPSLongitude",
                refKey: "GPSLongitudeRef",
                negativeRef: "W",
                snapshot: snapshot
            )
        }
        if tag.id == "xmp-description" {
            return prioritizedFieldValue(
                in: snapshot,
                candidates: [
                    (keys: ["Caption-Abstract", "CaptionAbstract"], namespaces: [.iptc]),
                    (keys: ["Description"], namespaces: [.xmp]),
                    (keys: ["Description"], namespaces: [.iptc])
                ]
            )
        }

        let candidateKeys: Set<String>
        let candidateNamespaces: Set<MetadataNamespace>

        switch tag.id {
        case "exif-make":
            candidateKeys = [tag.key, "CameraMake"]
            candidateNamespaces = [.exif, .xmp]
        case "exif-model":
            candidateKeys = [tag.key, "CameraModelName"]
            candidateNamespaces = [.exif, .xmp]
        case "exif-serial":
            candidateKeys = [tag.key, "CameraSerialNumber"]
            candidateNamespaces = [.exif, .xmp]
        case "exif-lens":
            candidateKeys = [tag.key, "Lens", "LensID"]
            candidateNamespaces = [.exif, .xmp]
        case "datetime-modified":
            candidateKeys = [tag.key, "ModifyDate", "FileModifyDate"]
            candidateNamespaces = [.exif, .xmp, .iptc]
        case "datetime-digitized":
            candidateKeys = [tag.key, "CreateDate"]
            candidateNamespaces = [.exif, .xmp]
        case "datetime-created":
            candidateKeys = [tag.key, "CreateDate"]
            candidateNamespaces = [.exif, .xmp, .iptc]
        case "exif-exposure-program":
            candidateKeys = [tag.key]
            candidateNamespaces = [.exif, .xmp]
        case "exif-flash":
            candidateKeys = [tag.key, "FlashFired", "FlashMode"]
            candidateNamespaces = [.exif, .xmp]
        case "exif-metering-mode":
            candidateKeys = [tag.key]
            candidateNamespaces = [.exif, .xmp]
        case "xmp-city":
            candidateKeys = [tag.key]
            candidateNamespaces = [.xmp, .iptc]
        case "xmp-country":
            candidateKeys = [tag.key, "Country-PrimaryLocationName", "CountryPrimaryLocationName"]
            candidateNamespaces = [.xmp, .iptc]
        case "xmp-state":
            candidateKeys = [tag.key, "Province-State", "ProvinceState"]
            candidateNamespaces = [.xmp, .iptc]
        case "xmp-title":
            candidateKeys = [tag.key, "ObjectName"]
            candidateNamespaces = [.xmp, .iptc]
        case "xmp-description":
            candidateKeys = [tag.key, "Caption-Abstract", "CaptionAbstract"]
            candidateNamespaces = [.xmp, .iptc]
        case "xmp-subject":
            candidateKeys = [tag.key, "Keywords"]
            candidateNamespaces = [.xmp, .iptc]
        case "xmp-creator":
            candidateKeys = [tag.key, "By-line", "By-lineTitle", "Byline", "BylineTitle"]
            candidateNamespaces = [.xmp, .iptc, .exif]
        default:
            candidateKeys = [tag.key]
            candidateNamespaces = [tag.namespace]
        }

        return snapshot.fields.first(where: { candidateKeys.contains($0.key) && candidateNamespaces.contains($0.namespace) })?.value
    }

    private func prioritizedFieldValue(
        in snapshot: FileMetadataSnapshot,
        candidates: [(keys: [String], namespaces: [MetadataNamespace])]
    ) -> String? {
        for candidate in candidates {
            let keySet = Set(candidate.keys)
            let namespaceSet = Set(candidate.namespaces)
            if let value = snapshot.fields.first(where: {
                keySet.contains($0.key) && namespaceSet.contains($0.namespace)
            })?.value,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return value
            }
        }
        return nil
    }

    private func signedGPSValue(
        valueKey: String,
        refKey: String,
        negativeRef: String,
        snapshot: FileMetadataSnapshot
    ) -> String? {
        let valueCandidateKeys: Set<String> = [valueKey]
        let valueNamespaces: Set<MetadataNamespace> = [.exif, .xmp]
        guard let rawValue = snapshot.fields.first(where: {
            valueCandidateKeys.contains($0.key) && valueNamespaces.contains($0.namespace)
        })?.value else {
            return nil
        }

        guard let parsed = parseCoordinateNumber(rawValue) else {
            return rawValue
        }

        let ref = snapshot.fields.first(where: { $0.key == refKey && $0.namespace == .exif })?.value
            ?? snapshot.fields.first(where: { $0.key == refKey && $0.namespace == .xmp })?.value

        let signed: Double
        if let ref, ref.uppercased().contains(negativeRef) {
            signed = -abs(parsed)
        } else {
            signed = parsed
        }

        return Self.compactDecimalString(signed)
    }

    private func parseCoordinateNumber(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let direct = Double(trimmed) {
            return direct
        }

        let ns = trimmed as NSString
        let regex = try? NSRegularExpression(pattern: "-?\\d+(?:\\.\\d+)?")
        let matches = regex?.matches(in: trimmed, range: NSRange(location: 0, length: ns.length)) ?? []
        let numbers: [Double] = matches.compactMap {
            Double(ns.substring(with: $0.range))
        }

        guard let first = numbers.first else { return nil }
        if numbers.count >= 3 {
            let degrees = abs(first)
            let minutes = abs(numbers[1])
            let seconds = abs(numbers[2])
            let composed = degrees + (minutes / 60) + (seconds / 3600)
            return first < 0 ? -composed : composed
        }
        return first
    }

    private func recalculateInspectorState() {
        let snapshots = selectedSnapshots

        guard !snapshots.isEmpty else {
            baselineValues = [:]
            draftValues = [:]
            return
        }

        var nextBaseline: [EditableTag: String?] = [:]
        var nextDraft: [EditableTag: String] = [:]

        for tag in EditableTag.common {
            let values = snapshots.map { normalizedDisplayValue($0, for: tag) }
            let unique = Set(values)

            if unique.count == 1 {
                let only = unique.first ?? ""
                nextBaseline[tag] = only
                nextDraft[tag] = only
            } else {
                nextBaseline[tag] = nil
                nextDraft[tag] = ""
            }
        }

        baselineValues = nextBaseline
        draftValues = nextDraft
    }

    private func normalizedDisplayValue(_ snapshot: FileMetadataSnapshot, for tag: EditableTag) -> String {
        guard let raw = value(for: tag, in: snapshot) else {
            return ""
        }

        if tag.id == "exif-shutter" {
            return formatExposureTime(raw)
        }
        if tag.id == "exif-exposure-program" || tag.id == "exif-flash" || tag.id == "exif-metering-mode" {
            return normalizeEnumRawValue(raw)
        }

        return raw
    }

    private func normalizeEnumRawValue(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let number = Double(trimmed), number.isFinite else { return trimmed }
        let rounded = number.rounded()
        if abs(number - rounded) < 0.000_001 {
            return String(Int(rounded))
        }
        return trimmed
    }

    private func formatExposureTime(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return raw }
        if trimmed.contains("/") { return trimmed }

        guard let value = Double(trimmed), value > 0 else { return raw }

        if value < 1 {
            let reciprocal = 1.0 / value
            let rounded = reciprocal.rounded()
            if abs(reciprocal - rounded) / max(reciprocal, 1) < 0.03 {
                return "1/\(Int(rounded))"
            }
        }

        let fraction = Self.approximateFraction(value, maxDenominator: 10_000)
        if fraction.denominator == 1 {
            return "\(fraction.numerator)"
        }
        return "\(fraction.numerator)/\(fraction.denominator)"
    }

    private static func approximateFraction(_ value: Double, maxDenominator: Int) -> (numerator: Int, denominator: Int) {
        var x = value
        var a = floor(x)
        var h1 = 1.0
        var k1 = 0.0
        var h = a
        var k = 1.0

        while x - a > 1e-10 && k < Double(maxDenominator) {
            x = 1.0 / (x - a)
            a = floor(x)
            let h2 = h1
            h1 = h
            let k2 = k1
            k1 = k
            h = a * h1 + h2
            k = a * k1 + k2
        }

        let numerator = max(1, Int(h.rounded()))
        let denominator = max(1, Int(k.rounded()))
        let divisor = Self.gcd(numerator, denominator)
        return (numerator / divisor, denominator / divisor)
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var x = abs(a)
        var y = abs(b)
        while y != 0 {
            let r = x % y
            x = y
            y = r
        }
        return max(1, x)
    }

    private static func compactDecimalString(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 8
        formatter.minimumFractionDigits = 0
        formatter.decimalSeparator = "."
        formatter.usesGroupingSeparator = false
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private func parseDate(_ raw: String) -> Date? {
        if let parsed = Self.exifDateFormatter.date(from: raw) {
            return parsed
        }
        if let parsed = Self.iso8601DateFormatter.date(from: raw) {
            return parsed
        }
        if let parsed = Self.fallbackDateFormatter.date(from: raw) {
            return parsed
        }
        return nil
    }

    private static let exifDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()

    private static let listDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    private static let fallbackDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static let iso8601DateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private func loadMetadataForSelection() async {
        let files = Array(selectedFileURLs)
        guard !files.isEmpty else {
            recalculateInspectorState()
            return
        }

        do {
            let snapshots = try await engine.readMetadata(files: files)
            var map = metadataByFile
            for snapshot in snapshots {
                map[snapshot.fileURL] = snapshot
            }
            metadataByFile = map
            recalculateInspectorState()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func selectionChanged() {
        Task {
            await loadMetadataForSelection()
        }
    }

    private func appendTrace(_ trace: ExifToolInvocationTrace) {
        exifToolTraces.append(trace)
        if exifToolTraces.count > 200 {
            exifToolTraces.removeFirst(exifToolTraces.count - 200)
        }
    }

    private func setStatusMessage(_ message: String, autoClearAfterSuccess: Bool) {
        statusResetTask?.cancel()
        statusResetTask = nil
        statusMessage = message

        guard autoClearAfterSuccess else { return }
        statusResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, self.statusMessage == message else { return }
            self.statusMessage = "Ready"
            self.statusResetTask = nil
        }
    }

    private func shellJoinedCommand(executable: String, arguments: [String]) -> String {
        let parts = [executable] + arguments
        return parts.map(Self.shellQuote).joined(separator: " ")
    }

    private static func shellQuote(_ value: String) -> String {
        if value.isEmpty { return "''" }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-=:"))
        if value.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
            return value
        }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static let logTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()
}

@MainActor
private final class QuickLookPreviewController: NSObject, @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    static let shared = QuickLookPreviewController()

    private var items: [NSURL] = []
    private weak var model: AppModel?
    private var panelObservation: NSKeyValueObservation?

    func present(urls: [URL], focusedURL: URL?, model: AppModel) {
        items = urls.map { $0 as NSURL }
        self.model = model
        guard !items.isEmpty, let panel = QLPreviewPanel.shared() else { return }

        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()

        if let focusedURL,
           let index = items.firstIndex(where: { ($0 as URL) == focusedURL }) {
            panel.currentPreviewItemIndex = index
        } else {
            panel.currentPreviewItemIndex = 0
        }
        syncSelection(forIndex: panel.currentPreviewItemIndex)

        panelObservation = panel.observe(\.currentPreviewItemIndex, options: [.new]) { [weak self] panel, _ in
            self?.syncSelection(forIndex: panel.currentPreviewItemIndex)
        }

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        items.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard items.indices.contains(index) else { return nil }
        return items[index]
    }

    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        guard let url = (item as? NSURL) as URL? ?? (item as? URL),
              let rect = model?.quickLookSourceFrame(for: url)
        else {
            return .zero
        }
        return rect
    }

    func previewPanel(_ panel: QLPreviewPanel!, transitionImageFor item: QLPreviewItem!, contentRect: UnsafeMutablePointer<NSRect>) -> Any! {
        guard let url = (item as? NSURL) as URL? ?? (item as? URL),
              let image = model?.quickLookTransitionImage(for: url)
        else {
            return nil
        }
        return image
    }

    func previewPanelWillClose(_ panel: QLPreviewPanel!) {
        panelObservation = nil
    }

    private func syncSelection(forIndex index: Int) {
        guard items.indices.contains(index) else { return }
        model?.setSelectionFromQuickLook(items[index] as URL)
    }
}

private struct UnavailableExifToolService: ExifToolServiceProtocol {
    func readMetadata(files _: [URL]) async throws -> [FileMetadataSnapshot] {
        throw ExifEditError.exifToolNotFound
    }

    func writeMetadata(operation: EditOperation) async -> OperationResult {
        OperationResult(
            operationID: operation.id,
            succeeded: [],
            failed: operation.targetFiles.map { FileError(fileURL: $0, message: ExifEditError.exifToolNotFound.localizedDescription) },
            backupLocation: nil,
            duration: 0
        )
    }
}
