import AppKit
import Combine
import ExifEditCore
import Foundation
import OSLog
import Quartz
import SharedUI
import SwiftUI

let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ExifEdit", category: "AppModel")

enum ThumbnailPipeline {
    static func cachedImage(for fileURL: URL, minRenderedSide: CGFloat) -> NSImage? {
        ThumbnailService.cachedImage(for: fileURL, minRenderedSide: minRenderedSide)
    }

    static func storeCachedImage(_ image: NSImage, for fileURL: URL, renderedSide: CGFloat) {
        ThumbnailService.storeCachedImage(image, for: fileURL, renderedSide: renderedSide)
    }

    static func invalidateAllCachedImages() {
        ThumbnailService.invalidateAllCachedImages()
    }

    static func invalidateCachedImages(for fileURLs: Set<URL>) {
        ThumbnailService.invalidateCachedImages(for: fileURLs)
    }

    static func fallbackIcon(for fileURL: URL, side: CGFloat) -> NSImage {
        ThumbnailService.fallbackIcon(for: fileURL, side: side)
    }

}

enum AppBrand {
    private static let fallbackDisplayName = "Ledger"
    static let legacyDisplayNames = ["Logbook", "ExifEditMac"]
    static let migrationSentinelKey = "Ledger.Migration.v1Completed"

    static var displayName: String {
        let bundle = Bundle.main
        if let display = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
           !display.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return display
        }
        if let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }
        return fallbackDisplayName
    }

    static var identifierPrefix: String {
        let cleaned = displayName.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
        return cleaned.isEmpty ? fallbackDisplayName : cleaned
    }

    static var supportDirectoryName: String {
        displayName
    }

    private static func applicationSupportRootURL(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    }

    static func currentSupportDirectoryURL(fileManager: FileManager = .default) -> URL {
        applicationSupportRootURL(fileManager: fileManager)
            .appendingPathComponent(supportDirectoryName, isDirectory: true)
    }

    static func legacySupportDirectoryURLs(fileManager: FileManager = .default) -> [URL] {
        let root = applicationSupportRootURL(fileManager: fileManager)
        return legacyDisplayNames.map { root.appendingPathComponent($0, isDirectory: true) }
    }

    static var localizedTrashDisplayName: String {
        let trashPath = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".Trash", isDirectory: true).path
        let displayName = FileManager.default.displayName(atPath: trashPath).trimmingCharacters(in: .whitespacesAndNewlines)
        if displayName.isEmpty {
            return "Trash"
        }
        if displayName.caseInsensitiveCompare("Trash") == .orderedSame,
           Locale.current.region?.identifier == "GB" {
            return "Bin"
        }
        return displayName
    }
}

enum AppTheme {
    static var accentNSColor: NSColor {
        NSColor(named: "AccentColor") ?? .systemTeal
    }

    static var accentColor: Color {
        Color(nsColor: accentNSColor)
    }
}

protocol SidebarFavoritesStoreProtocol {
    func loadFavorites() throws -> [SidebarFavorite]
    func saveFavorites(_ favorites: [SidebarFavorite]) throws
}

protocol RecentLocationsStoreProtocol {
    func loadRecentLocations() throws -> [RecentLocation]
    func saveRecentLocations(_ locations: [RecentLocation]) throws
}

struct SidebarFavorite: Codable, Hashable, Identifiable {
    var id: String { path }
    let path: String
    let displayName: String
    let order: Int
}

struct RecentLocation: Codable, Hashable, Identifiable {
    var id: String { path }
    let path: String
    let displayName: String
    let order: Int
    let lastOpenedAt: Date?
}

struct SidebarFavoritesStore: SidebarFavoritesStoreProtocol {
    struct Envelope: Codable {
        let schemaVersion: Int
        let favorites: [SidebarFavorite]
    }

    static let schemaVersion = 1
    let fileURL: URL

    init(fileURL: URL = SidebarFavoritesStore.currentFileURL()) {
        self.fileURL = fileURL
    }

    func loadFavorites() throws -> [SidebarFavorite] {
        let fileManager = FileManager.default
        let candidates = [fileURL] + Self.legacyFileURLs()
        guard let sourceURL = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) else {
            return []
        }

        let data = try Data(contentsOf: sourceURL)
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        if envelope.schemaVersion > Self.schemaVersion {
            return []
        }
        return envelope.favorites
    }

    func saveFavorites(_ favorites: [SidebarFavorite]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let envelope = Envelope(schemaVersion: Self.schemaVersion, favorites: favorites)
        let data = try JSONEncoder().encode(envelope)
        let temporaryURL = directory.appendingPathComponent("sidebar_favorites.tmp.\(UUID().uuidString)")
        try data.write(to: temporaryURL, options: .atomic)

        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporaryURL)
        } else {
            try FileManager.default.moveItem(at: temporaryURL, to: fileURL)
        }
    }

    static func currentFileURL() -> URL {
        AppBrand.currentSupportDirectoryURL()
            .appendingPathComponent("sidebar_favorites.json", isDirectory: false)
    }

    static func legacyFileURLs() -> [URL] {
        AppBrand.legacySupportDirectoryURLs().map {
            $0.appendingPathComponent("sidebar_favorites.json", isDirectory: false)
        }
    }
}

struct RecentLocationsStore: RecentLocationsStoreProtocol {
    struct Envelope: Codable {
        let schemaVersion: Int
        let locations: [RecentLocation]
    }

    static let schemaVersion = 1
    let fileURL: URL

    init(fileURL: URL = RecentLocationsStore.currentFileURL()) {
        self.fileURL = fileURL
    }

    func loadRecentLocations() throws -> [RecentLocation] {
        let fileManager = FileManager.default
        let candidates = [fileURL] + Self.legacyFileURLs()
        guard let sourceURL = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) else {
            return []
        }

        let data = try Data(contentsOf: sourceURL)
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        if envelope.schemaVersion > Self.schemaVersion {
            return []
        }
        return envelope.locations
    }

    func saveRecentLocations(_ locations: [RecentLocation]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let envelope = Envelope(schemaVersion: Self.schemaVersion, locations: locations)
        let data = try JSONEncoder().encode(envelope)
        let temporaryURL = directory.appendingPathComponent("recent_locations.tmp.\(UUID().uuidString)")
        try data.write(to: temporaryURL, options: .atomic)

        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporaryURL)
        } else {
            try FileManager.default.moveItem(at: temporaryURL, to: fileURL)
        }
    }

    static func currentFileURL() -> URL {
        AppBrand.currentSupportDirectoryURL()
            .appendingPathComponent("recent_locations.json", isDirectory: false)
    }

    static func legacyFileURLs() -> [URL] {
        AppBrand.legacySupportDirectoryURLs().map {
            $0.appendingPathComponent("recent_locations.json", isDirectory: false)
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let galleryColumnRange = 2 ... 9

    enum BrowserViewMode: String, CaseIterable, Identifiable {
        case gallery
        case list

        var id: String { rawValue }
    }

    enum SidebarKind: Hashable {
        case pictures
        case desktop
        case downloads
        case mountedVolume(URL)
        case favorite(URL)
        case folder(URL)
    }

    enum FileActionID: CaseIterable {
        case openInDefaultApp
        case sendToPhotos
        case sendToLightroom
        case sendToLightroomClassic
        case refreshMetadata
        case applyMetadataChanges
        case clearMetadataChanges
        case restoreFromLastBackup
        case batchRenameSelection
        case batchRenameFolder
    }

    struct FileActionState: Hashable {
        let id: FileActionID
        let title: String
        let symbolName: String
        let isEnabled: Bool
    }

    enum BrowserSort: String, CaseIterable, Identifiable {
        case name
        case created
        case modified
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
            .init(id: "exif-serial", namespace: .exif, key: "SerialNumber", label: "Serial Number", section: "Camera"),
            .init(id: "exif-lens", namespace: .exif, key: "LensModel", label: "Lens Model", section: "Camera"),
            .init(id: "exif-aperture", namespace: .exif, key: "FNumber", label: "Aperture", section: "Capture"),
            .init(id: "exif-shutter", namespace: .exif, key: "ExposureTime", label: "Shutter Speed", section: "Capture"),
            .init(id: "exif-iso", namespace: .exif, key: "ISO", label: "ISO", section: "Capture"),
            .init(id: "exif-focal", namespace: .exif, key: "FocalLength", label: "Focal Length", section: "Capture"),
            .init(id: "exif-exposure-program", namespace: .exif, key: "ExposureProgram", label: "Exposure Program", section: "Capture"),
            .init(id: "exif-flash", namespace: .exif, key: "Flash", label: "Flash", section: "Capture"),
            .init(id: "exif-metering-mode", namespace: .exif, key: "MeteringMode", label: "Metering Mode", section: "Capture"),
            .init(id: "exif-exposure-comp", namespace: .exif, key: "ExposureCompensation", label: "Exposure Compensation", section: "Capture"),
            .init(id: "datetime-created", namespace: .exif, key: "DateTimeOriginal", label: "Original", section: "Date and Time"),
            .init(id: "datetime-digitized", namespace: .exif, key: "CreateDate", label: "Digitised", section: "Date and Time"),
            .init(id: "datetime-modified", namespace: .exif, key: "ModifyDate", label: "Modified", section: "Date and Time"),
            .init(id: "exif-gps-lat", namespace: .exif, key: "GPSLatitude", label: "Latitude", section: "Location"),
            .init(id: "exif-gps-lon", namespace: .exif, key: "GPSLongitude", label: "Longitude", section: "Location"),
            .init(id: "exif-gps-alt", namespace: .exif, key: "GPSAltitude", label: "Altitude", section: "Location"),
            .init(id: "exif-gps-direction", namespace: .exif, key: "GPSImgDirection", label: "Direction", section: "Location"),
            .init(id: "iptc-sublocation",  namespace: .xmpIptcCore,  key: "Location",              label: "Sublocation",      section: "Location"),
            .init(id: "iptc-city",         namespace: .xmpPhotoshop, key: "City",                  label: "City",             section: "Location"),
            .init(id: "iptc-state",        namespace: .xmpPhotoshop, key: "State",                 label: "State / Province", section: "Location"),
            .init(id: "iptc-country",      namespace: .xmpPhotoshop, key: "Country",               label: "Country",          section: "Location"),
            .init(id: "iptc-country-code", namespace: .xmpIptcCore,  key: "CountryCode",           label: "Country Code",     section: "Location"),
            .init(id: "xmp-title", namespace: .xmp, key: "Title", label: "Title", section: "Descriptive"),
            .init(id: "xmp-description", namespace: .xmp, key: "Description", label: "Description", section: "Descriptive"),
            .init(id: "xmp-subject", namespace: .xmp, key: "Subject", label: "Keywords", section: "Descriptive"),
            .init(id: "xmp-headline",      namespace: .xmpPhotoshop, key: "Headline",              label: "Headline",         section: "Editorial"),
            .init(id: "xmp-caption-writer", namespace: .xmpPhotoshop, key: "CaptionWriter",        label: "Caption Writer",   section: "Editorial"),
            .init(id: "xmp-credit",         namespace: .xmpPhotoshop, key: "Credit",               label: "Credit",           section: "Editorial"),
            .init(id: "xmp-source",         namespace: .xmpPhotoshop, key: "Source",               label: "Source",           section: "Editorial"),
            .init(id: "xmp-instructions",   namespace: .xmpPhotoshop, key: "Instructions",         label: "Instructions",     section: "Editorial"),
            .init(id: "xmp-job-id",         namespace: .xmpPhotoshop, key: "TransmissionReference", label: "Job ID",          section: "Editorial"),
            .init(id: "exif-artist", namespace: .exif, key: "Artist", label: "Artist", section: "Rights"),
            .init(id: "exif-copyright", namespace: .exif, key: "Copyright", label: "Copyright", section: "Rights"),
            .init(id: "xmp-creator", namespace: .xmp, key: "Creator", label: "Creator", section: "Rights"),
            .init(id: "xmp-copyright-status", namespace: .xmpRights, key: "Marked",          label: "Copyright Status", section: "Rights"),
            .init(id: "xmp-usage-terms",      namespace: .xmpRights, key: "UsageTerms",      label: "Usage Terms",      section: "Rights"),
            .init(id: "xmp-copyright-url",    namespace: .xmpRights, key: "WebStatement",    label: "Copyright URL",    section: "Rights"),
        ]

        static let rating = EditableTag(id: "xmp-rating", namespace: .xmp,   key: "Rating", label: "Star Rating",  section: "Rating")
        static let pick   = EditableTag(id: "xmp-pick",   namespace: .xmpDM, key: "Pick",   label: "Flag",         section: "Rating")
        static let label  = EditableTag(id: "xmp-label",  namespace: .xmp,   key: "Label",  label: "Colour Label", section: "Rating")
    }

    struct FieldCatalogEntry: Hashable, Identifiable {
        let id: String
        let namespace: MetadataNamespace
        let key: String
        let label: String
        let section: String
        let inputKind: ImportFieldInputKind
        let isEnabled: Bool

        func withEnabled(_ isEnabled: Bool) -> FieldCatalogEntry {
            FieldCatalogEntry(
                id: id,
                namespace: namespace,
                key: key,
                label: label,
                section: section,
                inputKind: inputKind,
                isEnabled: isEnabled
            )
        }
    }

    struct PickerOption: Identifiable, Hashable {
        var id: String { value }
        let value: String
        let label: String
    }

    enum StagedEditSource: Hashable {
        case manual
        case preset(UUID)
        case importSource(ImportSourceKind)
    }

    struct StagedEditRecord: Hashable {
        let value: String
        let source: StagedEditSource
        let updatedAt: Date
    }

    enum StagedImageOperation: Hashable, Sendable {
        case rotateLeft90
        case flipHorizontal
    }

    struct ImageTransformMatrix: Hashable {
        let a: Int
        let b: Int
        let c: Int
        let d: Int

        static let identity = ImageTransformMatrix(a: 1, b: 0, c: 0, d: 1)
        static let rotateLeft90 = ImageTransformMatrix(a: 0, b: -1, c: 1, d: 0)
        static let flipHorizontal = ImageTransformMatrix(a: -1, b: 0, c: 0, d: 1)

        func multiplied(by rhs: ImageTransformMatrix) -> ImageTransformMatrix {
            ImageTransformMatrix(
                a: a * rhs.a + b * rhs.c,
                b: a * rhs.b + b * rhs.d,
                c: c * rhs.a + d * rhs.c,
                d: c * rhs.b + d * rhs.d
            )
        }
    }

    struct EditSessionSnapshot {
        let tag: EditableTag
        let draftValue: String
        let selectedFileURLs: [URL]
        let stagedValuesByFile: [URL: StagedEditRecord]
    }

    struct EditableTagSectionGroup: Identifiable {
        let section: String
        let tags: [EditableTag]

        var id: String { section }
    }

    struct PendingEditState: Equatable {
        let pendingEditsByFile: [URL: [EditableTag: StagedEditRecord]]
        let pendingImageOpsByFile: [URL: [StagedImageOperation]]
    }

    @Published var sidebarItems: [SidebarItem] = []
    @Published var sidebarImageCounts: [String: Int] = [:]
    @Published var selectedSidebarID: String?
    @Published var isSidebarCollapsed = false
    @Published var isInspectorCollapsed = false
    @Published var browserItems: [BrowserItem] = [] {
        didSet { rebuildFilteredBrowserItems() }
    }
    @Published var browserSort: BrowserSort {
        didSet {
            UserDefaults.standard.set(browserSort.rawValue, forKey: Self.browserSortKey)
            rebuildFilteredBrowserItems()
        }
    }
    @Published var browserSortAscending: Bool {
        didSet {
            UserDefaults.standard.set(browserSortAscending, forKey: Self.browserSortAscendingKey)
            rebuildFilteredBrowserItems()
        }
    }
    @Published var selectedFileURLs: Set<URL> = []
    @Published var browserViewMode: BrowserViewMode {
        didSet { UserDefaults.standard.set(browserViewMode.rawValue, forKey: Self.browserViewModeKey) }
    }
    @Published var galleryGridLevel: Int {
        didSet { UserDefaults.standard.set(galleryGridLevel, forKey: Self.galleryGridLevelKey) }
    }
    @Published var metadataByFile: [URL: FileMetadataSnapshot] = [:]
    @Published var activeInspectorFieldCatalog: [FieldCatalogEntry] = AppModel.defaultFieldCatalogEntries()
    @Published var confirmBeforeApply = true {
        didSet { UserDefaults.standard.set(confirmBeforeApply, forKey: Self.confirmBeforeApplyKey) }
    }
    @Published var autoRefreshMetadataAfterApply = true {
        didSet { UserDefaults.standard.set(autoRefreshMetadataAfterApply, forKey: Self.autoRefreshAfterApplyKey) }
    }
    @Published var keepBackups = true {
        didSet { UserDefaults.standard.set(keepBackups, forKey: Self.keepBackupsKey) }
    }
    @Published var backupRetentionCount: Int = 20 {
        didSet { UserDefaults.standard.set(backupRetentionCount, forKey: Self.backupRetentionCountKey) }
    }
    @Published var draftValues: [EditableTag: String] = [:]
    @Published var baselineValues: [EditableTag: String?] = [:]
    @Published var presets: [MetadataPreset] = []
    @Published var selectedPresetID: UUID? {
        didSet {
            UserDefaults.standard.set(selectedPresetID?.uuidString, forKey: Self.selectedPresetIDKey)
        }
    }
    @Published var activePresetEditor: PresetEditorState? {
        didSet {
            notifyInspectorDidChange()
        }
    }
    @Published var activeWelcomePresentation: AppWelcomePresentation?
    @Published var isManagePresetsPresented = false {
        didSet {
            notifyInspectorDidChange()
        }
    }
    @Published var pendingImportSourceKind: ImportSourceKind? {
        didSet { notifyInspectorDidChange() }
    }
    @Published var pendingBatchRenameScope: BatchRenameScope?
    @Published var pendingDateTimeAdjustSession: DateTimeAdjustSession?
    @Published var pendingLocationAdjustSession: LocationAdjustSession?
    var locationPersistedCoordinates: Bool = true
    var locationPersistedAdvancedFields: Set<LocationAdvancedField> = []
    @Published var isRenaming = false
    @Published var renameProgress: (completed: Int, total: Int) = (0, 0)
    /// Maps current on-disk URL → proposed final filename (basename + ext).
    /// Populated when the user stages a batch rename; cleared on apply or discard.
    @Published var pendingRenameByFile: [URL: String] = [:]
    // Search UI removed for v1.0 (name-only, aesthetically wrong). Property kept
    // so filteredBrowserItems/rebuildFilteredBrowserItems can be wired up for R14
    // (metadata-aware search) without a data-model rewrite.
    @Published var searchQuery = "" {
        didSet { rebuildFilteredBrowserItems() }
    }
    @Published var statusMessage = "Ready"
    @Published var browserThumbnailInvalidationToken = UUID()
    @Published var browserThumbnailInvalidatedURLs: Set<URL> = []
    /// Bumped on every staged image operation so the gallery can refresh display transforms
    /// without clearing the thumbnail pipeline cache (no async re-fetch needed).
    @Published var stagedOpsDisplayToken: UInt64 = 0
    @Published var isFolderContentLoading = false
    @Published var isFolderMetadataLoading = false
    @Published var folderMetadataLoadCompleted = 0
    @Published var folderMetadataLoadTotal = 0
    @Published var browserEnumerationError: Error? = nil
    @Published var isApplyingMetadata = false
    @Published var applyMetadataCompleted = 0
    @Published var applyMetadataTotal = 0
    @Published var isPreviewPreloading = false
    @Published var collapsedInspectorSections: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(collapsedInspectorSections), forKey: Self.collapsedInspectorSectionsKey)
            notifyInspectorDidChange()
        }
    }
    @Published var inspectorRefreshRevision: UInt64 = 0

    @Published var pendingEditsByFile: [URL: [EditableTag: StagedEditRecord]] = [:]
    @Published var pendingImageOpsByFile: [URL: [StagedImageOperation]] = [:]

    var pendingEditsCount: Int {
        Set(pendingEditsByFile.keys).union(pendingImageOpsByFile.keys).count
    }

    private var badgeObservers: [AnyCancellable] = []
    /// Values written to disk but not yet confirmed by an exiftool re-read.
    /// Sits between pendingEditsByFile and availableSnapshot in the inspector priority order
    /// so the inspector shows the applied value during the reload gap rather than the old on-disk snapshot.
    var pendingCommitsByFile: [URL: [EditableTag: String]] = [:]
    @Published var inspectorPreviewImages: [URL: NSImage] = [:]
    var mixedTags: Set<EditableTag> = []
    var editSessionSnapshotsByTagID: [String: EditSessionSnapshot] = [:]
    /// Set to true the first time selectSidebar(id:) is called, meaning the user
    /// has explicitly chosen a sidebar item (vs. SwiftUI auto-selecting at startup).
    var hasHadExplicitSidebarSelection = false
    var favoriteItems: [SidebarItem] = []
    var locationItems: [SidebarItem] = []
    var recentLocationLastOpenedAtByID: [String: Date] = [:]
    var folderMetadataLoadTask: Task<Void, Never>?
    var folderMetadataLoadID = UUID()
    var browserItemHydrationTask: Task<Void, Never>?
    var browserItemHydrationID = UUID()
    var selectionMetadataLoadTask: Task<Void, Never>?
    var previewPreloadTask: Task<Void, Never>?
    var deferredFolderMetadataPrefetchTask: Task<Void, Never>?
    var deferredPreviewPreloadTask: Task<Void, Never>?
    var activeFolderLoadID = UUID()
    var previewPreloadID = UUID()
    var inspectorPreviewInflight: Set<URL> = []
    var inspectorPreviewTasksByURL: [URL: Task<Void, Never>] = [:]
    var inspectorPreviewRecency: [URL] = []
    var staleMetadataFiles: Set<URL> = []
    var selectionAnchorURL: URL?
    var selectionFocusURL: URL?
    var quickLookSourceFrames: [URL: NSRect] = [:]
    var stagedQuickLookPreviewFiles: [URL: URL] = [:]
    var stagedQuickLookPreviewGenerationInFlight: Set<URL> = []

    let engine: ExifEditEngine
    let presetStore: PresetStoreProtocol
    let favoritesStore: SidebarFavoritesStoreProtocol
    let recentLocationsStore: RecentLocationsStoreProtocol
    var lastOperationIDs: [UUID] = []
    var lastOperationFilesByID: [UUID: Set<URL>] = [:]
    var statusResetTask: Task<Void, Never>?
    var inspectorDebounceTask: Task<Void, Never>?
    var metadataUndoStack: [PendingEditState] = []
    var metadataRedoStack: [PendingEditState] = []
    var isApplyingMetadataUndoState = false
    var undoCoalescingTagID: String? = nil
    var workspaceObserverTokens: [NSObjectProtocol] = []
    var sidebarImageCountTasks: [String: Task<Void, Never>] = [:]
    var backgroundWarmTasksBySelectionID: [String: Task<Void, Never>] = [:]
    var photosImportStagingDirectory: URL?

    private static let browserViewModeKey = "ui.browser.view.mode"
    private static let browserSortKey = "ui.browser.sort"
    private static let browserSortAscendingKey = "ui.browser.sort.ascending"
    private static let galleryGridLevelKey = "ui.gallery.grid.level"
    private static let galleryZoomKey = "ui.gallery.zoom"
    private static let collapsedInspectorSectionsKey = "ui.inspector.collapsed.sections"
    private static let selectedPresetIDKey = "ui.presets.selected.id"
    private static let confirmBeforeApplyKey = "ui.settings.confirm.before.apply"
    private static let autoRefreshAfterApplyKey = "ui.settings.auto.refresh.after.apply"
    private static let keepBackupsKey = "ui.settings.keep.backups"
    private static let backupRetentionCountKey = "ui.settings.backup.retention.count"
    static let inspectorFieldVisibilityKey = "ui.settings.inspector.field.visibility"
    static let legacyUserDefaultsPrefixes = ["Logbook"]
    static let selectionMetadataBatchSize = 120
    static let selectionMetadataDebounceNanoseconds: UInt64 = 90_000_000
    static let folderMetadataBatchSize = 8
    static let metadataReadTimeoutNanoseconds: UInt64 = 8_000_000_000
    static let previewBulkStartDelayNanoseconds: UInt64 = 220_000_000
    static let metadataPrefetchStartDelayNanoseconds: UInt64 = 280_000_000
    static let initialThumbnailWarmupCount = 56
    static let initialThumbnailWarmupSide: CGFloat = 180
    static let inspectorPreviewTargetSide: CGFloat = 700
    static let inspectorPreviewFullSide: CGFloat = 1400
    static let maxInspectorPreviewCacheEntries = 48
    static let previewPreloadNeighborRadius = 10
    static let maxPreviewPreloadCandidates = 64
    static let maxRecentLocations = 20
    nonisolated static let supportedImageExtensions: Set<String> = [
        "jpg", "jpeg", "tif", "tiff", "png", "heic", "heif", "dng", "arw", "cr2", "cr3", "nef", "orf", "rw2", "raf"
    ]

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
        if !pendingEditsByFile.isEmpty {
            return true
        }
        if !pendingRenameByFile.isEmpty {
            return true
        }
        return pendingImageOpsByFile.values.contains { !Self.normalizeStagedImageOperations($0).isEmpty }
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

    var primarySelectionURL: URL? {
        if let focus = selectionFocusURL, selectedFileURLs.contains(focus) {
            return focus
        }
        return selectedFileURLs.sorted(by: { $0.path < $1.path }).first
    }

    init(
        exifToolService: ExifToolServiceProtocol? = nil,
        presetStore: PresetStoreProtocol = FilePresetStore(),
        favoritesStore: SidebarFavoritesStoreProtocol = SidebarFavoritesStore(),
        recentLocationsStore: RecentLocationsStoreProtocol = RecentLocationsStore()
    ) {
        Self.performBrandMigrationsIfNeeded()
        let defaults = UserDefaults.standard
        browserViewMode = BrowserViewMode(
            rawValue: Self.firstUserDefaultsValue(for: Self.browserViewModeKey, defaults: defaults, as: String.self) ?? ""
        ) ?? .gallery
        browserSort = BrowserSort(
            rawValue: Self.firstUserDefaultsValue(for: Self.browserSortKey, defaults: defaults, as: String.self) ?? ""
        ) ?? .name
        browserSortAscending = Self.firstUserDefaultsValue(for: Self.browserSortAscendingKey, defaults: defaults, as: Bool.self) ?? true
        let storedLevel = Self.firstUserDefaultsValue(for: Self.galleryGridLevelKey, defaults: defaults, as: Int.self) ?? 0
        if storedLevel == 0 {
            // One-time fallback from legacy floating zoom persistence.
            let legacyZoom = Self.firstUserDefaultsValue(for: Self.galleryZoomKey, defaults: defaults, as: Double.self) ?? 0
            if legacyZoom > 0 {
                galleryGridLevel = Self.columnCount(forLegacyZoom: CGFloat(legacyZoom))
            } else {
                galleryGridLevel = 4
            }
        } else {
            galleryGridLevel = min(max(storedLevel, Self.galleryColumnRange.lowerBound), Self.galleryColumnRange.upperBound)
        }

        let service: ExifToolServiceProtocol
        if let exifToolService {
            service = exifToolService
            statusMessage = "Ready"
        } else if let live = try? ExifToolService() {
            service = live
            statusMessage = "Ready"
        } else {
            service = UnavailableExifToolService()
            statusMessage = "\(AppBrand.displayName) requires ExifTool to work. Try reinstalling the app."
            Task { @MainActor in
                let alert = NSAlert()
                alert.messageText = "\(AppBrand.displayName) requires exiftool"
                alert.informativeText = "The exiftool executable could not be found. The app bundle may be corrupted. Please reinstall \(AppBrand.displayName)."
                alert.alertStyle = .critical
                alert.addButton(withTitle: "OK")
                alert.runSheetOrModal(for: nil) { _ in }
            }
        }

        let backupDirectory = AppBrand.currentSupportDirectoryURL().appendingPathComponent("Backups", isDirectory: true)
        engine = ExifEditEngine(exifToolService: service, backupManager: BackupManager(baseDirectory: backupDirectory))
        self.presetStore = presetStore
        self.favoritesStore = favoritesStore
        self.recentLocationsStore = recentLocationsStore

        let storedCollapsed = Self.firstUserDefaultsValue(
            for: Self.collapsedInspectorSectionsKey,
            defaults: defaults,
            as: [String].self
        ) ?? []
        collapsedInspectorSections = Set(storedCollapsed)
        confirmBeforeApply = Self.firstUserDefaultsValue(
            for: Self.confirmBeforeApplyKey,
            defaults: defaults,
            as: Bool.self
        ) ?? true
        autoRefreshMetadataAfterApply = Self.firstUserDefaultsValue(
            for: Self.autoRefreshAfterApplyKey,
            defaults: defaults,
            as: Bool.self
        ) ?? true
        keepBackups = Self.firstUserDefaultsValue(
            for: Self.keepBackupsKey,
            defaults: defaults,
            as: Bool.self
        ) ?? true
        backupRetentionCount = Self.firstUserDefaultsValue(
            for: Self.backupRetentionCountKey,
            defaults: defaults,
            as: Int.self
        ) ?? 20
        let visibility = Self.firstUserDefaultsValue(
            for: Self.inspectorFieldVisibilityKey,
            defaults: defaults,
            as: [String: Bool].self
        ) ?? [:]
        activeInspectorFieldCatalog = activeInspectorFieldCatalog.map { entry in
            guard let enabled = visibility[entry.id] else { return entry }
            return entry.withEnabled(enabled)
        }
        persistInspectorFieldVisibility()
        reconcileAndLoadFavorites()
        reconcileAndLoadRecentLocations()
        sidebarItems = composedSidebarItems()
        installWorkspaceVolumeObservers()
        if let selectedPresetRaw = Self.firstUserDefaultsValue(for: Self.selectedPresetIDKey, defaults: defaults, as: String.self),
           let selectedPresetUUID = UUID(uuidString: selectedPresetRaw) {
            selectedPresetID = selectedPresetUUID
        }
        loadPresets()
        let retentionCount = backupRetentionCount
        Task.detached(priority: .background) { [backupDirectory, retentionCount] in
            try? BackupManager(baseDirectory: backupDirectory).pruneOperations(keepLast: retentionCount)
        }

        $pendingEditsByFile.combineLatest($pendingImageOpsByFile)
            .sink { edits, imageOps in
                let count = Set(edits.keys).union(imageOps.keys).count
                NSApp?.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
            }
            .store(in: &badgeObservers)
    }


    static func columnCount(forLegacyZoom zoom: CGFloat) -> Int {
        let legacyZoomMin = CGFloat(0.55)
        let legacyZoomMax = CGFloat(3.0)
        let clampedZoom = min(max(zoom, legacyZoomMin), legacyZoomMax)
        let normalized = (clampedZoom - legacyZoomMin) / (legacyZoomMax - legacyZoomMin)
        let reversed = 1 - normalized
        let span = CGFloat(Self.galleryColumnRange.upperBound - Self.galleryColumnRange.lowerBound)
        let raw = CGFloat(Self.galleryColumnRange.lowerBound) + reversed * span
        return Int(raw.rounded())
    }




    @Published var filteredBrowserItems: [BrowserItem] = []

}
