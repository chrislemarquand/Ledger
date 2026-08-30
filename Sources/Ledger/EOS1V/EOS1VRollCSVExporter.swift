import Foundation

/// Reformats a roll already parsed from eos1v-serial's own CSV
/// (`EOS1VSessionController.loadFilmRolls`) into Canon's own EOS-1V Memory
/// per-roll export layout — verified byte-for-byte against a real Canon
/// export (`022.CSV`). This never re-invokes or reshapes eos1v-serial's own
/// output; it only reformats data Ledger already has.
///
/// Known limitations, to verify empirically against more real Canon exports:
/// - Numeric formatting (Av/aperture forced to one decimal place; exposure
///   compensation sign convention) is a best-effort match against the single
///   sample available when this was written.
/// - Canon's own export omits optional columns entirely when a roll's
///   recorded-items mask didn't include them. eos1v-serial's CSV doesn't
///   carry that per-roll mask, so this approximates it by omitting a column
///   only when it is blank across every frame in the roll — not a precise
///   match to Canon's mask-driven behavior.
/// - "Custom Function settings" and "Focusing point selection" have no
///   corresponding data in eos1v-serial's CSV at all, so are never emitted.
/// - "Bulb exposure time" has no corresponding data source either; the
///   column is always included but always blank, matching Canon's own
///   behavior for non-bulb frames (bulb frames can't currently be detected).
enum EOS1VRollCSVExporter {
    static func canonCSV(for roll: EOS1VFilmRoll) -> Data {
        var lines: [String] = []

        let (loadedDate, loadedTime) = reformattedDateTime(date: roll.loadedDate, time: roll.loadedTime)
        let isoDX = roll.frames.first?.isoDX ?? ""
        lines.append(csvRow([
            "", "Film ID", paddedFilmID(roll.id), "Title", "",
            "Date and time film loaded", loadedDate, loadedTime,
            "Frame count", "\(roll.frames.count)", "ISO (DX)", isoDX,
        ]))
        lines.append(csvRow(["", "Remarks", ""]))
        lines.append("")

        let includeAFPoint = roll.frames.contains { !$0.afPointAchievingFocus.isEmpty }
        let includeAFSelection = roll.frames.contains { !$0.afPointSelection.isEmpty }
        let includeBattery = roll.frames.contains { !$0.batteryDate.isEmpty || !$0.batteryTime.isEmpty }

        var header = ["", "Frame No.", "Focal length", "Max. aperture", "Tv", "Av", "ISO (M)",
                      "Exposure compensation", "Flash exposure compensation", "Flash mode",
                      "Metering mode", "Shooting mode", "Film advance mode", "AF mode"]
        if includeAFPoint { header.append("AF point achieving focus") }
        if includeAFSelection { header.append("AF point selection") }
        header.append(contentsOf: ["Bulb exposure time", "Date", "Time", "Multiple exposure"])
        if includeBattery { header.append(contentsOf: ["Battery-loaded date", "Battery-loaded time"]) }
        header.append("Remarks")
        lines.append(csvRow(header))

        for frame in roll.frames {
            let (frameDate, frameTime) = reformattedDateTime(date: frame.date, time: frame.time)
            let (batteryDate, batteryTime) = reformattedDateTime(date: frame.batteryDate, time: frame.batteryTime)
            var row = ["", frame.frameNumber, frame.focalLength, oneDecimal(frame.maxAperture),
                      tvFormatted(frame.tv), oneDecimal(frame.av), frame.isoM,
                      signedDecimal(frame.exposureCompensation), signedDecimal(frame.flashExposureCompensation),
                      frame.flashMode.uppercased(), frame.meteringMode, frame.shootingMode,
                      frame.filmAdvance, frame.afMode]
            if includeAFPoint { row.append(frame.afPointAchievingFocus) }
            if includeAFSelection { row.append(frame.afPointSelection) }
            row.append(contentsOf: ["", frameDate, frameTime, frame.multipleExposure.uppercased()])
            if includeBattery { row.append(contentsOf: [batteryDate, batteryTime]) }
            row.append("")
            lines.append(csvRow(row))
        }

        let text = lines.joined(separator: "\r\n") + "\r\n"
        return Data(text.utf8)
    }

    /// eos1v-serial strips leading zeros from the roll number ("00-13");
    /// Canon's own export keeps it zero-padded to 3 digits ("00-024").
    private static func paddedFilmID(_ id: String) -> String {
        let parts = id.split(separator: "-", maxSplits: 1)
        guard parts.count == 2, let number = Int(parts[1]) else { return id }
        return "\(parts[0])-\(String(format: "%03d", number))"
    }

    /// eos1v-serial gives ISO dates ("2025-10-08"); Canon's export uses
    /// unpadded d/M/yyyy ("11/7/2026").
    private static func reformattedDateTime(date: String, time: String) -> (date: String, time: String) {
        let components = date.split(separator: "-")
        guard components.count == 3,
              let year = Int(components[0]), let month = Int(components[1]), let day = Int(components[2])
        else {
            return (date, time)
        }
        return ("\(day)/\(month)/\(year)", time)
    }

    /// Excel forces a "1/60"-shaped string to be reinterpreted as a date
    /// unless wrapped as a formula-literal; Canon's own export does this.
    private static func tvFormatted(_ tv: String) -> String {
        guard !tv.isEmpty else { return "" }
        return "=\"\(tv)\""
    }

    private static func oneDecimal(_ value: String) -> String {
        guard let number = Double(value) else { return value }
        return String(format: "%.1f", number)
    }

    private static func signedDecimal(_ value: String) -> String {
        guard let number = Double(value) else { return value }
        let formatted = String(format: "%.1f", abs(number))
        if number > 0 { return "+\(formatted)" }
        if number < 0 { return "-\(formatted)" }
        return formatted
    }

    private static func csvRow(_ fields: [String]) -> String {
        fields.map(csvEscaped).joined(separator: ",")
    }

    private static func csvEscaped(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") else { return field }
        return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
