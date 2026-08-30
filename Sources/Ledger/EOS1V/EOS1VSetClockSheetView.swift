import SharedUI
import SwiftUI

/// Writes the connected camera's clock over the ES-E1 cable — Ledger's one
/// write path to the camera. Visually mirrors DateTimeAdjustSheetView's
/// chrome (WorkflowSheetContainer, segmented mode picker, WorkflowFormRow)
/// but is much simpler: one camera, one write, no per-file targeting.
///
/// A SwiftUI leaf presented via NSHostingController + presentAsSheet(_:)
/// from EOS1VPropertiesViewController, the same pattern as
/// LensProfileManagerSheet and EOS1VRollDetailSheetView.
struct EOS1VSetClockSheetView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case system
        case shift
        case specific

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .system: "System"
            case .shift: "Shift"
            case .specific: "Specific"
            }
        }
    }

    let session: EOS1VSessionController
    let onDone: () -> Void

    @State private var mode: Mode = .system
    @State private var shiftDays = 0
    @State private var shiftHours = 0
    @State private var shiftMinutes = 0
    @State private var shiftSeconds = 0
    @State private var specificDate = Date()
    @State private var isWriting = false
    @State private var errorMessage: String?

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    var body: some View {
        WorkflowSheetContainer(
            title: "Change Date and Time",
            subtitle: "Writes the camera's clock over the ES-E1 cable.",
            width: 620,
            sectionSpacing: .uniform(20)
        ) {
            VStack(alignment: .leading, spacing: 0) {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 16)

                VStack(alignment: .leading, spacing: 10) {
                    WorkflowFormRow("Camera clock:", labelWidth: 132) {
                        Text(cameraClockDisplay)
                            .foregroundStyle(.secondary)
                    }

                    modeSpecificControls

                    WorkflowFormRow("New clock:", labelWidth: 132) {
                        newClockPreview
                    }
                }
                .padding(.bottom, 16)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 8)
                }

                HStack {
                    if isWriting {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Spacer()
                    Button("Cancel", action: onDone)
                        .keyboardShortcut(.cancelAction)
                        .disabled(isWriting)
                    Button("Adjust", action: performAdjust)
                        .keyboardShortcut(.defaultAction)
                        .disabled(isWriting || !isAdjustEnabled)
                }
            }
        }
    }

    // MARK: - Mode-Specific Controls

    @ViewBuilder
    private var modeSpecificControls: some View {
        switch mode {
        case .system:
            EmptyView()
        case .shift:
            WorkflowFormRow("Offset:", labelWidth: 132) {
                HStack(spacing: 8) {
                    offsetField(value: $shiftDays, label: "Days")
                    offsetField(value: $shiftHours, label: "Hours")
                    offsetField(value: $shiftMinutes, label: "Mins")
                    offsetField(value: $shiftSeconds, label: "Secs")
                }
            }
        case .specific:
            WorkflowFormRow("Set to:", labelWidth: 132) {
                InspectorDatePickerField(
                    selection: $specificDate,
                    datePickerElements: [.yearMonthDay, .hourMinuteSecond],
                    accessibilityLabel: "New camera date and time"
                )
            }
        }
    }

    private func offsetField(value: Binding<Int>, label: String) -> some View {
        HStack(spacing: 2) {
            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 44)
                .multilineTextAlignment(.trailing)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Values

    private var cameraClockDate: Date? {
        guard let date = session.camera?.clockDate, let time = session.camera?.clockTime else { return nil }
        return Self.displayFormatter.date(from: "\(date) \(time)")
    }

    private var cameraClockDisplay: String {
        guard let cameraClockDate else { return "—" }
        return Self.displayFormatter.string(from: cameraClockDate)
    }

    /// The value that will actually be written. For `.system` this is
    /// deliberately NOT used for the write itself -- performAdjust() reads
    /// Date() fresh at the moment "Adjust" is pressed, matching "applies it
    /// at the point I press Adjust" rather than whatever was last displayed.
    private var pendingDate: Date? {
        switch mode {
        case .system:
            return Date()
        case .shift:
            guard let cameraClockDate else { return nil }
            var components = DateComponents()
            components.day = shiftDays
            components.hour = shiftHours
            components.minute = shiftMinutes
            components.second = shiftSeconds
            return Calendar.current.date(byAdding: components, to: cameraClockDate)
        case .specific:
            return specificDate
        }
    }

    private var isAdjustEnabled: Bool {
        pendingDate != nil
    }

    @ViewBuilder
    private var newClockPreview: some View {
        switch mode {
        case .system:
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Self.displayFormatter.string(from: context.date))
            }
        case .shift:
            if let pendingDate {
                Text(Self.displayFormatter.string(from: pendingDate))
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        case .specific:
            Text(Self.displayFormatter.string(from: specificDate))
        }
    }

    // MARK: - Actions

    private func performAdjust() {
        // Recomputed fresh here (not read from `pendingDate`'s cached System
        // value) so System mode writes the time at the moment of the click.
        let dateToWrite: Date
        switch mode {
        case .system:
            dateToWrite = Date()
        case .shift, .specific:
            guard let pendingDate else { return }
            dateToWrite = pendingDate
        }

        isWriting = true
        errorMessage = nil
        session.writeClock(dateToWrite) { result in
            isWriting = false
            switch result {
            case .success:
                onDone()
            case let .failure(error):
                errorMessage = error.localizedDescription
            }
        }
    }
}
