import AppKit
import Foundation
import ImageIO
import SharedUI

enum ThumbnailService {

    // MARK: - Memory cache

    // NSCache is thread-safe internally; nonisolated(unsafe) suppresses the Swift 6
    // Sendable warning while preserving correct concurrent access.
    private nonisolated(unsafe) static let memoryCache: NSCache<NSURL, NSImage> = {
        let c = NSCache<NSURL, NSImage>()
        c.countLimit = 2_000
        c.totalCostLimit = 200 * 1024 * 1024
        return c
    }()

    // MARK: - Disk cache

    private static let diskCacheDirectory: URL = {
        let bundleID = Bundle.main.bundleIdentifier ?? "Ledger"
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Caches")
        let dir = base.appendingPathComponent(bundleID).appendingPathComponent("thumbnails")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func diskURL(for fileURL: URL) -> URL {
        // DJB2-variant hash of the file path — deterministic, no extra imports.
        let hash = fileURL.path.utf8.reduce(into: UInt64(5381)) { $0 = $0 &* 31 &+ UInt64($1) }
        return diskCacheDirectory.appendingPathComponent(String(hash, radix: 16) + ".jpg")
    }

    private static func readDiskCache(sourceURL: URL, at diskURL: URL) -> NSImage? {
        guard FileManager.default.fileExists(atPath: diskURL.path) else { return nil }
        guard !ThumbnailGenerator.isDiskCacheStale(sourceURL: sourceURL, cacheURL: diskURL) else { return nil }
        return NSImage(contentsOf: diskURL)
    }

    private static func writeDiskCache(_ image: NSImage, to diskURL: URL) {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
        else { return }
        try? jpeg.write(to: diskURL, options: .atomic)
        scheduleDiskCacheMaintenanceIfNeeded()
    }

    // MARK: - Disk cache maintenance (Phase 3.3)

    /// Measured against this app's real disk cache contents (2026-09-02): 627 thumbnails
    /// (a mix of ~180px gallery thumbnails and up to 1400px inspector previews) averaged
    /// ~224KB each, ~135MB total, for well under one full benchmark-corpus folder (1,012
    /// files) worth of browsing. With no cap at all, that grows without bound across every
    /// folder ever visited, forever. 1GB holds roughly 4,000+ thumbnails at that measured
    /// average — several corpus-folders' worth — as a documented, evidence-derived budget
    /// rather than an arbitrary number.
    static let diskCacheBudgetBytes = 1_000 * 1024 * 1024
    /// Trim back to 80% of budget, not exactly to the limit, so maintenance doesn't re-run
    /// on essentially every subsequent write once the cache sits right at the boundary.
    static let diskCacheTrimTargetBytes = 800 * 1024 * 1024
    private static let diskCacheMaintenanceMinInterval: TimeInterval = 5 * 60

    private nonisolated(unsafe) static var lastDiskCacheMaintenanceAt = Date.distantPast
    private static let maintenanceScheduleLock = NSLock()

    /// Rate-limited trigger, called after every disk-cache write (already off the hot path —
    /// `writeDiskCache` itself only ever runs inside a detached background `Task`, never from
    /// launch, cell-configuration, scrolling, or decode call sites). A cheap timestamp check
    /// under a lock, not a directory scan, is all that runs synchronously here; the scan itself
    /// is further dispatched to a detached utility-priority task.
    private static func scheduleDiskCacheMaintenanceIfNeeded() {
        maintenanceScheduleLock.lock()
        let now = Date()
        guard now.timeIntervalSince(lastDiskCacheMaintenanceAt) >= diskCacheMaintenanceMinInterval else {
            maintenanceScheduleLock.unlock()
            return
        }
        lastDiskCacheMaintenanceAt = now
        maintenanceScheduleLock.unlock()

        Task.detached(priority: .utility) {
            performDiskCacheMaintenance()
        }
    }

    /// Pure selection logic, independent of `FileManager` so it's directly unit-testable:
    /// given every cache entry's size and modification date, returns which URLs to delete —
    /// oldest-modified first — to bring `totalSize` down to `trimTargetBytes`, or an empty
    /// array if `totalSize` doesn't exceed `budgetBytes` yet.
    static func urlsToEvictForDiskCacheMaintenance(
        items: [(url: URL, size: Int, modifiedAt: Date)],
        totalSize: Int,
        budgetBytes: Int,
        trimTargetBytes: Int
    ) -> [URL] {
        guard totalSize > budgetBytes else { return [] }
        let orderedByAge = items.sorted { $0.modifiedAt < $1.modifiedAt }
        var remaining = totalSize
        var toEvict: [URL] = []
        for item in orderedByAge {
            guard remaining > trimTargetBytes else { break }
            toEvict.append(item.url)
            remaining -= item.size
        }
        return toEvict
    }

    /// Scans a disk cache directory and evicts oldest entries if over budget. Tolerant of
    /// missing, corrupt, or concurrently-removed files throughout — a file that vanishes or
    /// fails to read between the scan and the delete is simply skipped, never treated as an
    /// error worth surfacing (this is disposable cache maintenance, not user data).
    /// `budgetBytes`/`trimTargetBytes` default to the real production constants; overridable
    /// so tests can exercise real eviction end-to-end on a small temporary directory without
    /// needing a multi-gigabyte fixture to cross the real budget.
    static func performDiskCacheMaintenance(
        in directory: URL = diskCacheDirectory,
        budgetBytes: Int = diskCacheBudgetBytes,
        trimTargetBytes: Int = diskCacheTrimTargetBytes
    ) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var items: [(url: URL, size: Int, modifiedAt: Date)] = []
        var totalSize = 0
        for url in entries {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize
            else { continue }
            let modifiedAt = values.contentModificationDate ?? .distantPast
            items.append((url, size, modifiedAt))
            totalSize += size
        }

        let toEvict = urlsToEvictForDiskCacheMaintenance(
            items: items,
            totalSize: totalSize,
            budgetBytes: budgetBytes,
            trimTargetBytes: trimTargetBytes
        )
        for url in toEvict {
            try? fileManager.removeItem(at: url)
        }
    }

    // MARK: - Cost

    private static func costBytes(for image: NSImage) -> Int {
        for rep in image.representations {
            if let bitmap = rep as? NSBitmapImageRep {
                return max(1, bitmap.pixelsWide * bitmap.pixelsHigh * 4)
            }
        }
        return max(1, Int(image.size.width) * Int(image.size.height) * 4)
    }

    // MARK: - Request broker

    private actor Broker {
        private let maxConcurrent: Int
        private var active = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var inflight: [RequestKey: Task<NSImage?, Never>] = [:]
        private static let maxWaiters = 200

        init(maxConcurrent: Int) { self.maxConcurrent = maxConcurrent }

        func request(
            key: RequestKey,
            priority: TaskPriority,
            work: @escaping @Sendable () async -> NSImage?
        ) async -> NSImage? {
            if let existing = inflight[key] { return await existing.value }
            let task = Task(priority: priority) { [weak self] in
                await self?.withPermit(work)
            }
            inflight[key] = task
            let image = await task.value
            inflight[key] = nil
            return image
        }

        func cancelAll() {
            inflight.values.forEach { $0.cancel() }
            inflight.removeAll()
            waiters.forEach { $0.resume() }
            waiters.removeAll()
            active = 0
        }

        private func withPermit(_ work: @escaping @Sendable () async -> NSImage?) async -> NSImage? {
            await acquirePermit()
            guard !Task.isCancelled else { releasePermit(); return nil }
            defer { releasePermit() }
            return await work()
        }

        private func acquirePermit() async {
            guard active >= maxConcurrent else { active += 1; return }
            if waiters.count >= Self.maxWaiters { waiters.removeFirst().resume() }
            await withCheckedContinuation { waiters.append($0) }
        }

        private func releasePermit() {
            if !waiters.isEmpty { waiters.removeFirst().resume() }
            else { active = max(0, active - 1) }
        }
    }

    private struct RequestKey: Hashable {
        let url: URL
        let side: Int
    }

    private static let broker = Broker(maxConcurrent: 4)

    // MARK: - Public cache API

    /// Returns a cached image if one exists in memory and is at least `minRenderedSide` points on
    /// its longest edge. Pass `minRenderedSide: 1` to accept any cached image regardless of size.
    ///
    /// Memory-only, deliberately — v1.4 Phase 1.1. This used to fall back to a synchronous on-disk
    /// cache read (a `FileManager.fileExists`/mtime stat plus `NSImage(contentsOf:)` decode) on a
    /// memory-cache miss, so cells configured synchronously wouldn't paint the generic fallback
    /// icon for a frame when a thumbnail was already sitting on disk. That fallback ran inline on
    /// every caller's thread, including genuine cell-configuration and selection hot paths
    /// (`collectionView(_:itemForRepresentedObjectAt:)`, `didSelectItemsAt`, list row
    /// configuration) — real disk I/O and image decode on the main thread during scrolling,
    /// folder switching, and selection. Disk-cache reads still happen, just asynchronously, via
    /// `request(url:requiredSide:forceRefresh:)` → `generate(fileURL:maxPixelSize:)`. The accepted
    /// trade-off (per the plan): a cold-cache-in-memory-but-warm-on-disk thumbnail may show a
    /// placeholder for one more render pass instead of appearing synchronously.
    static func cachedImage(for fileURL: URL, minRenderedSide: CGFloat) -> NSImage? {
        guard let image = memoryCache.object(forKey: fileURL as NSURL) else { return nil }
        guard minRenderedSide > 1 else { return image }
        let cachedSide = max(image.size.width, image.size.height)
        return cachedSide >= minRenderedSide * 0.9 ? image : nil
    }

    static func storeCachedImage(_ image: NSImage, for fileURL: URL, renderedSide: CGFloat) {
        memoryCache.setObject(image, forKey: fileURL as NSURL, cost: costBytes(for: image))
    }

    static func invalidateAllCachedImages() {
        memoryCache.removeAllObjects()
        let dir = diskCacheDirectory
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    static func invalidateCachedImages(for fileURLs: Set<URL>) {
        for url in fileURLs {
            memoryCache.removeObject(forKey: url as NSURL)
            try? FileManager.default.removeItem(at: diskURL(for: url))
        }
    }

    static func fallbackIcon(for fileURL: URL, side: CGFloat) -> NSImage {
        ThumbnailGenerator.thumbnailFallbackIcon(for: fileURL, side: max(16, min(side, 256)))
    }

    static func cancelAllRequests() async {
        await broker.cancelAll()
    }

    // MARK: - Public request API

    /// Request a thumbnail at `requiredSide` points on the longest edge.
    /// Returns a cached image immediately if one exists at adequate resolution.
    /// If the cached image is smaller than requested, falls through to generate at full size —
    /// callers can use `cachedImage(for:minRenderedSide:1)` to show a placeholder while waiting.
    static func request(url: URL, requiredSide: CGFloat, forceRefresh: Bool) async -> NSImage? {
        let signpostID = Signposts.thumbnail.makeSignpostID()
        let state = Signposts.thumbnail.beginInterval("ThumbnailRequest", id: signpostID)
        defer { Signposts.thumbnail.endInterval("ThumbnailRequest", state) }

        if forceRefresh {
            invalidateCachedImages(for: [url])
        } else if let cached = memoryCache.object(forKey: url as NSURL) {
            let cachedSide = max(cached.size.width, cached.size.height)
            if cachedSide >= requiredSide * 0.9 { return cached }
            // Cached image is too small — fall through to generate at the requested size.
        }

        let side = max(1, Int(requiredSide.rounded(.up)))
        let priority: TaskPriority = (Task.currentPriority >= .userInitiated) ? .userInitiated : .utility
        return await broker.request(key: RequestKey(url: url, side: side), priority: priority) {
            await generate(fileURL: url, maxPixelSize: CGFloat(side))
        }
    }

    // MARK: - Generation

    static func generateThumbnail(fileURL: URL, maxPixelSize: CGFloat) async -> NSImage? {
        await generate(fileURL: fileURL, maxPixelSize: maxPixelSize)
    }

    static func isLikelyImageFile(_ fileURL: URL) -> Bool {
        ThumbnailGenerator.isLikelyImageFile(fileURL)
    }

    private static func generateDownsampledFallback(fileURL: URL, maxPixelSize: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixelSize.rounded(.up)))
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private static func generate(fileURL: URL, maxPixelSize: CGFloat) async -> NSImage? {
        // Hot path — another task may have populated the cache while we waited for a broker permit.
        if let cached = memoryCache.object(forKey: fileURL as NSURL) {
            let cachedSide = max(cached.size.width, cached.size.height)
            if cachedSide >= maxPixelSize * 0.9 { return cached }
        }

        // Warm path — disk cache.
        let dURL = diskURL(for: fileURL)
        if let disk = readDiskCache(sourceURL: fileURL, at: dURL) {
            let diskSide = max(disk.size.width, disk.size.height)
            if diskSide >= maxPixelSize * 0.9 {
                memoryCache.setObject(disk, forKey: fileURL as NSURL, cost: costBytes(for: disk))
                return disk
            }
        }

        // Cold path — generate fresh.
        let image: NSImage?
        if CloudFileStateResolver.resolve(for: fileURL).isPlaceholder {
            // Placeholder files aren't on disk yet. generateOrientedThumbnail and
            // generateDownsampledFallback both read raw file bytes via CGImageSource, which
            // forces fileproviderd to materialise the whole file — not native Finder behaviour.
            // QLThumbnailGenerator can preview a placeholder without downloading it; if that
            // fails too, fall straight to the generic icon rather than forcing a download.
            image = await ThumbnailGenerator.generateQuickLookThumbnail(fileURL: fileURL, maxPixelSize: maxPixelSize)
        } else if ThumbnailGenerator.isLikelyImageFile(fileURL) {
            if let oriented = ThumbnailGenerator.generateOrientedThumbnail(fileURL: fileURL, maxPixelSize: maxPixelSize) {
                image = oriented
            } else if let ql = await ThumbnailGenerator.generateQuickLookThumbnail(fileURL: fileURL, maxPixelSize: maxPixelSize) {
                image = ql
            } else {
                image = generateDownsampledFallback(fileURL: fileURL, maxPixelSize: maxPixelSize)
            }
        } else {
            if let ql = await ThumbnailGenerator.generateQuickLookThumbnail(fileURL: fileURL, maxPixelSize: maxPixelSize) {
                image = ql
            } else if let oriented = ThumbnailGenerator.generateOrientedThumbnail(fileURL: fileURL, maxPixelSize: maxPixelSize) {
                image = oriented
            } else {
                image = generateDownsampledFallback(fileURL: fileURL, maxPixelSize: maxPixelSize)
            }
        }

        if let image {
            memoryCache.setObject(image, forKey: fileURL as NSURL, cost: costBytes(for: image))
            Task.detached(priority: .background) { writeDiskCache(image, to: dURL) }
            return image
        }

        // Fallback icon — stored in memory only (cheap to recreate, wrong content type for disk).
        let icon = ThumbnailGenerator.thumbnailFallbackIcon(for: fileURL, side: max(16, min(maxPixelSize, 256)))
        memoryCache.setObject(icon, forKey: fileURL as NSURL, cost: costBytes(for: icon))
        return icon
    }
}
