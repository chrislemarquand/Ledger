import Foundation
import SharedUI

@MainActor
extension AppModel {

    // MARK: - Sheet Lifecycle

    func beginDateTimeAdjust(scope: DateTimeAdjustScope, launchTag: DateTimeTargetTag) {
        let files = filesForDateTimeAdjust(scope)
        guard !files.isEmpty else {
            statusMessage = "No files in scope for date/time adjustment."
            return
        }

        var session = DateTimeAdjustSession(
            scope: scope,
            launchTag: launchTag,
            fileURLs: files
        )
        session.applyTo = [launchTag]
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
        guard let editableTag = editableTag(forID: tag.editableTagID) else { return nil }
        guard let snapshot = availableSnapshot(for: fileURL) else { return nil }
        let raw = normalizedDisplayValue(snapshot, for: editableTag)
        guard !raw.isEmpty else { return nil }
        return parseDate(raw)
    }

    func fileCreationDate(for fileURL: URL) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.creationDate] as? Date
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
            return fileCreationDate(for: fileURL)
        }
    }

    private func computeShiftAdjusted(for fileURL: URL, session: DateTimeAdjustSession) -> Date? {
        guard let original = originalDate(for: fileURL, tag: .dateTimeOriginal) else { return nil }
        var components = DateComponents()
        components.day = session.shiftDays
        components.hour = session.shiftHours
        components.minute = session.shiftMinutes
        components.second = session.shiftSeconds
        return Calendar.current.date(byAdding: components, to: original)
    }

    private func computeTimeZoneAdjusted(for fileURL: URL, session: DateTimeAdjustSession) -> Date? {
        guard let original = originalDate(for: fileURL, tag: .dateTimeOriginal) else { return nil }

        let sourceIdentifier: String
        switch session.sourceBasis {
        case .fixedUTC:
            sourceIdentifier = "UTC"
        case .ianaTimeZone(let id):
            sourceIdentifier = id
        case .useEmbeddedOffsetWhenAvailable(let fallback):
            if let offset = embeddedOffsetString(for: fileURL),
               let tz = timeZone(fromOffsetString: offset) {
                sourceIdentifier = tz.identifier
            } else {
                sourceIdentifier = fallback
            }
        }

        guard let targetIdentifier = TimeZoneCityData.identifier(forCity: session.closestCity) ?? Optional(session.targetTimezone),
              !targetIdentifier.isEmpty else { return original }

        guard let sourceTZ = TimeZone(identifier: sourceIdentifier),
              let targetTZ = TimeZone(identifier: targetIdentifier) else { return original }

        let sourceOffset = sourceTZ.secondsFromGMT(for: original)
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

    private func timeZone(fromOffsetString offset: String) -> TimeZone? {
        // Parse "+05:30" or "-08:00" style offsets
        let trimmed = offset.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 5 else { return nil }
        let sign: Int = trimmed.hasPrefix("-") ? -1 : 1
        let digits = trimmed.dropFirst().replacingOccurrences(of: ":", with: "")
        guard digits.count >= 4,
              let hours = Int(digits.prefix(2)),
              let minutes = Int(digits.suffix(2)) else { return nil }
        let seconds = sign * (hours * 3600 + minutes * 60)
        return TimeZone(secondsFromGMT: seconds)
    }

    // MARK: - Resolved Timezone Name

    func resolvedTimeZoneName(for session: DateTimeAdjustSession) -> String {
        guard let identifier = TimeZoneCityData.identifier(forCity: session.closestCity),
              let tz = TimeZone(identifier: identifier) else {
            return ""
        }
        return tz.localizedName(for: .standard, locale: .current) ?? identifier
    }

    // MARK: - Preview

    func previewDateTimeAdjust(session: DateTimeAdjustSession) -> DateTimeAdjustAssessment {
        var rows: [DateTimeAdjustPreviewRow] = []
        var blockingIssues: [String] = []
        var warnings: [String] = []
        var filesWithNoOriginal = 0

        for fileURL in session.fileURLs {
            let fileName = fileURL.lastPathComponent
            let original = originalDate(for: fileURL, tag: .dateTimeOriginal)
            let adjusted = computeAdjustedDate(for: fileURL, session: session)

            let originalDisplay: String
            let adjustedDisplay: String
            let deltaText: String
            var rowWarnings: [String] = []

            if let original {
                originalDisplay = Self.exifDateFormatter.string(from: original)
            } else {
                originalDisplay = "—"
                filesWithNoOriginal += 1
                rowWarnings.append("No original date")
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

            rows.append(DateTimeAdjustPreviewRow(
                id: fileURL,
                fileName: fileName,
                originalDisplay: originalDisplay,
                adjustedDisplay: adjustedDisplay,
                deltaText: deltaText,
                warnings: rowWarnings
            ))
        }

        if filesWithNoOriginal == session.fileURLs.count {
            blockingIssues.append("No files have a DateTimeOriginal value to adjust.")
        } else if filesWithNoOriginal > 0 {
            warnings.append("\(filesWithNoOriginal) file(s) have no DateTimeOriginal and will be skipped.")
        }

        if session.applyTo.isEmpty {
            blockingIssues.append("No target tags selected in \"Apply to\".")
        }

        return DateTimeAdjustAssessment(rows: rows, blockingIssues: blockingIssues, warnings: warnings)
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
            guard let adjusted = computeAdjustedDate(for: fileURL, session: session) else { continue }
            let formatted = Self.exifDateFormatter.string(from: adjusted)

            for targetTag in session.applyTo {
                guard let tag = editableTag(forID: targetTag.editableTagID) else { continue }
                stageEdit(formatted, for: tag, fileURLs: [fileURL], source: .manual)
            }
            stagedCount += 1
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

