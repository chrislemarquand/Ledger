import AppKit
import Foundation
import ImageIO
import QuickLookThumbnailing

enum ThumbnailService {
    private struct RequestKey: Hashable {
        let url: URL
        let requiredSide: Int
        let lane: RequestLane
    }

    private enum RequestLane: Hashable {
        case foreground
        case background
    }

    private final class ThumbnailCache: @unchecked Sendable {
        private let maxEntries: Int
        private let maxTotalCostBytes: Int
        private let lock = NSLock()
        private var entries: [URL: CacheEntry] = [:]
        private var totalCostBytes = 0
        private var lruHead: CacheNode?
        private var lruTail: CacheNode?

        private final class CacheNode {
            let url: URL
            var previous: CacheNode?
            var next: CacheNode?

            init(url: URL) {
                self.url = url
            }
        }

        private struct CacheEntry {
            var image: NSImage
            var renderedSide: CGFloat
            var costBytes: Int
            let node: CacheNode
        }

        init(maxEntries: Int, maxTotalCostBytes: Int) {
            self.maxEntries = max(100, maxEntries)
            self.maxTotalCostBytes = max(64 * 1024 * 1024, maxTotalCostBytes)
        }

        func image(for url: URL, minRenderedSide: CGFloat) -> NSImage? {
            lock.lock()
            defer { lock.unlock() }
            guard let entry = entries[url] else { return nil }
            if entry.renderedSide + 0.5 < minRenderedSide {
                return nil
            }
            touch(entry.node)
            return entry.image
        }

        func store(_ image: NSImage, for url: URL, renderedSide: CGFloat) {
            lock.lock()
            defer { lock.unlock() }
            let newCostBytes = estimateCostBytes(for: image)
            if var existing = entries[url] {
                totalCostBytes -= existing.costBytes
                existing.image = image
                existing.renderedSide = max(renderedSide, existing.renderedSide)
                existing.costBytes = newCostBytes
                entries[url] = existing
                totalCostBytes += newCostBytes
                touch(existing.node)
            } else {
                let node = CacheNode(url: url)
                let entry = CacheEntry(
                    image: image,
                    renderedSide: renderedSide,
                    costBytes: newCostBytes,
                    node: node
                )
                entries[url] = entry
                totalCostBytes += newCostBytes
                appendToTail(node)
            }
            trimIfNeeded()
        }

        func invalidateAll() {
            lock.lock()
            defer { lock.unlock() }
            entries.removeAll()
            totalCostBytes = 0
            lruHead = nil
            lruTail = nil
        }

        func invalidate(urls: Set<URL>) {
            guard !urls.isEmpty else { return }
            lock.lock()
            defer { lock.unlock() }
            for url in urls {
                removeEntry(for: url)
            }
        }

        private func touch(_ node: CacheNode) {
            guard lruTail !== node else { return }
            detach(node)
            appendToTail(node)
        }

        private func trimIfNeeded() {
            while entries.count > maxEntries || totalCostBytes > maxTotalCostBytes {
                guard let oldest = lruHead else { break }
                removeEntry(for: oldest.url)
            }
        }

        private func removeEntry(for url: URL) {
            guard let existing = entries.removeValue(forKey: url) else { return }
            totalCostBytes = max(0, totalCostBytes - existing.costBytes)
            detach(existing.node)
        }

        private func appendToTail(_ node: CacheNode) {
            node.previous = lruTail
            node.next = nil
            lruTail?.next = node
            lruTail = node
            if lruHead == nil {
                lruHead = node
            }
        }

        private func detach(_ node: CacheNode) {
            let previous = node.previous
            let next = node.next
            if let previous {
                previous.next = next
            } else {
                lruHead = next
            }
            if let next {
                next.previous = previous
            } else {
                lruTail = previous
            }
            node.previous = nil
            node.next = nil
        }

        private func estimateCostBytes(for image: NSImage) -> Int {
            var bestCost = 0
            for representation in image.representations {
                if let bitmap = representation as? NSBitmapImageRep {
                    let width = max(1, bitmap.pixelsWide)
                    let height = max(1, bitmap.pixelsHigh)
                    bestCost = max(bestCost, width * height * 4)
                }
            }
            if bestCost > 0 {
                return bestCost
            }
            let fallbackWidth = max(1, Int(image.size.width.rounded(.up)))
            let fallbackHeight = max(1, Int(image.size.height.rounded(.up)))
            return max(1, fallbackWidth * fallbackHeight * 4)
        }
    }

    private actor RequestBroker {
        private let maxConcurrentRequests: Int
        private var activeRequestCount = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var inflight: [RequestKey: Task<NSImage?, Never>] = [:]

        init(maxConcurrentRequests: Int) {
            self.maxConcurrentRequests = max(1, maxConcurrentRequests)
        }

        func request(
            key: RequestKey,
            priority: TaskPriority,
            operation: @escaping @Sendable () async -> NSImage?
        ) async -> NSImage? {
            if let task = inflight[key] {
                return await task.value
            }
            let task = Task<NSImage?, Never>(priority: priority) { [weak self] in
                guard let self else { return nil }
                return await self.runWithPermit(operation)
            }
            inflight[key] = task
            let image = await task.value
            inflight[key] = nil
            return image
        }

        func cancelAllRequests() {
            for task in inflight.values {
                task.cancel()
            }
            inflight.removeAll()
            while !waiters.isEmpty {
                waiters.removeFirst().resume()
            }
        }

        private func acquirePermit() async {
            if activeRequestCount < maxConcurrentRequests {
                activeRequestCount += 1
                return
            }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        private func releasePermit() {
            if !waiters.isEmpty {
                let waiter = waiters.removeFirst()
                waiter.resume()
                return
            }
            activeRequestCount = max(0, activeRequestCount - 1)
        }

        private func runWithPermit(
            _ operation: @escaping @Sendable () async -> NSImage?
        ) async -> NSImage? {
            await acquirePermit()
            guard !Task.isCancelled else {
                releasePermit()
                return nil
            }
            defer { releasePermit() }
            return await operation()
        }
    }

    private static let cache = ThumbnailCache(
        maxEntries: 3_000,
        maxTotalCostBytes: 256 * 1024 * 1024
    )
    private static let broker = RequestBroker(maxConcurrentRequests: 4)

    static func cachedImage(for fileURL: URL, minRenderedSide: CGFloat) -> NSImage? {
        cache.image(for: fileURL, minRenderedSide: minRenderedSide)
    }

    static func storeCachedImage(_ image: NSImage, for fileURL: URL, renderedSide: CGFloat) {
        cache.store(image, for: fileURL, renderedSide: renderedSide)
    }

    static func invalidateAllCachedImages() {
        cache.invalidateAll()
    }

    static func invalidateCachedImages(for fileURLs: Set<URL>) {
        cache.invalidate(urls: fileURLs)
    }

    static func fallbackIcon(for fileURL: URL, side: CGFloat) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: fileURL.path)
        icon.size = NSSize(width: side, height: side)
        return icon
    }

    static func cancelAllRequests() async {
        await broker.cancelAllRequests()
    }

    static func request(url: URL, requiredSide: CGFloat, forceRefresh: Bool) async -> NSImage? {
        let normalizedSide = max(1, Int(requiredSide.rounded(.up)))
        if forceRefresh {
            invalidateCachedImages(for: [url])
        } else if let cached = cachedImage(for: url, minRenderedSide: CGFloat(normalizedSide)) {
            return cached
        }

        let lane = requestLane(for: Task.currentPriority)
        let taskPriority = taskPriority(for: lane)
        let key = RequestKey(url: url, requiredSide: normalizedSide, lane: lane)
        return await broker.request(key: key, priority: taskPriority) {
            await generateThumbnail(fileURL: url, maxPixelSize: CGFloat(normalizedSide))
        }
    }

    private static func requestLane(for priority: TaskPriority) -> RequestLane {
        switch priority {
        case .userInitiated, .high:
            return .foreground
        default:
            return .background
        }
    }

    private static func taskPriority(for lane: RequestLane) -> TaskPriority {
        switch lane {
        case .foreground:
            return .userInitiated
        case .background:
            return .utility
        }
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
