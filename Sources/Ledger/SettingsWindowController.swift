import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    private let tabsController: SettingsTabViewController
    private let contentWidth: CGFloat = 620

    init(model: AppModel) {
        tabsController = SettingsTabViewController(model: model)
        let window = NSWindow(contentViewController: tabsController)
        window.title = "General"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: contentWidth, height: 320))
        window.minSize = NSSize(width: contentWidth, height: 280)
        window.maxSize = NSSize(width: contentWidth, height: 1200)
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        super.init(window: window)
        tabsController.refreshWindowForSelectedTab(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showWindowAndActivate() {
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
private final class SettingsTabViewController: NSTabViewController {
    private weak var model: AppModel?
    private let generalHeight: CGFloat = 320
    private let inspectorHeight: CGFloat = 620

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let model else { return }

        let general = NSHostingController(rootView: GeneralSettingsView(model: model))
        let generalItem = NSTabViewItem(viewController: general)
        generalItem.label = "General"
        generalItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "General")

        let inspector = NSHostingController(rootView: InspectorSettingsView(model: model))
        let inspectorItem = NSTabViewItem(viewController: inspector)
        inspectorItem.label = "Inspector"
        inspectorItem.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Inspector")

        addTabViewItem(generalItem)
        addTabViewItem(inspectorItem)
        selectedTabViewItemIndex = 0
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        refreshWindowForSelectedTab(animated: false)
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        refreshWindowForSelectedTab(animated: true)
    }

    func refreshWindowForSelectedTab(animated: Bool) {
        guard let window = view.window else { return }
        let selected = tabViewItems.indices.contains(selectedTabViewItemIndex) ? tabViewItems[selectedTabViewItemIndex] : nil
        window.title = selected?.label ?? "Settings"

        let targetContentHeight: CGFloat
        switch selected?.label {
        case "Inspector":
            targetContentHeight = inspectorHeight
        default:
            targetContentHeight = generalHeight
        }

        let frame = window.frame
        let currentContentRect = window.contentRect(forFrameRect: frame)
        let delta = targetContentHeight - currentContentRect.height
        guard abs(delta) > 0.5 else { return }

        var targetFrame = frame
        targetFrame.size.height += delta
        targetFrame.origin.y -= delta
        window.setFrame(targetFrame, display: true, animate: animated)
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Toggle("Confirm before Apply", isOn: Binding(
                get: { model.confirmBeforeApply },
                set: { value in
                    DispatchQueue.main.async {
                        model.confirmBeforeApply = value
                    }
                }
            ))

            Toggle("Auto-refresh metadata after Apply", isOn: Binding(
                get: { model.autoRefreshMetadataAfterApply },
                set: { value in
                    DispatchQueue.main.async {
                        model.autoRefreshMetadataAfterApply = value
                    }
                }
            ))

            Toggle("Keep backups", isOn: Binding(
                get: { model.keepBackups },
                set: { value in
                    DispatchQueue.main.async {
                        model.keepBackups = value
                    }
                }
            ))
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct InspectorSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(model.inspectorFieldSections, id: \.section) { grouped in
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(grouped.section, isOn: Binding(
                            get: { model.isInspectorSectionEnabled(grouped.section) },
                            set: { value in
                                DispatchQueue.main.async {
                                    model.setInspectorSectionEnabled(section: grouped.section, isEnabled: value)
                                }
                            }
                        ))
                        .font(.headline)

                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(grouped.fields, id: \.id) { field in
                                Toggle(field.label, isOn: Binding(
                                    get: { model.isInspectorFieldEnabled(field.id) },
                                    set: { value in
                                        DispatchQueue.main.async {
                                            model.setInspectorFieldEnabled(fieldID: field.id, isEnabled: value)
                                        }
                                    }
                                ))
                            }
                        }
                        .padding(.leading, 18)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
