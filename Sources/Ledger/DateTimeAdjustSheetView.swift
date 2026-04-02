import SharedUI
import SwiftUI

struct DateTimeAdjustSheetView: View {
    @ObservedObject var model: AppModel
    @State private var session: DateTimeAdjustSession

    @State private var showPreview = false
    @State private var previewRows: [DateTimeAdjustPreviewRow] = []
    @State private var previewBlockingIssues: [String] = []
    @State private var previewWarnings: [String] = []
    @State private var isLoadingPreview = false

    private static let modeOrder: [DateTimeAdjustMode] = [.shift, .timeZone, .specific, .file]
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
            subtitle: session.mode.subtitle(fileCount: fileCount)
        ) {
            // Mode segmented control
            Picker("Mode", selection: $session.mode) {
                ForEach(Self.modeOrder) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .center)

            // Original row
            labeledRow("Original:") {
                InspectorDatePickerField(
                    selection: .constant(representativeOriginalDate ?? Date()),
                    isEnabled: false,
                    datePickerElements: [.yearMonthDay, .hourMinuteSecond],
                    accessibilityLabel: "Original date and time"
                )
            }

            // Adjusted row
            labeledRow("Adjusted:") {
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
            labeledRow("Apply to:") {
                HStack(spacing: 16) {
                    ForEach(DateTimeTargetTag.allCases) { tag in
                        Toggle(tag.displayName, isOn: applyToBinding(for: tag))
                            .toggleStyle(.checkbox)
                    }
                }
            }

            // Footer
            HStack {
                Button("Preview\u{2026}") {
                    if previewRows.isEmpty && !isLoadingPreview {
                        Task { await refreshPreview() }
                    }
                    showPreview = true
                }
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
                .disabled(hasBlockingIssues)
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
            labeledRow("Source Time Zone:") {
                WorkflowCityComboField(
                    value: $session.sourceTimeZoneID,
                    items: Self.knownTimeZones,
                    placeholder: "Europe/London"
                )
            }
            labeledRow("Closest City:") {
                WorkflowCityComboField(
                    value: $session.closestCity,
                    items: TimeZoneCityData.cities.map(\.city),
                    placeholder: "Type a city name"
                )
            }
            labeledRow("Time Zone:") {
                Text(model.resolvedTimeZoneName(for: session))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .shift:
            labeledRow("Offset:") {
                HStack(spacing: 8) {
                    offsetField(value: $session.shiftDays, label: "Days")
                    offsetField(value: $session.shiftHours, label: "Hours")
                    offsetField(value: $session.shiftMinutes, label: "Mins")
                    offsetField(value: $session.shiftSeconds, label: "Secs")
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

    private func offsetField(value: Binding<Int>, label: String) -> some View {
        HStack(spacing: 2) {
            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 48)
                .multilineTextAlignment(.trailing)
            Stepper(label, value: value)
                .labelsHidden()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
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

    // MARK: - Helpers

    private func labeledRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(label)
                .frame(width: 90, alignment: .trailing)
            content()
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
