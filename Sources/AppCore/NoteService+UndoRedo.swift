import Foundation

// Applying undo and redo (`design-docs/specs/action-history-undo.md`).
//
// One bidirectional routine per action kind (U5): undo writes the delta's
// `before` side, redo its `after` side. Every application is preceded by a
// conflict guard (U6) and runs in ONE transaction together with appending the
// `undone`/`redone` entry and linking the target (U8).

/// Everything one application produced: the snapshot captured when a creation
/// was undone (U4), and the change events to publish after commit (U13).
private struct NoteActionApplication {
  var deferredSnapshot: JSONValue?
  var changeEvents: [NoteChangeEvent]

  init(deferredSnapshot: JSONValue? = nil, changeEvents: [NoteChangeEvent] = []) {
    self.deferredSnapshot = deferredSnapshot
    self.changeEvents = changeEvents
  }
}

public extension NoteService {
  /// Reverts this actor's most recent undoable action, or returns nil when
  /// there is nothing to undo. Throws `NoteServiceError.conflict` when the
  /// store no longer matches what the entry expects.
  @discardableResult
  func undoLastAction() throws -> NoteActionUndoResult? {
    let outcome = try driver.withDatabase { database in
      try database.transaction { db -> (result: NoteActionUndoResult, events: [NoteChangeEvent])? in
        guard let target = try latestUndoTarget(in: db) else {
          return nil
        }
        let base = try resolveBaseEntry(of: target, in: db)
        let application = try applyActionEntry(
          base,
          direction: .undo,
          snapshotSource: nil,
          in: db
        )
        let undoneSeq = try recordAction(
          NoteActionRecord(
            kind: .undone,
            provenance: .human,
            entityType: base.entityType,
            entityId: base.entityId,
            notebookId: base.notebookId,
            display: base.display.asObject ?? [:],
            delta: application.deferredSnapshot,
            undoable: false,
            undoOfSeq: target.seq
          ),
          in: db
        )
        try db.execute(
          "UPDATE note_action_log SET undone_by_seq = ? WHERE seq = ?",
          bindings: [.int(undoneSeq), .int(target.seq)]
        )
        guard let entry = try actionLogEntry(seq: undoneSeq, in: db) else {
          throw NoteServiceError.invalidRow("undo entry vanished at seq \(undoneSeq)")
        }
        return (NoteActionUndoResult(entry: entry, target: target), application.changeEvents)
      }
    }
    guard let outcome else {
      return nil
    }
    for event in outcome.events {
      publishChange(event)
    }
    return outcome.result
  }

  /// Re-applies this actor's most recently undone action, or returns nil when
  /// redo is unavailable — including after any new action, which clears redo
  /// (U7).
  @discardableResult
  func redoLastAction() throws -> NoteActionUndoResult? {
    let outcome = try driver.withDatabase { database in
      try database.transaction { db -> (result: NoteActionUndoResult, events: [NoteChangeEvent])? in
        guard let undoneEntry = try undoState(in: db).redoTarget else {
          return nil
        }
        guard let targetSeq = undoneEntry.undoOfSeq,
              let target = try actionLogEntry(seq: targetSeq, in: db) else {
          throw NoteServiceError.conflict("redo target refers to a pruned entry")
        }
        let base = try resolveBaseEntry(of: target, in: db)
        let application = try applyActionEntry(
          base,
          direction: .redo,
          snapshotSource: undoneEntry.delta,
          in: db
        )
        let redoneSeq = try recordAction(
          NoteActionRecord(
            kind: .redone,
            provenance: .human,
            entityType: base.entityType,
            entityId: base.entityId,
            notebookId: base.notebookId,
            display: base.display.asObject ?? [:],
            undoable: true,
            undoOfSeq: base.seq
          ),
          in: db
        )
        try db.execute(
          "UPDATE note_action_log SET undone_by_seq = ? WHERE seq = ?",
          bindings: [.int(redoneSeq), .int(undoneEntry.seq)]
        )
        if base.kind?.isCreationShaped == true {
          // The snapshot moved back into the live row; clearing it keeps the
          // log free of copies of live data (U4, U9).
          try db.execute(
            "UPDATE note_action_log SET delta_json = NULL WHERE seq = ?",
            bindings: [.int(undoneEntry.seq)]
          )
        }
        guard let entry = try actionLogEntry(seq: redoneSeq, in: db) else {
          throw NoteServiceError.invalidRow("redo entry vanished at seq \(redoneSeq)")
        }
        return (NoteActionUndoResult(entry: entry, target: target), application.changeEvents)
      }
    }
    guard let outcome else {
      return nil
    }
    for event in outcome.events {
      publishChange(event)
    }
    return outcome.result
  }
}

extension NoteService {
  /// A `redone` target points `undo_of_seq` straight at its base entry; every
  /// other target is its own base. At most one hop (U8).
  func resolveBaseEntry(
    of target: NoteActionLogEntry,
    in db: SQLiteDatabase
  ) throws -> NoteActionLogEntry {
    guard target.kind == .redone else {
      return target
    }
    guard let baseSeq = target.undoOfSeq,
          let base = try actionLogEntry(seq: baseSeq, in: db) else {
      throw NoteServiceError.conflict("undo target refers to a pruned entry")
    }
    return base
  }

  private func applyActionEntry(
    _ base: NoteActionLogEntry,
    direction: NoteBodyPatchDirection,
    snapshotSource: JSONValue?,
    in db: SQLiteDatabase
  ) throws -> NoteActionApplication {
    guard let kind = base.kind else {
      throw NoteServiceError.conflict("cannot apply unknown action '\(base.action)'")
    }
    switch kind {
    case .noteBodyUpdated:
      return try applyNoteBodyDelta(base, direction: direction, in: db)
    case .noteTagsApplied, .noteTagRemoved:
      return try applyNoteTagsDelta(base, direction: direction, in: db)
    case .noteReadOnlySet:
      return try applyNoteReadOnlyDelta(base, direction: direction, in: db)
    case .notebookReadOnlySet:
      return try applyNotebookReadOnlyDelta(base, direction: direction, in: db)
    case .noteCreated:
      switch direction {
      case .undo:
        return try captureAndDeleteNote(base, in: db)
      case .redo:
        return try restoreNote(from: snapshotSource, in: db)
      }
    case .noteDeleted:
      switch direction {
      case .undo:
        return try restoreNote(from: base.delta, in: db)
      case .redo:
        var application = try captureAndDeleteNote(base, in: db)
        // The base entry still holds the snapshot; the re-deletion needs no
        // second copy.
        application.deferredSnapshot = nil
        return application
      }
    case .notebookCreated:
      switch direction {
      case .undo:
        return try captureAndDeleteEmptyNotebook(base, in: db)
      case .redo:
        return try restoreNotebook(from: snapshotSource, in: db)
      }
    case .commentAdded:
      switch direction {
      case .undo:
        return try captureAndDeleteComment(base, in: db)
      case .redo:
        return try restoreComment(from: snapshotSource, base: base, in: db)
      }
    case .notebookDeleted, .notebookIngested, .undone, .redone:
      throw NoteServiceError.conflict("action '\(base.action)' is not undoable")
    }
  }

  // MARK: - Delta applications

  private func applyNoteBodyDelta(
    _ base: NoteActionLogEntry,
    direction: NoteBodyPatchDirection,
    in db: SQLiteDatabase
  ) throws -> NoteActionApplication {
    let noteId = NoteID(base.entityId)
    let note = try requireWritableNote(noteId, in: db)
    guard let delta = base.delta else {
      throw NoteServiceError.conflict("body update entry carries no delta")
    }
    let previous = try ftsPayload(noteId: noteId, in: db)
    var newBody = note.bodyMarkdown
    if let bodyValue = delta["body"] {
      guard let patch = NoteBodyPatch(jsonValue: bodyValue),
            let patched = applyNoteBodyPatch(patch, to: note.bodyMarkdown, direction: direction) else {
        throw NoteServiceError.conflict("note body no longer matches the recorded edit: \(noteId)")
      }
      newBody = patched
    }
    var newTitle = note.title
    if let titleValue = delta["title"] {
      let expected = direction == .undo ? titleValue["after"]?.asString : titleValue["before"]?.asString
      let replacement = direction == .undo ? titleValue["before"]?.asString : titleValue["after"]?.asString
      guard note.title == expected else {
        throw NoteServiceError.conflict("note title no longer matches the recorded edit: \(noteId)")
      }
      newTitle = replacement
    }
    let now = NoteStoreClock.system.now()
    try db.execute(
      """
      UPDATE notes
      SET title = ?, body_markdown = ?, updated_at = ?,
        updated_by = (SELECT owner_user_id FROM notebooks WHERE notebook_id = notes.notebook_id)
      WHERE note_id = ?
      """,
      bindings: [.optionalText(newTitle), .text(newBody), .text(now), .id(noteId)]
    )
    try touchNotebook(note.notebookId, in: db)
    try refreshFTS(noteId: noteId, previous: previous, in: db)
    return NoteActionApplication(changeEvents: [
      NoteChangeEvent(kind: NoteChangeEventKind.noteUpdated, notebookId: note.notebookId)
    ])
  }

  private func applyNoteTagsDelta(
    _ base: NoteActionLogEntry,
    direction: NoteBodyPatchDirection,
    in db: SQLiteDatabase
  ) throws -> NoteActionApplication {
    let noteId = NoteID(base.entityId)
    let note = try requireNote(noteId, in: db)
    guard let items = base.delta?["tags"]?.asArray else {
      throw NoteServiceError.conflict("tag entry carries no delta")
    }
    let previous = try ftsPayload(noteId: noteId, in: db)
    for item in items {
      guard let tagId = item.identifier("tagId", as: TagID.self) else {
        throw NoteServiceError.invalidRow("tag delta is missing its tag id")
      }
      // The member subscript folds `.null` into nil, which is exactly the
      // "assignment absent" reading both sides use.
      let expected = direction == .undo ? item["after"] : item["before"]
      let desired = direction == .undo ? item["before"] : item["after"]
      let currentRow = try db.query(
        """
        SELECT provenance, assigned_by, deletable, created_at
        FROM note_tags WHERE note_id = ? AND tag_id = ? LIMIT 1
        """,
        bindings: [.id(noteId), .id(tagId)]
      ).first
      let current: JSONValue? = currentRow.map { row in
        .object([
          "provenance": .optionalString(row["provenance"]),
          "assignedBy": .optionalString(row["assigned_by"]),
          "deletable": .bool(row["deletable"] == "1"),
          "createdAt": .optionalString(row["created_at"])
        ])
      }
      guard current == expected else {
        throw NoteServiceError.conflict("tag assignment changed since it was recorded: \(tagId)")
      }
      if let desired {
        guard try !db.query(
          "SELECT 1 AS present FROM tags WHERE tag_id = ? LIMIT 1",
          bindings: [.id(tagId)]
        ).isEmpty else {
          throw NoteServiceError.conflict("tag no longer exists: \(tagId)")
        }
        try db.execute(
          """
          INSERT OR REPLACE INTO note_tags (
            note_id, tag_id, provenance, assigned_by, deletable, created_at
          ) VALUES (?, ?, ?, ?, ?, ?)
          """,
          bindings: [
            .id(noteId),
            .id(tagId),
            .text(desired["provenance"]?.asString ?? NoteProvenance.human.rawValue),
            .optionalText(desired["assignedBy"]?.asString),
            .int(desired["deletable"]?.asBool == false ? 0 : 1),
            .text(desired["createdAt"]?.asString ?? NoteStoreClock.system.now())
          ]
        )
      } else {
        try db.execute(
          "DELETE FROM note_tags WHERE note_id = ? AND tag_id = ?",
          bindings: [.id(noteId), .id(tagId)]
        )
      }
    }
    try refreshFTS(noteId: noteId, previous: previous, in: db)
    return NoteActionApplication(changeEvents: [
      NoteChangeEvent(kind: NoteChangeEventKind.noteTags, notebookId: note.notebookId)
    ])
  }

  private func applyNoteReadOnlyDelta(
    _ base: NoteActionLogEntry,
    direction: NoteBodyPatchDirection,
    in db: SQLiteDatabase
  ) throws -> NoteActionApplication {
    let noteId = NoteID(base.entityId)
    let note = try requireNote(noteId, in: db)
    let (expected, desired) = try readOnlyDeltaSides(base, direction: direction)
    guard note.readOnly == expected else {
      throw NoteServiceError.conflict("note read-only flag changed since it was recorded: \(noteId)")
    }
    try db.execute(
      """
      UPDATE notes SET read_only = ?, updated_at = ?,
        updated_by = (SELECT owner_user_id FROM notebooks WHERE notebook_id = notes.notebook_id)
      WHERE note_id = ?
      """,
      bindings: [.int(desired ? 1 : 0), .text(NoteStoreClock.system.now()), .id(noteId)]
    )
    return NoteActionApplication(changeEvents: [
      NoteChangeEvent(kind: NoteChangeEventKind.noteUpdated, notebookId: note.notebookId)
    ])
  }

  private func applyNotebookReadOnlyDelta(
    _ base: NoteActionLogEntry,
    direction: NoteBodyPatchDirection,
    in db: SQLiteDatabase
  ) throws -> NoteActionApplication {
    let notebookId = NotebookID(base.entityId)
    let notebook = try requireNotebook(notebookId, in: db)
    let (expected, desired) = try readOnlyDeltaSides(base, direction: direction)
    guard notebook.readOnly == expected else {
      throw NoteServiceError.conflict(
        "notebook read-only flag changed since it was recorded: \(notebookId)"
      )
    }
    try db.execute(
      "UPDATE notebooks SET read_only = ?, updated_at = ?, updated_by = owner_user_id WHERE notebook_id = ?",
      bindings: [.int(desired ? 1 : 0), .text(NoteStoreClock.system.now()), .id(notebookId)]
    )
    return NoteActionApplication(changeEvents: [
      NoteChangeEvent(
        kind: NoteChangeEventKind.notebookReadOnly,
        notebookId: notebookId,
        tagNames: folderTagNames(of: notebook)
      )
    ])
  }

  private func readOnlyDeltaSides(
    _ base: NoteActionLogEntry,
    direction: NoteBodyPatchDirection
  ) throws -> (expected: Bool, desired: Bool) {
    guard let readOnly = base.delta?["readOnly"],
          let before = readOnly["before"]?.asBool,
          let after = readOnly["after"]?.asBool else {
      throw NoteServiceError.conflict("read-only entry carries no delta")
    }
    return direction == .undo ? (after, before) : (before, after)
  }

  // MARK: - Creation/deletion applications

  private func captureAndDeleteNote(
    _ base: NoteActionLogEntry,
    in db: SQLiteDatabase
  ) throws -> NoteActionApplication {
    let noteId = NoteID(base.entityId)
    let note: Note
    do {
      note = try requireNote(noteId, in: db)
    } catch NoteServiceError.notFound {
      throw NoteServiceError.conflict("note no longer exists: \(noteId)")
    }
    let notebook = try requireNotebook(note.notebookId, in: db)
    guard !note.readOnly, !notebook.readOnly else {
      throw NoteServiceError.readOnly(noteId.rawValue)
    }
    let snapshot = try captureNoteSnapshot(noteId: noteId, in: db)
    try deleteNoteRows(noteId: noteId, in: db)
    try touchNotebook(note.notebookId, in: db)
    return NoteActionApplication(
      deferredSnapshot: snapshot,
      changeEvents: [
        NoteChangeEvent(kind: NoteChangeEventKind.noteUpdated, notebookId: note.notebookId)
      ]
    )
  }

  private func restoreNote(
    from snapshot: JSONValue?,
    in db: SQLiteDatabase
  ) throws -> NoteActionApplication {
    guard let snapshot else {
      throw NoteServiceError.conflict("note snapshot is no longer available")
    }
    let restored = try restoreNoteSnapshot(snapshot, in: db)
    try refreshFTS(noteId: restored.noteId, previous: nil, in: db)
    try touchNotebook(restored.notebookId, in: db)
    return NoteActionApplication(changeEvents: [
      NoteChangeEvent(kind: NoteChangeEventKind.noteCreated, notebookId: restored.notebookId)
    ])
  }

  private func captureAndDeleteEmptyNotebook(
    _ base: NoteActionLogEntry,
    in db: SQLiteDatabase
  ) throws -> NoteActionApplication {
    let notebookId = NotebookID(base.entityId)
    let notebook: Notebook
    do {
      notebook = try requireNotebook(notebookId, in: db)
    } catch NoteServiceError.notFound {
      throw NoteServiceError.conflict("notebook no longer exists: \(notebookId)")
    }
    guard !notebook.readOnly else {
      throw NoteServiceError.readOnly(notebookId.rawValue)
    }
    let noteCount = try db.query(
      "SELECT COUNT(*) AS note_count FROM notes WHERE notebook_id = ?",
      bindings: [.id(notebookId)]
    ).first?["note_count"].flatMap(Int.init) ?? 0
    guard noteCount == 0 else {
      throw NoteServiceError.conflict(
        "notebook gained notes since it was created: \(notebookId)"
      )
    }
    let snapshot = try captureNotebookSnapshot(notebookId: notebookId, in: db)
    try db.execute("DELETE FROM notebook_tags WHERE notebook_id = ?", bindings: [.id(notebookId)])
    try db.execute("DELETE FROM notebook_files WHERE notebook_id = ?", bindings: [.id(notebookId)])
    try db.execute("DELETE FROM notebooks WHERE notebook_id = ?", bindings: [.id(notebookId)])
    return NoteActionApplication(
      deferredSnapshot: snapshot,
      changeEvents: [
        NoteChangeEvent(
          kind: NoteChangeEventKind.notebookDeleted,
          notebookId: notebookId,
          tagNames: folderTagNames(of: notebook)
        )
      ]
    )
  }

  private func restoreNotebook(
    from snapshot: JSONValue?,
    in db: SQLiteDatabase
  ) throws -> NoteActionApplication {
    guard let snapshot else {
      throw NoteServiceError.conflict("notebook snapshot is no longer available")
    }
    let notebookId = try restoreNotebookSnapshot(snapshot, in: db)
    return NoteActionApplication(changeEvents: [
      NoteChangeEvent(kind: NoteChangeEventKind.notebookCreated, notebookId: notebookId)
    ])
  }

  private func captureAndDeleteComment(
    _ base: NoteActionLogEntry,
    in db: SQLiteDatabase
  ) throws -> NoteActionApplication {
    let commentId = CommentID(base.entityId)
    let snapshot: JSONValue
    do {
      snapshot = try captureCommentSnapshot(commentId: commentId, in: db)
    } catch NoteServiceError.notFound {
      throw NoteServiceError.conflict("comment no longer exists: \(commentId)")
    }
    try db.execute(
      "DELETE FROM note_comments WHERE comment_id = ?",
      bindings: [.id(commentId)]
    )
    return NoteActionApplication(
      deferredSnapshot: snapshot,
      changeEvents: [
        NoteChangeEvent(kind: NoteChangeEventKind.noteUpdated, notebookId: base.notebookId)
      ]
    )
  }

  private func restoreComment(
    from snapshot: JSONValue?,
    base: NoteActionLogEntry,
    in db: SQLiteDatabase
  ) throws -> NoteActionApplication {
    guard let snapshot else {
      throw NoteServiceError.conflict("comment snapshot is no longer available")
    }
    if let noteId = snapshot.identifier("noteId", as: NoteID.self) {
      guard try !db.query(
        "SELECT 1 AS present FROM notes WHERE note_id = ? LIMIT 1",
        bindings: [.id(noteId)]
      ).isEmpty else {
        throw NoteServiceError.conflict("the comment's note no longer exists: \(noteId)")
      }
    }
    try restoreCommentSnapshot(snapshot, in: db)
    return NoteActionApplication(changeEvents: [
      NoteChangeEvent(kind: NoteChangeEventKind.noteUpdated, notebookId: base.notebookId)
    ])
  }

  private func touchNotebook(_ notebookId: NotebookID, in db: SQLiteDatabase) throws {
    try db.execute(
      "UPDATE notebooks SET updated_at = ?, updated_by = owner_user_id WHERE notebook_id = ?",
      bindings: [.text(NoteStoreClock.system.now()), .id(notebookId)]
    )
  }
}
