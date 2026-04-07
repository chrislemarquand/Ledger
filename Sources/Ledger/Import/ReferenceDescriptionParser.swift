import Foundation

/// Parses free-text exposure descriptions (e.g. "F8 250 24-105") into
/// `ImportReviewRow`s with carry-forward lens logic.
enum ReferenceDescriptionParser {

    // MARK: - Public API

    /// Parse a sequence of (fileURL, description) pairs into review rows.
    /// Lens tokens carry forward across rows until a new lens is stated.
    static func parse(rows: [(fileURL: URL, description: String)]) -> [ImportReviewRow] {
        var currentLens: String?
        var result: [ImportReviewRow] = []

        for (fileURL, description) in rows {
            var parsed = parseTokens(in: description)

            var lensIsCarriedForward = false
            if let lens = parsed.lensName {
                currentLens = lens
            } else if let carried = currentLens {
                parsed.lensName = carried
                lensIsCarriedForward = true
            }

            var fields: [ReviewableField] = []
            if let aperture = parsed.aperture {
                fields.append(ReviewableField(tagID: "exif-aperture", value: aperture, isIncluded: true))
            }
            if let shutter = parsed.shutter {
                fields.append(ReviewableField(tagID: "exif-shutter", value: shutter, isIncluded: true))
            }
            if let lens = parsed.lensName {
                fields.append(ReviewableField(
                    tagID: "exif-lens",
                    value: lens,
                    isIncluded: !lens.isEmpty,
                    isEdited: !lensIsCarriedForward
                ))
            }

            result.append(ImportReviewRow(
                fileURL: fileURL,
                fields: fields,
                lensIsCarriedForward: lensIsCarriedForward
            ))
        }

        return result
    }

    // MARK: - Private

    private struct ParsedDescription {
        var aperture: String?
        var shutter: String?
        var lensName: String?
    }

    private static func parseTokens(in description: String) -> ParsedDescription {
        var result = ParsedDescription()
        let tokens = description
            .split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == ";" })
            .map(String.init)

        for token in tokens {
            if let aperture = parseAperture(token) {
                if result.aperture == nil { result.aperture = aperture }
            } else if let shutter = parseShutter(token) {
                if result.shutter == nil { result.shutter = shutter }
            } else if let focal = parseFocalOrLens(token) {
                if result.lensName == nil { result.lensName = focal }
            } else if let bare = parseBareInteger(token, hasAperture: result.aperture != nil) {
                if bare.isShutter, result.shutter == nil {
                    result.shutter = bare.value
                } else if !bare.isShutter, result.aperture == nil {
                    result.aperture = bare.value
                }
            }
        }

        return result
    }

    /// "F8", "f2.8", "f/4" → "8", "2.8", "4"
    private static func parseAperture(_ token: String) -> String? {
        let t = token.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("F") || t.hasPrefix("f") else { return nil }
        var rest = t.dropFirst()
        if rest.hasPrefix("/") { rest = rest.dropFirst() }
        let num = String(rest)
        guard !num.isEmpty, Double(num) != nil else { return nil }
        return num
    }

    /// "1/250" → "1/250"; strips trailing "s" if present
    private static func parseShutter(_ token: String) -> String? {
        var t = token.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasSuffix("s") { t = String(t.dropLast()) }
        guard t.range(of: #"^\d+/\d+$"#, options: .regularExpression) != nil else { return nil }
        return t
    }

    /// "24-105", "50mm", "50-200" → returns as-is; plain lens name text → as-is
    private static func parseFocalOrLens(_ token: String) -> String? {
        let t = token.trimmingCharacters(in: .whitespaces)
        // Focal range e.g. "24-105"
        if t.range(of: #"^\d+-\d+$"#, options: .regularExpression) != nil {
            return t
        }
        // Focal with mm suffix e.g. "50mm"
        if t.lowercased().hasSuffix("mm") {
            let num = String(t.dropLast(2))
            if Double(num) != nil { return t }
        }
        return nil
    }

    /// Bare integer disambiguation:
    /// - n > 22 OR (aperture already found AND n ≥ 60) → shutter denominator
    /// - n ≤ 22 AND no aperture yet → aperture
    private static func parseBareInteger(
        _ token: String,
        hasAperture: Bool
    ) -> (value: String, isShutter: Bool)? {
        let t = token.trimmingCharacters(in: .whitespaces)
        guard let n = Int(t), n > 0, t == "\(n)" else { return nil }
        let treatAsShutter = n > 22 || (hasAperture && n >= 60)
        if treatAsShutter {
            return ("1/\(n)", true)
        } else {
            return (t, false)
        }
    }
}
