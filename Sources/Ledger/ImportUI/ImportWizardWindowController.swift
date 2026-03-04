import AppKit
import ExifEditCore
import Foundation
import UniformTypeIdentifiers

@MainActor
final class ImportWizardWindowController: NSWindowController, NSWindowDelegate {
    private let wizardController: ImportWizardViewController
    var onClose: (() -> Void)?

    init(model: AppModel, initialSourceKind: ImportSourceKind) {
        wizardController = ImportWizardViewController(model: model, initialSourceKind: initialSourceKind)
        let window = NSWindow(contentViewController: wizardController)
        window.title = "Import"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 760, height: 560))
        window.isReleasedWhenClosed = false
        window.titleVisibility = .visible
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func presentSheet(for parentWindow: NSWindow) {
        guard let window else { return }
        if parentWindow.attachedSheet == window {
            parentWindow.makeKeyAndOrderFront(nil)
            return
        }
        parentWindow.beginSheet(window)
    }

    func updateInitialSourceKind(_ sourceKind: ImportSourceKind) {
        wizardController.selectSourceKind(sourceKind)
    }

    func windowWillClose(_: Notification) {
        onClose?()
    }
}

@MainActor
private final class ImportWizardViewController: NSViewController {
    private enum Step: Int, CaseIterable {
        case source
        case match
        case preview
        case conflicts
        case summary

        var title: String {
            switch self {
            case .source:
                return "1. Source and Options"
            case .match:
                return "2. Match"
            case .preview:
                return "3. Preview"
            case .conflicts:
                return "4. Resolve Conflicts"
            case .summary:
                return "5. Summary"
            }
        }
    }

    private weak var model: AppModel?
    private let coordinator = ImportCoordinator()
    private var options: ImportRunOptions
    private var currentStep: Step = .source
    private var preparedRun: ImportPreparedRun?
    private var conflictResolutions: [UUID: ImportConflictResolutionChoice] = [:]
    private var latestResolveResult: ImportConflictResolveResult?
    private var workingReport: ImportReport?
    private var isBusy = false

    private let rootStack = NSStackView()
    private let contentStack = NSStackView()
    private let stepLabel = NSTextField(labelWithString: "")
    private let backButton = NSButton(title: "Back", target: nil, action: nil)
    private let nextButton = NSButton(title: "Next", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let stageButton = NSButton(title: "Stage Import", target: nil, action: nil)
    private let exportButton = NSButton(title: "Export Report…", target: nil, action: nil)
    private let progressIndicator = NSProgressIndicator()

    private let sourceKindPopup = NSPopUpButton()
    private let sourcePathField = NSTextField(labelWithString: "No source selected")
    private let chooseSourceButton = NSButton(title: "Choose…", target: nil, action: nil)
    private let scopePopup = NSPopUpButton()
    private let emptyPolicyPopup = NSPopUpButton()
    private let matchStrategyPopup = NSPopUpButton()
    private let rowStartField = NSTextField(string: "1")
    private let rowCountField = NSTextField(string: "0")
    private let toleranceField = NSTextField(string: "600")
    private let offsetField = NSTextField(string: "0")
    private let selectedFieldsLabel = NSTextField(labelWithString: "")
    private let scopeSummaryLabel = NSTextField(labelWithString: "")
    private let chooseFieldsButton = NSButton(title: "Choose Fields…", target: nil, action: nil)
    private let detailsTextView = NSTextView()
    private let detailsScrollView = NSScrollView()

    private var conflictControls: [UUID: NSComboBox] = [:]

    init(model: AppModel, initialSourceKind: ImportSourceKind) {
        self.model = model
        options = coordinator.loadPersistedOptions(for: initialSourceKind)
        if options.sourceKind != initialSourceKind {
            options = ImportRunOptions.defaults(for: initialSourceKind)
        }
        super.init(nibName: nil, bundle: nil)
        applySelectionDrivenDefaults()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureUI()
        refreshSourceControlState()
        render()
    }

    func selectSourceKind(_ sourceKind: ImportSourceKind) {
        options = coordinator.loadPersistedOptions(for: sourceKind)
        options.sourceKind = sourceKind
        applySelectionDrivenDefaults()
        preparedRun = nil
        latestResolveResult = nil
        workingReport = nil
        conflictResolutions.removeAll()
        currentStep = .source
        refreshSourceControlState()
        render()
    }

    private func configureUI() {
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 12
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        stepLabel.font = .systemFont(ofSize: 15, weight: .semibold)

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 10
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        detailsTextView.isEditable = false
        detailsTextView.isVerticallyResizable = true
        detailsTextView.isHorizontallyResizable = false
        detailsTextView.textContainerInset = NSSize(width: 8, height: 8)
        detailsScrollView.hasVerticalScroller = true
        detailsScrollView.documentView = detailsTextView
        detailsScrollView.translatesAutoresizingMaskIntoConstraints = false
        detailsScrollView.heightAnchor.constraint(equalToConstant: 300).isActive = true
        detailsScrollView.widthAnchor.constraint(greaterThanOrEqualToConstant: 700).isActive = true

        sourceKindPopup.target = self
        sourceKindPopup.action = #selector(sourceKindChanged(_:))

        chooseSourceButton.target = self
        chooseSourceButton.action = #selector(chooseSourceAction(_:))

        scopePopup.target = self
        scopePopup.action = #selector(scopeChanged(_:))
        emptyPolicyPopup.target = self
        emptyPolicyPopup.action = #selector(emptyPolicyChanged(_:))
        matchStrategyPopup.target = self
        matchStrategyPopup.action = #selector(matchStrategyChanged(_:))
        chooseFieldsButton.target = self
        chooseFieldsButton.action = #selector(chooseFieldsAction(_:))

        backButton.target = self
        backButton.action = #selector(backAction(_:))
        nextButton.target = self
        nextButton.action = #selector(nextAction(_:))
        cancelButton.target = self
        cancelButton.action = #selector(cancelAction(_:))
        stageButton.target = self
        stageButton.action = #selector(stageAction(_:))
        exportButton.target = self
        exportButton.action = #selector(exportReportAction(_:))

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false

        view.addSubview(rootStack)
        rootStack.addArrangedSubview(stepLabel)
        rootStack.addArrangedSubview(contentStack)
        rootStack.setCustomSpacing(18, after: contentStack)

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8
        buttonRow.addArrangedSubview(progressIndicator)
        buttonRow.addArrangedSubview(NSView())
        buttonRow.addArrangedSubview(exportButton)
        buttonRow.addArrangedSubview(backButton)
        buttonRow.addArrangedSubview(nextButton)
        buttonRow.addArrangedSubview(stageButton)
        buttonRow.addArrangedSubview(cancelButton)
        rootStack.addArrangedSubview(buttonRow)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            rootStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            rootStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 18),
            rootStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -18),
        ])
    }

    private func refreshSourceControlState() {
        sourceKindPopup.removeAllItems()
        for sourceKind in ImportSourceKind.allCases {
            sourceKindPopup.addItem(withTitle: sourceKind.title)
            sourceKindPopup.lastItem?.representedObject = sourceKind.rawValue
        }
        if let index = ImportSourceKind.allCases.firstIndex(of: options.sourceKind) {
            sourceKindPopup.selectItem(at: index)
        }

        scopePopup.removeAllItems()
        for scope in ImportScope.allCases {
            scopePopup.addItem(withTitle: scope.title)
            scopePopup.lastItem?.representedObject = scope.rawValue
        }
        if let index = ImportScope.allCases.firstIndex(of: options.scope) {
            scopePopup.selectItem(at: index)
        }

        emptyPolicyPopup.removeAllItems()
        for policy in ImportEmptyValuePolicy.allCases {
            emptyPolicyPopup.addItem(withTitle: policy.title)
            emptyPolicyPopup.lastItem?.representedObject = policy.rawValue
        }
        if let index = ImportEmptyValuePolicy.allCases.firstIndex(of: options.emptyValuePolicy) {
            emptyPolicyPopup.selectItem(at: index)
        }

        matchStrategyPopup.removeAllItems()
        for strategy in ImportMatchStrategy.allCases {
            matchStrategyPopup.addItem(withTitle: strategy.title)
            matchStrategyPopup.lastItem?.representedObject = strategy.rawValue
        }
        if let index = ImportMatchStrategy.allCases.firstIndex(of: options.matchStrategy) {
            matchStrategyPopup.selectItem(at: index)
        }

        sourcePathField.stringValue = sourceSummaryText()
        rowStartField.stringValue = String(max(1, options.rowParityStartRow))
        rowCountField.stringValue = String(max(0, options.rowParityRowCount))
        toleranceField.stringValue = String(options.gpxToleranceSeconds)
        offsetField.stringValue = String(options.gpxCameraOffsetSeconds)

        let selectedCount = options.selectedTagIDs.isEmpty ? (model?.importTagCatalog.count ?? 0) : options.selectedTagIDs.count
        selectedFieldsLabel.stringValue = "\(selectedCount) fields selected"
        scopeSummaryLabel.stringValue = currentScopeSummaryText()
        scopeSummaryLabel.textColor = .secondaryLabelColor
    }

    private func render() {
        stepLabel.stringValue = currentStep.title
        clearContentStack()
        switch currentStep {
        case .source:
            renderSourceStep()
        case .match:
            renderMatchStep()
        case .preview:
            renderPreviewStep()
        case .conflicts:
            renderConflictStep()
        case .summary:
            renderSummaryStep()
        }

        backButton.isHidden = currentStep == .source
        nextButton.isHidden = currentStep == .summary
        stageButton.isHidden = currentStep != .summary
        exportButton.isHidden = currentStep != .summary
        exportButton.isEnabled = workingReport != nil
        nextButton.title = currentStep == .conflicts ? "Continue" : "Next"
        backButton.isEnabled = !isBusy
        nextButton.isEnabled = !isBusy
        stageButton.isEnabled = !isBusy
        chooseSourceButton.isEnabled = !isBusy
        progressIndicator.isHidden = !isBusy
        if isBusy {
            progressIndicator.startAnimation(nil)
        } else {
            progressIndicator.stopAnimation(nil)
        }
    }

    private func renderSourceStep() {
        contentStack.addArrangedSubview(makeLabeledRow(label: "Import Type", view: sourceKindPopup))
        let sourceLabel = options.sourceKind == .gpx ? "Sources" : "Source"
        contentStack.addArrangedSubview(makeLabeledPathRow(label: sourceLabel, textField: sourcePathField, actionButton: chooseSourceButton))

        contentStack.addArrangedSubview(makeLabeledRow(label: "Target Scope", view: scopePopup))
        contentStack.addArrangedSubview(makeLabeledRow(label: "Applying To", view: scopeSummaryLabel))
        contentStack.addArrangedSubview(makeLabeledRow(label: "Empty Values", view: emptyPolicyPopup))
        if options.sourceKind == .csv || options.sourceKind == .eos1v {
            contentStack.addArrangedSubview(makeLabeledRow(label: "Matching", view: matchStrategyPopup))
            if options.matchStrategy == .rowParity {
                contentStack.addArrangedSubview(makeLabeledRow(label: "Start Row", view: rowStartField))
                contentStack.addArrangedSubview(makeLabeledRow(label: "Row Count", view: rowCountField))
            }
        }

        if options.sourceKind == .gpx {
            contentStack.addArrangedSubview(makeLabeledRow(label: "Tolerance (sec)", view: toleranceField))
            contentStack.addArrangedSubview(makeLabeledRow(label: "Camera Offset (sec)", view: offsetField))
        }

        if options.sourceKind == .referenceFolder || options.sourceKind == .referenceImage {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            row.addArrangedSubview(selectedFieldsLabel)
            row.addArrangedSubview(chooseFieldsButton)
            contentStack.addArrangedSubview(makeLabeledRow(label: "Fields", view: row))
        }

        let hint = NSTextField(labelWithString: "Flow: Source/options -> Match -> Preview -> Conflicts -> Summary")
        hint.textColor = .secondaryLabelColor
        contentStack.addArrangedSubview(hint)
    }

    private func renderMatchStep() {
        guard let preparedRun else {
            detailsTextView.string = "No prepared import run."
            contentStack.addArrangedSubview(detailsScrollView)
            return
        }
        detailsTextView.string = """
        Parsed rows: \(preparedRun.previewSummary.parsedRows)
        Matched rows: \(preparedRun.previewSummary.matchedRows)
        Conflicts: \(preparedRun.previewSummary.conflictedRows)
        Warnings: \(preparedRun.previewSummary.warnings)
        Estimated field writes: \(preparedRun.previewSummary.fieldWrites)
        """
        contentStack.addArrangedSubview(detailsScrollView)
    }

    private func renderPreviewStep() {
        guard let preparedRun else {
            detailsTextView.string = "No preview available."
            contentStack.addArrangedSubview(detailsScrollView)
            return
        }
        var lines: [String] = []
        for entry in preparedRun.matchResult.matched.prefix(250) {
            lines.append("L\(entry.row.sourceLine)  \(entry.row.sourceIdentifier) -> \(entry.targetURL.lastPathComponent) (\(entry.row.fields.count) fields)")
        }
        if preparedRun.matchResult.matched.count > 250 {
            lines.append("… \(preparedRun.matchResult.matched.count - 250) additional rows omitted")
        }
        if lines.isEmpty {
            lines.append("No matched rows to preview.")
        }
        detailsTextView.string = lines.joined(separator: "\n")
        contentStack.addArrangedSubview(detailsScrollView)
    }

    private func renderConflictStep() {
        guard let preparedRun else {
            detailsTextView.string = "No conflict data."
            contentStack.addArrangedSubview(detailsScrollView)
            return
        }
        conflictControls.removeAll()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8

        if preparedRun.matchResult.conflicts.isEmpty {
            stack.addArrangedSubview(NSTextField(labelWithString: "No conflicts."))
        } else {
            for conflict in preparedRun.matchResult.conflicts {
                let row = NSStackView()
                row.orientation = .horizontal
                row.alignment = .centerY
                row.spacing = 8
                row.distribution = .fillProportionally

                let label = NSTextField(wrappingLabelWithString: "L\(conflict.sourceLine): \(conflict.message)")
                label.preferredMaxLayoutWidth = 440
                label.setContentHuggingPriority(.defaultLow, for: .horizontal)

                let chooser = NSComboBox()
                chooser.usesDataSource = false
                chooser.completes = false
                chooser.isEditable = false
                chooser.numberOfVisibleItems = 8
                chooser.widthAnchor.constraint(equalToConstant: 250).isActive = true
                chooser.addItem(withObjectValue: "Choose resolution…")
                if !conflict.candidateTargets.isEmpty {
                    conflict.candidateTargets.forEach { chooser.addItem(withObjectValue: $0.path) }
                }
                chooser.addItem(withObjectValue: "Skip row")
                chooser.target = self
                chooser.action = #selector(conflictResolutionChanged(_:))
                chooser.identifier = NSUserInterfaceItemIdentifier(conflict.id.uuidString)
                conflictControls[conflict.id] = chooser

                if conflict.kind == .missingTarget {
                    chooser.selectItem(at: max(chooser.numberOfItems - 1, 0))
                    conflictResolutions[conflict.id] = .skip
                } else if let existing = conflictResolutions[conflict.id] {
                    applyConflictResolution(existing, to: chooser, conflict: conflict)
                }

                row.addArrangedSubview(label)
                row.addArrangedSubview(chooser)
                stack.addArrangedSubview(row)
            }
        }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = stack
        scroll.heightAnchor.constraint(equalToConstant: 320).isActive = true
        scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 700).isActive = true
        contentStack.addArrangedSubview(scroll)
    }

    private func renderSummaryStep() {
        guard let preparedRun else {
            detailsTextView.string = "No summary available."
            contentStack.addArrangedSubview(detailsScrollView)
            return
        }

        let resolve = latestResolveResult ?? coordinator.resolveAssignments(preparedRun: preparedRun, resolutions: conflictResolutions)
        latestResolveResult = resolve
        var lines: [String] = [
            "Ready to stage import.",
            "",
            "Assignments: \(resolve.assignments.count)",
            "Skipped conflicts: \(resolve.skippedConflicts.count)",
            "Unresolved conflicts: \(resolve.unresolvedConflicts.count)",
            "Warnings: \(preparedRun.matchResult.warnings.count)",
        ]
        if !resolve.unresolvedConflicts.isEmpty {
            lines.append("")
            lines.append("Resolve all conflicts before staging.")
        }
        detailsTextView.string = lines.joined(separator: "\n")
        contentStack.addArrangedSubview(detailsScrollView)
        stageButton.isEnabled = resolve.unresolvedConflicts.isEmpty
    }

    private func clearContentStack() {
        for view in contentStack.arrangedSubviews {
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func makeLabeledRow(label: String, view: NSView) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        let labelField = NSTextField(labelWithString: label)
        labelField.alignment = .right
        labelField.widthAnchor.constraint(equalToConstant: 140).isActive = true
        row.addArrangedSubview(labelField)
        row.addArrangedSubview(view)
        return row
    }

    private func makeLabeledPathRow(label: String, textField: NSTextField, actionButton: NSButton) -> NSView {
        textField.lineBreakMode = .byTruncatingMiddle
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let container = NSStackView()
        container.orientation = .horizontal
        container.alignment = .centerY
        container.spacing = 8
        container.addArrangedSubview(textField)
        container.addArrangedSubview(actionButton)
        return makeLabeledRow(label: label, view: container)
    }

    @objc
    private func sourceKindChanged(_: Any?) {
        guard sourceKindPopup.indexOfSelectedItem >= 0 else { return }
        let selected = ImportSourceKind.allCases[sourceKindPopup.indexOfSelectedItem]
        options = coordinator.loadPersistedOptions(for: selected)
        options.sourceKind = selected
        applySelectionDrivenDefaults()
        preparedRun = nil
        latestResolveResult = nil
        workingReport = nil
        refreshSourceControlState()
        render()
    }

    @objc
    private func chooseSourceAction(_: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = options.sourceKind == .referenceFolder
        panel.allowsMultipleSelection = options.sourceKind == .gpx
        panel.canChooseDirectories = options.sourceKind == .referenceFolder
        panel.canChooseFiles = options.sourceKind != .referenceFolder
        panel.allowsOtherFileTypes = false
        switch options.sourceKind {
        case .csv, .eos1v:
            if let csvType = UTType(filenameExtension: "csv") {
                panel.allowedContentTypes = [.commaSeparatedText, csvType]
            } else {
                panel.allowedContentTypes = [.commaSeparatedText]
            }
            panel.title = "Choose CSV Source"
        case .gpx:
            if let gpxType = UTType(filenameExtension: "gpx") {
                panel.allowedContentTypes = [gpxType]
            }
            panel.title = "Choose GPX Source Files"
        case .referenceFolder:
            panel.title = "Choose Reference Folder"
        case .referenceImage:
            panel.allowedContentTypes = ReferenceImportSupport.supportedImageExtensions.compactMap { UTType(filenameExtension: $0) }
            panel.title = "Choose Reference Image"
        }
        guard panel.runModal() == .OK else { return }
        if options.sourceKind == .gpx {
            let urls = panel.urls
            guard let primary = urls.first else { return }
            options.sourceURLPath = primary.path
            options.auxiliaryURLPaths = urls.dropFirst().map(\.path)
        } else if let url = panel.url {
            options.sourceURLPath = url.path
            options.auxiliaryURLPaths = []
        } else {
            return
        }
        sourcePathField.stringValue = sourceSummaryText()
        preparedRun = nil
    }

    @objc
    private func scopeChanged(_: Any?) {
        if scopePopup.indexOfSelectedItem >= 0 {
            options.scope = ImportScope.allCases[scopePopup.indexOfSelectedItem]
            if options.scope == .selection,
               options.matchStrategy == .rowParity,
               let model {
                options.rowParityRowCount = model.selectedFileURLs.count
                rowCountField.stringValue = String(max(0, options.rowParityRowCount))
            }
            scopeSummaryLabel.stringValue = currentScopeSummaryText()
        }
    }

    @objc
    private func emptyPolicyChanged(_: Any?) {
        if emptyPolicyPopup.indexOfSelectedItem >= 0 {
            options.emptyValuePolicy = ImportEmptyValuePolicy.allCases[emptyPolicyPopup.indexOfSelectedItem]
        }
    }

    @objc
    private func matchStrategyChanged(_: Any?) {
        if matchStrategyPopup.indexOfSelectedItem >= 0 {
            options.matchStrategy = ImportMatchStrategy.allCases[matchStrategyPopup.indexOfSelectedItem]
            if options.matchStrategy == .rowParity,
               options.scope == .selection,
               let model {
                options.rowParityRowCount = model.selectedFileURLs.count
                rowCountField.stringValue = String(max(0, options.rowParityRowCount))
            }
            render()
        }
    }

    @objc
    private func chooseFieldsAction(_: Any?) {
        guard let model else { return }
        let tags = model.importTagCatalog
        let selected = options.selectedTagIDs.isEmpty ? Set(tags.map(\.id)) : Set(options.selectedTagIDs)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        var checkboxes: [(id: String, button: NSButton)] = []

        if tags.isEmpty {
            stack.addArrangedSubview(NSTextField(labelWithString: "No importable fields are available."))
        } else {
            for tag in tags {
                let button = NSButton(checkboxWithTitle: "\(tag.section): \(tag.label)", target: nil, action: nil)
                button.state = selected.contains(tag.id) ? .on : .off
                checkboxes.append((tag.id, button))
                stack.addArrangedSubview(button)
            }
        }

        let documentView = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 320))
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: documentView.widthAnchor),
        ])
        documentView.layoutSubtreeIfNeeded()
        let fittingHeight = stack.fittingSize.height
        documentView.frame = NSRect(x: 0, y: 0, width: 520, height: max(320, fittingHeight))

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = documentView
        scroll.frame = NSRect(x: 0, y: 0, width: 520, height: 320)

        let alert = NSAlert()
        alert.messageText = "Choose Fields"
        alert.informativeText = "Selected fields will be imported."
        alert.alertStyle = .informational
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")

        let response: NSApplication.ModalResponse
        if let window = view.window {
            response = alert.runModal()
            _ = window
        } else {
            response = alert.runModal()
        }
        guard response == .alertFirstButtonReturn else { return }

        let selectedIDs = checkboxes
            .filter { $0.button.state == .on }
            .map(\.id)
        options.selectedTagIDs = selectedIDs
        selectedFieldsLabel.stringValue = "\(selectedIDs.count) fields selected"
    }

    @objc
    private func backAction(_: Any?) {
        guard !isBusy else { return }
        switch currentStep {
        case .source:
            break
        case .match:
            currentStep = .source
        case .preview:
            currentStep = .match
        case .conflicts:
            currentStep = .preview
        case .summary:
            if preparedRun?.matchResult.conflicts.isEmpty == false {
                currentStep = .conflicts
            } else {
                currentStep = .preview
            }
        }
        render()
    }

    @objc
    private func nextAction(_: Any?) {
        guard !isBusy else { return }

        switch currentStep {
        case .source:
            guard validateSourceStep() else { return }
            options.gpxToleranceSeconds = max(1, toleranceField.integerValue)
            options.gpxCameraOffsetSeconds = offsetField.integerValue
            options.rowParityStartRow = max(1, rowStartField.integerValue)
            options.rowParityRowCount = max(0, rowCountField.integerValue)
            prepareImportRun()
        case .match:
            currentStep = .preview
            render()
        case .preview:
            if preparedRun?.matchResult.conflicts.isEmpty == false {
                currentStep = .conflicts
            } else {
                latestResolveResult = preparedRun.map {
                    coordinator.resolveAssignments(preparedRun: $0, resolutions: conflictResolutions)
                }
                currentStep = .summary
            }
            render()
        case .conflicts:
            guard let preparedRun else { return }
            let resolve = coordinator.resolveAssignments(preparedRun: preparedRun, resolutions: conflictResolutions)
            guard resolve.unresolvedConflicts.isEmpty else {
                showAlert(
                    title: "Resolve Conflicts First",
                    message: "Choose a target or skip for each conflict before continuing."
                )
                return
            }
            latestResolveResult = resolve
            currentStep = .summary
            render()
        case .summary:
            break
        }
    }

    @objc
    private func cancelAction(_: Any?) {
        if let sheet = view.window, let parent = sheet.sheetParent {
            parent.endSheet(sheet)
            return
        }
        view.window?.close()
    }

    @objc
    private func stageAction(_: Any?) {
        guard let model, let preparedRun else { return }
        let resolve = latestResolveResult ?? coordinator.resolveAssignments(
            preparedRun: preparedRun,
            resolutions: conflictResolutions
        )
        guard resolve.unresolvedConflicts.isEmpty else {
            showAlert(title: "Unresolved Conflicts", message: "Resolve all conflicts before staging.")
            return
        }

        let pendingPolicy: ImportPendingEditsPolicy
        if model.hasUnsavedEdits {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Existing pending edits found."
            alert.informativeText = "Choose how to stage imported metadata."
            alert.addButton(withTitle: "Merge")
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                pendingPolicy = .merge
            } else if response == .alertSecondButtonReturn {
                pendingPolicy = .replace
            } else {
                return
            }
        } else {
            pendingPolicy = .merge
        }

        let stageSummary = model.stageImportAssignments(
            resolve.assignments,
            sourceKind: preparedRun.options.sourceKind,
            emptyValuePolicy: preparedRun.options.emptyValuePolicy,
            pendingPolicy: pendingPolicy
        )
        var report = preparedRun.report
        report = coordinator.appendStagingRows(
            report: report,
            stagedAssignments: resolve.assignments,
            skippedConflicts: resolve.skippedConflicts
        )
        workingReport = report

        let message = "Staged \(stageSummary.stagedFields) field(s) on \(stageSummary.stagedFiles) file(s)."
        model.statusMessage = message
        cancelAction(self)
    }

    @objc
    private func exportReportAction(_: Any?) {
        guard let report = workingReport ?? preparedRun?.report else { return }
        let panel = NSSavePanel()
        if let csvType = UTType(filenameExtension: "csv") {
            panel.allowedContentTypes = [csvType]
        }
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "import-report-\(report.sourceKind.rawValue).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try coordinator.export(report: report, to: url)
        } catch {
            showAlert(title: "Export Failed", message: error.localizedDescription)
        }
    }

    @objc
    private func conflictResolutionChanged(_ sender: NSComboBox) {
        guard let identifier = sender.identifier?.rawValue,
              let conflictID = UUID(uuidString: identifier),
              let preparedRun
        else { return }
        guard let conflict = preparedRun.matchResult.conflicts.first(where: { $0.id == conflictID }) else { return }

        let selectedIndex = sender.indexOfSelectedItem
        if selectedIndex < 0 {
            conflictResolutions.removeValue(forKey: conflictID)
            return
        }

        let values = sender.objectValues
        guard selectedIndex < values.count else {
            conflictResolutions.removeValue(forKey: conflictID)
            return
        }
        let selected = String(describing: values[selectedIndex])
        if selected == "Skip row" {
            conflictResolutions[conflictID] = .skip
            return
        }
        if let candidate = conflict.candidateTargets.first(where: { $0.path == selected }) {
            conflictResolutions[conflictID] = .target(candidate)
            return
        }
        conflictResolutions.removeValue(forKey: conflictID)
    }

    private func prepareImportRun() {
        guard let model else { return }
        let targetFiles = model.importTargetFiles(for: options.scope)
        if targetFiles.isEmpty {
            showAlert(title: "No Target Files", message: "No target images are available in the selected scope.")
            return
        }

        isBusy = true
        render()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let prepared = try await coordinator.prepareRun(
                    options: options,
                    targetFiles: targetFiles,
                    tagCatalog: model.importTagCatalog,
                    metadataProvider: { files in
                        await model.importMetadataSnapshots(for: files)
                    }
                )
                preparedRun = prepared
                workingReport = prepared.report
                conflictResolutions = [:]
                latestResolveResult = nil
                currentStep = .match
            } catch {
                showAlert(title: "Import Setup Failed", message: error.localizedDescription)
            }
            isBusy = false
            render()
        }
    }

    private func validateSourceStep() -> Bool {
        guard options.sourceURL != nil else {
            showAlert(title: "Select Source", message: "Choose a source before continuing.")
            return false
        }
        if options.matchStrategy == .rowParity, rowStartField.integerValue < 1 {
            showAlert(title: "Invalid Start Row", message: "Start row must be 1 or greater.")
            return false
        }
        if options.matchStrategy == .rowParity, rowCountField.integerValue < 0 {
            showAlert(title: "Invalid Row Count", message: "Row count cannot be negative.")
            return false
        }
        return true
    }

    private func applySelectionDrivenDefaults() {
        guard let model else { return }
        let selectedCount = model.selectedFileURLs.count
        options.scope = selectedCount > 0 ? .selection : .folder
        if options.matchStrategy == .rowParity {
            options.rowParityStartRow = max(1, options.rowParityStartRow)
            options.rowParityRowCount = selectedCount > 0 ? selectedCount : options.rowParityRowCount
        }
    }

    private func currentScopeSummaryText() -> String {
        guard let model else { return "No targets" }
        let count = model.importTargetFiles(for: options.scope).count
        switch options.scope {
        case .selection:
            return "Selection (\(count) image\(count == 1 ? "" : "s"))"
        case .folder:
            return "Folder (\(count) image\(count == 1 ? "" : "s"))"
        }
    }

    private func sourceSummaryText() -> String {
        switch options.sourceKind {
        case .gpx:
            var urls: [URL] = []
            if let primary = options.sourceURL {
                urls.append(primary)
            }
            urls.append(contentsOf: options.auxiliaryURLs)
            guard let first = urls.first else { return "No source selected" }
            if urls.count == 1 {
                return first.path
            }
            return "\(urls.count) GPX files selected (first: \(first.lastPathComponent))"
        default:
            return options.sourceURL?.path ?? "No source selected"
        }
    }

    private func applyConflictResolution(
        _ resolution: ImportConflictResolutionChoice,
        to chooser: NSComboBox,
        conflict: ImportConflict
    ) {
        switch resolution {
        case .skip:
            let index = chooser.objectValues.firstIndex(where: { String(describing: $0) == "Skip row" }) ?? -1
            if index >= 0 {
                chooser.selectItem(at: index)
            }
        case let .target(url):
            let index = chooser.objectValues.firstIndex(where: { String(describing: $0) == url.path }) ?? -1
            if index >= 0 {
                chooser.selectItem(at: index)
            } else if conflict.candidateTargets.isEmpty {
                chooser.selectItem(at: max(chooser.numberOfItems - 1, 0))
            }
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
