import AppKit
import MapKit
import SharedUI
import SwiftUI

private struct InspectorPreviewActionPressedKey: EnvironmentKey {
    static let defaultValue = false
}

private struct InspectorPreviewActionHoveredKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    var inspectorPreviewActionIsPressed: Bool {
        get { self[InspectorPreviewActionPressedKey.self] }
        set { self[InspectorPreviewActionPressedKey.self] = newValue }
    }

    var inspectorPreviewActionIsHovered: Bool {
        get { self[InspectorPreviewActionHoveredKey.self] }
        set { self[InspectorPreviewActionHoveredKey.self] = newValue }
    }
}

private struct InspectorPreviewActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        InspectorPreviewActionButton(configuration: configuration)
    }

    private struct InspectorPreviewActionButton: View {
        let configuration: Configuration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .environment(\.inspectorPreviewActionIsPressed, configuration.isPressed)
                .environment(\.inspectorPreviewActionIsHovered, isHovered)
                .onHover { hovering in
                    isHovered = hovering
                }
        }
    }
}

private struct InspectorPreviewActionLabel: View {
    let symbolName: String
    let title: String
    @Environment(\.inspectorPreviewActionIsPressed) private var isPressed
    @Environment(\.inspectorPreviewActionIsHovered) private var isHovered

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbolName)
                .font(.body)
                .foregroundStyle(isPressed ? Color.primary.opacity(0.7) : (isHovered ? Color.primary : Color.secondary))
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct InspectorView: View {
    @ObservedObject var model: AppModel
    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }()
    @FocusState private var focusedTagID: String?
    @State private var activeEditTagID: String?
    @State private var suppressNextFocusScrollAnimation = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if model.selectedFileURLs.isEmpty {
                    PlaceholderView(
                        symbolName: "slider.horizontal.3",
                        title: "No Selection",
                        description: "Select one or more images to view and edit their metadata."
                    )
                    .frame(maxWidth: .infinity)
                    .containerRelativeFrame(.vertical, alignment: .center)
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                    if model.selectedFileURLs.count == 1,
                       let first = model.selectedFileURLs.first {
                        InspectorHeaderView(
                            title: inspectorTitle(for: first),
                            subtitle: singleSelectionSubtitle,
                            pendingChange: model.pendingRenameByFile[first] != nil
                        )
                    } else {
                        InspectorHeaderView(
                            title: "\(model.selectedFileURLs.count) images selected",
                            subtitle: multiSelectionSubtitle
                        )
                    }

                    InspectorRatingFlagView(
                        rating: Int(model.valueForTag(AppModel.EditableTag.rating).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0,
                        ratingPending: model.hasPendingChange(for: AppModel.EditableTag.rating),
                        ratingEnabled: model.isInspectorFieldEnabled(AppModel.EditableTag.rating.id),
                        onRatingChange: { model.updateValue($0 == 0 ? "" : String($0), for: AppModel.EditableTag.rating) },
                        pick: Int(model.valueForTag(AppModel.EditableTag.pick).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0,
                        pickPending: model.hasPendingChange(for: AppModel.EditableTag.pick),
                        pickEnabled: model.isInspectorFieldEnabled(AppModel.EditableTag.pick.id),
                        onPickChange: { model.updateValue($0 == 0 ? "" : String($0), for: AppModel.EditableTag.pick) },
                        label: model.valueForTag(AppModel.EditableTag.label).trimmingCharacters(in: .whitespacesAndNewlines),
                        labelPending: model.hasPendingChange(for: AppModel.EditableTag.label),
                        labelEnabled: model.isInspectorFieldEnabled(AppModel.EditableTag.label.id),
                        onLabelChange: { model.updateValue($0, for: AppModel.EditableTag.label) }
                    )

                    if model.selectedFileURLs.count == 1 {
                        InspectorSectionContainer(
                            "Preview",
                            isExpanded: sectionExpandedBinding(for: "Preview")
                        ) {
                            if let previewURL = primarySelectedFileURL {
                                VStack(spacing: 10) {
                                    InspectorPreviewCard(
                                        image: model.inspectorPreviewImage(for: previewURL),
                                        isLoading: model.isInspectorPreviewLoading(for: previewURL)
                                    ) {
                                        if model.hasPendingImageEdits(for: previewURL) {
                                            Image(systemName: "circle.fill")
                                                .font(.system(size: 9))
                                                .symbolRenderingMode(.monochrome)
                                                .foregroundStyle(Color(nsColor: .systemOrange))
                                                .padding(8)
                                        }
                                    }
                                    .task(id: "\(previewURL.path)::\(model.inspectorRefreshRevision)") {
                                        model.ensureInspectorPreviewLoaded(for: previewURL)
                                    }

                                    Divider()

                                    HStack(spacing: 0) {
                                        Button {
                                            model.rotateLeft(fileURL: previewURL)
                                        } label: {
                                            InspectorPreviewActionLabel(symbolName: "rotate.left", title: "Rotate")
                                            .frame(maxWidth: .infinity, minHeight: 44)
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(InspectorPreviewActionButtonStyle())

                                        Button {
                                            model.flipHorizontal(fileURL: previewURL)
                                        } label: {
                                            InspectorPreviewActionLabel(symbolName: "flip.horizontal", title: "Flip")
                                            .frame(maxWidth: .infinity, minHeight: 44)
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(InspectorPreviewActionButtonStyle())

                                        Button {
                                            model.openInDefaultApp(previewURL)
                                        } label: {
                                            InspectorPreviewActionLabel(symbolName: "arrow.up.forward.app", title: "Open")
                                            .frame(maxWidth: .infinity, minHeight: 44)
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(InspectorPreviewActionButtonStyle())
                                    }
                                }
                            }
                        }
                    }

                    ForEach(model.orderedEditableTagSections.filter { $0.section != "Rating" }) { grouped in
                        InspectorSectionContainer(
                            grouped.section,
                            isExpanded: sectionExpandedBinding(for: grouped.section)
                        ) {
                            VStack(alignment: .leading, spacing: 10) {
                                    ForEach(grouped.tags) { tag in
                                        InspectorFieldRow {
                                            HStack(spacing: 6) {
                                                if model.hasPendingChange(for: tag) {
                                                    Image(systemName: "circle.fill")
                                                        .font(.system(size: 6))
                                                        .foregroundStyle(.orange)
                                                }
                                                InspectorFieldLabel(tag.label)
                                            }
                                        } value: {
                                            InspectorTagFieldView(
                                                tag: tag,
                                                model: model,
                                                focusedTagID: $focusedTagID,
                                                onBeginEditSession: { beginEditSessionIfNeeded(for: tag) },
                                                onOpenDateTimeAdjust: { openDateTimeAdjustSheet(for: tag) },
                                                onOpenLocationAdjust: { openLocationAdjustSheet() }
                                            )
                                        }
                                        .id(tag.id)
                                    }

                                    if grouped.section == "Location", let coordinate = photoCoordinate {
                                        locationMapView(for: coordinate)
                                    }

                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }


                }
                    .padding(.vertical, 12)
                }
            }
            .inspectorScrollSetup()
            .animation(appAnimation(), value: model.collapsedInspectorSections)
            .onChange(of: focusedTagID) { oldValue, newValue in
                if oldValue != nil {
                    // Focus left a text field — end the undo coalescing window so
                    // the next edit in any field gets its own undo entry.
                    model.endUndoCoalescing()
                }
                guard let newValue else { return }
                guard oldValue != nil else { return }
                DispatchQueue.main.async {
                    if suppressNextFocusScrollAnimation {
                        var transaction = Transaction()
                        transaction.animation = nil
                        withTransaction(transaction) {
                            proxy.scrollTo(newValue)
                        }
                        suppressNextFocusScrollAnimation = false
                    } else {
                        withAnimation(appAnimation()) {
                            proxy.scrollTo(newValue)
                        }
                    }
                }
            }
        }
        .onChange(of: model.selectedFileURLs) { _, _ in
            model.endUndoCoalescing()
            model.clearEditSessionSnapshots()
            activeEditTagID = nil
            suppressNextFocusScrollAnimation = true
            // Defer @FocusState clear: setting it synchronously during the SwiftUI
            // update phase triggers an AppKit first-responder change which calls
            // layout() on the NSHostingView while SwiftUI is still processing the
            // update → NSHostingView reentrant layout fault.
            DispatchQueue.main.async {
                focusedTagID = nil
            }
        }
        .onExitCommand {
            let targetTagID = focusedTagID ?? activeEditTagID
            guard let targetTagID,
                  let snapshot = model.editSessionSnapshot(forTagID: targetTagID)
            else {
                self.focusedTagID = nil
                NotificationCenter.default.post(name: .inspectorDidRequestBrowserFocus, object: nil)
                return
            }

            // Mixed-value text fields can emit a late commit after Esc.
            // Restore twice (now and next runloop) so staged edits are truly cleared.
            model.restoreEditSession(snapshot)
            DispatchQueue.main.async {
                model.restoreEditSession(snapshot)
            }
            model.removeEditSessionSnapshot(forTagID: targetTagID)
            activeEditTagID = nil
            self.focusedTagID = nil
            NotificationCenter.default.post(name: .inspectorDidRequestBrowserFocus, object: nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: .inspectorDidRequestFieldNavigation)) { notification in
            let backward = (notification.userInfo?["backward"] as? Bool) ?? false
            moveInspectorFieldFocus(backward: backward)
        }
        .sheet(item: Binding(
            get: { model.activeWelcomePresentation },
            set: { newValue in
                Task { @MainActor in
                    model.activeWelcomePresentation = newValue
                }
            }
        )) { presentation in
            AppWelcomeSheetView(presentation: presentation)
        }
        .sheet(item: Binding(
            get: { model.activePresetEditor },
            set: { newValue in
                Task { @MainActor in
                    model.activePresetEditor = newValue
                }
            }
        )) { editor in
            PresetEditorSheet(
                model: model,
                initialEditor: editor
            )
        }
        .tint(AppTheme.accentColor)
        .sheet(isPresented: Binding(
            get: { model.isManagePresetsPresented },
            set: { newValue in
                Task { @MainActor in
                    model.isManagePresetsPresented = newValue
                }
            }
        )) {
            PresetManagerSheet(model: model)
        }
        .sheet(item: Binding(
            get: { model.pendingImportSourceKind },
            set: { newValue in
                Task { @MainActor in
                    model.pendingImportSourceKind = newValue
                }
            }
        )) { sourceKind in
            ImportSheetView(model: model, sourceKind: sourceKind)
        }
        .batchRenameSheet(model: model)
        .dateTimeAdjustSheet(model: model)
        .locationAdjustSheet(model: model)
    }

    private var photoCoordinate: CLLocationCoordinate2D? {
        guard let latitude = numericValue(forTagID: "exif-gps-lat"),
              let longitude = numericValue(forTagID: "exif-gps-lon"),
              (-90 ... 90).contains(latitude),
              (-180 ... 180).contains(longitude)
        else {
            return nil
        }

        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    private var primarySelectedFileURL: URL? {
        model.selectedFileURLs.sorted { $0.path < $1.path }.first
    }

    private func inspectorTitle(for fileURL: URL) -> String {
        if let stagedName = model.pendingRenameByFile[fileURL], !stagedName.isEmpty {
            return URL(fileURLWithPath: stagedName).deletingPathExtension().lastPathComponent
        }
        return fileURL.deletingPathExtension().lastPathComponent
    }


    private var singleSelectionSubtitle: String? {
        guard model.selectedFileURLs.count == 1,
              let url = primarySelectedFileURL
        else {
            return nil
        }

        let browserItem = model.browserItems.first(where: { $0.url == url })
        let typeText = browserItem?.kind ?? {
            let ext = url.pathExtension.uppercased()
            return ext.isEmpty ? "Unknown" : ext
        }()
        let sizeText: String = {
            if let size = browserItem?.sizeBytes, size >= 0 {
                return Self.byteCountFormatter.string(fromByteCount: Int64(size))
            }
            return "—"
        }()

        var parts: [String] = [typeText, sizeText]
        if let (width, height) = model.imagePixelDimensions(for: url),
           width > 0, height > 0 {
            parts.append("\(width)×\(height)")
            let megapixels = (Double(width) * Double(height)) / 1_000_000
            parts.append(String(format: "%.1f MP", megapixels))
        }
        return parts.joined(separator: " • ")
    }

    private var multiSelectionSubtitle: String? {
        let selectedItems = model.browserItems.filter { model.selectedFileURLs.contains($0.url) }
        guard !selectedItems.isEmpty else { return nil }

        let selectedCount = selectedItems.count
        let nonEmptyTypes = selectedItems
            .compactMap { $0.kind?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let uniqueTypes = Set(nonEmptyTypes)
        let typeSummary: String = {
            if uniqueTypes.count == 1, let only = uniqueTypes.first {
                return only
            }
            return "Mixed types"
        }()

        let totalSize = selectedItems.reduce(Int64(0)) { partial, item in
            partial + Int64(max(item.sizeBytes ?? 0, 0))
        }
        let totalSizeText = Self.byteCountFormatter.string(fromByteCount: totalSize)

        return "\(typeSummary), \(selectedCount) selected • \(totalSizeText) total"
    }

    private func numericValue(forTagID id: String) -> Double? {
        guard let tag = AppModel.EditableTag.common.first(where: { $0.id == id }) else {
            return nil
        }
        let raw = model.valueForTag(tag).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        return parseCoordinate(raw)
    }

    private func sectionExpandedBinding(for section: String) -> Binding<Bool> {
        Binding(
            get: { !model.isInspectorSectionCollapsed(section) },
            set: { _ in
                model.toggleInspectorSection(section)
            }
        )
    }

    @ViewBuilder
    private func locationMapView(for coordinate: CLLocationCoordinate2D) -> some View {
        SharedUI.InspectorLocationMapView(coordinate: coordinate)
        .frame(height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func parseCoordinate(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let direct = Double(trimmed), direct.isFinite {
            return direct
        }

        let ns = trimmed as NSString
        let regex = try? NSRegularExpression(pattern: "-?\\d+(?:\\.\\d+)?")
        let matches = regex?.matches(in: trimmed, range: NSRange(location: 0, length: ns.length)) ?? []
        guard let firstMatch = matches.first else { return nil }

        let numbers: [Double] = matches.compactMap { Double(ns.substring(with: $0.range)) }
        guard let first = numbers.first else { return nil }

        let hasExplicitNegative = ns.substring(with: firstMatch.range)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix("-")

        let magnitude: Double
        if numbers.count >= 3 {
            let degrees = abs(first)
            let minutes = abs(numbers[1])
            let seconds = abs(numbers[2])
            magnitude = degrees + (minutes / 60) + (seconds / 3600)
        } else {
            magnitude = abs(first)
        }

        let parsed = hasExplicitNegative ? -magnitude : magnitude
        if let direction = coordinateDirection(in: trimmed) {
            switch direction {
            case .south, .west:
                return -abs(parsed)
            case .north, .east:
                return abs(parsed)
            }
        }
        return parsed
    }

    private func moveInspectorFieldFocus(backward: Bool) {
        let focusableTagIDs = focusableInspectorTagIDs()
        guard !focusableTagIDs.isEmpty else { return }
        let current = focusedTagID ?? activeEditTagID
        let nextID: String
        if let current, let currentIndex = focusableTagIDs.firstIndex(of: current) {
            let delta = backward ? -1 : 1
            let nextIndex = (currentIndex + delta + focusableTagIDs.count) % focusableTagIDs.count
            nextID = focusableTagIDs[nextIndex]
        } else {
            nextID = backward ? focusableTagIDs.last! : focusableTagIDs.first!
        }
        guard focusedTagID != nextID else { return }
        focusedTagID = nextID
    }

    private func focusableInspectorTagIDs() -> [String] {
        model.orderedEditableTagSections
            .filter { $0.section != "Rating" && !model.isInspectorSectionCollapsed($0.section) }
            .flatMap(\.tags)
            .filter { tag in
                !model.isDateTimeTag(tag) && model.pickerOptions(for: tag) == nil
            }
            .map(\.id)
    }

    private enum CoordinateDirection {
        case north
        case south
        case east
        case west
    }

    private func coordinateDirection(in raw: String) -> CoordinateDirection? {
        let tokens = raw
            .uppercased()
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
        for token in tokens.reversed() {
            switch token {
            case "N", "NORTH":
                return .north
            case "S", "SOUTH":
                return .south
            case "E", "EAST":
                return .east
            case "W", "WEST":
                return .west
            default:
                continue
            }
        }
        return nil
    }

    private func beginEditSessionIfNeeded(for tag: AppModel.EditableTag) {
        model.beginEditSessionSnapshotIfNeeded(for: tag)
        activeEditTagID = tag.id
    }

    private func openDateTimeAdjustSheet(for tag: AppModel.EditableTag) {
        let targetTag = DateTimeTargetTag.from(editableTagID: tag.id) ?? .dateTimeOriginal
        let scope: DateTimeAdjustScope = model.selectedFileURLs.count > 1 ? .selection : .single
        model.beginDateTimeAdjust(scope: scope, launchTag: targetTag, launchContext: .inspector)
    }

    private func openLocationAdjustSheet() {
        model.beginLocationAdjust()
    }

}
