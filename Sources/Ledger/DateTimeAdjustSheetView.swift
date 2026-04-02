import CoreLocation
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

    @ObservedObject var model: AppModel
    @State private var session: DateTimeAdjustSession

    @State private var showPreview = false
    @State private var previewRows: [DateTimeAdjustPreviewRow] = []
    @State private var previewBlockingIssues: [String] = []
    @State private var previewWarnings: [String] = []
    @State private var hasEffectivePreviewChanges = false
    @State private var isLoadingPreview = false
    @State private var hoveredOffsetField: OffsetFieldID?
    @FocusState private var focusedOffsetField: OffsetFieldID?

    private static let sheetWidth: CGFloat = 620
    private static let sectionSpacing = WorkflowSheetSectionSpacing.uniform(20)
    private static let modeOrder: [DateTimeAdjustMode] = [.shift, .timeZone, .specific, .file]
    private static let labelColumnWidth: CGFloat = 132
    private static let formRowSpacing: CGFloat = 10
    private static let knownTimeZones: [String] = TimeZone.knownTimeZoneIdentifiers
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

    init(model: AppModel, initialSession: DateTimeAdjustSession) {
        self.model = model
        _session = State(initialValue: initialSession)
    }

    private var fileCount: Int { session.fileURLs.count }

    private var representativeOriginalDate: Date? {
        guard let first = session.fileURLs.first else { return nil }
        return model.originalDate(for: first, tag: session.launchTag)
    }

    private var computedAdjustedDate: Date? {
        guard let first = session.fileURLs.first else { return nil }
        return model.computeAdjustedDate(for: first, session: session)
    }

    private var hasBlockingIssues: Bool {
        !previewBlockingIssues.isEmpty || session.applyTo.isEmpty
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
            session.closestCity,
            session.targetTimezone,
            "\(session.shiftDays)",
            "\(session.shiftHours)",
            "\(session.shiftMinutes)",
            "\(session.shiftSeconds)",
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
                        InspectorDatePickerField(
                            selection: .constant(representativeOriginalDate ?? Date()),
                            isEnabled: false,
                            datePickerElements: [.yearMonthDay, .hourMinuteSecond],
                            accessibilityLabel: "Original date and time"
                        )
                    }

                    // Adjusted row
                    WorkflowFormRow("Adjusted:", labelWidth: Self.labelColumnWidth) {
                        if session.mode == .specific {
                            InspectorDatePickerField(
                                selection: $session.specificDate,
                                datePickerElements: [.yearMonthDay, .hourMinuteSecond],
                                accessibilityLabel: "Adjusted date and time"
                            )
                        } else if session.mode == .shift {
                            InspectorDatePickerField(
                                selection: shiftAdjustedBinding,
                                datePickerElements: [.yearMonthDay, .hourMinuteSecond],
                                accessibilityLabel: "Adjusted date and time"
                            )
                        } else {
                            InspectorDatePickerField(
                                selection: .constant(computedAdjustedDate ?? Date()),
                                isEnabled: false,
                                datePickerElements: [.yearMonthDay, .hourMinuteSecond],
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
            await refreshPreview()
        }
    }

    // MARK: - Mode-Specific Controls

    @ViewBuilder
    private var modeSpecificControls: some View {
        switch session.mode {
        case .timeZone:
            WorkflowFormRow("Original Time Zone:", labelWidth: Self.labelColumnWidth) {
                WorkflowCityComboField(
                    value: $session.sourceTimeZoneID,
                    items: Self.knownTimeZones,
                    placeholder: "Europe/London"
                )
            }
            WorkflowFormRow("Closest City:", labelWidth: Self.labelColumnWidth) {
                WorkflowCityComboField(
                    value: $session.closestCity,
                    items: TimeZoneCityData.cities.map(\.city),
                    placeholder: "Type a city name"
                )
            }
            WorkflowFormRow("New Time Zone:", labelWidth: Self.labelColumnWidth) {
                Text(model.resolvedTimeZoneName(for: session))
                    .foregroundStyle(.secondary)
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
        case .specific, .file:
            EmptyView()
        }
    }

    private var shiftAdjustedBinding: Binding<Date> {
        Binding(
            get: { computedAdjustedDate ?? Date() },
            set: { newAdjustedDate in
                applyShiftFromEditedAdjustedDate(newAdjustedDate)
            }
        )
    }

    private func applyShiftFromEditedAdjustedDate(_ adjustedDate: Date) {
        guard let first = session.fileURLs.first,
              let original = model.originalDate(for: first, tag: session.launchTag) else {
            return
        }
        setShiftComponents(fromSeconds: Int(adjustedDate.timeIntervalSince(original).rounded()))
    }

    private func setShiftComponents(fromSeconds totalSeconds: Int) {
        let sign = totalSeconds < 0 ? -1 : 1
        let absoluteSeconds = abs(totalSeconds)
        let days = absoluteSeconds / 86_400
        let hours = (absoluteSeconds % 86_400) / 3_600
        let minutes = (absoluteSeconds % 3_600) / 60
        let seconds = absoluteSeconds % 60
        session.shiftDays = days * sign
        session.shiftHours = hours * sign
        session.shiftMinutes = minutes * sign
        session.shiftSeconds = seconds * sign
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
                                .font(.system(.caption, design: .monospaced))
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
                    session.applyTo.insert(tag)
                } else {
                    session.applyTo.remove(tag)
                }
            }
        )
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
    @StateObject private var userLocationProvider = WorkflowUserLocationProvider()

    @State private var showAdvanced = false
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
                span: MKCoordinateSpan(latitudeDelta: 0.12, longitudeDelta: 0.12)
            )
        )
    }

    private var fileCount: Int { session.fileURLs.count }

    private var subtitle: String {
        let noun = fileCount == 1 ? "1 selected file" : "\(fileCount) selected files"
        return "Changing \(noun) to a new location"
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
                        scheduleReverseGeocode(for: coordinate)
                    }
                )
                .frame(height: 260)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.bottom, Self.mapToCoordinatesSpacing)

                // Block 4: Latitude / Longitude
                HStack(spacing: 28) {
                    HStack(spacing: 4) {
                        Text("Latitude:")
                            .font(.callout)
                        Text(selectedCoordinate.map { AppModel.compactDecimalString($0.latitude) } ?? "—")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 4) {
                        Text("Longitude:")
                            .font(.callout)
                        Text(selectedCoordinate.map { AppModel.compactDecimalString($0.longitude) } ?? "—")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.bottom, Self.coordinatesToFooterSpacing)

                // Block 5: Footer buttons
                HStack {
                    Button("Advanced\u{2026}") {
                        showAdvanced = true
                    }
                    .disabled(!isAdvancedActionEnabled)
                    .popover(isPresented: $showAdvanced) {
                        advancedPopover
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
            if selectedCoordinate == nil {
                userLocationProvider.requestLocationIfNeeded()
            }
        }
        .task(id: previewKey) {
            await refreshPreview()
        }
        .onChange(of: advancedAvailabilityKey) { _, _ in
            sanitizeAdvancedSelection()
        }
        .onReceive(userLocationProvider.$coordinate) { coordinate in
            guard selectedCoordinate == nil, let coordinate else { return }
            session.latitude = coordinate.latitude
            session.longitude = coordinate.longitude
            mapRegion.center = coordinate
            scheduleReverseGeocode(for: coordinate)
        }
        .onDisappear {
            reverseGeocodeTask?.cancel()
        }
    }

    @ViewBuilder
    private var advancedPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            if availableAdvancedFields.isEmpty {
                Text("Enable location text fields in Inspector Settings to use Advanced options.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(availableAdvancedFields) { field in
                    Toggle(field.label, isOn: bindingForAdvancedField(field))
                        .toggleStyle(.checkbox)
                }
            }
        }
        .padding()
        .frame(minWidth: 220)
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
                                .font(.system(.caption, design: .monospaced))
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
        if !isAdvancedActionEnabled {
            showAdvanced = false
        }
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

private final class WorkflowUserLocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var coordinate: CLLocationCoordinate2D?

    private let manager = CLLocationManager()
    private var hasRequested = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func requestLocationIfNeeded() {
        guard !hasRequested else { return }
        hasRequested = true
        guard CLLocationManager.locationServicesEnabled() else { return }

        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .restricted, .denied:
            break
        @unknown default:
            break
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .restricted, .denied, .notDetermined:
            break
        @unknown default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        coordinate = location.coordinate
        manager.stopUpdatingLocation()
    }

    func locationManager(_: CLLocationManager, didFailWithError _: Error) {
        // Keep location optional; the map remains usable via search and manual pin move.
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
