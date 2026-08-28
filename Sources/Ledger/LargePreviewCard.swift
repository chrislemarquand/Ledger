import SharedUI
import SwiftUI

/// Hosts SharedUI's `LargePreviewCard` for the Gallery (filmstrip) browser mode, gating on the
/// iCloud-placeholder state exactly as `InspectorView` does for its own preview card — the
/// preview pipeline must not be asked to load a placeholder. Reads the same model-side preview
/// pipeline the Inspector already uses, so selecting a file anywhere (filmstrip, list, icon grid)
/// keeps this in sync for free.
struct LargePreviewPane: View {
    @ObservedObject var model: AppModel

    /// Matches the filmstrip's own edge insets (`GalleryMetrics.default.gridInsets`) so the big
    /// preview, the filmstrip below it, and the pane's outer edge all share one consistent inset
    /// rather than a second invented margin — mirrors Finder's Gallery View, which doesn't let
    /// the large preview bleed to the pane's edges either.
    private static let padding = GalleryMetrics.default.gridInsets

    var body: some View {
        Group {
            if let url = model.primarySelectionURL, model.cloudStateByURL[url]?.isPlaceholder != true {
                LargePreviewCard(
                    image: model.inspectorPreviewImage(for: url),
                    isLoading: model.isInspectorPreviewLoading(for: url)
                )
                .padding(EdgeInsets(
                    top: Self.padding.top,
                    leading: Self.padding.left,
                    bottom: Self.padding.bottom,
                    trailing: Self.padding.right
                ))
                .task(id: "\(url.path)::\(model.inspectorRefreshRevision)") {
                    model.ensureInspectorPreviewLoaded(for: url)
                }
            } else {
                // No selection and "not downloaded" both already get a full explanation with a
                // Download Now button in the Inspector, right next to this pane — repeating that
                // here (as this used to) reads as a confusing duplicate. Keep this pane's
                // placeholder minimal: a plain glyph, the same size a filmstrip thumbnail would
                // be, in the same secondary shade as the Inspector's own placeholder text —
                // a cloud-download glyph when the file just isn't downloaded yet, a generic
                // image glyph when nothing is selected at all.
                let isPlaceholder = model.primarySelectionURL.flatMap { model.cloudStateByURL[$0]?.isPlaceholder } == true
                Image(systemName: isPlaceholder ? "icloud.and.arrow.down" : "photo")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .frame(width: BrowserFilmstripViewController.rowHeight, height: BrowserFilmstripViewController.rowHeight)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
