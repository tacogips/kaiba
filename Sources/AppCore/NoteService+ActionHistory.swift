import Foundation

// Recording side of the action history
// (`design-docs/specs/action-history-undo.md`). Mutations call `recordAction`
// on their already-open transaction, adjacent to `enqueueAutoActions`, so the
// log row commits or rolls back with the mutation itself (U2).

extension NoteService {
  static let defaultActionHistoryMaxEntries = 1000
  static let minimumActionHistoryMaxEntries = 10

  /// Appends one entry and prunes the oldest beyond the retention cap (U9).
  /// Runs on the caller's open transaction; a failure rolls the mutation back.
  @discardableResult
  func recordAction(_ record: NoteActionRecord, in db: SQLiteDatabase) throws -> Int64 {
    try db.execute(
      """
      INSERT INTO note_action_log (
        occurred_at, actor_user_id, provenance, entity_type, entity_id,
        notebook_id, action, display_json, delta_json, undoable, undo_of_seq
      ) VALUES (?, ?, ?, ?, ?, ?, ?, jsonb(?), jsonb(?), ?, ?)
      """,
      bindings: [
        .text(NoteStoreClock.system.now()),
        .id(writeOwnerUserId()),
        .text(record.provenance.rawValue),
        .text(record.entityType.rawValue),
        .text(record.entityId),
        .optionalID(record.notebookId),
        .text(record.kind.rawValue),
        .text(try JSONValue.object(record.display).encodedString()),
        .optionalText(try record.delta.map { try $0.encodedString() }),
        .int(record.undoable ? 1 : 0),
        record.undoOfSeq.map(SQLiteValue.int) ?? .null
      ]
    )
    // MAX(seq) rather than last_insert_rowid(): safe under BEGIN IMMEDIATE on
    // both the local handle and the SQL-over-HTTP driver.
    guard let seqText = try db.query("SELECT MAX(seq) AS seq FROM note_action_log").first?["seq"],
          let seq = Int64(seqText) else {
      throw NoteServiceError.invalidRow("action log insert produced no seq")
    }
    if let notebookId = record.notebookId {
      try persistTranslationSourceRevision(seq, notebookId: notebookId, in: db)
    }
    try pruneActionLog(in: db)
    return seq
  }

  /// Keeps the translation source token outside the prunable action-history
  /// retention window. The action and token share the caller's transaction, so
  /// a committed mutation can never disappear from translation validation.
  private func persistTranslationSourceRevision(
    _ revision: Int64,
    notebookId: NotebookID,
    in database: SQLiteDatabase
  ) throws {
    guard !(try database.query(
      "SELECT 1 FROM notebooks WHERE notebook_id = ? LIMIT 1",
      bindings: [.id(notebookId)]
    )).isEmpty else {
      // Notebook-deletion actions are recorded after the notebook row is gone.
      return
    }
    try database.execute(
      """
      INSERT INTO notebook_translation_revisions (notebook_id, revision)
      VALUES (?, ?)
      ON CONFLICT(notebook_id) DO UPDATE SET revision = excluded.revision
      """,
      bindings: [.id(notebookId), .int(revision)]
    )
  }

  /// Deletes entries beyond the newest `history.maxEntries`, oldest first,
  /// keeping any old entry a survivor still points at through `undo_of_seq`
  /// so redo chains stay resolvable (U9).
  func pruneActionLog(in db: SQLiteDatabase) throws {
    let maxEntries = actionHistoryMaxEntries(in: db)
    guard let cutoffText = try db.query(
      "SELECT seq FROM note_action_log ORDER BY seq DESC LIMIT 1 OFFSET ?",
      bindings: [.int(Int64(maxEntries))]
    ).first?["seq"], let cutoff = Int64(cutoffText) else {
      return
    }
    try db.execute(
      """
      DELETE FROM note_action_log
      WHERE seq <= ?
        AND seq NOT IN (
          SELECT undo_of_seq FROM note_action_log
          WHERE seq > ? AND undo_of_seq IS NOT NULL
        )
      """,
      bindings: [.int(cutoff), .int(cutoff)]
    )
  }

  /// The retention cap from the `history` app setting, defaulting to 1000 and
  /// clamped so a misconfigured store cannot erase its own history on the
  /// next write.
  func actionHistoryMaxEntries(in db: SQLiteDatabase) -> Int {
    let rows = (try? db.query(
      "SELECT json(value_json) AS value_json FROM app_settings WHERE setting_key = 'history' LIMIT 1"
    )) ?? []
    guard let text = rows.first?["value_json"],
          let value = try? JSONValue(parsing: text),
          let configured = value["maxEntries"]?.asInt else {
      return Self.defaultActionHistoryMaxEntries
    }
    return Swift.max(Self.minimumActionHistoryMaxEntries, configured)
  }

  // MARK: - Queries

  /// The newest entries for this actor, descending; `beforeSeq` pages older.
  public func actionHistory(limit: Int = 50, beforeSeq: Int64? = nil) throws -> [NoteActionLogEntry] {
    let clamped = Swift.min(Swift.max(limit, 1), 500)
    return try driver.withDatabase { database in
      var predicates = ["actor_user_id = ?"]
      var bindings: [SQLiteValue] = [.id(writeOwnerUserId())]
      if let beforeSeq {
        predicates.append("seq < ?")
        bindings.append(.int(beforeSeq))
      }
      bindings.append(.int(Int64(clamped)))
      return try database.query(
        """
        SELECT \(noteActionLogColumns)
        FROM note_action_log
        WHERE \(predicates.joined(separator: " AND "))
        ORDER BY seq DESC
        LIMIT ?
        """,
        bindings: bindings
      ).map(noteActionLogEntry(from:))
    }
  }

  /// What undo and redo would currently act on for this actor (U3, U7).
  public func undoState() throws -> NoteUndoState {
    try driver.withDatabase { database in
      try undoState(in: database)
    }
  }

  func undoState(in db: SQLiteDatabase) throws -> NoteUndoState {
    let undoTarget = try latestUndoTarget(in: db)
    let redoCandidate = try latestRedoCandidate(in: db)
    // A new action after an undo clears redo (U7): the undone entry must be
    // newer than every ordinary undo target to still be re-appliable.
    let redoTarget = redoCandidate.flatMap { candidate in
      candidate.seq > (undoTarget?.seq ?? 0) ? candidate : nil
    }
    return NoteUndoState(undoTarget: undoTarget, redoTarget: redoTarget)
  }

  /// The newest undoable, not-yet-undone entry for this actor. `redone`
  /// entries qualify (U3); `undone` entries never carry `undoable = 1`.
  func latestUndoTarget(in db: SQLiteDatabase) throws -> NoteActionLogEntry? {
    try db.query(
      """
      SELECT \(noteActionLogColumns)
      FROM note_action_log
      WHERE actor_user_id = ? AND undoable = 1 AND undone_by_seq IS NULL
      ORDER BY seq DESC
      LIMIT 1
      """,
      bindings: [.id(writeOwnerUserId())]
    ).first.map(noteActionLogEntry(from:))
  }

  func latestRedoCandidate(in db: SQLiteDatabase) throws -> NoteActionLogEntry? {
    try db.query(
      """
      SELECT \(noteActionLogColumns)
      FROM note_action_log
      WHERE actor_user_id = ? AND action = ? AND undone_by_seq IS NULL
      ORDER BY seq DESC
      LIMIT 1
      """,
      bindings: [.id(writeOwnerUserId()), .text(NoteActionKind.undone.rawValue)]
    ).first.map(noteActionLogEntry(from:))
  }

  func actionLogEntry(seq: Int64, in db: SQLiteDatabase) throws -> NoteActionLogEntry? {
    try db.query(
      "SELECT \(noteActionLogColumns) FROM note_action_log WHERE seq = ? LIMIT 1",
      bindings: [.int(seq)]
    ).first.map(noteActionLogEntry(from:))
  }
}

// MARK: - Snapshots

// Content enters the log only when it stops being live (U4): a deletion
// snapshots at record time, a creation snapshots at undo time. These helpers
// capture and restore the full restorable bundle of an entity (U12).

extension NoteService {
  func captureNoteSnapshot(noteId: NoteID, in db: SQLiteDatabase) throws -> JSONValue {
    guard let noteRow = try db.query(
      """
      SELECT note_id, notebook_id, note_number, title, title_source, body_markdown,
        read_only, created_by, updated_by, created_at, updated_at,
        CASE WHEN meta_json IS NULL THEN NULL ELSE json(meta_json) END AS meta_json
      FROM notes WHERE note_id = ? LIMIT 1
      """,
      bindings: [.id(noteId)]
    ).first else {
      throw NoteServiceError.notFound("note not found: \(noteId)")
    }
    let note: JSONObject = [
      "noteId": .optionalString(noteRow["note_id"]),
      "notebookId": .optionalString(noteRow["notebook_id"]),
      "noteNumber": .optionalInt(noteRow["note_number"].flatMap(Int.init)),
      "title": .optionalString(noteRow["title"]),
      "titleSource": .optionalString(noteRow["title_source"]),
      "bodyMarkdown": .optionalString(noteRow["body_markdown"]),
      "readOnly": .bool(noteRow["read_only"] == "1"),
      "createdBy": .optionalString(noteRow["created_by"]),
      "updatedBy": .optionalString(noteRow["updated_by"]),
      "createdAt": .optionalString(noteRow["created_at"]),
      "updatedAt": .optionalString(noteRow["updated_at"]),
      "metaJSON": .optionalString(noteRow["meta_json"])
    ]
    let tags = try db.query(
      "SELECT tag_id, provenance, assigned_by, deletable, created_at FROM note_tags WHERE note_id = ?",
      bindings: [.id(noteId)]
    ).map { row -> JSONValue in
      .object([
        "tagId": .optionalString(row["tag_id"]),
        "provenance": .optionalString(row["provenance"]),
        "assignedBy": .optionalString(row["assigned_by"]),
        "deletable": .bool(row["deletable"] == "1"),
        "createdAt": .optionalString(row["created_at"])
      ])
    }
    let links = try db.query(
      """
      SELECT from_note_id, to_note_id, link_kind, provenance, created_at
      FROM note_links WHERE from_note_id = ? OR to_note_id = ?
      """,
      bindings: [.id(noteId), .id(noteId)]
    ).map { row -> JSONValue in
      .object([
        "fromNoteId": .optionalString(row["from_note_id"]),
        "toNoteId": .optionalString(row["to_note_id"]),
        "linkKind": .optionalString(row["link_kind"]),
        "provenance": .optionalString(row["provenance"]),
        "createdAt": .optionalString(row["created_at"])
      ])
    }
    let comments = try db.query(
      """
      SELECT comment_id, note_id, notebook_id, body_markdown, author, created_at
      FROM note_comments WHERE note_id = ?
      """,
      bindings: [.id(noteId)]
    ).map(commentSnapshotValue(from:))
    let files = try db.query(
      "SELECT file_id, role, position FROM note_files WHERE note_id = ?",
      bindings: [.id(noteId)]
    ).map { row -> JSONValue in
      .object([
        "fileId": .optionalString(row["file_id"]),
        "role": .optionalString(row["role"]),
        "position": .optionalInt(row["position"].flatMap(Int.init))
      ])
    }
    return .object([
      "note": .object(note),
      "tags": .array(tags),
      "links": .array(links),
      "comments": .array(comments),
      "files": .array(files)
    ])
  }

  /// Re-creates a deleted note from its snapshot: the row verbatim, then every
  /// relation whose other end still exists (U12). The caller refreshes FTS.
  func restoreNoteSnapshot(
    _ snapshot: JSONValue,
    in db: SQLiteDatabase
  ) throws -> (noteId: NoteID, notebookId: NotebookID) {
    guard let note = snapshot["note"],
          let noteId = note.identifier("noteId", as: NoteID.self),
          let notebookId = note.identifier("notebookId", as: NotebookID.self),
          let noteNumber = note["noteNumber"]?.asInt,
          let bodyMarkdown = note["bodyMarkdown"]?.asString else {
      throw NoteServiceError.invalidRow("note snapshot is missing required fields")
    }
    guard try db.query(
      "SELECT 1 AS present FROM notes WHERE note_id = ? LIMIT 1",
      bindings: [.id(noteId)]
    ).isEmpty else {
      throw NoteServiceError.conflict("note already exists: \(noteId)")
    }
    _ = try requireWritableNotebook(notebookId, in: db)
    do {
      try db.execute(
        """
        INSERT INTO notes (
          note_id, notebook_id, note_number, title, title_source, body_markdown,
          read_only, created_by, updated_by, created_at, updated_at, meta_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, jsonb(?))
        """,
        bindings: [
          .id(noteId),
          .id(notebookId),
          .int(Int64(noteNumber)),
          .optionalText(note["title"]?.asString),
          .text(note["titleSource"]?.asString ?? NoteTitleSource.derived.rawValue),
          .text(bodyMarkdown),
          .int(note["readOnly"]?.asBool == true ? 1 : 0),
          .optionalText(note["createdBy"]?.asString),
          .optionalText(note["updatedBy"]?.asString),
          .text(note["createdAt"]?.asString ?? NoteStoreClock.system.now()),
          .text(note["updatedAt"]?.asString ?? NoteStoreClock.system.now()),
          .optionalText(note["metaJSON"]?.asString)
        ]
      )
    } catch let error as SQLiteError where isSQLiteUniqueConstraintViolation(error) {
      throw NoteServiceError.conflict("note number \(noteNumber) is taken in notebook \(notebookId)")
    }
    for tag in snapshot["tags"]?.asArray ?? [] {
      guard let tagId = tag.identifier("tagId", as: TagID.self),
            try !db.query(
              "SELECT 1 AS present FROM tags WHERE tag_id = ? LIMIT 1",
              bindings: [.id(tagId)]
            ).isEmpty else {
        continue
      }
      try db.execute(
        """
        INSERT OR IGNORE INTO note_tags (
          note_id, tag_id, provenance, assigned_by, deletable, created_at
        ) VALUES (?, ?, ?, ?, ?, ?)
        """,
        bindings: [
          .id(noteId),
          .id(tagId),
          .text(tag["provenance"]?.asString ?? NoteProvenance.human.rawValue),
          .optionalText(tag["assignedBy"]?.asString),
          .int(tag["deletable"]?.asBool == false ? 0 : 1),
          .text(tag["createdAt"]?.asString ?? NoteStoreClock.system.now())
        ]
      )
    }
    for link in snapshot["links"]?.asArray ?? [] {
      guard let fromId = link.identifier("fromNoteId", as: NoteID.self),
            let toId = link.identifier("toNoteId", as: NoteID.self) else {
        continue
      }
      let peer = fromId == noteId ? toId : fromId
      guard try !db.query(
        "SELECT 1 AS present FROM notes WHERE note_id = ? LIMIT 1",
        bindings: [.id(peer)]
      ).isEmpty else {
        continue
      }
      try db.execute(
        """
        INSERT OR IGNORE INTO note_links (
          from_note_id, to_note_id, link_kind, provenance, created_at
        ) VALUES (?, ?, ?, ?, ?)
        """,
        bindings: [
          .id(fromId),
          .id(toId),
          .text(link["linkKind"]?.asString ?? "related"),
          .text(link["provenance"]?.asString ?? NoteProvenance.human.rawValue),
          .text(link["createdAt"]?.asString ?? NoteStoreClock.system.now())
        ]
      )
    }
    for comment in snapshot["comments"]?.asArray ?? [] {
      try restoreCommentSnapshot(comment, in: db)
    }
    for file in snapshot["files"]?.asArray ?? [] {
      guard let fileId = file.identifier("fileId", as: FileID.self),
            let role = file["role"]?.asString,
            try !db.query(
              "SELECT 1 AS present FROM files WHERE file_id = ? LIMIT 1",
              bindings: [.id(fileId)]
            ).isEmpty else {
        continue
      }
      try db.execute(
        "INSERT OR IGNORE INTO note_files (note_id, file_id, role, position) VALUES (?, ?, ?, ?)",
        bindings: [.id(noteId), .id(fileId), .text(role), .int(Int64(file["position"]?.asInt ?? 0))]
      )
    }
    return (noteId, notebookId)
  }

  func captureNotebookSnapshot(notebookId: NotebookID, in db: SQLiteDatabase) throws -> JSONValue {
    guard let row = try db.query(
      """
      SELECT notebook_id, title, read_only, owner_user_id, library_id, created_by,
        updated_by, created_at, updated_at,
        CASE WHEN meta_json IS NULL THEN NULL ELSE json(meta_json) END AS meta_json
      FROM notebooks WHERE notebook_id = ? LIMIT 1
      """,
      bindings: [.id(notebookId)]
    ).first else {
      throw NoteServiceError.notFound("notebook not found: \(notebookId)")
    }
    let notebook: JSONObject = [
      "notebookId": .optionalString(row["notebook_id"]),
      "title": .optionalString(row["title"]),
      "readOnly": .bool(row["read_only"] == "1"),
      "ownerUserId": .optionalString(row["owner_user_id"]),
      "libraryId": .optionalString(row["library_id"]),
      "createdBy": .optionalString(row["created_by"]),
      "updatedBy": .optionalString(row["updated_by"]),
      "createdAt": .optionalString(row["created_at"]),
      "updatedAt": .optionalString(row["updated_at"]),
      "metaJSON": .optionalString(row["meta_json"])
    ]
    let tags = try db.query(
      """
      SELECT tag_id, provenance, assigned_by, deletable, created_at
      FROM notebook_tags WHERE notebook_id = ?
      """,
      bindings: [.id(notebookId)]
    ).map { row -> JSONValue in
      .object([
        "tagId": .optionalString(row["tag_id"]),
        "provenance": .optionalString(row["provenance"]),
        "assignedBy": .optionalString(row["assigned_by"]),
        "deletable": .bool(row["deletable"] == "1"),
        "createdAt": .optionalString(row["created_at"])
      ])
    }
    return .object(["notebook": .object(notebook), "tags": .array(tags)])
  }

  func restoreNotebookSnapshot(_ snapshot: JSONValue, in db: SQLiteDatabase) throws -> NotebookID {
    guard let notebook = snapshot["notebook"],
          let notebookId = notebook.identifier("notebookId", as: NotebookID.self),
          let title = notebook["title"]?.asString,
          let ownerUserId = notebook.identifier("ownerUserId", as: UserID.self),
          let libraryId = notebook.identifier("libraryId", as: LibraryID.self) else {
      throw NoteServiceError.invalidRow("notebook snapshot is missing required fields")
    }
    guard try db.query(
      "SELECT 1 AS present FROM notebooks WHERE notebook_id = ? LIMIT 1",
      bindings: [.id(notebookId)]
    ).isEmpty else {
      throw NoteServiceError.conflict("notebook already exists: \(notebookId)")
    }
    // The snapshot names the library it came from; re-creating the notebook
    // there is a write into that library and needs the same reach check any
    // other mutation gets (U6) — access may have been revoked since.
    try requireLibraryReach(
      libraryId: libraryId,
      subject: notebookId.rawValue,
      kind: .notebook,
      in: db
    )
    try db.execute(
      """
      INSERT INTO notebooks (
        notebook_id, title, read_only, owner_user_id, library_id, created_by,
        updated_by, created_at, updated_at, meta_json
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, jsonb(?))
      """,
      bindings: [
        .id(notebookId),
        .text(title),
        .int(notebook["readOnly"]?.asBool == true ? 1 : 0),
        .id(ownerUserId),
        .id(libraryId),
        .optionalText(notebook["createdBy"]?.asString),
        .optionalText(notebook["updatedBy"]?.asString),
        .text(notebook["createdAt"]?.asString ?? NoteStoreClock.system.now()),
        .text(notebook["updatedAt"]?.asString ?? NoteStoreClock.system.now()),
        .optionalText(notebook["metaJSON"]?.asString)
      ]
    )
    for tag in snapshot["tags"]?.asArray ?? [] {
      guard let tagId = tag.identifier("tagId", as: TagID.self),
            try !db.query(
              "SELECT 1 AS present FROM tags WHERE tag_id = ? LIMIT 1",
              bindings: [.id(tagId)]
            ).isEmpty else {
        continue
      }
      try db.execute(
        """
        INSERT OR IGNORE INTO notebook_tags (
          notebook_id, tag_id, provenance, assigned_by, deletable, created_at
        ) VALUES (?, ?, ?, ?, ?, ?)
        """,
        bindings: [
          .id(notebookId),
          .id(tagId),
          .text(tag["provenance"]?.asString ?? NoteProvenance.system.rawValue),
          .optionalText(tag["assignedBy"]?.asString),
          .int(tag["deletable"]?.asBool == false ? 0 : 1),
          .text(tag["createdAt"]?.asString ?? NoteStoreClock.system.now())
        ]
      )
    }
    return notebookId
  }

  func captureCommentSnapshot(commentId: CommentID, in db: SQLiteDatabase) throws -> JSONValue {
    guard let row = try db.query(
      """
      SELECT comment_id, note_id, notebook_id, body_markdown, author, created_at
      FROM note_comments WHERE comment_id = ? LIMIT 1
      """,
      bindings: [.id(commentId)]
    ).first else {
      throw NoteServiceError.notFound("comment not found: \(commentId)")
    }
    return commentSnapshotValue(from: row)
  }

  func restoreCommentSnapshot(_ snapshot: JSONValue, in db: SQLiteDatabase) throws {
    guard let commentId = snapshot.identifier("commentId", as: CommentID.self),
          let bodyMarkdown = snapshot["bodyMarkdown"]?.asString,
          let author = snapshot["author"]?.asString else {
      throw NoteServiceError.invalidRow("comment snapshot is missing required fields")
    }
    try db.execute(
      """
      INSERT OR IGNORE INTO note_comments (
        comment_id, note_id, notebook_id, body_markdown, author, created_at
      ) VALUES (?, ?, ?, ?, ?, ?)
      """,
      bindings: [
        .id(commentId),
        .optionalID(snapshot.identifier("noteId", as: NoteID.self)),
        .optionalID(snapshot.identifier("notebookId", as: NotebookID.self)),
        .text(bodyMarkdown),
        .text(author),
        .text(snapshot["createdAt"]?.asString ?? NoteStoreClock.system.now())
      ]
    )
  }
}

/// One changed note-tag assignment as `{tagId, name, before, after}`, where a
/// side is `null` when the assignment did not exist. Nil when nothing changed
/// (e.g. a protected assignment the apply skipped), so no-op applies record
/// nothing.
func noteTagAssignmentDelta(before: TagAssignment?, after: TagAssignment?) -> JSONValue? {
  func sideValue(_ assignment: TagAssignment?) -> JSONValue {
    guard let assignment else {
      return .null
    }
    return .object([
      "provenance": .string(assignment.provenance.rawValue),
      "assignedBy": .optionalString(assignment.assignedBy),
      "deletable": .bool(assignment.deletable),
      "createdAt": .string(assignment.createdAt)
    ])
  }
  let beforeValue = sideValue(before)
  let afterValue = sideValue(after)
  guard beforeValue != afterValue, let tag = (after ?? before)?.tag else {
    return nil
  }
  return .object([
    "tagId": .id(tag.tagId),
    "name": .string(tag.name),
    "before": beforeValue,
    "after": afterValue
  ])
}

private func commentSnapshotValue(from row: SQLiteRow) -> JSONValue {
  .object([
    "commentId": .optionalString(row["comment_id"]),
    "noteId": .optionalString(row["note_id"]),
    "notebookId": .optionalString(row["notebook_id"]),
    "bodyMarkdown": .optionalString(row["body_markdown"]),
    "author": .optionalString(row["author"]),
    "createdAt": .optionalString(row["created_at"])
  ])
}
