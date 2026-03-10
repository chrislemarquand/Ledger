import Foundation

struct ImportMatcher {
    func match(parseResult: ImportParseResult, targetFiles: [URL], options: ImportRunOptions) -> ImportMatchResult {
        match(parseResult: parseResult, targetFiles: targetFiles, options: options as ImportRunOptions?)
    }

    func match(parseResult: ImportParseResult, targetFiles: [URL]) -> ImportMatchResult {
        match(parseResult: parseResult, targetFiles: targetFiles, options: nil)
    }

    private func match(parseResult: ImportParseResult, targetFiles: [URL], options: ImportRunOptions?) -> ImportMatchResult {
        let usesReferenceFolderFallback = options?.sourceKind == .referenceFolder && options?.referenceFolderRowFallbackEnabled == true
        let targetSet = Set(targetFiles)
        let byFilename = Dictionary(grouping: targetFiles) { $0.lastPathComponent.lowercased() }
        // Contract: for `.rowNumber(n)` selectors, `targetFiles` must already be in
        // the desired row-parity order from the caller (AppModel.importTargetFiles).
        // This matcher intentionally does not reorder.
        let rowOrderedTargets = targetFiles
        assert(Set(rowOrderedTargets).count == rowOrderedTargets.count, "Row-parity target order expects unique target URLs.")

        var filenameSourceCounts: [String: Int] = [:]
        var rowSourceCounts: [Int: Int] = [:]
        for row in parseResult.rows {
            if case let .filename(name) = row.targetSelector {
                filenameSourceCounts[name.lowercased(), default: 0] += 1
            } else if case let .rowNumber(number) = row.targetSelector {
                rowSourceCounts[number, default: 0] += 1
            }
        }

        var matched: [ImportRowMatch] = []
        var conflicts: [ImportConflict] = []
        var matchedTargets = Set<URL>()
        var filenameFallbackRows: [ImportRow] = []
        var warnings = parseResult.warnings

        for row in parseResult.rows {
            switch row.targetSelector {
            case let .direct(url):
                if targetSet.contains(url) {
                    matched.append(ImportRowMatch(row: row, targetURL: url))
                    matchedTargets.insert(url)
                } else {
                    conflicts.append(
                        ImportConflict(
                            id: UUID(),
                            kind: .missingTarget,
                            sourceLine: row.sourceLine,
                            sourceIdentifier: row.sourceIdentifier,
                            rowFields: row.fields,
                            candidateTargets: [],
                            message: "Target file is not in the current scope."
                        )
                    )
                }

            case let .filename(name):
                let normalized = name.lowercased()
                if (filenameSourceCounts[normalized] ?? 0) > 1 {
                    conflicts.append(
                        ImportConflict(
                            id: UUID(),
                            kind: .duplicateSourceIdentifier,
                            sourceLine: row.sourceLine,
                            sourceIdentifier: row.sourceIdentifier,
                            rowFields: row.fields,
                            candidateTargets: byFilename[normalized] ?? [],
                            message: "Multiple source rows target “\(name)”."
                        )
                    )
                    continue
                }

                let candidates = byFilename[normalized] ?? []
                if candidates.isEmpty {
                    if usesReferenceFolderFallback {
                        filenameFallbackRows.append(row)
                    } else {
                        conflicts.append(
                            ImportConflict(
                                id: UUID(),
                                kind: .missingTarget,
                                sourceLine: row.sourceLine,
                                sourceIdentifier: row.sourceIdentifier,
                                rowFields: row.fields,
                                candidateTargets: [],
                                message: "No target file named “\(name)” in scope."
                            )
                        )
                    }
                } else if candidates.count > 1 {
                    conflicts.append(
                        ImportConflict(
                            id: UUID(),
                            kind: .multipleTargets,
                            sourceLine: row.sourceLine,
                            sourceIdentifier: row.sourceIdentifier,
                            rowFields: row.fields,
                            candidateTargets: candidates.sorted(by: { $0.path < $1.path }),
                            message: "Multiple target files match “\(name)”."
                        )
                    )
                } else if let first = candidates.first {
                    matched.append(ImportRowMatch(row: row, targetURL: first))
                    matchedTargets.insert(first)
                }

            case let .rowNumber(number):
                if (rowSourceCounts[number] ?? 0) > 1 {
                    conflicts.append(
                        ImportConflict(
                            id: UUID(),
                            kind: .duplicateSourceIdentifier,
                            sourceLine: row.sourceLine,
                            sourceIdentifier: row.sourceIdentifier,
                            rowFields: row.fields,
                            candidateTargets: [],
                            message: "Multiple source rows target row \(number)."
                        )
                    )
                    continue
                }
                let index = number - 1
                guard index >= 0, index < rowOrderedTargets.count else {
                    conflicts.append(
                        ImportConflict(
                            id: UUID(),
                            kind: .missingTarget,
                            sourceLine: row.sourceLine,
                            sourceIdentifier: row.sourceIdentifier,
                            rowFields: row.fields,
                            candidateTargets: [],
                            message: "No target file for row \(number) in current scope."
                        )
                    )
                    continue
                }
                matched.append(ImportRowMatch(row: row, targetURL: rowOrderedTargets[index]))
                matchedTargets.insert(rowOrderedTargets[index])
            }
        }

        if usesReferenceFolderFallback, !filenameFallbackRows.isEmpty {
            let unmatchedTargets = rowOrderedTargets.filter { !matchedTargets.contains($0) }
            let matchCount = min(filenameFallbackRows.count, unmatchedTargets.count)

            if matchCount > 0 {
                warnings.append(
                    ImportWarning(
                        sourceLine: nil,
                        message: "Using row-order fallback for \(matchCount) unmatched reference row(s).",
                        severity: .warning
                    )
                )
            }

            for index in 0..<matchCount {
                matched.append(ImportRowMatch(row: filenameFallbackRows[index], targetURL: unmatchedTargets[index]))
            }

            if matchCount < filenameFallbackRows.count {
                for row in filenameFallbackRows.dropFirst(matchCount) {
                    conflicts.append(
                        ImportConflict(
                            id: UUID(),
                            kind: .missingTarget,
                            sourceLine: row.sourceLine,
                            sourceIdentifier: row.sourceIdentifier,
                            rowFields: row.fields,
                            candidateTargets: [],
                            message: "No remaining target file for row-order fallback after filename matching."
                        )
                    )
                }
            }
        }

        let sortedMatches = matched.sorted(by: { lhs, rhs in
            if lhs.row.sourceLine == rhs.row.sourceLine {
                return lhs.targetURL.path < rhs.targetURL.path
            }
            return lhs.row.sourceLine < rhs.row.sourceLine
        })
        let sortedConflicts = conflicts.sorted(by: { lhs, rhs in
            if lhs.sourceLine == rhs.sourceLine {
                return lhs.sourceIdentifier.localizedCaseInsensitiveCompare(rhs.sourceIdentifier) == .orderedAscending
            }
            return lhs.sourceLine < rhs.sourceLine
        })

        return ImportMatchResult(
            matched: sortedMatches,
            conflicts: sortedConflicts,
            warnings: warnings
        )
    }
}
