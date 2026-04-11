import Foundation
import CoreLocation
import SharedUI

@MainActor
extension AppModel {

    // MARK: - Sheet Lifecycle

    func beginDateTimeAdjust(
        scope: DateTimeAdjustScope,
        launchTag: DateTimeTargetTag,
        launchContext: DateTimeAdjustLaunchContext = .inspector
    ) {
        let files = filesForDateTimeAdjust(scope)
        guard !files.isEmpty else {
            statusMessage = "No files in scope for date/time adjustment."
            return
        }

        guard let primaryFile = files.first else { return }

        var session = DateTimeAdjustSession(
            scope: scope,
            launchTag: launchTag,
            fileURLs: files
        )
        session.sourceTimeZoneID = DateTimeAdjustSession.cameraClockIdentifier
        session.cameraClockOffsetSeconds = preferredCameraClockOffsetSeconds(for: files)
        session.dataReadSource = preferredInitialDataReadSource(
            for: primaryFile,
            launchTag: launchTag,
            launchContext: launchContext
        )
        session.applyTo = []

        var captured: [URL: [DateTimeTargetTag: Date]] = [:]
        for fileURL in files {
            var tagDates: [DateTimeTargetTag: Date] = [:]
            for tag in DateTimeTargetTag.allCases {
                if let date = originalDate(for: fileURL, tag: tag) {
                    tagDates[tag] = date
                }
            }
            if !tagDates.isEmpty {
                captured[fileURL] = tagDates
            }
        }
        session.capturedDates = captured
        if let primaryDate = captured[primaryFile]?[launchTag] {
            session.specificDate = primaryDate
        }

        pendingDateTimeAdjustSession = session
    }

    func dismissDateTimeAdjustSheet() {
        pendingDateTimeAdjustSession = nil
    }

    // MARK: - Scope Resolution

    func filesForDateTimeAdjust(_ scope: DateTimeAdjustScope) -> [URL] {
        let urls: [URL]
        switch scope {
        case .single:
            if let first = selectedFileURLs.sorted(by: {
                let cmp = $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                if cmp != .orderedSame { return cmp == .orderedAscending }
                return $0.path < $1.path
            }).first {
                urls = [first]
            } else {
                urls = []
            }
        case .selection:
            urls = Array(selectedFileURLs).sorted {
                let cmp = $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                if cmp != .orderedSame { return cmp == .orderedAscending }
                return $0.path < $1.path
            }
        case .folder:
            urls = browserItems.map(\.url).sorted {
                let cmp = $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                if cmp != .orderedSame { return cmp == .orderedAscending }
                return $0.path < $1.path
            }
        }
        return urls
    }

    // MARK: - Original Date Extraction

    func originalDate(for fileURL: URL, tag: DateTimeTargetTag) -> Date? {
        // Look up from the full catalog, not just enabled fields — the date/time
        // sheet must work even when the corresponding inspector field is hidden.
        guard let entry = activeInspectorFieldCatalog.first(where: { $0.id == tag.editableTagID }) else { return nil }
        let editableTag = EditableTag(
            id: entry.id,
            namespace: entry.namespace,
            key: entry.key,
            label: entry.label,
            section: entry.section
        )
        guard let snapshot = availableSnapshot(for: fileURL) else { return nil }
        let raw = normalizedDisplayValue(snapshot, for: editableTag)
        guard !raw.isEmpty else { return nil }
        return parseDate(raw)
    }

    func fileCreationDate(for fileURL: URL) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.creationDate] as? Date
    }

    func isDataReadSourceAvailable(_ source: DateTimeDataReadSource, for fileURL: URL) -> Bool {
        if let tag = source.sourceTag {
            return originalDate(for: fileURL, tag: tag) != nil
        }
        return fileCreationDate(for: fileURL) != nil
    }

    // MARK: - Adjusted Date Computation

    func computeAdjustedDate(for fileURL: URL, session: DateTimeAdjustSession) -> Date? {
        switch session.mode {
        case .timeZone:
            return computeTimeZoneAdjusted(for: fileURL, session: session)
        case .shift:
            return computeShiftAdjusted(for: fileURL, session: session)
        case .specific:
            return session.specificDate
        case .file:
            assertionFailure("Data mode should use dataModeFileState directly, not computeAdjustedDate")
            return nil
        }
    }

    func dataModeFileState(for fileURL: URL, session: DateTimeAdjustSession) -> DateTimeDataModeFileState {
        let readValue = dataModeReadValue(for: fileURL, session: session)
        let destinations = dataModeWritableTargets(for: session).map { targetTag in
            DateTimeDataModeDestination(
                targetTag: targetTag,
                currentValue: session.capturedDates[fileURL]?[targetTag] ?? originalDate(for: fileURL, tag: targetTag)
            )
        }
        return DateTimeDataModeFileState(
            readValue: readValue,
            destinations: destinations
        )
    }

    func dataModeWritableTargets(for session: DateTimeAdjustSession) -> [DateTimeTargetTag] {
        let sourceTag = session.dataReadSource.sourceTag
        return DateTimeTargetTag.allCases.filter {
            session.applyTo.contains($0) && $0 != sourceTag
        }
    }

    func dataModeReadValue(for fileURL: URL, session: DateTimeAdjustSession) -> Date? {
        if let sourceTag = session.dataReadSource.sourceTag {
            return session.capturedDates[fileURL]?[sourceTag] ?? originalDate(for: fileURL, tag: sourceTag)
        }
        return fileCreationDate(for: fileURL)
    }

    private func preferredInitialDataReadSource(
        for representativeFile: URL,
        launchTag: DateTimeTargetTag,
        launchContext: DateTimeAdjustLaunchContext
    ) -> DateTimeDataReadSource {
        switch launchContext {
        case .inspector:
            return .from(tag: launchTag)
        case .menu:
            return DateTimeDataReadSource.allCases.first {
                isDataReadSourceAvailable($0, for: representativeFile)
            } ?? .original
        }
    }

    private func dateValuesEqual(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case let (left?, right?):
            return abs(left.timeIntervalSince(right)) < 1
        case (nil, nil):
            return true
        default:
            return false
        }
    }

    private func computeShiftAdjusted(for fileURL: URL, session: DateTimeAdjustSession) -> Date? {
        guard let original = session.capturedDates[fileURL]?[session.launchTag] ?? originalDate(for: fileURL, tag: session.launchTag) else { return nil }
        var components = DateComponents()
        components.day = session.shiftDays
        components.hour = session.shiftHours
        components.minute = session.shiftMinutes
        components.second = session.shiftSeconds
        return Calendar.current.date(byAdding: components, to: original)
    }

    private func computeTimeZoneAdjusted(for fileURL: URL, session: DateTimeAdjustSession) -> Date? {
        guard let original = session.capturedDates[fileURL]?[session.launchTag] ?? originalDate(for: fileURL, tag: session.launchTag) else { return nil }
        guard let targetTZ = resolvedTargetTimeZone(for: session) else {
            return nil
        }

        let sourceOffset: Int
        if session.sourceUsesCameraClock {
            sourceOffset = session.cameraClockOffsetSeconds
        } else {
            guard let sourceTZ = resolvedSourceTimeZone(for: session) else { return nil }
            sourceOffset = sourceTZ.secondsFromGMT(for: original)
        }
        let targetOffset = targetTZ.secondsFromGMT(for: original)
        let delta = TimeInterval(targetOffset - sourceOffset)
        return original.addingTimeInterval(delta)
    }

    func embeddedOffsetString(for fileURL: URL) -> String? {
        guard let snapshot = metadataByFile[fileURL] else { return nil }
        return snapshot.fields
            .first { $0.namespace == .exif && $0.key == "OffsetTimeOriginal" }?
            .value
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func offsetSeconds(fromOffsetString offset: String) -> Int? {
        // Parse "+05:30" or "-08:00" style offsets
        let trimmed = offset.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 5 else { return nil }
        let sign: Int = trimmed.hasPrefix("-") ? -1 : 1
        let digits = trimmed.dropFirst().replacingOccurrences(of: ":", with: "")
        guard digits.count >= 4,
              let hours = Int(digits.prefix(2)),
              let minutes = Int(digits.suffix(2)) else { return nil }
        return sign * (hours * 3600 + minutes * 60)
    }

    private func preferredCameraClockOffsetSeconds(for files: [URL]) -> Int {
        guard !files.isEmpty else { return 0 }
        let offsets = files.compactMap { embeddedOffsetString(for: $0) }
        if offsets.count == files.count,
           let first = offsets.first,
           offsets.allSatisfy({ $0 == first }),
           let seconds = offsetSeconds(fromOffsetString: first) {
            return seconds
        }
        return 0
    }

    // MARK: - Resolved Timezone Name

    func resolvedTimeZoneName(for session: DateTimeAdjustSession) -> String {
        guard let identifier = resolvedTargetTimeZoneIdentifier(for: session),
              let tz = TimeZone(identifier: identifier) else {
            return ""
        }
        return tz.localizedName(for: .standard, locale: .current) ?? identifier
    }

    func normalizeTargetTimeZoneEntry(_ rawInput: String) -> (identifier: String, display: String)? {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let identifier: String
        if let cityMatch = TimeZoneCityData.identifier(forCity: trimmed), !cityMatch.isEmpty {
            identifier = cityMatch
        } else if let canonical = canonicalTimeZoneIdentifier(matching: trimmed) {
            identifier = canonical
        } else {
            return nil
        }

        let display = TimeZone(identifier: identifier)?
            .localizedName(for: .standard, locale: .current) ?? identifier
        return (identifier, display)
    }

    private func resolvedSourceTimeZone(for session: DateTimeAdjustSession) -> TimeZone? {
        guard !session.sourceUsesCameraClock else { return nil }
        let identifier = session.sourceTimeZoneID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else { return nil }
        guard let canonical = canonicalTimeZoneIdentifier(matching: identifier) else { return nil }
        return TimeZone(identifier: canonical)
    }

    private func canonicalTimeZoneIdentifier(matching value: String) -> String? {
        if let exact = TimeZone.knownTimeZoneIdentifiers.first(where: {
            $0.caseInsensitiveCompare(value) == .orderedSame
        }) {
            return exact
        }
        return TimeZone(identifier: value)?.identifier
    }

    private func resolvedTargetTimeZoneIdentifier(for session: DateTimeAdjustSession) -> String? {
        let storedID = session.targetTimeZoneID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !storedID.isEmpty {
            return canonicalTimeZoneIdentifier(matching: storedID) ?? storedID
        }
        let rawInput = session.targetTimeZoneInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawInput.isEmpty else { return nil }
        return normalizeTargetTimeZoneEntry(rawInput)?.identifier
    }

    private func resolvedTargetTimeZone(for session: DateTimeAdjustSession) -> TimeZone? {
        guard let identifier = resolvedTargetTimeZoneIdentifier(for: session) else { return nil }
        return TimeZone(identifier: identifier)
    }

    // MARK: - Preview

    func previewDateTimeAdjust(session: DateTimeAdjustSession) -> DateTimeAdjustAssessment {
        if session.mode == .file {
            return previewDataModeAdjust(session: session)
        }

        var rows: [DateTimeAdjustPreviewRow] = []
        var blockingIssues: [String] = []
        var warnings: [String] = []
        var skippedCount = 0
        var effectiveChangeFileCount = 0

        if session.mode == .timeZone {
            if !session.sourceUsesCameraClock, resolvedSourceTimeZone(for: session) == nil {
                blockingIssues.append("Source time zone is invalid.")
            }
            if resolvedTargetTimeZone(for: session) == nil {
                blockingIssues.append("Target time zone is required.")
            }
        }

        for fileURL in session.fileURLs {
            let fileName = fileURL.lastPathComponent
            let original = session.capturedDates[fileURL]?[session.launchTag] ?? originalDate(for: fileURL, tag: session.launchTag)
            let adjusted = computeAdjustedDate(for: fileURL, session: session)

            let originalDisplay: String
            let adjustedDisplay: String
            var deltaText: String
            var rowWarnings: [String] = []

            if let original {
                originalDisplay = Self.exifDateFormatter.string(from: original)
            } else {
                originalDisplay = "—"
                if session.mode != .file {
                    rowWarnings.append("No \(session.launchTag.displayName) date")
                }
            }

            if let adjusted {
                adjustedDisplay = Self.exifDateFormatter.string(from: adjusted)
            } else {
                adjustedDisplay = "—"
            }

            if let original, let adjusted {
                let interval = adjusted.timeIntervalSince(original)
                deltaText = formattedDelta(interval)
            } else {
                deltaText = ""
            }

            if let adjusted {
                let targetTags = DateTimeTargetTag.allCases.filter { session.applyTo.contains($0) }
                let hasEffectiveChange = targetTags.contains { tag in
                    let current = session.capturedDates[fileURL]?[tag] ?? originalDate(for: fileURL, tag: tag)
                    return !dateValuesEqual(current, adjusted)
                }
                if hasEffectiveChange {
                    effectiveChangeFileCount += 1
                }
            }

            if adjusted == nil {
                skippedCount += 1
                switch session.mode {
                case .file:
                    rowWarnings.append("No \(session.dataReadSource.missingValueDescription)")
                case .timeZone, .shift:
                    rowWarnings.append("No computable source date")
                case .specific:
                    break
                }
            }

            rows.append(DateTimeAdjustPreviewRow(
                id: fileURL.path,
                fileName: fileName,
                originalDisplay: originalDisplay,
                adjustedDisplay: adjustedDisplay,
                deltaText: deltaText,
                warnings: rowWarnings
            ))
        }

        if skippedCount == session.fileURLs.count {
            switch session.mode {
            case .file:
                blockingIssues.append("No files have a \(session.dataReadSource.missingValueDescription) to use.")
            case .timeZone, .shift:
                blockingIssues.append("No files have a \(session.launchTag.displayName) date to adjust.")
            case .specific:
                break
            }
        } else if skippedCount > 0 {
            switch session.mode {
            case .file:
                warnings.append("\(skippedCount) file(s) have no \(session.dataReadSource.missingValueDescription) and will be skipped.")
            case .timeZone, .shift:
                warnings.append("\(skippedCount) file(s) have no \(session.launchTag.displayName) date and will be skipped.")
            case .specific:
                break
            }
        }

        if session.applyTo.isEmpty {
            blockingIssues.append("No target tags selected in \"Apply to\".")
        }

        return DateTimeAdjustAssessment(
            rows: rows,
            blockingIssues: blockingIssues,
            warnings: warnings,
            effectiveChangeFileCount: effectiveChangeFileCount
        )
    }

    private func previewDataModeAdjust(session: DateTimeAdjustSession) -> DateTimeAdjustAssessment {
        let writableTargets = dataModeWritableTargets(for: session)

        var rows: [DateTimeAdjustPreviewRow] = []
        var blockingIssues: [String] = []
        var warnings: [String] = []
        var missingSourceCount = 0
        var effectiveChangeFileCount = 0

        if writableTargets.isEmpty {
            blockingIssues.append("No target tags selected in \"Apply to\".")
        }

        for fileURL in session.fileURLs {
            let fileState = dataModeFileState(for: fileURL, session: session)
            let fileName = fileURL.lastPathComponent
            var fileHasEffectiveChange = false

            if fileState.readValue == nil {
                missingSourceCount += 1
            }

            for destination in fileState.destinations {
                let existingTargetDate = destination.currentValue
                let originalDisplay = existingTargetDate.map(Self.exifDateFormatter.string(from:)) ?? "—"

                let adjustedDisplay: String
                let deltaText: String
                var rowWarnings: [String] = []

                if let readValue = fileState.readValue {
                    adjustedDisplay = Self.exifDateFormatter.string(from: readValue)
                    if let existingTargetDate {
                        let interval = readValue.timeIntervalSince(existingTargetDate)
                        deltaText = formattedDelta(interval)
                    } else {
                        deltaText = "set"
                    }

                    if !dateValuesEqual(existingTargetDate, readValue) {
                        fileHasEffectiveChange = true
                    }
                } else {
                    adjustedDisplay = "—"
                    deltaText = ""
                    rowWarnings.append("No \(session.dataReadSource.missingValueDescription)")
                }

                rows.append(DateTimeAdjustPreviewRow(
                    id: "\(fileURL.path)#\(destination.targetTag.rawValue)",
                    fileName: "\(fileName) [\(destination.targetTag.displayName)]",
                    originalDisplay: originalDisplay,
                    adjustedDisplay: adjustedDisplay,
                    deltaText: deltaText,
                    warnings: rowWarnings
                ))
            }

            if fileHasEffectiveChange {
                effectiveChangeFileCount += 1
            }
        }

        if missingSourceCount == session.fileURLs.count {
            blockingIssues.append("No files have a \(session.dataReadSource.missingValueDescription) to use.")
        } else if missingSourceCount > 0 {
            warnings.append("\(missingSourceCount) file(s) have no \(session.dataReadSource.missingValueDescription) and will be skipped.")
        }

        return DateTimeAdjustAssessment(
            rows: rows,
            blockingIssues: blockingIssues,
            warnings: warnings,
            effectiveChangeFileCount: effectiveChangeFileCount
        )
    }

    private func formattedDelta(_ interval: TimeInterval) -> String {
        guard abs(interval) >= 1 else { return "no change" }
        let sign = interval >= 0 ? "+" : "-"
        let total = Int(abs(interval))
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let mins = (total % 3600) / 60
        let secs = total % 60

        var parts: [String] = []
        if days > 0 { parts.append("\(days)d") }
        if hours > 0 { parts.append("\(hours)h") }
        if mins > 0 { parts.append("\(mins)m") }
        if secs > 0 { parts.append("\(secs)s") }
        if parts.isEmpty { parts.append("0s") }
        return "\(sign)\(parts.joined(separator: " "))"
    }

    // MARK: - Stage Adjustments

    func stageDateTimeAdjustments(session: DateTimeAdjustSession) {
        let previousState = currentPendingEditState()
        var stagedCount = 0

        for fileURL in session.fileURLs {
            let dataModeState = session.mode == .file ? dataModeFileState(for: fileURL, session: session) : nil
            guard let adjusted = session.mode == .file ? dataModeState?.readValue : computeAdjustedDate(for: fileURL, session: session) else {
                continue
            }
            let formatted = Self.exifDateFormatter.string(from: adjusted)
            var stagedForFile = false

            let targetTags: [DateTimeTargetTag]
            if let dataModeState {
                targetTags = dataModeState.destinations.map(\.targetTag)
            } else {
                targetTags = DateTimeTargetTag.allCases.filter { session.applyTo.contains($0) }
            }

            for targetTag in targetTags {
                if let dataModeState,
                   let currentValue = dataModeState.destinations.first(where: { $0.targetTag == targetTag })?.currentValue,
                   dateValuesEqual(currentValue, adjusted) {
                    continue
                }
                guard let tag = editableTag(forID: targetTag.editableTagID) else { continue }
                stageEdit(formatted, for: tag, fileURLs: [fileURL], source: .manual)
                stagedForFile = true
            }
            if stagedForFile {
                stagedCount += 1
            }
        }

        guard stagedCount > 0 else {
            statusMessage = "No date/time changes to stage."
            return
        }

        registerMetadataUndoIfNeeded(previous: previousState)
        recalculateInspectorState(forceNotify: true)
        let noun = stagedCount == 1 ? "1 file" : "\(stagedCount) files"
        setStatusMessage(
            "Prepared date/time changes for \(noun). Ready to apply.",
            autoClearAfterSuccess: true
        )
        pendingDateTimeAdjustSession = nil
    }
}

@MainActor
extension AppModel {

    // MARK: - Location Sheet Lifecycle

    func locationCoordinateFieldsEnabled() -> Bool {
        isInspectorFieldEnabled("exif-gps-lat") && isInspectorFieldEnabled("exif-gps-lon")
    }

    func enabledLocationAdvancedFields() -> [LocationAdvancedField] {
        LocationAdvancedField.allCases.filter { isInspectorFieldEnabled($0.tagID) }
    }

    func canOpenLocationAdjustSheet() -> Bool {
        !selectedFileURLs.isEmpty && locationCoordinateFieldsEnabled()
    }

    func beginLocationAdjust() {
        guard locationCoordinateFieldsEnabled() else {
            statusMessage = "Enable Latitude and Longitude in Inspector Settings to use Set Location."
            return
        }

        let files = Array(selectedFileURLs).sorted {
            let cmp = $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
            if cmp != .orderedSame { return cmp == .orderedAscending }
            return $0.path < $1.path
        }
        guard !files.isEmpty else {
            statusMessage = "No selected files for location adjustment."
            return
        }

        var session = LocationAdjustSession(fileURLs: files)
        if let coordinate = representativeLocationCoordinate(for: files) {
            session.latitude = coordinate.latitude
            session.longitude = coordinate.longitude
        }
        session.includeCoordinates = locationPersistedCoordinates
        session.selectedAdvancedFields = locationPersistedAdvancedFields
            .filter { isInspectorFieldEnabled($0.tagID) }
        pendingLocationAdjustSession = session
    }

    func dismissLocationAdjustSheet() {
        pendingLocationAdjustSession = nil
    }

    func saveLocationFieldSelection(from session: LocationAdjustSession) {
        locationPersistedCoordinates = session.includeCoordinates
        locationPersistedAdvancedFields = session.selectedAdvancedFields
    }

    // MARK: - Location Preview + Stage

    func previewLocationAdjust(session: LocationAdjustSession) -> LocationAdjustAssessment {
        guard locationCoordinateFieldsEnabled() else {
            return LocationAdjustAssessment(
                rows: [],
                blockingIssues: ["Enable Latitude and Longitude in Inspector Settings to use Set Location."],
                warnings: [],
                effectiveChangeFileCount: 0
            )
        }

        let target = coordinate(from: session)
        if session.includeCoordinates && target == nil {
            return LocationAdjustAssessment(
                rows: [],
                blockingIssues: ["Set a location before previewing or applying."],
                warnings: [],
                effectiveChangeFileCount: 0
            )
        }

        var rows: [LocationAdjustPreviewRow] = []
        var warnings: [String] = []
        var effectiveChangeFileCount = 0

        let disabledSelections = session.selectedAdvancedFields
            .filter { !isInspectorFieldEnabled($0.tagID) }
            .sorted { $0.label < $1.label }
        if !disabledSelections.isEmpty {
            let labels = disabledSelections.map(\.label).joined(separator: ", ")
            warnings.append("Ignoring disabled fields: \(labels).")
        }

        let emptySelections = session.selectedAdvancedFields
            .filter { isInspectorFieldEnabled($0.tagID) }
            .filter { session.resolvedValue(for: $0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.label < $1.label }
        if !emptySelections.isEmpty {
            let labels = emptySelections.map(\.label).joined(separator: ", ")
            warnings.append("No resolved value for: \(labels).")
        }

        let advancedTargets = resolvedAdvancedTargets(for: session, respectingSettings: true)

        for fileURL in session.fileURLs {
            let existing = locationCoordinate(for: fileURL)
            var deltaText: String = "no change"
            var coordinateChanged = false

            if session.includeCoordinates, let target {
                if let existing {
                    let distance = CLLocation(latitude: existing.latitude, longitude: existing.longitude)
                        .distance(from: CLLocation(latitude: target.latitude, longitude: target.longitude))
                    if distance >= 1 {
                        coordinateChanged = true
                        deltaText = formattedDistance(distance)
                    }
                } else {
                    coordinateChanged = true
                    deltaText = ""
                }
            }

            var advancedChanged = false
            for target in advancedTargets {
                let existingValue = existingLocationFieldValue(for: fileURL, field: target.field)
                if existingValue != target.value {
                    advancedChanged = true
                    break
                }
            }

            if !coordinateChanged, advancedChanged {
                deltaText = "metadata"
            }

            if coordinateChanged || advancedChanged {
                effectiveChangeFileCount += 1
            }

            rows.append(
                LocationAdjustPreviewRow(
                    id: fileURL,
                    fileName: fileURL.lastPathComponent,
                    originalDisplay: formattedCoordinate(existing),
                    adjustedDisplay: session.includeCoordinates ? formattedCoordinate(target) : formattedCoordinate(existing),
                    deltaText: deltaText
                )
            )
        }

        return LocationAdjustAssessment(
            rows: rows,
            blockingIssues: [],
            warnings: warnings,
            effectiveChangeFileCount: effectiveChangeFileCount
        )
    }

    func stageLocationAdjustments(session: LocationAdjustSession) {
        guard locationCoordinateFieldsEnabled() else {
            statusMessage = "Enable Latitude and Longitude in Inspector Settings to use Set Location."
            return
        }

        if session.includeCoordinates && coordinate(from: session) == nil {
            statusMessage = "Set a location before applying."
            return
        }

        let assessment = previewLocationAdjust(session: session)
        guard assessment.blockingIssues.isEmpty else {
            statusMessage = assessment.blockingIssues.first ?? "Location adjustment is blocked."
            return
        }
        guard assessment.effectiveChangeFileCount > 0 else {
            statusMessage = "No location changes to stage."
            return
        }

        let previousState = currentPendingEditState()
        let advancedTargets = resolvedAdvancedTargets(for: session, respectingSettings: true)

        if session.includeCoordinates, let target = coordinate(from: session),
           let latitudeTag = editableTag(forID: "exif-gps-lat"),
           let longitudeTag = editableTag(forID: "exif-gps-lon") {
            let latitudeValue = Self.compactDecimalString(target.latitude)
            let longitudeValue = Self.compactDecimalString(target.longitude)
            for fileURL in session.fileURLs {
                stageEdit(latitudeValue, for: latitudeTag, fileURLs: [fileURL], source: .manual)
                stageEdit(longitudeValue, for: longitudeTag, fileURLs: [fileURL], source: .manual)
            }
        }

        for fileURL in session.fileURLs {
            for target in advancedTargets {
                let existingValue = existingLocationFieldValue(for: fileURL, field: target.field)
                guard existingValue != target.value else { continue }
                stageEdit(target.value, for: target.tag, fileURLs: [fileURL], source: .manual)
            }
        }

        registerMetadataUndoIfNeeded(previous: previousState)
        recalculateInspectorState(forceNotify: true)
        let noun = assessment.effectiveChangeFileCount == 1
            ? "1 file"
            : "\(assessment.effectiveChangeFileCount) files"
        setStatusMessage(
            "Prepared location changes for \(noun). Ready to apply.",
            autoClearAfterSuccess: true
        )
        pendingLocationAdjustSession = nil
    }

    // MARK: - Location Helpers

    func representativeLocationCoordinate(for fileURLs: [URL]) -> CLLocationCoordinate2D? {
        for fileURL in fileURLs {
            if let coordinate = locationCoordinate(for: fileURL) {
                return coordinate
            }
        }
        return nil
    }

    func locationCoordinate(for fileURL: URL) -> CLLocationCoordinate2D? {
        guard let latitudeTag = editableTag(forID: "exif-gps-lat"),
              let longitudeTag = editableTag(forID: "exif-gps-lon"),
              let snapshot = availableSnapshot(for: fileURL)
        else {
            return nil
        }

        let rawLatitude = normalizedDisplayValue(snapshot, for: latitudeTag)
        let rawLongitude = normalizedDisplayValue(snapshot, for: longitudeTag)
        guard let latitude = parseCoordinateNumber(rawLatitude),
              let longitude = parseCoordinateNumber(rawLongitude),
              (-90 ... 90).contains(latitude),
              (-180 ... 180).contains(longitude)
        else {
            return nil
        }

        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    func formattedCoordinate(_ coordinate: CLLocationCoordinate2D?) -> String {
        guard let coordinate else { return "—" }
        let latitude = Self.compactDecimalString(coordinate.latitude)
        let longitude = Self.compactDecimalString(coordinate.longitude)
        return "\(latitude), \(longitude)"
    }

    private func coordinate(from session: LocationAdjustSession) -> CLLocationCoordinate2D? {
        guard let latitude = session.latitude,
              let longitude = session.longitude,
              (-90 ... 90).contains(latitude),
              (-180 ... 180).contains(longitude)
        else {
            return nil
        }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    private func formattedDistance(_ meters: Double) -> String {
        if meters >= 1_000 {
            return String(format: "%.1f km", meters / 1_000)
        }
        return String(format: "%.0f m", meters)
    }

    private struct LocationAdvancedTarget {
        let field: LocationAdvancedField
        let tag: EditableTag
        let value: String
    }

    private func resolvedAdvancedTargets(
        for session: LocationAdjustSession,
        respectingSettings: Bool
    ) -> [LocationAdvancedTarget] {
        var targets: [LocationAdvancedTarget] = []
        for field in LocationAdvancedField.allCases where session.selectedAdvancedFields.contains(field) {
            if respectingSettings, !isInspectorFieldEnabled(field.tagID) {
                continue
            }
            guard let tag = editableTag(forID: field.tagID) else { continue }
            let value = session.resolvedValue(for: field).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            targets.append(LocationAdvancedTarget(field: field, tag: tag, value: value))
        }
        return targets
    }

    private func existingLocationFieldValue(for fileURL: URL, field: LocationAdvancedField) -> String {
        guard let tag = editableTag(forID: field.tagID),
              let snapshot = availableSnapshot(for: fileURL) else {
            return ""
        }
        return normalizedDisplayValue(snapshot, for: tag).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
