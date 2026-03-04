import Foundation

struct ImportConflictResolveResult {
    let assignments: [ImportAssignment]
    let unresolvedConflicts: [ImportConflict]
    let skippedConflicts: [ImportConflict]
}

struct ImportConflictResolver {
    func resolve(
        matchResult: ImportMatchResult,
        resolutions: [UUID: ImportConflictResolutionChoice]
    ) -> ImportConflictResolveResult {
        var assignments: [ImportAssignment] = matchResult.matched.map {
            ImportAssignment(targetURL: $0.targetURL, fields: $0.row.fields)
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
                assignments.append(ImportAssignment(targetURL: url, fields: conflict.rowFields))
            }
        }

        let merged = mergeAssignments(assignments: assignments)
        return ImportConflictResolveResult(
            assignments: merged,
            unresolvedConflicts: unresolved,
            skippedConflicts: skipped
        )
    }

    private func mergeAssignments(assignments: [ImportAssignment]) -> [ImportAssignment] {
        var byTarget: [URL: [String: String]] = [:]
        for assignment in assignments {
            var fieldsByTag = byTarget[assignment.targetURL] ?? [:]
            for field in assignment.fields {
                fieldsByTag[field.tagID] = field.value
            }
            byTarget[assignment.targetURL] = fieldsByTag
        }
        return byTarget.map { targetURL, fieldsByTag in
            let fields = fieldsByTag.keys.sorted().map { key in
                ImportFieldValue(tagID: key, value: fieldsByTag[key] ?? "")
            }
            return ImportAssignment(targetURL: targetURL, fields: fields)
        }.sorted(by: { $0.targetURL.path < $1.targetURL.path })
    }
}
