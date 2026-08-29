import Foundation

/// EOS-1V serial protocol opcodes, classified by whether they read or write.
///
/// **Read-only policy.** Only the opcodes in `readOnly` may be issued. Write opcodes
/// are catalogued here — deliberately, as documentation — but no code path can send
/// them: `EOS1VOpcodePolicy.readOnly.permits(_:)` rejects everything outside the read
/// allowlist, and no transport in this app calls a write.
///
/// **If writes are ever implemented**, the transcribed tables below are the authority.
/// They come from the eos1v-serial protocol notes and must be used verbatim.
/// *Never derive a write opcode arithmetically* — see `customFunctionWrites`, where two
/// of the four banks also require a payload suffix that no rule would produce.
enum EOS1VOpcode {

    // MARK: - Reads (the only opcodes this app issues)

    static let wake: UInt8 = 0xFF           // host → camera; camera answers 0xF4
    static let sync: UInt8 = 0xF4           // bidirectional busy / poll token
    static let filmHeader: UInt8 = 0xE3     // → 33-byte film header
    static let frameRecord: UInt8 = 0xE4    // → 33-byte frame record
    static let clock: UInt8 = 0xF3          // → BCD YY MM DD HH MM SS (pure read)
    static let recordedItems: UInt8 = 0xE8  // → 8-byte "items to be recorded" mask
    static let rollCount: UInt8 = 0xE1      // → byte 1 is the stored-roll count
    static let status1: UInt8 = 0xF1        // → 3 bytes, not yet decoded
    static let status6: UInt8 = 0xF6        // → 14 bytes, not yet decoded
    static let statusFC: UInt8 = 0xFC       // → 2 bytes, not yet decoded

    /// Post-wake status queries, in the order the original software issues them.
    static let setupSequence: [UInt8] = [0xF6, 0xF1, 0xE8, 0xFC, 0xE1]

    /// Custom Function register reads. `D1` is the active bank; `D5`/`D7`/`D9` are the
    /// three switchable banks. Only `D1` carries C.Fn 0 (an extra 11th byte).
    static let customFunctionReads: [UInt8] = [0xD5, 0xD7, 0xD9, 0xD1]

    /// Personal Function register reads, in the order the original software issues them.
    static let personalFunctionReads: [UInt8] = [
        0xD3, 0xDD, 0xC5, 0xC6, 0xC1, 0xC3, 0xC4, 0xCB,
        0xCC, 0xCA, 0xC7, 0xC8, 0xC0, 0xCD, 0xCF, 0xCE, 0xD1,
    ]

    static let readOnly: Set<UInt8> = {
        var set: Set<UInt8> = [wake, sync, filmHeader, frameRecord, clock,
                               recordedItems, rollCount, status1, status6, statusFC]
        set.formUnion(setupSequence)
        set.formUnion(customFunctionReads)
        set.formUnion(personalFunctionReads)
        return set
    }()

    // MARK: - Writes — CATALOGUED, NEVER ISSUED

    /// Not implemented and not reachable. Present so that any future implementation
    /// transcribes rather than invents, and so reviewers can see exactly what is excluded.
    enum Writes {
        /// Erases **all** shooting data. A single byte with no arming step and no undo.
        /// This must never appear in any allowlist.
        static let eraseAll: UInt8 = 0xE2

        static let beginWrite: UInt8 = 0xF9      // ack is a BARE byte, not a framed reply
        static let writeDataFollows: UInt8 = 0xF8

        /// Custom Function writes: read opcode → (write opcode, required payload suffix).
        /// **`D7`/`D9` append a constant `0x41` that their reads never return**, so a
        /// computed "read + 1" mapping would emit a wrong write for half the banks.
        static let customFunctionWrites: [UInt8: (write: UInt8, suffix: [UInt8])] = [
            0xD1: (0xD2, []), 0xD5: (0xD6, []),
            0xD7: (0xD8, [0x41]), 0xD9: (0xDA, [0x41]),
        ]

        /// Personal Function writes. D-registers map +1, C-registers −0x10.
        /// `0xD1` is the C.Fn active bank and is **never** written as a P.Fn register.
        static let personalFunctionWrites: [UInt8: UInt8] = [
            0xD3: 0xD4, 0xDD: 0xDE,
            0xC5: 0xB5, 0xC6: 0xB6, 0xC1: 0xB1, 0xC3: 0xB3, 0xC4: 0xB4,
            0xCB: 0xBB, 0xCC: 0xBC, 0xCA: 0xBA, 0xC7: 0xB7, 0xC8: 0xB8,
            0xC0: 0xB0, 0xCD: 0xBD, 0xCF: 0xBF, 0xCE: 0xBE,
        ]
    }
}

/// Gates which opcodes a session may issue. Read-only today; adding a write capability
/// later is an additive change here rather than a restructuring of the transport.
struct EOS1VOpcodePolicy {
    private let allowed: Set<UInt8>

    static let readOnly = EOS1VOpcodePolicy(allowed: EOS1VOpcode.readOnly)

    private init(allowed: Set<UInt8>) {
        self.allowed = allowed
    }

    func permits(_ opcode: UInt8) -> Bool { allowed.contains(opcode) }
}
