import Foundation

public actor BatchRenameService {
    private var outputDateFormatters: [DateFormat: DateFormatter] = [:]
    private var exifDateParsers: [String: DateFormatter] = [:]

    public init() {}

    // MARK: - Plan

    public func buildPlan(
        files: [URL],
        pattern: RenamePattern,
        metadata: [URL: FileMetadataSnapshot] = [:],
        assumeSorted: Bool = false
    ) -> [RenamePlanEntry] {
        let sorted = assumeSorted ? files : Self.sortedFiles(files)

        let sourceLower = Set(sorted.map { $0.lastPathComponent.lowercased() })
        let fallbackDate = Date()
        var plannedLower: Set<String> = []
        var entries: [RenamePlanEntry] = []

        for (sequenceIndex, fileURL) in sorted.enumerated() {
            let rawBasename = renderBasename(
                tokens: pattern.tokens,
                originalURL: fileURL,
                sequenceIndex: sequenceIndex,
                fallbackDate: fallbackDate,
                metadata: metadata
            )
            let basename = rawBasename.isEmpty
                ? fileURL.deletingPathExtension().lastPathComponent
                : rawBasename
            let ext = resolvedExtension(pattern: pattern, originalURL: fileURL)
            let directory = fileURL.deletingLastPathComponent()

            let finalURL = resolveCollision(
                directory: directory,
                basename: basename,
                ext: ext,
                existingPlanned: &plannedLower,
                sourceLower: sourceLower
            )

            plannedLower.insert(finalURL.lastPathComponent.lowercased())
            entries.append(RenamePlanEntry(
                sourceURL: fileURL,
                proposedBasename: basename,
                finalTargetURL: finalURL
            ))
        }

        return entries
    }

    public func assessPlan(
        files: [URL],
        pattern: RenamePattern,
        metadata: [URL: FileMetadataSnapshot] = [:],
        assumeSorted: Bool = false
    ) -> RenamePlanAssessment {
        let entries = buildPlan(files: files, pattern: pattern, metadata: metadata, assumeSorted: assumeSorted)
        let issues = validatePlannedEntries(entries, pattern: pattern)
        return RenamePlanAssessment(entries: entries, issues: issues)
    }

    // MARK: - Execute

    public func execute(
        operation: RenameOperation,
        backupManager: some BackupManaging
    ) async throws -> RenameResult {
        let plan = buildPlan(files: operation.files, pattern: operation.pattern)
        let issues = validatePlannedEntries(plan, pattern: operation.pattern)
        if let first = issues.first {
            throw ExifEditError.invalidOperation(first.message)
        }
        return try executePlan(plan: plan, operationID: operation.id, backupManager: backupManager)
    }

    public func executeWithoutBackup(operation: RenameOperation) async throws -> RenameResult {
        let plan = buildPlan(files: operation.files, pattern: operation.pattern)
        let issues = validatePlannedEntries(plan, pattern: operation.pattern)
        if let first = issues.first {
            throw ExifEditError.invalidOperation(first.message)
        }
        return try executePlan(plan: plan, operationID: operation.id, backupManager: nil)
    }

    public func executeStagedMappings(
        targetsBySource: [URL: String],
        operationID: UUID = UUID(),
        backupManager: (any BackupManaging)? = nil
    ) async throws -> RenameResult {
        let sortedSources = targetsBySource.keys.sorted { a, b in
            let cmp = a.lastPathComponent.localizedStandardCompare(b.lastPathComponent)
            if cmp != .orderedSame { return cmp == .orderedAscending }
            return a.path < b.path
        }
        let plan = sortedSources.map { sourceURL -> RenamePlanEntry in
            let targetName = targetsBySource[sourceURL] ?? sourceURL.lastPathComponent
            let targetURL = sourceURL.deletingLastPathComponent().appendingPathComponent(targetName)
            let basename = targetURL.deletingPathExtension().lastPathComponent
            return RenamePlanEntry(
                sourceURL: sourceURL,
                proposedBasename: basename,
                finalTargetURL: targetURL
            )
        }
        let issues = validatePlannedEntries(plan, pattern: RenamePattern())
        if let first = issues.first {
            throw ExifEditError.invalidOperation(first.message)
        }
        return try executePlan(plan: plan, operationID: operationID, backupManager: backupManager)
    }

    // MARK: - Helpers

    private func executePlan(
        plan: [RenamePlanEntry],
        operationID: UUID,
        backupManager: (any BackupManaging)?
    ) throws -> RenameResult {
        let start = Date()
        guard !plan.isEmpty else {
            throw ExifEditError.invalidOperation("No files were selected.")
        }

        let backupURL = try backupManager?.createBackup(operationID: operationID, files: plan.map(\.sourceURL))

        let fm = FileManager.default
        var moves: [(source: URL, temp: URL, final: URL)] = []

        for entry in plan {
            let tempURL = entry.sourceURL
                .deletingLastPathComponent()
                .appendingPathComponent(UUID().uuidString + ".rnrtmp")
            do {
                try fm.moveItem(at: entry.sourceURL, to: tempURL)
                moves.append((source: entry.sourceURL, temp: tempURL, final: entry.finalTargetURL))
            } catch {
                _ = rollbackAtomicMoves(moves)
                throw ExifEditError.invalidOperation("Couldn't rename files. No files were renamed.")
            }
        }

        for move in moves {
            do {
                try fm.moveItem(at: move.temp, to: move.final)
            } catch {
                let rollbackError = rollbackAtomicMoves(moves)
                if let rollbackError {
                    throw ExifEditError.invalidOperation(
                        "Couldn't finish renaming files, and restore was incomplete: \(rollbackError.localizedDescription)"
                    )
                }
                throw ExifEditError.invalidOperation("Couldn't rename files. All files were restored.")
            }
        }

        let succeeded = moves.map(\.final)
        if !succeeded.isEmpty {
            try backupManager?.recordRenamedOutputs(operationID: operationID, renamedPaths: succeeded)
        }

        return RenameResult(
            operationID: operationID,
            succeeded: succeeded,
            failed: [],
            backupLocation: backupURL,
            duration: Date().timeIntervalSince(start)
        )
    }

    private func rollbackAtomicMoves(_ moves: [(source: URL, temp: URL, final: URL)]) -> Error? {
        let fm = FileManager.default
        var rollbackErrors: [String] = []

        for move in moves.reversed() {
            if fm.fileExists(atPath: move.source.path) { continue }
            do {
                if fm.fileExists(atPath: move.final.path) {
                    try fm.moveItem(at: move.final, to: move.source)
                } else if fm.fileExists(atPath: move.temp.path) {
                    try fm.moveItem(at: move.temp, to: move.source)
                }
            } catch {
                rollbackErrors.append(error.localizedDescription)
            }
        }

        guard !rollbackErrors.isEmpty else { return nil }
        return NSError(domain: "BatchRenameService", code: 1, userInfo: [
            NSLocalizedDescriptionKey: rollbackErrors.joined(separator: "; ")
        ])
    }

    private func renderBasename(
        tokens: [RenameToken],
        originalURL: URL,
        sequenceIndex: Int,
        fallbackDate: Date,
        metadata: [URL: FileMetadataSnapshot]
    ) -> String {
        tokens.compactMap { token -> String? in
            switch token {
            case .text(let s):
                return s
            case .originalName:
                return originalURL.deletingPathExtension().lastPathComponent
            case .sequence(let start, let padding):
                let value = start + sequenceIndex
                return String(format: "%0\(padding.rawValue)d", value)
            case .sequenceLetter(let uppercase):
                return letterSequence(index: sequenceIndex, uppercase: uppercase)
            case .date(let source, let format):
                let date = resolveDate(source: source, forURL: originalURL, metadata: metadata, fallback: fallbackDate)
                return formatDate(date, format: format)
            case .extension:
                return nil  // extension token does not contribute to basename
            }
        }.joined()
    }

    private func letterSequence(index: Int, uppercase: Bool) -> String {
        var n = index
        var result = ""
        repeat {
            let scalar = UnicodeScalar(65 + (n % 26))!
            result = String(scalar) + result
            n = n / 26 - 1
        } while n >= 0
        return uppercase ? result : result.lowercased()
    }

    private func formatDate(_ date: Date, format: DateFormat) -> String {
        formatter(for: format).string(from: date)
    }

    private func resolveDate(
        source: DateSource,
        forURL url: URL,
        metadata: [URL: FileMetadataSnapshot],
        fallback: Date
    ) -> Date {
        guard let snapshot = metadata[url] else { return fallback }
        let keysToCheck: [String]
        switch source {
        case .dateTimeOriginal: keysToCheck = ["DateTimeOriginal"]
        case .createDate:       keysToCheck = ["CreateDate"]
        case .modifyDate:       keysToCheck = ["ModifyDate", "FileModifyDate"]
        }
        for key in keysToCheck {
            if let field = snapshot.fields.first(where: { $0.key == key }),
               let date = parseExifDate(field.value) {
                return date
            }
        }
        return fallback
    }

    private func parseExifDate(_ string: String) -> Date? {
        let formats = ["yyyy:MM:dd HH:mm:ssXXXXX", "yyyy:MM:dd HH:mm:ss", "yyyy:MM:dd"]
        for format in formats {
            if let date = parser(for: format).date(from: string) { return date }
        }
        return nil
    }

    private static func sortedFiles(_ files: [URL]) -> [URL] {
        files.sorted { a, b in
            let cmp = a.lastPathComponent.localizedStandardCompare(b.lastPathComponent)
            if cmp != .orderedSame { return cmp == .orderedAscending }
            return a.path < b.path
        }
    }

    private func formatter(for format: DateFormat) -> DateFormatter {
        if let cached = outputDateFormatters[format] { return cached }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = format.dateFormatString
        outputDateFormatters[format] = df
        return df
    }

    private func parser(for format: String) -> DateFormatter {
        if let cached = exifDateParsers[format] { return cached }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = format
        exifDateParsers[format] = df
        return df
    }

    private func resolvedExtension(pattern: RenamePattern, originalURL: URL) -> String {
        for token in pattern.tokens {
            if case .extension(let ext) = token {
                let normalized = ext.hasPrefix(".") ? String(ext.dropFirst()) : ext
                return normalized
            }
        }
        return originalURL.pathExtension
    }

    private func resolveCollision(
        directory: URL,
        basename: String,
        ext: String,
        existingPlanned: inout Set<String>,
        sourceLower: Set<String>
    ) -> URL {
        let fm = FileManager.default

        func candidate(suffix: String) -> URL {
            let name = suffix.isEmpty
                ? (ext.isEmpty ? basename : "\(basename).\(ext)")
                : (ext.isEmpty ? "\(basename)\(suffix)" : "\(basename)\(suffix).\(ext)")
            return directory.appendingPathComponent(name)
        }

        func isConflict(_ url: URL) -> Bool {
            let lower = url.lastPathComponent.lowercased()
            if existingPlanned.contains(lower) { return true }
            return fm.fileExists(atPath: url.path) && !sourceLower.contains(lower)
        }

        let plain = candidate(suffix: "")
        if !isConflict(plain) { return plain }

        var n = 1
        while true {
            let attempt = candidate(suffix: "_\(n)")
            if !isConflict(attempt) { return attempt }
            n += 1
        }
    }

    private func validatePlannedEntries(
        _ entries: [RenamePlanEntry],
        pattern: RenamePattern
    ) -> [RenameValidationIssue] {
        var issues: [RenameValidationIssue] = []
        let invalidCharacters = CharacterSet(charactersIn: "/:\0")
        let sourceSet = Set(entries.map { $0.sourceURL.path.lowercased() })
        var targetLower: Set<String> = []
        let fm = FileManager.default

        // Validate any .extension tokens
        for token in pattern.tokens {
            if case .extension(let ext) = token {
                let normalized = ext.hasPrefix(".") ? String(ext.dropFirst()) : ext
                if normalized.isEmpty {
                    issues.append(RenameValidationIssue(message: "Enter an extension or remove the New Extension token."))
                } else if normalized.rangeOfCharacter(from: invalidCharacters) != nil {
                    issues.append(RenameValidationIssue(message: "Extension contains invalid characters."))
                }
            }
        }

        for entry in entries {
            let targetName = entry.finalTargetURL.lastPathComponent
            let basename = entry.finalTargetURL.deletingPathExtension().lastPathComponent

            if basename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(RenameValidationIssue(
                    sourceURL: entry.sourceURL,
                    message: "Filename can't be empty."
                ))
                continue
            }
            if targetName == "." || targetName == ".." {
                issues.append(RenameValidationIssue(
                    sourceURL: entry.sourceURL,
                    message: "Filename is invalid."
                ))
                continue
            }
            if targetName.rangeOfCharacter(from: invalidCharacters) != nil {
                issues.append(RenameValidationIssue(
                    sourceURL: entry.sourceURL,
                    message: "Filename contains invalid characters."
                ))
                continue
            }

            let lowerTargetPath = entry.finalTargetURL.path.lowercased()
            if targetLower.contains(lowerTargetPath) {
                issues.append(RenameValidationIssue(
                    sourceURL: entry.sourceURL,
                    message: "Two files would end up with the same name."
                ))
                continue
            }
            targetLower.insert(lowerTargetPath)

            if fm.fileExists(atPath: entry.finalTargetURL.path), !sourceSet.contains(lowerTargetPath) {
                issues.append(RenameValidationIssue(
                    sourceURL: entry.sourceURL,
                    message: "A file with that name already exists."
                ))
            }
        }

        return issues
    }
}

// MARK: - Sendable error wrapper

public struct RenameFileError: Error, Sendable {
    public let url: URL
    public let message: String
}
