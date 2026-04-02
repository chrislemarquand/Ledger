import AppKit

extension Notification.Name {
    static let inspectorDidRequestBrowserFocus = Notification.Name("\(AppBrand.identifierPrefix).InspectorDidRequestBrowserFocus")
    static let inspectorDidRequestFieldNavigation = Notification.Name("\(AppBrand.identifierPrefix).InspectorDidRequestFieldNavigation")
    static let browserDidRequestFocus = Notification.Name("\(AppBrand.identifierPrefix).BrowserDidRequestFocus")
    static let browserDidSwitchViewMode = Notification.Name("\(AppBrand.identifierPrefix).BrowserDidSwitchViewMode")
}

enum UIMetrics {
    enum Sidebar {
        static let sectionItemIndent: CGFloat = 11
        static let trailingColumnWidth: CGFloat = 28
        static let trailingColumnInset: CGFloat = 6
        static let topControlYOffset: CGFloat = -30
        static let rowIconSize: CGFloat = 15
        static let rowLeadingIconFrame: CGFloat = 16
        static let rowSpacing: CGFloat = 7
        static let headerFontSize: CGFloat = 11
        static let headerChevronFrameHeight: CGFloat = 22
        static let topControlGlyphSize: CGFloat = 16
        static let topControlFrameSize: CGFloat = 24
    }

    enum List {
        static let rowHeight: CGFloat = 24
        static let cellHorizontalInset: CGFloat = 8
        static let iconSize: CGFloat = 16
        static let iconGap: CGFloat = 6
        static let pendingDotSize: CGFloat = 6
    }

    enum Gallery {
        static let thumbnailCornerRadius: CGFloat = 8
        static let pendingDotSize: CGFloat = 8
        static let pendingDotInset: CGFloat = 6
        static let titleGap: CGFloat = 6
    }
}
