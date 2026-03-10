import Foundation

struct ImportConflictResolveResult {
    let assignments: [ImportAssignment]
    let unresolvedConflicts: [ImportConflict]
    let skippedConflicts: [ImportConflict]
    let warnings: [String]
}

struct ImportConflictResolver {
    func resolve(
        matchResult: ImportMatchResult,
        resolutions: [UUID: ImportConflictResolutionChoice]
    ) -> ImportConflictResolveResult {
        var entries: [AssignmentEntry] = matchResult.matched.map {
            AssignmentEntry(
                assignment: ImportAssignment(targetURL: $0.targetURL, fields: $0.row.fields),
                origin: .matched(sourceLine: $0.row.sourceLine)
            )
        }
        var unresolved: [ImportConflict] = []
        var skipped: [ImportConflict] = []

        for conflict in matchResult.conflicts {
            guard let resolution = resolutions[conflict.id] else {
                unresolved.append(conflict)
                continue
            }

            switch resolution {
            case .skip:
                skipped.append(conflict)
            case let .target(url):
                entries.append(
                    AssignmentEntry(
                        assignment: ImportAssignment(targetURL: url, fields: conflict.rowFields),
                        origin: .resolvedConflict(sourceLine: conflict.sourceLine)
                    )
                )
            }
        }

        let merged = mergeAssignments(entries: entries)
        return ImportConflictResolveResult(
            assignments: merged.assignments,
            unresolvedConflicts: unresolved,
            skippedConflicts: skipped,
            warnings: merged.warnings
        )
    }

    private func mergeAssignments(entries: [AssignmentEntry]) -> (assignments: [ImportAssignment], warnings: [String]) {
        var byTarget: [URL: [String: String]] = [:]
        var originByTarget: [URL: [String: AssignmentOrigin]] = [:]
        var warnings: [String] = []
        for entry in entries {
            var fieldsByTag = byTarget[entry.assignment.targetURL] ?? [:]
            var fieldOrigins = originByTarget[entry.assignment.targetURL] ?? [:]
            for field in entry.assignment.fields {
                if let existingValue = fieldsByTag[field.tagID],
                   existingValue != field.value {
                    let previousOrigin = fieldOrigins[field.tagID]?.description ?? "previous assignment"
                    warnings.append(
                        "Field collision for \(entry.assignment.targetURL.lastPathComponent) tag \(field.tagID): " +
                        "\(previousOrigin) value was overwritten by \(entry.origin.description)."
                    )
                }
                fieldsByTag[field.tagID] = field.value
                fieldOrigins[field.tagID] = entry.origin
            }
            byTarget[entry.assignment.targetURL] = fieldsByTag
            originByTarget[entry.assignment.targetURL] = fieldOrigins
        }
        let assignments = byTarget.map { targetURL, fieldsByTag in
            let fields = fieldsByTag.keys.sorted().map { key in
                ImportFieldValue(tagID: key, value: fieldsByTag[key] ?? "")
            }
            return ImportAssignment(targetURL: targetURL, fields: fields)
        }.sorted(by: { $0.targetURL.path < $1.targetURL.path })
        return (assignments: assignments, warnings: warnings)
    }
}

private struct AssignmentEntry {
    let assignment: ImportAssignment
    let origin: AssignmentOrigin
}

private enum AssignmentOrigin {
    case matched(sourceLine: Int)
    case resolvedConflict(sourceLine: Int)

    var description: String {
        switch self {
        case let .matched(sourceLine):
            return "matched row \(sourceLine)"
        case let .resolvedConflict(sourceLine):
            return "resolved conflict row \(sourceLine)"
        }
    }
}
