import Foundation
import SharedUI

/// Manages show-once logic for the welcome / What's New screen.
/// Compares major.minor version only — patch releases do not re-trigger the screen.
enum WelcomeCoordinator {
    private static let lastSeenKey = "\(AppBrand.identifierPrefix).welcomeLastSeenVersion"

    /// True on first run and when the app's major.minor version has changed since last seen.
    static var shouldShowOnLaunch: Bool {
        guard let stored = UserDefaults.standard.string(forKey: lastSeenKey) else { return true }
        return stored != minorVersion
    }

    /// Record the current version as seen. Call after the welcome screen is dismissed.
    static func markSeen() {
        UserDefaults.standard.set(minorVersion, forKey: lastSeenKey)
    }

    /// major.minor string derived from CFBundleShortVersionString (e.g. "1.2" from "1.2.3").
    private static var minorVersion: String {
        let full = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let parts = full.split(separator: ".").prefix(2)
        return parts.joined(separator: ".")
    }
}
