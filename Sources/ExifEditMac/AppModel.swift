import AppKit
import ExifEditCore
import Foundation
import ImageIO
import OSLog
import QuickLookThumbnailing
import Quartz
import SwiftUI

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ExifEdit", category: "AppModel")

final class SharedBrowserThumbnailCache: @unchecked Sendable {
    static let shared = SharedBrowserThumbnailCache(maxEntries: 3_000)

    private let maxEntries: Int
    private let lock = NSLock()
    private var images: [URL: NSImage] = [:]
    private var renderedSideByURL: [URL: CGFloat] = [:]
    private var recency: [URL] = []

    init(maxEntries: Int) {
        self.maxEntries = max(100, maxEntries)
    }

    func image(for url: URL, minRenderedSide: CGFloat) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        guard let image = images[url] else { return nil }
        if let rendered = renderedSideByURL[url], rendered + 0.5 < minRenderedSide {
            return nil
        }
        touch(url)
        return image
    }

    func store(_ image: NSImage, for url: URL, renderedSide: CGFloat) {
        lock.lock()
        defer { lock.unlock() }
        images[url] = image
        renderedSideByURL[url] = max(renderedSide, renderedSideByURL[url] ?? 0)
        touch(url)
        trimIfNeeded()
    }

    func invalidateAll() {
        lock.lock()
        defer { lock.unlock() }
        images.removeAll()
        renderedSideByURL.removeAll()
        recency.removeAll()
    }

    func invalidate(urls: Set<URL>) {
        guard !urls.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        for url in urls {
            images.removeValue(forKey: url)
            renderedSideByURL.removeValue(forKey: url)
        }
        recency.removeAll(where: { urls.contains($0) })
    }

    private func touch(_ url: URL) {
        recency.removeAll(where: { $0 == url })
        recency.append(url)
    }

    private func trimIfNeeded() {
        let overflow = images.count - maxEntries
        guard overflow > 0 else { return }
        let toRemove = recency.prefix(overflow)
        for url in toRemove {
            images.removeValue(forKey: url)
            renderedSideByURL.removeValue(forKey: url)
        }
        recency.removeFirst(min(overflow, recency.count))
    }
}

enum ThumbnailPipeline {
    static func cachedImage(for fileURL: URL, minRenderedSide: CGFloat) -> NSImage? {
        SharedBrowserThumbnailCache.shared.image(for: fileURL, minRenderedSide: minRenderedSide)
    }

    static func storeCachedImage(_ image: NSImage, for fileURL: URL, renderedSide: CGFloat) {
        SharedBrowserThumbnailCache.shared.store(image, for: fileURL, renderedSide: renderedSide)
    }

    static func invalidateAllCachedImages() {
        SharedBrowserThumbnailCache.shared.invalidateAll()
    }

    static func invalidateCachedImages(for fileURLs: Set<URL>) {
        SharedBrowserThumbnailCache.shared.invalidate(urls: fileURLs)
    }

    static func fallbackIcon(for fileURL: URL, side: CGFloat) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: fileURL.path)
        icon.size = NSSize(width: side, height: side)
        return icon
    }

    static func generateThumbnail(fileURL: URL, maxPixelSize: CGFloat) async -> NSImage? {
        if let cached = cachedImage(for: fileURL, minRenderedSide: maxPixelSize) {
            return cached
        }

        if isLikelyImageFile(fileURL) {
            if let oriented = generateOrientedThumbnail(fileURL: fileURL, maxPixelSize: maxPixelSize) {
                storeCachedImage(oriented, for: fileURL, renderedSide: maxPixelSize)
                return oriented
            }
            if let quickLook = await generateQuickLookThumbnail(fileURL: fileURL, maxPixelSize: maxPixelSize) {
                storeCachedImage(quickLook, for: fileURL, renderedSide: maxPixelSize)
                return quickLook
            }
        } else {
            if let quickLook = await generateQuickLookThumbnail(fileURL: fileURL, maxPixelSize: maxPixelSize) {
                storeCachedImage(quickLook, for: fileURL, renderedSide: maxPixelSize)
                return quickLook
            }
            if let oriented = generateOrientedThumbnail(fileURL: fileURL, maxPixelSize: maxPixelSize) {
                storeCachedImage(oriented, for: fileURL, renderedSide: maxPixelSize)
                return oriented
            }
        }
        if let decoded = NSImage(contentsOf: fileURL) {
            storeCachedImage(decoded, for: fileURL, renderedSide: maxPixelSize)
            return decoded
        }
        let fallback = fallbackIcon(for: fileURL, side: max(16, min(maxPixelSize, 256)))
        storeCachedImage(fallback, for: fileURL, renderedSide: maxPixelSize)
        return fallback
    }

    static func isLikelyImageFile(_ fileURL: URL) -> Bool {
        let imageExtensions: Set<String> = [
            "jpg", "jpeg", "heic", "heif", "png", "tif", "tiff", "gif", "bmp", "webp", "dng", "cr2", "cr3", "arw", "nef", "raf", "orf"
        ]
        return imageExtensions.contains(fileURL.pathExtension.lowercased())
    }

    private static func generateOrientedThumbnail(fileURL: URL, maxPixelSize: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(32, Int(maxPixelSize)),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: .zero)
    }

    private static func generateQuickLookThumbnail(fileURL: URL, maxPixelSize: CGFloat) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: fileURL,
            size: CGSize(width: maxPixelSize, height: maxPixelSize),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail
        )

        return await withCheckedContinuation { continuation in
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
    }
}

enum AppBrand {
    static let fallbackDisplayName = "Ledger"
    static let legacyDisplayNames = ["Logbook", "ExifEditMac"]

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

    static func applicationSupportRootURL(fileManager: FileManager = .default) -> URL {
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
}

enum AppTheme {
    static var accentNSColor: NSColor {
        NSColor(named: "BrandAccent") ?? .systemTeal
    }

    static var accentStrongNSColor: NSColor {
        NSColor(named: "BrandAccentStrong") ?? accentNSColor
    }

    static var accentSoftNSColor: NSColor {
        NSColor(named: "BrandAccentSoft") ?? accentNSColor.withAlphaComponent(0.18)
    }

    static var accentColor: Color {
        Color(nsColor: accentNSColor)
    }

    static var accentStrongColor: Color {
        Color(nsColor: accentStrongNSColor)
    }

    static var accentSoftColor: Color {
        Color(nsColor: accentSoftNSColor)
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
    private struct Envelope: Codable {
        let schemaVersion: Int
        let favorites: [SidebarFavorite]
    }

    private static let schemaVersion = 1
    private let fileURL: URL

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

    private static func legacyFileURLs() -> [URL] {
        AppBrand.legacySupportDirectoryURLs().map {
            $0.appendingPathComponent("sidebar_favorites.json", isDirectory: false)
        }
    }
}

struct RecentLocationsStore: RecentLocationsStoreProtocol {
    private struct Envelope: Codable {
        let schemaVersion: Int
        let locations: [RecentLocation]
    }

    private static let schemaVersion = 1
    private let fileURL: URL

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

    private static func legacyFileURLs() -> [URL] {
        AppBrand.legacySupportDirectoryURLs().map {
            $0.appendingPathComponent("recent_locations.json", isDirectory: false)
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    private static let galleryColumnRange = 2 ... 9

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
        case refreshMetadata
        case applyMetadataChanges
        case clearMetadataChanges
        case restoreFromLastBackup
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
            .init(id: "exif-lens", namespace: .exif, key: "LensModel", label: "Lens", section: "Camera"),
            .init(id: "exif-aperture", namespace: .exif, key: "FNumber", label: "Aperture", section: "Capture"),
            .init(id: "exif-shutter", namespace: .exif, key: "ExposureTime", label: "Shutter Speed", section: "Capture"),
            .init(id: "exif-iso", namespace: .exif, key: "ISO", label: "ISO", section: "Capture"),
            .init(id: "exif-focal", namespace: .exif, key: "FocalLength", label: "Focal Length", section: "Capture"),
            .init(id: "exif-exposure-program", namespace: .exif, key: "ExposureProgram", label: "Exposure Program", section: "Capture"),
            .init(id: "exif-flash", namespace: .exif, key: "Flash", label: "Flash", section: "Capture"),
            .init(id: "exif-metering-mode", namespace: .exif, key: "MeteringMode", label: "Metering Mode", section: "Capture"),
            .init(id: "datetime-modified", namespace: .exif, key: "ModifyDate", label: "Date Modified", section: "Date and Time"),
            .init(id: "datetime-digitized", namespace: .exif, key: "DateTimeDigitized", label: "Digitized", section: "Date and Time"),
            .init(id: "datetime-created", namespace: .exif, key: "DateTimeOriginal", label: "Date Created", section: "Date and Time"),
            .init(id: "exif-gps-lat", namespace: .exif, key: "GPSLatitude", label: "Latitude", section: "Location"),
            .init(id: "exif-gps-lon", namespace: .exif, key: "GPSLongitude", label: "Longitude", section: "Location"),
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

    private struct ImageTransformMatrix: Hashable {
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

    private struct PendingEditState: Equatable {
        let pendingEditsByFile: [URL: [EditableTag: StagedEditRecord]]
        let pendingImageOpsByFile: [URL: [StagedImageOperation]]
    }

    @Published var sidebarItems: [SidebarItem] = []
    @Published private(set) var sidebarImageCounts: [String: Int] = [:]
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
    @Published var isManagePresetsPresented = false {
        didSet {
            notifyInspectorDidChange()
        }
    }
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
    @Published var lastResult: OperationResult? {
        didSet {
            notifyInspectorDidChange()
        }
    }
    @Published var isFolderMetadataLoading = false
    @Published var folderMetadataLoadCompleted = 0
    @Published var folderMetadataLoadTotal = 0
    @Published var browserEnumerationError: Error? = nil
    @Published var isApplyingMetadata = false
    @Published var applyMetadataCompleted = 0
    @Published var applyMetadataTotal = 0
    @Published var isPreviewPreloading = false
    @Published var previewPreloadCompleted = 0
    @Published var previewPreloadTotal = 0
    @Published var collapsedInspectorSections: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(collapsedInspectorSections), forKey: Self.collapsedInspectorSectionsKey)
            notifyInspectorDidChange()
        }
    }
    @Published private(set) var inspectorRefreshRevision: UInt64 = 0

    @Published private var pendingEditsByFile: [URL: [EditableTag: StagedEditRecord]] = [:]
    @Published private var pendingImageOpsByFile: [URL: [StagedImageOperation]] = [:]
    /// Values written to disk but not yet confirmed by an exiftool re-read.
    /// Sits between pendingEditsByFile and availableSnapshot in the inspector priority order
    /// so the inspector shows the applied value during the reload gap rather than the old on-disk snapshot.
    private var pendingCommitsByFile: [URL: [EditableTag: String]] = [:]
    @Published private var inspectorPreviewImages: [URL: NSImage] = [:]
    @Published private var inspectorPreviewRenderedSide: [URL: CGFloat] = [:]
    private var mixedTags: Set<EditableTag> = []
    private var isRevertingSidebarSelection = false
    private var suppressNextSidebarSelectionChange = false
    /// Set to true the first time selectSidebar(id:) is called, meaning the user
    /// has explicitly chosen a sidebar item (vs. SwiftUI auto-selecting at startup).
    private var hasHadExplicitSidebarSelection = false
    /// System uptime (seconds since boot) recorded at init. Used to reject stale
    /// pre-launch events (Dock click, Finder double-click) that are still set as
    /// NSApp.currentEvent when the SwiftUI List performs its first-render auto-selection.
    private let initializationUptime = ProcessInfo.processInfo.systemUptime
    private var favoriteItems: [SidebarItem] = []
    private var locationItems: [SidebarItem] = []
    private var recentLocationLastOpenedAtByID: [String: Date] = [:]
    private var folderMetadataLoadTask: Task<Void, Never>?
    private var folderMetadataLoadID = UUID()
    private var browserItemHydrationTask: Task<Void, Never>?
    private var browserItemHydrationID = UUID()
    private var selectionMetadataLoadTask: Task<Void, Never>?
    private var previewPreloadTask: Task<Void, Never>?
    private var deferredPreviewPreloadTask: Task<Void, Never>?
    private var previewPreloadID = UUID()
    private var inspectorPreviewInflight: Set<URL> = []
    private var inspectorPreviewTasksByURL: [URL: Task<Void, Never>] = [:]
    private var inspectorPreviewRecency: [URL] = []
    private var staleMetadataFiles: Set<URL> = []
    private var selectionAnchorURL: URL?
    private var selectionFocusURL: URL?
    private var quickLookSourceFrames: [URL: NSRect] = [:]
    private var stagedQuickLookPreviewFiles: [URL: URL] = [:]
    private var stagedQuickLookPreviewGenerationInFlight: Set<URL> = []

    private let engine: ExifEditEngine
    private let presetStore: PresetStoreProtocol
    private let favoritesStore: SidebarFavoritesStoreProtocol
    private let recentLocationsStore: RecentLocationsStoreProtocol
    private var lastOperationIDs: [UUID] = []
    private var lastOperationFilesByID: [UUID: URL] = [:]
    private var statusResetTask: Task<Void, Never>?
    private var inspectorDebounceTask: Task<Void, Never>?
    private var metadataUndoStack: [PendingEditState] = []
    private var metadataRedoStack: [PendingEditState] = []
    private var isApplyingMetadataUndoState = false
    private var workspaceObserverTokens: [NSObjectProtocol] = []
    private var sidebarImageCountTasks: [String: Task<Void, Never>] = [:]
    private var backgroundWarmTasksBySelectionID: [String: Task<Void, Never>] = [:]

    private static let browserViewModeKey = "ui.browser.view.mode"
    private static let browserSortKey = "ui.browser.sort"
    private static let browserSortAscendingKey = "ui.browser.sort.ascending"
    private static let galleryGridLevelKey = "ui.gallery.grid.level"
    private static let galleryZoomKey = "ui.gallery.zoom"
    private static let collapsedInspectorSectionsKey = "ui.inspector.collapsed.sections"
    private static let selectedPresetIDKey = "ui.presets.selected.id"
    private static let selectionMetadataBatchSize = 120
    private static let selectionMetadataDebounceNanoseconds: UInt64 = 90_000_000
    private static let folderMetadataBatchSize = 8
    private static let metadataReadTimeoutNanoseconds: UInt64 = 8_000_000_000
    private static let previewBulkStartDelayNanoseconds: UInt64 = 220_000_000
    private static let inspectorPreviewTargetSide: CGFloat = 700
    private static let inspectorPreviewFullSide: CGFloat = 1400
    private static let maxInspectorPreviewCacheEntries = 600
    private static let maxRecentLocations = 20
    nonisolated private static let supportedImageExtensions: Set<String> = [
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
        Self.migrateLegacySupportDirectoryIfNeeded()
        browserViewMode = BrowserViewMode(
            rawValue: UserDefaults.standard.string(forKey: Self.browserViewModeKey) ?? ""
        ) ?? .gallery
        browserSort = BrowserSort(
            rawValue: UserDefaults.standard.string(forKey: Self.browserSortKey) ?? ""
        ) ?? .name
        browserSortAscending = UserDefaults.standard.object(forKey: Self.browserSortAscendingKey) as? Bool ?? true
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
        if let exifToolService {
            service = exifToolService
            statusMessage = "Ready"
        } else if let live = try? ExifToolService() {
            service = live
            statusMessage = "Ready"
        } else {
            service = UnavailableExifToolService()
            statusMessage = "Ledger requires ExifTool to work. Try reinstalling the app."
            Task { @MainActor in
                let alert = NSAlert()
                alert.messageText = "Ledger requires exiftool"
                alert.informativeText = "The exiftool executable could not be found. The app bundle may be corrupted. Please reinstall Ledger."
                alert.alertStyle = .critical
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }

        engine = ExifEditEngine(exifToolService: service)
        self.presetStore = presetStore
        self.favoritesStore = favoritesStore
        self.recentLocationsStore = recentLocationsStore

        let storedCollapsed = UserDefaults.standard.stringArray(forKey: Self.collapsedInspectorSectionsKey) ?? []
        collapsedInspectorSections = Set(storedCollapsed)
        reconcileAndLoadFavorites()
        reconcileAndLoadRecentLocations()
        sidebarItems = composedSidebarItems()
        installWorkspaceVolumeObservers()
        if let selectedPresetRaw = UserDefaults.standard.string(forKey: Self.selectedPresetIDKey),
           let selectedPresetUUID = UUID(uuidString: selectedPresetRaw) {
            selectedPresetID = selectedPresetUUID
        }
        loadPresets()
        Task.detached(priority: .background) {
            try? BackupManager().pruneOperations(keepLast: 20)
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
            statusMessage = "Couldn’t open “\(fileURL.lastPathComponent)” in the default app."
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
            statusMessage = "Couldn’t open \(failedCount) images in the default app."
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
            statusMessage = "Select an image to open in the default app."
            return
        }
        openInDefaultApp(url)
    }

    func applyMetadataSelectionTitle(for targetURLs: [URL]) -> String {
        let count = Set(targetURLs).count
        guard count > 0 else {
            return "Apply Metadata Changes to Selection"
        }
        let suffix = count == 1 ? "" : "s"
        return "Apply Metadata Changes to \(count) Image\(suffix)"
    }

    func fileActionState(for id: FileActionID, targetURLs: [URL]) -> FileActionState {
        let normalized = Array(Set(targetURLs)).sorted { $0.path < $1.path }
        let hasSelection = !normalized.isEmpty
        let hasPending = normalized.contains { hasPendingEdits(for: $0) }
        let hasRestorable = normalized.contains { hasRestorableBackup(for: $0) }
        let openAppName = defaultAppDisplayName(for: normalized.first)

        switch id {
        case .openInDefaultApp:
            return FileActionState(
                id: id,
                title: "Open in \(openAppName)",
                symbolName: "arrow.up.forward.app",
                isEnabled: hasSelection
            )
        case .refreshMetadata:
            return FileActionState(
                id: id,
                title: "Refresh Metadata",
                symbolName: "arrow.clockwise",
                isEnabled: hasSelection
            )
        case .applyMetadataChanges:
            return FileActionState(
                id: id,
                title: "Apply Metadata Changes",
                symbolName: "square.and.arrow.down",
                isEnabled: hasPending
            )
        case .clearMetadataChanges:
            return FileActionState(
                id: id,
                title: "Clear Metadata Changes",
                symbolName: "xmark.circle",
                isEnabled: hasPending
            )
        case .restoreFromLastBackup:
            return FileActionState(
                id: id,
                title: "Restore from Backup",
                symbolName: "arrow.uturn.backward.circle",
                isEnabled: hasRestorable
            )
        }
    }

    func performFileAction(_ id: FileActionID, targetURLs: [URL]) {
        let normalized = Array(Set(targetURLs)).sorted { $0.path < $1.path }
        guard !normalized.isEmpty else { return }
        switch id {
        case .openInDefaultApp:
            openInDefaultApp(normalized)
        case .refreshMetadata:
            refreshMetadata(for: normalized)
        case .applyMetadataChanges:
            applyChanges(for: normalized)
        case .clearMetadataChanges:
            clearPendingEdits(for: normalized)
        case .restoreFromLastBackup:
            restoreLastOperation(for: normalized)
        }
    }

    func rotateLeft(fileURL: URL) {
        stageImageOperation(.rotateLeft90, for: fileURL)
    }

    func flipHorizontal(fileURL: URL) {
        stageImageOperation(.flipHorizontal, for: fileURL)
    }

    func quickLookSelection() {
        let visibleItems = filteredBrowserItems
        let orderedItems = visibleItems.map(\.url)

        guard !orderedItems.isEmpty else {
            statusMessage = "No images to preview."
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

    func quickLookDisplayURL(for sourceURL: URL) -> URL {
        // Keep Quick Look on original file URLs for immediate, stable native behavior.
        removeStagedQuickLookPreviewFile(for: sourceURL)
        return sourceURL
    }

    func setQuickLookSourceFrame(for fileURL: URL, rectOnScreen: NSRect) {
        quickLookSourceFrames[fileURL] = rectOnScreen
    }

    func quickLookSourceFrame(for fileURL: URL) -> NSRect? {
        return quickLookSourceFrames[fileURL]
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
        guard let image = inspectorPreviewImages[fileURL] else { return nil }
        markInspectorPreviewAsRecentlyUsed(fileURL)
        return displayImageForCurrentStagedState(image, fileURL: fileURL)
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
            statusMessage = "Select images to reveal in Finder."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func revealInFinder(_ fileURLs: [URL]) {
        let urls = Array(Set(fileURLs)).sorted(by: { $0.path < $1.path })
        guard !urls.isEmpty else {
            statusMessage = "Select images to reveal in Finder."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func canOpenSidebarItemInFinder(_ item: SidebarItem) -> Bool {
        sidebarOpenURL(for: item.kind) != nil
    }

    func openSidebarItemInFinder(_ item: SidebarItem) {
        guard let url = sidebarOpenURL(for: item.kind) else { return }
        if !NSWorkspace.shared.open(url) {
            statusMessage = "Couldn’t open “\(item.title)” in Finder."
        }
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

    func openFolder(at folderURL: URL) {
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

    /// Called when the app becomes active. If a folder is selected but the browser
    /// is empty — e.g. because a TCC permission prompt blocked the initial enumeration
    /// — silently retry the file load now that permission may have been granted.
    ///
    /// Privacy-gated locations (Desktop, Downloads) are skipped until the user has
    /// explicitly clicked a sidebar item; this prevents a startup race where SwiftUI's
    /// List auto-selection transiently sets selectedSidebarID before
    /// handleSidebarSelectionChange can suppress and revert it.
    func reloadFilesIfBrowserEmpty() {
        guard let item = selectedSidebarItem, browserItems.isEmpty else { return }
        guard !isPrivacySensitiveSidebarKind(item.kind) || hasHadExplicitSidebarSelection else { return }
        loadFiles(for: item.kind)
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
                invalidateInspectorPreviews(for: files)
                ThumbnailPipeline.invalidateCachedImages(for: Set(files))
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
        hasHadExplicitSidebarSelection = true
        selectedSidebarID = id
        if let id {
            backgroundWarmTasksBySelectionID[id]?.cancel()
            backgroundWarmTasksBySelectionID[id] = nil
        }
        guard let itemToLoad = selectedSidebarItem else { return }

        // Avoid touching protected locations on app launch; compute counts only after explicit selection.
        ensureSidebarImageCount(for: itemToLoad)
        loadFiles(for: itemToLoad.kind)
    }

    func handleSidebarSelectionChange(from oldID: String?, to newID: String?, triggerEvent: NSEvent? = nil) {
        if suppressNextSidebarSelectionChange {
            suppressNextSidebarSelectionChange = false
            return
        }
        if isRevertingSidebarSelection {
            isRevertingSidebarSelection = false
            return
        }
        guard newID != oldID else { return }

        if shouldSuppressPrivacySensitiveAutoSelection(from: oldID, to: newID, triggerEvent: triggerEvent) {
            isRevertingSidebarSelection = true
            selectedSidebarID = oldID
            return
        }

        if hasUnsavedEdits {
            let shouldDiscard = confirmDiscardUnsavedChanges(for: "switching folders")
            guard shouldDiscard else {
                isRevertingSidebarSelection = true
                selectedSidebarID = oldID
                return
            }
            discardUnsavedEdits()
        }

        if let oldID, oldID != newID {
            scheduleBackgroundWarm(forSelectionID: oldID, files: browserItems.map(\.url))
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
        pendingImageOpsByFile.removeAll()
        removeAllStagedQuickLookPreviewFiles()
        invalidateAllBrowserThumbnails()
        invalidateInspectorPreviews(for: browserItems.map(\.url))
        recalculateInspectorState(forceNotify: true)
        setStatusMessage("Discarded unsaved metadata changes.", autoClearAfterSuccess: true)
    }

    func clearPendingEdits(for fileURLs: [URL]) {
        let uniqueURLs = Array(Set(fileURLs))
        guard !uniqueURLs.isEmpty else { return }
        registerMetadataUndoIfNeeded(previous: currentPendingEditState())
        for fileURL in uniqueURLs {
            pendingEditsByFile[fileURL] = nil
            pendingImageOpsByFile[fileURL] = nil
            removeStagedQuickLookPreviewFile(for: fileURL)
        }
        invalidateBrowserThumbnails(for: uniqueURLs)
        invalidateInspectorPreviews(for: uniqueURLs)
        recalculateInspectorState(forceNotify: true)
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

        let reachableFiles = files.filter { FileManager.default.isReadableFile(atPath: $0.path) }
        let unreachableCount = files.count - reachableFiles.count

        guard !reachableFiles.isEmpty else {
            setStatusMessage(
                "Selected source is unavailable. Reconnect the drive, then refresh and apply again.",
                autoClearAfterSuccess: false
            )
            return
        }

        if unreachableCount > 0 {
            setStatusMessage(
                "Skipping \(unreachableCount) unavailable file(s); applying remaining changes.",
                autoClearAfterSuccess: true
            )
        }

        isApplyingMetadata = true
        applyMetadataCompleted = 0
        applyMetadataTotal = reachableFiles.count

        Task {
            let startedAt = Date()
            var succeeded: [URL] = []
            var failed: [FileError] = []
            var firstBackupLocation: URL?
            var operationIDs: [UUID] = []
            var operationFilesByID: [UUID: URL] = [:]

            for (index, fileURL) in reachableFiles.enumerated() {
                let patches = buildPatches(for: fileURL)
                let imageOps = effectiveImageOperations(for: fileURL)
                guard !patches.isEmpty || !imageOps.isEmpty else {
                    applyMetadataCompleted = index + 1
                    continue
                }
                let operationID = UUID()
                operationFilesByID[operationID] = fileURL

                do {
                    if imageOps.isEmpty {
                        let operation = EditOperation(id: operationID, targetFiles: [fileURL], changes: patches)
                        let result = try await engine.apply(operation: operation)
                        operationIDs.append(result.operationID)
                        if firstBackupLocation == nil {
                            firstBackupLocation = result.backupLocation
                        }
                        if result.failed.isEmpty {
                            succeeded.append(fileURL)
                            pendingCommitsByFile[fileURL] = pendingEditsByFile[fileURL]?.mapValues(\.value)
                            pendingEditsByFile[fileURL] = nil
                            staleMetadataFiles.insert(fileURL)
                        } else {
                            failed.append(contentsOf: result.failed)
                        }
                    } else {
                        var didApplyImageOps = false
                        let backupLocation = try await engine.createBackup(operationID: operationID, files: [fileURL])
                        if firstBackupLocation == nil {
                            firstBackupLocation = backupLocation
                        }

                        try await Self.applyStagedImageOperations(imageOps, to: fileURL)
                        didApplyImageOps = true

                        if patches.isEmpty {
                            operationIDs.append(operationID)
                            succeeded.append(fileURL)
                            pendingImageOpsByFile[fileURL] = nil
                            staleMetadataFiles.insert(fileURL)
                        } else {
                            let metadataOperation = EditOperation(id: operationID, targetFiles: [fileURL], changes: patches)
                            let metadataResult = try await engine.writeMetadataWithoutBackup(operation: metadataOperation)
                            if metadataResult.failed.isEmpty {
                                operationIDs.append(metadataResult.operationID)
                                succeeded.append(fileURL)
                                pendingCommitsByFile[fileURL] = pendingEditsByFile[fileURL]?.mapValues(\.value)
                                pendingEditsByFile[fileURL] = nil
                                pendingImageOpsByFile[fileURL] = nil
                                staleMetadataFiles.insert(fileURL)
                            } else {
                                if didApplyImageOps {
                                    do { _ = try await engine.restore(operationID: operationID) }
                                    catch { logger.error("Fallback restore after metadata write failed: \(error)") }
                                }
                                failed.append(contentsOf: metadataResult.failed)
                            }
                        }
                    }
                    removeStagedQuickLookPreviewFile(for: fileURL)
                } catch {
                    if !imageOps.isEmpty {
                        do { _ = try await engine.restore(operationID: operationID) }
                        catch { logger.error("Fallback restore after apply error: \(error)") }
                    }
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
                statusMessage = "Couldn’t apply changes. \(firstError)"
                let failedNames = result.failed.prefix(5).map { $0.fileURL.lastPathComponent }.joined(separator: "\n")
                Task { @MainActor in
                    let alert = NSAlert()
                    alert.messageText = "Apply failed"
                    alert.informativeText = "Could not write metadata to \(result.failed.count) file(s):\n\(failedNames)\n\n\(firstError)"
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            } else {
                statusMessage = "Applied \(result.succeeded.count) of \(result.succeeded.count + result.failed.count) — \(result.failed.count) failed"
            }
            applyMetadataCompleted = applyMetadataTotal
            clearMetadataUndoHistory()

            Task { @MainActor [weak self] in
                await self?.loadMetadataForSelection()
                self?.isApplyingMetadata = false
            }
        }
    }

    func hasRestorableBackup(for fileURL: URL) -> Bool {
        lastOperationFilesByID.values.contains(fileURL)
    }

    func restoreLastOperation() {
        guard !lastOperationIDs.isEmpty else {
            statusMessage = "No backup to restore."
            return
        }
        let files = lastOperationIDs.compactMap { lastOperationFilesByID[$0] }
        restoreLastOperation(for: files)
    }

    func restoreLastOperation(for fileURLs: [URL]) {
        let requestedFiles = Array(Set(fileURLs))
        guard !requestedFiles.isEmpty else {
            statusMessage = "Select images to restore from backup."
            return
        }

        let requestedSet = Set(requestedFiles)
        let operationIDsToRestore = lastOperationIDs.filter { operationID in
            guard let fileURL = lastOperationFilesByID[operationID] else { return false }
            return requestedSet.contains(fileURL)
        }

        let skippedCount = requestedFiles.count - operationIDsToRestore.count
        guard !operationIDsToRestore.isEmpty else {
            statusMessage = "No backup available for the selected images."
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
                    guard let fileURL = operationFilesByID[operationID] else { continue }
                    failed.append(FileError(fileURL: fileURL, message: error.localizedDescription))
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
            if !summary.succeeded.isEmpty {
                for fileURL in summary.succeeded {
                    pendingEditsByFile[fileURL] = nil
                    pendingImageOpsByFile[fileURL] = nil
                    removeStagedQuickLookPreviewFile(for: fileURL)
                    // Mark stale so loadMetadataForSelection re-reads from disk.
                    // Without this, metadataByFile retains the applied values and
                    // the inspector continues to show the pre-restore metadata.
                    staleMetadataFiles.insert(fileURL)
                }
                invalidateBrowserThumbnails(for: summary.succeeded)
                invalidateInspectorPreviews(for: summary.succeeded)
            }
            if summary.failed.isEmpty {
                var message = "Restored \(summary.succeeded.count) file(s)."
                if skippedCount > 0 {
                    message += " \(skippedCount) had no backup."
                }
                setStatusMessage(message, autoClearAfterSuccess: true)
            } else if summary.succeeded.isEmpty {
                let firstError = summary.failed.first?.message ?? "Unknown restore error."
                statusMessage = "Couldn’t restore metadata. \(firstError)"
                let failedNames = summary.failed.prefix(5).map { $0.fileURL.lastPathComponent }.joined(separator: "\n")
                Task { @MainActor in
                    let alert = NSAlert()
                    alert.messageText = "Restore failed"
                    alert.informativeText = "Could not restore \(summary.failed.count) file(s):\n\(failedNames)\n\n\(firstError)"
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            } else {
                statusMessage = "Restored \(summary.succeeded.count) of \(summary.succeeded.count + summary.failed.count) — \(summary.failed.count) failed"
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
        } catch ExifEditError.presetSchemaVersionTooNew {
            presets = []
            selectedPresetID = nil
            Task { @MainActor in
                let alert = NSAlert()
                alert.messageText = "Presets saved by a newer version"
                alert.informativeText = "Your presets were saved by a newer version of Ledger and can't be read. Update Ledger to access them."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        } catch {
            presets = []
            selectedPresetID = nil
            statusMessage = "Couldn’t load presets. \(error.localizedDescription)"
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
            statusMessage = "Select images to apply a preset."
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
        registerMetadataUndoIfNeeded(previous: previousState)
        notifyInspectorDidChange()
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
        !(pendingEditsByFile[fileURL]?.isEmpty ?? true) || !effectiveImageOperations(for: fileURL).isEmpty
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
        let currentValue = valueForTag(tag).trimmingCharacters(in: .whitespacesAndNewlines)
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
                .init(value: "0", label: "No Flash"),
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
                .init(value: "32", label: "No Flash"),
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
            .filter { hasPendingEdits(for: $0) }
            .count
    }

    private func stageImageOperation(_ operation: StagedImageOperation, for fileURL: URL) {
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

    nonisolated private static func generateStagedQuickLookPreviewFile(sourceURL: URL, operations: [StagedImageOperation]) -> URL? {
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

    nonisolated private static func runSipsSync(arguments: [String]) throws {
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

    private func effectiveImageOperations(for fileURL: URL) -> [StagedImageOperation] {
        Self.normalizeStagedImageOperations(pendingImageOpsByFile[fileURL] ?? [])
    }

    private static func normalizeStagedImageOperations(_ operations: [StagedImageOperation]) -> [StagedImageOperation] {
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

    private static let canonicalImageOperationMap: [ImageTransformMatrix: [StagedImageOperation]] = {
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

    private static func applyStagedImageOperations(_ operations: [StagedImageOperation], to fileURL: URL) async throws {
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

    nonisolated private static func applyImageOperations(_ operations: [StagedImageOperation], to image: NSImage) -> NSImage? {
        var current = image
        for operation in operations {
            guard let next = transformedImage(current, operation: operation) else { return nil }
            current = next
        }
        return current
    }

    nonisolated private static func transformedImage(_ image: NSImage, operation: StagedImageOperation) -> NSImage? {
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

    nonisolated private static func writeImage(_ image: NSImage, to fileURL: URL) throws {
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

    @Published private(set) var filteredBrowserItems: [BrowserItem] = []

    private func rebuildFilteredBrowserItems() {
        let baseItems: [BrowserItem]
        if searchQuery.isEmpty {
            baseItems = browserItems
        } else {
            let query = searchQuery.lowercased()
            baseItems = browserItems.filter { $0.name.lowercased().contains(query) }
        }
        filteredBrowserItems = sortBrowserItems(baseItems)
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

    func sidebarImageCount(for item: SidebarItem) -> Int {
        sidebarImageCounts[item.id] ?? 0
    }

    func sidebarImageCountText(for item: SidebarItem) -> String? {
        guard let count = sidebarImageCounts[item.id] else { return nil }
        return "\(count)"
    }

    func shouldEagerlyLoadSidebarImageCount(for item: SidebarItem) -> Bool {
        !isPrivacySensitiveSidebarKind(item.kind)
    }

    func ensureSidebarImageCount(for item: SidebarItem) {
        guard sidebarImageCounts[item.id] == nil else { return }
        guard sidebarImageCountTasks[item.id] == nil else { return }
        if isPrivacySensitiveSidebarKind(item.kind) {
            // Never touch privacy-sensitive locations in background.
            // Only load counts after an explicit selection of the exact item.
            guard hasHadExplicitSidebarSelection, selectedSidebarID == item.id else { return }
        }
        guard let sourceURL = sidebarCountURL(for: item.kind) else {
            var counts = sidebarImageCounts
            counts[item.id] = 0
            sidebarImageCounts = counts
            return
        }

        let id = item.id
        sidebarImageCountTasks[id] = Task.detached(priority: .utility) { [id, sourceURL] in
            let count = Self.countSupportedImages(in: sourceURL)
            await MainActor.run {
                var counts = self.sidebarImageCounts
                counts[id] = count
                self.sidebarImageCounts = counts
                self.sidebarImageCountTasks[id] = nil
            }
        }
    }

    var sidebarSectionOrder: [String] {
        ["Sources", "Pinned", "Recents"]
    }

    private func noteRecentLocation(
        _ url: URL,
        titleOverride: String? = nil,
        promoteToTopIfExisting: Bool = false
    ) -> SidebarItem? {
        guard let canonical = canonicalSidebarURL(url) else {
            return nil
        }
        if let sourceItem = sourceSidebarItem(forCanonicalURL: canonical) {
            removeRecentLocation(forCanonicalURL: canonical)
            persistRecentLocations()
            refreshSidebarItems(preferredSelectionID: sourceItem.id)
            return sourceItem
        }
        if let pinnedItem = favoriteSidebarItem(forCanonicalURL: canonical) {
            removeRecentLocation(forCanonicalURL: canonical)
            persistRecentLocations()
            refreshSidebarItems(preferredSelectionID: pinnedItem.id)
            return pinnedItem
        }
        if let mountedItem = mountedVolumeSidebarItem(forCanonicalURL: canonical) {
            removeRecentLocation(forCanonicalURL: canonical)
            persistRecentLocations()
            refreshSidebarItems(preferredSelectionID: mountedItem.id)
            return mountedItem
        }

        let id = "folder::\(canonical.path)"
        let title = titleOverride ?? canonical.lastPathComponent
        var didMutateRecentLocations = false
        let now = Date()

        if let existingIndex = locationItems.firstIndex(where: { $0.id == id }) {
            let existing = locationItems[existingIndex]
            if existing.title != title {
                locationItems[existingIndex] = SidebarItem(id: id, title: title, section: "Recents", kind: .folder(canonical))
                didMutateRecentLocations = true
            }
            if promoteToTopIfExisting, existingIndex > 0 {
                let item = locationItems.remove(at: existingIndex)
                locationItems.insert(item, at: 0)
                didMutateRecentLocations = true
            }
            recentLocationLastOpenedAtByID[id] = now
        } else {
            // Keep insertion order stable by recording first-seen time once.
            recentLocationLastOpenedAtByID[id] = now
            locationItems.append(
                SidebarItem(id: id, title: title, section: "Recents", kind: .folder(canonical))
            )
            trimRecentLocationsToLimit()
            didMutateRecentLocations = true
        }

        if didMutateRecentLocations {
            persistRecentLocations()
            refreshSidebarItems(preferredSelectionID: id)
        } else {
            // Persist recency changes without changing in-session order.
            persistRecentLocations()
        }
        return locationItems.first(where: { $0.id == id })
    }

    var canPinSelectedSidebarLocation: Bool {
        guard let selectedSidebarItem else { return false }
        switch selectedSidebarItem.kind {
        case .pictures, .desktop, .downloads, .mountedVolume, .folder:
            return true
        case .favorite:
            return false
        }
    }

    var canUnpinSelectedSidebarLocation: Bool {
        guard let selectedSidebarItem else { return false }
        if case .favorite = selectedSidebarItem.kind {
            return true
        }
        return false
    }

    var canMoveSelectedFavoriteUp: Bool {
        guard let selectedSidebarItem,
              case let .favorite(url) = selectedSidebarItem.kind,
              let index = favoriteItems.firstIndex(where: { item in
                  if case let .favorite(candidateURL) = item.kind {
                      return candidateURL == url
                  }
                  return false
              })
        else { return false }
        return index > 0
    }

    var canMoveSelectedFavoriteDown: Bool {
        guard let selectedSidebarItem,
              case let .favorite(url) = selectedSidebarItem.kind,
              let index = favoriteItems.firstIndex(where: { item in
                  if case let .favorite(candidateURL) = item.kind {
                      return candidateURL == url
                  }
                  return false
              })
        else { return false }
        return index < favoriteItems.count - 1
    }

    func pinSelectedSidebarLocationToFavorites() {
        guard let selectedSidebarItem else { return }
        switch selectedSidebarItem.kind {
        case .pictures:
            pinFavorite(url: picturesDirectoryURL(), title: "Pictures")
        case .desktop:
            pinFavorite(url: desktopDirectoryURL(), title: "Desktop")
        case .downloads:
            pinFavorite(url: downloadsDirectoryURL(), title: "Downloads")
        case let .mountedVolume(url):
            pinFavorite(url: url, title: selectedSidebarItem.title)
        case let .folder(url):
            pinFavorite(url: url, title: selectedSidebarItem.title)
        case .favorite:
            return
        }
    }

    func unpinSelectedSidebarFavorite() {
        guard let selectedSidebarItem,
              case let .favorite(url) = selectedSidebarItem.kind
        else {
            return
        }
        let neighborSelectionID = favoriteNeighborSelectionID(removingFavoriteURL: url)
        favoriteItems.removeAll { item in
            if case let .favorite(candidateURL) = item.kind {
                return candidateURL == url
            }
            return false
        }
        persistFavorites()
        refreshSidebarItems(preferredSelectionID: neighborSelectionID)
    }

    func moveSelectedFavoriteUp() {
        moveSelectedFavorite(offset: -1)
    }

    func moveSelectedFavoriteDown() {
        moveSelectedFavorite(offset: 1)
    }

    func canPinSidebarItem(_ item: SidebarItem) -> Bool {
        switch item.kind {
        case .pictures, .desktop, .downloads, .mountedVolume, .folder:
            return true
        case .favorite:
            return false
        }
    }

    func canUnpinSidebarItem(_ item: SidebarItem) -> Bool {
        if case .favorite = item.kind {
            return true
        }
        return false
    }

    func canMoveFavoriteUp(_ item: SidebarItem) -> Bool {
        guard case let .favorite(url) = item.kind,
              let index = favoriteItems.firstIndex(where: { candidate in
                  if case let .favorite(candidateURL) = candidate.kind {
                      return candidateURL == url
                  }
                  return false
              })
        else { return false }
        return index > 0
    }

    func canMoveFavoriteDown(_ item: SidebarItem) -> Bool {
        guard case let .favorite(url) = item.kind,
              let index = favoriteItems.firstIndex(where: { candidate in
                  if case let .favorite(candidateURL) = candidate.kind {
                      return candidateURL == url
                  }
                  return false
              })
        else { return false }
        return index < favoriteItems.count - 1
    }

    func pinSidebarItem(_ item: SidebarItem) {
        switch item.kind {
        case .pictures:
            pinFavorite(url: picturesDirectoryURL(), title: "Pictures")
        case .desktop:
            pinFavorite(url: desktopDirectoryURL(), title: "Desktop")
        case .downloads:
            pinFavorite(url: downloadsDirectoryURL(), title: "Downloads")
        case let .mountedVolume(url):
            pinFavorite(url: url, title: item.title)
        case let .folder(url):
            pinFavorite(url: url, title: item.title)
        case .favorite:
            return
        }
    }

    func unpinSidebarItem(_ item: SidebarItem) {
        guard case let .favorite(url) = item.kind else { return }
        let neighborSelectionID = favoriteNeighborSelectionID(removingFavoriteURL: url)
        let preferredSelectionID = selectedSidebarID == item.id ? neighborSelectionID : selectedSidebarID
        favoriteItems.removeAll { candidate in
            if case let .favorite(candidateURL) = candidate.kind {
                return candidateURL == url
            }
            return false
        }
        persistFavorites()
        refreshSidebarItems(preferredSelectionID: preferredSelectionID)
    }

    func moveFavoriteUp(_ item: SidebarItem) {
        moveFavorite(item, offset: -1)
    }

    func moveFavoriteDown(_ item: SidebarItem) {
        moveFavorite(item, offset: 1)
    }

    private func didChooseFolder(_ folderURL: URL) {
        guard let item = noteRecentLocation(folderURL, promoteToTopIfExisting: false) else {
            statusMessage = "Couldn’t open this location."
            return
        }
        if selectedSidebarID != item.id {
            suppressNextSidebarSelectionChange = true
            selectedSidebarID = item.id
        }
        loadFiles(for: item.kind)
        NotificationCenter.default.post(
            name: Notification.Name("\(AppBrand.identifierPrefix).SidebarShouldResignFocus"),
            object: nil
        )
    }

    private func loadFiles(for kind: SidebarKind) {
        folderMetadataLoadTask?.cancel()
        folderMetadataLoadTask = nil
        folderMetadataLoadID = UUID()
        browserItemHydrationTask?.cancel()
        browserItemHydrationTask = nil
        browserItemHydrationID = UUID()
        selectionMetadataLoadTask?.cancel()
        selectionMetadataLoadTask = nil
        previewPreloadTask?.cancel()
        previewPreloadTask = nil
        deferredPreviewPreloadTask?.cancel()
        deferredPreviewPreloadTask = nil
        previewPreloadID = UUID()

        let urls: [URL]
        var enumerationError: Error?

        do {
            switch kind {
            case .pictures:
                urls = try enumerateImages(in: picturesDirectoryURL())
            case .desktop:
                urls = try enumerateImages(in: desktopDirectoryURL())
            case .downloads:
                urls = try enumerateImages(in: downloadsDirectoryURL())
            case let .mountedVolume(volumeURL):
                urls = try enumerateImages(in: volumeURL)
            case let .favorite(favoriteURL):
                urls = try enumerateImages(in: favoriteURL)
            case let .folder(folder):
                urls = try enumerateImages(in: folder)
            }
        } catch {
            enumerationError = error
            urls = []
        }

        // clearLoadedContentState resets browserEnumerationError to nil;
        // re-apply it afterwards so the error state is actually visible to the view.
        clearLoadedContentState(preserveSessionCaches: true)
        browserEnumerationError = enumerationError
        let hydrationID = UUID()
        browserItemHydrationID = hydrationID
        browserItems = urls.map {
            BrowserItem(
                url: $0,
                name: $0.lastPathComponent,
                modifiedAt: nil,
                createdAt: nil,
                sizeBytes: nil,
                kind: nil
            )
        }
        startBrowserItemHydration(for: urls, hydrationID: hydrationID)

        startFolderMetadataPrefetch(for: urls, batchSize: metadataBatchSize(for: kind))
    }

    private func clearLoadedContentState(preserveSessionCaches: Bool = false) {
        folderMetadataLoadTask?.cancel()
        folderMetadataLoadTask = nil
        folderMetadataLoadID = UUID()
        browserItemHydrationTask?.cancel()
        browserItemHydrationTask = nil
        browserItemHydrationID = UUID()
        selectionMetadataLoadTask?.cancel()
        selectionMetadataLoadTask = nil
        isFolderMetadataLoading = false
        folderMetadataLoadCompleted = 0
        folderMetadataLoadTotal = 0
        browserEnumerationError = nil

        previewPreloadTask?.cancel()
        previewPreloadTask = nil
        deferredPreviewPreloadTask?.cancel()
        deferredPreviewPreloadTask = nil
        previewPreloadID = UUID()
        isPreviewPreloading = false
        previewPreloadCompleted = 0
        previewPreloadTotal = 0

        browserItems = []
        selectedFileURLs = []
        draftValues = [:]
        baselineValues = [:]
        if !preserveSessionCaches {
            metadataByFile = [:]
            staleMetadataFiles = []
        }
        pendingEditsByFile = [:]
        pendingImageOpsByFile = [:]
        removeAllStagedQuickLookPreviewFiles()
        if !preserveSessionCaches {
            inspectorPreviewImages = [:]
            inspectorPreviewRenderedSide = [:]
            inspectorPreviewRecency = []
        }
        inspectorPreviewInflight = []
        for task in inspectorPreviewTasksByURL.values {
            task.cancel()
        }
        inspectorPreviewTasksByURL = [:]
        clearMetadataUndoHistory()
        recalculateInspectorState(forceNotify: true)
    }

    private func startBrowserItemHydration(for files: [URL], hydrationID: UUID) {
        browserItemHydrationTask?.cancel()
        browserItemHydrationTask = nil
        guard !files.isEmpty else { return }

        browserItemHydrationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            typealias BrowserFileAttributes = (modifiedAt: Date?, createdAt: Date?, sizeBytes: Int?, kind: String?)
            var attributesByURL: [URL: BrowserFileAttributes] = [:]
            attributesByURL.reserveCapacity(files.count)

            let batchSize = 96
            for batchStart in stride(from: 0, to: files.count, by: batchSize) {
                if Task.isCancelled { return }
                guard self.browserItemHydrationID == hydrationID else { return }

                let batchEnd = min(batchStart + batchSize, files.count)
                let batch = Array(files[batchStart..<batchEnd])
                let batchResult = await Task.detached(priority: .utility) { () -> [URL: BrowserFileAttributes] in
                    var result: [URL: BrowserFileAttributes] = [:]
                    result.reserveCapacity(batch.count)
                    for fileURL in batch {
                        let resourceValues = try? fileURL.resourceValues(
                            forKeys: [
                                .contentModificationDateKey,
                                .creationDateKey,
                                .fileSizeKey,
                                .localizedTypeDescriptionKey
                            ]
                        )
                        result[fileURL] = (
                            resourceValues?.contentModificationDate,
                            resourceValues?.creationDate,
                            resourceValues?.fileSize,
                            resourceValues?.localizedTypeDescription
                        )
                    }
                    return result
                }.value

                if Task.isCancelled { return }
                guard self.browserItemHydrationID == hydrationID else { return }
                attributesByURL.merge(batchResult) { _, new in new }

                let currentURLs = Set(self.browserItems.map(\.url))
                if !currentURLs.isEmpty {
                    self.browserItems = self.browserItems.map { item in
                        guard let attrs = attributesByURL[item.url] else { return item }
                        return BrowserItem(
                            url: item.url,
                            name: item.name,
                            modifiedAt: attrs.modifiedAt,
                            createdAt: attrs.createdAt,
                            sizeBytes: attrs.sizeBytes,
                            kind: attrs.kind
                        )
                    }
                }
            }

            guard !Task.isCancelled, self.browserItemHydrationID == hydrationID else { return }
            self.browserItemHydrationTask = nil
        }
    }

    private func sortBrowserItems(_ items: [BrowserItem]) -> [BrowserItem] {
        let asc = browserSortAscending
        // cmp(before) returns true when lhs should precede rhs, flipping for descending.
        // Nil values are always sorted last regardless of direction.
        return items.sorted { lhs, rhs in
            func cmp(_ before: Bool) -> Bool { asc ? before : !before }
            switch browserSort {
            case .name:
                let c = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if c != .orderedSame { return cmp(c == .orderedAscending) }
                return cmp(lhs.url.path < rhs.url.path)
            case .created:
                switch (lhs.createdAt, rhs.createdAt) {
                case let (l?, r?):
                    if l != r { return cmp(l < r) }
                case (nil, nil): break
                case (nil, _?): return false  // nil always last
                case (_?, nil): return true   // nil always last
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            case .size:
                switch (lhs.sizeBytes, rhs.sizeBytes) {
                case let (l?, r?):
                    if l != r { return cmp(l < r) }
                case (nil, nil): break
                case (nil, _?): return false  // nil always last
                case (_?, nil): return true   // nil always last
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            case .kind:
                let lKind = lhs.kind ?? ""
                let rKind = rhs.kind ?? ""
                let c = lKind.localizedCaseInsensitiveCompare(rKind)
                if c != .orderedSame { return cmp(c == .orderedAscending) }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }

    private func baseSidebarItems() -> [SidebarItem] {
        var items: [SidebarItem] = [
            SidebarItem(id: "source-desktop", title: "Desktop", section: "Sources", kind: .desktop),
            SidebarItem(id: "source-downloads", title: "Downloads", section: "Sources", kind: .downloads),
            SidebarItem(id: "source-pictures", title: "Pictures", section: "Sources", kind: .pictures)
        ]
        items.append(contentsOf: mountedVolumeSidebarItems())
        return items
    }

    private func composedSidebarItems() -> [SidebarItem] {
        baseSidebarItems() + favoriteItems + locationItems
    }

    private func refreshSidebarItems(selectFirstWhenMissing: Bool = true, preferredSelectionID: String? = nil) {
        let priorSelection = selectedSidebarID
        sidebarItems = composedSidebarItems()
        reconcileSidebarImageCountState()
        if let preferredSelectionID, sidebarItems.contains(where: { $0.id == preferredSelectionID }) {
            selectedSidebarID = preferredSelectionID
        } else if let priorSelection, sidebarItems.contains(where: { $0.id == priorSelection }) {
            selectedSidebarID = priorSelection
        } else if selectFirstWhenMissing {
            selectedSidebarID = sidebarItems.first?.id
        } else {
            selectedSidebarID = nil
        }
    }

    private func warmSidebarImageCounts(includePrivacySensitive: Bool = false) {
        for item in sidebarItems {
            if !includePrivacySensitive, isPrivacySensitiveSidebarKind(item.kind) {
                continue
            }
            ensureSidebarImageCount(for: item)
        }
    }

    private func isPrivacySensitiveFileSystemURL(_ url: URL) -> Bool {
        let candidate = url.standardizedFileURL
        let desktop = desktopDirectoryURL().standardizedFileURL
        let downloads = downloadsDirectoryURL().standardizedFileURL
        return isWithinOrSame(candidate, root: desktop) || isWithinOrSame(candidate, root: downloads)
    }

    private func isPrivacySensitiveSidebarKind(_ kind: SidebarKind) -> Bool {
        switch kind {
        case .desktop, .downloads:
            return true
        case let .favorite(url), let .folder(url), let .mountedVolume(url):
            return isPrivacySensitiveFileSystemURL(url)
        case .pictures:
            return false
        }
    }

    private func shouldSuppressPrivacySensitiveAutoSelection(from oldID: String?, to newID: String?, triggerEvent: NSEvent?) -> Bool {
        guard oldID == nil, let newID else { return false }
        guard let candidate = sidebarItems.first(where: { $0.id == newID }) else { return false }
        guard isPrivacySensitiveSidebarKind(candidate.kind) else { return false }
        // Reject events that predate app launch (Dock click / Finder double-click that
        // launched the app). NSEvent.timestamp is seconds since last system boot, as is
        // ProcessInfo.systemUptime, so they are directly comparable. A stale launch event
        // will always have timestamp < initializationUptime; a genuine sidebar click will
        // always have timestamp > initializationUptime.
        guard let event = triggerEvent, event.timestamp > initializationUptime else {
            return true
        }
        return !isLikelyUserInitiatedSidebarChange(event: event)
    }

    private func isLikelyUserInitiatedSidebarChange(event: NSEvent?) -> Bool {
        guard let event else { return false }
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp, .keyDown, .keyUp:
            return true
        default:
            return false
        }
    }

    private func isWithinOrSame(_ url: URL, root: URL) -> Bool {
        let candidatePath = url.standardizedFileURL.path
        var rootPath = root.standardizedFileURL.path
        if !rootPath.hasSuffix("/") {
            rootPath.append("/")
        }
        return candidatePath == root.standardizedFileURL.path || candidatePath.hasPrefix(rootPath)
    }

    private func canonicalSidebarURL(_ url: URL, validateExistence: Bool = true) -> URL? {
        let standardized = url.standardizedFileURL
        if !validateExistence {
            // Startup/background paths for privacy-sensitive locations should avoid
            // filesystem probes to prevent TCC prompts before explicit user intent.
            return standardized
        }
        let resolved = standardized.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: resolved.path)
        else {
            return nil
        }
        return resolved
    }

    private func pinFavorite(url: URL, title: String) {
        guard let canonical = canonicalSidebarURL(url) else {
            statusMessage = "Couldn’t pin this location."
            return
        }
        let id = "favorite::\(canonical.path)"
        guard !favoriteItems.contains(where: { $0.id == id }) else {
            statusMessage = "This location is already pinned."
            return
        }

        favoriteItems.append(
            SidebarItem(
                id: id,
                title: title,
                section: "Pinned",
                kind: .favorite(canonical)
            )
        )
        removeRecentLocation(forCanonicalURL: canonical)
        persistFavorites()
        persistRecentLocations()
        refreshSidebarItems(preferredSelectionID: id)
        statusMessage = "“\(title)” added to Pinned."
    }

    private func moveSelectedFavorite(offset: Int) {
        guard let selectedSidebarItem,
              case let .favorite(url) = selectedSidebarItem.kind,
              let index = favoriteItems.firstIndex(where: { item in
                  if case let .favorite(candidateURL) = item.kind {
                      return candidateURL == url
                  }
                  return false
              })
        else {
            return
        }

        let nextIndex = index + offset
        guard favoriteItems.indices.contains(nextIndex) else { return }
        let item = favoriteItems.remove(at: index)
        favoriteItems.insert(item, at: nextIndex)
        persistFavorites()
        refreshSidebarItems()
        selectedSidebarID = item.id
    }

    private func moveFavorite(_ item: SidebarItem, offset: Int) {
        guard case let .favorite(url) = item.kind,
              let index = favoriteItems.firstIndex(where: { candidate in
                  if case let .favorite(candidateURL) = candidate.kind {
                      return candidateURL == url
                  }
                  return false
              })
        else {
            return
        }

        let nextIndex = index + offset
        guard favoriteItems.indices.contains(nextIndex) else { return }
        let movingItem = favoriteItems.remove(at: index)
        favoriteItems.insert(movingItem, at: nextIndex)
        persistFavorites()
        refreshSidebarItems()
        selectedSidebarID = movingItem.id
    }

    private func favoriteNeighborSelectionID(removingFavoriteURL url: URL) -> String? {
        guard let index = favoriteItems.firstIndex(where: { candidate in
            if case let .favorite(candidateURL) = candidate.kind {
                return candidateURL == url
            }
            return false
        })
        else {
            return nil
        }

        if favoriteItems.indices.contains(index + 1) {
            return favoriteItems[index + 1].id
        }
        if favoriteItems.indices.contains(index - 1) {
            return favoriteItems[index - 1].id
        }
        return nil
    }

    private func reconcileAndLoadFavorites() {
        do {
            let stored = try favoritesStore.loadFavorites()
            var normalized: [SidebarItem] = []
            for favorite in stored.sorted(by: { $0.order < $1.order }) {
                let url = URL(fileURLWithPath: favorite.path)
                let shouldValidate = !isPrivacySensitiveFileSystemURL(url)
                guard let canonical = canonicalSidebarURL(url, validateExistence: shouldValidate) else { continue }
                let id = "favorite::\(canonical.path)"
                if normalized.contains(where: { $0.id == id }) {
                    continue
                }
                normalized.append(
                    SidebarItem(
                        id: id,
                        title: favorite.displayName,
                        section: "Pinned",
                        kind: .favorite(canonical)
                    )
                )
            }
            favoriteItems = normalized
            persistFavorites()
        } catch {
            favoriteItems = []
            statusMessage = "Couldn’t load pinned locations. \(error.localizedDescription)"
        }
    }

    private func persistFavorites() {
        let records: [SidebarFavorite] = favoriteItems.enumerated().compactMap { index, item in
            guard case let .favorite(url) = item.kind else { return nil }
            return SidebarFavorite(path: url.path, displayName: item.title, order: index)
        }
        do {
            try favoritesStore.saveFavorites(records)
        } catch {
            statusMessage = "Couldn’t save pinned locations. \(error.localizedDescription)"
        }
    }

    private func reconcileAndLoadRecentLocations() {
        do {
            let stored = try recentLocationsStore.loadRecentLocations()
            var normalized: [(item: SidebarItem, order: Int)] = []
            var openedByID: [String: Date] = [:]
            for location in stored.sorted(by: { $0.order < $1.order }) {
                let url = URL(fileURLWithPath: location.path)
                let shouldValidate = !isPrivacySensitiveFileSystemURL(url)
                guard let canonical = canonicalSidebarURL(url, validateExistence: shouldValidate) else { continue }
                let id = "folder::\(canonical.path)"
                if normalized.contains(where: { $0.item.id == id }) {
                    continue
                }
                let item = SidebarItem(
                        id: id,
                        title: location.displayName,
                        section: "Recents",
                        kind: .folder(canonical)
                    )
                normalized.append((item: item, order: location.order))
                if let opened = location.lastOpenedAt {
                    openedByID[id] = opened
                }
                if normalized.count == Self.maxRecentLocations {
                    break
                }
            }
            locationItems = normalized
                .sorted { lhs, rhs in
                    let lhsOpened = openedByID[lhs.item.id] ?? .distantPast
                    let rhsOpened = openedByID[rhs.item.id] ?? .distantPast
                    if lhsOpened != rhsOpened {
                        return lhsOpened > rhsOpened
                    }
                    return lhs.order < rhs.order
                }
                .map(\.item)
            recentLocationLastOpenedAtByID = openedByID
            persistRecentLocations()
        } catch {
            locationItems = []
            recentLocationLastOpenedAtByID = [:]
            statusMessage = "Couldn’t load recent locations. \(error.localizedDescription)"
        }
    }

    private func persistRecentLocations() {
        let records: [RecentLocation] = locationItems.enumerated().compactMap { index, item in
            guard case let .folder(url) = item.kind else { return nil }
            return RecentLocation(
                path: url.path,
                displayName: item.title,
                order: index,
                lastOpenedAt: recentLocationLastOpenedAtByID[item.id]
            )
        }
        do {
            try recentLocationsStore.saveRecentLocations(records)
        } catch {
            statusMessage = "Couldn’t save recent locations. \(error.localizedDescription)"
        }
    }

    private func trimRecentLocationsToLimit() {
        guard locationItems.count > Self.maxRecentLocations else { return }
        while locationItems.count > Self.maxRecentLocations {
            // Remove the oldest inserted entry to keep order stable.
            let removedID = locationItems.removeFirst().id
            recentLocationLastOpenedAtByID[removedID] = nil
        }
    }

    private func favoriteSidebarItem(forCanonicalURL canonical: URL) -> SidebarItem? {
        favoriteItems.first { item in
            guard case let .favorite(url) = item.kind else { return false }
            return url.standardizedFileURL.resolvingSymlinksInPath().path == canonical.path
        }
    }

    private func sourceSidebarItem(forCanonicalURL canonical: URL) -> SidebarItem? {
        let pictures = picturesDirectoryURL().standardizedFileURL.resolvingSymlinksInPath().path
        if canonical.path == pictures {
            return SidebarItem(id: "source-pictures", title: "Pictures", section: "Sources", kind: .pictures)
        }

        let desktop = desktopDirectoryURL().standardizedFileURL.resolvingSymlinksInPath().path
        if canonical.path == desktop {
            return SidebarItem(id: "source-desktop", title: "Desktop", section: "Sources", kind: .desktop)
        }

        let downloads = downloadsDirectoryURL().standardizedFileURL.resolvingSymlinksInPath().path
        if canonical.path == downloads {
            return SidebarItem(id: "source-downloads", title: "Downloads", section: "Sources", kind: .downloads)
        }

        return nil
    }

    private func mountedVolumeSidebarItem(forCanonicalURL canonical: URL) -> SidebarItem? {
        mountedVolumeSidebarItems().first { item in
            guard case let .mountedVolume(url) = item.kind else { return false }
            return url.standardizedFileURL.resolvingSymlinksInPath().path == canonical.path
        }
    }

    @discardableResult
    private func removeRecentLocation(forCanonicalURL canonical: URL) -> Bool {
        let before = locationItems.count
        locationItems.removeAll { item in
            guard case let .folder(url) = item.kind else { return false }
            return url.standardizedFileURL.resolvingSymlinksInPath().path == canonical.path
        }
        recentLocationLastOpenedAtByID.removeValue(forKey: "folder::\(canonical.path)")
        return locationItems.count != before
    }

    private func mountedVolumeSidebarItems() -> [SidebarItem] {
        let keys: [URLResourceKey] = [
            .volumeIsRemovableKey,
            .volumeIsEjectableKey,
            .volumeIsInternalKey,
            .volumeIsRootFileSystemKey,
            .volumeIsBrowsableKey,
            .volumeLocalizedNameKey,
            .nameKey
        ]
        let mounted = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []

        return mounted.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsRootFileSystem != true,
                  values.volumeIsBrowsable != false
            else {
                return nil
            }

            let isExternalLike = values.volumeIsInternal == false
                || values.volumeIsRemovable == true
                || values.volumeIsEjectable == true
            guard isExternalLike else { return nil }

            let title = values.volumeLocalizedName ?? values.name ?? url.lastPathComponent
            return SidebarItem(
                id: "volume::\(url.path)",
                title: title,
                section: "Sources",
                kind: .mountedVolume(url)
            )
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private func metadataBatchSize(for kind: SidebarKind) -> Int {
        switch kind {
        case .mountedVolume:
            return 1
        case let .favorite(url), let .folder(url):
            return isLikelyExternalLocation(url) ? 1 : Self.folderMetadataBatchSize
        case .pictures, .desktop, .downloads:
            return Self.folderMetadataBatchSize
        }
    }

    private func isLikelyExternalLocation(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path.hasPrefix("/Volumes/")
    }

    private func isReachableDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && FileManager.default.isReadableFile(atPath: url.path)
    }

    private func installWorkspaceVolumeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didMountNotification,
            NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification
        ]

        for name in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    self?.handleWorkspaceVolumeChange()
                }
            }
            workspaceObserverTokens.append(token)
        }
    }

    private func handleWorkspaceVolumeChange() {
        let previousSelectionID = selectedSidebarID
        let previousSelection = selectedSidebarItem
        refreshSidebarItems(selectFirstWhenMissing: false)

        if let previousSelection,
           let sourceURL = sidebarSourceURL(for: previousSelection.kind),
           !isReachableDirectory(sourceURL) {
            clearToEmptyStateAfterSourceLoss()
            return
        }

        guard selectedSidebarID != previousSelectionID, let replacement = selectedSidebarItem else { return }
        loadFiles(for: replacement.kind)
    }

    private func clearToEmptyStateAfterSourceLoss() {
        selectedSidebarID = nil
        clearLoadedContentState(preserveSessionCaches: true)
        setStatusMessage(
            "External source was disconnected.",
            autoClearAfterSuccess: false
        )
    }

    private func sidebarSourceURL(for kind: SidebarKind) -> URL? {
        switch kind {
        case let .mountedVolume(url):
            return url
        case let .favorite(url):
            return url
        case let .folder(url):
            return url
        case .pictures, .desktop, .downloads:
            return nil
        }
    }

    private func sidebarOpenURL(for kind: SidebarKind) -> URL? {
        switch kind {
        case .pictures:
            return picturesDirectoryURL()
        case .desktop:
            return desktopDirectoryURL()
        case .downloads:
            return downloadsDirectoryURL()
        case let .mountedVolume(url), let .favorite(url), let .folder(url):
            return url
        }
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

    private func enumerateImages(in folder: URL) throws -> [URL] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )

        return urls.filter { url in
            guard Self.supportedImageExtensions.contains(url.pathExtension.lowercased()) else { return false }
            let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            return isRegular
        }
    }

    private func enumerateImagesRecursively(in folder: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var files: [URL] = []

        for case let url as URL in enumerator {
            // Skip symbolic links to prevent potential cycles.
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                enumerator.skipDescendants()
                continue
            }
            let ext = url.pathExtension.lowercased()
            guard Self.supportedImageExtensions.contains(ext) else { continue }
            files.append(url)
        }

        return files
    }

    nonisolated private static func countSupportedImages(in folder: URL) -> Int {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
        } catch {
            logger.error("countSupportedImages: failed to enumerate \(folder.path): \(error)")
            return 0
        }

        return urls.reduce(into: 0) { total, url in
            guard supportedImageExtensions.contains(url.pathExtension.lowercased()) else { return }
            let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            if isRegular {
                total += 1
            }
        }
    }

    private func sidebarCountURL(for kind: SidebarKind) -> URL? {
        switch kind {
        case .pictures:
            return picturesDirectoryURL()
        case .desktop:
            return desktopDirectoryURL()
        case .downloads:
            return downloadsDirectoryURL()
        case let .mountedVolume(url), let .favorite(url), let .folder(url):
            return url
        }
    }

    private func reconcileSidebarImageCountState() {
        let validIDs = Set(sidebarItems.map(\.id))

        sidebarImageCounts = sidebarImageCounts.filter { validIDs.contains($0.key) }

        let staleTaskIDs = sidebarImageCountTasks.keys.filter { !validIDs.contains($0) }
        for id in staleTaskIDs {
            sidebarImageCountTasks[id]?.cancel()
            sidebarImageCountTasks[id] = nil
        }
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

    private func recalculateInspectorState(forceNotify: Bool = false) {
        inspectorDebounceTask?.cancel()
        inspectorDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled, let self else { return }
            self.performRecalculateInspectorState(forceNotify: forceNotify)
        }
    }

    private func performRecalculateInspectorState(forceNotify: Bool = false) {
        let selectedURLs = Array(selectedFileURLs)
        var didChange = false
        guard !selectedURLs.isEmpty else {
            if !baselineValues.isEmpty {
                baselineValues = [:]
                didChange = true
            }
            if !draftValues.isEmpty {
                draftValues = [:]
                didChange = true
            }
            if !mixedTags.isEmpty {
                mixedTags = []
                didChange = true
            }
            if didChange || forceNotify {
                notifyInspectorDidChange()
            }
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
                // Show the value that was just written during the reload gap so the
                // inspector never flashes back to the pre-apply on-disk snapshot.
                if let committedValue = pendingCommitsByFile[url]?[tag] {
                    draftValuesForTag.append(committedValue)
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

        if baselineValues != nextBaseline {
            baselineValues = nextBaseline
            didChange = true
        }
        if draftValues != nextDraft {
            draftValues = nextDraft
            didChange = true
        }
        if mixedTags != nextMixedTags {
            mixedTags = nextMixedTags
            didChange = true
        }
        if didChange || forceNotify {
            notifyInspectorDidChange()
        }
    }

    private func notifyInspectorDidChange() {
        inspectorRefreshRevision &+= 1
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
            statusMessage = "Couldn’t save presets. \(error.localizedDescription)"
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
            return
        }

        let filesToLoad = files.filter { fileURL in
            staleMetadataFiles.contains(fileURL) || metadataByFile[fileURL] == nil
        }
        guard !filesToLoad.isEmpty else {
            return
        }

        var map = metadataByFile

        for batchStart in stride(from: 0, to: filesToLoad.count, by: Self.selectionMetadataBatchSize) {
            let batchEnd = min(batchStart + Self.selectionMetadataBatchSize, filesToLoad.count)
            let batch = Array(filesToLoad[batchStart..<batchEnd])
            let snapshots = await readMetadataBatchResilient(batch)

            // Ignore stale async results after selection has changed.
            guard selectionAtStart == selectedFileURLs else { return }
            for snapshot in snapshots {
                map[snapshot.fileURL] = snapshot
                staleMetadataFiles.remove(snapshot.fileURL)
                pendingCommitsByFile.removeValue(forKey: snapshot.fileURL)
            }
        }

        guard selectionAtStart == selectedFileURLs else { return }
        metadataByFile = map
        recalculateInspectorState()
    }

    private func startFolderMetadataPrefetch(for files: [URL], batchSize: Int) {
        folderMetadataLoadTask?.cancel()
        folderMetadataLoadTask = nil

        let loadID = UUID()
        folderMetadataLoadID = loadID
        let effectiveBatchSize = max(1, batchSize)

        let filesToLoad = files.filter { fileURL in
            staleMetadataFiles.contains(fileURL) || metadataByFile[fileURL] == nil
        }

        guard !filesToLoad.isEmpty else {
            isFolderMetadataLoading = false
            folderMetadataLoadCompleted = 0
            folderMetadataLoadTotal = 0
            scheduleDeferredPreviewPreload(for: files)
            return
        }

        isFolderMetadataLoading = true
        folderMetadataLoadCompleted = 0
        folderMetadataLoadTotal = filesToLoad.count

        folderMetadataLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var map = self.metadataByFile

            for batchStart in stride(from: 0, to: filesToLoad.count, by: effectiveBatchSize) {
                if Task.isCancelled { return }
                guard self.folderMetadataLoadID == loadID else { return }
                await Task.yield()

                let batchEnd = min(batchStart + effectiveBatchSize, filesToLoad.count)
                let batch = Array(filesToLoad[batchStart..<batchEnd])
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
            self.scheduleDeferredPreviewPreload(for: files)
        }
    }

    private func scheduleDeferredPreviewPreload(for files: [URL]) {
        deferredPreviewPreloadTask?.cancel()
        deferredPreviewPreloadTask = nil
        let filesSnapshot = files
        deferredPreviewPreloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: Self.previewBulkStartDelayNanoseconds)
            guard !Task.isCancelled else { return }
            self.startPreviewPreload(for: filesSnapshot)
        }
    }

    private func startPreviewPreload(for files: [URL]) {
        previewPreloadTask?.cancel()
        previewPreloadTask = nil
        deferredPreviewPreloadTask?.cancel()
        deferredPreviewPreloadTask = nil
        let preloadID = UUID()
        previewPreloadID = preloadID

        var filesToPreload: [URL] = []
        for fileURL in files {
            let currentSide = inspectorPreviewRenderedSide[fileURL] ?? 0
            if currentSide >= Self.inspectorPreviewTargetSide {
                continue
            }
            if let cached = ThumbnailPipeline.cachedImage(for: fileURL, minRenderedSide: Self.inspectorPreviewTargetSide) {
                storeInspectorPreview(
                    cached,
                    for: fileURL,
                    renderedSide: max(Self.inspectorPreviewTargetSide, renderedSide(for: cached))
                )
            } else {
                if currentSide <= 0,
                   let cachedLowRes = ThumbnailPipeline.cachedImage(for: fileURL, minRenderedSide: 1) {
                    storeInspectorPreview(cachedLowRes, for: fileURL, renderedSide: renderedSide(for: cachedLowRes))
                }
                filesToPreload.append(fileURL)
            }
        }

        guard !filesToPreload.isEmpty else {
            isPreviewPreloading = false
            previewPreloadCompleted = 0
            previewPreloadTotal = 0
            return
        }

        isPreviewPreloading = true
        previewPreloadCompleted = 0
        previewPreloadTotal = filesToPreload.count

        previewPreloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for (index, fileURL) in filesToPreload.enumerated() {
                if Task.isCancelled { return }
                guard self.previewPreloadID == preloadID else { return }
                await Task.yield()

                self.inspectorPreviewInflight.insert(fileURL)
                if let image = await Self.generateInspectorPreviewOffMain(for: fileURL, priority: .utility) {
                    self.storeInspectorPreview(
                        image,
                        for: fileURL,
                        renderedSide: max(Self.inspectorPreviewFullSide, self.renderedSide(for: image))
                    )
                }
                self.inspectorPreviewInflight.remove(fileURL)
                self.inspectorPreviewTasksByURL[fileURL] = nil

                self.previewPreloadCompleted = index + 1
            }

            guard !Task.isCancelled, self.previewPreloadID == preloadID else { return }
            self.previewPreloadTask = nil
            self.isPreviewPreloading = false
            self.previewPreloadCompleted = self.previewPreloadTotal
            self.setStatusMessage("Metadata loaded", autoClearAfterSuccess: true)
        }
    }

    private static func generateInspectorPreviewOffMain(for fileURL: URL, priority: TaskPriority) async -> NSImage? {
        await Task.detached(priority: priority) {
            await ThumbnailPipeline.generateThumbnail(fileURL: fileURL, maxPixelSize: Self.inspectorPreviewFullSide)
        }.value
    }

    private struct MetadataReadTimeoutError: LocalizedError {
        let fileCount: Int

        var errorDescription: String? {
            "Timed out reading metadata for \(fileCount) file(s)."
        }
    }

    private func readMetadataWithTimeout(_ files: [URL], timeoutNanoseconds: UInt64) async throws -> [FileMetadataSnapshot] {
        try await withThrowingTaskGroup(of: [FileMetadataSnapshot].self) { group in
            group.addTask {
                try await self.engine.readMetadata(files: files)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw MetadataReadTimeoutError(fileCount: files.count)
            }

            guard let first = try await group.next() else {
                group.cancelAll()
                return []
            }
            group.cancelAll()
            return first
        }
    }

    private func readMetadataBatchResilient(_ files: [URL]) async -> [FileMetadataSnapshot] {
        guard !files.isEmpty else { return [] }
        do {
            return try await readMetadataWithTimeout(
                files,
                timeoutNanoseconds: Self.metadataReadTimeoutNanoseconds
            )
        } catch is MetadataReadTimeoutError {
            // Do not immediately re-enter per-file reads after a timeout; that can queue behind
            // the same stuck operation path and stall progress updates.
            return []
        } catch {
            var partial: [FileMetadataSnapshot] = []
            for file in files {
                if Task.isCancelled { break }
                if let one = try? await readMetadataWithTimeout(
                    [file],
                    timeoutNanoseconds: Self.metadataReadTimeoutNanoseconds
                ).first {
                    partial.append(one)
                }
            }
            return partial
        }
    }

    func selectionChanged() {
        let selection = selectedFileURLs
        cancelStaleInspectorPreviewTasks(keeping: selection)

        previewPreloadTask?.cancel()
        previewPreloadTask = nil
        previewPreloadID = UUID()
        isPreviewPreloading = false

        if let primary = primarySelectionURL {
            inspectorPreviewTasksByURL[primary]?.cancel()
            inspectorPreviewTasksByURL[primary] = nil
            inspectorPreviewInflight.remove(primary)
            loadInspectorPreview(for: primary, force: false, priority: .userInitiated)
        }

        scheduleDeferredPreviewPreload(for: browserItems.map(\.url))

        // Recompute immediately so UI doesn't show stale single-file values while async load runs.
        // Force a refresh even when canonical values happen to be unchanged, so selection/header state updates.
        recalculateInspectorState(forceNotify: true)
        let needsMetadataLoad = selection.contains { staleMetadataFiles.contains($0) || metadataByFile[$0] == nil }
        guard needsMetadataLoad else { return }
        selectionMetadataLoadTask?.cancel()
        selectionMetadataLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: Self.selectionMetadataDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            await self.loadMetadataForSelection()
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

    private func loadInspectorPreview(for fileURL: URL, force: Bool, priority: TaskPriority? = nil) {
        let requestPriority = priority ?? (selectedFileURLs.contains(fileURL) ? .userInitiated : .utility)
        if !force, (inspectorPreviewRenderedSide[fileURL] ?? 0) >= Self.inspectorPreviewTargetSide {
            markInspectorPreviewAsRecentlyUsed(fileURL)
            return
        }
        if !force,
           let cached = ThumbnailPipeline.cachedImage(for: fileURL, minRenderedSide: Self.inspectorPreviewTargetSide) {
            storeInspectorPreview(
                cached,
                for: fileURL,
                renderedSide: max(Self.inspectorPreviewTargetSide, renderedSide(for: cached))
            )
            return
        }
        if !force, inspectorPreviewImages[fileURL] == nil,
           let cachedLowRes = ThumbnailPipeline.cachedImage(for: fileURL, minRenderedSide: 1) {
            storeInspectorPreview(cachedLowRes, for: fileURL, renderedSide: renderedSide(for: cachedLowRes))
        }

        if force {
            inspectorPreviewTasksByURL[fileURL]?.cancel()
            inspectorPreviewTasksByURL[fileURL] = nil
            inspectorPreviewInflight.remove(fileURL)
            inspectorPreviewImages[fileURL] = nil
            inspectorPreviewRenderedSide[fileURL] = nil
            ThumbnailPipeline.invalidateCachedImages(for: [fileURL])
        }
        guard !inspectorPreviewInflight.contains(fileURL) else { return }
        inspectorPreviewInflight.insert(fileURL)

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let image = await Self.generateInspectorPreviewOffMain(for: fileURL, priority: requestPriority)
            if let image {
                self.storeInspectorPreview(
                    image,
                    for: fileURL,
                    renderedSide: max(Self.inspectorPreviewFullSide, self.renderedSide(for: image))
                )
            }
            self.inspectorPreviewInflight.remove(fileURL)
            self.inspectorPreviewTasksByURL[fileURL] = nil
        }
        inspectorPreviewTasksByURL[fileURL] = task
    }

    private func invalidateInspectorPreviews(for fileURLs: [URL]) {
        guard !fileURLs.isEmpty else { return }
        let targets = Set(fileURLs)
        for fileURL in targets {
            inspectorPreviewTasksByURL[fileURL]?.cancel()
            inspectorPreviewTasksByURL[fileURL] = nil
            inspectorPreviewInflight.remove(fileURL)
            inspectorPreviewImages[fileURL] = nil
            inspectorPreviewRenderedSide[fileURL] = nil
        }
        inspectorPreviewRecency.removeAll(where: { targets.contains($0) })
    }

    private func makeStagedQuickLookPreviewFile(for sourceURL: URL) throws -> URL {
        let previewsDirectory = AppBrand.currentSupportDirectoryURL()
            .appendingPathComponent("QuickLookPreviews", isDirectory: true)
        try FileManager.default.createDirectory(at: previewsDirectory, withIntermediateDirectories: true)
        let ext = sourceURL.pathExtension.isEmpty ? "jpg" : sourceURL.pathExtension
        let name = "\(UUID().uuidString).\(ext)"
        return previewsDirectory.appendingPathComponent(name, isDirectory: false)
    }

    private func removeStagedQuickLookPreviewFile(for sourceURL: URL) {
        stagedQuickLookPreviewGenerationInFlight.remove(sourceURL)
        guard let previewURL = stagedQuickLookPreviewFiles.removeValue(forKey: sourceURL) else { return }
        try? FileManager.default.removeItem(at: previewURL)
    }

    private func removeAllStagedQuickLookPreviewFiles() {
        stagedQuickLookPreviewGenerationInFlight.removeAll()
        for sourceURL in Array(stagedQuickLookPreviewFiles.keys) {
            removeStagedQuickLookPreviewFile(for: sourceURL)
        }
    }

    private func storeInspectorPreview(_ image: NSImage, for fileURL: URL, renderedSide: CGFloat) {
        inspectorPreviewImages[fileURL] = image
        let side = max(1, renderedSide)
        inspectorPreviewRenderedSide[fileURL] = max(side, inspectorPreviewRenderedSide[fileURL] ?? 0)
        ThumbnailPipeline.storeCachedImage(image, for: fileURL, renderedSide: side)
        markInspectorPreviewAsRecentlyUsed(fileURL)
        trimInspectorPreviewCacheIfNeeded()
    }

    private func renderedSide(for image: NSImage) -> CGFloat {
        max(image.size.width, image.size.height)
    }

    private static func migrateLegacySupportDirectoryIfNeeded() {
        let fileManager = FileManager.default
        let current = AppBrand.currentSupportDirectoryURL(fileManager: fileManager)

        guard !fileManager.fileExists(atPath: current.path) else { return }
        for legacy in AppBrand.legacySupportDirectoryURLs(fileManager: fileManager) {
            guard fileManager.fileExists(atPath: legacy.path) else { continue }
            do {
                try fileManager.createDirectory(at: current.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.moveItem(at: legacy, to: current)
            } catch {
                // Preserve backward compatibility by leaving legacy data in place if move fails.
            }
            break
        }
    }

    private func markInspectorPreviewAsRecentlyUsed(_ fileURL: URL) {
        if let index = inspectorPreviewRecency.firstIndex(of: fileURL) {
            inspectorPreviewRecency.remove(at: index)
        }
        inspectorPreviewRecency.append(fileURL)
    }

    private func trimInspectorPreviewCacheIfNeeded() {
        let excessCount = inspectorPreviewRecency.count - Self.maxInspectorPreviewCacheEntries
        guard excessCount > 0 else { return }
        let evicted = inspectorPreviewRecency.prefix(excessCount)
        for fileURL in evicted {
            inspectorPreviewImages[fileURL] = nil
            inspectorPreviewRenderedSide[fileURL] = nil
            inspectorPreviewInflight.remove(fileURL)
        }
        inspectorPreviewRecency.removeFirst(excessCount)
    }

    private func scheduleBackgroundWarm(forSelectionID id: String, files: [URL]) {
        guard backgroundWarmTasksBySelectionID[id] == nil else { return }
        let uniqueFiles = Array(Set(files))
        guard !uniqueFiles.isEmpty else { return }

        backgroundWarmTasksBySelectionID[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.backgroundWarmTasksBySelectionID[id] = nil }
            await self.warmCachesInBackground(files: uniqueFiles)
        }
    }

    private func warmCachesInBackground(files: [URL]) async {
        // Never contend with the active foreground load. Warm only when the UI is idle.
        while isFolderMetadataLoading || isPreviewPreloading {
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        try? await Task.sleep(nanoseconds: Self.previewBulkStartDelayNanoseconds)
        if Task.isCancelled { return }

        let filesNeedingMetadata = files.filter { fileURL in
            staleMetadataFiles.contains(fileURL) || metadataByFile[fileURL] == nil
        }
        if !filesNeedingMetadata.isEmpty {
            var map = metadataByFile
            for fileURL in filesNeedingMetadata {
                if Task.isCancelled { return }
                await Task.yield()

                let snapshots = await readMetadataBatchResilient([fileURL])
                if Task.isCancelled { return }

                for snapshot in snapshots {
                    map[snapshot.fileURL] = snapshot
                    staleMetadataFiles.remove(snapshot.fileURL)
                }
            }
            metadataByFile = map
        }

        let filesNeedingPreview = files.filter { (inspectorPreviewRenderedSide[$0] ?? 0) < Self.inspectorPreviewTargetSide }
        for fileURL in filesNeedingPreview {
            if Task.isCancelled { return }
            await Task.yield()

            if (inspectorPreviewRenderedSide[fileURL] ?? 0) >= Self.inspectorPreviewTargetSide { continue }
            if let cached = ThumbnailPipeline.cachedImage(for: fileURL, minRenderedSide: Self.inspectorPreviewTargetSide) {
                storeInspectorPreview(
                    cached,
                    for: fileURL,
                    renderedSide: max(Self.inspectorPreviewTargetSide, renderedSide(for: cached))
                )
                continue
            }
            inspectorPreviewInflight.insert(fileURL)
            if let image = await Self.generateInspectorPreviewOffMain(for: fileURL, priority: .utility) {
                storeInspectorPreview(
                    image,
                    for: fileURL,
                    renderedSide: max(Self.inspectorPreviewFullSide, renderedSide(for: image))
                )
            }
            inspectorPreviewInflight.remove(fileURL)
        }
    }

    private func cancelStaleInspectorPreviewTasks(keeping keepURLs: Set<URL>) {
        let staleURLs = inspectorPreviewTasksByURL.keys.filter { !keepURLs.contains($0) }
        guard !staleURLs.isEmpty else { return }
        for fileURL in staleURLs {
            inspectorPreviewTasksByURL[fileURL]?.cancel()
            inspectorPreviewTasksByURL[fileURL] = nil
            inspectorPreviewInflight.remove(fileURL)
        }
    }

    private func currentPendingEditState() -> PendingEditState {
        PendingEditState(
            pendingEditsByFile: pendingEditsByFile,
            pendingImageOpsByFile: pendingImageOpsByFile
        )
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
        let previousPreviewSources = Set(pendingImageOpsByFile.keys)
        pendingEditsByFile = state.pendingEditsByFile
        pendingImageOpsByFile = state.pendingImageOpsByFile.reduce(into: [:]) { partial, entry in
            let normalized = Self.normalizeStagedImageOperations(entry.value)
            if !normalized.isEmpty {
                partial[entry.key] = normalized
            }
        }
        let nextPreviewSources = Set(pendingImageOpsByFile.keys)
        let removedSources = previousPreviewSources.subtracting(nextPreviewSources)
        for sourceURL in removedSources {
            removeStagedQuickLookPreviewFile(for: sourceURL)
        }
        let invalidated = Array(previousPreviewSources.union(nextPreviewSources))
        if !invalidated.isEmpty {
            invalidateBrowserThumbnails(for: invalidated)
            invalidateInspectorPreviews(for: invalidated)
        }
        recalculateInspectorState()
        isApplyingMetadataUndoState = false
    }

    private func clearMetadataUndoHistory() {
        metadataUndoStack.removeAll()
        metadataRedoStack.removeAll()
    }

    private func availableSnapshot(for fileURL: URL) -> FileMetadataSnapshot? {
        // Keep last-known metadata visible while a stale file is being refreshed.
        // This avoids inspector fields collapsing to empty during rotate/refresh cycles.
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

    private var sourceItems: [URL] = []
    private var displayItems: [NSURL] = []
    private var displayToSource: [URL: URL] = [:]
    private weak var model: AppModel?
    private var panelObservation: NSKeyValueObservation?
    // Height locked to the first image's natural QL height for the session.
    // All subsequent images use this height; width varies by aspect ratio.
    // Mirrors Finder's QuickLook behaviour. Cleared on panel close.
    private var lockedHeight: CGFloat?

    func present(urls: [URL], focusedURL: URL?, model: AppModel) {
        sourceItems = urls
        self.model = model
        guard !sourceItems.isEmpty, let panel = QLPreviewPanel.shared() else { return }

        panel.dataSource = self
        panel.delegate = self
        rebuildDisplayItems(using: model)
        panel.reloadData()

        if let focusedURL,
           let index = sourceItems.firstIndex(of: focusedURL) {
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

        // Register the resize observer exactly once per panel instance.
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResizeNotification, object: panel)
        NotificationCenter.default.addObserver(self, selector: #selector(panelDidResize(_:)),
                                               name: NSWindow.didResizeNotification, object: panel)

        if !panel.isVisible {
            lockedHeight = nil // Fresh open — capture height from the first image.
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Called whenever QL resizes the panel (new image, user drag, etc.).
    // On first call: locks the height to QL's natural choice for the first image.
    // On subsequent calls: maintains that height, deriving width from QL's own
    // aspect ratio for the new image (QL already accounts for EXIF rotation).
    // Fires before the display refresh, so corrections are invisible.
    @objc private func panelDidResize(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel else { return }
        let size = panel.frame.size
        guard size.width > 1, size.height > 1 else { return }

        if lockedHeight == nil {
            lockedHeight = size.height
        }
        let targetHeight = lockedHeight!
        let aspectRatio = size.width / size.height
        let targetWidth = (targetHeight * aspectRatio).rounded()

        let screenFrame = (panel.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)

        // Constrain to screen; if width would overflow, scale both dimensions down.
        let finalWidth = min(targetWidth, screenFrame.width - 40)
        let finalHeight = finalWidth < targetWidth
            ? (finalWidth / aspectRatio).rounded()
            : targetHeight

        let origin = NSPoint(
            x: (screenFrame.minX + (screenFrame.width - finalWidth)  / 2).rounded(),
            y: (screenFrame.minY + (screenFrame.height - finalHeight) / 2).rounded()
        )
        let targetFrame = NSRect(origin: origin, size: NSSize(width: finalWidth, height: finalHeight))

        // Guard prevents a loop: our own setFrame triggers a second notification,
        // but the frame is already at target so we return immediately.
        guard panel.frame != targetFrame else { return }
        panel.setFrame(targetFrame, display: true)
    }

    func refreshIfVisible(model: AppModel) {
        guard let panel = QLPreviewPanel.shared() else { return }
        guard self.model === model else { return }
        let currentIndex = panel.currentPreviewItemIndex
        rebuildDisplayItems(using: model)
        panel.reloadData()
        if currentIndex >= 0, currentIndex < displayItems.count {
            panel.currentPreviewItemIndex = currentIndex
        }
        panel.refreshCurrentPreviewItem()
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        displayItems.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard displayItems.indices.contains(index) else { return nil }
        return displayItems[index]
    }

    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        guard let sourceURL = sourceURL(for: item),
              let rect = model?.quickLookSourceFrame(for: sourceURL)
        else {
            return .zero
        }
        return rect
    }

    func previewPanelWillClose(_ panel: QLPreviewPanel!) {
        panelObservation = nil
        lockedHeight = nil
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResizeNotification, object: panel)
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
        guard sourceItems.indices.contains(index) else { return }
        model?.setSelectionFromQuickLook(sourceItems[index])
    }

    private func moveSelection(in panel: QLPreviewPanel, direction: MoveCommandDirection) -> Bool {
        guard !sourceItems.isEmpty else { return false }

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
               let selectedIndex = sourceItems.firstIndex(of: selectedURL) {
                panel.currentPreviewItemIndex = selectedIndex
                return true
            }
        }

        return moveLinearly(in: panel, delta: direction == .left || direction == .up ? -1 : 1)
    }

    private func moveLinearly(in panel: QLPreviewPanel, delta: Int) -> Bool {
        guard !sourceItems.isEmpty else { return true }
        let current = panel.currentPreviewItemIndex
        let fallback = current >= 0 ? current : 0
        let proposed = fallback + delta
        let clamped = min(max(proposed, 0), sourceItems.count - 1)
        guard clamped != current else { return true }
        panel.currentPreviewItemIndex = clamped
        syncSelection(forIndex: clamped)
        return true
    }

    private func sourceURL(for item: QLPreviewItem?) -> URL? {
        guard let url = (item as? NSURL) as URL? ?? (item as? URL) else { return nil }
        return displayToSource[url.standardizedFileURL] ?? url
    }

    private func rebuildDisplayItems(using model: AppModel) {
        displayToSource.removeAll(keepingCapacity: true)
        displayItems = sourceItems.map { sourceURL in
            let displayURL = model.quickLookDisplayURL(for: sourceURL)
            displayToSource[displayURL.standardizedFileURL] = sourceURL
            return displayURL as NSURL
        }
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
