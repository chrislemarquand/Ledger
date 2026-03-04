import Foundation

struct ImportMatcher {
    func match(parseResult: ImportParseResult, targetFiles: [URL]) -> ImportMatchResult {
        let targetSet = Set(targetFiles)
        let byFilename = Dictionary(grouping: targetFiles) { $0.lastPathComponent.lowercased() }
        let rowOrderedTargets = targetFiles

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

        for row in parseResult.rows {
            switch row.targetSelector {
            case let .direct(url):
                if targetSet.contains(url) {
                    matched.append(ImportRowMatch(row: row, targetURL: url))
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
            warnings: parseResult.warnings
        )
    }
}
