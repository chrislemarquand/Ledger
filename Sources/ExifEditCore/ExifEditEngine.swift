import Foundation

public actor ExifEditEngine {
    private let exifToolService: ExifToolServiceProtocol
    private let backupManager: BackupManaging
    private let validator: MetadataValidator

    public init(
        exifToolService: ExifToolServiceProtocol,
        backupManager: BackupManaging = BackupManager(),
        validator: MetadataValidator = MetadataValidator()
    ) {
        self.exifToolService = exifToolService
        self.backupManager = backupManager
        self.validator = validator
    }

    public func readMetadata(files: [URL]) async throws -> [FileMetadataSnapshot] {
        try await exifToolService.readMetadata(files: files)
    }

    public func apply(operation: EditOperation) async throws -> OperationResult {
        guard !operation.targetFiles.isEmpty else {
            throw ExifEditError.invalidOperation("No files were selected.")
        }

        try validator.validate(patches: operation.changes)

        let startedAt = Date()
        let backupLocation = try backupManager.createBackup(operationID: operation.id, files: operation.targetFiles)
        let writeResult = await exifToolService.writeMetadata(operation: operation)

        return OperationResult(
            operationID: writeResult.operationID,
            succeeded: writeResult.succeeded,
            failed: writeResult.failed,
            backupLocation: backupLocation,
            duration: Date().timeIntervalSince(startedAt)
        )
    }

    public func restore(operationID: UUID) async throws -> OperationResult {
        try backupManager.restoreBackup(operationID: operationID)
    }
}
