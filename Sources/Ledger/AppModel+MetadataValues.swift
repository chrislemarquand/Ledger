import Foundation
import ExifEditCore

@MainActor
extension AppModel {
    func buildPatches(for fileURL: URL) -> [MetadataPatch] {
        guard let staged = pendingEditsByFile[fileURL], !staged.isEmpty else {
            return []
        }

        let enabledIDs = Set(activeInspectorFieldCatalog.filter(\.isEnabled).map(\.id))
        var allPatches: [MetadataPatch] = []
        for (tag, record) in staged {
            guard enabledIDs.contains(tag.id) else { continue }
            allPatches.append(contentsOf: patchesForTag(tag, rawValue: record.value))
        }
        return allPatches
    }

    private func patchesForTag(_ tag: EditableTag, rawValue: String) -> [MetadataPatch] {
        if tag.id == "exif-gps-lat" {
            return gpsPatches(
                rawValue: rawValue,
                valueKey: "GPSLatitude",
                refKey: "GPSLatitudeRef",
                negativeRef: "S",
                positiveRef: "N",
                namespace: .exif
            )
        }
        if tag.id == "exif-gps-lon" {
            return gpsPatches(
                rawValue: rawValue,
                valueKey: "GPSLongitude",
                refKey: "GPSLongitudeRef",
                negativeRef: "W",
                positiveRef: "E",
                namespace: .exif
            )
        }

        let normalized = normalizedWriteValue(rawValue, for: tag)
        var patches: [MetadataPatch] = [
            MetadataPatch(
                key: tag.key,
                namespace: tag.namespace,
                newValue: normalized
            )
        ]

        // Keep Photos-compatible descriptive metadata in sync.
        if tag.id == "xmp-description" {
            patches.append(
                MetadataPatch(
                    key: "Caption-Abstract",
                    namespace: .iptc,
                    newValue: normalized
                )
            )
        } else if tag.id == "xmp-title" {
            patches.append(
                MetadataPatch(
                    key: "ObjectName",
                    namespace: .iptc,
                    newValue: normalized
                )
            )
        } else if tag.id == "xmp-subject" {
            patches.append(
                MetadataPatch(
                    key: "Keywords",
                    namespace: .iptc,
                    newValue: normalized
                )
            )
        } else if tag.id == "iptc-keywords" {
            patches.append(
                MetadataPatch(
                    key: "Subject",
                    namespace: .xmp,
                    newValue: normalized
                )
            )
        } else if tag.id == "exif-exposure-comp" {
            patches.append(
                MetadataPatch(
                    key: "ExposureBiasValue",
                    namespace: .xmp,
                    newValue: normalized
                )
            )
        } else if tag.id == "xmp-exposure-bias" {
            patches.append(
                MetadataPatch(
                    key: "ExposureCompensation",
                    namespace: .exif,
                    newValue: normalized
                )
            )
        }

        return patches
    }

    private func gpsPatches(
        rawValue: String,
        valueKey: String,
        refKey: String,
        negativeRef: String,
        positiveRef: String,
        namespace: MetadataNamespace
    ) -> [MetadataPatch] {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return [
                MetadataPatch(key: valueKey, namespace: namespace, newValue: ""),
                MetadataPatch(key: refKey, namespace: namespace, newValue: ""),
            ]
        }

        if let signed = parseSignedCoordinateForWrite(trimmed, negativeRef: negativeRef, positiveRef: positiveRef) {
            return [
                MetadataPatch(
                    key: valueKey,
                    namespace: namespace,
                    newValue: Self.compactDecimalString(abs(signed))
                ),
                MetadataPatch(
                    key: refKey,
                    namespace: namespace,
                    newValue: signed < 0 ? negativeRef : positiveRef
                ),
            ]
        }

        // If coordinate parsing fails, preserve the original user/import value.
        return [
            MetadataPatch(key: valueKey, namespace: namespace, newValue: trimmed),
        ]
    }

    private func normalizedWriteValue(_ value: String, for tag: EditableTag) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard tag.id == "exif-shutter" else { return trimmed }
        guard !trimmed.isEmpty else { return trimmed }

        if trimmed.contains("/") {
            let parts = trimmed.split(separator: "/", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2,
                  let numerator = Double(parts[0]),
                  let denominator = Double(parts[1]),
                  denominator != 0
            else {
                return trimmed
            }

            return Self.compactDecimalString(numerator / denominator)
        }

        if let decimal = Double(trimmed) {
            return Self.compactDecimalString(decimal)
        }

        return trimmed
    }

    func value(for tag: EditableTag, in snapshot: FileMetadataSnapshot) -> String? {
        if tag.id == "exif-gps-lat" {
            return signedGPSValue(
                valueKey: "GPSLatitude",
                refKey: "GPSLatitudeRef",
                negativeRef: "S",
                snapshot: snapshot
            )
        }
        if tag.id == "exif-gps-lon" {
            return signedGPSValue(
                valueKey: "GPSLongitude",
                refKey: "GPSLongitudeRef",
                negativeRef: "W",
                snapshot: snapshot
            )
        }
        if tag.id == "xmp-description" {
            return prioritizedFieldValue(
                in: snapshot,
                candidates: [
                    (keys: ["Caption-Abstract", "CaptionAbstract"], namespaces: [.iptc]),
                    (keys: ["Description"], namespaces: [.xmp]),
                    (keys: ["Description"], namespaces: [.iptc])
                ]
            )
        }

        let candidateKeys: [String]
        let candidateNamespaces: [MetadataNamespace]

        switch tag.id {
        case "exif-make":
            candidateKeys = [tag.key, "CameraMake"]
            candidateNamespaces = [.exif, .xmp]
        case "exif-model":
            candidateKeys = [tag.key, "CameraModelName"]
            candidateNamespaces = [.exif, .xmp]
        case "exif-serial":
            candidateKeys = [tag.key, "CameraSerialNumber"]
            candidateNamespaces = [.exif, .xmp]
        case "exif-lens":
            candidateKeys = [tag.key, "Lens", "LensID"]
            candidateNamespaces = [.exif, .xmp]
        case "exif-lens-exif":
            candidateKeys = [tag.key, "LensModel", "LensID"]
            candidateNamespaces = [.exif, .xmp]
        case "datetime-modified":
            candidateKeys = [tag.key, "ModifyDate", "FileModifyDate"]
            candidateNamespaces = [.exif, .xmp, .iptc]
        case "datetime-digitized":
            candidateKeys = [tag.key, "CreateDate"]
            candidateNamespaces = [.exif, .xmp]
        case "datetime-created":
            candidateKeys = [tag.key, "CreateDate"]
            candidateNamespaces = [.exif, .xmp, .iptc]
        case "exif-exposure-program":
            candidateKeys = [tag.key]
            candidateNamespaces = [.exif, .xmp]
        case "exif-flash":
            candidateKeys = [tag.key, "FlashFired", "FlashMode"]
            candidateNamespaces = [.exif, .xmp]
        case "exif-metering-mode":
            candidateKeys = [tag.key]
            candidateNamespaces = [.exif, .xmp]
        case "exif-exposure-comp":
            candidateKeys = [tag.key, "ExposureBiasValue"]
            candidateNamespaces = [.exif, .xmp]
        case "xmp-exposure-bias":
            candidateKeys = [tag.key, "ExposureCompensation"]
            candidateNamespaces = [.xmp, .exif]
        case "xmp-city":
            candidateKeys = [tag.key]
            candidateNamespaces = [.xmp, .iptc]
        case "xmp-country":
            candidateKeys = [tag.key, "Country-PrimaryLocationName", "CountryPrimaryLocationName"]
            candidateNamespaces = [.xmp, .iptc]
        case "xmp-state":
            candidateKeys = [tag.key, "Province-State", "ProvinceState"]
            candidateNamespaces = [.xmp, .iptc]
        case "xmp-title":
            candidateKeys = [tag.key, "ObjectName"]
            candidateNamespaces = [.xmp, .iptc]
        case "xmp-description":
            candidateKeys = [tag.key, "Caption-Abstract", "CaptionAbstract"]
            candidateNamespaces = [.xmp, .iptc]
        case "xmp-subject":
            candidateKeys = [tag.key, "Keywords"]
            candidateNamespaces = [.xmp, .iptc]
        case "iptc-keywords":
            candidateKeys = [tag.key, "Subject"]
            candidateNamespaces = [.iptc, .xmp]
        case "xmp-creator":
            candidateKeys = [tag.key, "By-line", "By-lineTitle", "Byline", "BylineTitle"]
            candidateNamespaces = [.xmp, .iptc, .exif]
        default:
            candidateKeys = [tag.key]
            candidateNamespaces = [tag.namespace]
        }

        return preferredFieldValue(
            in: snapshot,
            candidateKeys: candidateKeys,
            candidateNamespaces: candidateNamespaces
        )
    }

    private func preferredFieldValue(
        in snapshot: FileMetadataSnapshot,
        candidateKeys: [String],
        candidateNamespaces: [MetadataNamespace]
    ) -> String? {
        var fallback: String?

        for key in candidateKeys {
            for namespace in candidateNamespaces {
                guard let value = snapshot.fields.first(where: { $0.key == key && $0.namespace == namespace })?.value else {
                    continue
                }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
                if fallback == nil {
                    fallback = trimmed
                }
            }
        }

        return fallback
    }

    private func prioritizedFieldValue(
        in snapshot: FileMetadataSnapshot,
        candidates: [(keys: [String], namespaces: [MetadataNamespace])]
    ) -> String? {
        for candidate in candidates {
            let keySet = Set(candidate.keys)
            let namespaceSet = Set(candidate.namespaces)
            if let value = snapshot.fields.first(where: {
                keySet.contains($0.key) && namespaceSet.contains($0.namespace)
            })?.value,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return value
            }
        }
        return nil
    }

    func signedGPSValue(
        valueKey: String,
        refKey: String,
        negativeRef: String,
        snapshot: FileMetadataSnapshot
    ) -> String? {
        let valueCandidateKeys: Set<String> = [valueKey]
        let valueNamespaces: Set<MetadataNamespace> = [.exif, .xmp]
        guard let rawValue = snapshot.fields.first(where: {
            valueCandidateKeys.contains($0.key) && valueNamespaces.contains($0.namespace)
        })?.value else {
            return nil
        }

        guard let parsed = parseCoordinateNumber(rawValue) else {
            return rawValue
        }

        let ref = snapshot.fields.first(where: { $0.key == refKey && $0.namespace == .exif })?.value
            ?? snapshot.fields.first(where: { $0.key == refKey && $0.namespace == .xmp })?.value

        let signed: Double
        if let ref, ref.uppercased().contains(negativeRef) {
            signed = -abs(parsed)
        } else {
            signed = parsed
        }

        return Self.compactDecimalString(signed)
    }

    func parseCoordinateNumber(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let direct = Double(trimmed) {
            return direct
        }

        let ns = trimmed as NSString
        let regex = try? NSRegularExpression(pattern: "-?\\d+(?:\\.\\d+)?")
        let matches = regex?.matches(in: trimmed, range: NSRange(location: 0, length: ns.length)) ?? []
        let numbers: [Double] = matches.compactMap {
            Double(ns.substring(with: $0.range))
        }
        let hasExplicitNegative = matches.first
            .map { ns.substring(with: $0.range).trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("-") }
            ?? false

        guard let first = numbers.first else { return nil }
        if numbers.count >= 3 {
            let degrees = abs(first)
            let minutes = abs(numbers[1])
            let seconds = abs(numbers[2])
            let composed = degrees + (minutes / 60) + (seconds / 3600)
            return hasExplicitNegative ? -composed : composed
        }
        return first
    }

    private func parseSignedCoordinateForWrite(
        _ raw: String,
        negativeRef: String,
        positiveRef: String
    ) -> Double? {
        guard let parsed = parseCoordinateNumber(raw) else { return nil }
        let uppercase = raw.uppercased()
        let hasNegativeRef = containsStandaloneDirection(negativeRef, in: uppercase)
        let hasPositiveRef = containsStandaloneDirection(positiveRef, in: uppercase)

        if hasNegativeRef, !hasPositiveRef {
            return -abs(parsed)
        }
        if hasPositiveRef, !hasNegativeRef {
            return abs(parsed)
        }
        return parsed
    }

    private func containsStandaloneDirection(_ direction: String, in text: String) -> Bool {
        guard let directionChar = direction.uppercased().first else { return false }
        let chars = Array(text)
        for index in chars.indices where chars[index] == directionChar {
            let prevIsAlphaNum = index > chars.startIndex && isAlphanumeric(chars[index - 1])
            let nextIndex = chars.index(after: index)
            let nextIsAlphaNum = nextIndex < chars.endIndex && isAlphanumeric(chars[nextIndex])
            if !prevIsAlphaNum, !nextIsAlphaNum {
                return true
            }
        }
        return false
    }

    private func isAlphanumeric(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
    }

    func recalculateInspectorState(forceNotify: Bool = false) {
        inspectorDebounceTask?.cancel()
        if forceNotify {
            performRecalculateInspectorState(forceNotify: true)
            return
        }
        inspectorDebounceTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
            guard let self else { return }
            self.performRecalculateInspectorState(forceNotify: forceNotify)
        }
    }

    private func performRecalculateInspectorState(forceNotify: Bool = false) {
        let selectedURLs = Array(selectedFileURLs)
        var didChange = false
        guard !selectedURLs.isEmpty else {
            if !baselineValues.isEmpty {
                baselineValues = [:]
                didChange = true
            }
            if !draftValues.isEmpty {
                draftValues = [:]
                didChange = true
            }
            if !mixedTags.isEmpty {
                mixedTags = []
                didChange = true
            }
            if didChange || forceNotify {
                notifyInspectorDidChange()
            }
            return
        }

        var nextBaseline: [EditableTag: String?] = [:]
        var nextDraft: [EditableTag: String] = [:]
        var nextMixedTags = Set<EditableTag>()

        for tag in activeEditableTags {
            var baselineValuesForTag: [String] = []
            for url in selectedURLs {
                guard let snapshot = availableSnapshot(for: url) else {
                    continue
                }
                baselineValuesForTag.append(normalizedDisplayValue(snapshot, for: tag))
            }
            let uniqueBaselineCanonical = Set(
                baselineValuesForTag.map { canonicalInspectorValue($0, for: tag) }
            )

            var draftValuesForTag: [String] = []
            for url in selectedURLs {
                if let pendingValue = pendingEditsByFile[url]?[tag]?.value {
                    draftValuesForTag.append(pendingValue)
                    continue
                }
                // Show the value that was just written during the reload gap so the
                // inspector never flashes back to the pre-apply on-disk snapshot.
                if let committedValue = pendingCommitsByFile[url]?[tag] {
                    draftValuesForTag.append(committedValue)
                    continue
                }
                guard let snapshot = availableSnapshot(for: url) else {
                    continue
                }
                draftValuesForTag.append(normalizedDisplayValue(snapshot, for: tag))
            }
            let uniqueDraftCanonical = Set(
                draftValuesForTag.map { canonicalInspectorValue($0, for: tag) }
            )

            if uniqueBaselineCanonical.count == 1 {
                nextBaseline[tag] = baselineValuesForTag.first ?? ""
            } else if uniqueBaselineCanonical.isEmpty {
                nextBaseline[tag] = nil
            } else {
                nextBaseline[tag] = nil
                if selectedURLs.count > 1 {
                    nextMixedTags.insert(tag)
                }
            }

            if uniqueDraftCanonical.count == 1 {
                nextDraft[tag] = draftValuesForTag.first ?? ""
            } else if uniqueDraftCanonical.isEmpty {
                nextDraft[tag] = ""
            } else {
                nextDraft[tag] = ""
                if selectedURLs.count > 1 {
                    nextMixedTags.insert(tag)
                }
            }
        }

        if baselineValues != nextBaseline {
            baselineValues = nextBaseline
            didChange = true
        }
        if draftValues != nextDraft {
            draftValues = nextDraft
            didChange = true
        }
        if mixedTags != nextMixedTags {
            mixedTags = nextMixedTags
            didChange = true
        }
        if didChange || forceNotify {
            notifyInspectorDidChange()
        }
    }

    func notifyInspectorDidChange() {
        inspectorRefreshRevision &+= 1
    }

    private func canonicalInspectorValue(_ value: String, for tag: EditableTag) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        switch tag.id {
        case "exif-make", "exif-model", "exif-lens", "exif-lens-exif":
            let squashedWhitespace = trimmed.replacingOccurrences(
                of: "\\s+",
                with: " ",
                options: .regularExpression
            )
            return squashedWhitespace.folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: .current
            )
        case "exif-serial":
            return trimmed.folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: .current
            )
        default:
            return trimmed
        }
    }

    func normalizedDisplayValue(_ snapshot: FileMetadataSnapshot, for tag: EditableTag) -> String {
        guard let raw = value(for: tag, in: snapshot) else {
            return ""
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if tag.id == "exif-shutter" {
            return formatExposureTime(trimmed)
        }
        if tag.id == "exif-exposure-program" || tag.id == "exif-flash" || tag.id == "exif-metering-mode" {
            return normalizeEnumRawValue(trimmed)
        }
        if tag.id == "xmp-copyright-status" {
            return normalizeBooleanRawValue(trimmed)
        }
        if tag.id == "exif-aperture" || tag.id == "exif-focal" || tag.id == "exif-iso" || tag.id == "exif-exposure-comp" || tag.id == "xmp-exposure-bias" {
            return normalizeNumericRawValue(trimmed)
        }

        return trimmed
    }

    private func normalizeEnumRawValue(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let number = Double(trimmed), number.isFinite else { return trimmed }
        let rounded = number.rounded()
        if abs(number - rounded) < 0.000_001 {
            return String(Int(rounded))
        }
        return trimmed
    }

    private func normalizeBooleanRawValue(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        if ["1", "true", "t", "yes", "y"].contains(lowered) {
            return "True"
        }
        if ["0", "false", "f", "no", "n"].contains(lowered) {
            return "False"
        }
        return trimmed
    }

    private func normalizeNumericRawValue(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if trimmed.contains("/") {
            let parts = trimmed.split(separator: "/", maxSplits: 1).map { String($0) }
            if parts.count == 2,
               let numerator = Double(parts[0]),
               let denominator = Double(parts[1]),
               denominator != 0 {
                return Self.compactDecimalString(numerator / denominator)
            }
            return trimmed
        }

        if let value = Double(trimmed), value.isFinite {
            return Self.compactDecimalString(value)
        }
        return trimmed
    }

    private func formatExposureTime(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return raw }
        if trimmed.contains("/") { return trimmed }

        guard let value = Double(trimmed), value > 0 else { return raw }

        if value < 1 {
            let reciprocal = 1.0 / value
            let rounded = reciprocal.rounded()
            if abs(reciprocal - rounded) / max(reciprocal, 1) < 0.03 {
                return "1/\(Int(rounded))"
            }
        }

        let fraction = Self.approximateFraction(value, maxDenominator: 10_000)
        if fraction.denominator == 1 {
            return "\(fraction.numerator)"
        }
        return "\(fraction.numerator)/\(fraction.denominator)"
    }

    private static func approximateFraction(_ value: Double, maxDenominator: Int) -> (numerator: Int, denominator: Int) {
        var x = value
        var a = floor(x)
        var h1 = 1.0
        var k1 = 0.0
        var h = a
        var k = 1.0

        while x - a > 1e-10 && k < Double(maxDenominator) {
            x = 1.0 / (x - a)
            a = floor(x)
            let h2 = h1
            h1 = h
            let k2 = k1
            k1 = k
            h = a * h1 + h2
            k = a * k1 + k2
        }

        let numerator = max(1, Int(h.rounded()))
        let denominator = max(1, Int(k.rounded()))
        let divisor = Self.gcd(numerator, denominator)
        return (numerator / divisor, denominator / divisor)
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var x = abs(a)
        var y = abs(b)
        while y != 0 {
            let r = x % y
            x = y
            y = r
        }
        return max(1, x)
    }

    static let compactDecimalFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.maximumFractionDigits = 8
        f.minimumFractionDigits = 0
        f.decimalSeparator = "."
        f.usesGroupingSeparator = false
        return f
    }()

    static func compactDecimalString(_ value: Double) -> String {
        compactDecimalFormatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    func normalizePresetFields(_ fields: [PresetFieldValue]) -> [PresetFieldValue] {
        var seen = Set<String>()
        var normalized: [PresetFieldValue] = []

        for field in fields {
            let trimmedTagID = field.tagID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedTagID.isEmpty, !seen.contains(trimmedTagID) else { continue }
            seen.insert(trimmedTagID)
            normalized.append(
                PresetFieldValue(
                    tagID: trimmedTagID,
                    value: field.value.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            )
        }

        return normalized
    }

    func sortPresets() {
        presets.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func persistPresets() {
        do {
            try presetStore.savePresets(presets)
        } catch {
            statusMessage = "Couldn’t save presets. \(error.localizedDescription)"
        }
    }

    func parseDate(_ raw: String) -> Date? {
        if let parsed = Self.exifDateFormatter.date(from: raw) {
            return parsed
        }
        if let parsed = Self.iso8601DateFormatter.date(from: raw) {
            return parsed
        }
        if let parsed = Self.fallbackDateFormatter.date(from: raw) {
            return parsed
        }
        return nil
    }
}
