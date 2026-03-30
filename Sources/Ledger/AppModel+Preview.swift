import AppKit
import ExifEditCore
import Foundation
import SharedUI

@MainActor
final class QuickLookPreviewController: NSObject {
    static let shared = QuickLookPreviewController()

    private let coordinator = QuickLookPanelCoordinator<URL>()
    private weak var model: AppModel?

    func present(urls: [URL], focusedURL: URL?, model: AppModel) {
        self.model = model
        coordinator.present(
            sourceItems: urls,
            focusedItem: focusedURL,
            displayURLForSource: { sourceURL in
                model.quickLookDisplayURL(for: sourceURL)
            },
            sourceFrameForSource: { sourceURL in
                model.quickLookSourceFrame(for: sourceURL)
            },
            selectionDidChange: { sourceURL in
                model.setSelectionFromQuickLook(sourceURL)
            },
            moveSelection: { [weak model] direction in
                guard let model else { return nil }
                switch model.browserViewMode {
                case .gallery:
                    model.moveSelectionInGallery(direction: direction, extendingSelection: false)
                case .list:
                    switch direction {
                    case .up, .down:
                        model.moveSelectionInList(direction: direction, extendingSelection: false)
                    case .left:
                        return nil
                    case .right:
                        return nil
                    }
                }
                return model.primarySelectionURL
            },
            onWillClose: { [weak self] in
                self?.model = nil
            }
        )
    }

    func refreshIfVisible(model: AppModel) {
        guard self.model === model else { return }
        coordinator.refreshDisplayItems()
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
