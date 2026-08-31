import AppKit
import Combine
import Foundation

enum EOS1VToolAccessLevel: Sendable {
    case read
    case write
    case destructive
}

struct EOS1VToolAccessPolicy: Sendable {
    let allowed: Set<Allowed>

    enum Allowed: Sendable {
        case read
        case write
        case destructive
    }

    static let readOnly = EOS1VToolAccessPolicy(allowed: [.read])
    // The one deliberate exception: EOS1VToolClient.Operation.setClock is
    // the only case anywhere in that enum classified `.write` — adding
    // `.write` here only unlocks that single operation, not a general
    // loosening. See docs on EOS1VSessionController's client init.
    static let readAndClockWrite = EOS1VToolAccessPolicy(allowed: [.read, .write])

    func permits(_ level: EOS1VToolAccessLevel) -> Bool {
        switch level {
        case .read: allowed.contains(.read)
        case .write: allowed.contains(.write)
        case .destructive: allowed.contains(.destructive)
        }
    }
}

struct EOS1VSetting: Decodable, Identifiable, Sendable {
    struct Choice: Decodable, Sendable {
        let value: String
        let label: String
    }

    let id: String
    let number: Int
    let name: String
    let value: String
    let choices: [Choice]?
    let choiceHints: [String]?
}

struct EOS1VRecordedItem: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let enabled: Bool
    let mandatory: Bool
    let size: Int
}

struct EOS1VMachineResult: Decodable, Sendable {
    struct Camera: Decodable, Sendable {
        let model: String
        let responding: Bool
        let clockDate: String?
        let clockTime: String?
        let storedRollCount: Int?
    }

    struct RecordedItems: Decodable, Sendable {
        let mask: String?
        let recordLength: Int?
        let hasUnknownItems: Bool
        let items: [EOS1VRecordedItem]
    }

    struct ClockSnapshot: Decodable, Sendable {
        let date: String?
        let time: String?
    }

    let camera: Camera?
    let recordedItems: RecordedItems?
    let status: [String: String]?
    let custom: [EOS1VSetting]?
    let personal: [EOS1VSetting]?
    let warnings: [String]?
    // set-clock's result shape: {"before", "written", "after", "verified"}
    // (see _machine_set_clock in eos1v_tool.py) — field names match its JSON
    // keys directly, same convention every other field here already follows.
    let before: ClockSnapshot?
    let written: ClockSnapshot?
    let after: ClockSnapshot?
    let verified: Bool?
    let filmCount: Int?
    let frameCount: Int?
    let csvPath: String?
    let rawPath: String?
}

private struct EOS1VMachineEvent: Decodable {
    struct Failure: Decodable {
        let type: String
        let message: String
    }

    let schemaVersion: Int
    let event: String
    let operation: String
    let result: EOS1VMachineResult?
    let error: Failure?
}

@MainActor
final class EOS1VToolClient {
    enum Operation: Sendable {
        case inspect
        case settings
        case download(csv: URL, raw: URL)
        // The only `.write`-classified case in this enum. Writes the
        // camera's clock via eos1v-serial's `set-clock`, which wraps its
        // existing, unmodified EOS1V.set_clock() (see docs/eos1v-set-clock-review-2026-08.md
        // for the independent review confirming no new camera-facing
        // protocol behavior).
        case setClock(Date)

        var accessLevel: EOS1VToolAccessLevel {
            switch self {
            case .inspect, .settings, .download: .read
            case .setClock: .write
            }
        }

        var arguments: [String] {
            switch self {
            case .inspect: ["machine", "inspect"]
            case .settings: ["machine", "settings"]
            case let .download(csv, raw): ["machine", "download", csv.path, raw.path]
            case let .setClock(date): ["machine", "set-clock", Self.isoFormatter.string(from: date)]
            }
        }

        // Naive local wall-clock string (no "Z"/offset) — matches how
        // eos1v-serial's clock_bcd() packs dt.year/month/day/hour/minute/second
        // verbatim with no timezone conversion, and how Python's
        // datetime.fromisoformat() parses without a "Z" suffix.
        private static let isoFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            return formatter
        }()
    }

    enum ClientError: LocalizedError {
        case accessDenied
        case configuration(String)
        case launch(String)
        case command(String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .accessDenied: "Ledger is configured for read-only EOS-1V access."
            case let .configuration(message), let .launch(message), let .command(message): message
            case .invalidResponse: "The EOS-1V tool returned an unreadable response."
            }
        }
    }

    private let policy: EOS1VToolAccessPolicy
    private var process: Process?

    init(policy: EOS1VToolAccessPolicy = .readOnly) {
        self.policy = policy
    }

    var isRunning: Bool { process?.isRunning == true }

    func cancel() {
        guard let process, process.isRunning else { return }
        process.terminate()
    }

    func run(
        _ operation: Operation,
        completion: @escaping @MainActor @Sendable (Result<EOS1VMachineResult, Error>) -> Void
    ) {
        guard process == nil else {
            completion(.failure(ClientError.command("Another EOS-1V operation is already running.")))
            return
        }
        guard policy.permits(operation.accessLevel) else {
            completion(.failure(ClientError.accessDenied))
            return
        }

        let configuration = resolvedConfiguration()
        guard FileManager.default.isExecutableFile(atPath: configuration.python.path) else {
            completion(.failure(ClientError.configuration("Python was not found at \(configuration.python.path).")))
            return
        }
        guard FileManager.default.fileExists(atPath: configuration.script.path) else {
            completion(.failure(ClientError.configuration("eos1v_tool.py was not found at \(configuration.script.path).")))
            return
        }

        let task = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        task.executableURL = configuration.python
        task.arguments = [configuration.script.path] + operation.arguments
        task.currentDirectoryURL = configuration.script.deletingLastPathComponent()
        task.standardOutput = stdout
        task.standardError = stderr
        process = task

        task.terminationHandler = { [weak self] finished in
            let output = stdout.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
            Task { @MainActor in
                guard let self else { return }
                self.process = nil
                if finished.terminationReason == .uncaughtSignal {
                    completion(.failure(ClientError.command("The EOS-1V operation was cancelled.")))
                    return
                }
                completion(Self.decode(output: output, stderr: errorOutput))
            }
        }

        do {
            try task.run()
        } catch {
            process = nil
            completion(.failure(ClientError.launch(error.localizedDescription)))
        }
    }

    private func resolvedConfiguration() -> (python: URL, script: URL) {
        let defaults = UserDefaults.standard
        let prefix = AppBrand.identifierPrefix
        let fm = FileManager.default
        // eos1v-serial lives as a git submodule inside Ledger's own project
        // folder (External/eos1v-serial) rather than as a sibling directory.
        let projectRoot = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Xcode Projects/Ledger/External/eos1v-serial", isDirectory: true)

        // A persisted directory can outlive the location it was set for — e.g. this key
        // predates eos1v-serial's move into External/, so on-disk installs still carry the
        // old path. Trusting it blindly makes every EOS-1V operation fail preflight (wrong
        // path, script "not found") before ever touching the camera, which looks identical
        // to a real connection failure. Validate it still holds the script before trusting
        // it; otherwise fall back to the current guessed location instead of staying stuck.
        let persistedToolDirectory = defaults.string(forKey: "\(prefix).eos1v.toolDirectory")
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        let toolDirectory: URL
        if let persistedToolDirectory,
           fm.fileExists(atPath: persistedToolDirectory.appendingPathComponent("eos1v_tool.py").path) {
            toolDirectory = persistedToolDirectory
        } else {
            toolDirectory = projectRoot
        }

        let persistedPython = defaults.string(forKey: "\(prefix).eos1v.pythonPath").map { URL(fileURLWithPath: $0) }
        let python: URL
        if let persistedPython, fm.isExecutableFile(atPath: persistedPython.path) {
            python = persistedPython
        } else {
            python = toolDirectory.appendingPathComponent(".venv/bin/python")
        }

        return (python, toolDirectory.appendingPathComponent("eos1v_tool.py"))
    }

    private static func decode(output: Data, stderr: Data) -> Result<EOS1VMachineResult, Error> {
        let decoder = JSONDecoder()
        let events = output.split(separator: UInt8(ascii: "\n")).compactMap { line in
            try? decoder.decode(EOS1VMachineEvent.self, from: Data(line))
        }
        guard events.allSatisfy({ $0.schemaVersion == 1 }) else {
            return .failure(ClientError.invalidResponse)
        }
        if let failure = events.last(where: { $0.event == "failed" })?.error {
            return .failure(ClientError.command(failure.message))
        }
        if let result = events.last(where: { $0.event == "completed" })?.result {
            return .success(result)
        }
        let diagnostic = String(data: stderr, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .failure(ClientError.command(diagnostic?.isEmpty == false ? diagnostic! : "The EOS-1V operation did not complete."))
    }
}

struct EOS1VShootingRow: Identifiable, Sendable {
    let id: Int
    let film: String
    let frame: String
    let details: String
}

/// One frame record, retaining every field from eos1v-serial's own CSV
/// (`films_to_csv`) verbatim — enough to rebuild Canon's exact export format
/// without re-invoking eos1v-serial or touching its code.
struct EOS1VFrameRecord: Identifiable, Sendable {
    let id: Int
    let frameNumber: String
    let focalLength: String
    let maxAperture: String
    let tv: String
    let av: String
    let isoDX: String
    let isoM: String
    let exposureCompensation: String
    let flashExposureCompensation: String
    let shootingMode: String
    let meteringMode: String
    let flashMode: String
    let filmAdvance: String
    let afMode: String
    let afPointAchievingFocus: String
    let afPointSelection: String
    let multipleExposure: String
    let date: String
    let time: String
    let batteryDate: String
    let batteryTime: String
}

/// One roll (film), grouping its frames — mirrors eos1v-serial's `Film`
/// column (e.g. "00-13"), re-padded to Canon's own "00-024" convention when
/// exporting (see EOS1VRollCSVExporter).
struct EOS1VFilmRoll: Identifiable, Sendable {
    let id: String
    let loadedDate: String
    let loadedTime: String
    let frames: [EOS1VFrameRecord]
}

@MainActor
final class EOS1VSessionController: ObservableObject {
    enum State: Equatable {
        case cableConnected
        case searching
        case notFound(String)
        case connected
        case downloading
        case loaded(films: Int, frames: Int)
        case failed(String)
    }

    @Published private(set) var state: State = .cableConnected
    @Published private(set) var customSettings: [EOS1VSetting] = []
    @Published private(set) var personalSettings: [EOS1VSetting] = []
    @Published private(set) var recordedItems: EOS1VMachineResult.RecordedItems?
    @Published private(set) var camera: EOS1VMachineResult.Camera?
    // The system clock at the exact moment `camera.clockDate/clockTime` was
    // read — paired with it so the Date and Time tab can show a frozen
    // snapshot of the two clocks, rather than comparing a fixed camera
    // reading against whatever the system clock says whenever the tab is
    // later reopened.
    @Published private(set) var cameraClockSnapshotDate: Date?
    @Published private(set) var rawStatus: [String: String] = [:]
    @Published private(set) var shootingRows: [EOS1VShootingRow] = []
    @Published private(set) var filmRolls: [EOS1VFilmRoll] = []
    @Published private(set) var lastCSVURL: URL?
    @Published private(set) var lastRawURL: URL?
    @Published private(set) var deletedRollIDs: Set<String>

    private let client: EOS1VToolClient
    private let deletedRollsStore: EOS1VDeletedRollsStore

    init(client: EOS1VToolClient = EOS1VToolClient(policy: .readAndClockWrite)) {
        self.client = client
        // Stable location regardless of the user-configurable capture output
        // directory (see captureDirectory()) — this is Ledger-internal
        // bookkeeping, not a capture the user chose an export location for.
        let store = EOS1VDeletedRollsStore(
            directory: AppBrand.currentSupportDirectoryURL().appendingPathComponent("EOS-1V Captures", isDirectory: true)
        )
        deletedRollsStore = store
        deletedRollIDs = store.load()
    }

    /// Hides a roll from the default Shooting Data list. Never touches the
    /// camera or the downloaded CSV/raw files — eos1v-serial re-downloads
    /// whatever's currently on the camera every time, so this tombstone is
    /// what keeps a locally-deleted roll from reappearing.
    func markRollDeleted(_ id: String) {
        guard deletedRollIDs.insert(id).inserted else { return }
        deletedRollsStore.save(deletedRollIDs)
    }

    func restoreRoll(_ id: String) {
        guard deletedRollIDs.remove(id) != nil else { return }
        deletedRollsStore.save(deletedRollIDs)
    }

    var tabsEnabled: Bool {
        if case .loaded = state { return true }
        return false
    }

    func cableDidDisconnect() {
        client.cancel()
        state = .cableConnected
    }

    func search() {
        guard !client.isRunning else { return }
        state = .searching
        client.run(.inspect) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(payload):
                camera = payload.camera
                cameraClockSnapshotDate = payload.camera?.clockDate != nil ? Date() : nil
                recordedItems = payload.recordedItems
                rawStatus = payload.status ?? [:]
                customSettings = payload.custom ?? []
                personalSettings = payload.personal ?? []
                state = payload.camera?.responding == true
                    ? .connected
                    : .notFound("The camera did not respond.")
            case let .failure(error):
                state = .notFound(error.localizedDescription)
            }
        }
    }

    /// Writes the camera clock, then refreshes just the clock/settings fields
    /// via a cheap re-inspect — never a full roll download. Deliberately does
    /// NOT call `search()` (which would flip `state` through `.searching` ->
    /// `.connected`, dropping `tabsEnabled` and kicking the Date and Time tab
    /// back to Connect mid-flow, since tabs are only enabled while
    /// `state == .loaded`): `refreshCameraClock` updates the same published
    /// fields `search()` does, minus the state transition.
    func writeClock(_ date: Date, completion: @escaping (Result<Void, Error>) -> Void) {
        guard !client.isRunning else {
            completion(.failure(EOS1VToolClient.ClientError.command("Another EOS-1V operation is already running.")))
            return
        }
        client.run(.setClock(date)) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                refreshCameraClock(completion: completion)
            case let .failure(error):
                completion(.failure(error))
            }
        }
    }

    private func refreshCameraClock(completion: @escaping (Result<Void, Error>) -> Void) {
        client.run(.inspect) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(payload):
                camera = payload.camera
                cameraClockSnapshotDate = payload.camera?.clockDate != nil ? Date() : nil
                recordedItems = payload.recordedItems
                rawStatus = payload.status ?? [:]
                customSettings = payload.custom ?? []
                personalSettings = payload.personal ?? []
                completion(.success(()))
            case let .failure(error):
                completion(.failure(error))
            }
        }
    }

    func download() {
        guard case .connected = state, !client.isRunning else { return }
        do {
            let directory = try captureDirectory()
            let stamp = Self.stampFormatter.string(from: Date())
            let csv = directory.appendingPathComponent("\(stamp)-shooting-data.csv")
            let raw = directory.appendingPathComponent("\(stamp)-raw.txt")
            state = .downloading
            client.run(.download(csv: csv, raw: raw)) { [weak self] result in
                guard let self else { return }
                switch result {
                case let .failure(error):
                    state = .failed(error.localizedDescription)
                case let .success(payload):
                    lastCSVURL = csv
                    lastRawURL = raw
                    shootingRows = Self.loadShootingRows(from: csv)
                    filmRolls = Self.loadFilmRolls(from: csv)
                    state = .loaded(
                        films: payload.filmCount ?? 0,
                        frames: payload.frameCount ?? shootingRows.count
                    )
                }
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func captureDirectory() throws -> URL {
        if let configured = UserDefaults.standard.string(
            forKey: "\(AppBrand.identifierPrefix).eos1v.outputDirectory"
        ) {
            let url = URL(fileURLWithPath: configured, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let url = AppBrand.currentSupportDirectoryURL().appendingPathComponent("EOS-1V Captures", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func loadShootingRows(from url: URL) -> [EOS1VShootingRow] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let headerLine = lines.first else { return [] }
        let header = csvFields(headerLine)
        return lines.dropFirst().enumerated().compactMap { index, line in
            let fields = csvFields(line)
            guard fields.count >= header.count else { return nil }
            let values = Dictionary(uniqueKeysWithValues: zip(header, fields))
            let film = values["Film"] ?? ""
            let frame = values["Frame"] ?? ""
            let dateTime = [values["Date"], values["Time"]].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            let exposure = [values["Tv"], values["Av"].map { "f/\($0)" }, values["Focal length"],
                            (values["ISO (M)"]?.isEmpty == false ? values["ISO (M)"] : values["ISO (DX)"]).map { "ISO \($0)" }]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            return EOS1VShootingRow(id: index, film: film, frame: frame,
                                    details: [dateTime, exposure].filter { !$0.isEmpty }.joined(separator: " — "))
        }
    }

    /// Parses eos1v-serial's own CSV (`Film,Film loaded date,Film loaded
    /// time,Frame,Focal length,Max aperture,Tv,Av,ISO (DX),ISO (M),Exposure
    /// compensation,Flash exposure compensation,Shooting mode,Metering mode,
    /// Flash mode,Film advance,AF mode,AF point achieving focus,AF point
    /// selection,Multiple exposure,Date,Time,Battery date,Battery time`)
    /// into rolls, retaining every field for EOS1VRollCSVExporter to
    /// reformat into Canon's own export layout. Never re-invokes or reshapes
    /// eos1v-serial's own output.
    private static func loadFilmRolls(from url: URL) -> [EOS1VFilmRoll] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let headerLine = lines.first else { return [] }
        let header = csvFields(headerLine)
        func field(_ values: [String: String], _ name: String) -> String {
            values[name] ?? ""
        }

        var framesByFilm: [String: (loadedDate: String, loadedTime: String, frames: [EOS1VFrameRecord])] = [:]
        var order: [String] = []
        for (index, line) in lines.dropFirst().enumerated() {
            let fields = csvFields(line)
            guard fields.count >= header.count else { continue }
            let values = Dictionary(uniqueKeysWithValues: zip(header, fields))
            let film = field(values, "Film")
            guard !film.isEmpty else { continue }
            let record = EOS1VFrameRecord(
                id: index,
                frameNumber: field(values, "Frame"),
                focalLength: field(values, "Focal length"),
                maxAperture: field(values, "Max aperture"),
                tv: field(values, "Tv"),
                av: field(values, "Av"),
                isoDX: field(values, "ISO (DX)"),
                isoM: field(values, "ISO (M)"),
                exposureCompensation: field(values, "Exposure compensation"),
                flashExposureCompensation: field(values, "Flash exposure compensation"),
                shootingMode: field(values, "Shooting mode"),
                meteringMode: field(values, "Metering mode"),
                flashMode: field(values, "Flash mode"),
                filmAdvance: field(values, "Film advance"),
                afMode: field(values, "AF mode"),
                afPointAchievingFocus: field(values, "AF point achieving focus"),
                afPointSelection: field(values, "AF point selection"),
                multipleExposure: field(values, "Multiple exposure"),
                date: field(values, "Date"),
                time: field(values, "Time"),
                batteryDate: field(values, "Battery date"),
                batteryTime: field(values, "Battery time")
            )
            if framesByFilm[film] == nil {
                framesByFilm[film] = (field(values, "Film loaded date"), field(values, "Film loaded time"), [])
                order.append(film)
            }
            framesByFilm[film]?.frames.append(record)
        }
        return order.compactMap { film in
            guard let entry = framesByFilm[film] else { return nil }
            return EOS1VFilmRoll(id: film, loadedDate: entry.loadedDate, loadedTime: entry.loadedTime, frames: entry.frames)
        }
    }

    private static func csvFields(_ line: String) -> [String] {
        var fields: [String] = []
        var field = ""
        var quoted = false
        for character in line {
            if character == "\"" { quoted.toggle() }
            else if character == ",", !quoted { fields.append(field); field = "" }
            else { field.append(character) }
        }
        fields.append(field)
        return fields
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
