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
        session.sourceTimeZoneID = TimeZone.current.identifier
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
        guard let original = originalDate(for: fileURL, tag: session.launchTag) else { return nil }
        var components = DateComponents()
        components.day = session.shiftDays
        components.hour = session.shiftHours
        components.minute = session.shiftMinutes
        components.second = session.shiftSeconds
        return Calendar.current.date(byAdding: components, to: original)
    }

    private func computeTimeZoneAdjusted(for fileURL: URL, session: DateTimeAdjustSession) -> Date? {
        guard let original = originalDate(for: fileURL, tag: session.launchTag) else { return nil }
        guard let sourceTZ = resolvedSourceTimeZone(for: session),
              let targetTZ = resolvedTargetTimeZone(for: session) else {
            return nil
        }

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
        guard let identifier = resolvedTargetTimeZoneIdentifier(for: session),
              let tz = TimeZone(identifier: identifier) else {
            return ""
        }
        return tz.localizedName(for: .standard, locale: .current) ?? identifier
    }

    private func resolvedSourceTimeZone(for session: DateTimeAdjustSession) -> TimeZone? {
        let identifier = session.sourceTimeZoneID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else { return nil }
        return TimeZone(identifier: identifier)
    }

    private func resolvedTargetTimeZoneIdentifier(for session: DateTimeAdjustSession) -> String? {
        if let identifier = TimeZoneCityData.identifier(forCity: session.closestCity), !identifier.isEmpty {
            return identifier
        }
        let fallback = session.targetTimezone.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? nil : fallback
    }

    private func resolvedTargetTimeZone(for session: DateTimeAdjustSession) -> TimeZone? {
        guard let identifier = resolvedTargetTimeZoneIdentifier(for: session) else { return nil }
        return TimeZone(identifier: identifier)
    }

    // MARK: - Preview

    func previewDateTimeAdjust(session: DateTimeAdjustSession) -> DateTimeAdjustAssessment {
        var rows: [DateTimeAdjustPreviewRow] = []
        var blockingIssues: [String] = []
        var warnings: [String] = []
        var skippedCount = 0
        var effectiveChangeFileCount = 0

        if session.mode == .timeZone {
            if resolvedSourceTimeZone(for: session) == nil {
                blockingIssues.append("Source time zone is invalid.")
            }
            if resolvedTargetTimeZone(for: session) == nil {
                blockingIssues.append("Target time zone is required.")
            }
        }

        for fileURL in session.fileURLs {
            let fileName = fileURL.lastPathComponent
            let original = originalDate(for: fileURL, tag: session.launchTag)
            let adjusted = computeAdjustedDate(for: fileURL, session: session)

            let originalDisplay: String
            let adjustedDisplay: String
            let deltaText: String
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
                if abs(interval) >= 1 {
                    effectiveChangeFileCount += 1
                }
            } else if original == nil, adjusted != nil {
                // Filling a missing date is still an effective change.
                deltaText = ""
                effectiveChangeFileCount += 1
            } else {
                deltaText = ""
            }

            if adjusted == nil {
                skippedCount += 1
                switch session.mode {
                case .file:
                    rowWarnings.append("No file creation date")
                case .timeZone, .shift:
                    rowWarnings.append("No computable source date")
                case .specific:
                    break
                }
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

        if skippedCount == session.fileURLs.count {
            switch session.mode {
            case .file:
                blockingIssues.append("No files have a file creation date to use.")
            case .timeZone, .shift:
                blockingIssues.append("No files have a \(session.launchTag.displayName) date to adjust.")
            case .specific:
                break
            }
        } else if skippedCount > 0 {
            switch session.mode {
            case .file:
                warnings.append("\(skippedCount) file(s) have no file creation date and will be skipped.")
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
            var stagedForFile = false

            for targetTag in session.applyTo {
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
