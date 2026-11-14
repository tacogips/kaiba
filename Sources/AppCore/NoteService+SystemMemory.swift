import Foundation

public struct SystemMemoryAttachmentInput: Sendable {
  public enum Source: Sendable {
    case data(Data)
    case fileURL(URL)
  }

  public var source: Source
  public var role: NoteFileRole
  public var mediaType: String
  public var originalFilename: String?
  public var position: Int

  public init(
    source: Source,
    role: NoteFileRole = .related,
    mediaType: String,
    originalFilename: String? = nil,
    position: Int = 0
  ) {
    self.source = source
    self.role = role
    self.mediaType = mediaType
    self.originalFilename = originalFilename
    self.position = position
  }
}

public struct SystemMemoryNoteInput: Sendable {
  public var bodyMarkdown: String
  public var tags: [NoteTagInput]
  public var metaJSON: String?
  public var relatedNoteIds: [String]
  public var attachments: [SystemMemoryAttachmentInput]

  public init(
    bodyMarkdown: String,
    tags: [NoteTagInput],
    metaJSON: String? = nil,
    relatedNoteIds: [String] = [],
    attachments: [SystemMemoryAttachmentInput] = []
  ) {
    self.bodyMarkdown = bodyMarkdown
    self.tags = tags
    self.metaJSON = metaJSON
    self.relatedNoteIds = relatedNoteIds
    self.attachments = attachments
  }
}

extension NoteService {
  @discardableResult
  public func setNotebookReadOnly(notebookId: String, readOnly: Bool) throws -> Notebook {
    let notebook = try driver.withDatabase { database in
      try database.transaction { db in
        _ = try requireNotebook(notebookId, in: db)
        try db.execute(
          "UPDATE notebooks SET read_only = ?, updated_at = ? WHERE notebook_id = ?",
          bindings: [.int(readOnly ? 1 : 0), .text(NoteStoreClock.system.now()), .text(notebookId)]
        )
        return try requireNotebook(notebookId, in: db)
      }
    }
    publishChange(NoteChangeEvent(
      kind: NoteChangeEventKind.notebookReadOnly,
      notebookId: notebook.notebookId,
      tagNames: folderTagNames(of: notebook)
    ))
    return notebook
  }

  @discardableResult
  func bootstrapSystemMemoryNotebook() throws -> Notebook {
    try driver.withDatabase { database in
      try database.transaction { db in
        let notebookIds = try systemMemoryNotebookIds(in: db)
        if notebookIds.count > 1 {
          throw NoteServiceError.invalidInput(
            "multiple notebooks carry \(NoteStoreSchema.systemMemoryNotebookKindTag)"
          )
        }
        if let notebookId = notebookIds.first {
          try validateCanonicalSystemMemoryNotebook(notebookId: notebookId, in: db)
          return try requireNotebook(notebookId, in: db)
        }

        let notebookId = makeNoteId(prefix: "notebook")
        let now = NoteStoreClock.system.now()
        try db.execute(
          """
          INSERT INTO notebooks (
            notebook_id, title, status, read_only, created_at, updated_at, meta_json
          ) VALUES (?, 'Kaiba System Memory', 'none', 1, ?, ?, NULL)
          """,
          bindings: [.text(notebookId), .text(now), .text(now)]
        )
        try applyNotebookTag(
          notebookId: notebookId,
          tagId: NoteStoreSchema.systemMemoryNotebookKindTagId,
          provenance: .system,
          assignedBy: "kaiba-note",
          deletable: false,
          allowsSystemMemoryIdentityCreation: true,
          in: db
        )
        return try requireNotebook(notebookId, in: db)
      }
    }
  }

  public func systemMemoryNotebook() throws -> Notebook {
    try driver.withDatabase { database in
      let notebookIds = try systemMemoryNotebookIds(in: database)
      guard notebookIds.count == 1, let notebookId = notebookIds.first else {
        if notebookIds.isEmpty {
          throw NoteServiceError.notFound("system-memory notebook not found")
        }
        throw NoteServiceError.invalidInput(
          "multiple notebooks carry \(NoteStoreSchema.systemMemoryNotebookKindTag)"
        )
      }
      return try requireNotebook(notebookId, in: database)
    }
  }

  @discardableResult
  public func appendSystemMemoryNote(
    bodyMarkdown: String,
    tags: [NoteTagInput],
    metaJSON: String? = nil,
    relatedNoteIds: [String] = [],
    attachments: [SystemMemoryAttachmentInput] = []
  ) throws -> Note {
    let notes = try appendSystemMemoryNotes([
      SystemMemoryNoteInput(
        bodyMarkdown: bodyMarkdown,
        tags: tags,
        metaJSON: metaJSON,
        relatedNoteIds: relatedNoteIds,
        attachments: attachments
      )
    ])
    guard let note = notes.first else {
      throw NoteServiceError.invalidInput("system-memory append produced no note")
    }
    return note
  }

  public func appendSystemMemoryNotes(
    _ inputs: [SystemMemoryNoteInput],
    idempotencyKey: String? = nil
  ) throws -> [Note] {
    guard !inputs.isEmpty else {
      return []
    }
    let normalizedIdempotencyKey = try normalizedSystemMemoryIdempotencyKey(idempotencyKey)
    if let normalizedIdempotencyKey,
       let existing = try existingSystemMemoryBatch(
         idempotencyKey: normalizedIdempotencyKey,
         expectedCount: inputs.count
       ) {
      return existing
    }
    try validateSystemMemoryAttachments(inputs)
    let fileStore = LocalNoteFileStore(noteRoot: noteRootPath())
    let stagedAttachments = try stageSystemMemoryAttachments(inputs, fileStore: fileStore)
    do {
      let result = try driver.withDatabase { database in
        try database.transaction { db in
          let notebookIds = try systemMemoryNotebookIds(in: db)
          guard notebookIds.count == 1, let notebookId = notebookIds.first else {
            throw NoteServiceError.invalidInput("system-memory notebook invariant violated")
          }
          if let normalizedIdempotencyKey,
             let existing = try existingSystemMemoryBatch(
               notebookId: notebookId,
               idempotencyKey: normalizedIdempotencyKey,
               expectedCount: inputs.count,
               in: db
             ) {
            return SystemMemoryBatchAppendResult(
              notes: existing,
              dispatches: [],
              inserted: false
            )
          }
          let now = NoteStoreClock.system.now()
          let firstNoteNumber = try nextNoteNumber(notebookId: notebookId, in: db)
          var notes: [Note] = []
          var dispatches: [QueuedAutoActionDispatch] = []
          for (index, input) in inputs.enumerated() {
            let noteId = systemMemoryNoteId(
              idempotencyKey: normalizedIdempotencyKey,
              index: index
            ) ?? makeNoteId(prefix: "note")
            try insertSystemMemoryNote(
              noteId: noteId,
              notebookId: notebookId,
              noteNumber: firstNoteNumber + index,
              input: input,
              stagedAttachments: stagedAttachments.filter { $0.noteIndex == index },
              timestamp: now,
              in: db
            )
            let note = try requireNote(noteId, in: db)
            notes.append(note)
            dispatches.append(contentsOf: try enqueueAutoActions(
              for: NoteAutoActionEvent(
                trigger: .noteCreated,
                notebookId: notebookId,
                noteId: noteId,
                noteBodyMarkdown: input.bodyMarkdown
              ),
              in: db
            ))
          }
          try db.execute(
            "UPDATE notebooks SET updated_at = ? WHERE notebook_id = ?",
            bindings: [.text(now), .text(notebookId)]
          )
          return SystemMemoryBatchAppendResult(
            notes: notes,
            dispatches: dispatches,
            inserted: true
          )
        }
      }
      if !result.inserted {
        deleteStagedSystemMemoryAttachments(stagedAttachments, fileStore: fileStore)
      }
      dispatchQueuedAutoActions(result.dispatches)
      return result.notes
    } catch {
      deleteStagedSystemMemoryAttachments(stagedAttachments, fileStore: fileStore)
      throw error
    }
  }

  public func listSystemMemoryNotes(personaId: String, limit: Int) throws -> [Note] {
    let boundedLimit = max(1, min(limit, 100))
    return try driver.withDatabase { database in
      let notebookIds = try systemMemoryNotebookIds(in: database)
      guard notebookIds.count == 1, let notebookId = notebookIds.first else {
        throw NoteServiceError.invalidInput("system-memory notebook invariant violated")
      }
      let noteIds = try database.query(
        """
        SELECT n.note_id
        FROM notes n
        INNER JOIN note_tags nt ON nt.note_id = n.note_id
        INNER JOIN tags t ON t.tag_id = nt.tag_id
        WHERE n.notebook_id = ?
          AND t.name = ?
          AND json_extract(n.meta_json, '$.systemMemoryVersion') = 1
          AND json_extract(n.meta_json, '$.personaId') = ?
        ORDER BY n.created_at DESC, n.note_id DESC
        LIMIT ?
        """,
        bindings: [
          .text(notebookId),
          .text("persona:\(personaId)"),
          .text(personaId),
          .int(Int64(boundedLimit))
        ]
      ).compactMap { $0["note_id"] }
      return try noteIds.map { try requireNote($0, in: database) }
    }
  }

  public func listSystemMemoryNotes(
    streamId: String,
    workflowId: String,
    nodeId: String? = nil,
    limit: Int
  ) throws -> [Note] {
    let boundedLimit = max(1, min(limit, 100))
    return try driver.withDatabase { database in
      let notebookIds = try systemMemoryNotebookIds(in: database)
      guard notebookIds.count == 1, let notebookId = notebookIds.first else {
        throw NoteServiceError.invalidInput("system-memory notebook invariant violated")
      }
      var bindings: [SQLiteValue] = [
        .text(notebookId),
        .text(Self.systemMemoryStreamTag(streamId)),
        .text(Self.systemMemoryWorkflowTag(workflowId)),
        .text(streamId),
        .text(workflowId)
      ]
      let nodeClause: String
      if let nodeId {
        nodeClause = """
          AND EXISTS (
            SELECT 1 FROM note_tags node_nt
            INNER JOIN tags node_t ON node_t.tag_id = node_nt.tag_id
            WHERE node_nt.note_id = n.note_id AND node_t.name = ?
          )
          AND json_extract(n.meta_json, '$.nodeId') = ?
          """
        bindings.append(.text(Self.systemMemoryNodeTag(nodeId)))
        bindings.append(.text(nodeId))
      } else {
        nodeClause = ""
      }
      bindings.append(.int(Int64(boundedLimit)))
      let noteIds = try database.query(
        """
        SELECT n.note_id
        FROM notes n
        WHERE n.notebook_id = ?
          AND EXISTS (
            SELECT 1 FROM note_tags stream_nt
            INNER JOIN tags stream_t ON stream_t.tag_id = stream_nt.tag_id
            WHERE stream_nt.note_id = n.note_id AND stream_t.name = ?
          )
          AND EXISTS (
            SELECT 1 FROM note_tags workflow_nt
            INNER JOIN tags workflow_t ON workflow_t.tag_id = workflow_nt.tag_id
            WHERE workflow_nt.note_id = n.note_id AND workflow_t.name = ?
          )
          AND json_extract(n.meta_json, '$.entryKind') = 'workflow-memory'
          AND json_extract(n.meta_json, '$.streamId') = ?
          AND json_extract(n.meta_json, '$.workflowId') = ?
          \(nodeClause)
        ORDER BY n.created_at DESC, n.note_id DESC
        LIMIT ?
        """,
        bindings: bindings
      ).compactMap { $0["note_id"] }
      return try noteIds.map { try requireNote($0, in: database) }
    }
  }

  public static func systemMemoryStreamTag(_ streamId: String) -> String {
    "system-memory-stream:\(streamId)"
  }

  public static func systemMemoryWorkflowTag(_ workflowId: String) -> String {
    "system-memory-workflow:\(workflowId)"
  }

  public static func systemMemoryNodeTag(_ nodeId: String) -> String {
    "system-memory-node:\(nodeId)"
  }

}

private extension NoteService {
  static let systemMemoryMaximumAttachmentCount = 64
  static let systemMemoryMaximumAttachmentBytes = 8 * 1024 * 1024

  struct SystemMemoryBatchAppendResult {
    var notes: [Note]
    var dispatches: [QueuedAutoActionDispatch]
    var inserted: Bool
  }

  struct StagedSystemMemoryAttachment {
    var noteIndex: Int
    var fileId: String
    var stored: StoredNoteFile
    var input: SystemMemoryAttachmentInput
  }

  func existingSystemMemoryBatch(
    idempotencyKey: String,
    expectedCount: Int
  ) throws -> [Note]? {
    try driver.withDatabase { database in
      let notebookIds = try systemMemoryNotebookIds(in: database)
      guard notebookIds.count == 1, let notebookId = notebookIds.first else {
        throw NoteServiceError.invalidInput("system-memory notebook invariant violated")
      }
      return try existingSystemMemoryBatch(
        notebookId: notebookId,
        idempotencyKey: idempotencyKey,
        expectedCount: expectedCount,
        in: database
      )
    }
  }

  func existingSystemMemoryBatch(
    notebookId: String,
    idempotencyKey: String,
    expectedCount: Int,
    in database: SQLiteDatabase
  ) throws -> [Note]? {
    let prefix = systemMemoryNoteIdPrefix(idempotencyKey: idempotencyKey)
    let noteIds = try database.query(
      """
      SELECT note_id FROM notes
      WHERE notebook_id = ? AND note_id LIKE ?
      ORDER BY note_id
      """,
      bindings: [.text(notebookId), .text("\(prefix)-%")]
    ).compactMap { $0["note_id"] }
    guard !noteIds.isEmpty else {
      return nil
    }
    let expectedNoteIds = (0..<expectedCount).map { "\(prefix)-\($0 + 1)" }
    guard noteIds.count == expectedNoteIds.count,
          Set(noteIds) == Set(expectedNoteIds) else {
      throw NoteServiceError.invalidInput(
        "system-memory idempotency key has inconsistent persisted entry count"
      )
    }
    return try expectedNoteIds.map { try requireNote($0, in: database) }
  }

  /// Stamps the fields `listSystemMemoryNotes` filters on so that every system-memory
  /// write is discoverable, whether it arrives through a note-memory/persona add-on
  /// (which supplies them itself) or through a direct service call. Caller-supplied
  /// values always win; only absent keys are filled in.
  func systemMemoryMetaJSON(for input: SystemMemoryNoteInput) -> String? {
    var object: [String: Any] = [:]
    if let metaJSON = input.metaJSON {
      guard
        let data = metaJSON.data(using: .utf8),
        let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else {
        // Non-object metadata is stored verbatim rather than silently rewritten.
        return metaJSON
      }
      object = decoded
    }
    if object["systemMemoryVersion"] == nil {
      object["systemMemoryVersion"] = 1
    }
    if object["personaId"] == nil, let personaId = Self.personaId(from: input.tags) {
      object["personaId"] = personaId
    }
    guard
      let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
      let json = String(data: data, encoding: .utf8)
    else {
      return input.metaJSON
    }
    return json
  }

  static func personaId(from tags: [NoteTagInput]) -> String? {
    for tag in tags where tag.name.hasPrefix("persona:") {
      let personaId = String(tag.name.dropFirst("persona:".count))
      if !personaId.isEmpty { return personaId }
    }
    return nil
  }

  func insertSystemMemoryNote(
    noteId: String,
    notebookId: String,
    noteNumber: Int,
    input: SystemMemoryNoteInput,
    stagedAttachments: [StagedSystemMemoryAttachment],
    timestamp: String,
    in database: SQLiteDatabase
  ) throws {
    try database.execute(
      """
      INSERT INTO notes (
        note_id, notebook_id, note_number, title, title_source, body_markdown,
        read_only, created_at, updated_at, meta_json
      ) VALUES (?, ?, ?, ?, 'derived', ?, 0, ?, ?, jsonb(?))
      """,
      bindings: [
        .text(noteId),
        .text(notebookId),
        .int(Int64(noteNumber)),
        .optionalText(noteTitle(from: input.bodyMarkdown)),
        .text(input.bodyMarkdown),
        .text(timestamp),
        .text(timestamp),
        .optionalText(systemMemoryMetaJSON(for: input))
      ]
    )
    for tag in input.tags {
      try applyTag(
        noteId: noteId,
        tag: tag,
        provenance: .system,
        assignedBy: "kaiba-system-memory",
        deletable: true,
        in: database
      )
    }
    for relatedNoteId in input.relatedNoteIds {
      _ = try linkNotesInDatabase(
        from: noteId,
        to: relatedNoteId,
        linkKind: "related",
        provenance: .system,
        in: database
      )
    }
    for attachment in stagedAttachments {
      _ = try insertFileRecord(
        fileId: attachment.fileId,
        stored: attachment.stored,
        mediaType: attachment.input.mediaType,
        originalFilename: attachment.input.originalFilename,
        in: database
      )
      try database.execute(
        """
        INSERT INTO note_files (note_id, file_id, role, position)
        VALUES (?, ?, ?, ?)
        """,
        bindings: [
          .text(noteId),
          .text(attachment.fileId),
          .text(attachment.input.role.rawValue),
          .int(Int64(attachment.input.position))
        ]
      )
    }
    try refreshFTS(noteId: noteId, previous: nil, in: database)
  }

  func stageSystemMemoryAttachments(
    _ noteInputs: [SystemMemoryNoteInput],
    fileStore: LocalNoteFileStore
  ) throws -> [StagedSystemMemoryAttachment] {
    var staged: [StagedSystemMemoryAttachment] = []
    do {
      for (noteIndex, noteInput) in noteInputs.enumerated() {
        for input in noteInput.attachments {
          let fileId = makeNoteId(prefix: "file")
          let stored: StoredNoteFile
          switch input.source {
          case let .data(data):
            stored = try fileStore.store(data: data, fileId: fileId)
          case let .fileURL(url):
            stored = try fileStore.store(fileURL: url, fileId: fileId)
          }
          staged.append(StagedSystemMemoryAttachment(
            noteIndex: noteIndex,
            fileId: fileId,
            stored: stored,
            input: input
          ))
        }
      }
      return staged
    } catch {
      deleteStagedSystemMemoryAttachments(staged, fileStore: fileStore)
      throw error
    }
  }

  func validateSystemMemoryAttachments(_ noteInputs: [SystemMemoryNoteInput]) throws {
    let attachments = noteInputs.flatMap(\.attachments)
    guard attachments.count <= Self.systemMemoryMaximumAttachmentCount else {
      throw NoteServiceError.invalidInput(
        "system-memory attachments exceed maximum of \(Self.systemMemoryMaximumAttachmentCount)"
      )
    }
    for attachment in attachments {
      let byteCount: Int
      switch attachment.source {
      case let .data(data):
        byteCount = data.count
      case let .fileURL(url):
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else {
          throw NoteServiceError.invalidInput(
            "system-memory attachment is not a regular file: \(url.path)"
          )
        }
        byteCount = values.fileSize ?? 0
      }
      guard byteCount <= Self.systemMemoryMaximumAttachmentBytes else {
        throw NoteServiceError.invalidInput(
          "system-memory attachment is \(byteCount) bytes; max \(Self.systemMemoryMaximumAttachmentBytes)"
        )
      }
    }
  }

  func deleteStagedSystemMemoryAttachments(
    _ attachments: [StagedSystemMemoryAttachment],
    fileStore: LocalNoteFileStore
  ) {
    for attachment in attachments {
      try? fileStore.delete(record: storedFileRecord(
        fileId: attachment.fileId,
        stored: attachment.stored,
        mediaType: attachment.input.mediaType,
        originalFilename: attachment.input.originalFilename
      ))
    }
  }

  func normalizedSystemMemoryIdempotencyKey(_ value: String?) throws -> String? {
    guard let value else {
      return nil
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw NoteServiceError.invalidInput("system-memory idempotency key must not be empty")
    }
    return trimmed
  }

  func systemMemoryNoteIdPrefix(idempotencyKey: String) -> String {
    "note-system-memory-\(sha256Hex(Data(idempotencyKey.utf8)))"
  }

  func systemMemoryNoteId(idempotencyKey: String?, index: Int) -> String? {
    idempotencyKey.map { "\(systemMemoryNoteIdPrefix(idempotencyKey: $0))-\(index + 1)" }
  }

}

func systemMemoryNotebookIds(in database: SQLiteDatabase) throws -> [String] {
  try database.query(
    """
    SELECT notebook_id
    FROM notebook_tags
    WHERE tag_id = ?
    ORDER BY notebook_id
    """,
    bindings: [.text(NoteStoreSchema.systemMemoryNotebookKindTagId)]
  ).compactMap { $0["notebook_id"] }
}

func validateSystemMemoryNotebookTagAssignment(
  notebookId: String,
  allowsIdentityCreation: Bool,
  in database: SQLiteDatabase
) throws {
  let notebookIds = try systemMemoryNotebookIds(in: database)
  if notebookIds == [notebookId] {
    return
  }
  guard allowsIdentityCreation, notebookIds.isEmpty else {
    throw NoteServiceError.invalidInput(
      "\(NoteStoreSchema.systemMemoryNotebookKindTag) is reserved for the canonical system-memory notebook"
    )
  }
}

func validateCanonicalSystemMemoryNotebook(
  notebookId: String,
  in database: SQLiteDatabase
) throws {
  guard let assignment = try notebookTagAssignment(
    notebookId: notebookId,
    tagId: NoteStoreSchema.systemMemoryNotebookKindTagId,
    in: database
  ), assignment.tag.isSystem,
     assignment.tag.classId == "document-kind",
     assignment.provenance == .system,
     assignment.assignedBy == "kaiba-note",
     !assignment.deletable else {
    throw NoteServiceError.invalidInput(
      "\(NoteStoreSchema.systemMemoryNotebookKindTag) is not owned by the canonical system-memory bootstrap"
    )
  }
}
