import AppKit
import MapKit
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
                .foregroundStyle(isPressed ? Color.white : (isHovered ? Color.primary : Color.secondary))
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct InspectorView: View {
    let model: AppModel
    private let topScrollStartInset: CGFloat = 56
    private let contentHorizontalInset: CGFloat = 16
    private let sectionInnerInset: CGFloat = 12
    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }()
    @FocusState private var focusedTagID: String?
    @State private var editSessionSnapshots: [String: AppModel.EditSessionSnapshot] = [:]
    @State private var activeEditTagID: String?
    @State private var suppressNextFocusScrollAnimation = false
    @State private var inspectorRefreshRevision: UInt64 = 0

    var body: some View {
        let _ = inspectorRefreshRevision
        ScrollViewReader { proxy in
            ScrollView {
                if model.selectedFileURLs.isEmpty {
                    ContentUnavailableView(
                        "No Selection",
                        systemImage: "slider.horizontal.3",
                        description: Text("Select one or more images to view and edit their metadata.")
                    )
                    .frame(maxWidth: .infinity)
                    .containerRelativeFrame(.vertical, alignment: .center)
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        if model.selectedFileURLs.count == 1,
                           let first = model.selectedFileURLs.first {
                            Text(first.deletingPathExtension().lastPathComponent)
                                .font(.title3.weight(.semibold))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if let subtitle = singleSelectionSubtitle {
                                Text(subtitle)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        } else {
                            Text("\(model.selectedFileURLs.count) images selected")
                                .font(.title3.weight(.semibold))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            if let subtitle = multiSelectionSubtitle {
                                Text(subtitle)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, contentHorizontalInset)

                    if model.selectedFileURLs.count == 1 {
                        DisclosureGroup(
                            isExpanded: Binding(
                                get: { !model.isInspectorSectionCollapsed("Preview") },
                                set: { _ in
                                    DispatchQueue.main.async {
                                        model.toggleInspectorSection("Preview")
                                    }
                                }
                            )
                        ) {
                            if let previewURL = primarySelectedFileURL {
                                VStack(spacing: 10) {
                                    InspectorPreviewImageView(model: model, fileURL: previewURL)
                                        .frame(maxWidth: .infinity)

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

                                        Divider()
                                            .frame(height: 28)

                                        Button {
                                            model.flipHorizontal(fileURL: previewURL)
                                        } label: {
                                            InspectorPreviewActionLabel(symbolName: "flip.horizontal", title: "Flip")
                                            .frame(maxWidth: .infinity, minHeight: 44)
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(InspectorPreviewActionButtonStyle())

                                        Divider()
                                            .frame(height: 28)

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
                                .padding(sectionInnerInset)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(.quaternary.opacity(0.35))
                                )
                            }
                        } label: {
                            Text(sectionHeaderTitle("Preview"))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.accentColor)
                                .tracking(0.4)
                        }
                        .padding(.horizontal, contentHorizontalInset)
                    }

                    ForEach(model.groupedEditableTags, id: \.section) { grouped in
                        DisclosureGroup(
                            isExpanded: Binding(
                                get: { !model.isInspectorSectionCollapsed(grouped.section) },
                                set: { _ in
                                    DispatchQueue.main.async {
                                        model.toggleInspectorSection(grouped.section)
                                    }
                                }
                            )
                        ) {
                            VStack(alignment: .leading, spacing: 10) {
                                    ForEach(grouped.tags) { tag in
                                        VStack(alignment: .leading, spacing: 4) {
                                            HStack(spacing: 6) {
                                                if model.hasPendingChange(for: tag) {
                                                    Image(systemName: "circle.fill")
                                                        .font(.system(size: 6))
                                                        .foregroundStyle(.orange)
                                                }
                                                Text(tag.label)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                            if model.isDateTimeTag(tag) {
                                                if let date = model.dateValueForTag(tag) {
                                                    HStack(spacing: 6) {
                                                        DatePicker(
                                                            "",
                                                            selection: Binding(
                                                                get: { model.dateValueForTag(tag) ?? date },
                                                                set: {
                                                                    beginEditSessionIfNeeded(for: tag)
                                                                    let newDate = $0
                                                                    DispatchQueue.main.async {
                                                                        model.updateDateValue(newDate, for: tag)
                                                                    }
                                                                }
                                                            ),
                                                            displayedComponents: [.date, .hourAndMinute]
                                                        )
                                                        .labelsHidden()
                                                        .datePickerStyle(.stepperField)

                                                        Spacer()

                                                        Button {
                                                            beginEditSessionIfNeeded(for: tag)
                                                            DispatchQueue.main.async {
                                                                model.clearDateValue(for: tag)
                                                            }
                                                        } label: {
                                                            Image(systemName: "xmark.circle.fill")
                                                                .foregroundStyle(.secondary)
                                                        }
                                                        .buttonStyle(.plain)
                                                        .help("Clear date and time")
                                                    }
                                                } else {
                                                    HStack(spacing: 6) {
                                                        if model.isMixedValue(for: tag) {
                                                            HStack {
                                                                Text("Multiple values")
                                                                    .foregroundStyle(.secondary)
                                                                    .font(.body)
                                                                Spacer(minLength: 0)
                                                            }
                                                            .padding(.horizontal, 10)
                                                            .padding(.vertical, 6)
                                                            .frame(maxWidth: .infinity, alignment: .leading)
                                                            .background(
                                                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                                    .strokeBorder(.quaternary, lineWidth: 1)
                                                            )
                                                        } else {
                                                            TextField("", text: .constant(""))
                                                                .textFieldStyle(.roundedBorder)
                                                                .disabled(true)
                                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                        }

                                                        Button("Set") {
                                                            beginEditSessionIfNeeded(for: tag)
                                                            let now = Date()
                                                            DispatchQueue.main.async {
                                                                model.updateDateValue(now, for: tag)
                                                            }
                                                        }
                                                        .controlSize(.small)
                                                    }
                                                }
                                            } else if let options = model.pickerOptions(for: tag) {
                                                Picker("", selection: Binding(
                                                    get: { model.valueForTag(tag) },
                                                    set: {
                                                        guard $0 != model.valueForTag(tag) else { return }
                                                        beginEditSessionIfNeeded(for: tag)
                                                        let newValue = $0
                                                        DispatchQueue.main.async {
                                                            model.updateValue(newValue, for: tag)
                                                        }
                                                    }
                                                )) {
                                                    // Always include tag("") so SwiftUI never sees an
                                                    // untagged selection when the field has no value.
                                                    Text(model.isMixedValue(for: tag) ? "Multiple values" : "—")
                                                        .tag("")
                                                    let currentValue = model.valueForTag(tag)
                                                    if !currentValue.isEmpty && !options.contains(where: { $0.value == currentValue }) {
                                                        Text(currentValue).tag(currentValue)
                                                    }
                                                    ForEach(options, id: \.value) { option in
                                                        Text(option.label).tag(option.value)
                                                    }
                                                }
                                                .labelsHidden()
                                                .pickerStyle(.menu)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                            } else {
                                                TextField(
                                                    "",
                                                    text: Binding(
                                                        get: { model.valueForTag(tag) },
                                                        set: {
                                                            beginEditSessionIfNeeded(for: tag)
                                                            let newValue = $0
                                                            DispatchQueue.main.async {
                                                                model.updateValue(newValue, for: tag)
                                                            }
                                                        }
                                                    ),
                                                    prompt: Text(model.isMixedValue(for: tag) ? "Multiple values" : model.placeholderForTag(tag))
                                                        .foregroundStyle(.secondary)
                                                )
                                                .textFieldStyle(.roundedBorder)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .focused($focusedTagID, equals: tag.id)
                                            }
                                        }
                                        .id(tag.id)
                                    }

                                    if grouped.section == "Location", let coordinate = photoCoordinate {
                                        locationMapView(for: coordinate)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(sectionInnerInset)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(.quaternary.opacity(0.35))
                                )
                        } label: {
                            Text(sectionHeaderTitle(grouped.section))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.accentColor)
                                .tracking(0.4)
                        }
                        .padding(.horizontal, contentHorizontalInset)
                    }

                    if let lastResult = model.lastResult {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Last Operation")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .tracking(0.4)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Succeeded: \(lastResult.succeeded.count)")
                                Text("Failed: \(lastResult.failed.count)")
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(sectionInnerInset)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(.quaternary.opacity(0.35))
                            )
                        }
                        .padding(.horizontal, contentHorizontalInset)
                    }
                }
                    .padding(.vertical, 12)
                }
            }
            .ignoresSafeArea(.container, edges: .top)
            .contentMargins(.top, topScrollStartInset, for: .scrollContent)
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
            editSessionSnapshots.removeAll()
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
        .onAppear {
            inspectorRefreshRevision = model.inspectorRefreshRevision
        }
        .onReceive(model.$inspectorRefreshRevision.removeDuplicates()) { revision in
            inspectorRefreshRevision = revision
        }
        .onExitCommand {
            let targetTagID = focusedTagID ?? activeEditTagID
            guard let targetTagID,
                  let snapshot = editSessionSnapshots[targetTagID]
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
            editSessionSnapshots.removeValue(forKey: targetTagID)
            activeEditTagID = nil
            self.focusedTagID = nil
            NotificationCenter.default.post(name: .inspectorDidRequestBrowserFocus, object: nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: .inspectorDidRequestFieldNavigation)) { notification in
            let backward = (notification.userInfo?["backward"] as? Bool) ?? false
            moveInspectorFieldFocus(backward: backward)
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

    private func sectionHeaderTitle(_ title: String) -> String {
        title.uppercased()
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

    @ViewBuilder
    private func locationMapView(for coordinate: CLLocationCoordinate2D) -> some View {
        InspectorLocationMapView(coordinate: coordinate)
        .frame(height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func parseCoordinate(_ raw: String) -> Double? {
        let upper = raw.uppercased()
        let hasWestOrSouth = upper.contains("W") || upper.contains("S")
        let hasEastOrNorth = upper.contains("E") || upper.contains("N")

        if let direct = Double(raw) {
            if direct == 0, hasWestOrSouth {
                return -0
            }
            return hasWestOrSouth ? -abs(direct) : direct
        }

        let numberMatches = raw.matches(of: /-?\d+(?:\.\d+)?/).map { Double($0.0) ?? 0 }
        guard let first = numberMatches.first else { return nil }

        let absoluteValue: Double
        if numberMatches.count >= 3 {
            let degrees = abs(first)
            let minutes = abs(numberMatches[1])
            let seconds = abs(numberMatches[2])
            absoluteValue = degrees + (minutes / 60) + (seconds / 3600)
        } else {
            absoluteValue = abs(first)
        }

        let hasExplicitNegative = first < 0
        let signed = hasExplicitNegative || hasWestOrSouth
            ? -absoluteValue
            : absoluteValue

        if hasEastOrNorth, signed == -0 {
            return 0
        }
        return signed
    }

    private func beginEditSessionIfNeeded(for tag: AppModel.EditableTag) {
        if editSessionSnapshots[tag.id] == nil {
            editSessionSnapshots[tag.id] = model.makeEditSessionSnapshot(for: tag)
        }
        activeEditTagID = tag.id
    }

    private func moveInspectorFieldFocus(backward: Bool) {
        let focusableTagIDs = focusableInspectorTagIDs()

        guard !focusableTagIDs.isEmpty else { return }

        let current = focusedTagID ?? activeEditTagID
        let nextID: String

        if let current,
           let currentIndex = focusableTagIDs.firstIndex(of: current) {
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
        model.groupedEditableTags
            .filter { !model.isInspectorSectionCollapsed($0.section) }
            .flatMap(\.tags)
            .filter { tag in
                !model.isDateTimeTag(tag) && model.pickerOptions(for: tag) == nil
            }
            .map(\.id)
    }
}


private struct InspectorPreviewImageView: View {
    @ObservedObject var model: AppModel
    let fileURL: URL

    var body: some View {
        ZStack {
            if let image = model.inspectorPreviewImage(for: fileURL) {
                // Overlay the dot on the Image itself so it anchors to the actual
                // rendered image bounds (which match the aspect-ratio-scaled size),
                // not the fixed 220 pt container — keeping it inside for both
                // portrait and landscape images.
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        if model.hasPendingImageEdits(for: fileURL) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.orange)
                                .padding(8)
                        }
                    }
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.quaternary.opacity(0.22))
            }
        }
        .frame(height: 220)
        .overlay {
            if model.isInspectorPreviewLoading(for: fileURL) {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .task(id: previewTaskID) {
            model.ensureInspectorPreviewLoaded(for: fileURL)
        }
    }

    private var previewTaskID: String {
        "\(fileURL.path)::\(model.inspectorRefreshRevision)"
    }
}


// Renders a static map snapshot via MKMapSnapshotter — no live MKMapView display link.
private struct InspectorLocationMapView: View {
    let coordinate: CLLocationCoordinate2D
    @State private var snapshotImage: NSImage?

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let image = snapshotImage {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .clipped()
                } else {
                    Color(nsColor: .windowBackgroundColor)
                }
            }
            .task(id: taskKey(geometry.size)) {
                snapshotImage = await makeSnapshot(size: geometry.size)
            }
        }
    }

    private func taskKey(_ size: CGSize) -> String {
        "\(coordinate.latitude),\(coordinate.longitude),\(Int(size.width)),\(Int(size.height))"
    }

    @MainActor
    private func makeSnapshot(size: CGSize) async -> NSImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.004, longitudeDelta: 0.004)
        )
        options.size = size
        guard let snapshot = try? await MKMapSnapshotter(options: options).start() else { return nil }

        // Composite a pin onto the snapshot image.
        // lockFocusFlipped(true) gives a top-left origin / y-down coordinate space,
        // which matches the coordinate space of snapshot.point(for:).
        let baseImage = snapshot.image
        let result = NSImage(size: baseImage.size)
        result.lockFocusFlipped(true)
        baseImage.draw(in: NSRect(origin: .zero, size: baseImage.size))
        let pinPoint = snapshot.point(for: coordinate)
        let pinSize: CGFloat = 22
        if let pin = NSImage(systemSymbolName: "mappin.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [.white, .systemRed])) {
            pin.draw(in: NSRect(
                x: pinPoint.x - pinSize / 2,
                y: pinPoint.y - pinSize / 2,
                width: pinSize,
                height: pinSize
            ))
        }
        result.unlockFocus()
        return result
    }
}
