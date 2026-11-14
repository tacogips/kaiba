import Foundation

public extension NoteService {
  @discardableResult
  func attachFile(
    noteId: String,
    data: Data,
    role: NoteFileRole = .related,
    mediaType: String,
    originalFilename: String? = nil,
    position: Int = 0
  ) throws -> NoteFileAttachment {
    let fileStore = LocalNoteFileStore(noteRoot: noteRootPath())
    let fileId = makeNoteId(prefix: "file")
    try driver.withDatabase { database in
      _ = try requireWritableNote(noteId, in: database)
    }
    let stored = try fileStore.store(data: data, fileId: fileId)
    do {
      return try driver.withDatabase { database in
        try database.transaction { db in
          _ = try requireWritableNote(noteId, in: db)
          let record = try insertFileRecord(
            fileId: fileId,
            stored: stored,
            mediaType: mediaType,
            originalFilename: originalFilename,
            in: db
          )
          try db.execute(
            """
            INSERT INTO note_files (note_id, file_id, role, position)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(note_id, file_id, role) DO UPDATE SET
              position = excluded.position
            """,
            bindings: [
              .text(noteId),
              .text(fileId),
              .text(role.rawValue),
              .int(Int64(position))
            ]
          )
          return NoteFileAttachment(noteId: noteId, file: record, role: role, position: position)
        }
      }
    } catch {
      try? fileStore.delete(record: storedFileRecord(
        fileId: fileId,
        stored: stored,
        mediaType: mediaType,
        originalFilename: originalFilename
      ))
      throw error
    }
  }

  @discardableResult
  func attachFile(
    noteId: String,
    fileURL: URL,
    role: NoteFileRole = .related,
    mediaType: String,
    originalFilename: String? = nil,
    position: Int = 0
  ) throws -> NoteFileAttachment {
    let fileStore = LocalNoteFileStore(noteRoot: noteRootPath())
    let fileId = makeNoteId(prefix: "file")
    try driver.withDatabase { database in
      _ = try requireWritableNote(noteId, in: database)
    }
    let stored = try fileStore.store(fileURL: fileURL, fileId: fileId)
    do {
      return try driver.withDatabase { database in
        try database.transaction { db in
          _ = try requireWritableNote(noteId, in: db)
          let record = try insertFileRecord(
            fileId: fileId,
            stored: stored,
            mediaType: mediaType,
            originalFilename: originalFilename,
            in: db
          )
          try db.execute(
            """
            INSERT INTO note_files (note_id, file_id, role, position)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(note_id, file_id, role) DO UPDATE SET
              position = excluded.position
            """,
            bindings: [
              .text(noteId),
              .text(fileId),
              .text(role.rawValue),
              .int(Int64(position))
            ]
          )
          return NoteFileAttachment(noteId: noteId, file: record, role: role, position: position)
        }
      }
    } catch {
      try? fileStore.delete(record: storedFileRecord(
        fileId: fileId,
        stored: stored,
        mediaType: mediaType,
        originalFilename: originalFilename
      ))
      throw error
    }
  }

  @discardableResult
  func attachFile(
    noteId: String,
    data: Data,
    role: NoteFileRole = .related,
    mediaType: String,
    originalFilename: String? = nil,
    position: Int = 0,
    s3Profile: S3StorageProfile,
    httpClient: any S3HTTPClient = URLSessionS3HTTPClient()
  ) throws -> NoteFileAttachment {
    let fileStore = S3NoteFileStore(profile: s3Profile, httpClient: httpClient)
    let fileId = makeNoteId(prefix: "file")
    try driver.withDatabase { database in
      _ = try requireWritableNote(noteId, in: database)
    }
    let stored = try fileStore.store(data: data, fileId: fileId)
    do {
      return try driver.withDatabase { database in
        try database.transaction { db in
          _ = try requireWritableNote(noteId, in: db)
          let record = try insertFileRecord(
            fileId: fileId,
            stored: stored,
            mediaType: mediaType,
            originalFilename: originalFilename,
            in: db
          )
          try db.execute(
            """
            INSERT INTO note_files (note_id, file_id, role, position)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(note_id, file_id, role) DO UPDATE SET
              position = excluded.position
            """,
            bindings: [
              .text(noteId),
              .text(fileId),
              .text(role.rawValue),
              .int(Int64(position))
            ]
          )
          return NoteFileAttachment(noteId: noteId, file: record, role: role, position: position)
        }
      }
    } catch {
      try? fileStore.delete(record: storedFileRecord(
        fileId: fileId,
        stored: stored,
        mediaType: mediaType,
        originalFilename: originalFilename
      ))
      throw error
    }
  }

  @discardableResult
  func attachNotebookFile(
    notebookId: String,
    data: Data,
    role: NotebookFileRole = .related,
    mediaType: String,
    originalFilename: String? = nil
  ) throws -> NotebookFileAttachment {
    let fileStore = LocalNoteFileStore(noteRoot: noteRootPath())
    let fileId = makeNoteId(prefix: "file")
    try driver.withDatabase { database in
      _ = try requireWritableNotebook(notebookId, in: database)
    }
    let stored = try fileStore.store(data: data, fileId: fileId)
    do {
      return try driver.withDatabase { database in
        try database.transaction { db in
          _ = try requireWritableNotebook(notebookId, in: db)
          let record = try insertFileRecord(
            fileId: fileId,
            stored: stored,
            mediaType: mediaType,
            originalFilename: originalFilename,
            in: db
          )
          try db.execute(
            """
            INSERT INTO notebook_files (notebook_id, file_id, role)
            VALUES (?, ?, ?)
            ON CONFLICT(notebook_id, file_id, role) DO NOTHING
            """,
            bindings: [.text(notebookId), .text(fileId), .text(role.rawValue)]
          )
          return NotebookFileAttachment(notebookId: notebookId, file: record, role: role)
        }
      }
    } catch {
      try? fileStore.delete(record: storedFileRecord(
        fileId: fileId,
        stored: stored,
        mediaType: mediaType,
        originalFilename: originalFilename
      ))
      throw error
    }
  }

  @discardableResult
  func attachNotebookFile(
    notebookId: String,
    fileURL: URL,
    role: NotebookFileRole = .related,
    mediaType: String,
    originalFilename: String? = nil
  ) throws -> NotebookFileAttachment {
    let fileStore = LocalNoteFileStore(noteRoot: noteRootPath())
    let fileId = makeNoteId(prefix: "file")
    try driver.withDatabase { database in
      _ = try requireWritableNotebook(notebookId, in: database)
    }
    let stored = try fileStore.store(fileURL: fileURL, fileId: fileId)
    do {
      return try driver.withDatabase { database in
        try database.transaction { db in
          _ = try requireWritableNotebook(notebookId, in: db)
          let record = try insertFileRecord(
            fileId: fileId,
            stored: stored,
            mediaType: mediaType,
            originalFilename: originalFilename,
            in: db
          )
          try db.execute(
            """
            INSERT INTO notebook_files (notebook_id, file_id, role)
            VALUES (?, ?, ?)
            ON CONFLICT(notebook_id, file_id, role) DO NOTHING
            """,
            bindings: [.text(notebookId), .text(fileId), .text(role.rawValue)]
          )
          return NotebookFileAttachment(notebookId: notebookId, file: record, role: role)
        }
      }
    } catch {
      try? fileStore.delete(record: storedFileRecord(
        fileId: fileId,
        stored: stored,
        mediaType: mediaType,
        originalFilename: originalFilename
      ))
      throw error
    }
  }

  func listFiles(noteId: String) throws -> [NoteFileAttachment] {
    try driver.withDatabase { database in
      _ = try requireNote(noteId, in: database)
      return try database.query(
        """
        SELECT f.file_id, f.storage_kind, f.local_path, f.s3_profile, f.s3_bucket, f.s3_key,
          f.media_type, f.byte_size, f.sha256, f.original_filename, f.created_at, f.migrated_at,
          nf.note_id, nf.role, nf.position
        FROM note_files nf
        INNER JOIN files f ON f.file_id = nf.file_id
        WHERE nf.note_id = ?
        ORDER BY nf.position, f.created_at, f.file_id
        """,
        bindings: [.text(noteId)]
      ).map(noteFileAttachment(from:))
    }
  }

  func listFiles(notebookId: String) throws -> [NotebookFileAttachment] {
    try driver.withDatabase { database in
      _ = try requireNotebook(notebookId, in: database)
      return try database.query(
        """
        SELECT f.file_id, f.storage_kind, f.local_path, f.s3_profile, f.s3_bucket, f.s3_key,
          f.media_type, f.byte_size, f.sha256, f.original_filename, f.created_at, f.migrated_at,
          nf.notebook_id, nf.role
        FROM notebook_files nf
        INNER JOIN files f ON f.file_id = nf.file_id
        WHERE nf.notebook_id = ?
        ORDER BY f.created_at, f.file_id
        """,
        bindings: [.text(notebookId)]
      ).map(notebookFileAttachment(from:))
    }
  }

  func resolveFileContent(fileId: String) throws -> Data {
    let record = try getFileRecord(fileId: fileId)
    guard record.storageKind == .local else {
      throw NoteFileStoreError.unsupportedStorageKind(record.storageKind)
    }
    return try LocalNoteFileStore(noteRoot: noteRootPath()).read(record: record)
  }

  func resolveFileContent(
    fileId: String,
    s3Profiles: [S3StorageProfile],
    httpClient: S3HTTPClient = URLSessionS3HTTPClient()
  ) throws -> Data {
    let record = try getFileRecord(fileId: fileId)
    switch record.storageKind {
    case .local:
      return try LocalNoteFileStore(noteRoot: noteRootPath()).read(record: record)
    case .s3:
      guard let profileName = record.s3Profile,
            let profile = s3Profiles.first(where: { $0.name == profileName }) else {
        throw NoteFileStoreError.missingS3Locator(fileId)
      }
      return try S3NoteFileStore(profile: profile, httpClient: httpClient).read(record: record)
    }
  }

  func resolveFileContent(
    fileId: String,
    s3Profiles: [S3StorageProfile],
    httpClient: any AsyncS3HTTPClient
  ) async throws -> Data {
    let record = try getFileRecord(fileId: fileId)
    switch record.storageKind {
    case .local:
      return try LocalNoteFileStore(noteRoot: noteRootPath()).read(record: record)
    case .s3:
      guard let profileName = record.s3Profile,
            let profile = s3Profiles.first(where: { $0.name == profileName }) else {
        throw NoteFileStoreError.missingS3Locator(fileId)
      }
      return try await S3NoteFileStore(profile: profile).read(record: record, httpClient: httpClient)
    }
  }

  func getFileRecord(fileId: String) throws -> FileRecord {
    try driver.withDatabase { database in
      try requireFileRecord(fileId: fileId, in: database)
    }
  }

  func noteRootPath() -> String {
    URL(fileURLWithPath: driver.databasePath).deletingLastPathComponent().path
  }

  /// Reclaims file storage that no note/notebook references any more.
  ///
  /// Two passes run:
  /// 1. Every `files` row with no `note_files`/`notebook_files` reference is
  ///    deleted, and its local/S3 blob is best-effort removed. Rows that are
  ///    still referenced keep the existing survive-note-deletion semantics.
  /// 2. The local `files/` tree is swept for stored blobs and leftover
  ///    `.file-*.tmp-*` temp files that have no corresponding `files` row and
  ///    whose on-disk modification time is older than `graceInterval` (default
  ///    24h). The grace window avoids racing an in-flight attach whose row has
  ///    not yet committed.
  ///
  /// The pass is best-effort: an individual blob or S3 delete that fails does not
  /// abort the sweep; the row is still removed so it is not retried forever.
  @discardableResult
  func reclaimUnreferencedFiles(
    olderThan graceInterval: TimeInterval = 24 * 60 * 60,
    s3Profiles: [S3StorageProfile] = [],
    httpClient: S3HTTPClient = URLSessionS3HTTPClient(),
    now: Date = Date()
  ) throws -> NoteFileReclamationResult {
    var result = NoteFileReclamationResult()
    let localStore = LocalNoteFileStore(noteRoot: noteRootPath())

    // Pass 1: orphaned `files` rows.
    let orphanedRows = try driver.withDatabase { database in
      try database.query(
        """
        SELECT f.file_id, f.storage_kind, f.local_path, f.s3_profile, f.s3_bucket, f.s3_key,
          f.media_type, f.byte_size, f.sha256, f.original_filename, f.created_at, f.migrated_at
        FROM files f
        WHERE NOT EXISTS (SELECT 1 FROM note_files nf WHERE nf.file_id = f.file_id)
          AND NOT EXISTS (SELECT 1 FROM notebook_files nbf WHERE nbf.file_id = f.file_id)
        ORDER BY f.created_at, f.file_id
        """
      ).map(fileRecord(from:))
    }
    for record in orphanedRows {
      switch record.storageKind {
      case .local:
        try? localStore.delete(record: record)
      case .s3:
        if let profileName = record.s3Profile,
           let profile = s3Profiles.first(where: { $0.name == profileName }) {
          try? S3NoteFileStore(profile: profile, httpClient: httpClient).delete(record: record)
        }
      }
      try driver.withDatabase { database in
        try database.execute("DELETE FROM files WHERE file_id = ?", bindings: [.text(record.fileId)])
      }
      result.deletedFileIds.append(record.fileId)
    }

    // Pass 2: sweep the local blob tree for entries with no `files` row.
    let referencedLocalPaths = Set(try driver.withDatabase { database in
      try database.query(
        "SELECT local_path FROM files WHERE storage_kind = 'local' AND local_path IS NOT NULL"
      ).compactMap { $0["local_path"] }
    })
    let cutoff = now.addingTimeInterval(-graceInterval)
    let filesRoot = URL(fileURLWithPath: noteRootPath(), isDirectory: true)
      .appendingPathComponent("files", isDirectory: true)
    result.sweptPaths = sweepUnreferencedLocalBlobs(
      filesRoot: filesRoot,
      referencedRelativePaths: referencedLocalPaths,
      cutoff: cutoff
    )
    return result
  }
}

public struct NoteFileReclamationResult: Equatable, Sendable {
  /// `files` rows removed because nothing referenced them.
  public var deletedFileIds: [String]
  /// Local blob / temp-file relative paths swept from disk in pass 2.
  public var sweptPaths: [String]

  public init(deletedFileIds: [String] = [], sweptPaths: [String] = []) {
    self.deletedFileIds = deletedFileIds
    self.sweptPaths = sweptPaths
  }
}

/// Walks `filesRoot/<shard>/…`, removing stored blobs and `.file-*.tmp-*` temp
/// files that no `files` row references and whose modification time predates
/// `cutoff`. Returns the shard-relative paths that were removed.
private func sweepUnreferencedLocalBlobs(
  filesRoot: URL,
  referencedRelativePaths: Set<String>,
  cutoff: Date
) -> [String] {
  let fileManager = FileManager.default
  guard let shardDirs = try? fileManager.contentsOfDirectory(
    at: filesRoot,
    includingPropertiesForKeys: [.isDirectoryKey],
    options: [.skipsHiddenFiles]
  ) else {
    return []
  }
  var swept: [String] = []
  for shardDir in shardDirs {
    let isDirectory = (try? shardDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    guard isDirectory else {
      continue
    }
    let shardName = shardDir.lastPathComponent
    guard let entries = try? fileManager.contentsOfDirectory(
      at: shardDir,
      includingPropertiesForKeys: [.contentModificationDateKey],
      options: []
    ) else {
      continue
    }
    for entry in entries {
      let name = entry.lastPathComponent
      let relativePath = "\(shardName)/\(name)"
      let isTempFile = name.hasPrefix(".") && name.contains(".tmp-")
      if !isTempFile && referencedRelativePaths.contains(relativePath) {
        continue
      }
      // A temp file is never a durable blob, so it is only kept while young;
      // stored blobs are kept if referenced (handled above) and otherwise swept.
      let modifiedAt = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
        .contentModificationDate ?? Date.distantFuture
      guard modifiedAt < cutoff else {
        continue
      }
      if (try? fileManager.removeItem(at: entry)) != nil {
        swept.append(relativePath)
      }
    }
  }
  return swept
}

func insertFileRecord(
  fileId: String,
  stored: StoredNoteFile,
  mediaType: String,
  originalFilename: String?,
  in database: SQLiteDatabase
) throws -> FileRecord {
  let now = NoteStoreClock.system.now()
  try database.execute(
    """
    INSERT INTO files (
      file_id, storage_kind, local_path, s3_profile, s3_bucket, s3_key,
      media_type, byte_size, sha256, original_filename, created_at, migrated_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
    """,
    bindings: [
      .text(fileId),
      .text(stored.locator.storageKind.rawValue),
      .optionalText(stored.locator.localPath),
      .optionalText(stored.locator.s3Profile),
      .optionalText(stored.locator.s3Bucket),
      .optionalText(stored.locator.s3Key),
      .text(mediaType),
      .int(stored.byteSize),
      .text(stored.sha256),
      .optionalText(originalFilename),
      .text(now)
    ]
  )
  return FileRecord(
    fileId: fileId,
    storageKind: stored.locator.storageKind,
    localPath: stored.locator.localPath,
    s3Profile: stored.locator.s3Profile,
    s3Bucket: stored.locator.s3Bucket,
    s3Key: stored.locator.s3Key,
    mediaType: mediaType,
    byteSize: stored.byteSize,
    sha256: stored.sha256,
    originalFilename: originalFilename,
    createdAt: now,
    migratedAt: nil
  )
}

func storedFileRecord(
  fileId: String,
  stored: StoredNoteFile,
  mediaType: String,
  originalFilename: String?
) -> FileRecord {
  FileRecord(
    fileId: fileId,
    storageKind: stored.locator.storageKind,
    localPath: stored.locator.localPath,
    s3Profile: stored.locator.s3Profile,
    s3Bucket: stored.locator.s3Bucket,
    s3Key: stored.locator.s3Key,
    mediaType: mediaType,
    byteSize: stored.byteSize,
    sha256: stored.sha256,
    originalFilename: originalFilename,
    createdAt: NoteStoreClock.system.now(),
    migratedAt: nil
  )
}

func requireFileRecord(fileId: String, in database: SQLiteDatabase) throws -> FileRecord {
  let rows = try database.query(
    """
    SELECT file_id, storage_kind, local_path, s3_profile, s3_bucket, s3_key,
      media_type, byte_size, sha256, original_filename, created_at, migrated_at
    FROM files
    WHERE file_id = ?
    LIMIT 1
    """,
    bindings: [.text(fileId)]
  )
  guard let row = rows.first else {
    throw NoteServiceError.notFound("file not found: \(fileId)")
  }
  return try fileRecord(from: row)
}

private func noteFileAttachment(from row: SQLiteRow) throws -> NoteFileAttachment {
  guard let noteId = row["note_id"],
        let roleText = row["role"],
        let role = NoteFileRole(rawValue: roleText),
        let positionText = row["position"],
        let position = Int(positionText) else {
    throw NoteServiceError.invalidRow("note file row is missing required fields")
  }
  return NoteFileAttachment(noteId: noteId, file: try fileRecord(from: row), role: role, position: position)
}

private func notebookFileAttachment(from row: SQLiteRow) throws -> NotebookFileAttachment {
  guard let notebookId = row["notebook_id"],
        let roleText = row["role"],
        let role = NotebookFileRole(rawValue: roleText) else {
    throw NoteServiceError.invalidRow("notebook file row is missing required fields")
  }
  return NotebookFileAttachment(notebookId: notebookId, file: try fileRecord(from: row), role: role)
}

func fileRecord(from row: SQLiteRow) throws -> FileRecord {
  guard let fileId = row["file_id"],
        let storageKindText = row["storage_kind"],
        let storageKind = NoteFileStorageKind(rawValue: storageKindText),
        let mediaType = row["media_type"],
        let byteSizeText = row["byte_size"],
        let byteSize = Int64(byteSizeText),
        let sha256 = row["sha256"],
        let createdAt = row["created_at"] else {
    throw NoteServiceError.invalidRow("file row is missing required fields")
  }
  return FileRecord(
    fileId: fileId,
    storageKind: storageKind,
    localPath: row["local_path"] ?? nil,
    s3Profile: row["s3_profile"] ?? nil,
    s3Bucket: row["s3_bucket"] ?? nil,
    s3Key: row["s3_key"] ?? nil,
    mediaType: mediaType,
    byteSize: byteSize,
    sha256: sha256,
    originalFilename: row["original_filename"] ?? nil,
    createdAt: createdAt,
    migratedAt: row["migrated_at"] ?? nil
  )
}
