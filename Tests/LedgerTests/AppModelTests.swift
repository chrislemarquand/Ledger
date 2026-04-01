import ExifEditCore
@testable import ExifEditMac
import AppKit
import Foundation
import XCTest

@MainActor
final class AppModelTests: XCTestCase {
    func testImportTagCatalogMirrorsGroupedEditableTags() {
        let model = makeModel()
        let groupedIDs = model.orderedEditableTagSections.flatMap(\.tags).map(\.id)
        let catalogIDs = model.importTagCatalog.map(\.id)
        XCTAssertEqual(groupedIDs, catalogIDs)
    }

    func testDefaultFieldCatalogStartsWithRatingPickAndLabel() {
        let entries = AppModel.defaultFieldCatalogEntries()

        XCTAssertEqual(entries.prefix(3).map(\.id), ["xmp-rating", "xmp-pick", "xmp-label"])
        XCTAssertTrue(entries.prefix(3).allSatisfy(\.isEnabled))
        XCTAssertEqual(entries.prefix(3).map(\.section), ["Rating", "Rating", "Rating"])
    }

    func testDefaultFieldCatalogAssignsExpectedInputKindsAndVisibility() {
        let byID = Dictionary(uniqueKeysWithValues: AppModel.defaultFieldCatalogEntries().map { ($0.id, $0) })

        XCTAssertEqual(byID["datetime-created"]?.inputKind, .dateTime)
        XCTAssertEqual(byID["exif-aperture"]?.inputKind, .decimal)
        XCTAssertEqual(byID["exif-gps-lat"]?.inputKind, .gpsCoordinate)
        XCTAssertEqual(byID["xmp-copyright-status"]?.inputKind, .boolean)
        XCTAssertEqual(byID["xmp-title"]?.inputKind, .text)

        if case let .enumChoice(choices)? = byID["exif-exposure-program"]?.inputKind {
            XCTAssertTrue(choices.contains(.init(value: "1", label: "Manual")))
            XCTAssertTrue(choices.contains(.init(value: "4", label: "Shutter Priority")))
        } else {
            XCTFail("Expected exif-exposure-program to use enumChoice input kind")
        }

        XCTAssertEqual(byID["iptc-city"]?.isEnabled, false)
        XCTAssertEqual(byID["xmp-headline"]?.isEnabled, false)
        XCTAssertEqual(byID["xmp-copyright-url"]?.isEnabled, false)
        XCTAssertEqual(byID["xmp-title"]?.isEnabled, true)
        XCTAssertEqual(byID["exif-make"]?.isEnabled, true)
    }

    func testOrderedEditableTagSectionsFollowFieldCatalogSectionOrder() {
        let model = makeModel()

        XCTAssertEqual(
            model.orderedEditableTagSections.map(\.section),
            ["Rating", "Camera", "Capture", "Date and Time", "Location", "Descriptive", "Rights"]
        )

        model.setInspectorFieldEnabled(fieldID: "xmp-credit", isEnabled: true)
        XCTAssertEqual(
            model.orderedEditableTagSections.map(\.section),
            ["Rating", "Camera", "Capture", "Date and Time", "Location", "Descriptive", "Editorial", "Rights"]
        )

        model.setInspectorSectionEnabled(section: "Editorial", isEnabled: false)

        XCTAssertFalse(model.orderedEditableTagSections.contains(where: { $0.section == "Editorial" }))
    }

    func testSidebarSectionOrderMatchesV1Sidebar() {
        let model = makeModel()
        XCTAssertEqual(model.sidebarSectionOrder, ["Sources", "Pinned", "Recents"])
    }

    func testSidebarStartsWithNoSelection() {
        let model = makeModel()
        XCTAssertNil(model.selectedSidebarID)
    }

    func testFavoriteReconciliationDropsInvalidPaths() throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let valid = temp.appendingPathComponent("valid", isDirectory: true)
        try FileManager.default.createDirectory(at: valid, withIntermediateDirectories: true)
        let missing = temp.appendingPathComponent("missing", isDirectory: true)

        let favoritesStore = InMemoryFavoritesStore(favorites: [
            SidebarFavorite(path: missing.path, displayName: "Missing", order: 0),
            SidebarFavorite(path: valid.path, displayName: "Valid", order: 1)
        ])

        let model = makeModel(favoritesStore: favoritesStore)
        let favorites = model.sidebarItems.filter { $0.section == "Pinned" }

        XCTAssertEqual(favorites.count, 1)
        XCTAssertEqual(favorites.first?.title, "Valid")
        XCTAssertEqual(favoritesStore.saved.last?.count, 1)
    }

    func testPinAndReorderFavorites() throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let a = temp.appendingPathComponent("A", isDirectory: true)
        let b = temp.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)

        let model = makeModel()
        model.pinSidebarItem(.init(id: "folder::\(a.path)", title: "A", section: "Recents", kind: .folder(a)))
        model.pinSidebarItem(.init(id: "folder::\(b.path)", title: "B", section: "Recents", kind: .folder(b)))

        var favorites = model.sidebarItems.filter { $0.section == "Pinned" }
        XCTAssertEqual(favorites.map(\.title), ["A", "B"])

        guard favorites.count == 2 else {
            XCTFail("Expected two favorites")
            return
        }

        model.moveFavoriteUp(favorites[1])
        favorites = model.sidebarItems.filter { $0.section == "Pinned" }
        XCTAssertEqual(favorites.map(\.title), ["B", "A"])
    }

    func testUnpinSelectedFavoriteSelectsAdjacentFavorite() throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let a = temp.appendingPathComponent("A", isDirectory: true)
        let b = temp.appendingPathComponent("B", isDirectory: true)
        let c = temp.appendingPathComponent("C", isDirectory: true)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: c, withIntermediateDirectories: true)

        let model = makeModel()
        model.pinSidebarItem(.init(id: "folder::\(a.path)", title: "A", section: "Recents", kind: .folder(a)))
        model.pinSidebarItem(.init(id: "folder::\(b.path)", title: "B", section: "Recents", kind: .folder(b)))
        model.pinSidebarItem(.init(id: "folder::\(c.path)", title: "C", section: "Recents", kind: .folder(c)))

        let favorites = model.sidebarItems.filter { $0.section == "Pinned" }
        guard favorites.count == 3 else {
            XCTFail("Expected three favorites")
            return
        }

        model.selectSidebar(id: favorites[1].id)
        model.unpinSidebarItem(favorites[1])

        let updatedFavorites = model.sidebarItems.filter { $0.section == "Pinned" }
        XCTAssertEqual(updatedFavorites.map(\.title), ["A", "C"])
        XCTAssertEqual(model.selectedSidebarID, updatedFavorites.last?.id)
    }

    func testFavoriteOrderPersistsAcrossRelaunch() throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let a = temp.appendingPathComponent("A", isDirectory: true)
        let b = temp.appendingPathComponent("B", isDirectory: true)
        let c = temp.appendingPathComponent("C", isDirectory: true)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: c, withIntermediateDirectories: true)

        let favoritesStore = InMemoryFavoritesStore()
        let firstLaunch = makeModel(favoritesStore: favoritesStore)
        firstLaunch.pinSidebarItem(.init(id: "folder::\(a.path)", title: "A", section: "Recents", kind: .folder(a)))
        firstLaunch.pinSidebarItem(.init(id: "folder::\(b.path)", title: "B", section: "Recents", kind: .folder(b)))
        firstLaunch.pinSidebarItem(.init(id: "folder::\(c.path)", title: "C", section: "Recents", kind: .folder(c)))

        var firstFavorites = firstLaunch.sidebarItems.filter { $0.section == "Pinned" }
        guard firstFavorites.count == 3 else {
            XCTFail("Expected three favorites")
            return
        }
        firstLaunch.moveFavoriteUp(firstFavorites[2])
        firstFavorites = firstLaunch.sidebarItems.filter { $0.section == "Pinned" }
        XCTAssertEqual(firstFavorites.map(\.title), ["A", "C", "B"])

        let secondLaunch = makeModel(favoritesStore: favoritesStore)
        let relaunchedFavorites = secondLaunch.sidebarItems.filter { $0.section == "Pinned" }
        XCTAssertEqual(relaunchedFavorites.map(\.title), ["A", "C", "B"])
    }

    func testRecentLocationsStayStableInSessionAndReorderOnRelaunch() throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let a = temp.appendingPathComponent("A", isDirectory: true)
        let b = temp.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)

        let recentLocationsStore = InMemoryRecentLocationsStore()
        let firstLaunch = makeModel(recentLocationsStore: recentLocationsStore)
        firstLaunch.openFolder(at: a)
        firstLaunch.openFolder(at: b)
        firstLaunch.openFolder(at: b)

        let firstRecent = firstLaunch.sidebarItems.filter { $0.section == "Recents" }
        XCTAssertEqual(firstRecent.map(\.title), ["A", "B"])

        let secondLaunch = makeModel(recentLocationsStore: recentLocationsStore)
        let secondRecent = secondLaunch.sidebarItems.filter { $0.section == "Recents" }
        XCTAssertEqual(secondRecent.map(\.title), ["B", "A"])
    }

    func testOpenExistingRecentReappliesSidebarSelection() throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let a = temp.appendingPathComponent("A", isDirectory: true)
        let b = temp.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)

        let model = makeModel()
        model.openFolder(at: a)
        model.openFolder(at: b)

        model.selectedSidebarID = nil
        model.openFolder(at: b)

        XCTAssertEqual(model.selectedSidebarID, "folder::\(b.path)")
        let recents = model.sidebarItems.filter { $0.section == "Recents" }
        XCTAssertEqual(recents.map(\.title), ["A", "B"])
    }

    func testPinnedLocationIsRemovedFromRecentsAndSelectedOnOpen() throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let a = temp.appendingPathComponent("A", isDirectory: true)
        let b = temp.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)

        let model = makeModel()
        model.openFolder(at: a)
        model.openFolder(at: b)

        let recentsBeforePin = model.sidebarItems.filter { $0.section == "Recents" }
        XCTAssertEqual(recentsBeforePin.map(\.title), ["A", "B"])

        guard let bRecent = recentsBeforePin.first(where: { $0.title == "B" }) else {
            XCTFail("Expected B in recents before pin")
            return
        }
        model.pinSidebarItem(bRecent)

        let pinned = model.sidebarItems.filter { $0.section == "Pinned" }
        XCTAssertEqual(pinned.map(\.title), ["B"])
        let recentsAfterPin = model.sidebarItems.filter { $0.section == "Recents" }
        XCTAssertEqual(recentsAfterPin.map(\.title), ["A"])

        model.selectedSidebarID = nil
        model.openFolder(at: b)
        XCTAssertEqual(model.selectedSidebarID, "favorite::\(b.path)")
    }

    func testOpeningDownloadsDoesNotAppearInRecents() throws {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            throw XCTSkip("No Downloads directory available in this environment")
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: downloads.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: downloads.path)
        else {
            throw XCTSkip("Downloads directory is not readable in this environment")
        }

        let recentStore = InMemoryRecentLocationsStore(locations: [
            RecentLocation(path: downloads.path, displayName: "Downloads", order: 0, lastOpenedAt: Date())
        ])

        let model = makeModel(recentLocationsStore: recentStore)
        model.openFolder(at: downloads)

        let recents = model.sidebarItems.filter { $0.section == "Recents" }
        XCTAssertFalse(recents.contains(where: { $0.id == "folder::\(downloads.standardizedFileURL.resolvingSymlinksInPath().path)" }))
        XCTAssertEqual(model.selectedSidebarID, "source-downloads")
    }

    func testOpeningMountedVolumeDoesNotAppearInRecents() throws {
        let keys: [URLResourceKey] = [
            .volumeIsRemovableKey,
            .volumeIsEjectableKey,
            .volumeIsInternalKey,
            .volumeIsRootFileSystemKey,
            .volumeIsBrowsableKey
        ]
        let mounted = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []
        let candidate = mounted.first { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsRootFileSystem != true,
                  values.volumeIsBrowsable != false
            else {
                return false
            }
            return values.volumeIsInternal == false
                || values.volumeIsRemovable == true
                || values.volumeIsEjectable == true
        }

        guard let mountedVolume = candidate else {
            throw XCTSkip("No removable/ejectable mounted volume available in this environment")
        }

        let canonical = mountedVolume.standardizedFileURL.resolvingSymlinksInPath()
        let recentStore = InMemoryRecentLocationsStore(locations: [
            RecentLocation(path: canonical.path, displayName: canonical.lastPathComponent, order: 0, lastOpenedAt: Date())
        ])
        let model = makeModel(recentLocationsStore: recentStore)
        model.openFolder(at: canonical)

        let recents = model.sidebarItems.filter { $0.section == "Recents" }
        XCTAssertFalse(recents.contains(where: { $0.id == "folder::\(canonical.path)" }))
        XCTAssertEqual(model.selectedSidebarID, "volume::\(canonical.path)")
    }

    func testFileActionStatesReflectPendingEdits() throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let fileURL = temp.appendingPathComponent("sample.jpg")
        try Data("x".utf8).write(to: fileURL)

        let model = makeModel()
        model.selectedFileURLs = [fileURL]

        var apply = model.fileActionState(for: .applyMetadataChanges, targetURLs: [fileURL])
        XCTAssertFalse(apply.isEnabled)

        let preset = model.createPreset(
            name: "Title preset",
            notes: nil,
            fields: [PresetFieldValue(tagID: "xmp-title", value: "New Title")]
        )
        XCTAssertNotNil(preset)

        if let preset {
            model.applyPreset(presetID: preset.id)
        }

        apply = model.fileActionState(for: .applyMetadataChanges, targetURLs: [fileURL])
        XCTAssertTrue(apply.isEnabled)

        let clear = model.fileActionState(for: .clearMetadataChanges, targetURLs: [fileURL])
        XCTAssertTrue(clear.isEnabled)

        model.performFileAction(.clearMetadataChanges, targetURLs: [fileURL])

        let applyAfterClear = model.fileActionState(for: .applyMetadataChanges, targetURLs: [fileURL])
        XCTAssertFalse(applyAfterClear.isEnabled)
    }

    func testSendToPhotosActionStateEnabledOnlyWithSelection() {
        let fileURL = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).jpg")
        let model = makeModel()

        let disabled = model.fileActionState(for: .sendToPhotos, targetURLs: [])
        XCTAssertFalse(disabled.isEnabled)

        let enabled = model.fileActionState(for: .sendToPhotos, targetURLs: [fileURL])
        XCTAssertTrue(enabled.isEnabled)
    }

    func testSendToPhotosWithoutSelectionShowsGuidanceMessage() {
        let model = makeModel()
        model.sendToPhotos([])
        XCTAssertEqual(model.statusMessage, "Select images to send to Photos.")
    }

    func testSendToLightroomActionStateDisabledWhenSelectionEmpty() {
        let fileURL = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).jpg")
        let model = makeModel()

        let disabled = model.fileActionState(for: .sendToLightroom, targetURLs: [])
        XCTAssertFalse(disabled.isEnabled)
        _ = model.fileActionState(for: .sendToLightroom, targetURLs: [fileURL])
    }

    func testSendToLightroomWithoutSelectionShowsGuidanceMessage() {
        let model = makeModel()
        model.sendToLightroom([])
        XCTAssertEqual(model.statusMessage, "Select images to send to Lightroom.")
    }

    func testSendToLightroomClassicActionStateDisabledWhenSelectionEmpty() {
        let fileURL = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).jpg")
        let model = makeModel()

        let disabled = model.fileActionState(for: .sendToLightroomClassic, targetURLs: [])
        XCTAssertFalse(disabled.isEnabled)
        _ = model.fileActionState(for: .sendToLightroomClassic, targetURLs: [fileURL])
    }

    func testSendToLightroomClassicWithoutSelectionShowsGuidanceMessage() {
        let model = makeModel()
        model.sendToLightroomClassic([])
        XCTAssertEqual(model.statusMessage, "Select images to send to Lightroom Classic.")
    }

    func testRotateFourTimesNormalizesToNoPendingImageEdits() throws {
        let fileURL = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).jpg")
        let model = makeModel()

        model.rotateLeft(fileURL: fileURL)
        model.rotateLeft(fileURL: fileURL)
        model.rotateLeft(fileURL: fileURL)
        model.rotateLeft(fileURL: fileURL)

        XCTAssertFalse(model.hasPendingImageEdits(for: fileURL))
        XCTAssertFalse(model.hasPendingEdits(for: fileURL))
    }

    func testApplyingRotatedImageKeepsLastKnownInspectorMetadataVisible() async throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let fileURL = temp.appendingPathComponent("sample.png")
        try make1x1PNG().write(to: fileURL)

        let model = makeModel()
        let makeTag = AppModel.EditableTag.common.first(where: { $0.id == "exif-make" })
        guard let makeTag else {
            XCTFail("Missing exif-make editable tag")
            return
        }

        model.metadataByFile = [
            fileURL: FileMetadataSnapshot(
                fileURL: fileURL,
                fields: [
                    MetadataField(key: "Make", namespace: .exif, value: "Canon")
                ]
            )
        ]
        model.setSelectionFromList([fileURL], focusedURL: fileURL)
        XCTAssertEqual(model.valueForTag(makeTag), "Canon")

        model.rotateLeft(fileURL: fileURL)
        model.applyChanges(for: [fileURL])

        for _ in 0..<300 {
            if model.isApplyingMetadata == false {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertFalse(model.isApplyingMetadata)
        XCTAssertEqual(model.applyMetadataCompleted, 1)
        XCTAssertEqual(model.applyMetadataTotal, 1)
        XCTAssertFalse(model.hasPendingEdits(for: fileURL))
        XCTAssertTrue(model.lastOperationFilesByID.values.contains { $0.contains(fileURL) })
        XCTAssertTrue(model.hasRestorableBackup(for: fileURL))

        // Let post-apply metadata refresh settle.
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(model.valueForTag(makeTag), "Canon")
    }

    func testApplyingNegativeLongitudeWritesGPSLongitudeRefWest() async throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let fileURL = temp.appendingPathComponent("sample.jpg")
        try Data().write(to: fileURL)

        let service = RecordingExifToolService()
        let model = AppModel(
            exifToolService: service,
            presetStore: InMemoryPresetStore(),
            favoritesStore: InMemoryFavoritesStore(),
            recentLocationsStore: InMemoryRecentLocationsStore()
        )

        _ = model.stageImportAssignments(
            [ImportAssignment(targetURL: fileURL, fields: [.init(tagID: "exif-gps-lon", value: "-0.2159974")])],
            sourceKind: .gpx,
            emptyValuePolicy: .clear
        )
        model.applyChanges(for: [fileURL])

        for _ in 0..<300 {
            if model.isApplyingMetadata == false {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let operations = await service.recordedOperations
        guard let operation = operations.last else {
            XCTFail("Expected a recorded write operation")
            return
        }

        let byKey = Dictionary(uniqueKeysWithValues: operation.changes.map { ("\($0.namespace.rawValue):\($0.key)", $0.newValue) })
        XCTAssertEqual(byKey["EXIF:GPSLongitude"], "0.2159974")
        XCTAssertEqual(byKey["EXIF:GPSLongitudeRef"], "W")
    }

    // MARK: - Empty state and enumeration

    func testEmptyFolderBrowserItemsAreEmpty() throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let model = makeModel()
        model.openFolder(at: temp)

        XCTAssertTrue(model.browserItems.isEmpty)
        XCTAssertNil(model.browserEnumerationError)
    }

    func testInaccessibleFolderSetsEnumerationError() throws {
        // Non-existent paths trigger a FileManager error.
        let nonExistent = URL(fileURLWithPath: "/tmp/__lattice_nonexistent_\(UUID().uuidString)")
        let model = makeModel()
        model.openFolder(at: nonExistent)

        XCTAssertNotNil(model.browserEnumerationError)
        XCTAssertTrue(model.browserItems.isEmpty)
    }

    func testPresetSchemaVersionMismatchThrows() throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        // Write a preset file with a future schema version.
        let presetFile = temp.appendingPathComponent("presets.json")
        let futurePayload = """
        {"schemaVersion":9999,"presets":[]}
        """
        try futurePayload.write(to: presetFile, atomically: true, encoding: .utf8)

        let store = FilePresetStore(fileURL: presetFile)
        XCTAssertThrowsError(try store.loadPresets()) { error in
            guard let editError = error as? ExifEditError,
                  case .presetSchemaVersionTooNew = editError else {
                XCTFail("Expected ExifEditError.presetSchemaVersionTooNew, got \(error)")
                return
            }
        }
    }

    // MARK: - filteredBrowserItems caching

    func testFilteredBrowserItemsUpdatesWhenBrowserItemsChange() {
        let model = makeModel()
        XCTAssertTrue(model.filteredBrowserItems.isEmpty)

        let items = makeBrowserItems(count: 3)
        model.browserItems = items

        XCTAssertEqual(model.filteredBrowserItems.count, 3)
    }

    func testSearchQueryFiltersFilteredBrowserItems() {
        let model = makeModel()
        model.browserItems = [
            makeBrowserItem(name: "alpha.jpg"),
            makeBrowserItem(name: "beta.jpg"),
            makeBrowserItem(name: "alpha_2.jpg")
        ]

        model.searchQuery = "alpha"

        XCTAssertEqual(model.filteredBrowserItems.count, 2)
        XCTAssertTrue(model.filteredBrowserItems.allSatisfy { $0.name.lowercased().contains("alpha") })
    }

    func testFilteredBrowserItemsClearsWhenSearchQueryClears() {
        let model = makeModel()
        model.browserItems = makeBrowserItems(count: 5)
        model.searchQuery = "zzz_no_match"
        XCTAssertTrue(model.filteredBrowserItems.isEmpty)

        model.searchQuery = ""
        XCTAssertEqual(model.filteredBrowserItems.count, 5)
    }

    // MARK: - Modified-click selection sync

    func testCommandClickAddsItemToSelection() {
        let model = makeModel()
        let items = makeBrowserItems(count: 3)
        // Plain-click item 0 to set anchor.
        model.selectFile(items[0].url, modifiers: [], in: items)
        XCTAssertEqual(model.selectedFileURLs, [items[0].url])

        // Cmd-click item 1 should add it without deselecting item 0.
        model.selectFile(items[1].url, modifiers: .command, in: items)
        XCTAssertEqual(model.selectedFileURLs, [items[0].url, items[1].url])
    }

    func testCommandClickDeselects() {
        let model = makeModel()
        let items = makeBrowserItems(count: 3)
        model.selectFile(items[0].url, modifiers: [], in: items)
        model.selectFile(items[1].url, modifiers: .command, in: items)
        XCTAssertTrue(model.selectedFileURLs.contains(items[1].url))

        // Cmd-click item 1 again removes it from selection.
        model.selectFile(items[1].url, modifiers: .command, in: items)
        XCTAssertFalse(model.selectedFileURLs.contains(items[1].url))
        XCTAssertTrue(model.selectedFileURLs.contains(items[0].url))
    }

    func testShiftClickRangeSelectsFromAnchor() {
        let model = makeModel()
        let items = makeBrowserItems(count: 5)
        // Plain-click item 1 sets the anchor.
        model.selectFile(items[1].url, modifiers: [], in: items)

        // Shift-click item 3 should produce items 1, 2, 3.
        model.selectFile(items[3].url, modifiers: .shift, in: items)
        XCTAssertEqual(
            model.selectedFileURLs,
            Set([items[1].url, items[2].url, items[3].url])
        )
    }

    func testShiftClickFromEmptySelectionSelectsOnlyTarget() {
        let model = makeModel()
        let items = makeBrowserItems(count: 4)
        // No prior selection; Shift-click with no anchor selects just that item.
        model.selectFile(items[2].url, modifiers: .shift, in: items)
        XCTAssertEqual(model.selectedFileURLs, [items[2].url])
    }

    func testCommandShiftClickAddsRangeToExistingSelection() {
        let model = makeModel()
        let items = makeBrowserItems(count: 6)
        model.selectFile(items[0].url, modifiers: [], in: items)
        // Cmd+Shift-click item 4 should add the range 0-4 without losing item 0.
        model.selectFile(items[4].url, modifiers: [.command, .shift], in: items)
        XCTAssertEqual(model.selectedFileURLs, Set(items[0...4].map(\.url)))
    }

    // Tests the list-selection adoption edge case: after setSelectionFromList syncs the
    // same URL back into the model, a subsequent Shift-click still uses the correct anchor.
    func testSetSelectionFromListPreservesAnchorForSubsequentRangeSelect() {
        let model = makeModel()
        let items = makeBrowserItems(count: 6)
        // Establish anchor at item 2 via plain click.
        model.selectFile(items[2].url, modifiers: [], in: items)

        // Simulate the list view calling setSelectionFromList (normal sync path after reload).
        // Using the same URL set: early-return guard should leave anchor intact.
        model.setSelectionFromList([items[2].url], focusedURL: items[2].url)

        // If the anchor was preserved at item 2, Shift-click item 4 → selects items 2, 3, 4.
        model.selectFile(items[4].url, modifiers: .shift, in: items)
        XCTAssertEqual(
            model.selectedFileURLs,
            Set([items[2].url, items[3].url, items[4].url])
        )
    }

    // MARK: - Helpers

    private func makeBrowserItems(count: Int) -> [AppModel.BrowserItem] {
        (0 ..< count).map { i in
            makeBrowserItem(name: "seltest_\(i).jpg")
        }
    }

    private func makeBrowserItem(name: String) -> AppModel.BrowserItem {
        AppModel.BrowserItem(
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            name: name,
            modifiedAt: nil,
            createdAt: nil,
            sizeBytes: nil,
            kind: nil
        )
    }

    private func makeModel(
        favoritesStore: InMemoryFavoritesStore = InMemoryFavoritesStore(),
        recentLocationsStore: InMemoryRecentLocationsStore = InMemoryRecentLocationsStore()
    ) -> AppModel {
        AppModel(
            exifToolService: StubExifToolService(),
            presetStore: InMemoryPresetStore(),
            favoritesStore: favoritesStore,
            recentLocationsStore: recentLocationsStore
        )
    }

    private func makeTempDirectory() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func waitUntil(
        _ description: String = "condition",
        timeoutNanoseconds: UInt64 = 3_000_000_000,
        pollIntervalNanoseconds: UInt64 = 20_000_000,
        _ condition: () -> Bool
    ) async throws {
        let timeoutSeconds = Double(timeoutNanoseconds) / 1_000_000_000
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
        XCTFail("Timed out waiting for \(description)")
    }

    // MARK: - Batch Rename action-state tests

    func testBatchRenameSelectionDisabledWhenSelectionEmpty() {
        let model = makeModel()
        // No browser items or selection
        let state = model.fileActionState(for: .batchRenameSelection, targetURLs: [])
        XCTAssertFalse(state.isEnabled)
    }

    func testBatchRenameSelectionEnabledWhenSelectionNonEmpty() {
        let fileURL = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).jpg")
        let model = makeModel()
        let state = model.fileActionState(for: .batchRenameSelection, targetURLs: [fileURL])
        XCTAssertTrue(state.isEnabled)
    }

    func testBatchRenameFolderDisabledWhenBrowserEmpty() {
        let model = makeModel()
        XCTAssertTrue(model.browserItems.isEmpty)
        let state = model.fileActionState(for: .batchRenameFolder, targetURLs: [])
        XCTAssertFalse(state.isEnabled)
    }

    func testBatchRenameFolderEnabledWhenBrowserNonEmpty() {
        let model = makeModel()
        model.browserItems = [makeBrowserItem(name: "photo.jpg")]
        let state = model.fileActionState(for: .batchRenameFolder, targetURLs: [])
        XCTAssertTrue(state.isEnabled)
    }

    func testBeginBatchRenameSelectionSetsPendingScope() {
        let fileURL = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).jpg")
        let model = makeModel()
        model.selectedFileURLs = [fileURL]
        model.beginBatchRename(scope: .selection)
        XCTAssertEqual(model.pendingBatchRenameScope, .selection)
    }

    func testBeginBatchRenameSelectionNoopWhenSelectionEmpty() {
        let model = makeModel()
        model.beginBatchRename(scope: .selection)
        XCTAssertNil(model.pendingBatchRenameScope)
    }

    func testBeginBatchRenameFolderSetsPendingScope() {
        let model = makeModel()
        model.browserItems = [makeBrowserItem(name: "photo.jpg")]
        model.beginBatchRename(scope: .folder)
        XCTAssertEqual(model.pendingBatchRenameScope, .folder)
    }

    func testDismissBatchRenameSheetClearsPendingScope() {
        let fileURL = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).jpg")
        let model = makeModel()
        model.selectedFileURLs = [fileURL]
        model.beginBatchRename(scope: .selection)
        model.dismissBatchRenameSheet()
        XCTAssertNil(model.pendingBatchRenameScope)
    }

    func testPreviewBatchRenameReturnsDeterministicPlan() async {
        let model = makeModel()
        let files = [
            URL(fileURLWithPath: "/tmp/b.jpg"),
            URL(fileURLWithPath: "/tmp/a.jpg"),
        ]
        model.selectedFileURLs = Set(files)
        let plan = await model.previewBatchRename(
            pattern: RenamePattern(tokens: [.sequence(start: 1, padding: .two)]),
            scope: .selection
        )
        // Plan should be sorted by name: a.jpg first, b.jpg second
        XCTAssertEqual(plan.count, 2)
        XCTAssertEqual(plan[0].sourceURL.lastPathComponent, "a.jpg")
        XCTAssertEqual(plan[0].finalTargetURL.lastPathComponent, "01.jpg")
        XCTAssertEqual(plan[1].sourceURL.lastPathComponent, "b.jpg")
        XCTAssertEqual(plan[1].finalTargetURL.lastPathComponent, "02.jpg")
    }

    func testStageBatchRenameStoresPendingRenamePlan() async {
        let model = makeModel()
        let files = [
            URL(fileURLWithPath: "/tmp/b.jpg"),
            URL(fileURLWithPath: "/tmp/a.jpg"),
        ]
        model.selectedFileURLs = Set(files)
        model.pendingBatchRenameScope = .selection

        await model.stageBatchRename(
            operation: RenameOperation(
                files: files,
                pattern: RenamePattern(tokens: [.sequence(start: 1, padding: .two)])
            )
        )

        XCTAssertEqual(model.pendingRenameByFile[URL(fileURLWithPath: "/tmp/a.jpg")], "01.jpg")
        XCTAssertEqual(model.pendingRenameByFile[URL(fileURLWithPath: "/tmp/b.jpg")], "02.jpg")
        XCTAssertNil(model.pendingBatchRenameScope)
        XCTAssertEqual(model.statusMessage, "Prepared name changes for 2 files. Ready to apply.")
    }

    func testListColumnValueUsesPendingRenameForNameColumn() {
        let model = makeModel()
        let item = makeBrowserItem(name: "original.jpg")
        model.pendingRenameByFile[item.url] = "renamed.jpg"

        let value = model.listColumnValue(
            for: item.url,
            columnID: ListColumnDefinition.idName,
            fallbackItem: item
        )

        XCTAssertEqual(value, "renamed.jpg")
    }

    func testListColumnDefinitionsExposeExpectedMetadataColumns() {
        let metadataIDs = Set(ListColumnDefinition.metadata.map(\.id))

        XCTAssertEqual(
            metadataIDs,
            Set([
                ListColumnDefinition.idRating,
                ListColumnDefinition.idMake,
                ListColumnDefinition.idModel,
                ListColumnDefinition.idLens,
                ListColumnDefinition.idAperture,
                ListColumnDefinition.idShutter,
                ListColumnDefinition.idISO,
                ListColumnDefinition.idFocal,
                ListColumnDefinition.idDateTaken,
                ListColumnDefinition.idDimensions,
                ListColumnDefinition.idTitle,
                ListColumnDefinition.idDescription,
                ListColumnDefinition.idKeywords,
                ListColumnDefinition.idCopyright,
                ListColumnDefinition.idCreator,
            ])
        )
        XCTAssertFalse(ListColumnDefinition.toggleable.contains(where: { $0.id == ListColumnDefinition.idName }))
        XCTAssertTrue(ListColumnDefinition.toggleable.contains(where: { $0.id == ListColumnDefinition.idRating }))
        XCTAssertTrue(ListColumnDefinition.metadata.allSatisfy { !$0.isSortable })
        XCTAssertTrue(ListColumnDefinition.metadata.allSatisfy { !$0.defaultIsVisible })
    }

    func testListColumnValueFormatsRepresentativeMetadataColumns() {
        let model = makeModel()
        let fileURL = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).jpg")
        model.metadataByFile = [
            fileURL: FileMetadataSnapshot(
                fileURL: fileURL,
                fields: [
                    MetadataField(key: "Rating", namespace: .xmp, value: "5"),
                    MetadataField(key: "Make", namespace: .exif, value: "Canon"),
                    MetadataField(key: "LensModel", namespace: .exif, value: "EF 50mm f/1.8 STM"),
                    MetadataField(key: "FNumber", namespace: .exif, value: "2.8"),
                    MetadataField(key: "ExposureTime", namespace: .exif, value: "1/250"),
                    MetadataField(key: "ISO", namespace: .exif, value: "400.0"),
                    MetadataField(key: "FocalLength", namespace: .exif, value: "50"),
                    MetadataField(key: "DateTimeOriginal", namespace: .exif, value: "2024:12:31 23:59:58"),
                    MetadataField(key: "Title", namespace: .xmp, value: "Sunset"),
                    MetadataField(key: "Copyright", namespace: .exif, value: "Chris"),
                    MetadataField(key: "Creator", namespace: .xmp, value: "Chris Lem")
                ]
            )
        ]

        XCTAssertEqual(model.listColumnValue(for: fileURL, columnID: ListColumnDefinition.idRating, fallbackItem: nil), "5")
        XCTAssertEqual(model.listColumnValue(for: fileURL, columnID: ListColumnDefinition.idMake, fallbackItem: nil), "Canon")
        XCTAssertEqual(model.listColumnValue(for: fileURL, columnID: ListColumnDefinition.idLens, fallbackItem: nil), "EF 50mm f/1.8 STM")
        XCTAssertEqual(model.listColumnValue(for: fileURL, columnID: ListColumnDefinition.idAperture, fallbackItem: nil), "f/2.8")
        XCTAssertEqual(model.listColumnValue(for: fileURL, columnID: ListColumnDefinition.idShutter, fallbackItem: nil), "1/250 s")
        XCTAssertEqual(model.listColumnValue(for: fileURL, columnID: ListColumnDefinition.idISO, fallbackItem: nil), "400")
        XCTAssertEqual(model.listColumnValue(for: fileURL, columnID: ListColumnDefinition.idFocal, fallbackItem: nil), "50 mm")
        XCTAssertEqual(model.listColumnValue(for: fileURL, columnID: ListColumnDefinition.idTitle, fallbackItem: nil), "Sunset")
        XCTAssertEqual(model.listColumnValue(for: fileURL, columnID: ListColumnDefinition.idCopyright, fallbackItem: nil), "Chris")
        XCTAssertEqual(model.listColumnValue(for: fileURL, columnID: ListColumnDefinition.idCreator, fallbackItem: nil), "Chris Lem")

        let expectedDate = AppModel.exifDateFormatter.date(from: "2024:12:31 23:59:58").map(AppModel.listDateFormatter.string(from:))
        XCTAssertEqual(model.listColumnValue(for: fileURL, columnID: ListColumnDefinition.idDateTaken, fallbackItem: nil), expectedDate)
    }

    func testRenameOnlyApplyAndRestoreTrackCurrentFileURLs() async throws {
        let temp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let original = temp.appendingPathComponent("original.jpg")
        let renamed = temp.appendingPathComponent("renamed.jpg")
        try Data("original".utf8).write(to: original)

        let model = makeModel()
        guard let sidebarItem = model.noteRecentLocation(temp) else {
            XCTFail("Expected temp folder to register as a sidebar location")
            return
        }
        await model.loadFiles(for: sidebarItem.kind)
        XCTAssertTrue(model.browserItems.contains(where: { $0.url.standardizedFileURL == original.standardizedFileURL }))

        model.selectedFileURLs = [original]
        model.pendingRenameByFile[original] = renamed.lastPathComponent
        model.applyChanges(for: [original])

        try await waitUntil("rename apply completion") {
            !model.isApplyingMetadata && FileManager.default.fileExists(atPath: renamed.path)
        }
        try await waitUntil("browser reload after rename") {
            model.browserItems.contains(where: { $0.url.standardizedFileURL == renamed.standardizedFileURL })
        }

        XCTAssertTrue(model.hasRestorableBackup(for: renamed))
        XCTAssertTrue(model.fileActionState(for: .restoreFromLastBackup, targetURLs: [renamed]).isEnabled)

        model.restoreLastOperation(for: [renamed])

        try await waitUntil("rename restore completion") {
            FileManager.default.fileExists(atPath: original.path)
                && !FileManager.default.fileExists(atPath: renamed.path)
        }
        try await waitUntil("browser reload after restore") {
            model.browserItems.contains(where: { $0.url.standardizedFileURL == original.standardizedFileURL })
                && !model.browserItems.contains(where: { $0.url.standardizedFileURL == renamed.standardizedFileURL })
        }

        XCTAssertFalse(model.fileActionState(for: .restoreFromLastBackup, targetURLs: [original]).isEnabled)
    }
}

private func make1x1PNG() throws -> Data {
    let image = NSImage(size: NSSize(width: 1, height: 1))
    image.lockFocus()
    NSColor.white.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1, height: 1)).fill()
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "AppModelTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to generate PNG test image"])
    }
    return png
}

private struct StubExifToolService: ExifToolServiceProtocol {
    func readMetadata(files _: [URL]) async throws -> [FileMetadataSnapshot] {
        []
    }

    func writeMetadata(operation: EditOperation) async -> OperationResult {
        OperationResult(operationID: operation.id, succeeded: operation.targetFiles, failed: [], backupLocation: nil, duration: 0)
    }
}

private actor RecordingExifToolService: ExifToolServiceProtocol {
    private(set) var recordedOperations: [EditOperation] = []

    func readMetadata(files _: [URL]) async throws -> [FileMetadataSnapshot] {
        []
    }

    func writeMetadata(operation: EditOperation) async -> OperationResult {
        recordedOperations.append(operation)
        return OperationResult(operationID: operation.id, succeeded: operation.targetFiles, failed: [], backupLocation: nil, duration: 0)
    }
}

private struct InMemoryPresetStore: PresetStoreProtocol {
    func loadPresets() throws -> [MetadataPreset] { [] }
    func savePresets(_: [MetadataPreset]) throws {}
}

private final class InMemoryFavoritesStore: SidebarFavoritesStoreProtocol {
    var favorites: [SidebarFavorite]
    var saved: [[SidebarFavorite]] = []

    init(favorites: [SidebarFavorite] = []) {
        self.favorites = favorites
    }

    func loadFavorites() throws -> [SidebarFavorite] {
        favorites
    }

    func saveFavorites(_ favorites: [SidebarFavorite]) throws {
        self.favorites = favorites
        saved.append(favorites)
    }
}

private final class InMemoryRecentLocationsStore: RecentLocationsStoreProtocol {
    var locations: [RecentLocation]
    var saved: [[RecentLocation]] = []

    init(locations: [RecentLocation] = []) {
        self.locations = locations
    }

    func loadRecentLocations() throws -> [RecentLocation] {
        locations
    }

    func saveRecentLocations(_ locations: [RecentLocation]) throws {
        self.locations = locations
        saved.append(locations)
    }
}
