import AppKit
import Foundation
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

    private static func readDiskCache(at diskURL: URL) -> NSImage? {
        guard FileManager.default.fileExists(atPath: diskURL.path) else { return nil }
        return NSImage(contentsOf: diskURL)
    }

    private static func writeDiskCache(_ image: NSImage, to diskURL: URL) {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
        else { return }
        try? jpeg.write(to: diskURL, options: .atomic)
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

    /// Returns a cached image if one exists and is at least `minRenderedSide` points on its longest edge.
    /// Pass `minRenderedSide: 1` to accept any cached image regardless of size.
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

    private static func generate(fileURL: URL, maxPixelSize: CGFloat) async -> NSImage? {
        // Hot path — another task may have populated the cache while we waited for a broker permit.
        if let cached = memoryCache.object(forKey: fileURL as NSURL) {
            let cachedSide = max(cached.size.width, cached.size.height)
            if cachedSide >= maxPixelSize * 0.9 { return cached }
        }

        // Warm path — disk cache.
        let dURL = diskURL(for: fileURL)
        if let disk = readDiskCache(at: dURL) {
            let diskSide = max(disk.size.width, disk.size.height)
            if diskSide >= maxPixelSize * 0.9 {
                memoryCache.setObject(disk, forKey: fileURL as NSURL, cost: costBytes(for: disk))
                return disk
            }
        }

        // Cold path — generate fresh.
        let image: NSImage?
        if ThumbnailGenerator.isLikelyImageFile(fileURL) {
            if let oriented = ThumbnailGenerator.generateOrientedThumbnail(fileURL: fileURL, maxPixelSize: maxPixelSize) {
                image = oriented
            } else if let ql = await ThumbnailGenerator.generateQuickLookThumbnail(fileURL: fileURL, maxPixelSize: maxPixelSize) {
                image = ql
            } else {
                image = NSImage(contentsOf: fileURL)
            }
        } else {
            if let ql = await ThumbnailGenerator.generateQuickLookThumbnail(fileURL: fileURL, maxPixelSize: maxPixelSize) {
                image = ql
            } else if let oriented = ThumbnailGenerator.generateOrientedThumbnail(fileURL: fileURL, maxPixelSize: maxPixelSize) {
                image = oriented
            } else {
                image = NSImage(contentsOf: fileURL)
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
