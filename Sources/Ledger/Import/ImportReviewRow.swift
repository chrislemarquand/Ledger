import Foundation

struct ReviewableField {
    var tagID: String
    var value: String
    var isIncluded: Bool
    var isEdited: Bool = false
}

struct ImportReviewRow: Identifiable {
    let id: UUID = UUID()
    let fileURL: URL
    var fields: [ReviewableField]
    var isIncluded: Bool = true
    var lensIsCarriedForward: Bool = false

    var displayName: String { fileURL.lastPathComponent }

    func field(forTagID tagID: String) -> ReviewableField? {
        fields.first { $0.tagID == tagID }
    }

    mutating func setValue(_ value: String, forTagID tagID: String, markEdited: Bool = true) {
        if let idx = fields.firstIndex(where: { $0.tagID == tagID }) {
            fields[idx].value = value
            if markEdited { fields[idx].isEdited = true }
            if !value.trimmingCharacters(in: .whitespaces).isEmpty {
                fields[idx].isIncluded = true
            }
        } else {
            fields.append(ReviewableField(
                tagID: tagID,
                value: value,
                isIncluded: !value.trimmingCharacters(in: .whitespaces).isEmpty,
                isEdited: markEdited
            ))
        }
    }

    mutating func setIncluded(_ included: Bool, forTagID tagID: String) {
        if let idx = fields.firstIndex(where: { $0.tagID == tagID }) {
            fields[idx].isIncluded = included
        }
    }
}

struct ImportReviewState: Identifiable {
    let id: UUID = UUID()
    var rows: [ImportReviewRow]
    /// Tag IDs to display as columns, in order.
    var columnTagIDs: [String]
    /// Human-readable label for each column tag ID.
    var columnLabels: [String: String]

    var hasAnyData: Bool { !rows.isEmpty }
}
