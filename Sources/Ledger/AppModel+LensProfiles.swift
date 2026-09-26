import AppKit
import LedgerCore
import Foundation

@MainActor
extension AppModel {
    func loadLensProfiles() {
        do {
            lensProfiles = try lensProfileStore.loadLensProfiles().sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        } catch MetadataEditError.lensProfileSchemaVersionTooNew {
            lensProfiles = []
            Task { @MainActor in
                let alert = NSAlert()
                alert.messageText = "Lenses saved by a newer version"
                alert.informativeText = "Your lens list was saved by a newer version of \(AppBrand.displayName) and can't be read. Update \(AppBrand.displayName) to access it."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runSheetOrModal(for: nil) { _ in }
            }
        } catch {
            lensProfiles = []
        }
    }

    @discardableResult
    func createLensProfile(_ profile: LensProfile) -> LensProfile? {
        let trimmedName = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }
        var normalized = profile
        normalized.name = trimmedName
        lensProfiles.append(normalized)
        sortLensProfiles()
        persistLensProfiles()
        return normalized
    }

    @discardableResult
    func updateLensProfile(_ profile: LensProfile) -> LensProfile? {
        guard let index = lensProfiles.firstIndex(where: { $0.id == profile.id }) else { return nil }
        let trimmedName = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }
        var normalized = profile
        normalized.name = trimmedName
        normalized.updatedAt = Date()
        lensProfiles[index] = normalized
        sortLensProfiles()
        persistLensProfiles()
        return normalized
    }

    @discardableResult
    func duplicateLensProfile(id: UUID) -> LensProfile? {
        guard let profile = lensProfiles.first(where: { $0.id == id }) else { return nil }
        let now = Date()
        let duplicate = LensProfile(
            id: UUID(),
            name: "\(profile.name) Copy",
            kind: profile.kind,
            minFocalLengthMM: profile.minFocalLengthMM,
            maxFocalLengthMM: profile.maxFocalLengthMM,
            widestApertureAtMinFocal: profile.widestApertureAtMinFocal,
            widestApertureAtMaxFocal: profile.widestApertureAtMaxFocal,
            notes: profile.notes,
            createdAt: now,
            updatedAt: now
        )
        return createLensProfile(duplicate)
    }

    func deleteLensProfile(id: UUID) {
        let previousCount = lensProfiles.count
        lensProfiles.removeAll { $0.id == id }
        guard lensProfiles.count != previousCount else { return }
        persistLensProfiles()
    }

    private func sortLensProfiles() {
        lensProfiles.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func persistLensProfiles() {
        try? lensProfileStore.saveLensProfiles(lensProfiles)
    }
}
