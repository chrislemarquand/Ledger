import Foundation

// MARK: - Models

struct EOS1VFilm {
    let header: [UInt8]
    let frames: [[UInt8]]

    /// `hd[5:7]` = 3-digit film number (BCD), `hd[7]` = 2-digit prefix (BCD).
    /// Matches the camera's own frame imprint, e.g. "26-218".
    var filmID: String {
        guard header.count > 7 else { return "??-??" }
        let prefix = String(format: "%02x", header[7])
        var number = String(format: "%02x%02x", header[5], header[6])
        while number.count > 1, number.hasPrefix("0") { number.removeFirst() }
        return "\(prefix)-\(number)"
    }

    /// `hd[18]` — the DX-read film speed. `0xF0` means the cassette had no DX code.
    var dxSpeedByte: UInt8 { header.count > 18 ? header[18] : 0xF0 }

    /// `hd[9:17]` — the per-film "items to be recorded" mask that drives record layout.
    var itemsMask: [UInt8] {
        guard header.count >= 17 else { return EOS1VFrameDecoder.baselineMask }
        return Array(header[9 ..< 17])
    }

    var loadedDate: String? { EOS1VFrameDecoder.bcdDate(Array(header.dropFirst(19).prefix(3))) }
    var loadedTime: String? { EOS1VFrameDecoder.bcdTime(Array(header.dropFirst(22).prefix(3))) }
}

/// One decoded frame. Field names match ES-E1's CSV columns so the export can be
/// byte-compatible with Canon's own output.
struct EOS1VFrameRow {
    var frameNumber: Int
    var focalLength = ""
    var maxAperture = ""
    var tv = ""
    var av = ""
    var isoDX = ""
    var isoManual = ""
    var exposureCompensation = ""
    var flashExposureCompensation = ""
    var shootingMode = ""
    var meteringMode = ""
    var flashMode = ""
    var filmAdvance = ""
    var afMode = ""
    var afPointAchievingFocus = ""
    var afPointSelection = ""
    var multipleExposure = false
    var date = ""
    var time = ""
    var batteryDate = ""
    var batteryTime = ""
    /// Layout could not be trusted (record length disagreed with the mask, or
    /// non-padding bytes where padding was expected). Values are suspect.
    var layoutUntrusted = false
    /// The mask set a bit belonging to an item we cannot identify.
    var hasUnknownItems = false
}

// MARK: - Decoder

/// Decodes EOS-1V frame records.
///
/// **The record layout is compositional, not fixed.** A frame record is the enabled
/// "shooting data items to be recorded" concatenated in a fixed canonical order, each a
/// fixed size, then `0xFF` padding — there is no fixed prefix. The film's 8-byte mask
/// (`hd[9:17]`) says which items are present, and therefore where every field sits.
/// Every set bit corresponds to exactly one recorded byte, so a field's offset is
/// `3 + (count of set bits before it)`.
enum EOS1VFrameDecoder {

    static let baselineMask: [UInt8] = [0xFF, 0xFF, 0x00, 0x3F, 0x00, 0x08, 0x00, 0x3F]

    /// (name, size, mask byte index relative to hd[9], presence bit) in record order.
    /// `hd[9]` bits 7 and 6 are film-header items, not part of the frame record.
    private struct FieldSpec {
        let name: String
        let size: Int
        let maskByte: Int
        let bit: Int
    }

    private static let fields: [FieldSpec] = [
        .init(name: "focal", size: 2, maskByte: 0, bit: 5),
        .init(name: "maxap", size: 1, maskByte: 0, bit: 3),
        .init(name: "Tv", size: 1, maskByte: 0, bit: 2),
        .init(name: "Av", size: 1, maskByte: 0, bit: 1),
        .init(name: "ISO", size: 1, maskByte: 0, bit: 0),
        .init(name: "expcomp", size: 1, maskByte: 1, bit: 7),
        .init(name: "flashcomp", size: 1, maskByte: 1, bit: 6),
        .init(name: "flashmode", size: 1, maskByte: 1, bit: 5),
        .init(name: "metering", size: 1, maskByte: 1, bit: 4),
        .init(name: "mode", size: 1, maskByte: 1, bit: 3),        // mandatory
        .init(name: "drive", size: 1, maskByte: 1, bit: 2),
        .init(name: "afmode", size: 1, maskByte: 1, bit: 1),
        .init(name: "pad16", size: 1, maskByte: 1, bit: 0),       // mandatory
        .init(name: "bulb", size: 2, maskByte: 2, bit: 3),
        .init(name: "shotdate", size: 3, maskByte: 3, bit: 5),
        .init(name: "shottime", size: 3, maskByte: 3, bit: 2),
        .init(name: "cfn", size: 11, maskByte: 4, bit: 6),        // spans hd13→hd14
        .init(name: "focus", size: 1, maskByte: 5, bit: 3),
        .init(name: "selection", size: 7, maskByte: 6, bit: 6),
        .init(name: "batdate", size: 3, maskByte: 7, bit: 5),
        .init(name: "battime", size: 3, maskByte: 7, bit: 2),
    ]

    private static let sizes: [String: Int] =
        Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.size) })

    /// hd[9] bits 7 and 6 are mandatory *header* items, not frame-record bytes.
    private static let headerBits: Set<Pair> = [Pair(0, 7), Pair(0, 6)]

    private struct Pair: Hashable {
        let byte: Int, bit: Int
        init(_ byte: Int, _ bit: Int) { self.byte = byte; self.bit = bit }
    }

    /// Every (byte, bit) a mapped field occupies, walking MSB-first and wrapping into
    /// subsequent mask bytes — a field can span bytes (the 11-byte C.Fn item does).
    private static func occupiedBits(_ spec: FieldSpec) -> [Pair] {
        var out: [Pair] = []
        var byte = spec.maskByte
        var bit = spec.bit
        for _ in 0 ..< spec.size {
            out.append(Pair(byte, bit))
            bit -= 1
            if bit < 0 { bit = 7; byte += 1 }
        }
        return out
    }

    private static let fieldStarts: [Pair: String] =
        Dictionary(uniqueKeysWithValues: fields.map { (Pair($0.maskByte, $0.bit), $0.name) })

    private static let knownBits: Set<Pair> = {
        var set = headerBits
        for spec in fields { set.formUnion(occupiedBits(spec)) }
        return set
    }()

    struct Layout {
        let offsets: [String: Int]
        let total: Int
        let hasUnknownItems: Bool
    }

    /// Walks the mask MSB-first, bytes in order, counting one recorded byte per set bit.
    static func layout(for mask: [UInt8]) -> Layout {
        let m = mask.count >= 8 ? Array(mask.prefix(8)) : baselineMask
        var offsets: [String: Int] = [:]
        var offset = 3                                  // the [01][81][seq] header
        var unknown = false
        for byteIndex in 0 ..< 8 {
            for bit in stride(from: 7, through: 0, by: -1) {
                let pair = Pair(byteIndex, bit)
                if headerBits.contains(pair) { continue }
                guard m[byteIndex] & (1 << UInt8(bit)) != 0 else { continue }
                if let name = fieldStarts[pair] {
                    offsets[name] = offset
                } else if !knownBits.contains(pair) {
                    unknown = true
                }
                offset += 1                             // every set bit is one byte
            }
        }
        return Layout(offsets: offsets, total: offset, hasUnknownItems: unknown)
    }

    // MARK: Frame decoding

    static func decode(frame: [UInt8], frameNumber: Int, dxSpeed: UInt8, mask: [UInt8]) -> EOS1VFrameRow {
        let layout = layout(for: mask)
        var row = EOS1VFrameRow(frameNumber: frameNumber)
        row.hasUnknownItems = layout.hasUnknownItems

        // Structural check valid for any mask: bits==bytes means the recorded content
        // is exactly frame[0..<total] and everything after must be 0xFF padding. If that
        // holds, offsets are trustworthy even when unidentified items sit among them.
        let trusted = layout.total <= frame.count
            && frame[layout.total...].allSatisfy { $0 == 0xFF }
        row.layoutUntrusted = !trusted
        guard trusted else { return row }

        func bytes(_ name: String) -> [UInt8]? {
            guard let offset = layout.offsets[name], let size = sizes[name],
                  offset + size <= frame.count else { return nil }
            return Array(frame[offset ..< (offset + size)])
        }
        func byte(_ name: String) -> UInt8? { bytes(name)?.first }

        row.date = bytes("shotdate").flatMap(bcdDate) ?? ""
        row.time = bytes("shottime").flatMap(bcdTime) ?? ""
        row.batteryDate = bytes("batdate").flatMap(bcdDate) ?? ""
        row.batteryTime = bytes("battime").flatMap(bcdTime) ?? ""

        // ISO: the header holds the DX-read speed; the frame's ISO field is the actual
        // taking speed. ES-E1 shows a manual "(M)" value when the film had no DX code,
        // or when the taking speed was overridden away from it.
        let hasDX = ![0x00, 0xF0, 0xFF].contains(dxSpeed)
        let isoByte = byte("ISO")
        row.isoDX = hasDX ? isoFromSv(dxSpeed) : ""
        let manual = !hasDX || (isoByte != nil && isoByte != dxSpeed)
        row.isoManual = manual ? (isoByte.map(isoFromSv) ?? "") : ""

        let modeByte = byte("mode")
        let mode = modeByte.map { label(exposureModes, $0 & 0xFC) } ?? ""
        row.shootingMode = mode

        if let focal = bytes("focal") {
            let mm = (Int(focal[0]) << 8) | Int(focal[1])       // big-endian; >255mm needs both
            row.focalLength = mm != 0 ? "\(mm)mm" : ""
        }
        row.maxAperture = byte("maxap").map(apexAperture) ?? ""
        if let tv = byte("Tv") { row.tv = tv == 0xF0 ? "" : apexShutter(tv) }  // 0xF0 = Bulb
        row.av = byte("Av").map(apexAperture) ?? ""

        // ES-E1 blanks exposure compensation in Manual and Bulb.
        if let ec = byte("expcomp"), !noExposureCompensationModes.contains(mode) {
            row.exposureCompensation = compensation(ec)
        }
        row.flashExposureCompensation = byte("flashcomp").map(compensation) ?? ""
        row.flashMode = byte("flashmode").map(flashLabel) ?? ""
        row.meteringMode = byte("metering").map { label(meteringModes, $0 & 0xF0) } ?? ""
        row.filmAdvance = byte("drive").map { label(driveModes, $0 & 0x7F) } ?? ""  // 0x80 = ME
        // AF enum is the low 6 bits; 0x40/0x80 are flags ES-E1 ignores.
        row.afMode = byte("afmode").map { label(afModes, $0 & 0x3F) } ?? ""

        row.afPointAchievingFocus = byte("focus").map { String(format: "%02x", $0) } ?? ""
        row.afPointSelection = bytes("selection")?.map { String(format: "%02x", $0) }.joined() ?? ""

        return row
    }

    // MARK: Value encodings

    /// Aperture: `f = 2^(b/8)`, snapped to Canon's standard 1/3-stop ladder so labels
    /// match the camera's own (e.g. 0x19 → "9.0", not "8.7").
    private static let standardApertures: [Double] = [
        1.0, 1.1, 1.2, 1.4, 1.6, 1.8, 2.0, 2.2, 2.5, 2.8, 3.2, 3.5, 4.0, 4.5, 5.0,
        5.6, 6.3, 7.1, 8.0, 9.0, 10, 11, 13, 14, 16, 18, 20, 22, 25, 29, 32, 36,
        40, 45, 51, 57, 64,
    ]

    static func apexAperture(_ b: UInt8) -> String {
        guard b != 0, b != 0xFF else { return "" }
        let f = pow(2.0, Double(b) / 8.0)
        let nearest = standardApertures.min {
            abs(log2($0) - log2(f)) < abs(log2($1) - log2(f))
        } ?? f
        return nearest < 10 ? String(format: "%.1f", nearest) : String(Int(nearest.rounded()))
    }

    private static let fastShutters: [Int] = [
        4, 5, 6, 8, 10, 13, 15, 20, 25, 30, 40, 50, 60, 80, 100, 125, 160, 200, 250,
        320, 400, 500, 640, 800, 1000, 1250, 1600, 2000, 2500, 3200, 4000, 5000, 6400, 8000,
    ]
    /// Speeds at or slower than ~0.3s are shown by ES-E1 as decimal seconds, not 1/N.
    private static let slowShutters: [Double] = [
        0.3, 0.4, 0.5, 0.6, 0.8, 1, 1.3, 1.6, 2, 2.5, 3, 4, 5, 6, 8, 10, 13, 15, 20, 25, 30,
    ]

    private static let shutterLadder: [(apex: Double, label: String)] = {
        var ladder = fastShutters.map { (log2(Double($0)), "1/\($0)") }
        ladder += slowShutters.map { seconds in
            let text = seconds == seconds.rounded()
                ? String(Int(seconds))
                : String(format: "%g", seconds)
            return (-log2(seconds), text)
        }
        return ladder
    }()

    /// Shutter: `Tv_apex = (b − 20) / 4`, `T = 2^(−Tv_apex)` (so 0x14 = 1 s).
    static func apexShutter(_ b: UInt8) -> String {
        guard b != 0, b != 0xFF else { return "" }
        let tv = (Double(b) - 20) / 4.0
        return shutterLadder.min { abs($0.apex - tv) < abs($1.apex - tv) }?.label ?? ""
    }

    /// ISO from Sv: 8 counts per stop, ISO 50 anchored at 0x40.
    static func isoFromSv(_ b: UInt8) -> String {
        guard b != 0, b != 0xF0, b != 0xFF else { return "" }
        let iso = 50 * pow(2.0, (Double(b) - 64) / 8.0)
        let standard = [25, 32, 40, 50, 64, 80, 100, 125, 160, 200, 250, 320, 400,
                        500, 640, 800, 1000, 1250, 1600, 2000, 2500, 3200]
        let nearest = standard.min {
            abs(log2(Double($0)) - log2(iso)) < abs(log2(Double($1)) - log2(iso))
        } ?? Int(iso)
        return String(nearest)
    }

    /// Exposure / flash compensation: signed eighths of a stop, shown in Canon thirds
    /// (0x08 → +1.0, 0xF8 → −1.0, 0x05 → +0.7).
    static func compensation(_ b: UInt8) -> String {
        let signed = b < 128 ? Int(b) : Int(b) - 256
        let thirds = (Double(signed) / 8.0 * 3).rounded() / 3
        return abs(thirds) < 1e-6 ? "0.0" : String(format: "%+.1f", thirds)
    }

    /// Bit 0x08 means the flash fired; the 0xC0 bits distinguish E-TTL from plain TTL.
    static func flashLabel(_ b: UInt8) -> String {
        guard b & 0x08 != 0 else { return "OFF" }
        return (b & 0xC0) != 0 ? "E-TTL" : "TTL autoflash"
    }

    static let exposureModes: [UInt8: String] = [
        0x10: "Program AE", 0x20: "Shutter-speed-priority AE",
        0x40: "Aperture-priority AE", 0x80: "Manual exposure",
        0x08: "Depth-of-field AE", 0x04: "Bulb",
    ]
    static let meteringModes: [UInt8: String] = [
        0x10: "Center Averaging", 0x20: "Evaluative", 0x40: "Partial", 0x80: "Spot",
    ]
    static let driveModes: [UInt8: String] = [
        0x08: "Single-frame", 0x04: "Ultra-high-speed continuous",
        0x40: "Continuous (body only)", 0x10: "2-sec. self-timer",
        0x20: "10-sec. self-timer",
    ]
    static let afModes: [UInt8: String] = [
        0x02: "One-Shot AF", 0x04: "AI Servo AF", 0x12: "Manual focus",
    ]

    private static let noExposureCompensationModes: Set<String> = ["Manual exposure", "Bulb"]

    /// Unrecognised enum values are surfaced, never guessed at.
    private static func label(_ table: [UInt8: String], _ b: UInt8) -> String {
        table[b] ?? String(format: "?(0x%02x)", b)
    }

    // MARK: BCD

    private static func validBCD(_ bytes: [UInt8]) -> Bool {
        bytes.allSatisfy { ($0 >> 4) <= 9 && ($0 & 0x0F) <= 9 }
    }

    /// 3 BCD bytes `YY MM DD` → "20YY-MM-DD", or nil if absent/implausible.
    static func bcdDate(_ bytes: [UInt8]) -> String? {
        guard bytes.count >= 3, !bytes.allSatisfy({ $0 == 0xFF }), validBCD(Array(bytes.prefix(3)))
        else { return nil }
        let month = Int(String(format: "%02x", bytes[1])) ?? 0
        let day = Int(String(format: "%02x", bytes[2])) ?? 0
        guard (1 ... 12).contains(month), (1 ... 31).contains(day) else { return nil }
        return String(format: "20%02x-%02x-%02x", bytes[0], bytes[1], bytes[2])
    }

    /// 3 BCD bytes `HH MM SS` → "HH:MM:SS", or nil if absent/implausible.
    static func bcdTime(_ bytes: [UInt8]) -> String? {
        guard bytes.count >= 3, !bytes.allSatisfy({ $0 == 0xFF }), validBCD(Array(bytes.prefix(3)))
        else { return nil }
        let values = (0 ..< 3).map { Int(String(format: "%02x", bytes[$0])) ?? 99 }
        guard values[0] <= 23, values[1] <= 59, values[2] <= 59 else { return nil }
        return String(format: "%02x:%02x:%02x", bytes[0], bytes[1], bytes[2])
    }

    // MARK: Film-level decoding

    /// Decodes every frame in a film, resolving multiple-exposure flags.
    ///
    /// A multiple exposure is stored as several records sharing one frame number, with
    /// continuation records also setting `0x80` on the drive byte.
    static func decode(film: EOS1VFilm) -> [EOS1VFrameRow] {
        let mask = film.itemsMask
        let driveOffset = layout(for: mask).offsets["drive"]
        let numbers = film.frames.enumerated().map { index, frame in
            frame.count > 2 ? Int(frame[2]) : index + 1
        }
        var counts: [Int: Int] = [:]
        for number in numbers { counts[number, default: 0] += 1 }

        return film.frames.enumerated().map { index, frame in
            let number = numbers[index]
            var row = decode(frame: frame, frameNumber: number,
                             dxSpeed: film.dxSpeedByte, mask: mask)
            let continuation = driveOffset.map { frame.count > $0 && frame[$0] & 0x80 != 0 } ?? false
            row.multipleExposure = (counts[number] ?? 0) > 1 || continuation
            return row
        }
    }
}
