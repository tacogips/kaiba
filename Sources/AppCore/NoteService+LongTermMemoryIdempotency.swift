import Foundation

extension NoteService {
  private static let legacyLongTermMemoryReservedMetadataKeys: Set<String> = [
    "longTermMemoryVersion",
    "entryKind",
    "idempotencyPrincipalId",
    "idempotencyRequestSHA256",
    "sourceNoteIds",
    "unresolvedRelatedNoteIds",
    "periodStart",
    "periodEnd"
  ]

  func existingLongTermMemoryBatch(
    notebookId: NotebookID,
    idempotencyKey: String,
    principalId: UserID,
    requestDigest: String,
    entries: [LongTermMemoryEntryInput],
    assignedBy: String,
    expectedCount: Int,
    in database: SQLiteDatabase
  ) throws -> [Note]? {
    let prefix = longTermMemoryNoteIdPrefix(
      idempotencyKey: idempotencyKey,
      principalId: principalId
    )
    let noteIds = try database.query(
      """
      SELECT note_id FROM notes
      WHERE notebook_id = ? AND note_id LIKE ?
      ORDER BY note_id
      """,
      bindings: [.id(notebookId), .text("\(prefix)-%")]
    ).compactMap { $0.identifier("note_id", as: NoteID.self) }
    if noteIds.isEmpty {
      return try adoptLegacyLongTermMemoryBatch(
        notebookId: notebookId,
        idempotencyKey: idempotencyKey,
        principalId: principalId,
        requestDigest: requestDigest,
        entries: entries,
        assignedBy: assignedBy,
        expectedCount: expectedCount,
        in: database
      )
    }
    let expectedNoteIds = (0..<expectedCount).map { NoteID("\(prefix)-\($0 + 1)") }
    guard noteIds.count == expectedNoteIds.count, Set(noteIds) == Set(expectedNoteIds) else {
      throw NoteServiceError.invalidInput(
        "long-term memory idempotency key has inconsistent persisted entry count"
      )
    }
    let notes = try expectedNoteIds.map { try requireNote($0, in: database) }
    guard notes.allSatisfy({ note in
      guard let metaJSON = note.metaJSON,
            let metadata = (try? JSONValue(parsing: metaJSON))?.asObject else {
        return false
      }
      return metadata["idempotencyPrincipalId"] == .id(principalId)
        && metadata["idempotencyRequestSHA256"] == .string(requestDigest)
    }) else {
      throw NoteServiceError.invalidInput(
        "long-term memory idempotency key conflicts with a different request"
      )
    }
    return notes
  }

  private func adoptLegacyLongTermMemoryBatch(
    notebookId: NotebookID,
    idempotencyKey: String,
    principalId: UserID,
    requestDigest: String,
    entries: [LongTermMemoryEntryInput],
    assignedBy: String,
    expectedCount: Int,
    in database: SQLiteDatabase
  ) throws -> [Note]? {
    guard principalId == NoteStoreSchema.defaultUserId else { return nil }
    let prefix = legacyLongTermMemoryNoteIdPrefix(idempotencyKey: idempotencyKey)
    let noteIds = try persistedLongTermMemoryNoteIds(
      notebookId: notebookId,
      prefix: prefix,
      in: database
    )
    guard !noteIds.isEmpty else { return nil }
    let expectedNoteIds = (0..<expectedCount).map { NoteID("\(prefix)-\($0 + 1)") }
    guard noteIds.count == expectedNoteIds.count, Set(noteIds) == Set(expectedNoteIds) else {
      throw NoteServiceError.invalidInput(
        "long-term memory idempotency key has inconsistent persisted entry count"
      )
    }
    guard assignedBy == Self.longTermMemoryAssignedBy else {
      throw longTermMemoryIdempotencyConflict()
    }
    let notes = try expectedNoteIds.map { try requireNote($0, in: database) }
    for (note, entry) in zip(notes, entries) {
      guard try legacyLongTermMemoryNote(note, matches: entry, in: database) else {
        throw longTermMemoryIdempotencyConflict()
      }
    }
    for note in notes {
      guard let metaJSON = note.metaJSON,
            var metadata = (try? JSONValue(parsing: metaJSON))?.asObject else {
        throw longTermMemoryIdempotencyConflict()
      }
      metadata["idempotencyPrincipalId"] = .id(principalId)
      metadata["idempotencyRequestSHA256"] = .string(requestDigest)
      try database.execute(
        "UPDATE notes SET meta_json = jsonb(?) WHERE note_id = ?",
        bindings: [
          .text(try JSONValue.object(metadata).encodedString()),
          .id(note.noteId)
        ]
      )
    }
    return try expectedNoteIds.map { try requireNote($0, in: database) }
  }

  private func legacyLongTermMemoryNote(
    _ note: Note,
    matches entry: LongTermMemoryEntryInput,
    in database: SQLiteDatabase
  ) throws -> Bool {
    let callerMetadata = try callerLongTermMemoryMetadata(entry.metaJSON)
    guard note.bodyMarkdown == entry.bodyMarkdown,
          Set(note.tags.map(\.tag.name)) == Set(entry.topicTags),
          note.tags.allSatisfy({
            $0.provenance == .system
              && $0.assignedBy == Self.longTermMemoryAssignedBy
              && $0.deletable
          }),
          let metaJSON = note.metaJSON,
          let metadata = (try? JSONValue(parsing: metaJSON))?.asObject,
          metadata["longTermMemoryVersion"] == .integer(1),
          metadata["entryKind"] == .string("long-term-memory"),
          metadata["sourceNoteIds"] == .ids(entry.sourceNoteIds),
          metadata["periodStart"] == entry.periodStart.map({
            .string(longTermMemoryTimestamp($0))
          }),
          metadata["periodEnd"] == entry.periodEnd.map({
            .string(longTermMemoryTimestamp($0))
          }),
          legacyCallerMetadata(metadata) == callerMetadata else {
      return false
    }
    let unresolved = metadata["unresolvedRelatedNoteIds"]?.asArray?.compactMap(\.asString) ?? []
    let linked = try database.query(
      """
      SELECT to_note_id FROM note_links
      WHERE from_note_id = ? AND link_kind = ?
      ORDER BY to_note_id
      """,
      bindings: [.id(note.noteId), .text(Self.longTermMemoryRelatedLinkKind)]
    ).compactMap { $0["to_note_id"] }
    return Set(unresolved + linked) == Set(entry.relatedNoteIds.map(\.rawValue))
  }

  private func persistedLongTermMemoryNoteIds(
    notebookId: NotebookID,
    prefix: String,
    in database: SQLiteDatabase
  ) throws -> [NoteID] {
    try database.query(
      """
      SELECT note_id FROM notes
      WHERE notebook_id = ? AND note_id LIKE ?
      ORDER BY note_id
      """,
      bindings: [.id(notebookId), .text("\(prefix)-%")]
    ).compactMap { $0.identifier("note_id", as: NoteID.self) }
  }

  private func callerLongTermMemoryMetadata(_ metaJSON: String?) throws -> JSONObject {
    guard let metaJSON else { return [:] }
    guard let object = (try? JSONValue(parsing: metaJSON))?.asObject else {
      throw NoteServiceError.invalidInput("long-term memory metaJSON must encode a JSON object")
    }
    return legacyCallerMetadata(object)
  }

  private func legacyCallerMetadata(_ metadata: JSONObject) -> JSONObject {
    var callerMetadata = metadata
    for key in Self.legacyLongTermMemoryReservedMetadataKeys {
      callerMetadata.removeValue(forKey: key)
    }
    return callerMetadata
  }

  private func longTermMemoryIdempotencyConflict() -> NoteServiceError {
    .invalidInput("long-term memory idempotency key conflicts with a different request")
  }

  func normalizedLongTermMemoryIdempotencyKey(_ value: String) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw NoteServiceError.invalidInput("long-term memory idempotency key must not be empty")
    }
    return trimmed
  }

  func longTermMemoryRequestDigest(
    entries: [LongTermMemoryEntryInput],
    assignedBy: String
  ) throws -> String {
    let values = try entries.map { entry -> JSONValue in
      let callerMetadata: JSONValue
      if let metaJSON = entry.metaJSON {
        guard let object = (try? JSONValue(parsing: metaJSON))?.asObject else {
          throw NoteServiceError.invalidInput(
            "long-term memory metaJSON must encode a JSON object"
          )
        }
        callerMetadata = .object(object)
      } else {
        callerMetadata = .null
      }
      return .object([
        "bodyMarkdown": .string(entry.bodyMarkdown),
        "topicTags": .strings(entry.topicTags),
        "sourceNoteIds": .ids(entry.sourceNoteIds),
        "relatedNoteIds": .ids(entry.relatedNoteIds),
        "periodStart": .optionalString(entry.periodStart.map(longTermMemoryTimestamp)),
        "periodEnd": .optionalString(entry.periodEnd.map(longTermMemoryTimestamp)),
        "meta": callerMetadata
      ])
    }
    let request = JSONValue.object([
      "assignedBy": .string(assignedBy),
      "entries": .array(values)
    ])
    return sha256Hex(try request.encodedData())
  }

  func longTermMemoryNoteIdPrefix(
    idempotencyKey: String,
    principalId: UserID
  ) -> String {
    let identity = "\(principalId.rawValue)\u{0}\(idempotencyKey)"
    return "note-long-term-memory-\(sha256Hex(Data(identity.utf8)))"
  }

  func legacyLongTermMemoryNoteIdPrefix(idempotencyKey: String) -> String {
    "note-long-term-memory-\(sha256Hex(Data(idempotencyKey.utf8)))"
  }

  func longTermMemoryNoteId(
    idempotencyKey: String,
    principalId: UserID,
    index: Int
  ) -> NoteID {
    NoteID(
      "\(longTermMemoryNoteIdPrefix(idempotencyKey: idempotencyKey, principalId: principalId))-\(index + 1)"
    )
  }
}
