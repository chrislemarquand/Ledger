import Foundation

public actor BatchRenameService {
    public init() {}

    // MARK: - Plan

    /// Builds a rename plan for the given files. Does not touch the file system beyond
    /// checking for existing names (case-insensitive, matching APFS defaults).
    public func buildPlan(files: [URL], pattern: RenamePattern) -> [RenamePlanEntry] {
        let sorted = files.sorted { a, b in
            let cmp = a.lastPathComponent.localizedStandardCompare(b.lastPathComponent)
            if cmp != .orderedSame { return cmp == .orderedAscending }
            return a.path < b.path
        }

        // Source paths (lowercased) that are being renamed — excluded from FS collision checks
        // so a file is not considered to collide with itself.
        let sourceLower = Set(sorted.map { $0.lastPathComponent.lowercased() })

        let now = Date()
        var plannedLower: Set<String> = []   // lower-cased final target names (for collision detection)
        var entries: [RenamePlanEntry] = []

        for (sequenceIndex, fileURL) in sorted.enumerated() {
            let basename = renderBasename(
                tokens: pattern.tokens,
                originalURL: fileURL,
                sequenceIndex: sequenceIndex,
                date: now
            )
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

    // MARK: - Execute

    public func execute(
        operation: RenameOperation,
        backupManager: some BackupManaging
    ) async throws -> RenameResult {
        let start = Date()
        let operationID = operation.id

        // Build plan
        let plan = buildPlan(files: operation.files, pattern: operation.pattern)

        // Create backup
        let backupURL = try backupManager.createBackup(operationID: operationID, files: operation.files)

        var succeeded: [URL] = []
        var failed: [(URL, any Error & Sendable)] = []

        // Phase A: move each source → unique temp name in same directory
        var tempMoves: [(from: URL, to: URL, finalTarget: URL)] = []
        for entry in plan {
            let tempName = UUID().uuidString + ".rnrtmp"
            let tempURL = entry.sourceURL.deletingLastPathComponent().appendingPathComponent(tempName)
            do {
                try FileManager.default.moveItem(at: entry.sourceURL, to: tempURL)
                tempMoves.append((from: entry.sourceURL, to: tempURL, finalTarget: entry.finalTargetURL))
            } catch {
                // Roll back already-completed Phase A moves
                for completed in tempMoves {
                    try? FileManager.default.moveItem(at: completed.to, to: completed.from)
                }
                throw error
            }
        }

        // Phase B: move each temp name → final target
        var completedFinals: [(temp: URL, final: URL)] = []
        for move in tempMoves {
            do {
                try FileManager.default.moveItem(at: move.to, to: move.finalTarget)
                completedFinals.append((temp: move.to, final: move.finalTarget))
                succeeded.append(move.finalTarget)
            } catch {
                // Leave remaining temp files — they still hold the data safely
                let sendableError = RenameFileError(url: move.from, message: error.localizedDescription)
                failed.append((move.from, sendableError))
            }
        }

        // Record renamed output paths in the backup manifest
        if !succeeded.isEmpty {
            try? backupManager.recordRenamedOutputs(operationID: operationID, renamedPaths: succeeded)
        }

        return RenameResult(
            operationID: operationID,
            succeeded: succeeded,
            failed: failed,
            backupLocation: backupURL,
            duration: Date().timeIntervalSince(start)
        )
    }

    // MARK: - Helpers

    private func renderBasename(
        tokens: [RenameToken],
        originalURL: URL,
        sequenceIndex: Int,
        date: Date
    ) -> String {
        tokens.map { token -> String in
            switch token {
            case .text(let s):
                return s
            case .originalName:
                return originalURL.deletingPathExtension().lastPathComponent
            case .sequence(let start, let step, let padding):
                let value = start + sequenceIndex * step
                return String(format: "%0\(max(1, padding))d", value)
            case .date(let format):
                let formatter = DateFormatter()
                formatter.dateFormat = format
                return formatter.string(from: date)
            }
        }.joined()
    }

    private func resolvedExtension(pattern: RenamePattern, originalURL: URL) -> String {
        if let override = pattern.extensionOverride {
            // Normalise: strip any leading dot the user may have typed
            return override.hasPrefix(".") ? String(override.dropFirst()) : override
        }
        let original = originalURL.pathExtension
        return original
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
            // A file on disk is only a collision if it is NOT one of the sources
            // being renamed (sources will be moved away during the rename).
            return fm.fileExists(atPath: url.path) && !sourceLower.contains(lower)
        }

        // First, try the plain name
        let plain = candidate(suffix: "")
        if !isConflict(plain) { return plain }

        // Disambiguate with _1, _2, …
        var n = 1
        while true {
            let attempt = candidate(suffix: "_\(n)")
            if !isConflict(attempt) { return attempt }
            n += 1
        }
    }
}

// MARK: - Sendable error wrapper

public struct RenameFileError: Error, Sendable {
    public let url: URL
    public let message: String
}
