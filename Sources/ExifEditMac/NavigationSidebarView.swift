import AppKit
import SwiftUI

struct NavigationSidebarView: View {
    @ObservedObject var model: AppModel
    @State private var collapsedSections: Set<String> = []
    @State private var hoveredSection: String?
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isSidebarFocused: Bool

    var body: some View {
        List(selection: $model.selectedSidebarID) {
            ForEach(model.sidebarSectionOrder, id: \.self) { section in
                let sectionItems = model.sidebarItems.filter { $0.section == section }
                if !sectionItems.isEmpty {
                    Section {
                        if !collapsedSections.contains(section) {
                            ForEach(sectionItems) { item in
                                Group {
                                    if hasSidebarActions(item) {
                                        sidebarRow(item)
                                            .contextMenu {
                                                // Reset tint so SF Symbol images render in label
                                                // colour, not the inherited accent tint.
                                                sidebarContextMenu(for: item)
                                                    .tint(Color.primary)
                                            }
                                    } else {
                                        sidebarRow(item)
                                    }
                                }
                                .task(id: item.id) {
                                    guard model.shouldEagerlyLoadSidebarImageCount(for: item) else { return }
                                    model.ensureSidebarImageCount(for: item)
                                }
                            }
                        }
                    } header: {
                        sidebarSectionHeader(section)
                    }
                }
            }
        }
        .animation(appAnimation(), value: collapsedSections)
        .listStyle(.sidebar)
        .frame(maxHeight: .infinity)
        .focused($isSidebarFocused)
        .onReceive(NotificationCenter.default.publisher(for: .sidebarDidRequestFocus)) { _ in
            isSidebarFocused = true
        }
        .onChange(of: model.selectedSidebarID) { oldValue, newValue in
            // Capture the triggering event synchronously while it is still current.
            // NSApp.currentEvent will be nil or stale by the time the deferred Task runs,
            // breaking the isLikelyUserInitiatedSidebarChange() check (causes Desktop /
            // Downloads to flicker and revert on user click).
            let triggerEvent = NSApp.currentEvent
            // Defer out of the SwiftUI update cycle. Calling handleSidebarSelectionChange
            // synchronously here causes B14: clearLoadedContentState + loadFiles mutate
            // @Published properties (browserItems → filteredBrowserItems) from within
            // the SwiftUI transaction, which triggers "Publishing changes from within
            // view updates is not allowed" and downstream NSHostingView reentrant layout.
            Task { @MainActor in
                model.handleSidebarSelectionChange(from: oldValue, to: newValue, triggerEvent: triggerEvent)
            }
        }
    }

    private func icon(for kind: AppModel.SidebarKind) -> String {
        switch kind {
        case .pictures:
            return "photo"
        case .desktop:
            return "menubar.dock.rectangle"
        case .downloads:
            return "arrow.down.circle"
        case .mountedVolume:
            return "externaldrive"
        case .favorite:
            return "pin"
        case .folder:
            return "folder"
        }
    }

    private func hasSidebarActions(_ item: AppModel.SidebarItem) -> Bool {
        model.canPinSidebarItem(item)
            || model.canUnpinSidebarItem(item)
            || model.canMoveFavoriteUp(item)
            || model.canMoveFavoriteDown(item)
    }

    @ViewBuilder
    private func sidebarRow(_ item: AppModel.SidebarItem) -> some View {
        let isSelected = model.selectedSidebarID == item.id
        let isInactiveSelected = isSelected && !isSidebarFocused
        let row = HStack(spacing: UIMetrics.Sidebar.rowSpacing) {
            Image(systemName: icon(for: item.kind))
                .font(.system(size: UIMetrics.Sidebar.rowIconSize))
                .frame(width: UIMetrics.Sidebar.rowLeadingIconFrame, alignment: .center)
            Text(item.title)
        }
        .padding(.leading, UIMetrics.Sidebar.sectionItemIndent)
        .tag(item.id)
        .badge(model.sidebarImageCountText(for: item).map { Text($0) })

        if isInactiveSelected {
            row.foregroundStyle(Color.accentColor)
        } else {
            row
        }
    }

    private func sidebarSectionHeader(_ section: String) -> some View {
        Button {
            toggleSection(section)
        } label: {
            Text(section)
                .font(.system(size: UIMetrics.Sidebar.headerFontSize, weight: .semibold))
                .foregroundStyle(sidebarHeaderColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .trailing) {
                    Image(systemName: collapsedSections.contains(section) ? "chevron.right" : "chevron.down")
                        .font(.system(size: UIMetrics.Sidebar.headerFontSize, weight: .semibold))
                        .foregroundStyle(sidebarHeaderColor)
                        .opacity(hoveredSection == section ? 1 : 0)
                        .frame(width: UIMetrics.Sidebar.trailingColumnWidth, height: UIMetrics.Sidebar.headerChevronFrameHeight, alignment: .trailing)
                        .contentShape(Rectangle())
                        .padding(.trailing, UIMetrics.Sidebar.trailingColumnInset)
                }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { isHovering in
            hoveredSection = isHovering ? section : nil
        }
    }

    private func toggleSection(_ section: String) {
        var t = Transaction(animation: appAnimation())
        if reduceMotion { t.disablesAnimations = true }
        withTransaction(t) {
            if collapsedSections.contains(section) {
                collapsedSections.remove(section)
            } else {
                collapsedSections.insert(section)
            }
        }
    }

    private var sidebarHeaderColor: Color {
        controlActiveState == .key
            ? Color(nsColor: .secondaryLabelColor)
            : Color(nsColor: .disabledControlTextColor)
    }

    @ViewBuilder
    private func sidebarContextMenu(for item: AppModel.SidebarItem) -> some View {
        if model.canOpenSidebarItemInFinder(item) {
            Button {
                model.openSidebarItemInFinder(item)
            } label: {
                Label("Open in Finder", systemImage: "folder")
            }
        }

        if model.canPinSidebarItem(item) {
            if model.canOpenSidebarItemInFinder(item) {
                Divider()
            }
            Button {
                model.pinSidebarItem(item)
            } label: {
                Label("Pin", systemImage: "pin")
            }
        }

        if model.canUnpinSidebarItem(item) {
            Button {
                model.unpinSidebarItem(item)
            } label: {
                Label("Unpin Pinned", systemImage: "pin.slash")
            }

            if model.canMoveFavoriteUp(item) || model.canMoveFavoriteDown(item) {
                Divider()
            }

            Button {
                model.moveFavoriteUp(item)
            } label: {
                Label("Move Pinned Up", systemImage: "arrow.up")
            }
            .disabled(!model.canMoveFavoriteUp(item))

            Button {
                model.moveFavoriteDown(item)
            } label: {
                Label("Move Pinned Down", systemImage: "arrow.down")
            }
            .disabled(!model.canMoveFavoriteDown(item))
        }
    }
}
