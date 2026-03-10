import Foundation

public struct ExifToolCommandBuilder: Sendable {
    public init() {}

    public func readArguments(for files: [URL]) -> [String] {
        var args = ["-j", "-G1", "-n"]
        args.append(contentsOf: files.map(\.path))
        return args
    }

    public func writeArguments(for operation: EditOperation, file: URL) -> [String] {
        var args = ["-overwrite_original"]

        for change in operation.changes {
            let tag = writeTag(for: change)
            args.append("-\(tag)=\(change.newValue)")
        }

        args.append(file.path)
        return args
    }

    private func writeTag(for patch: MetadataPatch) -> String {
        // GPS tags must be written in the GPS group so longitude/latitude refs
        // are interpreted consistently by exiftool and image readers.
        if patch.namespace == .exif, patch.key.uppercased().hasPrefix("GPS") {
            return "GPS:\(patch.key)"
        }
        return "\(patch.namespace.rawValue):\(patch.key)"
    }
}
