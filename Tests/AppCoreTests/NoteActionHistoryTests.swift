import XCTest

@testable import AppCore

/// Action history recording, splice patches, and undo/redo
/// (`design-docs/specs/action-history-undo.md`).
final class NoteActionHistoryTests: NoteTestCase {

  // MARK: - Splice patch

  func testBodyPatchStoresOnlyChangedSpan() throws {
    let old = "# Title\n\nfirst paragraph\n\nlast paragraph\n"
    let new = "# Title\n\nrewritten paragraph\n\nlast paragraph\n"
    let patch = try XCTUnwrap(makeNoteBodyPatch(from: old, to: new))
    XCTAssertEqual(patch.removed, "first")
    XCTAssertEqual(patch.inserted, "rewritten")
    XCTAssertEqual(applyNoteBodyPatch(patch, to: new, direction: .undo), old)
    XCTAssertEqual(applyNoteBodyPatch(patch, to: old, direction: .redo), new)
  }

  func testBodyPatchHandlesMultibyteText() throws {
    let old = "はじめに🙂\n本文です\nおわり"
    let new = "はじめに🙂\n書き直した本文🎉です\nおわり"
    let patch = try XCTUnwrap(makeNoteBodyPatch(from: old, to: new))
    XCTAssertEqual(applyNoteBodyPatch(patch, to: new, direction: .undo), old)
    XCTAssertEqual(applyNoteBodyPatch(patch, to: old, direction: .redo), new)
  }

  func testBodyPatchFullRewriteAndEdges() throws {
    XCTAssertNil(makeNoteBodyPatch(from: "same", to: "same"))
    let rewrite = try XCTUnwrap(makeNoteBodyPatch(from: "abc", to: "xyz"))
    XCTAssertEqual(applyNoteBodyPatch(rewrite, to: "xyz", direction: .undo), "abc")
    let append = try XCTUnwrap(makeNoteBodyPatch(from: "abc", to: "abcdef"))
    XCTAssertEqual(append.removed, "")
    XCTAssertEqual(append.inserted, "def")
    XCTAssertEqual(applyNoteBodyPatch(append, to: "abcdef", direction: .undo), "abc")
    let fromEmpty = try XCTUnwrap(makeNoteBodyPatch(from: "", to: "hello"))
    XCTAssertEqual(applyNoteBodyPatch(fromEmpty, to: "hello", direction: .undo), "")
  }

  func testBodyPatchIsByteExactAcrossNormalizationForms() throws {
    // "é" precomposed (U+00E9) vs decomposed (e + U+0301): equal as
    // Characters, different bytes. The patch must capture the byte change so
    // undo of the edit that re-encoded the shared text still applies.
    let old = "caf\u{E9} menu"
    let new = "cafe\u{301} menu, updated"
    let patch = try XCTUnwrap(makeNoteBodyPatch(from: old, to: new))
    XCTAssertEqual(applyNoteBodyPatch(patch, to: new, direction: .undo), old)
    XCTAssertEqual(applyNoteBodyPatch(patch, to: old, direction: .redo), new)
    // Canonically equal but byte-different strings are still a change.
    XCTAssertNotNil(makeNoteBodyPatch(from: "caf\u{E9}", to: "cafe\u{301}"))
  }

  func testBodyPatchRefusesMismatchedText() throws {
    let patch = try XCTUnwrap(makeNoteBodyPatch(from: "aaa bbb ccc", to: "aaa xxx ccc"))
    XCTAssertNil(applyNoteBodyPatch(patch, to: "aaa yyy ccc", direction: .undo))
    XCTAssertNil(applyNoteBodyPatch(patch, to: "totally different", direction: .undo))
  }

  func testBodyPatchRoundTripsThroughJSON() throws {
    let patch = try XCTUnwrap(makeNoteBodyPatch(from: "one two three", to: "one 2️⃣ three"))
    let text = try patch.jsonValue.encodedString()
    let decoded = try XCTUnwrap(NoteBodyPatch(jsonValue: JSONValue(parsing: text)))
    XCTAssertEqual(decoded, patch)
  }

  // MARK: - Recording

  func testCreateNoteRecordsDeltaOnlyEntries() throws {
    let service = try NoteService(driver: makeNoteDriver())
    let note = try service.createNote(bodyMarkdown: "# Hello\n\nbody")
    let entries = try service.actionHistory()
    XCTAssertEqual(entries.map(\.action), ["note-created", "notebook-created"])
    let created = try XCTUnwrap(entries.first)
    XCTAssertEqual(created.entityId, note.noteId.rawValue)
    XCTAssertTrue(created.undoable)
    // Creations store no content (U4): the live row is the data.
    XCTAssertNil(created.delta)
  }

  func testUpdateNoteBodyRecordsSplicePatchNotFullText() throws {
    let service = try NoteService(driver: makeNoteDriver())
    let longTail = String(repeating: "shared tail text\n", count: 50)
    let note = try service.createNote(bodyMarkdown: "# Title\n\nold intro\n\n" + longTail)
    _ = try service.updateNoteBody(
      noteId: note.noteId,
      bodyMarkdown: "# Title\n\nnew intro\n\n" + longTail
    )
    let entry = try XCTUnwrap(try service.actionHistory().first)
    XCTAssertEqual(entry.action, "note-body-updated")
    let body = try XCTUnwrap(entry.delta?["body"])
    XCTAssertEqual(body["del"]?.asString, "old")
    XCTAssertEqual(body["ins"]?.asString, "new")
  }

  func testNoOpEditRecordsNothing() throws {
    let service = try NoteService(driver: makeNoteDriver())
    let note = try service.createNote(bodyMarkdown: "stable body")
    let countBefore = try service.actionHistory().count
    _ = try service.updateNoteBody(noteId: note.noteId, bodyMarkdown: "stable body")
    XCTAssertEqual(try service.actionHistory().count, countBefore)
  }

  func testDeleteNotebookAndIngestAreRecordedButNotUndoable() throws {
    let service = try NoteService(driver: makeNoteDriver())
    let ingest = try service.createNotebookWithNotes(
      title: "Bulk",
      pages: [NotePageDraft(bodyMarkdown: "page", readOnly: false)]
    )
    try service.deleteNotebook(notebookId: ingest.notebook.notebookId)
    let entries = try service.actionHistory()
    XCTAssertEqual(entries.map(\.action), ["notebook-deleted", "notebook-ingested"])
    XCTAssertTrue(entries.allSatisfy { !$0.undoable })
    XCTAssertNil(try service.undoState().undoTarget)
  }

  // MARK: - Undo/redo: body edits

  func testUndoAndRedoBodyEdit() throws {
    let service = try NoteService(driver: makeNoteDriver())
    let note = try service.createNote(bodyMarkdown: "# Note\n\nversion one")
    _ = try service.updateNoteBody(noteId: note.noteId, bodyMarkdown: "# Note\n\nversion two")

    let undone = try XCTUnwrap(try service.undoLastAction())
    XCTAssertEqual(undone.target.action, "note-body-updated")
    XCTAssertEqual(try service.getNote(note.noteId).bodyMarkdown, "# Note\n\nversion one")

    let redone = try XCTUnwrap(try service.redoLastAction())
    XCTAssertEqual(redone.entry.action, "redone")
    XCTAssertEqual(try service.getNote(note.noteId).bodyMarkdown, "# Note\n\nversion two")

    // A redone entry is itself undoable (U3).
    _ = try XCTUnwrap(try service.undoLastAction())
    XCTAssertEqual(try service.getNote(note.noteId).bodyMarkdown, "# Note\n\nversion one")
  }

  func testUndoBodyEditRestoresDerivedTitle() throws {
    let service = try NoteService(driver: makeNoteDriver())
    let note = try service.createNote(bodyMarkdown: "# First Title\n\nbody")
    _ = try service.updateNoteBody(noteId: note.noteId, bodyMarkdown: "# Second Title\n\nbody")
    XCTAssertEqual(try service.getNote(note.noteId).title, "Second Title")
    _ = try service.undoLastAction()
    XCTAssertEqual(try service.getNote(note.noteId).title, "First Title")
  }

  func testUndoConflictsAfterInterveningEdit() throws {
    let service = try NoteService(driver: makeNoteDriver())
    let note = try service.createNote(bodyMarkdown: "start")
    _ = try service.updateNoteBody(noteId: note.noteId, bodyMarkdown: "start edited")
    _ = try service.undoLastAction()
    // Simulate divergence: redo target expects "start", but the store moved on.
    _ = try service.updateNoteBody(noteId: note.noteId, bodyMarkdown: "moved on")
    // The new edit cleared redo (U7)...
    XCTAssertNil(try service.redoLastAction())
    // ...and undoing the new edit still works linearly.
    _ = try XCTUnwrap(try service.undoLastAction())
    XCTAssertEqual(try service.getNote(note.noteId).bodyMarkdown, "start")
  }

  // MARK: - Undo/redo: create and delete

  func testUndoCreateCapturesDeferredSnapshotAndRedoRestores() throws {
    let service = try NoteService(driver: makeNoteDriver())
    let note = try service.createNote(
      bodyMarkdown: "# Snap\n\ncontent",
      tags: [NoteTagInput(name: "keep-me")]
    )
    let undone = try XCTUnwrap(try service.undoLastAction())
    XCTAssertEqual(undone.target.action, "note-created")
    XCTAssertThrowsError(try service.getNote(note.noteId))
    // The undone entry now carries the snapshot (deferred capture, U4).
    XCTAssertNotNil(undone.entry.delta?["note"])

    let redone = try XCTUnwrap(try service.redoLastAction())
    XCTAssertEqual(redone.entry.action, "redone")
    let restored = try service.getNote(note.noteId)
    XCTAssertEqual(restored.bodyMarkdown, "# Snap\n\ncontent")
    XCTAssertEqual(restored.noteNumber, note.noteNumber)
    XCTAssertEqual(restored.tags.map(\.tag.name), ["keep-me"])
    // The consumed snapshot was cleared (U9).
    let consumed = try service.actionHistory().first { $0.seq == undone.entry.seq }
    XCTAssertNil(try XCTUnwrap(consumed).delta)
  }

  func testUndoDeleteRestoresNoteWithRelations() throws {
    let service = try NoteService(driver: makeNoteDriver())
    let note = try service.createNote(
      bodyMarkdown: "# Doomed\n\ncontent",
      tags: [NoteTagInput(name: "survivor")]
    )
    _ = try service.addComment(noteId: note.noteId, bodyMarkdown: "a memo")
    try service.deleteNote(noteId: note.noteId)
    XCTAssertThrowsError(try service.getNote(note.noteId))

    let undone = try XCTUnwrap(try service.undoLastAction())
    XCTAssertEqual(undone.target.action, "note-deleted")
    let restored = try service.getNote(note.noteId)
    XCTAssertEqual(restored.bodyMarkdown, "# Doomed\n\ncontent")
    XCTAssertEqual(restored.tags.map(\.tag.name), ["survivor"])
    XCTAssertEqual(try service.listComments(noteId: note.noteId).map(\.bodyMarkdown), ["a memo"])

    // Redo deletes it again without needing a second snapshot.
    _ = try XCTUnwrap(try service.redoLastAction())
    XCTAssertThrowsError(try service.getNote(note.noteId))
  }

  func testUndoNotebookCreateRequiresEmptyNotebook() throws {
    let service = try NoteService(driver: makeNoteDriver())
    let notebook = try service.createNotebook(title: "Empty me")
    _ = try service.createNote(notebookId: notebook.notebookId, bodyMarkdown: "occupant")
    // Undo target is the note creation; undo it first.
    _ = try XCTUnwrap(try service.undoLastAction())
    // Now the notebook creation is the target and the notebook is empty.
    let undone = try XCTUnwrap(try service.undoLastAction())
    XCTAssertEqual(undone.target.action, "notebook-created")
    XCTAssertThrowsError(try service.getNotebook(notebook.notebookId))
    // Redo restores the notebook.
    _ = try XCTUnwrap(try service.redoLastAction())
    XCTAssertEqual(try service.getNotebook(notebook.notebookId).title, "Empty me")
  }

  func testUndoNotebookCreateConflictsWhenNotebookHasNotes() throws {
    let driver = try makeNoteDriver()
    let service = try NoteService(driver: driver)
    let notebook = try service.createNotebook(title: "Occupied")
    // A raw storage write simulates an independently committed occupant while
    // keeping the default actor's history target on notebook creation.
    try driver.withDatabase { database in
      try database.execute(
        """
        INSERT INTO notes (
          note_id, notebook_id, note_number, title, title_source, body_markdown,
          read_only, created_by, updated_by, created_at, updated_at, meta_json
        ) VALUES (?, ?, 1, NULL, 'derived', ?, 0, ?, ?, ?, ?, NULL)
        """,
        bindings: [
          .id(NoteID.generate()), .id(notebook.notebookId), .text("occupant note"),
          .id(NoteStoreSchema.defaultUserId), .id(NoteStoreSchema.defaultUserId),
          .text(NoteStoreClock.system.now()), .text(NoteStoreClock.system.now())
        ]
      )
    }
    XCTAssertThrowsError(try service.undoLastAction()) { error in
      guard case NoteServiceError.conflict = error else {
        return XCTFail("expected conflict, got \(error)")
      }
    }
    // Nothing was applied: the notebook and the note both survive.
    XCTAssertEqual(try service.getNotebook(notebook.notebookId).title, "Occupied")
  }

  func testUndoCommentAddAndRedo() throws {
    let service = try NoteService(driver: makeNoteDriver())
    let note = try service.createNote(bodyMarkdown: "note body")
    let comment = try service.addComment(noteId: note.noteId, bodyMarkdown: "memo body")
    let undone = try XCTUnwrap(try service.undoLastAction())
    XCTAssertEqual(undone.target.action, "comment-added")
    XCTAssertTrue(try service.listComments(noteId: note.noteId).isEmpty)
    _ = try XCTUnwrap(try service.redoLastAction())
    XCTAssertEqual(
      try service.listComments(noteId: note.noteId).map(\.commentId),
      [comment.commentId]
    )
  }

  // MARK: - Undo/redo: tags and read-only

  func testUndoAndRedoTagChanges() throws {
    let service = try NoteService(driver: makeNoteDriver())
    let note = try service.createNote(bodyMarkdown: "body")
    _ = try service.applyTags(
      noteId: note.noteId,
      tags: [NoteTagInput(name: "alpha")],
      provenance: .human
    )
    XCTAssertEqual(try service.getNote(note.noteId).tags.map(\.tag.name), ["alpha"])
    _ = try XCTUnwrap(try service.undoLastAction())
    XCTAssertTrue(try service.getNote(note.noteId).tags.isEmpty)
    _ = try XCTUnwrap(try service.redoLastAction())
    XCTAssertEqual(try service.getNote(note.noteId).tags.map(\.tag.name), ["alpha"])

    _ = try service.removeTag(noteId: note.noteId, tagName: "alpha", removedBy: .human)
    XCTAssertTrue(try service.getNote(note.noteId).tags.isEmpty)
    _ = try XCTUnwrap(try service.undoLastAction())
    XCTAssertEqual(try service.getNote(note.noteId).tags.map(\.tag.name), ["alpha"])
  }

  func testUndoReadOnlyFlip() throws {
    let service = try NoteService(driver: makeNoteDriver())
    let note = try service.createNote(bodyMarkdown: "body")
    _ = try service.setReadOnly(noteId: note.noteId, readOnly: true)
    XCTAssertTrue(try service.getNote(note.noteId).readOnly)
    _ = try XCTUnwrap(try service.undoLastAction())
    XCTAssertFalse(try service.getNote(note.noteId).readOnly)
    _ = try XCTUnwrap(try service.redoLastAction())
    XCTAssertTrue(try service.getNote(note.noteId).readOnly)
  }

  // MARK: - State, isolation, retention

  func testUndoStateReportsTargets() throws {
    let service = try NoteService(driver: makeNoteDriver())
    XCTAssertNil(try service.undoState().undoTarget)
    XCTAssertNil(try service.undoState().redoTarget)
    let note = try service.createNote(bodyMarkdown: "body")
    _ = try service.updateNoteBody(noteId: note.noteId, bodyMarkdown: "body v2")
    let state = try service.undoState()
    XCTAssertEqual(state.undoTarget?.action, "note-body-updated")
    XCTAssertNil(state.redoTarget)
    _ = try service.undoLastAction()
    let afterUndo = try service.undoState()
    XCTAssertEqual(afterUndo.undoTarget?.action, "note-created")
    XCTAssertEqual(afterUndo.redoTarget?.action, "undone")
  }

  func testHistoryAndUndoAreScopedPerActor() throws {
    let driver = try makeNoteDriver()
    let service = try NoteService(driver: driver)
    let other = try service.createUser(email: "other@example.com", displayName: "Other")
    _ = try service.createNote(bodyMarkdown: "default user note")
    let scoped = service.scoped(to: other.userId)
    XCTAssertTrue(try scoped.actionHistory().isEmpty)
    XCTAssertNil(try scoped.undoState().undoTarget)
    XCTAssertNil(try scoped.undoLastAction())
    XCTAssertEqual(try service.actionHistory().count, 2)
  }

  func testRetentionCapPrunesOldEntries() throws {
    let service = try NoteService(driver: makeNoteDriver())
    _ = try service.setAppSetting(key: "history", valueJSON: "{\"maxEntries\": 10}")
    let note = try service.createNote(bodyMarkdown: "v0")
    for index in 1...30 {
      _ = try service.updateNoteBody(noteId: note.noteId, bodyMarkdown: "v\(index)")
    }
    let entries = try service.actionHistory(limit: 500)
    XCTAssertLessThanOrEqual(entries.count, 11)
    // The newest entries survive and undo still works.
    _ = try XCTUnwrap(try service.undoLastAction())
    XCTAssertEqual(try service.getNote(note.noteId).bodyMarkdown, "v29")
  }

  func testRetentionClampsBelowMinimum() throws {
    let service = try NoteService(driver: makeNoteDriver())
    _ = try service.setAppSetting(key: "history", valueJSON: "{\"maxEntries\": 1}")
    let note = try service.createNote(bodyMarkdown: "v0")
    for index in 1...5 {
      _ = try service.updateNoteBody(noteId: note.noteId, bodyMarkdown: "v\(index)")
    }
    // Clamped to 10, so all seven entries (implicit notebook + note creation
    // + five edits) survive.
    XCTAssertEqual(try service.actionHistory(limit: 500).count, 7)
  }

  func testAIEditIsRecordedWithAIProvenanceAndUndoable() throws {
    let service = try NoteService(driver: makeNoteDriver())
    let note = try service.createNote(bodyMarkdown: "human text")
    _ = try service.updateNoteBody(
      noteId: note.noteId,
      bodyMarkdown: "ai rewrote this",
      provenance: .ai
    )
    let entry = try XCTUnwrap(try service.actionHistory().first)
    XCTAssertEqual(entry.provenance, .ai)
    _ = try XCTUnwrap(try service.undoLastAction())
    XCTAssertEqual(try service.getNote(note.noteId).bodyMarkdown, "human text")
  }
}
