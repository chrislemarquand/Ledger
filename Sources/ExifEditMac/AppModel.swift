import AppKit
import ExifEditCore
import Foundation
import ImageIO
import QuickLookThumbnailing
import Quartz
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    private static let galleryColumnRange = 2 ... 9

    enum BrowserViewMode: String, CaseIterable, Identifiable {
        case gallery
        case list

        var id: String { rawValue }
    }

    enum SidebarKind: Hashable {
        case recent24Hours
        case recent7Days
        case recent30Days
        case pictures
        case desktop
        case downloads
        case mountedVolume(URL)
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
        let section: String
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

    enum StagedEditSource: Hashable {
        case manual
        case preset(UUID)
        case gpx(URL)
        case csv(URL)
        case referenceFolder(URL)
    }

    struct StagedEditRecord: Hashable {
        let value: String
        let source: StagedEditSource
        let updatedAt: Date
    }

    struct EditSessionSnapshot {
        let tag: EditableTag
        let draftValue: String
        let selectedFileURLs: [URL]
        let stagedValuesByFile: [URL: StagedEditRecord]
    }

    struct ImportConflict: Identifiable, Hashable {
        let id = UUID()
        let fileURL: URL
        let tag: EditableTag
        let existing: StagedEditRecord
        let incomingValue: String
        let incomingSource: StagedEditSource
    }

    enum ImportConflictChoice: Hashable {
        case keepExisting
        case replaceWithIncoming
    }

    struct ImportApplyResult: Hashable {
        let affectedFiles: Int
        let affectedFields: Int
        let skippedUnmatched: Int
        let conflictsResolved: Int
    }

    private struct PendingEditState: Equatable {
        let pendingEditsByFile: [URL: [EditableTag: StagedEditRecord]]
    }

    @Published var sidebarItems: [SidebarItem] = []
    @Published var selectedSidebarID: String? = "recent-7d"
    @Published var isSidebarCollapsed = false
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
    @Published var presets: [MetadataPreset] = []
    @Published var selectedPresetID: UUID? {
        didSet {
            UserDefaults.standard.set(selectedPresetID?.uuidString, forKey: Self.selectedPresetIDKey)
        }
    }
    @Published var activePresetEditor: PresetEditorState?
    @Published var isManagePresetsPresented = false
    @Published var isImportConflictSheetPresented = false
    @Published var searchQuery = ""
    @Published var statusMessage = "Ready"
    @Published var browserThumbnailInvalidationToken = UUID()
    @Published var browserThumbnailInvalidatedURLs: Set<URL> = []
    @Published var lastResult: OperationResult?
    @Published var isFolderMetadataLoading = false
    @Published var folderMetadataLoadCompleted = 0
    @Published var folderMetadataLoadTotal = 0
    @Published var isApplyingMetadata = false
    @Published var applyMetadataCompleted = 0
    @Published var applyMetadataTotal = 0
    @Published var isPreviewPreloading = false
    @Published var previewPreloadCompleted = 0
    @Published var previewPreloadTotal = 0
    @Published var collapsedInspectorSections: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(collapsedInspectorSections), forKey: Self.collapsedInspectorSectionsKey)
        }
    }

    @Published private var pendingEditsByFile: [URL: [EditableTag: StagedEditRecord]] = [:]
    @Published private var inspectorPreviewImages: [URL: NSImage] = [:]
    private var mixedTags: Set<EditableTag> = []
    private var pendingImportConflicts: [ImportConflict] = []
    private var pendingImportNonConflictEdits: [URL: [EditableTag: StagedEditRecord]] = [:]
    private var pendingImportConflictChoices: [UUID: Bool] = [:] // true = replace, false = keep existing
    private var isRevertingSidebarSelection = false
    private var folderMetadataLoadTask: Task<Void, Never>?
    private var folderMetadataLoadID = UUID()
    private var previewPreloadTask: Task<Void, Never>?
    private var previewPreloadID = UUID()
    private var inspectorPreviewInflight: Set<URL> = []
    private var staleMetadataFiles: Set<URL> = []
    private var selectionAnchorURL: URL?
    private var selectionFocusURL: URL?
    private var quickLookSourceFrames: [URL: NSRect] = [:]
    private var quickLookTransitionImages: [URL: NSImage] = [:]

    private let engine: ExifEditEngine
    private let presetStore: PresetStoreProtocol
    private var lastOperationIDs: [UUID] = []
    private var lastOperationFilesByID: [UUID: URL] = [:]
    private var statusResetTask: Task<Void, Never>?
    private var metadataUndoStack: [PendingEditState] = []
    private var metadataRedoStack: [PendingEditState] = []
    private var isApplyingMetadataUndoState = false

    private static let browserViewModeKey = "ui.browser.view.mode"
    private static let browserSortKey = "ui.browser.sort"
    private static let galleryGridLevelKey = "ui.gallery.grid.level"
    private static let galleryZoomKey = "ui.gallery.zoom"
    private static let collapsedInspectorSectionsKey = "ui.inspector.collapsed.sections"
    private static let selectedPresetIDKey = "ui.presets.selected.id"
    private static let selectionMetadataBatchSize = 120
    private static let folderMetadataBatchSize = 8

    var galleryColumnCount: Int {
        galleryGridLevel
    }

    var canIncreaseGalleryZoom: Bool {
        galleryGridLevel > Self.galleryColumnRange.lowerBound
    }

    var canDecreaseGalleryZoom: Bool {
        galleryGridLevel < Self.galleryColumnRange.upperBound
    }

    var hasUnsavedEdits: Bool {
        !pendingEditsByFile.isEmpty
    }

    var canApplyMetadataChanges: Bool {
        hasUnsavedEdits
    }

    var canUndoMetadataEdits: Bool {
        !metadataUndoStack.isEmpty
    }

    var canRedoMetadataEdits: Bool {
        !metadataRedoStack.isEmpty
    }

    var hasImportConflicts: Bool {
        !pendingImportConflicts.isEmpty
    }

    var groupedImportConflicts: [(fileURL: URL, conflicts: [ImportConflict])] {
        let grouped = Dictionary(grouping: pendingImportConflicts, by: \.fileURL)
        return grouped
            .map { ($0.key, $0.value.sorted { $0.tag.label < $1.tag.label }) }
            .sorted { $0.fileURL.lastPathComponent.localizedCaseInsensitiveCompare($1.fileURL.lastPathComponent) == .orderedAscending }
    }

    var primarySelectionURL: URL? {
        if let focus = selectionFocusURL, selectedFileURLs.contains(focus) {
            return focus
        }
        return selectedFileURLs.sorted(by: { $0.path < $1.path }).first
    }

    init() {
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
        presetStore = FilePresetStore()

        let storedCollapsed = UserDefaults.standard.stringArray(forKey: Self.collapsedInspectorSectionsKey) ?? []
        collapsedInspectorSections = Set(storedCollapsed)
        sidebarItems = defaultSidebarItems()
        if let selectedPresetRaw = UserDefaults.standard.string(forKey: Self.selectedPresetIDKey),
           let selectedPresetUUID = UUID(uuidString: selectedPresetRaw) {
            selectedPresetID = selectedPresetUUID
        }
        loadPresets()

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

    func openInDefaultApp(_ fileURLs: [URL]) {
        let uniqueURLs = Array(Set(fileURLs)).sorted { $0.path < $1.path }
        guard !uniqueURLs.isEmpty else { return }
        var failedCount = 0
        for fileURL in uniqueURLs {
            if !NSWorkspace.shared.open(fileURL) {
                failedCount += 1
            }
        }
        if failedCount > 0 {
            statusMessage = "Could not open \(failedCount) file(s) in the default app."
        }
    }

    func defaultAppDisplayName(for fileURL: URL?) -> String {
        guard let fileURL,
              let appURL = NSWorkspace.shared.urlForApplication(toOpen: fileURL)
        else {
            return "Default App"
        }

        if let bundle = Bundle(url: appURL) {
            if let display = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
               !display.isEmpty {
                return display
            }
            if let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
               !name.isEmpty {
                return name
            }
        }
        return appURL.deletingPathExtension().lastPathComponent
    }

    func openSelectedInDefaultApp() {
        guard let url = selectedFileURLs.sorted(by: { $0.path < $1.path }).first else {
            statusMessage = "Select a file to open in the default app."
            return
        }
        openInDefaultApp(url)
    }

    func rotateLeft(fileURL: URL) {
        statusMessage = "Rotating \(fileURL.lastPathComponent)…"
        Task { [weak self] in
            guard let self else { return }
            do {
                try await Self.runSipsRotateLeft(fileURL: fileURL)
                await MainActor.run {
                    self.refreshMetadata(for: [fileURL])
                }
            } catch {
                await MainActor.run {
                    self.statusMessage = "Failed to rotate \(fileURL.lastPathComponent). \(error.localizedDescription)"
                }
            }
        }
    }

    func flipHorizontal(fileURL: URL) {
        statusMessage = "Flipping \(fileURL.lastPathComponent)…"
        Task { [weak self] in
            guard let self else { return }
            do {
                try await Self.runSipsFlipHorizontal(fileURL: fileURL)
                await MainActor.run {
                    self.refreshMetadata(for: [fileURL])
                }
            } catch {
                await MainActor.run {
                    self.statusMessage = "Failed to flip \(fileURL.lastPathComponent). \(error.localizedDescription)"
                }
            }
        }
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
        return quickLookSourceFrames[fileURL]
    }

    func quickLookTransitionImage(for fileURL: URL) -> NSImage? {
        quickLookTransitionImages[fileURL]
    }

    func setSelectionFromQuickLook(_ fileURL: URL) {
        let selection: Set<URL> = [fileURL]
        guard selectedFileURLs != selection else { return }
        selectedFileURLs = selection
        selectionAnchorURL = fileURL
        selectionFocusURL = fileURL
        selectionChanged()
    }

    func inspectorPreviewImage(for fileURL: URL) -> NSImage? {
        inspectorPreviewImages[fileURL]
    }

    func isInspectorPreviewLoading(for fileURL: URL) -> Bool {
        inspectorPreviewInflight.contains(fileURL)
    }

    func ensureInspectorPreviewLoaded(for fileURL: URL) {
        loadInspectorPreview(for: fileURL, force: false)
    }

    func forceReloadInspectorPreview(for fileURL: URL) {
        loadInspectorPreview(for: fileURL, force: true)
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
                    guard let self else { return }
                    if self.hasUnsavedEdits {
                        let shouldDiscard = self.confirmDiscardUnsavedChanges(for: "opening a different folder")
                        guard shouldDiscard else { return }
                        self.discardUnsavedEdits()
                    }
                    self.didChooseFolder(folderURL)
                }
            }
            return
        }

        guard panel.runModal() == .OK, let folderURL = panel.url else { return }
        if hasUnsavedEdits {
            let shouldDiscard = confirmDiscardUnsavedChanges(for: "opening a different folder")
            guard shouldDiscard else { return }
            discardUnsavedEdits()
        }
        didChooseFolder(folderURL)
    }

    func refresh() {
        invalidateAllBrowserThumbnails()
        if let item = selectedSidebarItem {
            loadFiles(for: item.kind)
        }

        Task {
            await loadMetadataForSelection()
        }
    }

    func refreshMetadata(for fileURLs: [URL]) {
        let files = Array(Set(fileURLs)).sorted { $0.path < $1.path }
        guard !files.isEmpty else { return }

        Task {
            do {
                let snapshots = try await engine.readMetadata(files: files)
                var map = metadataByFile
                for snapshot in snapshots {
                    map[snapshot.fileURL] = snapshot
                    staleMetadataFiles.remove(snapshot.fileURL)
                }
                metadataByFile = map
                for fileURL in files {
                    forceReloadInspectorPreview(for: fileURL)
                }
                invalidateBrowserThumbnails(for: files)
                recalculateInspectorState()
                if let selectedURL = primarySelectionURL, files.contains(selectedURL) {
                    ensureInspectorPreviewLoaded(for: selectedURL)
                }
                setStatusMessage("Refreshed metadata for \(files.count) file(s).", autoClearAfterSuccess: true)
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    func selectSidebar(id: String?) {
        selectedSidebarID = id
        guard let item = selectedSidebarItem else { return }
        loadFiles(for: item.kind)
    }

    func handleSidebarSelectionChange(from oldID: String?, to newID: String?) {
        if isRevertingSidebarSelection {
            isRevertingSidebarSelection = false
            return
        }
        guard newID != oldID else { return }

        if hasUnsavedEdits {
            let shouldDiscard = confirmDiscardUnsavedChanges(for: "switching folders")
            guard shouldDiscard else {
                isRevertingSidebarSelection = true
                selectedSidebarID = oldID
                return
            }
            discardUnsavedEdits()
        }

        selectSidebar(id: newID)
    }

    func confirmDiscardUnsavedChanges(for actionDescription: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "You have unsaved metadata changes."
        alert.informativeText = "Discard unsaved edits before \(actionDescription)?"
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func discardUnsavedEdits() {
        registerMetadataUndoIfNeeded(previous: currentPendingEditState())
        pendingEditsByFile.removeAll()
        pendingImportConflicts = []
        pendingImportConflictChoices = [:]
        pendingImportNonConflictEdits = [:]
        isImportConflictSheetPresented = false
        recalculateInspectorState()
        setStatusMessage("Discarded unsaved metadata changes.", autoClearAfterSuccess: true)
    }

    func clearPendingEdits(for fileURLs: [URL]) {
        let uniqueURLs = Array(Set(fileURLs))
        guard !uniqueURLs.isEmpty else { return }
        registerMetadataUndoIfNeeded(previous: currentPendingEditState())
        for fileURL in uniqueURLs {
            pendingEditsByFile[fileURL] = nil
        }
        recalculateInspectorState()
        setStatusMessage("Cleared metadata changes for \(uniqueURLs.count) file(s).", autoClearAfterSuccess: true)
    }

    func applyChanges() {
        let files = browserItems
            .map(\.url)
            .filter { hasPendingEdits(for: $0) }
        applyChanges(for: files)
    }

    func applyChanges(for fileURLs: [URL]) {
        let files = Array(Set(fileURLs)).sorted { $0.path < $1.path }
            .filter { hasPendingEdits(for: $0) }
        guard !files.isEmpty else {
            setStatusMessage("No metadata changes to apply.", autoClearAfterSuccess: true)
            return
        }

        isApplyingMetadata = true
        applyMetadataCompleted = 0
        applyMetadataTotal = files.count

        Task {
            let startedAt = Date()
            var succeeded: [URL] = []
            var failed: [FileError] = []
            var firstBackupLocation: URL?
            var operationIDs: [UUID] = []
            var operationFilesByID: [UUID: URL] = [:]

            for (index, fileURL) in files.enumerated() {
                let patches = buildPatches(for: fileURL)
                guard !patches.isEmpty else { continue }
                let operationID = UUID()
                let operation = EditOperation(id: operationID, targetFiles: [fileURL], changes: patches)
                operationFilesByID[operationID] = fileURL

                do {
                    let result = try await engine.apply(operation: operation)
                    operationIDs.append(result.operationID)
                    if firstBackupLocation == nil {
                        firstBackupLocation = result.backupLocation
                    }
                    if result.failed.isEmpty {
                        succeeded.append(fileURL)
                        pendingEditsByFile[fileURL] = nil
                        staleMetadataFiles.insert(fileURL)
                    } else {
                        failed.append(contentsOf: result.failed)
                    }
                } catch {
                    failed.append(FileError(fileURL: fileURL, message: error.localizedDescription))
                }
                applyMetadataCompleted = index + 1
            }

            let summaryOperationID = operationIDs.last ?? UUID()
            let result = OperationResult(
                operationID: summaryOperationID,
                succeeded: succeeded,
                failed: failed,
                backupLocation: firstBackupLocation,
                duration: Date().timeIntervalSince(startedAt)
            )
            lastOperationIDs = operationIDs
            lastOperationFilesByID = operationFilesByID
            lastResult = result

            if result.failed.isEmpty {
                setStatusMessage(
                    "Metadata applied",
                    autoClearAfterSuccess: true
                )
            } else if result.succeeded.isEmpty {
                let firstError = result.failed.first?.message ?? "Unknown write error."
                statusMessage = "Failed to apply metadata changes. \(firstError)"
            } else {
                    let firstError = result.failed.first?.message ?? "Unknown write error."
                    statusMessage = "Applied to \(result.succeeded.count) file(s), failed on \(result.failed.count). \(firstError)"
            }
            applyMetadataCompleted = applyMetadataTotal
            isApplyingMetadata = false
            clearMetadataUndoHistory()

            Task { @MainActor [weak self] in
                await self?.loadMetadataForSelection()
            }
        }
    }

    func hasRestorableBackup(for fileURL: URL) -> Bool {
        lastOperationFilesByID.values.contains(fileURL)
    }

    func restoreLastOperation() {
        guard !lastOperationIDs.isEmpty else {
            statusMessage = "No previous operation to restore."
            return
        }
        let files = lastOperationIDs.compactMap { lastOperationFilesByID[$0] }
        restoreLastOperation(for: files)
    }

    func restoreLastOperation(for fileURLs: [URL]) {
        let requestedFiles = Array(Set(fileURLs))
        guard !requestedFiles.isEmpty else {
            statusMessage = "Select one or more files to restore."
            return
        }

        let requestedSet = Set(requestedFiles)
        let operationIDsToRestore = lastOperationIDs.filter { operationID in
            guard let fileURL = lastOperationFilesByID[operationID] else { return false }
            return requestedSet.contains(fileURL)
        }

        let skippedCount = requestedFiles.count - operationIDsToRestore.count
        guard !operationIDsToRestore.isEmpty else {
            statusMessage = "No backup available for the selected file(s)."
            return
        }

        let operationFilesByID = lastOperationFilesByID

        Task {
            var succeeded: [URL] = []
            var failed: [FileError] = []
            var backupLocation: URL?
            let startedAt = Date()

            for operationID in operationIDsToRestore {
                do {
                    let result = try await engine.restore(operationID: operationID)
                    if backupLocation == nil {
                        backupLocation = result.backupLocation
                    }
                    succeeded.append(contentsOf: result.succeeded)
                    failed.append(contentsOf: result.failed)
                } catch {
                    let fallbackURL = operationFilesByID[operationID] ?? URL(fileURLWithPath: "/")
                    failed.append(FileError(fileURL: fallbackURL, message: error.localizedDescription))
                }
            }

            let summary = OperationResult(
                operationID: operationIDsToRestore.last ?? UUID(),
                succeeded: succeeded,
                failed: failed,
                backupLocation: backupLocation,
                duration: Date().timeIntervalSince(startedAt)
            )
            lastResult = summary
            if summary.failed.isEmpty {
                var message = "Restored \(summary.succeeded.count) file(s)."
                if skippedCount > 0 {
                    message += " \(skippedCount) had no backup."
                }
                setStatusMessage(message, autoClearAfterSuccess: true)
            } else if summary.succeeded.isEmpty {
                let firstError = summary.failed.first?.message ?? "Unknown restore error."
                statusMessage = "Failed to restore metadata. \(firstError)"
            } else {
                let firstError = summary.failed.first?.message ?? "Unknown restore error."
                statusMessage = "Restored \(summary.succeeded.count) file(s), failed on \(summary.failed.count). \(firstError)"
            }
            await loadMetadataForSelection()
        }
    }

    func loadPresets() {
        do {
            presets = try presetStore.loadPresets().sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            if let selectedPresetID,
               !presets.contains(where: { $0.id == selectedPresetID }) {
                self.selectedPresetID = nil
            }
        } catch {
            presets = []
            selectedPresetID = nil
            statusMessage = "Could not load presets. \(error.localizedDescription)"
        }
    }

    @discardableResult
    func createPreset(name: String, notes: String?, fields: [PresetFieldValue]) -> MetadataPreset? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedFields = normalizePresetFields(fields)
        guard !trimmedName.isEmpty, !normalizedFields.isEmpty else { return nil }

        let now = Date()
        let preset = MetadataPreset(
            id: UUID(),
            name: trimmedName,
            notes: notes?.trimmingCharacters(in: .whitespacesAndNewlines),
            fields: normalizedFields,
            createdAt: now,
            updatedAt: now
        )
        presets.append(preset)
        sortPresets()
        persistPresets()
        selectedPresetID = preset.id
        setStatusMessage("Saved preset “\(preset.name)”.", autoClearAfterSuccess: true)
        return preset
    }

    @discardableResult
    func updatePreset(id: UUID, name: String, notes: String?, fields: [PresetFieldValue]) -> MetadataPreset? {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return nil }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedFields = normalizePresetFields(fields)
        guard !trimmedName.isEmpty, !normalizedFields.isEmpty else { return nil }

        var preset = presets[index]
        preset.name = trimmedName
        preset.notes = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        preset.fields = normalizedFields
        preset.updatedAt = Date()
        presets[index] = preset
        sortPresets()
        persistPresets()
        selectedPresetID = preset.id
        setStatusMessage("Updated preset “\(preset.name)”.", autoClearAfterSuccess: true)
        return preset
    }

    @discardableResult
    func duplicatePreset(id: UUID) -> MetadataPreset? {
        guard let preset = preset(withID: id) else { return nil }
        return createPreset(name: "\(preset.name) Copy", notes: preset.notes, fields: preset.fields)
    }

    func deletePreset(id: UUID) {
        let previousCount = presets.count
        presets.removeAll { $0.id == id }
        guard presets.count != previousCount else { return }

        if selectedPresetID == id {
            selectedPresetID = nil
        }
        persistPresets()
        setStatusMessage("Deleted preset.", autoClearAfterSuccess: true)
    }

    func preset(withID id: UUID) -> MetadataPreset? {
        presets.first(where: { $0.id == id })
    }

    func beginCreatePresetFromCurrent() {
        var includedTagIDs = Set<String>()
        var valuesByTagID: [String: String] = [:]

        for tag in EditableTag.common {
            let value = valueForTag(tag).trimmingCharacters(in: .whitespacesAndNewlines)
            valuesByTagID[tag.id] = value
            if !value.isEmpty, !isMixedValue(for: tag) {
                includedTagIDs.insert(tag.id)
            }
        }

        activePresetEditor = PresetEditorState(
            mode: .createFromCurrent,
            name: "",
            notes: "",
            includedTagIDs: includedTagIDs,
            valuesByTagID: valuesByTagID
        )
    }

    func beginCreateBlankPreset() {
        var valuesByTagID: [String: String] = [:]
        for tag in EditableTag.common {
            valuesByTagID[tag.id] = ""
        }

        activePresetEditor = PresetEditorState(
            mode: .createBlank,
            name: "",
            notes: "",
            includedTagIDs: [],
            valuesByTagID: valuesByTagID
        )
    }

    func beginEditPreset(_ presetID: UUID) {
        guard let preset = preset(withID: presetID) else { return }

        var includedTagIDs = Set<String>()
        var valuesByTagID: [String: String] = [:]
        for field in preset.fields {
            includedTagIDs.insert(field.tagID)
            valuesByTagID[field.tagID] = field.value
        }
        for tag in EditableTag.common where valuesByTagID[tag.id] == nil {
            valuesByTagID[tag.id] = ""
        }

        activePresetEditor = PresetEditorState(
            mode: .edit(preset.id),
            name: preset.name,
            notes: preset.notes ?? "",
            includedTagIDs: includedTagIDs,
            valuesByTagID: valuesByTagID
        )
    }

    func dismissPresetEditor(reopenManagePresets: Bool = false) {
        activePresetEditor = nil
        guard reopenManagePresets else { return }
        DispatchQueue.main.async { [weak self] in
            self?.isManagePresetsPresented = true
        }
    }

    func applyPreset(presetID: UUID) {
        guard let preset = preset(withID: presetID) else {
            statusMessage = "Preset not found."
            return
        }

        let files = Array(selectedFileURLs)
        guard !files.isEmpty else {
            statusMessage = "Select at least one file to apply a preset."
            return
        }

        var unknownTagIDs: [String] = []
        var stagedFieldCount = 0
        let previousState = currentPendingEditState()

        for field in preset.fields {
            guard let tag = editableTag(forID: field.tagID) else {
                unknownTagIDs.append(field.tagID)
                continue
            }
            let value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
            stageEdit(
                value,
                for: tag,
                fileURLs: files,
                source: .preset(preset.id)
            )
            stagedFieldCount += 1
        }

        guard stagedFieldCount > 0 else {
            statusMessage = unknownTagIDs.isEmpty
                ? "Preset has no applicable fields."
                : "Preset contains unsupported fields only."
            return
        }
        registerMetadataUndoIfNeeded(previous: previousState)
        recalculateInspectorState()
        let ignoredText = unknownTagIDs.isEmpty ? "" : " Ignored \(unknownTagIDs.count) unsupported preset field(s)."
        setStatusMessage(
            "Staged preset “\(preset.name)” for \(files.count) file(s).\(ignoredText)",
            autoClearAfterSuccess: true
        )
    }

    func importGPX() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        var contentTypes: [UTType] = [.xml]
        if let gpxType = UTType(filenameExtension: "gpx") {
            contentTypes.insert(gpxType, at: 0)
        }
        panel.allowedContentTypes = contentTypes
        panel.prompt = "Import GPX"

        guard panel.runModal() == .OK, let gpxURL = panel.url else { return }

        Task { @MainActor in
            do {
                let points = try GPXImporter.parseTrackPoints(from: gpxURL)
                let files = browserItems.map(\.url)
                if !files.isEmpty {
                    let snapshots = try await engine.readMetadata(files: files)
                    var map = metadataByFile
                    for snapshot in snapshots {
                        map[snapshot.fileURL] = snapshot
                    }
                    metadataByFile = map
                }

                let previousState = currentPendingEditState()
                let result = stageGPXImport(points: points, sourceURL: gpxURL)
                registerMetadataUndoIfNeeded(previous: previousState)
                if hasImportConflicts {
                    isImportConflictSheetPresented = true
                } else {
                    setStatusMessage(
                        "Staged GPX data for \(result.affectedFiles) file(s). \(result.skippedUnmatched) unmatched.",
                        autoClearAfterSuccess: true
                    )
                }
            } catch {
                statusMessage = "Failed to import GPX. \(error.localizedDescription)"
            }
        }
    }

    func importConflictChoice(for conflictID: UUID) -> Bool {
        pendingImportConflictChoices[conflictID] ?? false
    }

    func setImportConflictChoice(_ replaceWithIncoming: Bool, for conflictID: UUID) {
        pendingImportConflictChoices[conflictID] = replaceWithIncoming
    }

    func cancelImportConflictResolution() {
        pendingImportConflicts = []
        pendingImportConflictChoices = [:]
        pendingImportNonConflictEdits = [:]
        isImportConflictSheetPresented = false
    }

    func applyImportConflictResolution() {
        let previousState = currentPendingEditState()

        for (fileURL, entries) in pendingImportNonConflictEdits {
            for (tag, record) in entries {
                stageEdit(record.value, for: tag, fileURLs: [fileURL], source: record.source)
            }
        }

        var resolvedCount = 0
        for conflict in pendingImportConflicts {
            let shouldReplace = pendingImportConflictChoices[conflict.id] ?? false
            if shouldReplace {
                stageEdit(
                    conflict.incomingValue,
                    for: conflict.tag,
                    fileURLs: [conflict.fileURL],
                    source: conflict.incomingSource
                )
                resolvedCount += 1
            }
        }

        pendingImportConflicts = []
        pendingImportConflictChoices = [:]
        pendingImportNonConflictEdits = [:]
        isImportConflictSheetPresented = false
        registerMetadataUndoIfNeeded(previous: previousState)
        recalculateInspectorState()
        setStatusMessage("Staged imported metadata. Resolved \(resolvedCount) conflict(s).", autoClearAfterSuccess: true)
    }

    func valueForTag(_ tag: EditableTag) -> String {
        draftValues[tag] ?? ""
    }

    func updateValue(_ value: String, for tag: EditableTag) {
        let previousState = currentPendingEditState()
        draftValues[tag] = value
        trackPendingEdit(value, for: tag, source: .manual)
        registerMetadataUndoIfNeeded(previous: previousState)
    }

    @discardableResult
    func undoLastMetadataEdit() -> Bool {
        guard let previousState = metadataUndoStack.popLast() else { return false }
        let currentState = currentPendingEditState()
        metadataRedoStack.append(currentState)
        applyPendingEditState(previousState)
        setStatusMessage("Undid metadata edit.", autoClearAfterSuccess: true)
        return true
    }

    @discardableResult
    func redoLastMetadataEdit() -> Bool {
        guard let nextState = metadataRedoStack.popLast() else { return false }
        let currentState = currentPendingEditState()
        metadataUndoStack.append(currentState)
        applyPendingEditState(nextState)
        setStatusMessage("Redid metadata edit.", autoClearAfterSuccess: true)
        return true
    }

    func makeEditSessionSnapshot(for tag: EditableTag) -> EditSessionSnapshot {
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

    func editableTag(forID id: String) -> EditableTag? {
        Self.editableTagsByID[id]
    }

    func parseEditableDateValue(_ raw: String) -> Date? {
        parseDate(raw)
    }

    func formatEditableDateValue(_ date: Date) -> String {
        Self.exifDateFormatter.string(from: date)
    }

    var mixedOverrideCount: Int {
        EditableTag.common.reduce(0) { count, tag in
            guard isMixedValue(for: tag) else { return count }
            let current = draftValues[tag]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return current.isEmpty ? count : count + 1
        }
    }

    var needsMixedValueConfirmation: Bool {
        selectedFileURLs.count > 1 && mixedOverrideCount > 0
    }

    var requiresBatchApplyConfirmation: Bool {
        pendingEditedFileCount > 1
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
        !(pendingEditsByFile[fileURL]?.isEmpty ?? true)
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
        selectedFileURLs.count > 1 && mixedTags.contains(tag)
    }

    var pendingEditedFileCount: Int {
        browserItems
            .map(\.url)
            .filter { !(pendingEditsByFile[$0]?.isEmpty ?? true) }
            .count
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

    private func stageEdit(_ value: String, for tag: EditableTag, fileURLs: [URL], source: StagedEditSource) {
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

    private func stageGPXImport(points: [GPXTrackPoint], sourceURL: URL) -> ImportApplyResult {
        let latTag = Self.editableTagsByID["exif-gps-lat"]
        let lonTag = Self.editableTagsByID["exif-gps-lon"]
        guard let latTag, let lonTag else {
            return ImportApplyResult(affectedFiles: 0, affectedFields: 0, skippedUnmatched: browserItems.count, conflictsResolved: 0)
        }

        pendingImportConflicts = []
        pendingImportConflictChoices = [:]
        pendingImportNonConflictEdits = [:]

        let pointsBySecond = Dictionary(uniqueKeysWithValues: points.map { (Int($0.timestamp.timeIntervalSince1970), $0) })
        let visibleURLs = browserItems.map(\.url)
        var matchedFiles = Set<URL>()
        var affectedFields = 0

        for fileURL in visibleURLs {
            guard let timestamp = captureDate(for: fileURL) else { continue }
            let second = Int(timestamp.timeIntervalSince1970)
            guard let point = pointsBySecond[second] else { continue }
            matchedFiles.insert(fileURL)

            let updates: [(EditableTag, String)] = [
                (latTag, Self.compactDecimalString(point.latitude)),
                (lonTag, Self.compactDecimalString(point.longitude))
            ]
            for (tag, incomingValue) in updates {
                if let existing = pendingEditsByFile[fileURL]?[tag],
                   existing.value != incomingValue {
                    let conflict = ImportConflict(
                        fileURL: fileURL,
                        tag: tag,
                        existing: existing,
                        incomingValue: incomingValue,
                        incomingSource: .gpx(sourceURL)
                    )
                    pendingImportConflicts.append(conflict)
                    pendingImportConflictChoices[conflict.id] = false
                    continue
                }

                var map = pendingImportNonConflictEdits[fileURL] ?? [:]
                map[tag] = StagedEditRecord(value: incomingValue, source: .gpx(sourceURL), updatedAt: Date())
                pendingImportNonConflictEdits[fileURL] = map
                affectedFields += 1
            }
        }

        if pendingImportConflicts.isEmpty {
            for (fileURL, entries) in pendingImportNonConflictEdits {
                for (tag, record) in entries {
                    stageEdit(record.value, for: tag, fileURLs: [fileURL], source: record.source)
                }
            }
            pendingImportNonConflictEdits = [:]
            recalculateInspectorState()
        }

        return ImportApplyResult(
            affectedFiles: matchedFiles.count,
            affectedFields: affectedFields,
            skippedUnmatched: max(0, visibleURLs.count - matchedFiles.count),
            conflictsResolved: 0
        )
    }

    private func captureDate(for fileURL: URL) -> Date? {
        guard let snapshot = availableSnapshot(for: fileURL) else { return nil }
        let keys = ["DateTimeOriginal", "CreateDate", "DateTimeDigitized"]
        for key in keys {
            if let raw = snapshot.fields.first(where: { $0.key == key })?.value,
               let parsed = parseDate(raw) {
                return parsed
            }
        }
        return nil
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

    func toggleSelection(for fileURL: URL, additive: Bool) {
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

    func moveSelectionInList(direction: MoveCommandDirection, extendingSelection: Bool = false) {
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

        if extendingSelection {
            moveRangeSelection(in: items, delta: delta)
        } else {
            moveSingleSelection(in: items, delta: delta)
        }
    }

    func moveSelectionInGallery(direction: MoveCommandDirection, extendingSelection: Bool = false) {
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

    func extendSelectionToBoundary(towardStart: Bool) {
        let items = filteredBrowserItems
        guard !items.isEmpty else { return }

        let targetURL = towardStart ? items.first!.url : items.last!.url
        let previousSelection = selectedFileURLs

        if selectedFileURLs.isEmpty {
            selectedFileURLs = [targetURL]
            selectionAnchorURL = targetURL
            selectionFocusURL = targetURL
        } else {
            applyRangeSelection(to: targetURL, additive: false, in: items)
        }

        guard selectedFileURLs != previousSelection else { return }
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

    private func currentSelectionIndex(in items: [BrowserItem]) -> Int? {
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

    var selectedSidebarItem: SidebarItem? {
        guard let selectedSidebarID else { return nil }
        return sidebarItems.first { $0.id == selectedSidebarID }
    }

    var sidebarSectionOrder: [String] {
        ["Recents", "Import Sources", "Locations"]
    }

    private func addFolderToSidebar(_ url: URL) {
        let id = "folder::\(url.path)"
        if !sidebarItems.contains(where: { $0.id == id }) {
            sidebarItems.append(
                SidebarItem(id: id, title: url.lastPathComponent, section: "Locations", kind: .folder(url))
            )
        }
        selectedSidebarID = id
    }

    private func didChooseFolder(_ folderURL: URL) {
        addFolderToSidebar(folderURL)
        loadFiles(for: .folder(folderURL))
    }

    private func loadFiles(for kind: SidebarKind) {
        folderMetadataLoadTask?.cancel()
        folderMetadataLoadTask = nil
        folderMetadataLoadID = UUID()
        previewPreloadTask?.cancel()
        previewPreloadTask = nil
        previewPreloadID = UUID()

        let urls: [URL]

        switch kind {
        case .recent24Hours:
            urls = loadRecentFiles(within: 24 * 60 * 60)
        case .recent7Days:
            urls = loadRecentFiles(within: 7 * 24 * 60 * 60)
        case .recent30Days:
            urls = loadRecentFiles(within: 30 * 24 * 60 * 60)
        case .pictures:
            urls = enumerateImages(in: picturesDirectoryURL())
        case .desktop:
            urls = enumerateImages(in: desktopDirectoryURL())
        case .downloads:
            urls = enumerateImages(in: downloadsDirectoryURL())
        case let .mountedVolume(volumeURL):
            urls = enumerateImages(in: volumeURL)
        case let .folder(folder):
            urls = enumerateImages(in: folder)
        }

        browserItems = urls.map {
            let resourceValues = try? $0.resourceValues(
                forKeys: [
                    .contentModificationDateKey,
                    .creationDateKey,
                    .fileSizeKey,
                    .localizedTypeDescriptionKey
                ]
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
        staleMetadataFiles = []
        pendingEditsByFile = [:]
        pendingImportConflicts = []
        pendingImportConflictChoices = [:]
        pendingImportNonConflictEdits = [:]
        isImportConflictSheetPresented = false
        inspectorPreviewImages = [:]
        inspectorPreviewInflight = []
        isPreviewPreloading = false
        previewPreloadCompleted = 0
        previewPreloadTotal = 0
        clearMetadataUndoHistory()
        startFolderMetadataPrefetch(for: urls)
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

    private func loadRecentFiles(within interval: TimeInterval) -> [URL] {
        let cutoff = Date().addingTimeInterval(-interval)
        var uniqueURLs = Set<URL>()
        var candidates: [(URL, Date)] = []

        for root in recentSearchRoots() {
            for url in enumerateImagesRecursively(in: root) {
                guard uniqueURLs.insert(url).inserted else { continue }
                guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
                    continue
                }
                guard modified >= cutoff else { continue }
                candidates.append((url, modified))
            }
        }

        return candidates
            .sorted { $0.1 > $1.1 }
            .prefix(500)
            .map(\.0)
    }

    private func defaultSidebarItems() -> [SidebarItem] {
        var items: [SidebarItem] = [
            SidebarItem(id: "recent-24h", title: "Last 24 Hours", section: "Recents", kind: .recent24Hours),
            SidebarItem(id: "recent-7d", title: "Last 7 Days", section: "Recents", kind: .recent7Days),
            SidebarItem(id: "recent-30d", title: "Last 30 Days", section: "Recents", kind: .recent30Days),
            SidebarItem(id: "source-pictures", title: "Pictures", section: "Import Sources", kind: .pictures),
            SidebarItem(id: "source-desktop", title: "Desktop", section: "Import Sources", kind: .desktop),
            SidebarItem(id: "source-downloads", title: "Downloads", section: "Import Sources", kind: .downloads)
        ]
        items.append(contentsOf: mountedVolumeSidebarItems())
        return items
    }

    private func mountedVolumeSidebarItems() -> [SidebarItem] {
        let keys: [URLResourceKey] = [.volumeIsRemovableKey, .volumeLocalizedNameKey, .nameKey]
        let mounted = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []

        return mounted.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsRemovable == true
            else {
                return nil
            }
            let title = values.volumeLocalizedName ?? values.name ?? url.lastPathComponent
            return SidebarItem(
                id: "volume::\(url.path)",
                title: title,
                section: "Import Sources",
                kind: .mountedVolume(url)
            )
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private func recentSearchRoots() -> [URL] {
        var roots = [picturesDirectoryURL(), desktopDirectoryURL(), downloadsDirectoryURL()]
        roots.append(contentsOf: mountedVolumeSidebarItems().compactMap { item in
            if case let .mountedVolume(url) = item.kind {
                return url
            }
            return nil
        })
        return roots
    }

    private func picturesDirectoryURL() -> URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
    }

    private func desktopDirectoryURL() -> URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
    }

    private func downloadsDirectoryURL() -> URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
    }

    private func enumerateImages(in folder: URL) -> [URL] {
        let allowedExtensions = Set([
            "jpg", "jpeg", "tif", "tiff", "png", "heic", "heif", "dng", "arw", "cr2", "cr3", "nef", "orf", "rw2", "raf"
        ])

        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )) ?? []

        return urls.filter { url in
            guard allowedExtensions.contains(url.pathExtension.lowercased()) else { return false }
            let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            return isRegular
        }
    }

    private func enumerateImagesRecursively(in folder: URL) -> [URL] {
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

    private func buildPatches(for fileURL: URL) -> [MetadataPatch] {
        guard let staged = pendingEditsByFile[fileURL], !staged.isEmpty else {
            return []
        }

        var allPatches: [MetadataPatch] = []
        for (tag, record) in staged {
            allPatches.append(contentsOf: patchesForTag(tag, rawValue: record.value))
        }
        return allPatches
    }

    private func patchesForTag(_ tag: EditableTag, rawValue: String) -> [MetadataPatch] {
        let normalized = normalizedWriteValue(rawValue, for: tag)
        var patches: [MetadataPatch] = [
            MetadataPatch(
                key: tag.key,
                namespace: tag.namespace,
                newValue: normalized
            )
        ]

        // Keep Photos-compatible descriptive metadata in sync.
        if tag.id == "xmp-description" {
            patches.append(
                MetadataPatch(
                    key: "Caption-Abstract",
                    namespace: .iptc,
                    newValue: normalized
                )
            )
        } else if tag.id == "xmp-title" {
            patches.append(
                MetadataPatch(
                    key: "ObjectName",
                    namespace: .iptc,
                    newValue: normalized
                )
            )
        }

        return patches
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

        let candidateKeys: [String]
        let candidateNamespaces: [MetadataNamespace]

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

        return preferredFieldValue(
            in: snapshot,
            candidateKeys: candidateKeys,
            candidateNamespaces: candidateNamespaces
        )
    }

    private func preferredFieldValue(
        in snapshot: FileMetadataSnapshot,
        candidateKeys: [String],
        candidateNamespaces: [MetadataNamespace]
    ) -> String? {
        var fallback: String?

        for key in candidateKeys {
            for namespace in candidateNamespaces {
                guard let value = snapshot.fields.first(where: { $0.key == key && $0.namespace == namespace })?.value else {
                    continue
                }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
                if fallback == nil {
                    fallback = trimmed
                }
            }
        }

        return fallback
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
        let selectedURLs = Array(selectedFileURLs)
        guard !selectedURLs.isEmpty else {
            baselineValues = [:]
            draftValues = [:]
            mixedTags = []
            return
        }

        var nextBaseline: [EditableTag: String?] = [:]
        var nextDraft: [EditableTag: String] = [:]
        var nextMixedTags = Set<EditableTag>()

        for tag in EditableTag.common {
            var baselineValuesForTag: [String] = []
            for url in selectedURLs {
                guard let snapshot = availableSnapshot(for: url) else {
                    continue
                }
                baselineValuesForTag.append(normalizedDisplayValue(snapshot, for: tag))
            }
            let uniqueBaselineCanonical = Set(
                baselineValuesForTag.map { canonicalInspectorValue($0, for: tag) }
            )

            var draftValuesForTag: [String] = []
            for url in selectedURLs {
                if let pendingValue = pendingEditsByFile[url]?[tag]?.value {
                    draftValuesForTag.append(pendingValue)
                    continue
                }
                guard let snapshot = availableSnapshot(for: url) else {
                    continue
                }
                draftValuesForTag.append(normalizedDisplayValue(snapshot, for: tag))
            }
            let uniqueDraftCanonical = Set(
                draftValuesForTag.map { canonicalInspectorValue($0, for: tag) }
            )

            if uniqueBaselineCanonical.count == 1 {
                nextBaseline[tag] = baselineValuesForTag.first ?? ""
            } else if uniqueBaselineCanonical.isEmpty {
                nextBaseline[tag] = nil
            } else {
                nextBaseline[tag] = nil
                if selectedURLs.count > 1 {
                    nextMixedTags.insert(tag)
                }
            }

            if uniqueDraftCanonical.count == 1 {
                nextDraft[tag] = draftValuesForTag.first ?? ""
            } else if uniqueDraftCanonical.isEmpty {
                nextDraft[tag] = ""
            } else {
                nextDraft[tag] = ""
                if selectedURLs.count > 1 {
                    nextMixedTags.insert(tag)
                }
            }
        }

        baselineValues = nextBaseline
        draftValues = nextDraft
        mixedTags = nextMixedTags
    }

    private func canonicalInspectorValue(_ value: String, for tag: EditableTag) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        switch tag.id {
        case "exif-make", "exif-model", "exif-lens":
            let squashedWhitespace = trimmed.replacingOccurrences(
                of: "\\s+",
                with: " ",
                options: .regularExpression
            )
            return squashedWhitespace.folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: .current
            )
        case "exif-serial":
            return trimmed.folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: .current
            )
        default:
            return trimmed
        }
    }

    private func normalizedDisplayValue(_ snapshot: FileMetadataSnapshot, for tag: EditableTag) -> String {
        guard let raw = value(for: tag, in: snapshot) else {
            return ""
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if tag.id == "exif-shutter" {
            return formatExposureTime(trimmed)
        }
        if tag.id == "exif-exposure-program" || tag.id == "exif-flash" || tag.id == "exif-metering-mode" {
            return normalizeEnumRawValue(trimmed)
        }
        if tag.id == "exif-aperture" || tag.id == "exif-focal" || tag.id == "exif-iso" {
            return normalizeNumericRawValue(trimmed)
        }

        return trimmed
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

    private func normalizeNumericRawValue(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if trimmed.contains("/") {
            let parts = trimmed.split(separator: "/", maxSplits: 1).map { String($0) }
            if parts.count == 2,
               let numerator = Double(parts[0]),
               let denominator = Double(parts[1]),
               denominator != 0 {
                return Self.compactDecimalString(numerator / denominator)
            }
            return trimmed
        }

        if let value = Double(trimmed), value.isFinite {
            return Self.compactDecimalString(value)
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

    private func normalizePresetFields(_ fields: [PresetFieldValue]) -> [PresetFieldValue] {
        var seen = Set<String>()
        var normalized: [PresetFieldValue] = []

        for field in fields {
            let trimmedTagID = field.tagID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedTagID.isEmpty, !seen.contains(trimmedTagID) else { continue }
            seen.insert(trimmedTagID)
            normalized.append(
                PresetFieldValue(
                    tagID: trimmedTagID,
                    value: field.value.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            )
        }

        return normalized
    }

    private func sortPresets() {
        presets.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func persistPresets() {
        do {
            try presetStore.savePresets(presets)
        } catch {
            statusMessage = "Could not save presets. \(error.localizedDescription)"
        }
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
        let selectionAtStart = Set(files)
        guard !files.isEmpty else {
            recalculateInspectorState()
            return
        }

        var map = metadataByFile

        for batchStart in stride(from: 0, to: files.count, by: Self.selectionMetadataBatchSize) {
            let batchEnd = min(batchStart + Self.selectionMetadataBatchSize, files.count)
            let batch = Array(files[batchStart..<batchEnd])
            let snapshots = await readMetadataBatchResilient(batch)

            // Ignore stale async results after selection has changed.
            guard selectionAtStart == selectedFileURLs else { return }
            for snapshot in snapshots {
                map[snapshot.fileURL] = snapshot
                staleMetadataFiles.remove(snapshot.fileURL)
            }
        }

        guard selectionAtStart == selectedFileURLs else { return }
        metadataByFile = map
        recalculateInspectorState()
    }

    private func startFolderMetadataPrefetch(for files: [URL]) {
        folderMetadataLoadTask?.cancel()
        folderMetadataLoadTask = nil

        let loadID = UUID()
        folderMetadataLoadID = loadID

        guard !files.isEmpty else {
            isFolderMetadataLoading = false
            folderMetadataLoadCompleted = 0
            folderMetadataLoadTotal = 0
            return
        }

        isFolderMetadataLoading = true
        folderMetadataLoadCompleted = 0
        folderMetadataLoadTotal = files.count

        folderMetadataLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var map = self.metadataByFile

            for batchStart in stride(from: 0, to: files.count, by: Self.folderMetadataBatchSize) {
                if Task.isCancelled { return }
                guard self.folderMetadataLoadID == loadID else { return }

                let batchEnd = min(batchStart + Self.folderMetadataBatchSize, files.count)
                let batch = Array(files[batchStart..<batchEnd])
                let snapshots = await self.readMetadataBatchResilient(batch)

                if Task.isCancelled { return }
                guard self.folderMetadataLoadID == loadID else { return }

                for snapshot in snapshots {
                    map[snapshot.fileURL] = snapshot
                    self.staleMetadataFiles.remove(snapshot.fileURL)
                }
                self.metadataByFile = map
                self.folderMetadataLoadCompleted = batchEnd
                let batchURLs = Set(batch)
                if !self.selectedFileURLs.isEmpty,
                   !self.selectedFileURLs.isDisjoint(with: batchURLs) {
                    self.recalculateInspectorState()
                }
            }

            guard !Task.isCancelled, self.folderMetadataLoadID == loadID else { return }
            self.isFolderMetadataLoading = false
            self.folderMetadataLoadTask = nil
            self.folderMetadataLoadCompleted = self.folderMetadataLoadTotal
            if !self.selectedFileURLs.isEmpty {
                self.recalculateInspectorState()
            }
            self.startPreviewPreload(for: files)
        }
    }

    private func startPreviewPreload(for files: [URL]) {
        previewPreloadTask?.cancel()
        previewPreloadTask = nil
        let preloadID = UUID()
        previewPreloadID = preloadID

        guard !files.isEmpty else {
            isPreviewPreloading = false
            previewPreloadCompleted = 0
            previewPreloadTotal = 0
            setStatusMessage("Metadata loaded", autoClearAfterSuccess: true)
            return
        }

        isPreviewPreloading = true
        previewPreloadCompleted = 0
        previewPreloadTotal = files.count

        previewPreloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for (index, fileURL) in files.enumerated() {
                if Task.isCancelled { return }
                guard self.previewPreloadID == preloadID else { return }

                if self.inspectorPreviewImages[fileURL] == nil {
                    self.inspectorPreviewInflight.insert(fileURL)
                    if let image = await Self.generateInspectorPreview(for: fileURL) {
                        self.inspectorPreviewImages[fileURL] = image
                    }
                    self.inspectorPreviewInflight.remove(fileURL)
                }

                self.previewPreloadCompleted = index + 1
            }

            guard !Task.isCancelled, self.previewPreloadID == preloadID else { return }
            self.previewPreloadTask = nil
            self.isPreviewPreloading = false
            self.previewPreloadCompleted = self.previewPreloadTotal
            self.setStatusMessage("Metadata and previews loaded", autoClearAfterSuccess: true)
        }
    }

    private static func generateInspectorPreview(for fileURL: URL) async -> NSImage? {
        if let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1400,
                kCGImageSourceShouldCacheImmediately: true
            ]
            if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return NSImage(cgImage: cgImage, size: .zero)
            }
        }

        let request = QLThumbnailGenerator.Request(
            fileAt: fileURL,
            size: CGSize(width: 1400, height: 1400),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail
        )

        let quickLookImage: NSImage? = await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { thumbnail, _ in
                let image: NSImage? = {
                    guard let thumbnail else { return nil }
                    if thumbnail.type == .icon {
                        return nil
                    }
                    return thumbnail.nsImage
                }()
                continuation.resume(returning: image)
            }
        }

        if let quickLookImage {
            return quickLookImage
        }
        if let decoded = NSImage(contentsOf: fileURL) {
            return decoded
        }
        if Self.isLikelyImageFile(fileURL) {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: fileURL.path)
    }

    private func readMetadataBatchResilient(_ files: [URL]) async -> [FileMetadataSnapshot] {
        guard !files.isEmpty else { return [] }
        do {
            return try await engine.readMetadata(files: files)
        } catch {
            var partial: [FileMetadataSnapshot] = []
            for file in files {
                if Task.isCancelled { break }
                if let one = try? await engine.readMetadata(files: [file]).first {
                    partial.append(one)
                }
            }
            return partial
        }
    }

    func selectionChanged() {
        // Recompute immediately so UI doesn't show stale single-file values while async load runs.
        recalculateInspectorState()
        Task {
            await loadMetadataForSelection()
        }
    }

    private func invalidateAllBrowserThumbnails() {
        browserThumbnailInvalidatedURLs = []
        browserThumbnailInvalidationToken = UUID()
    }

    private func invalidateBrowserThumbnails(for fileURLs: [URL]) {
        browserThumbnailInvalidatedURLs = Set(fileURLs)
        browserThumbnailInvalidationToken = UUID()
    }

    private static func runSipsRotateLeft(fileURL: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
            process.arguments = ["-r", "-90", fileURL.path]

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
                        domain: "Logbook.Rotate",
                        code: Int(proc.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: stderrText]
                    ))
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "Logbook.Rotate",
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

    private static func runSipsFlipHorizontal(fileURL: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
            process.arguments = ["--flip", "horizontal", fileURL.path]

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
                        domain: "Logbook.Flip",
                        code: Int(proc.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: stderrText]
                    ))
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "Logbook.Flip",
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

    private func loadInspectorPreview(for fileURL: URL, force: Bool) {
        if !force, inspectorPreviewImages[fileURL] != nil { return }
        guard !inspectorPreviewInflight.contains(fileURL) else { return }
        inspectorPreviewInflight.insert(fileURL)

        Task { @MainActor [weak self] in
            guard let self else { return }
            let image = await Self.generateInspectorPreview(for: fileURL)
            if let image {
                self.inspectorPreviewImages[fileURL] = image
            }
            self.inspectorPreviewInflight.remove(fileURL)
        }
    }

    private static func isLikelyImageFile(_ fileURL: URL) -> Bool {
        let imageExtensions: Set<String> = [
            "jpg", "jpeg", "heic", "heif", "png", "tif", "tiff", "gif", "bmp", "webp", "dng", "cr2", "cr3", "arw", "nef", "raf", "orf"
        ]
        return imageExtensions.contains(fileURL.pathExtension.lowercased())
    }

    private func currentPendingEditState() -> PendingEditState {
        PendingEditState(pendingEditsByFile: pendingEditsByFile)
    }

    private func registerMetadataUndoIfNeeded(previous: PendingEditState) {
        guard !isApplyingMetadataUndoState else { return }
        let current = currentPendingEditState()
        guard previous != current else { return }
        metadataUndoStack.append(previous)
        if metadataUndoStack.count > 100 {
            metadataUndoStack.removeFirst(metadataUndoStack.count - 100)
        }
        metadataRedoStack.removeAll()
    }

    private func applyPendingEditState(_ state: PendingEditState) {
        isApplyingMetadataUndoState = true
        pendingEditsByFile = state.pendingEditsByFile
        recalculateInspectorState()
        isApplyingMetadataUndoState = false
    }

    private func clearMetadataUndoHistory() {
        metadataUndoStack.removeAll()
        metadataRedoStack.removeAll()
    }

    private func availableSnapshot(for fileURL: URL) -> FileMetadataSnapshot? {
        guard !staleMetadataFiles.contains(fileURL) else { return nil }
        return metadataByFile[fileURL]
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

    private static let editableTagsByID: [String: EditableTag] = {
        Dictionary(uniqueKeysWithValues: EditableTag.common.map { ($0.id, $0) })
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

        panelObservation = panel.observe(\.currentPreviewItemIndex, options: [.new]) { [weak self] _, change in
            guard let index = change.newValue else { return }
            Task { @MainActor [weak self] in
                self?.syncSelection(forIndex: index)
            }
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

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return false }

        switch event.keyCode {
        case 123, 126: // left, up
            let direction: MoveCommandDirection = event.keyCode == 123 ? .left : .up
            return moveSelection(in: panel, direction: direction)
        case 124, 125: // right, down
            let direction: MoveCommandDirection = event.keyCode == 124 ? .right : .down
            return moveSelection(in: panel, direction: direction)
        default:
            return false
        }
    }

    private func syncSelection(forIndex index: Int) {
        guard items.indices.contains(index) else { return }
        model?.setSelectionFromQuickLook(items[index] as URL)
    }

    private func moveSelection(in panel: QLPreviewPanel, direction: MoveCommandDirection) -> Bool {
        guard !items.isEmpty else { return false }

        if let model {
            switch model.browserViewMode {
            case .gallery:
                model.moveSelectionInGallery(direction: direction, extendingSelection: false)
            case .list:
                switch direction {
                case .up, .down:
                    model.moveSelectionInList(direction: direction, extendingSelection: false)
                case .left:
                    _ = moveLinearly(in: panel, delta: -1)
                case .right:
                    _ = moveLinearly(in: panel, delta: 1)
                default:
                    return false
                }
            }

            if let selectedURL = model.primarySelectionURL,
               let selectedIndex = items.firstIndex(where: { ($0 as URL) == selectedURL }) {
                panel.currentPreviewItemIndex = selectedIndex
                return true
            }
        }

        return moveLinearly(in: panel, delta: direction == .left || direction == .up ? -1 : 1)
    }

    private func moveLinearly(in panel: QLPreviewPanel, delta: Int) -> Bool {
        let current = panel.currentPreviewItemIndex
        let fallback = current >= 0 ? current : 0
        let proposed = fallback + delta
        let clamped = min(max(proposed, 0), items.count - 1)
        guard clamped != current else { return true }
        panel.currentPreviewItemIndex = clamped
        syncSelection(forIndex: clamped)
        return true
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
