import Foundation

public extension NoteService {
  @discardableResult
  func linkNotes(
    from fromNoteId: String,
    to toNoteId: String,
    linkKind: String = "related",
    provenance: NoteProvenance = .human
  ) throws -> NoteLink {
    return try driver.withDatabase { database in
      try database.transaction { db in
        try linkNotesInDatabase(
          from: fromNoteId,
          to: toNoteId,
          linkKind: linkKind,
          provenance: provenance,
          in: db
        )
      }
    }
  }

  func listLinks(noteId: String) throws -> [NoteLink] {
    try driver.withDatabase { database in
      _ = try requireNote(noteId, in: database)
      return try database.query(
        """
        SELECT from_note_id, to_note_id, link_kind, provenance, created_at
        FROM note_links
        WHERE from_note_id = ? OR to_note_id = ?
        ORDER BY created_at, from_note_id, to_note_id
        """,
        bindings: [.text(noteId), .text(noteId)]
      ).map(noteLink(from:))
    }
  }

  func proposeLinks(noteId: String, limit: Int = 8) throws -> [NoteLinkProposal] {
    guard limit >= 0 else {
      throw NoteServiceError.invalidInput("note link proposal limit must not be negative")
    }
    guard limit > 0 else {
      return []
    }
    return try driver.withDatabase { database in
      _ = try requireNote(noteId, in: database)
      let links = try database.query(
        """
        SELECT from_note_id, to_note_id, link_kind, provenance, created_at
        FROM note_links
        WHERE from_note_id = ? OR to_note_id = ?
        """,
        bindings: [.text(noteId), .text(noteId)]
      ).map(noteLink(from:))
      let excludedIds = Set(links.map { $0.counterpartNoteId(for: noteId) } + [noteId])
      let results = try noteGraphNeighborsInDatabase(
        noteIds: [noteId],
        maxDepth: NoteGraphPolicy.associationMaxDepth,
        limit: limit,
        resultExclusions: excludedIds,
        in: database
      )
      return results.map { result in
        NoteLinkProposal(
          targetNote: result.note,
          linkKind: "related",
          reason: "Graph \(result.edgeKind.rawValue) path: \(result.pathNoteIds.joined(separator: " -> "))."
        )
      }
    }
  }

  func listComments(noteId: String) throws -> [NoteComment] {
    try driver.withDatabase { database in
      _ = try requireNote(noteId, in: database)
      return try database.query(
        """
        SELECT comment_id, note_id, notebook_id, body_markdown, author, created_at
        FROM note_comments
        WHERE note_id = ?
        ORDER BY created_at, comment_id
        """,
        bindings: [.text(noteId)]
      ).map(noteComment(from:))
    }
  }

  /// Every memo in the notebook — note-anchored and notebook-level alike —
  /// oldest first. The `note_id IN (...)` arm covers rows that predate the v9
  /// backfill only in stores restored from partial copies; normally
  /// `notebook_id` alone matches everything.
  func listNotebookComments(notebookId: String) throws -> [NoteComment] {
    try driver.withDatabase { database in
      _ = try requireNotebook(notebookId, in: database)
      return try database.query(
        """
        SELECT comment_id, note_id, notebook_id, body_markdown, author, created_at
        FROM note_comments
        WHERE notebook_id = ?
          OR note_id IN (SELECT note_id FROM notes WHERE notebook_id = ?)
        ORDER BY created_at, comment_id
        """,
        bindings: [.text(notebookId), .text(notebookId)]
      ).map(noteComment(from:))
    }
  }

  /// A notebook-level memo: anchored to the notebook only, no note.
  @discardableResult
  func addNotebookComment(
    notebookId: String,
    bodyMarkdown: String,
    author: String = "user"
  ) throws -> NoteComment {
    let comment = try driver.withDatabase { database in
      try database.transaction { db -> NoteComment in
        _ = try requireNotebook(notebookId, in: db)
        let now = NoteStoreClock.system.now()
        let commentId = makeNoteId(prefix: "comment")
        try db.execute(
          """
          INSERT INTO note_comments (comment_id, note_id, notebook_id, body_markdown, author, created_at)
          VALUES (?, NULL, ?, ?, ?, ?)
          """,
          bindings: [.text(commentId), .text(notebookId), .text(bodyMarkdown), .text(author), .text(now)]
        )
        return NoteComment(
          commentId: commentId,
          noteId: nil,
          notebookId: notebookId,
          bodyMarkdown: bodyMarkdown,
          author: author,
          createdAt: now
        )
      }
    }
    publishChange(NoteChangeEvent(
      kind: NoteChangeEventKind.noteUpdated,
      notebookId: notebookId
    ))
    return comment
  }

  /// Substring search over memos (note-anchored and notebook-level), oldest
  /// first, optionally scoped to one notebook. Backs `kaiba search --memos`
  /// so agentic search can grep memo text too.
  func searchComments(
    query: String,
    notebookId: String? = nil,
    limit: Int = 50
  ) throws -> [NoteComment] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return []
    }
    guard (0...200).contains(limit) else {
      throw NoteServiceError.invalidInput("limit must be between 0 and 200")
    }
    return try driver.withDatabase { database in
      var sql = """
        SELECT comment_id, note_id, notebook_id, body_markdown, author, created_at
        FROM note_comments
        WHERE body_markdown LIKE ? ESCAPE '\\'
        """
      var bindings: [SQLiteValue] = [.text("%\(escapedLikePattern(trimmed))%")]
      if let notebookId {
        sql += "\n  AND (notebook_id = ? OR note_id IN (SELECT note_id FROM notes WHERE notebook_id = ?))"
        bindings.append(.text(notebookId))
        bindings.append(.text(notebookId))
      }
      sql += "\nORDER BY created_at, comment_id LIMIT ?"
      bindings.append(.int(Int64(limit)))
      return try database.query(sql, bindings: bindings).map { row in
        guard let commentId = row["comment_id"],
          let bodyMarkdown = row["body_markdown"],
          let author = row["author"],
          let createdAt = row["created_at"]
        else {
          throw NoteServiceError.invalidRow("note comment row is missing required fields")
        }
        return NoteComment(
          commentId: commentId,
          noteId: row["note_id"] ?? nil,
          notebookId: row["notebook_id"] ?? nil,
          bodyMarkdown: bodyMarkdown,
          author: author,
          createdAt: createdAt
        )
      }
    }
  }

  @discardableResult
  func appendConversationTurn(
    notebookId: String,
    turn: NoteConversationTurn,
    sourceLinks: NoteConversationSourceLinks? = nil,
    assignedBy: String? = nil,
    originatingActionId: String? = nil,
    idempotencyKey: String? = nil
  ) throws -> Note {
    let result = try driver.withDatabase { database in
      try database.transaction { db in
        _ = try requireWritableNotebook(notebookId, in: db)
        let appendResult = try appendConversationTurnInDatabase(
          notebookId: notebookId,
          turn: turn,
          sourceLinks: sourceLinks,
          assignedBy: assignedBy,
          idempotencyKey: idempotencyKey,
          in: db
        )
        let dispatches: [QueuedAutoActionDispatch]
        if appendResult.inserted {
          dispatches = try enqueueAutoActions(
            for: NoteAutoActionEvent(
              trigger: .noteCreated,
              notebookId: appendResult.note.notebookId,
              noteId: appendResult.note.noteId,
              noteBodyMarkdown: appendResult.note.bodyMarkdown,
              originatingActionId: originatingActionId
            ),
            in: db
          )
        } else {
          dispatches = []
        }
        return (note: appendResult.note, dispatches: dispatches)
      }
    }
    dispatchQueuedAutoActions(result.dispatches)
    return result.note
  }

  @discardableResult
  func saveConversation(
    title conversationTitle: String,
    transcript: [NoteConversationTurn],
    notebookMetaJSON: String? = nil,
    sourceLinks: NoteConversationSourceLinks? = nil,
    assignedBy: String? = nil,
    originatingActionId: String? = nil
  ) throws -> SavedConversation {
    let result = try driver.withDatabase { database in
      try database.transaction { db in
        let now = NoteStoreClock.system.now()
        let notebookId = makeNoteId(prefix: "notebook")
        try db.execute(
          """
          INSERT INTO notebooks (notebook_id, title, created_at, updated_at, meta_json)
          VALUES (?, ?, ?, ?, jsonb(?))
          """,
          bindings: [
            .text(notebookId),
            .text(conversationTitle),
            .text(now),
            .text(now),
            .optionalText(notebookMetaJSON)
          ]
        )
        try applyConversationNotebookKind(notebookId: notebookId, assignedBy: assignedBy, in: db)

        var notes: [Note] = []
        for turn in transcript {
          notes.append(try appendConversationTurnInDatabase(
            notebookId: notebookId,
            turn: turn,
            sourceLinks: sourceLinks,
            assignedBy: assignedBy,
            idempotencyKey: nil,
            in: db
          ).note)
        }
        let notebook = try requireNotebook(notebookId, in: db)
        let saved = SavedConversation(notebook: notebook, notes: notes)
        var dispatches = try enqueueAutoActions(
          for: NoteAutoActionEvent(
            trigger: .notebookCreated,
            notebookId: notebook.notebookId,
            originatingActionId: originatingActionId
          ),
          in: db
        )
        for note in notes {
          dispatches.append(contentsOf: try enqueueAutoActions(
            for: NoteAutoActionEvent(
              trigger: .noteCreated,
              notebookId: notebook.notebookId,
              noteId: note.noteId,
              noteBodyMarkdown: note.bodyMarkdown,
              originatingActionId: originatingActionId
            ),
            in: db
          ))
        }
        return (saved: saved, dispatches: dispatches)
      }
    }
    dispatchQueuedAutoActions(result.dispatches)
    return result.saved
  }
}

private func appendConversationTurnInDatabase(
  notebookId: String,
  turn: NoteConversationTurn,
  sourceLinks: NoteConversationSourceLinks?,
  assignedBy: String?,
  idempotencyKey: String?,
  in database: SQLiteDatabase
) throws -> (note: Note, inserted: Bool) {
  if let idempotencyKey,
     let existing = try conversationTurn(
       notebookId: notebookId,
       idempotencyKey: idempotencyKey,
       in: database
     ) {
    return (existing, false)
  }
  for sourceNoteId in turn.sourceNoteIds {
    _ = try requireNote(sourceNoteId, in: database)
  }
  var sourceNoteIds = sourceLinks?.sourceNoteIds ?? []
  var missingSourceNoteIds: [String] = []
  if let sourceLinks {
    let existingSources = try requireNotes(sourceLinks.sourceNoteIds, in: database)
    missingSourceNoteIds = sourceLinks.sourceNoteIds.filter { existingSources[$0] == nil }
    if !sourceLinks.allowMissingSourceNotes, let missingSourceNoteId = missingSourceNoteIds.first {
      throw NoteServiceError.notFound("note not found: \(missingSourceNoteId)")
    }
    sourceNoteIds = sourceLinks.sourceNoteIds.filter { existingSources[$0] != nil }
  }
  let now = NoteStoreClock.system.now()
  let noteNumber = try nextNoteNumber(notebookId: notebookId, in: database)
  let bodyMarkdown = conversationBody(turn: turn, noteNumber: noteNumber)
  let noteId = makeNoteId(prefix: "note")
  let noteMetaJSON = try conversationTurnMetadataJSON(
    idempotencyKey: idempotencyKey,
    missingSourceNoteIds: missingSourceNoteIds
  )
  try database.execute(
    """
    INSERT INTO notes (
      note_id, notebook_id, note_number, title, body_markdown,
      read_only, created_at, updated_at, meta_json
    ) VALUES (?, ?, ?, ?, ?, 0, ?, ?, jsonb(?))
    """,
    bindings: [
      .text(noteId),
      .text(notebookId),
      .int(Int64(noteNumber)),
      .optionalText(noteTitle(from: bodyMarkdown)),
      .text(bodyMarkdown),
      .text(now),
      .text(now),
      .optionalText(noteMetaJSON)
    ]
  )
  for sourceNoteId in turn.sourceNoteIds {
    _ = try linkNotesInDatabase(
      from: noteId,
      to: sourceNoteId,
      linkKind: "source-citation",
      provenance: .system,
      in: database
    )
  }
  if let sourceLinks {
    for sourceNoteId in sourceNoteIds {
      _ = try linkNotesInDatabase(
        from: noteId,
        to: sourceNoteId,
        linkKind: sourceLinks.linkKind,
        provenance: sourceLinks.provenance,
        in: database
      )
    }
  }
  try database.execute(
    "UPDATE notebooks SET updated_at = ? WHERE notebook_id = ?",
    bindings: [.text(now), .text(notebookId)]
  )
  try refreshFTS(noteId: noteId, previous: nil, in: database)
  return (try requireNote(noteId, in: database), true)
}

private func conversationTurn(
  notebookId: String,
  idempotencyKey: String,
  in database: SQLiteDatabase
) throws -> Note? {
  let rows = try database.query(
    """
    SELECT note_id
    FROM notes
    WHERE notebook_id = ?
      AND json_extract(meta_json, '$.kaibaNote.conversationTurn.idempotencyKey') = ?
    LIMIT 1
    """,
    bindings: [.text(notebookId), .text(idempotencyKey)]
  )
  guard let noteId = rows.first?["note_id"] else {
    return nil
  }
  return try requireNote(noteId, in: database)
}

private func conversationTurnMetadataJSON(
  idempotencyKey: String?,
  missingSourceNoteIds: [String]
) throws -> String? {
  guard idempotencyKey != nil || !missingSourceNoteIds.isEmpty else {
    return nil
  }
  var metadata: [String: Any] = [:]
  if let idempotencyKey {
    metadata["idempotencyKey"] = idempotencyKey
  }
  if !missingSourceNoteIds.isEmpty {
    metadata["missingSourceNoteIds"] = missingSourceNoteIds
  }
  let root = ["kaibaNote": ["conversationTurn": metadata]]
  let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
  guard let json = String(data: data, encoding: .utf8) else {
    throw NoteServiceError.invalidInput("conversation turn metadata must be UTF-8 JSON")
  }
  return json
}

@discardableResult
func linkNotesInDatabase(
  from fromNoteId: String,
  to toNoteId: String,
  linkKind: String,
  provenance: NoteProvenance,
  in database: SQLiteDatabase
) throws -> NoteLink {
  // Bind link_kind verbatim (no trimming / emptiness check) so this shared
  // helper preserves the exact behavior of the public `linkNotes` mutation it
  // was extracted from. The conversation source-link callers always pass a
  // controlled, non-empty kind, so they need no additional validation here.
  _ = try requireNote(fromNoteId, in: database)
  _ = try requireNote(toNoteId, in: database)
  let now = NoteStoreClock.system.now()
  try database.execute(
    """
    INSERT INTO note_links (
      from_note_id, to_note_id, link_kind, provenance, created_at
    ) VALUES (?, ?, ?, ?, ?)
    ON CONFLICT(from_note_id, to_note_id, link_kind) DO UPDATE SET
      provenance = CASE
        WHEN note_links.provenance IN ('human', 'system')
          AND excluded.provenance = 'ai'
          THEN note_links.provenance
        ELSE excluded.provenance
      END,
      created_at = CASE
        WHEN note_links.provenance IN ('human', 'system')
          AND excluded.provenance = 'ai'
          THEN note_links.created_at
        ELSE excluded.created_at
      END
    """,
    bindings: [
      .text(fromNoteId),
      .text(toNoteId),
      .text(linkKind),
      .text(provenance.rawValue),
      .text(now)
    ]
  )
  return try requireNoteLink(from: fromNoteId, to: toNoteId, linkKind: linkKind, in: database)
}

private func applyConversationNotebookKind(
  notebookId: String,
  assignedBy: String?,
  in database: SQLiteDatabase
) throws {
  let tag = try requireTag(id: NoteStoreSchema.agentConversationNotebookKindTagId, in: database)
  guard tag.name == NoteStoreSchema.agentConversationNotebookKindTag,
        tag.classId == "document-kind",
        tag.isSystem else {
    throw NoteServiceError.invalidInput(
      "system tag ownership is invalid: \(NoteStoreSchema.agentConversationNotebookKindTag)"
    )
  }
  try database.execute(
    """
    INSERT INTO notebook_tags (
      notebook_id, tag_id, provenance, assigned_by, deletable, created_at
    ) VALUES (?, ?, 'system', ?, 0, ?)
    ON CONFLICT(notebook_id, tag_id) DO NOTHING
    """,
    bindings: [
      .text(notebookId),
      .text(tag.tagId),
      .optionalText(assignedBy ?? "kaiba-note"),
      .text(NoteStoreClock.system.now())
    ]
  )
}

private func conversationBody(turn: NoteConversationTurn, noteNumber: Int) -> String {
  """
  # Conversation Turn \(noteNumber)

  ## User
  \(turn.userMarkdown)

  ## Agent
  \(turn.assistantMarkdown)
  """
}

private func noteLink(from row: SQLiteRow) throws -> NoteLink {
  guard let fromNoteId = row["from_note_id"],
        let toNoteId = row["to_note_id"],
        let linkKind = row["link_kind"],
        let provenanceText = row["provenance"],
        let provenance = NoteProvenance(rawValue: provenanceText),
        let createdAt = row["created_at"] else {
    throw NoteServiceError.invalidRow("note link row is missing required fields")
  }
  return NoteLink(
    fromNoteId: fromNoteId,
    toNoteId: toNoteId,
    linkKind: linkKind,
    provenance: provenance,
    createdAt: createdAt
  )
}

private func requireNoteLink(
  from fromNoteId: String,
  to toNoteId: String,
  linkKind: String,
  in database: SQLiteDatabase
) throws -> NoteLink {
  let rows = try database.query(
    """
    SELECT from_note_id, to_note_id, link_kind, provenance, created_at
    FROM note_links
    WHERE from_note_id = ? AND to_note_id = ? AND link_kind = ?
    LIMIT 1
    """,
    bindings: [.text(fromNoteId), .text(toNoteId), .text(linkKind)]
  )
  guard let row = rows.first else {
    throw NoteServiceError.notFound("note link not found: \(fromNoteId) -> \(toNoteId) (\(linkKind))")
  }
  return try noteLink(from: row)
}

private func noteComment(from row: SQLiteRow) throws -> NoteComment {
  guard let commentId = row["comment_id"],
        let bodyMarkdown = row["body_markdown"],
        let author = row["author"],
        let createdAt = row["created_at"] else {
    throw NoteServiceError.invalidRow("note comment row is missing required fields")
  }
  return NoteComment(
    commentId: commentId,
    noteId: row["note_id"] ?? nil,
    notebookId: row["notebook_id"] ?? nil,
    bodyMarkdown: bodyMarkdown,
    author: author,
    createdAt: createdAt
  )
}

private extension NoteLink {
  func counterpartNoteId(for noteId: String) -> String {
    fromNoteId == noteId ? toNoteId : fromNoteId
  }
}
