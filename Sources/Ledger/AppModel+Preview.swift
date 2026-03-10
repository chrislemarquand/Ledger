import AppKit
import ExifEditCore
import Foundation
import Quartz

@MainActor
final class QuickLookPreviewController: NSObject, @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    static let shared = QuickLookPreviewController()

    private var sourceItems: [URL] = []
    private var displayItems: [NSURL] = []
    private var displayToSource: [URL: URL] = [:]
    private weak var model: AppModel?
    private var panelObservation: NSKeyValueObservation?
    // Locked to the height QL chooses for the first image of each session.
    // QL uses the current panel as a bounding box when sizing subsequent images,
    // so without correcting the size after each resize the panel shrinks on every
    // AR-changing navigation. We preserve QL's aspect ratio but restore the locked
    // height so the panel stays a consistent size across the session.
    // Always cleared in present() so stale values never carry over between sessions.
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

        // Always reset the locked height so a stale value from a previous session
        // (panel still visible, different image set) never corrupts the new session.
        lockedHeight = nil

        // Register the resize observer exactly once per panel instance.
        // Without this, QL anchors its bottom-left corner on resize, causing the
        // panel to jump left/up when aspect ratio changes between images.
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResizeNotification, object: panel)
        NotificationCenter.default.addObserver(self, selector: #selector(panelDidResize(_:)),
                                               name: NSWindow.didResizeNotification, object: panel)

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Called whenever QL resizes the panel (new image or user drag).
    // Locks height to QL's natural choice for the first image, then on subsequent
    // resizes restores that height while deriving width from the current AR.
    // This counteracts QL's bounding-box behaviour: without correction, QL
    // constrains each image to the previous panel size, causing progressive shrinkage.
    // A guard on the computed frame prevents the setFrame call from re-triggering
    // this handler in a loop.
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

        let finalWidth  = min(targetWidth, screenFrame.width - 40)
        let finalHeight = finalWidth < targetWidth
            ? (finalWidth / aspectRatio).rounded()
            : targetHeight

        let origin = NSPoint(
            x: (screenFrame.minX + (screenFrame.width  - finalWidth)  / 2).rounded(),
            y: (screenFrame.minY + (screenFrame.height - finalHeight) / 2).rounded()
        )
        let targetFrame = NSRect(origin: origin, size: NSSize(width: finalWidth, height: finalHeight))
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

struct UnavailableExifToolService: ExifToolServiceProtocol {
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
