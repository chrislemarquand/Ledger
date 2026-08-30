import Foundation

/// Pure, defensive parsing of a Personal Function's `.value`/`.choiceHints`
/// text (as emitted by eos1v-serial's `_pfn_dump_value`/`_pfn_choices`, which
/// this file never modifies or re-invokes) into a display shape matching the
/// real ES-E1 UI: a parent enable checkbox plus type-specific children.
///
/// Any shape that doesn't confidently match one of the known patterns falls
/// back to `.range`, which just shows the raw text — this must never guess.
enum EOS1VPersonalFunctionKind {
    case toggleOnly
    case disableList(items: [(index: Int, label: String, isDisabled: Bool)])
    case singleChoice(options: [(index: Int, label: String)], selectedIndex: Int?)
    case range(description: String)
}

struct EOS1VPersonalFunctionDisplay {
    let setting: EOS1VSetting
    /// Parent checkbox state. `.value == "off"` always means disabled,
    /// regardless of kind (confirmed in eos1v_tool.py's _pfn_dump_value).
    let isEnabled: Bool
    let kind: EOS1VPersonalFunctionKind
}

func parsePersonalFunction(_ setting: EOS1VSetting) -> EOS1VPersonalFunctionDisplay {
    let isEnabled = setting.value != "off"
    let hints = setting.choiceHints ?? []
    guard let firstHint = hints.first else {
        return EOS1VPersonalFunctionDisplay(setting: setting, isEnabled: isEnabled, kind: .range(description: setting.value))
    }

    // Plain on/off toggle: choiceHints == ["on | off"], no children.
    if hints.count == 1, firstHint == "on | off" {
        return EOS1VPersonalFunctionDisplay(setting: setting, isEnabled: isEnabled, kind: .toggleOnly)
    }

    // Multi-select disable list: first line mentions "modes to disable",
    // followed by "N: label" lines. .value is a comma-joined list of the
    // *disabled* ones using the same "N: label" text.
    if firstHint.contains("modes to disable") {
        let entries = hints.dropFirst().compactMap { parseNumberedEntry($0) }
        guard !entries.isEmpty else {
            return EOS1VPersonalFunctionDisplay(setting: setting, isEnabled: isEnabled, kind: .range(description: hints.joined(separator: " ")))
        }
        let disabledText = setting.value
        let items = entries.map { entry -> (index: Int, label: String, isDisabled: Bool) in
            let token = "\(entry.index): \(entry.label)"
            return (entry.index, entry.label, disabledText.contains(token))
        }
        return EOS1VPersonalFunctionDisplay(setting: setting, isEnabled: isEnabled, kind: .disableList(items: items))
    }

    // Single-select enum: either one line "A | B | C | off" or a numbered
    // list. .value is "K: label" — the selected option.
    if hints.count == 1, firstHint.contains("|") {
        let options = firstHint.split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0 != "off" }
        guard !options.isEmpty else {
            return EOS1VPersonalFunctionDisplay(setting: setting, isEnabled: isEnabled, kind: .range(description: firstHint))
        }
        let indexed = options.enumerated().map { (index: $0.offset, label: $0.element) }
        let selected = selectedIndex(fromValue: setting.value)
        return EOS1VPersonalFunctionDisplay(setting: setting, isEnabled: isEnabled, kind: .singleChoice(options: indexed, selectedIndex: selected))
    }

    let entries = hints.compactMap { parseNumberedEntry($0) }
    if !entries.isEmpty, !firstHint.lowercased().contains("range"), !firstHint.contains("..") {
        let options = entries.map { (index: $0.index, label: $0.label) }
        let selected = selectedIndex(fromValue: setting.value)
        return EOS1VPersonalFunctionDisplay(setting: setting, isEnabled: isEnabled, kind: .singleChoice(options: options, selectedIndex: selected))
    }

    // Range/composite (shutter, aperture, framecount, booster_fps, timers,
    // clear_defaults, or anything unrecognised): show the raw value with the
    // hint text as its description. Safe fallback — never fabricates options.
    return EOS1VPersonalFunctionDisplay(setting: setting, isEnabled: isEnabled, kind: .range(description: hints.joined(separator: " ")))
}

/// Parses a "N: label" line (optionally prefixed with "#    " leftovers) into
/// its index and label. Returns nil for lines that aren't of this shape
/// (e.g. continuation/description lines), so callers can filter safely.
private func parseNumberedEntry(_ line: String) -> (index: Int, label: String)? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard let colon = trimmed.firstIndex(of: ":") else { return nil }
    let indexPart = trimmed[trimmed.startIndex..<colon].trimmingCharacters(in: .whitespaces)
    guard let index = Int(indexPart) else { return nil }
    let label = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    guard !label.isEmpty else { return nil }
    return (index, label)
}

/// Extracts the leading "K" from a "K: label" value string.
private func selectedIndex(fromValue value: String) -> Int? {
    guard let colon = value.firstIndex(of: ":") else { return nil }
    return Int(value[value.startIndex..<colon].trimmingCharacters(in: .whitespaces))
}
