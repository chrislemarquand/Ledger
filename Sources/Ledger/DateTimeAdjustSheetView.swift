import AppKit
import MapKit
import SharedUI
import SwiftUI

struct DateTimeAdjustSheetView: View {
    private enum OffsetFieldID: Hashable {
        case days
        case hours
        case minutes
        case seconds
    }

    private enum DataAdjustedDisplay: Equatable {
        case blank
        case single(Date)
        case multipleValues
    }

    @ObservedObject var model: AppModel
    @State private var session: DateTimeAdjustSession

    @State private var showPreview = false
    @State private var previewRows: [DateTimeAdjustPreviewRow] = []
    @State private var previewBlockingIssues: [String] = []
    @State private var previewWarnings: [String] = []
    @State private var hasEffectivePreviewChanges = false
    @State private var isLoadingPreview = false
    @State private var hasUserEditedSpecificDate = false
    @State private var hoveredOffsetField: OffsetFieldID?
    @FocusState private var focusedOffsetField: OffsetFieldID?

    private static let sheetWidth: CGFloat = 620
    private static let sectionSpacing = WorkflowSheetSectionSpacing.uniform(20)
    private static let modeOrder: [DateTimeAdjustMode] = [.shift, .timeZone, .specific, .file]
    private static let labelColumnWidth: CGFloat = 132
    private static let formRowSpacing: CGFloat = 10
    private static let knownTimeZones: [String] = TimeZone.knownTimeZoneIdentifiers
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    private static let sourceTimeZoneOptions: [String] =
        [DateTimeAdjustSession.cameraClockDisplayName] + knownTimeZones
    private static let targetTimeZoneOptions: [String] = {
        Array(Set(TimeZoneCityData.cities.map(\.city) + knownTimeZones))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }()

    init(model: AppModel, initialSession: DateTimeAdjustSession) {
        self.model = model
        _session = State(initialValue: initialSession)
    }

    private var fileCount: Int { session.fileURLs.count }

    private var representativeOriginalDate: Date? {
        guard let first = session.fileURLs.first else { return nil }
        return session.capturedDates[first]?[session.launchTag]
    }

    private var computedAdjustedDate: Date? {
        guard let first = session.fileURLs.first else { return nil }
        return model.computeAdjustedDate(for: first, session: session)
    }

    private var representativeDataOriginalDisplay: DataAdjustedDisplay {
        guard session.mode == .file,
              let representativeFile = session.fileURLs.first else {
            return .blank
        }

        let fileState = model.dataModeFileState(for: representativeFile, session: session)
        guard fileState.hasWritableDestination else { return .blank }

        let baseline = fileState.destinations.first?.currentValue
        if fileState.destinations.dropFirst().contains(where: { !optionalDatesEqual($0.currentValue, baseline) }) {
            return .multipleValues
        }
        if let currentValue = baseline {
            return .single(currentValue)
        }
        return .blank
    }

    private var representativeDataAdjustedDisplay: DataAdjustedDisplay {
        guard session.mode == .file,
              let representativeFile = session.fileURLs.first else {
            return .blank
        }

        let fileState = model.dataModeFileState(for: representativeFile, session: session)
        guard fileState.hasWritableDestination else { return .blank }
        guard let sourceValue = fileState.readValue else {
            return .blank
        }

        return .single(sourceValue)
    }

    private var hasBlockingIssues: Bool {
        !previewBlockingIssues.isEmpty
    }

    private var isPreviewActionEnabled: Bool {
        !isLoadingPreview && hasEffectivePreviewChanges
    }

    private var isAdjustActionEnabled: Bool {
        !isLoadingPreview && hasEffectivePreviewChanges && !hasBlockingIssues
    }

    // MARK: - Preview Key

    private var previewKey: String {
        let parts: [String] = [
            session.mode.rawValue,
            session.sourceTimeZoneID,
            "\(session.cameraClockOffsetSeconds)",
            session.targetTimeZoneID,
            session.targetTimeZoneInput,
            "\(session.shiftDays)",
            "\(session.shiftHours)",
            "\(session.shiftMinutes)",
            "\(session.shiftSeconds)",
            session.dataReadSource.rawValue,
            "\(session.specificDate.timeIntervalSince1970)",
            session.applyTo.map(\.rawValue).sorted().joined(separator: ","),
        ]
        return parts.joined(separator: "|")
    }

    // MARK: - Body

    var body: some View {
        WorkflowSheetContainer(
            title: "Adjust Date and Time",
            subtitle: session.mode.subtitle(fileCount: fileCount),
            width: Self.sheetWidth,
            sectionSpacing: Self.sectionSpacing
        ) {
            VStack(alignment: .leading, spacing: 0) {
                // Mode segmented control
                Picker("Mode", selection: $session.mode) {
                    ForEach(Self.modeOrder) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, Self.sectionSpacing.topToMain)

                VStack(alignment: .leading, spacing: Self.formRowSpacing) {
                    // Original row
                    WorkflowFormRow("Original:", labelWidth: Self.labelColumnWidth) {
                        if session.mode == .file {
                            switch representativeDataOriginalDisplay {
                            case .blank:
                                readOnlyDateField(
                                    nil,
                                    accessibilityLabel: "Original date and time"
                                )
                            case let .single(date):
                                readOnlyDateField(
                                    date,
                                    accessibilityLabel: "Original date and time"
                                )
                            case .multipleValues:
                                readOnlyTextField(
                                    "Multiple values",
                                    accessibilityLabel: "Original date and time"
                                )
                            }
                        } else {
                            readOnlyDateField(
                                representativeOriginalDate,
                                accessibilityLabel: "Original date and time"
                            )
                        }
                    }

                    // Adjusted row
                    WorkflowFormRow("Adjusted:", labelWidth: Self.labelColumnWidth) {
                        if session.mode == .specific {
                            InspectorDatePickerField(
                                selection: specificDateBinding,
                                datePickerElements: [.yearMonthDay, .hourMinuteSecond],
                                accessibilityLabel: "Adjusted date and time"
                            )
                        } else if session.mode == .shift {
                            if computedAdjustedDate != nil {
                                InspectorDatePickerField(
                                    selection: shiftAdjustedBinding,
                                    datePickerElements: [.yearMonthDay, .hourMinuteSecond],
                                    accessibilityLabel: "Adjusted date and time"
                                )
                            } else {
                                readOnlyDateField(
                                    nil,
                                    accessibilityLabel: "Adjusted date and time"
                                )
                            }
                        } else if session.mode == .file {
                            switch representativeDataAdjustedDisplay {
                            case .blank:
                                readOnlyDateField(
                                    nil,
                                    accessibilityLabel: "Adjusted date and time"
                                )
                            case let .single(date):
                                readOnlyDateField(
                                    date,
                                    accessibilityLabel: "Adjusted date and time"
                                )
                            case .multipleValues:
                                readOnlyTextField(
                                    "Multiple values",
                                    accessibilityLabel: "Adjusted date and time"
                                )
                            }
                        } else {
                            readOnlyDateField(
                                computedAdjustedDate,
                                accessibilityLabel: "Adjusted date and time"
                            )
                        }
                    }

                    // Mode-specific controls
                    modeSpecificControls

                    // Apply to
                    WorkflowFormRow("Apply to:", labelWidth: Self.labelColumnWidth) {
                        HStack(spacing: 16) {
                            ForEach(DateTimeTargetTag.allCases) { tag in
                                Toggle(tag.displayName, isOn: applyToBinding(for: tag))
                                    .toggleStyle(.checkbox)
                                    .disabled(isApplyToTagDisabled(tag))
                            }
                        }
                    }
                }
                .padding(.bottom, Self.sectionSpacing.mainToFooter)

                // Footer
                HStack {
                    Button("Preview\u{2026}") {
                        if previewRows.isEmpty && !isLoadingPreview {
                            Task { await refreshPreview() }
                        }
                        showPreview = true
                    }
                    .disabled(!isPreviewActionEnabled)
                    .popover(isPresented: $showPreview) {
                        previewPopover
                    }

                    Spacer()

                    Button("Cancel") {
                        model.dismissDateTimeAdjustSheet()
                    }
                    .keyboardShortcut(.cancelAction)

                    Button("Adjust") {
                        model.stageDateTimeAdjustments(session: session)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isAdjustActionEnabled)
                }
            }
        }
        .task(id: previewKey) {
            enforceDataModeApplyToRules()
            hydrateCapturedDatesFromModel()
            await refreshPreview()
        }
        .onReceive(model.$metadataByFile) { _ in
            enforceDataModeApplyToRules()
            hydrateCapturedDatesFromModel()
        }
        .onChange(of: session.mode) { _, _ in
            enforceDataModeApplyToRules()
        }
        .onChange(of: session.dataReadSource) { _, _ in
            enforceDataModeApplyToRules()
        }
    }

    // MARK: - Mode-Specific Controls

    @ViewBuilder
    private var modeSpecificControls: some View {
        switch session.mode {
        case .timeZone:
            WorkflowFormRow("Original Time Zone:", labelWidth: Self.labelColumnWidth) {
                WorkflowCityComboField(
                    value: sourceTimeZoneFieldBinding,
                    items: Self.sourceTimeZoneOptions,
                    placeholder: DateTimeAdjustSession.cameraClockDisplayName
                )
            }
            WorkflowFormRow("New Time Zone:", labelWidth: Self.labelColumnWidth) {
                WorkflowCityComboField(
                    value: targetTimeZoneFieldBinding,
                    items: Self.targetTimeZoneOptions,
                    placeholder: "Type city or time zone"
                )
            }
        case .shift:
            WorkflowFormRow("Offset:", labelWidth: Self.labelColumnWidth) {
                HStack(spacing: 8) {
                    offsetField(value: $session.shiftDays, label: "Days", id: .days)
                    offsetField(value: $session.shiftHours, label: "Hours", id: .hours)
                    offsetField(value: $session.shiftMinutes, label: "Mins", id: .minutes)
                    offsetField(value: $session.shiftSeconds, label: "Secs", id: .seconds)
                }
            }
        case .file:
            WorkflowFormRow("Read from:", labelWidth: Self.labelColumnWidth) {
                WorkflowInlineRadioGroup(
                    selectionID: dataReadSourceSelectionIDBinding,
                    options: dataReadSourceRadioOptions
                )
            }
        case .specific:
            EmptyView()
        }
    }

    private var shiftAdjustedBinding: Binding<Date> {
        Binding(
            get: {
                computedAdjustedDate
                ?? representativeOriginalDate
                ?? session.specificDate
            },
            set: { newAdjustedDate in
                applyShiftFromEditedAdjustedDate(newAdjustedDate)
            }
        )
    }

    private var specificDateBinding: Binding<Date> {
        Binding(
            get: { session.specificDate },
            set: { newValue in
                hasUserEditedSpecificDate = true
                session.specificDate = newValue
            }
        )
    }

    private var sourceTimeZoneFieldBinding: Binding<String> {
        Binding(
            get: {
                session.sourceUsesCameraClock
                    ? DateTimeAdjustSession.cameraClockDisplayName
                    : session.sourceTimeZoneID
            },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty
                    || trimmed.caseInsensitiveCompare(DateTimeAdjustSession.cameraClockDisplayName) == .orderedSame {
                    session.sourceTimeZoneID = DateTimeAdjustSession.cameraClockIdentifier
                } else {
                    session.sourceTimeZoneID = trimmed
                }
            }
        )
    }

    private var targetTimeZoneFieldBinding: Binding<String> {
        Binding(
            get: { session.targetTimeZoneInput },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    session.targetTimeZoneInput = ""
                    session.targetTimeZoneID = ""
                    return
                }
                if let normalized = model.normalizeTargetTimeZoneEntry(trimmed) {
                    session.targetTimeZoneID = normalized.identifier
                    session.targetTimeZoneInput = normalized.display
                } else {
                    session.targetTimeZoneID = ""
                    session.targetTimeZoneInput = trimmed
                }
            }
        )
    }

    private func applyShiftFromEditedAdjustedDate(_ adjustedDate: Date) {
        guard let first = session.fileURLs.first,
              let original = session.capturedDates[first]?[session.launchTag] ?? model.originalDate(for: first, tag: session.launchTag) else {
            return
        }
        let components = Calendar.current.dateComponents([.day, .hour, .minute, .second], from: original, to: adjustedDate)
        session.shiftDays = components.day ?? 0
        session.shiftHours = components.hour ?? 0
        session.shiftMinutes = components.minute ?? 0
        session.shiftSeconds = components.second ?? 0
    }

    @ViewBuilder
    private func readOnlyDateField(_ date: Date?, accessibilityLabel: String) -> some View {
        if let date {
            InspectorDatePickerField(
                selection: .constant(date),
                isEnabled: false,
                datePickerElements: [.yearMonthDay, .hourMinuteSecond],
                datePickerStyle: .textField,
                accessibilityLabel: accessibilityLabel
            )
        } else {
            Text("—")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(accessibilityLabel)
        }
    }

    private func readOnlyTextField(_ text: String, accessibilityLabel: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(accessibilityLabel)
    }

    private func optionalDatesEqual(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case let (left?, right?):
            return abs(left.timeIntervalSince(right)) < 1
        case (nil, nil):
            return true
        default:
            return false
        }
    }

    private func hydrateCapturedDatesFromModel() {
        var didAddDate = false
        for fileURL in session.fileURLs {
            var tagDates: [DateTimeTargetTag: Date] = session.capturedDates[fileURL] ?? [:]
            for tag in DateTimeTargetTag.allCases where tagDates[tag] == nil {
                if let date = model.originalDate(for: fileURL, tag: tag) {
                    tagDates[tag] = date
                    didAddDate = true
                }
            }
            session.capturedDates[fileURL] = tagDates.isEmpty ? nil : tagDates
        }

        if !hasUserEditedSpecificDate,
           let first = session.fileURLs.first,
           let firstDate = session.capturedDates[first]?[session.launchTag] {
            session.specificDate = firstDate
        }

        guard didAddDate else { return }
        if showPreview || !previewRows.isEmpty {
            Task { await refreshPreview() }
        }
    }

    // MARK: - Offset Field

    private func offsetField(value: Binding<Int>, label: String, id: OffsetFieldID) -> some View {
        let stepperVisible = focusedOffsetField == id || hoveredOffsetField == id
        return HStack(spacing: 2) {
            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 48)
                .multilineTextAlignment(.trailing)
                .focused($focusedOffsetField, equals: id)
            Stepper(label, value: value)
                .labelsHidden()
                .opacity(stepperVisible ? 1 : 0)
                .allowsHitTesting(stepperVisible)
                .accessibilityHidden(!stepperVisible)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onHover { isHovered in
            if isHovered {
                hoveredOffsetField = id
            } else if hoveredOffsetField == id {
                hoveredOffsetField = nil
            }
        }
    }

    // MARK: - Preview Popover

    @ViewBuilder
    private var previewPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isLoadingPreview {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 80)
                    .padding()
            } else if !previewBlockingIssues.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(previewBlockingIssues.prefix(4).enumerated()), id: \.offset) { _, issue in
                        Text(issue)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                    ForEach(Array(previewWarnings.prefix(4).enumerated()), id: \.offset) { _, warning in
                        Text(warning)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
                .padding()
            } else if previewRows.isEmpty {
                Text("No files in scope.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .padding()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if !previewWarnings.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(previewWarnings.prefix(4).enumerated()), id: \.offset) { _, warning in
                                    Text(warning)
                                        .foregroundStyle(.secondary)
                                        .font(.caption)
                                }
                            }
                        }

                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(previewRows) { row in
                                HStack(spacing: 6) {
                                    Text(row.fileName)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 160, alignment: .leading)
                                    Text(row.originalDisplay)
                                        .foregroundStyle(.secondary)
                                    Image(systemName: "arrow.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                    Text(row.adjustedDisplay)
                                    Text(row.deltaText)
                                        .foregroundStyle(.tertiary)
                                    if !row.warnings.isEmpty {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundStyle(.yellow)
                                            .help(row.warnings.joined(separator: "\n"))
                                    }
                                }
                                .font(.caption)
                                .padding(.vertical, 2)
                            }
                        }
                    }
                    .padding()
                }
                .frame(width: 540, height: 320)
            }
        }
    }

    private func applyToBinding(for tag: DateTimeTargetTag) -> Binding<Bool> {
        Binding(
            get: { session.applyTo.contains(tag) },
            set: { isOn in
                if isOn {
                    guard !isApplyToTagDisabled(tag) else { return }
                    session.applyTo.insert(tag)
                } else {
                    session.applyTo.remove(tag)
                }
            }
        )
    }

    private var dataReadSourceSelectionIDBinding: Binding<String> {
        Binding(
            get: { session.dataReadSource.rawValue },
            set: { rawValue in
                guard let source = DateTimeDataReadSource(rawValue: rawValue),
                      isReadSourceAvailable(source) else {
                    return
                }
                session.dataReadSource = source
            }
        )
    }

    private var dataReadSourceRadioOptions: [WorkflowInlineRadioGroup.Option] {
        DateTimeDataReadSource.allCases.map { source in
            WorkflowInlineRadioGroup.Option(
                id: source.rawValue,
                title: source.displayName,
                isEnabled: isReadSourceAvailable(source)
            )
        }
    }

    private func isReadSourceAvailable(_ source: DateTimeDataReadSource) -> Bool {
        guard let first = session.fileURLs.first else { return false }
        return model.isDataReadSourceAvailable(source, for: first)
    }

    private func isApplyToTagDisabled(_ tag: DateTimeTargetTag) -> Bool {
        guard session.mode == .file,
              let sourceTag = session.dataReadSource.sourceTag else {
            return false
        }
        return sourceTag == tag
    }

    private func enforceDataModeApplyToRules() {
        guard session.mode == .file,
              let sourceTag = session.dataReadSource.sourceTag else {
            return
        }
        session.applyTo.remove(sourceTag)
    }

    private func refreshPreview() async {
        isLoadingPreview = true
        let assessment = model.previewDateTimeAdjust(session: session)
        previewRows = assessment.rows
        previewBlockingIssues = assessment.blockingIssues
        previewWarnings = assessment.warnings
        hasEffectivePreviewChanges = assessment.effectiveChangeFileCount > 0
        isLoadingPreview = false
    }
}

private struct WorkflowInlineRadioGroup: NSViewRepresentable {
    struct Option: Equatable {
        let id: String
        let title: String
        let isEnabled: Bool
    }

    @Binding var selectionID: String
    let options: [Option]

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> ContainerView {
        let view = ContainerView()
        view.rebuildButtons(options: options, coordinator: context.coordinator)
        context.coordinator.lastOptionLayout = options.map { "\($0.id)|\($0.title)" }
        return view
    }

    func updateNSView(_ nsView: ContainerView, context: Context) {
        context.coordinator.parent = self

        let optionLayout = options.map { "\($0.id)|\($0.title)" }
        if context.coordinator.lastOptionLayout != optionLayout {
            nsView.rebuildButtons(options: options, coordinator: context.coordinator)
            context.coordinator.lastOptionLayout = optionLayout
        }

        context.coordinator.isProgrammaticUpdate = true
        for button in nsView.buttons {
            guard let id = button.identifier?.rawValue,
                  let option = options.first(where: { $0.id == id }) else { continue }
            button.state = id == selectionID ? .on : .off
            button.isEnabled = option.isEnabled
        }
        context.coordinator.isProgrammaticUpdate = false
    }

    final class Coordinator: NSObject {
        fileprivate var parent: WorkflowInlineRadioGroup
        fileprivate var isProgrammaticUpdate = false
        fileprivate var lastOptionLayout: [String] = []

        fileprivate init(parent: WorkflowInlineRadioGroup) {
            self.parent = parent
        }

        @MainActor @objc fileprivate func didSelect(_ sender: NSButton) {
            guard !isProgrammaticUpdate,
                  let id = sender.identifier?.rawValue else {
                return
            }
            parent.selectionID = id
        }
    }

    final class ContainerView: NSView {
        let stack: NSStackView
        var buttons: [NSButton] = []

        override init(frame frameRect: NSRect) {
            stack = NSStackView()
            super.init(frame: frameRect)
            translatesAutoresizingMaskIntoConstraints = false

            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 14
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)

            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: leadingAnchor),
                stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
                stack.topAnchor.constraint(equalTo: topAnchor),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func rebuildButtons(options: [Option], coordinator: Coordinator) {
            buttons.forEach { button in
                stack.removeArrangedSubview(button)
                button.removeFromSuperview()
            }
            buttons.removeAll(keepingCapacity: true)

            for option in options {
                let button = NSButton(
                    radioButtonWithTitle: option.title,
                    target: coordinator,
                    action: #selector(Coordinator.didSelect(_:))
                )
                button.identifier = NSUserInterfaceItemIdentifier(option.id)
                button.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(button)
                buttons.append(button)
            }
        }

        override var intrinsicContentSize: NSSize {
            stack.fittingSize
        }
    }
}

// MARK: - View Modifier

extension View {
    func dateTimeAdjustSheet(model: AppModel) -> some View {
        self.sheet(item: Binding(
            get: { model.pendingDateTimeAdjustSession },
            set: { newValue in
                Task { @MainActor in
                    model.pendingDateTimeAdjustSession = newValue
                }
            }
        )) { session in
            DateTimeAdjustSheetView(model: model, initialSession: session)
        }
    }
}

struct LocationAdjustSheetView: View {
    @ObservedObject var model: AppModel
    @State private var session: LocationAdjustSession

    @State private var mapRegion: MKCoordinateRegion
    @State private var hasExplicitCoordinate: Bool

    @State private var showFields = false
    @State private var showPreview = false
    @State private var previewRows: [LocationAdjustPreviewRow] = []
    @State private var previewBlockingIssues: [String] = []
    @State private var previewWarnings: [String] = []
    @State private var hasEffectivePreviewChanges = false
    @State private var isLoadingPreview = false
    @State private var isSearching = false
    @State private var searchMessage: String?
    @State private var reverseGeocodeTask: Task<Void, Never>?

    private static let sheetWidth: CGFloat = 620
    private static let sectionSpacing = WorkflowSheetSectionSpacing.uniform(20)
    private static let searchToMapSpacing: CGFloat = 20
    private static let mapToCoordinatesSpacing: CGFloat = 20
    private static let coordinatesToFooterSpacing: CGFloat = 20
    private static let defaultMapCenter = CLLocationCoordinate2D(latitude: 51.5074, longitude: -0.1278)

    init(model: AppModel, initialSession: LocationAdjustSession) {
        self.model = model
        _session = State(initialValue: initialSession)

        let center = if let latitude = initialSession.latitude,
                        let longitude = initialSession.longitude,
                        (-90 ... 90).contains(latitude),
                        (-180 ... 180).contains(longitude) {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        } else {
            Self.defaultMapCenter
        }
        _mapRegion = State(
            initialValue: MKCoordinateRegion(
                center: center,
                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
            )
        )
        _hasExplicitCoordinate = State(
            initialValue: initialSession.latitude != nil && initialSession.longitude != nil
        )
    }

    private var fileCount: Int { session.fileURLs.count }

    private var subtitle: String {
        let noun = fileCount == 1 ? "1 selected file" : "\(fileCount) selected files"
        return "Changing \(noun) to a new location"
    }

    private var visiblePreviewItems: [(label: String, value: String)] {
        var items: [(String, String)] = []
        if session.includeCoordinates, let coord = selectedCoordinate {
            items.append(("Latitude", AppModel.compactDecimalString(coord.latitude)))
            items.append(("Longitude", AppModel.compactDecimalString(coord.longitude)))
        }
        for field in LocationAdvancedField.allCases {
            guard session.selectedAdvancedFields.contains(field) else { continue }
            let value = session.resolvedValue(for: field)
            guard !value.isEmpty else { continue }
            items.append((field.label, value))
        }
        return items
    }

    private var selectedCoordinate: CLLocationCoordinate2D? {
        guard let latitude = session.latitude,
              let longitude = session.longitude,
              (-90 ... 90).contains(latitude),
              (-180 ... 180).contains(longitude)
        else {
            return nil
        }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    private var hasBlockingIssues: Bool {
        !previewBlockingIssues.isEmpty || selectedCoordinate == nil
    }

    private var availableAdvancedFields: [LocationAdvancedField] {
        model.enabledLocationAdvancedFields()
    }

    private var isAdvancedActionEnabled: Bool {
        !availableAdvancedFields.isEmpty
    }

    private var isPreviewActionEnabled: Bool {
        !isLoadingPreview && hasEffectivePreviewChanges
    }

    private var isApplyActionEnabled: Bool {
        !isLoadingPreview && hasEffectivePreviewChanges && !hasBlockingIssues
    }

    private var previewKey: String {
        [
            "\(session.latitude ?? 0)",
            "\(session.longitude ?? 0)",
            "\(session.includeCoordinates)",
            "\(session.fileURLs.count)",
            session.selectedAdvancedFields
                .map(\.rawValue)
                .sorted()
                .joined(separator: ","),
            session.resolvedSublocation,
            session.resolvedCity,
            session.resolvedStateProvince,
            session.resolvedCountry,
            session.resolvedCountryCode,
        ].joined(separator: "|")
    }

    private var advancedAvailabilityKey: String {
        availableAdvancedFields
            .map(\.rawValue)
            .sorted()
            .joined(separator: ",")
    }

    private var coordinateBinding: Binding<CLLocationCoordinate2D?> {
        Binding(
            get: { selectedCoordinate },
            set: { newCoordinate in
                session.latitude = newCoordinate?.latitude
                session.longitude = newCoordinate?.longitude
                if let newCoordinate {
                    mapRegion.center = newCoordinate
                }
            }
        )
    }

    var body: some View {
        WorkflowSheetContainer(
            title: "Set Location",
            subtitle: subtitle,
            width: Self.sheetWidth,
            sectionSpacing: Self.sectionSpacing
        ) {
            VStack(alignment: .leading, spacing: 0) {
                // Block 1 (title/subtitle) is provided by WorkflowSheetContainer.
                // Block 2: Search
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        TextField("Find a place or address", text: $session.searchQuery)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                Task { await applySearchQuery() }
                            }
                        Button("Find") {
                            Task { await applySearchQuery() }
                        }
                        .disabled(session.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)
                    }

                    if let searchMessage, !searchMessage.isEmpty {
                        Text(searchMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, Self.searchToMapSpacing)

                // Block 3: Map
                WorkflowLocationMapField(
                    region: $mapRegion,
                    coordinate: coordinateBinding,
                    onCoordinateCommit: { coordinate in
                        hasExplicitCoordinate = true
                        scheduleReverseGeocode(for: coordinate)
                    }
                )
                .frame(height: 260)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.bottom, Self.mapToCoordinatesSpacing)

                // Block 4: Selected fields preview
                if !visiblePreviewItems.isEmpty {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                        ForEach(Array(visiblePreviewItems.enumerated()), id: \.offset) { _, item in
                            infoCell(label: item.label, value: item.value)
                        }
                    }
                    .padding(.bottom, Self.coordinatesToFooterSpacing)
                }

                // Block 5: Footer buttons
                HStack {
                    Button("Fields\u{2026}") {
                        showFields = true
                    }
                    .disabled(!isAdvancedActionEnabled)
                    .popover(isPresented: $showFields) {
                        fieldsPopover
                    }

                    Button("Preview\u{2026}") {
                        if previewRows.isEmpty && !isLoadingPreview {
                            Task { await refreshPreview() }
                        }
                        showPreview = true
                    }
                    .disabled(!isPreviewActionEnabled)
                    .popover(isPresented: $showPreview) {
                        previewPopover
                    }

                    Spacer()

                    Button("Cancel") {
                        model.dismissLocationAdjustSheet()
                    }
                    .keyboardShortcut(.cancelAction)

                    Button("Adjust") {
                        model.stageLocationAdjustments(session: session)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isApplyActionEnabled)
                }
            }
        }
        .task {
            sanitizeAdvancedSelection()
            if hasExplicitCoordinate, let coordinate = selectedCoordinate {
                scheduleReverseGeocode(for: coordinate)
            }
        }
        .task(id: previewKey) {
            await refreshPreview()
        }
        .onChange(of: advancedAvailabilityKey) { _, _ in
            sanitizeAdvancedSelection()
        }
        .onChange(of: session.selectedAdvancedFields) { _, newFields in
            guard !newFields.isEmpty, hasExplicitCoordinate, let coordinate = selectedCoordinate else { return }
            scheduleReverseGeocode(for: coordinate)
        }
        .onDisappear {
            reverseGeocodeTask?.cancel()
        }
    }

    @ViewBuilder
    private func infoCell(label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text("\(label):")
                .font(.callout)
            Text(value)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var fieldsPopover: some View {
        let coordinatesEnabled = selectedCoordinate != nil
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose Fields")
                .font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Latitude", isOn: $session.includeCoordinates)
                        .toggleStyle(.checkbox)
                        .disabled(!coordinatesEnabled)
                    Toggle("Longitude", isOn: $session.includeCoordinates)
                        .toggleStyle(.checkbox)
                        .disabled(!coordinatesEnabled)
                    ForEach(availableAdvancedFields) { field in
                        Toggle(field.label, isOn: bindingForAdvancedField(field))
                            .toggleStyle(.checkbox)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 300)
            HStack {
                Spacer()
                Button("Apply") {
                    model.saveLocationFieldSelection(from: session)
                    showFields = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(session.includeCoordinates == false && session.selectedAdvancedFields.isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 240)
    }

    @ViewBuilder
    private var previewPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isLoadingPreview {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 80)
                    .padding()
            } else if !previewBlockingIssues.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(previewBlockingIssues.prefix(4).enumerated()), id: \.offset) { _, issue in
                        Text(issue)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                    ForEach(Array(previewWarnings.prefix(4).enumerated()), id: \.offset) { _, warning in
                        Text(warning)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
                .padding()
            } else if previewRows.isEmpty {
                Text("No files in scope.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .padding()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if !previewWarnings.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(previewWarnings.prefix(4).enumerated()), id: \.offset) { _, warning in
                                    Text(warning)
                                        .foregroundStyle(.secondary)
                                        .font(.caption)
                                }
                            }
                        }

                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(previewRows) { row in
                                HStack(spacing: 6) {
                                    Text(row.fileName)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 160, alignment: .leading)
                                    Text(row.originalDisplay)
                                        .foregroundStyle(.secondary)
                                    Image(systemName: "arrow.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                    Text(row.adjustedDisplay)
                                    Text(row.deltaText)
                                        .foregroundStyle(.tertiary)
                                }
                                .font(.caption)
                                .padding(.vertical, 2)
                            }
                        }
                    }
                    .padding()
                }
                .frame(width: 540, height: 320)
            }
        }
    }

    private func applySearchQuery() async {
        let query = session.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        isSearching = true
        searchMessage = nil
        defer { isSearching = false }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.address, .pointOfInterest]

        do {
            let response = try await MKLocalSearch(request: request).start()
            guard let first = response.mapItems.first else {
                searchMessage = "No search results."
                return
            }
            let coordinate = first.location.coordinate
            hasExplicitCoordinate = true
            session.latitude = coordinate.latitude
            session.longitude = coordinate.longitude
            mapRegion = MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
            )
            applyPlacemark(first.placemark)
        } catch {
            searchMessage = "Location search failed."
        }
    }

    private func bindingForAdvancedField(_ field: LocationAdvancedField) -> Binding<Bool> {
        Binding(
            get: { session.selectedAdvancedFields.contains(field) },
            set: { isEnabled in
                if isEnabled {
                    session.selectedAdvancedFields.insert(field)
                } else {
                    session.selectedAdvancedFields.remove(field)
                }
            }
        )
    }

    private func sanitizeAdvancedSelection() {
        let allowed = Set(availableAdvancedFields)
        session.selectedAdvancedFields.formIntersection(allowed)
    }

    private func scheduleReverseGeocode(for coordinate: CLLocationCoordinate2D) {
        reverseGeocodeTask?.cancel()
        reverseGeocodeTask = Task {
            await resolvePlacemark(for: coordinate)
        }
    }

    private func resolvePlacemark(for coordinate: CLLocationCoordinate2D) async {
        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            guard !Task.isCancelled, let placemark = placemarks.first else { return }
            applyPlacemark(placemark)
        } catch {
            // Keep advanced metadata optional.
        }
    }

    private func applyPlacemark(_ placemark: CLPlacemark) {
        let sublocation = [placemark.subLocality, placemark.name]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""
        session.setResolvedValue(sublocation, for: .sublocation)
        session.setResolvedValue(placemark.locality?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", for: .city)
        session.setResolvedValue(placemark.administrativeArea?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", for: .stateProvince)
        session.setResolvedValue(placemark.country?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", for: .country)
        session.setResolvedValue((placemark.isoCountryCode ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), for: .countryCode)
    }

    private func refreshPreview() async {
        isLoadingPreview = true
        let assessment = model.previewLocationAdjust(session: session)
        previewRows = assessment.rows
        previewBlockingIssues = assessment.blockingIssues
        previewWarnings = assessment.warnings
        hasEffectivePreviewChanges = assessment.effectiveChangeFileCount > 0
        isLoadingPreview = false
    }
}

private struct WorkflowLocationMapField: NSViewRepresentable {
    @Binding var region: MKCoordinateRegion
    @Binding var coordinate: CLLocationCoordinate2D?
    var onCoordinateCommit: ((CLLocationCoordinate2D) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.mapType = .standard
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = false
        mapView.showsCompass = true
        mapView.showsScale = true
        mapView.setRegion(region, animated: false)

        context.coordinator.mapView = mapView
        context.coordinator.syncAnnotation(on: mapView, coordinate: coordinate)
        return mapView
    }

    func updateNSView(_ mapView: MKMapView, context: Context) {
        context.coordinator.parent = self

        if !context.coordinator.isRegionApproximatelyEqual(mapView.region, region) {
            context.coordinator.isSettingRegionFromSwiftUI = true
            mapView.setRegion(region, animated: false)
            context.coordinator.isSettingRegionFromSwiftUI = false
        }

        if !context.coordinator.isDraggingAnnotation {
            context.coordinator.syncAnnotation(on: mapView, coordinate: coordinate)
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: WorkflowLocationMapField
        weak var mapView: MKMapView?
        var isSettingRegionFromSwiftUI = false
        var isDraggingAnnotation = false

        private let annotation = MKPointAnnotation()
        private var hasAnnotation = false

        init(parent: WorkflowLocationMapField) {
            self.parent = parent
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated _: Bool) {
            guard !isSettingRegionFromSwiftUI else { return }
            parent.region = mapView.region
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation { return nil }

            let reuseIdentifier = "WorkflowLocationPin"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: reuseIdentifier) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: reuseIdentifier)
            view.annotation = annotation
            view.canShowCallout = false
            view.isDraggable = true
            view.markerTintColor = .systemTeal
            return view
        }

        func mapView(
            _ mapView: MKMapView,
            annotationView view: MKAnnotationView,
            didChange newState: MKAnnotationView.DragState,
            fromOldState _: MKAnnotationView.DragState
        ) {
            switch newState {
            case .starting:
                isDraggingAnnotation = true
                view.dragState = .dragging
            case .dragging:
                isDraggingAnnotation = true
                if let coordinate = view.annotation?.coordinate {
                    parent.coordinate = coordinate
                    parent.region.center = coordinate
                }
            case .ending, .canceling:
                if let coordinate = view.annotation?.coordinate {
                    parent.coordinate = coordinate
                    parent.region.center = coordinate
                }
                isDraggingAnnotation = false
                view.dragState = .none
                syncAnnotation(on: mapView, coordinate: parent.coordinate)
                if let coordinate = view.annotation?.coordinate {
                    parent.onCoordinateCommit?(coordinate)
                }
            default:
                break
            }
        }

        func syncAnnotation(on mapView: MKMapView, coordinate: CLLocationCoordinate2D?) {
            if let coordinate {
                annotation.coordinate = coordinate
                if !hasAnnotation {
                    mapView.addAnnotation(annotation)
                    hasAnnotation = true
                }
            } else if hasAnnotation {
                mapView.removeAnnotation(annotation)
                hasAnnotation = false
            }
        }

        func isRegionApproximatelyEqual(_ lhs: MKCoordinateRegion, _ rhs: MKCoordinateRegion) -> Bool {
            let centerLatitudeDelta = abs(lhs.center.latitude - rhs.center.latitude)
            let centerLongitudeDelta = abs(lhs.center.longitude - rhs.center.longitude)
            let spanLatitudeDelta = abs(lhs.span.latitudeDelta - rhs.span.latitudeDelta)
            let spanLongitudeDelta = abs(lhs.span.longitudeDelta - rhs.span.longitudeDelta)
            return centerLatitudeDelta < 0.000_001 &&
                centerLongitudeDelta < 0.000_001 &&
                spanLatitudeDelta < 0.000_001 &&
                spanLongitudeDelta < 0.000_001
        }
    }
}


extension View {
    func locationAdjustSheet(model: AppModel) -> some View {
        self.sheet(item: Binding(
            get: { model.pendingLocationAdjustSession },
            set: { newValue in
                Task { @MainActor in
                    model.pendingLocationAdjustSession = newValue
                }
            }
        )) { session in
            LocationAdjustSheetView(model: model, initialSession: session)
        }
    }
}
