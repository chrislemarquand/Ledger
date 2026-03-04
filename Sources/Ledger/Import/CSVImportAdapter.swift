import Foundation

struct CSVImportAdapter: ImportSourceAdapter {
    let sourceKind: ImportSourceKind = .csv

    private static let filenameAliases: Set<String> = [
        "filename",
        "file",
        "name",
        "sourcefile",
        "image",
        "imagefile",
        "photo",
    ]

    func parse(context: ImportParseContext) throws -> ImportParseResult {
        let data: Data
        do {
            data = try Data(contentsOf: context.sourceURL)
        } catch {
            throw ImportAdapterError.fileReadFailed(error.localizedDescription)
        }
        let rows = try CSVSupport.parseRows(from: data)
        guard let headerRow = rows.first, !headerRow.isEmpty else {
            throw ImportAdapterError.invalidSchema("CSV is empty.")
        }

        let (filenameColumn, mappedTagColumns, unknownColumns) = buildColumnMapping(
            headerRow: headerRow,
            tagCatalog: context.tagCatalog
        )
        if context.options.matchStrategy == .filename, filenameColumn == nil {
            throw ImportAdapterError.invalidSchema("Couldn’t find a filename column.")
        }

        var warnings: [ImportWarning] = unknownColumns.map {
            ImportWarning(sourceLine: 1, message: "Unsupported column “\($0)” ignored.", severity: .warning)
        }
        var parsedRows: [ImportRow] = []
        var parityRowNumber = 0

        for rowIndex in 1..<rows.count {
            let row = rows[rowIndex]
            let identifier: String
            let selector: ImportTargetSelector
            switch context.options.matchStrategy {
            case .filename:
                guard let filenameColumn else {
                    throw ImportAdapterError.invalidSchema("Couldn’t find a filename column.")
                }
                guard filenameColumn < row.count else {
                    warnings.append(
                        ImportWarning(
                            sourceLine: rowIndex + 1,
                            message: "Missing filename value.",
                            severity: .warning
                        )
                    )
                    continue
                }
                let filename = CSVSupport.trim(row[filenameColumn])
                guard !filename.isEmpty else {
                    warnings.append(
                        ImportWarning(
                            sourceLine: rowIndex + 1,
                            message: "Empty filename value.",
                            severity: .warning
                        )
                    )
                    continue
                }
                identifier = filename
                selector = .filename(filename)
            case .rowParity:
                parityRowNumber += 1
                identifier = String(format: "Row %03d", parityRowNumber)
                selector = .rowNumber(parityRowNumber)
            }

            var fields: [ImportFieldValue] = []
            for (columnIndex, tagID) in mappedTagColumns {
                guard columnIndex < row.count else { continue }
                fields.append(ImportFieldValue(tagID: tagID, value: CSVSupport.trim(row[columnIndex])))
            }

            if fields.isEmpty {
                warnings.append(
                    ImportWarning(
                        sourceLine: rowIndex + 1,
                        message: "No mapped metadata fields found for “\(identifier)”.",
                        severity: .info
                    )
                )
            }

            parsedRows.append(
                ImportRow(
                    sourceLine: rowIndex + 1,
                    sourceIdentifier: identifier,
                    targetSelector: selector,
                    fields: fields
                )
            )
        }

        return ImportParseResult(rows: parsedRows, warnings: warnings)
    }

    private func buildColumnMapping(
        headerRow: [String],
        tagCatalog: [ImportTagDescriptor]
    ) -> (filenameColumn: Int?, mappedTagColumns: [Int: String], unknownColumns: [String]) {
        var filenameColumn: Int?
        var mapped: [Int: String] = [:]
        var unknown: [String] = []

        let tagMappings = buildTagHeaderMap(tagCatalog: tagCatalog)
        for (index, header) in headerRow.enumerated() {
            let normalized = CSVSupport.normalizedHeader(header)
            if Self.filenameAliases.contains(normalized) {
                filenameColumn = index
                continue
            }
            if let tagID = tagMappings[normalized] {
                mapped[index] = tagID
            } else if !CSVSupport.trim(header).isEmpty {
                unknown.append(header)
            }
        }

        return (filenameColumn, mapped, unknown)
    }

    private func buildTagHeaderMap(tagCatalog: [ImportTagDescriptor]) -> [String: String] {
        var map: [String: String] = [:]
        for descriptor in tagCatalog {
            let namespaceKey = "\(descriptor.namespace.rawValue):\(descriptor.key)"
            let namespaceDashKey = "\(descriptor.namespace.rawValue)-\(descriptor.key)"
            let candidates = [
                descriptor.id,
                descriptor.key,
                descriptor.label,
                namespaceKey,
                namespaceDashKey,
            ]
            for candidate in candidates {
                map[CSVSupport.normalizedHeader(candidate)] = descriptor.id
            }
        }
        return map
    }
}
