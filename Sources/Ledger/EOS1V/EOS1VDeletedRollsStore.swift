import Foundation

/// Persists which downloaded rolls the user has locally "deleted" — hidden
/// from Ledger's own Shooting Data list. Never touches the camera and never
/// deletes the actual downloaded CSV/raw files: eos1v-serial re-downloads
/// whatever's currently on the camera every time, so without this a
/// locally-hidden roll would reappear on the next download. This is the only
/// way to make a "deleted" roll stay hidden until explicitly restored.
struct EOS1VDeletedRollsStore {
    private let fileURL: URL

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("deleted-rolls.json")
    }

    func load() -> Set<String> {
        guard let data = try? Data(contentsOf: fileURL),
              let ids = try? JSONDecoder().decode(Set<String>.self, from: data)
        else { return [] }
        return ids
    }

    func save(_ ids: Set<String>) {
        guard let data = try? JSONEncoder().encode(ids) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL)
    }
}
