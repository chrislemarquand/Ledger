import Foundation

/// One framed camera reply: `[echo][len][data…][checksum]`, where
/// `checksum = sum(data) & 0xFF`.
///
/// Replies are read **by length**, never by scanning for a terminator — a `0xF4`
/// occurring inside a data field must never be mistaken for the protocol's sync byte.
struct EOS1VReply: Equatable {
    let command: UInt8
    let echo: UInt8
    let data: [UInt8]
    let checksumValid: Bool

    /// Parses `[echo][len][data…][cksum]`. Returns nil if the buffer is too short
    /// to contain the length it declares.
    init?(command: UInt8, reply: [UInt8]) {
        guard reply.count >= 3 else { return nil }
        let length = Int(reply[1])
        guard reply.count >= 2 + length + 1 else { return nil }
        self.command = command
        echo = reply[0]
        data = Array(reply[2 ..< (2 + length)])
        let stated = reply[2 + length]
        checksumValid = stated == UInt8(data.reduce(0) { ($0 + Int($1)) & 0xFF })
    }
}

/// Parses the `<command-hex> <reply-hex>` line format produced by a download session.
///
/// This is the interface between the transport and everything above it. It is
/// deliberately raw bytes rather than any tool's human-readable output, so the
/// transport can later be swapped (Python subprocess → native Swift) without any
/// change to the decoding layer.
enum EOS1VRawDump {

    static func parse(_ text: String) -> [EOS1VReply] {
        // Split on `isNewline`, not on "\n": in Swift a CRLF is a *single* Character
        // (one grapheme cluster), so splitting on "\n" silently matches nothing in a
        // CRLF file and yields one enormous line.
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  let command = UInt8(parts[0], radix: 16),
                  let reply = hexBytes(parts[1])
            else { return nil }
            return EOS1VReply(command: command, reply: reply)
        }
    }

    static func hexBytes(_ hex: String) -> [UInt8]? {
        let cleaned = hex.filter { !$0.isWhitespace }
        guard cleaned.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index ..< next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }

    /// Splits a reply stream into films. `0xE3` opens a film, `0xE4` appends a frame.
    /// A single `0x00` data byte is the end-of-film marker and is dropped.
    static func films(from replies: [EOS1VReply]) -> [EOS1VFilm] {
        var films: [EOS1VFilm] = []
        var header: [UInt8]?
        var frames: [[UInt8]] = []

        func flush() {
            guard let header else { return }
            films.append(EOS1VFilm(header: header, frames: frames))
        }

        for reply in replies {
            switch reply.command {
            case EOS1VOpcode.filmHeader:
                flush()
                header = reply.data
                frames = []
            case EOS1VOpcode.frameRecord:
                guard header != nil else { continue }
                if reply.data.count == 1, reply.data[0] == 0 { continue }  // end-of-film
                frames.append(reply.data)
            default:
                continue
            }
        }
        flush()
        return films
    }

    /// The status replies captured during a session's post-wake setup queries.
    static func statusReply(_ opcode: UInt8, in replies: [EOS1VReply]) -> [UInt8]? {
        replies.first { $0.command == opcode }?.data
    }
}
