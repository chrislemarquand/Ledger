import Foundation

struct ImportReportWriter {
    func makeInitialReport(
        sourceKind: ImportSourceKind,
        parseResult: ImportParseResult,
        matchResult: ImportMatchResult
    ) -> ImportReport {
        var rows: [ImportReportRow] = []

        rows.append(contentsOf: parseResult.warnings.map {
            ImportReportRow(
                sourceLine: $0.sourceLine,
                sourceIdentifier: "",
                targetPath: nil,
                status: .warning,
                message: $0.message
            )
        })

        rows.append(contentsOf: matchResult.matched.map {
            ImportReportRow(
                sourceLine: $0.row.sourceLine,
                sourceIdentifier: $0.row.sourceIdentifier,
                targetPath: $0.targetURL.path,
                status: .matched,
                message: "Matched"
            )
        })

        rows.append(contentsOf: matchResult.conflicts.map {
            ImportReportRow(
                sourceLine: $0.sourceLine,
                sourceIdentifier: $0.sourceIdentifier,
                targetPath: nil,
                status: .conflict,
                message: $0.message
            )
        })

        let summary = ImportPreviewSummary(
            sourceKind: sourceKind,
            parsedRows: parseResult.rows.count,
            matchedRows: matchResult.matched.count,
            conflictedRows: matchResult.conflicts.count,
            warnings: parseResult.warnings.count,
            fieldWrites: matchResult.matched.reduce(0) { $0 + $1.row.fields.count }
        )

        return ImportReport(
            sourceKind: sourceKind,
            generatedAt: Date(),
            summary: summary,
            rows: rows.sorted(by: { lhs, rhs in
                switch (lhs.sourceLine, rhs.sourceLine) {
                case let (left?, right?):
                    return left < right
                case (nil, nil):
                    return lhs.message < rhs.message
                case (nil, _?):
                    return false
                case (_?, nil):
                    return true
                }
            })
        )
    }

    func appendStagingRows(
        report: ImportReport,
        stagedAssignments: [ImportAssignment],
        skippedConflicts: [ImportConflict]
    ) -> ImportReport {
        var rows = report.rows
        rows.append(contentsOf: skippedConflicts.map {
            ImportReportRow(
                sourceLine: $0.sourceLine,
                sourceIdentifier: $0.sourceIdentifier,
                targetPath: nil,
                status: .skipped,
                message: "Skipped by user during conflict resolution."
            )
        })
        rows.append(contentsOf: stagedAssignments.map {
            ImportReportRow(
                sourceLine: nil,
                sourceIdentifier: $0.targetURL.lastPathComponent,
                targetPath: $0.targetURL.path,
                status: .staged,
                message: "Staged \($0.fields.count) field(s)."
            )
        })

        return ImportReport(
            sourceKind: report.sourceKind,
            generatedAt: Date(),
            summary: report.summary,
            rows: rows
        )
    }

    func writeCSV(report: ImportReport, to url: URL) throws {
        var lines: [String] = ["SourceLine,SourceIdentifier,TargetPath,Status,Message"]
        for row in report.rows {
            lines.append(
                [
                    row.sourceLine.map(String.init) ?? "",
                    escape(row.sourceIdentifier),
                    escape(row.targetPath ?? ""),
                    row.status.rawValue,
                    escape(row.message),
                ].joined(separator: ",")
            )
        }
        let content = lines.joined(separator: "\n")
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func escape(_ input: String) -> String {
        if input.contains(",") || input.contains("\"") || input.contains("\n") {
            return "\"\(input.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return input
    }
}
