import Foundation
import ExifEditCore

@MainActor
extension AppModel {
    var sidebarSectionOrder: [String] {
        ["Sources", "Pinned", "Recents"]
    }

    func noteRecentLocation(
        _ url: URL,
        titleOverride: String? = nil,
        promoteToTopIfExisting: Bool = false
    ) -> SidebarItem? {
        guard let canonical = canonicalSidebarURL(url) else {
            return nil
        }
        if let sourceItem = sourceSidebarItem(forCanonicalURL: canonical) {
            removeRecentLocation(forCanonicalURL: canonical)
            persistRecentLocations()
            refreshSidebarItems(preferredSelectionID: sourceItem.id)
            return sourceItem
        }
        if let pinnedItem = favoriteSidebarItem(forCanonicalURL: canonical) {
            removeRecentLocation(forCanonicalURL: canonical)
            persistRecentLocations()
            refreshSidebarItems(preferredSelectionID: pinnedItem.id)
            return pinnedItem
        }
        if let mountedItem = mountedVolumeSidebarItem(forCanonicalURL: canonical) {
            removeRecentLocation(forCanonicalURL: canonical)
            persistRecentLocations()
            refreshSidebarItems(preferredSelectionID: mountedItem.id)
            return mountedItem
        }

        let id = "folder::\(canonical.path)"
        let title = titleOverride ?? canonical.lastPathComponent
        var didMutateRecentLocations = false
        let now = Date()

        if let existingIndex = locationItems.firstIndex(where: { $0.id == id }) {
            let existing = locationItems[existingIndex]
            if existing.title != title {
                locationItems[existingIndex] = SidebarItem(id: id, title: title, section: "Recents", kind: .folder(canonical))
                didMutateRecentLocations = true
            }
            if promoteToTopIfExisting, existingIndex > 0 {
                let item = locationItems.remove(at: existingIndex)
                locationItems.insert(item, at: 0)
                didMutateRecentLocations = true
            }
            recentLocationLastOpenedAtByID[id] = now
        } else {
            // Keep insertion order stable by recording first-seen time once.
            recentLocationLastOpenedAtByID[id] = now
            locationItems.append(
                SidebarItem(id: id, title: title, section: "Recents", kind: .folder(canonical))
            )
            trimRecentLocationsToLimit()
            didMutateRecentLocations = true
        }

        if didMutateRecentLocations {
            persistRecentLocations()
            refreshSidebarItems(preferredSelectionID: id)
        } else {
            // Persist recency changes without changing in-session order.
            persistRecentLocations()
        }
        return locationItems.first(where: { $0.id == id })
    }

    var canPinSelectedSidebarLocation: Bool {
        guard let selectedSidebarItem else { return false }
        switch selectedSidebarItem.kind {
        case .pictures, .desktop, .downloads, .mountedVolume, .folder:
            return true
        case .favorite:
            return false
        }
    }

    var canUnpinSelectedSidebarLocation: Bool {
        guard let selectedSidebarItem else { return false }
        if case .favorite = selectedSidebarItem.kind {
            return true
        }
        return false
    }

    var canMoveSelectedFavoriteUp: Bool {
        guard let selectedSidebarItem,
              case let .favorite(url) = selectedSidebarItem.kind,
              let index = favoriteItems.firstIndex(where: { item in
                  if case let .favorite(candidateURL) = item.kind {
                      return candidateURL == url
                  }
                  return false
              })
        else { return false }
        return index > 0
    }

    var canMoveSelectedFavoriteDown: Bool {
        guard let selectedSidebarItem,
              case let .favorite(url) = selectedSidebarItem.kind,
              let index = favoriteItems.firstIndex(where: { item in
                  if case let .favorite(candidateURL) = item.kind {
                      return candidateURL == url
                  }
                  return false
              })
        else { return false }
        return index < favoriteItems.count - 1
    }

    func pinSelectedSidebarLocationToFavorites() {
        guard let selectedSidebarItem else { return }
        switch selectedSidebarItem.kind {
        case .pictures:
            pinFavorite(url: picturesDirectoryURL(), title: "Pictures")
        case .desktop:
            pinFavorite(url: desktopDirectoryURL(), title: "Desktop")
        case .downloads:
            pinFavorite(url: downloadsDirectoryURL(), title: "Downloads")
        case let .mountedVolume(url):
            pinFavorite(url: url, title: selectedSidebarItem.title)
        case let .folder(url):
            pinFavorite(url: url, title: selectedSidebarItem.title)
        case .favorite:
            return
        }
    }

    func unpinSelectedSidebarFavorite() {
        guard let selectedSidebarItem,
              case let .favorite(url) = selectedSidebarItem.kind
        else {
            return
        }
        let neighborSelectionID = favoriteNeighborSelectionID(removingFavoriteURL: url)
        favoriteItems.removeAll { item in
            if case let .favorite(candidateURL) = item.kind {
                return candidateURL == url
            }
            return false
        }
        persistFavorites()
        refreshSidebarItems(preferredSelectionID: neighborSelectionID)
    }

    func moveSelectedFavoriteUp() {
        moveSelectedFavorite(offset: -1)
    }

    func moveSelectedFavoriteDown() {
        moveSelectedFavorite(offset: 1)
    }

    func canPinSidebarItem(_ item: SidebarItem) -> Bool {
        switch item.kind {
        case .pictures, .desktop, .downloads, .mountedVolume, .folder:
            return true
        case .favorite:
            return false
        }
    }

    func canUnpinSidebarItem(_ item: SidebarItem) -> Bool {
        if case .favorite = item.kind {
            return true
        }
        return false
    }

    func canRemoveRecentSidebarItem(_ item: SidebarItem) -> Bool {
        switch item.kind {
        case .folder, .favorite: return true
        default: return false
        }
    }

    func removeRecentSidebarItem(_ item: SidebarItem) {
        switch item.kind {
        case let .folder(url):
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            removeRecentLocation(forCanonicalURL: canonical)
            persistRecentLocations()
        case let .favorite(url):
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            favoriteItems.removeAll { candidate in
                guard case let .favorite(candidateURL) = candidate.kind else { return false }
                return candidateURL == url
            }
            persistFavorites()
            removeRecentLocation(forCanonicalURL: canonical)
            persistRecentLocations()
        default:
            return
        }
        refreshSidebarItems(selectFirstWhenMissing: false)
    }

    func clearRecentFolders() {
        locationItems.removeAll()
        recentLocationLastOpenedAtByID.removeAll()
        persistRecentLocations()
        refreshSidebarItems(selectFirstWhenMissing: false)
        setStatusMessage("Cleared recent folders.", autoClearAfterSuccess: true)
    }

    func canMoveFavoriteUp(_ item: SidebarItem) -> Bool {
        guard case let .favorite(url) = item.kind,
              let index = favoriteItems.firstIndex(where: { candidate in
                  if case let .favorite(candidateURL) = candidate.kind {
                      return candidateURL == url
                  }
                  return false
              })
        else { return false }
        return index > 0
    }

    func canMoveFavoriteDown(_ item: SidebarItem) -> Bool {
        guard case let .favorite(url) = item.kind,
              let index = favoriteItems.firstIndex(where: { candidate in
                  if case let .favorite(candidateURL) = candidate.kind {
                      return candidateURL == url
                  }
                  return false
              })
        else { return false }
        return index < favoriteItems.count - 1
    }

    func pinSidebarItem(_ item: SidebarItem) {
        switch item.kind {
        case .pictures:
            pinFavorite(url: picturesDirectoryURL(), title: "Pictures")
        case .desktop:
            pinFavorite(url: desktopDirectoryURL(), title: "Desktop")
        case .downloads:
            pinFavorite(url: downloadsDirectoryURL(), title: "Downloads")
        case let .mountedVolume(url):
            pinFavorite(url: url, title: item.title)
        case let .folder(url):
            pinFavorite(url: url, title: item.title)
        case .favorite:
            return
        }
    }

    func unpinSidebarItem(_ item: SidebarItem) {
        guard case let .favorite(url) = item.kind else { return }
        let wasSelected = selectedSidebarID == item.id
        let neighborSelectionID = favoriteNeighborSelectionID(removingFavoriteURL: url)
        favoriteItems.removeAll { candidate in
            if case let .favorite(candidateURL) = candidate.kind {
                return candidateURL == url
            }
            return false
        }
        persistFavorites()

        // Restore to Recents if it's a plain user folder (was moved out of Recents when pinned).
        var restoredRecentID: String? = nil
        if let canonical = canonicalSidebarURL(url),
           sourceSidebarItem(forCanonicalURL: canonical) == nil,
           mountedVolumeSidebarItem(forCanonicalURL: canonical) == nil {
            let recentID = "folder::\(canonical.path)"
            if !locationItems.contains(where: { $0.id == recentID }) {
                recentLocationLastOpenedAtByID[recentID] = Date()
                locationItems.insert(
                    SidebarItem(id: recentID, title: item.title, section: "Recents", kind: .folder(canonical)),
                    at: 0
                )
                trimRecentLocationsToLimit()
                persistRecentLocations()
                restoredRecentID = recentID
            }
        }

        // Choose landing selection:
        // - Unpinned item was selected: prefer adjacent favourite → restored Recent → nil (no folder)
        // - Unpinned item was not selected: keep whatever is currently selected
        let preferredSelectionID: String? = wasSelected
            ? (neighborSelectionID ?? restoredRecentID)
            : selectedSidebarID

        let priorSelectedID = selectedSidebarID
        // selectFirstWhenMissing: false — don't silently jump to Desktop/Downloads when nothing fits.
        refreshSidebarItems(selectFirstWhenMissing: false, preferredSelectionID: preferredSelectionID)

        // Always sync browser content to the sidebar selection if it changed.
        if selectedSidebarID != priorSelectedID {
            selectSidebar(id: selectedSidebarID)
        }
    }

    func moveFavoriteUp(_ item: SidebarItem) {
        moveFavorite(item, offset: -1)
    }

    func moveFavoriteDown(_ item: SidebarItem) {
        moveFavorite(item, offset: 1)
    }

    private func baseSidebarItems() -> [SidebarItem] {
        var items: [SidebarItem] = [
            SidebarItem(id: "source-desktop", title: "Desktop", section: "Sources", kind: .desktop),
            SidebarItem(id: "source-downloads", title: "Downloads", section: "Sources", kind: .downloads),
            SidebarItem(id: "source-pictures", title: "Pictures", section: "Sources", kind: .pictures)
        ]
        items.append(contentsOf: mountedVolumeSidebarItems())
        return items
    }

    func composedSidebarItems() -> [SidebarItem] {
        baseSidebarItems() + favoriteItems + locationItems
    }

    func refreshSidebarItems(selectFirstWhenMissing: Bool = true, preferredSelectionID: String? = nil) {
        let priorSelection = selectedSidebarID
        sidebarItems = composedSidebarItems()
        reconcileSidebarImageCountState()
        if let preferredSelectionID, sidebarItems.contains(where: { $0.id == preferredSelectionID }) {
            selectedSidebarID = preferredSelectionID
        } else if let priorSelection, sidebarItems.contains(where: { $0.id == priorSelection }) {
            selectedSidebarID = priorSelection
        } else if selectFirstWhenMissing {
            selectedSidebarID = sidebarItems.first?.id
        } else {
            selectedSidebarID = nil
        }
    }

    private func warmSidebarImageCounts(includePrivacySensitive: Bool = false) {
        for item in sidebarItems {
            if !includePrivacySensitive, isPrivacySensitiveSidebarKind(item.kind) {
                continue
            }
            ensureSidebarImageCount(for: item)
        }
    }

    func isFolderNotFoundError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSCocoaErrorDomain else { return false }
        return nsError.code == NSFileNoSuchFileError || nsError.code == NSFileReadNoSuchFileError
    }

    func isPrivacySensitiveFileSystemURL(_ url: URL) -> Bool {
        let candidate = url.standardizedFileURL
        let desktop = desktopDirectoryURL().standardizedFileURL
        let downloads = downloadsDirectoryURL().standardizedFileURL
        return isWithinOrSame(candidate, root: desktop) || isWithinOrSame(candidate, root: downloads)
    }

    func isPrivacySensitiveSidebarKind(_ kind: SidebarKind) -> Bool {
        switch kind {
        case .desktop, .downloads:
            return true
        case let .favorite(url), let .folder(url), let .mountedVolume(url):
            return isPrivacySensitiveFileSystemURL(url)
        case .pictures:
            return false
        }
    }

    private func isWithinOrSame(_ url: URL, root: URL) -> Bool {
        let candidatePath = url.standardizedFileURL.path
        var rootPath = root.standardizedFileURL.path
        if !rootPath.hasSuffix("/") {
            rootPath.append("/")
        }
        return candidatePath == root.standardizedFileURL.path || candidatePath.hasPrefix(rootPath)
    }

    func canonicalSidebarURL(_ url: URL, validateExistence: Bool = true) -> URL? {
        let standardized = url.standardizedFileURL
        if !validateExistence {
            // Startup/background paths for privacy-sensitive locations should avoid
            // filesystem probes to prevent TCC prompts before explicit user intent.
            return standardized
        }
        let resolved = standardized.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: resolved.path)
        else {
            return nil
        }
        return resolved
    }

    private func pinFavorite(url: URL, title: String) {
        guard let canonical = canonicalSidebarURL(url) else {
            statusMessage = "Couldn’t pin this location."
            return
        }
        let id = "favorite::\(canonical.path)"
        guard !favoriteItems.contains(where: { $0.id == id }) else {
            statusMessage = "This location is already pinned."
            return
        }

        favoriteItems.append(
            SidebarItem(
                id: id,
                title: title,
                section: "Pinned",
                kind: .favorite(canonical)
            )
        )
        removeRecentLocation(forCanonicalURL: canonical)
        persistFavorites()
        persistRecentLocations()

        // If the pinned item was selected (as a Recent: “folder::”), follow it to the new
        // favourite ID (“favorite::”) — same physical folder, no reload needed.
        // If a different item was selected, keep the current selection unchanged.
        let folderID = "folder::\(canonical.path)"
        let wasSelected = selectedSidebarID == folderID || selectedSidebarID == id
        refreshSidebarItems(preferredSelectionID: wasSelected ? id : selectedSidebarID)
        statusMessage = "“\(title)” added to Pinned."
    }

    private func moveSelectedFavorite(offset: Int) {
        guard let selectedSidebarItem,
              case let .favorite(url) = selectedSidebarItem.kind,
              let index = favoriteItems.firstIndex(where: { item in
                  if case let .favorite(candidateURL) = item.kind {
                      return candidateURL == url
                  }
                  return false
              })
        else {
            return
        }

        let nextIndex = index + offset
        guard favoriteItems.indices.contains(nextIndex) else { return }
        let item = favoriteItems.remove(at: index)
        favoriteItems.insert(item, at: nextIndex)
        persistFavorites()
        refreshSidebarItems()
        selectedSidebarID = item.id
    }

    private func moveFavorite(_ item: SidebarItem, offset: Int) {
        guard case let .favorite(url) = item.kind,
              let index = favoriteItems.firstIndex(where: { candidate in
                  if case let .favorite(candidateURL) = candidate.kind {
                      return candidateURL == url
                  }
                  return false
              })
        else {
            return
        }

        let nextIndex = index + offset
        guard favoriteItems.indices.contains(nextIndex) else { return }
        let movingItem = favoriteItems.remove(at: index)
        favoriteItems.insert(movingItem, at: nextIndex)
        persistFavorites()
        refreshSidebarItems()
        selectedSidebarID = movingItem.id
    }

    private func favoriteNeighborSelectionID(removingFavoriteURL url: URL) -> String? {
        guard let index = favoriteItems.firstIndex(where: { candidate in
            if case let .favorite(candidateURL) = candidate.kind {
                return candidateURL == url
            }
            return false
        })
        else {
            return nil
        }

        if favoriteItems.indices.contains(index + 1) {
            return favoriteItems[index + 1].id
        }
        if favoriteItems.indices.contains(index - 1) {
            return favoriteItems[index - 1].id
        }
        return nil
    }

    func reconcileAndLoadFavorites() {
        do {
            let stored = try favoritesStore.loadFavorites()
            var normalized: [SidebarItem] = []
            for favorite in stored.sorted(by: { $0.order < $1.order }) {
                let url = URL(fileURLWithPath: favorite.path)
                let shouldValidate = !isPrivacySensitiveFileSystemURL(url)
                guard let canonical = canonicalSidebarURL(url, validateExistence: shouldValidate) else { continue }
                let id = "favorite::\(canonical.path)"
                if normalized.contains(where: { $0.id == id }) {
                    continue
                }
                normalized.append(
                    SidebarItem(
                        id: id,
                        title: favorite.displayName,
                        section: "Pinned",
                        kind: .favorite(canonical)
                    )
                )
            }
            favoriteItems = normalized
            persistFavorites()
        } catch {
            favoriteItems = []
            statusMessage = "Couldn’t load pinned locations. \(error.localizedDescription)"
        }
    }

    func persistFavorites() {
        let records: [SidebarFavorite] = favoriteItems.enumerated().compactMap { index, item in
            guard case let .favorite(url) = item.kind else { return nil }
            return SidebarFavorite(path: url.path, displayName: item.title, order: index)
        }
        do {
            try favoritesStore.saveFavorites(records)
        } catch {
            statusMessage = "Couldn’t save pinned locations. \(error.localizedDescription)"
        }
    }

    func reconcileAndLoadRecentLocations() {
        do {
            let stored = try recentLocationsStore.loadRecentLocations()
            var normalized: [(item: SidebarItem, order: Int)] = []
            var openedByID: [String: Date] = [:]
            for location in stored.sorted(by: { $0.order < $1.order }) {
                let url = URL(fileURLWithPath: location.path)
                let shouldValidate = !isPrivacySensitiveFileSystemURL(url)
                guard let canonical = canonicalSidebarURL(url, validateExistence: shouldValidate) else { continue }
                let id = "folder::\(canonical.path)"
                if normalized.contains(where: { $0.item.id == id }) {
                    continue
                }
                let item = SidebarItem(
                        id: id,
                        title: location.displayName,
                        section: "Recents",
                        kind: .folder(canonical)
                    )
                normalized.append((item: item, order: location.order))
                if let opened = location.lastOpenedAt {
                    openedByID[id] = opened
                }
                if normalized.count == Self.maxRecentLocations {
                    break
                }
            }
            locationItems = normalized
                .sorted { lhs, rhs in
                    let lhsOpened = openedByID[lhs.item.id] ?? .distantPast
                    let rhsOpened = openedByID[rhs.item.id] ?? .distantPast
                    if lhsOpened != rhsOpened {
                        return lhsOpened > rhsOpened
                    }
                    return lhs.order < rhs.order
                }
                .map(\.item)
            recentLocationLastOpenedAtByID = openedByID
            persistRecentLocations()
        } catch {
            locationItems = []
            recentLocationLastOpenedAtByID = [:]
            statusMessage = "Couldn’t load recent locations. \(error.localizedDescription)"
        }
    }

    func persistRecentLocations() {
        let records: [RecentLocation] = locationItems.enumerated().compactMap { index, item in
            guard case let .folder(url) = item.kind else { return nil }
            return RecentLocation(
                path: url.path,
                displayName: item.title,
                order: index,
                lastOpenedAt: recentLocationLastOpenedAtByID[item.id]
            )
        }
        do {
            try recentLocationsStore.saveRecentLocations(records)
        } catch {
            statusMessage = "Couldn’t save recent locations. \(error.localizedDescription)"
        }
    }

    private func trimRecentLocationsToLimit() {
        guard locationItems.count > Self.maxRecentLocations else { return }
        while locationItems.count > Self.maxRecentLocations {
            // Remove the oldest inserted entry to keep order stable.
            let removedID = locationItems.removeFirst().id
            recentLocationLastOpenedAtByID[removedID] = nil
        }
    }

    private func favoriteSidebarItem(forCanonicalURL canonical: URL) -> SidebarItem? {
        favoriteItems.first { item in
            guard case let .favorite(url) = item.kind else { return false }
            return url.standardizedFileURL.resolvingSymlinksInPath().path == canonical.path
        }
    }

    private func sourceSidebarItem(forCanonicalURL canonical: URL) -> SidebarItem? {
        let pictures = picturesDirectoryURL().standardizedFileURL.resolvingSymlinksInPath().path
        if canonical.path == pictures {
            return SidebarItem(id: "source-pictures", title: "Pictures", section: "Sources", kind: .pictures)
        }

        let desktop = desktopDirectoryURL().standardizedFileURL.resolvingSymlinksInPath().path
        if canonical.path == desktop {
            return SidebarItem(id: "source-desktop", title: "Desktop", section: "Sources", kind: .desktop)
        }

        let downloads = downloadsDirectoryURL().standardizedFileURL.resolvingSymlinksInPath().path
        if canonical.path == downloads {
            return SidebarItem(id: "source-downloads", title: "Downloads", section: "Sources", kind: .downloads)
        }

        return nil
    }

    private func mountedVolumeSidebarItem(forCanonicalURL canonical: URL) -> SidebarItem? {
        mountedVolumeSidebarItems().first { item in
            guard case let .mountedVolume(url) = item.kind else { return false }
            return url.standardizedFileURL.resolvingSymlinksInPath().path == canonical.path
        }
    }

    @discardableResult
    private func removeRecentLocation(forCanonicalURL canonical: URL) -> Bool {
        let before = locationItems.count
        locationItems.removeAll { item in
            guard case let .folder(url) = item.kind else { return false }
            return url.standardizedFileURL.resolvingSymlinksInPath().path == canonical.path
        }
        recentLocationLastOpenedAtByID.removeValue(forKey: "folder::\(canonical.path)")
        return locationItems.count != before
    }

    private func mountedVolumeSidebarItems() -> [SidebarItem] {
        let keys: [URLResourceKey] = [
            .volumeIsRemovableKey,
            .volumeIsEjectableKey,
            .volumeIsInternalKey,
            .volumeIsRootFileSystemKey,
            .volumeIsBrowsableKey,
            .volumeLocalizedNameKey,
            .nameKey
        ]
        let mounted = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []

        return mounted.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsRootFileSystem != true,
                  values.volumeIsBrowsable != false
            else {
                return nil
            }

            let isExternalLike = values.volumeIsInternal == false
                || values.volumeIsRemovable == true
                || values.volumeIsEjectable == true
            guard isExternalLike else { return nil }

            let title = values.volumeLocalizedName ?? values.name ?? url.lastPathComponent
            return SidebarItem(
                id: "volume::\(url.path)",
                title: title,
                section: "Sources",
                kind: .mountedVolume(url)
            )
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
}
