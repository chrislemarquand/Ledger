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
            let tag = "\(change.namespace.rawValue):\(change.key)"
            args.append("-\(tag)=\(change.newValue)")
        }

        args.append(file.path)
        return args
    }
}
