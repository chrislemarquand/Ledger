import AppKit
import Foundation
import ImageIO
import QuickLookThumbnailing

enum ThumbnailService {
    private struct RequestKey: Hashable {
        let url: URL
        let requiredSide: Int
    }

    private final class ThumbnailCache: @unchecked Sendable {
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
            operation: @escaping @Sendable () async -> NSImage?
        ) async -> NSImage? {
            if let task = inflight[key] {
                return await task.value
            }
            let task = Task<NSImage?, Never> { [weak self] in
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

    private static let cache = ThumbnailCache(maxEntries: 3_000)
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

        let key = RequestKey(url: url, requiredSide: normalizedSide)
        return await broker.request(key: key) {
            await generateThumbnail(fileURL: url, maxPixelSize: CGFloat(normalizedSide))
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
