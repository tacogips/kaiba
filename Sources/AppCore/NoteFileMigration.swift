import Foundation

public struct NoteFileMigrationFailure: Equatable, Sendable {
  public var fileId: FileID
  public var message: String

  public init(fileId: FileID, message: String) {
    self.fileId = fileId
    self.message = message
  }
}

public struct NoteFileMigrationResult: Equatable, Sendable {
  public var migrated: [FileRecord]
  public var failures: [NoteFileMigrationFailure]
  /// Files that migrated durably to S3 but whose stale local blob could not be
  /// deleted afterward. The migration is a success (the row now points at S3);
  /// these paths are surfaced as cleanup warnings and reclaimed by a later GC pass.
  public var cleanupFailures: [NoteFileMigrationFailure]

  public init(
    migrated: [FileRecord] = [],
    failures: [NoteFileMigrationFailure] = [],
    cleanupFailures: [NoteFileMigrationFailure] = []
  ) {
    self.migrated = migrated
    self.failures = failures
    self.cleanupFailures = cleanupFailures
  }
}

/// Outcome of migrating a single file to S3: the durable record plus, when the
/// stale local blob could not be removed after the commit, the leftover path.
public struct SingleFileMigrationOutcome: Sendable {
  public var record: FileRecord
  public var cleanupFailure: NoteFileMigrationFailure?
}

public extension NoteService {
  @discardableResult
  func migrateFileStorage(
    fileId: FileID,
    to profile: S3StorageProfile,
    httpClient: S3HTTPClient = URLSessionS3HTTPClient(),
    verifyRemoteRead: Bool = false
  ) throws -> FileRecord {
    try migrateFileStorageOutcome(
      fileId: fileId,
      to: profile,
      httpClient: httpClient,
      verifyRemoteRead: verifyRemoteRead
    ).record
  }

  func migrateAllLocalFiles(
    to profile: S3StorageProfile,
    httpClient: S3HTTPClient = URLSessionS3HTTPClient(),
    verifyRemoteRead: Bool = false
  ) throws -> NoteFileMigrationResult {
    let localFileIds = try driver.withDatabase { database in
      try database.query(
        """
        SELECT file_id
        FROM files
        WHERE storage_kind = 'local'
        ORDER BY created_at, file_id
        """
      ).compactMap { $0.identifier("file_id", as: FileID.self) }
    }
    var result = NoteFileMigrationResult()
    for fileId in localFileIds {
      do {
        let outcome = try migrateFileStorageOutcome(
          fileId: fileId,
          to: profile,
          httpClient: httpClient,
          verifyRemoteRead: verifyRemoteRead
        )
        result.migrated.append(outcome.record)
        if let cleanupFailure = outcome.cleanupFailure {
          result.cleanupFailures.append(cleanupFailure)
        }
      } catch {
        result.failures.append(
          NoteFileMigrationFailure(fileId: fileId, message: String(describing: error))
        )
      }
    }
    return result
  }

  func migrateFileStorageOutcome(
    fileId: FileID,
    to profile: S3StorageProfile,
    httpClient: S3HTTPClient,
    verifyRemoteRead: Bool
  ) throws -> SingleFileMigrationOutcome {
    let localStore = LocalNoteFileStore(noteRoot: noteRootPath())
    let s3Store = S3NoteFileStore(profile: profile, httpClient: httpClient)
    let original = try getFileRecord(fileId: fileId)
    let data = try localStore.read(record: original)
    let stored = try s3Store.store(data: data, fileId: fileId)
    let migratedAt = NoteStoreClock.system.now()
    let pendingRecord = FileRecord(
      fileId: original.fileId,
      storageKind: .s3,
      localPath: nil,
      s3Profile: stored.locator.s3Profile,
      s3Bucket: stored.locator.s3Bucket,
      s3Key: stored.locator.s3Key,
      mediaType: original.mediaType,
      byteSize: stored.byteSize,
      sha256: stored.sha256,
      originalFilename: original.originalFilename,
      createdAt: original.createdAt,
      migratedAt: migratedAt
    )

    // Pre-commit compensation: the S3 object is already uploaded, but the
    // authoritative `files` row still points at the local blob. If the remote
    // read-back or the DB update fails, best-effort delete the just-uploaded
    // object so a failed migration does not leak an orphaned S3 object, then
    // rethrow. The record remains `local`.
    let migrated: FileRecord
    do {
      if verifyRemoteRead {
        _ = try s3Store.read(record: pendingRecord)
      }
      migrated = try driver.withDatabase { database in
        try database.transaction { db in
          try db.execute(
            """
            UPDATE files
            SET storage_kind = 's3',
              local_path = NULL,
              s3_profile = ?,
              s3_bucket = ?,
              s3_key = ?,
              byte_size = ?,
              sha256 = ?,
              migrated_at = ?
            WHERE file_id = ?
            """,
            bindings: [
              .optionalText(stored.locator.s3Profile),
              .optionalText(stored.locator.s3Bucket),
              .optionalText(stored.locator.s3Key),
              .int(stored.byteSize),
              .text(stored.sha256),
              .text(migratedAt),
              .id(fileId)
            ]
          )
          return try requireFileRecord(fileId: fileId, in: db)
        }
      }
    } catch {
      try? s3Store.delete(record: pendingRecord)
      throw error
    }

    // Post-commit cleanup: the migration is already durable. A failure to delete
    // the stale local blob is a leak, not a migration failure, so report the file
    // migrated and surface the leftover path as a cleanup warning for a later GC.
    do {
      try localStore.delete(record: original)
      return SingleFileMigrationOutcome(record: migrated, cleanupFailure: nil)
    } catch {
      return SingleFileMigrationOutcome(
        record: migrated,
        cleanupFailure: NoteFileMigrationFailure(fileId: fileId, message: String(describing: error))
      )
    }
  }
}
