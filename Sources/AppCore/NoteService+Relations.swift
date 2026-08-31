import Foundation

public extension NoteService {
  @discardableResult
  func linkNotes(
    from fromNoteId: NoteID,
    to toNoteId: NoteID,
    linkKind: String = "related",
    provenance: NoteProvenance = .human
  ) throws -> NoteLink {
    return try driver.withDatabase { database in
      try database.transaction { db in
        _ = try requireNote(fromNoteId, in: db)
        _ = try requireNote(toNoteId, in: db)
        return try linkNotesInDatabase(
          from: fromNoteId,
          to: toNoteId,
          linkKind: linkKind,
          provenance: provenance,
          in: db
        )
      }
    }
  }

  func listLinks(noteId: NoteID) throws -> [NoteLink] {
    try driver.withDatabase { database in
      _ = try requireNote(noteId, in: database)
      // A link is visible only when both endpoints are visible. Store-wide
      // maintenance and memory workflows may create cross-owner links, but a
      // scoped caller must not learn the other endpoint's id or provenance.
      return try database.query(
        """
        SELECT from_note_id, to_note_id, link_kind, provenance, created_at
        FROM note_links
        WHERE from_note_id = ? OR to_note_id = ?
        ORDER BY created_at, from_note_id, to_note_id
        """,
        bindings: [.id(noteId), .id(noteId)]
      ).map(noteLink(from:)).filter {
        try canReachNote($0.fromNoteId, in: database)
          && canReachNote($0.toNoteId, in: database)
      }
    }
  }

  func proposeLinks(noteId: NoteID, limit: Int = 8) throws -> [NoteLinkProposal] {
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
        bindings: [.id(noteId), .id(noteId)]
      ).map(noteLink(from:)).filter {
        try canReachNote($0.fromNoteId, in: database)
          && canReachNote($0.toNoteId, in: database)
      }
      let excludedIds = Set(links.map { $0.counterpartNoteId(for: noteId) } + [noteId])
      let results = try filterReachable(
        try noteGraphNeighborsInDatabase(
          noteIds: [noteId],
          maxDepth: NoteGraphPolicy.associationMaxDepth,
          limit: limit,
          resultExclusions: excludedIds,
          scope: NoteSearchScope(
            reachableLibraryIds: try reachableLibraryIds(in: database),
            actingUserId: actingUserId,
            excludesLongTermMemory: actingUserId != nil || isUnauthenticatedPrincipal
          ),
          in: database
        ),
        in: database
      )
      return results.map { result in
        NoteLinkProposal(
          targetNote: result.note,
          linkKind: "related",
          reason: "Graph \(result.edgeKind.rawValue) path: \(result.pathNoteIds.rawValues.joined(separator: " -> "))."
        )
      }
    }
  }

  func listComments(noteId: NoteID) throws -> [NoteComment] {
    try driver.withDatabase { database in
      _ = try requireNote(noteId, in: database)
      return try database.query(
        """
        SELECT comment_id, note_id, notebook_id, body_markdown, author, created_at
        FROM note_comments
        WHERE note_id = ?
        ORDER BY created_at, comment_id
        """,
        bindings: [.id(noteId)]
      ).map(noteComment(from:))
    }
  }

  /// Every memo in the notebook — note-anchored and notebook-level alike —
  /// oldest first. The `note_id IN (...)` arm covers rows that predate the v9
  /// backfill only in stores restored from partial copies; normally
  /// `notebook_id` alone matches everything.
  func listNotebookComments(notebookId: NotebookID) throws -> [NoteComment] {
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
        bindings: [.id(notebookId), .id(notebookId)]
      ).map(noteComment(from:))
    }
  }

  /// A notebook-level memo: anchored to the notebook only, no note.
  @discardableResult
  func addNotebookComment(
    notebookId: NotebookID,
    bodyMarkdown: String,
    author: String = "user"
  ) throws -> NoteComment {
    let comment = try driver.withDatabase { database in
      try database.transaction { db -> NoteComment in
        _ = try requireNotebook(notebookId, in: db)
        let now = NoteStoreClock.system.now()
        let commentId = CommentID.generate()
        try db.execute(
          """
          INSERT INTO note_comments (comment_id, note_id, notebook_id, body_markdown, author, created_at)
          VALUES (?, NULL, ?, ?, ?, ?)
          """,
          bindings: [.id(commentId), .id(notebookId), .text(bodyMarkdown), .text(author), .text(now)]
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
    notebookId: NotebookID? = nil,
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
        FROM note_comments c
        WHERE body_markdown LIKE ? ESCAPE '\\'
        """
      var bindings: [SQLiteValue] = [.text("%\(escapedLikePattern(trimmed))%")]
      if let actingUserId {
        // Restored partial copies can retain a note-anchored comment without
        // its denormalized notebook id. Either anchor establishes ownership.
        sql += """

          AND EXISTS (
            SELECT 1
            FROM notebooks owner_notebook
            WHERE owner_notebook.owner_user_id = ?
              AND (
                owner_notebook.notebook_id = c.notebook_id
                OR owner_notebook.notebook_id = (
                  SELECT notebook_id FROM notes WHERE note_id = c.note_id
                )
              )
          )
          """
        bindings.append(.id(actingUserId))
      }
      // A memo is as reachable as the notebook it hangs on
      // (`design-docs/specs/library.md`).
      if let reachableLibraryIds = try reachableLibraryIds(in: database) {
        if reachableLibraryIds.isEmpty {
          return []
        }
        sql += """

          AND EXISTS (
            SELECT 1
            FROM notebooks reachable_notebook
            WHERE reachable_notebook.library_id IN (\(placeholders(count: reachableLibraryIds.count)))
              AND (
                reachable_notebook.notebook_id = c.notebook_id
                OR reachable_notebook.notebook_id = (
                  SELECT notebook_id FROM notes WHERE note_id = c.note_id
                )
              )
          )
          """
        bindings.append(contentsOf: reachableLibraryIds.sqliteBindings)
      }
      // The store-wide long-term-memory notebook is an internal processing
      // surface. Its bootstrap owner must not make memo rows visible through
      // either comment anchor to a scoped (including unauthenticated) caller.
      // Rows restored without a notebook id remain eligible when their note
      // anchor is otherwise reachable.
      if actingUserId != nil || isUnauthenticatedPrincipal {
        sql += """

          AND NOT EXISTS (
            SELECT 1
            FROM notebook_tags internal_notebook
            WHERE internal_notebook.tag_id = ?
              AND (
                internal_notebook.notebook_id = c.notebook_id
                OR internal_notebook.notebook_id = (
                  SELECT notebook_id FROM notes WHERE note_id = c.note_id
                )
              )
          )
          """
        bindings.append(.id(NoteStoreSchema.longTermMemoryNotebookKindTagId))
      }
      if let notebookId {
        sql += "\n  AND (c.notebook_id = ? OR c.note_id IN (SELECT note_id FROM notes WHERE notebook_id = ?))"
        bindings.append(.id(notebookId))
        bindings.append(.id(notebookId))
      }
      sql += "\nORDER BY created_at, comment_id LIMIT ?"
      bindings.append(.int(Int64(limit)))
      return try database.query(sql, bindings: bindings).map { row in
        guard let commentId = row.identifier("comment_id", as: CommentID.self),
          let bodyMarkdown = row["body_markdown"],
          let author = row["author"],
          let createdAt = row["created_at"]
        else {
          throw NoteServiceError.invalidRow("note comment row is missing required fields")
        }
        return NoteComment(
          commentId: commentId,
          noteId: row.identifier("note_id", as: NoteID.self) ?? nil,
          notebookId: row.identifier("notebook_id", as: NotebookID.self) ?? nil,
          bodyMarkdown: bodyMarkdown,
          author: author,
          createdAt: createdAt
        )
      }
    }
  }

  @discardableResult
  func appendConversationTurn(
    notebookId: NotebookID,
    turn: NoteConversationTurn,
    sourceLinks: NoteConversationSourceLinks? = nil,
    assignedBy: String? = nil,
    originatingActionId: AutoActionID? = nil,
    idempotencyKey: String? = nil
  ) throws -> Note {
    let result = try driver.withDatabase { database in
      try database.transaction { db in
        let conversation = try requireWritableNotebook(notebookId, in: db)
        // An idempotent replay has already committed its sources and must not
        // be invalidated if one is deleted before the retry arrives.
        if let idempotencyKey,
           let existing = try conversationTurn(
             notebookId: notebookId,
             idempotencyKey: idempotencyKey,
             in: db
           ) {
          return (note: existing, dispatches: [QueuedAutoActionDispatch]())
        }
        try requireConversationTurnSourceNotes(using: self, turn: turn, in: db)
        try requireConversationSourceLinks(using: self, sourceLinks: sourceLinks, in: db)
        let sourceNoteIds = turn.sourceNoteIds + (sourceLinks?.sourceNoteIds ?? [])
        if let sourceLibraryId = try sourceLibraryId(fromSourceNoteIds: sourceNoteIds, in: db),
          sourceLibraryId != conversation.libraryId {
          throw NoteServiceError.invalidInput(
            "conversation sources must belong to the conversation library"
          )
        }
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
    originatingActionId: AutoActionID? = nil
  ) throws -> SavedConversation {
    let result = try driver.withDatabase { database in
      try database.transaction { db in
        try requireConversationSourceLinks(using: self, sourceLinks: sourceLinks, in: db)
        for turn in transcript {
          try requireConversationTurnSourceNotes(using: self, turn: turn, in: db)
        }
        let now = NoteStoreClock.system.now()
        let notebookId = NotebookID.generate()
        // A conversation about a note stays in that note's library. Landing it
        // in the default library would carry the transcript of an
        // authenticated library into an unauthenticated one.
        let libraryId = try inheritedLibraryId(
          fromSourceNoteIds: (sourceLinks?.sourceNoteIds ?? [])
            + transcript.flatMap(\.sourceNoteIds),
          in: db
        )
        try db.execute(
          """
          INSERT INTO notebooks (
            notebook_id, title, owner_user_id, library_id, created_by, updated_by,
            created_at, updated_at, meta_json
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, jsonb(?))
          """,
          bindings: [
            .id(notebookId),
            .text(conversationTitle),
            .id(writeOwnerUserId()),
            .id(libraryId),
            .id(writeOwnerUserId()),
            .id(writeOwnerUserId()),
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
  notebookId: NotebookID,
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
  var sourceNoteIds = sourceLinks?.sourceNoteIds ?? []
  var missingSourceNoteIds: [NoteID] = []
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
  let noteId = NoteID.generate()
  let noteMetaJSON = try conversationTurnMetadataJSON(
    idempotencyKey: idempotencyKey,
    missingSourceNoteIds: missingSourceNoteIds
  )
  try database.execute(
    """
    INSERT INTO notes (
      note_id, notebook_id, note_number, title, body_markdown,
      read_only, created_by, updated_by, created_at, updated_at, meta_json
    ) VALUES (
      ?, ?, ?, ?, ?, 0,
      (SELECT owner_user_id FROM notebooks WHERE notebook_id = ?),
      (SELECT owner_user_id FROM notebooks WHERE notebook_id = ?),
      ?, ?, jsonb(?)
    )
    """,
    bindings: [
      .id(noteId),
      .id(notebookId),
      .int(Int64(noteNumber)),
      .optionalText(noteTitle(from: bodyMarkdown)),
      .text(bodyMarkdown),
      .id(notebookId),
      .id(notebookId),
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
    "UPDATE notebooks SET updated_at = ?, updated_by = owner_user_id WHERE notebook_id = ?",
    bindings: [.text(now), .id(notebookId)]
  )
  try refreshFTS(noteId: noteId, previous: nil, in: database)
  return (try loadNote(noteId, in: database), true)
}

/// Conversation sources are an externally supplied graph entry point.  The
/// batch hydrator deliberately stays unscoped for graph filtering, so writers
/// must establish read-level ownership here before inserting any link.
private func requireConversationTurnSourceNotes(
  using service: NoteService,
  turn: NoteConversationTurn,
  in database: SQLiteDatabase
) throws {
  for sourceNoteId in turn.sourceNoteIds {
    _ = try service.requireNote(sourceNoteId, in: database)
  }
}

private func requireConversationSourceLinks(
  using service: NoteService,
  sourceLinks: NoteConversationSourceLinks?,
  in database: SQLiteDatabase
) throws {
  guard let sourceLinks else { return }
  for sourceNoteId in sourceLinks.sourceNoteIds {
    do {
      _ = try service.requireNote(sourceNoteId, in: database)
    } catch let error as NoteServiceError {
      // Missing expansion sources are an explicitly supported recovery path.
      // A foreign source reports the same public error, so distinguish it by
      // checking only whether a row exists and never treat it as deletable.
      let exists = try !database.query(
        "SELECT 1 FROM notes WHERE note_id = ? LIMIT 1",
        bindings: [.id(sourceNoteId)]
      ).isEmpty
      if sourceLinks.allowMissingSourceNotes, !exists {
        continue
      }
      throw error
    }
  }
}

private func conversationTurn(
  notebookId: NotebookID,
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
    bindings: [.id(notebookId), .text(idempotencyKey)]
  )
  guard let noteId = rows.first?.identifier("note_id", as: NoteID.self) else {
    return nil
  }
  return try loadNote(noteId, in: database)
}

private func conversationTurnMetadataJSON(
  idempotencyKey: String?,
  missingSourceNoteIds: [NoteID]
) throws -> String? {
  guard idempotencyKey != nil || !missingSourceNoteIds.isEmpty else {
    return nil
  }
  var metadata: JSONObject = [:]
  if let idempotencyKey {
    metadata["idempotencyKey"] = .string(idempotencyKey)
  }
  if !missingSourceNoteIds.isEmpty {
    metadata["missingSourceNoteIds"] = .ids(missingSourceNoteIds)
  }
  let root: JSONValue = .object(["kaibaNote": .object(["conversationTurn": .object(metadata)])])
  do {
    return try root.encodedString()
  } catch {
    throw NoteServiceError.invalidInput("conversation turn metadata must be UTF-8 JSON")
  }
}

@discardableResult
func linkNotesInDatabase(
  from fromNoteId: NoteID,
  to toNoteId: NoteID,
  linkKind: String,
  provenance: NoteProvenance,
  in database: SQLiteDatabase
) throws -> NoteLink {
  // Bind link_kind verbatim (no trimming / emptiness check) so this shared
  // helper preserves the exact behavior of the public `linkNotes` mutation it
  // was extracted from. The conversation source-link callers always pass a
  // controlled, non-empty kind, so they need no additional validation here.
  _ = try loadNote(fromNoteId, in: database)
  _ = try loadNote(toNoteId, in: database)
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
      .id(fromNoteId),
      .id(toNoteId),
      .text(linkKind),
      .text(provenance.rawValue),
      .text(now)
    ]
  )
  return try requireNoteLink(from: fromNoteId, to: toNoteId, linkKind: linkKind, in: database)
}

private func applyConversationNotebookKind(
  notebookId: NotebookID,
  assignedBy: String?,
  in database: SQLiteDatabase
) throws {
  let tag = try requireTag(id: NoteStoreSchema.agentConversationNotebookKindTagId, in: database)
  guard tag.name == NoteStoreSchema.agentConversationNotebookKindTag,
        tag.classId == .documentKind,
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
      .id(notebookId),
      .id(tag.tagId),
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
  guard let fromNoteId = row.identifier("from_note_id", as: NoteID.self),
        let toNoteId = row.identifier("to_note_id", as: NoteID.self),
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
  from fromNoteId: NoteID,
  to toNoteId: NoteID,
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
    bindings: [.id(fromNoteId), .id(toNoteId), .text(linkKind)]
  )
  guard let row = rows.first else {
    throw NoteServiceError.notFound("note link not found: \(fromNoteId) -> \(toNoteId) (\(linkKind))")
  }
  return try noteLink(from: row)
}

private func noteComment(from row: SQLiteRow) throws -> NoteComment {
  guard let commentId = row.identifier("comment_id", as: CommentID.self),
        let bodyMarkdown = row["body_markdown"],
        let author = row["author"],
        let createdAt = row["created_at"] else {
    throw NoteServiceError.invalidRow("note comment row is missing required fields")
  }
  return NoteComment(
    commentId: commentId,
    noteId: row.identifier("note_id", as: NoteID.self) ?? nil,
    notebookId: row.identifier("notebook_id", as: NotebookID.self) ?? nil,
    bodyMarkdown: bodyMarkdown,
    author: author,
    createdAt: createdAt
  )
}

private extension NoteLink {
  func counterpartNoteId(for noteId: NoteID) -> NoteID {
    fromNoteId == noteId ? toNoteId : fromNoteId
  }
}
