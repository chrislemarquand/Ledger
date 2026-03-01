import AppKit
import Foundation

enum ThumbnailSurfacePolicy {
    case gallery
    case list
    case inspector

    var defaultPriority: TaskPriority {
        switch self {
        case .gallery:
            return .userInitiated
        case .list:
            return .utility
        case .inspector:
            return .userInitiated
        }
    }

    func lowResolutionSide(for targetSide: CGFloat) -> CGFloat {
        switch self {
        case .gallery:
            return min(max(targetSide, 120), 220)
        case .list:
            return min(max(targetSide, 32), 64)
        case .inspector:
            return min(max(targetSide, 180), 320)
        }
    }

    func highResolutionSide(for targetSide: CGFloat) -> CGFloat {
        switch self {
        case .gallery:
            return max(targetSide * 2, 240)
        case .list:
            return max(targetSide, 64)
        case .inspector:
            return max(targetSide, 480)
        }
    }
}

enum ThumbnailLoadPhase: String {
    case missing
    case loadingLow
    case readyLow
    case loadingHigh
    case readyHigh
    case failedFallback
}

struct ThumbnailLoadState: Sendable {
    let phase: ThumbnailLoadPhase
    let renderedSide: CGFloat
    let lastUpdatedAt: Date
}

@MainActor
final class ThumbnailCoordinator {
    static let shared = ThumbnailCoordinator()

    private var states: [URL: ThumbnailLoadState] = [:]
    private var requestTasks: [URL: Task<Void, Never>] = [:]
    private var requestGenerations: [URL: Int] = [:]
    private var inflightTargetSide: [URL: CGFloat] = [:]

    private init() {}

    func state(for url: URL) -> ThumbnailLoadState? {
        states[url]
    }

    func ensureThumbnail(
        url: URL,
        targetSide: CGFloat,
        policy: ThumbnailSurfacePolicy,
        forceRefresh: Bool = false,
        notifyUpdates: Bool = true,
        priorityOverride: TaskPriority? = nil
    ) {
        let normalizedTarget = max(16, targetSide)
        if forceRefresh {
            invalidate(urls: [url])
        } else if let cached = ThumbnailPipeline.cachedImage(for: url, minRenderedSide: normalizedTarget) {
            updateState(
                url: url,
                phase: .readyHigh,
                renderedSide: max(normalizedTarget, renderedSide(for: cached)),
                notify: false
            )
            return
        } else if let inflight = inflightTargetSide[url], inflight + 0.5 >= normalizedTarget {
            return
        }

        let generation = (requestGenerations[url] ?? 0) + 1
        requestGenerations[url] = generation
        inflightTargetSide[url] = normalizedTarget
        requestTasks[url]?.cancel()
        requestTasks[url] = Task { @MainActor [weak self] in
            guard let self else { return }
            let _ = await self.loadThumbnail(
                url: url,
                targetSide: normalizedTarget,
                policy: policy,
                forceRefresh: forceRefresh,
                generation: generation,
                notifyUpdates: notifyUpdates,
                priorityOverride: priorityOverride
            )
            self.requestTasks[url] = nil
            self.inflightTargetSide[url] = nil
        }
    }

    func prefetch(
        urls: [URL],
        targetSide: CGFloat,
        policy: ThumbnailSurfacePolicy
    ) {
        for url in urls {
            ensureThumbnail(
                url: url,
                targetSide: targetSide,
                policy: policy,
                forceRefresh: false,
                notifyUpdates: false
            )
        }
    }

    func loadThumbnail(
        url: URL,
        targetSide: CGFloat,
        policy: ThumbnailSurfacePolicy,
        forceRefresh: Bool,
        priorityOverride: TaskPriority? = nil
    ) async -> NSImage? {
        let generation = (requestGenerations[url] ?? 0) + 1
        requestGenerations[url] = generation
        return await loadThumbnail(
            url: url,
            targetSide: targetSide,
            policy: policy,
            forceRefresh: forceRefresh,
            generation: generation,
            notifyUpdates: true,
            priorityOverride: priorityOverride
        )
    }

    func invalidate(urls: Set<URL>) {
        guard !urls.isEmpty else { return }
        for url in urls {
            requestTasks[url]?.cancel()
            requestTasks[url] = nil
            inflightTargetSide[url] = nil
            states[url] = ThumbnailLoadState(phase: .missing, renderedSide: 0, lastUpdatedAt: Date())
        }
        ThumbnailPipeline.invalidateCachedImages(for: urls)
    }

    func invalidateAll() {
        for task in requestTasks.values {
            task.cancel()
        }
        requestTasks.removeAll()
        inflightTargetSide.removeAll()
        states.removeAll()
        ThumbnailPipeline.invalidateAllCachedImages()
    }

    private func loadThumbnail(
        url: URL,
        targetSide: CGFloat,
        policy: ThumbnailSurfacePolicy,
        forceRefresh: Bool,
        generation: Int,
        notifyUpdates: Bool,
        priorityOverride: TaskPriority?
    ) async -> NSImage? {
        let normalizedTarget = max(16, targetSide)
        if forceRefresh {
            ThumbnailPipeline.invalidateCachedImages(for: [url])
        }

        if let cached = ThumbnailPipeline.cachedImage(for: url, minRenderedSide: normalizedTarget) {
            updateState(url: url, phase: .readyHigh, renderedSide: max(normalizedTarget, renderedSide(for: cached)), notify: notifyUpdates)
            return cached
        }

        let lowSide = min(normalizedTarget, policy.lowResolutionSide(for: normalizedTarget))
        updateState(url: url, phase: .loadingLow, renderedSide: max(lowSide, 1), notify: false)

        let lowImage: NSImage?
        if let cachedLow = ThumbnailPipeline.cachedImage(for: url, minRenderedSide: lowSide) {
            lowImage = cachedLow
        } else {
            lowImage = await requestImage(url: url, requiredSide: lowSide, forceRefresh: false, priority: priorityOverride ?? policy.defaultPriority)
        }

        guard isLatestGeneration(url: url, generation: generation) else { return nil }

        if let lowImage {
            updateState(url: url, phase: .readyLow, renderedSide: max(lowSide, renderedSide(for: lowImage)), notify: notifyUpdates)
        }

        let highSide = max(normalizedTarget, policy.highResolutionSide(for: normalizedTarget))
        guard highSide > lowSide + 1 else {
            return lowImage
        }

        if let cachedHigh = ThumbnailPipeline.cachedImage(for: url, minRenderedSide: highSide) {
            updateState(url: url, phase: .readyHigh, renderedSide: max(highSide, renderedSide(for: cachedHigh)), notify: notifyUpdates)
            return cachedHigh
        }

        updateState(url: url, phase: .loadingHigh, renderedSide: max(highSide, 1), notify: false)
        let highImage = await requestImage(
            url: url,
            requiredSide: highSide,
            forceRefresh: false,
            priority: priorityOverride ?? policy.defaultPriority
        )

        guard isLatestGeneration(url: url, generation: generation) else { return lowImage }

        if let highImage {
            updateState(url: url, phase: .readyHigh, renderedSide: max(highSide, renderedSide(for: highImage)), notify: notifyUpdates)
            return highImage
        }

        if let lowImage {
            return lowImage
        }

        let fallback = ThumbnailPipeline.fallbackIcon(for: url, side: max(16, min(highSide, 256)))
        updateState(url: url, phase: .failedFallback, renderedSide: max(16, renderedSide(for: fallback)), notify: notifyUpdates)
        return fallback
    }

    private func requestImage(
        url: URL,
        requiredSide: CGFloat,
        forceRefresh: Bool,
        priority: TaskPriority
    ) async -> NSImage? {
        await Task.detached(priority: priority) {
            await SharedThumbnailRequestBroker.shared.request(
                url: url,
                requiredSide: requiredSide,
                forceRefresh: forceRefresh
            )
        }.value
    }

    private func isLatestGeneration(url: URL, generation: Int) -> Bool {
        requestGenerations[url] == generation
    }

    private func updateState(
        url: URL,
        phase: ThumbnailLoadPhase,
        renderedSide: CGFloat,
        notify: Bool = true
    ) {
        let normalizedSide = max(1, renderedSide)
        if let previous = states[url],
           previous.phase == phase,
           abs(previous.renderedSide - normalizedSide) < 1 {
            return
        }
        states[url] = ThumbnailLoadState(
            phase: phase,
            renderedSide: normalizedSide,
            lastUpdatedAt: Date()
        )
        if notify {
            NotificationCenter.default.post(
                name: .thumbnailCoordinatorDidUpdate,
                object: nil,
                userInfo: ["url": url]
            )
        }
    }

    private func renderedSide(for image: NSImage) -> CGFloat {
        max(image.size.width, image.size.height)
    }
}

extension Notification.Name {
    static let thumbnailCoordinatorDidUpdate = Notification.Name("\(AppBrand.identifierPrefix).ThumbnailCoordinatorDidUpdate")
}
