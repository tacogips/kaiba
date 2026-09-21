import Foundation

// Anywhere capture: the write half.
//
// `design-docs/specs/note-capture-and-entity-pages.md` C3 and C4. Every capture
// lands in one accumulating notebook, found by the system kind tag
// `notebook-kind:quick-memo` rather than by title, because titles are
// user-mutable and not unique. The capture itself is an ordinary `createNote`,
// so the auto-action outbox and the change feed apply with no capture-specific
// mechanism at all — that is the point of C4, not an implementation shortcut.

extension NoteService {
  public static let quickMemoNotebookTitle = "Quick Memos"

  /// Finds the Quick Memos notebook or creates it, in one transaction.
  ///
  /// Shaped after `bootstrapLongTermMemoryNotebook()`: the kind tag is the
  /// identity, more than one holder is a loud invariant failure rather than a
  /// silent pick, and the created notebook carries the tag as a
  /// `provenance: .system`, `deletable: false` assignment so a client cannot
  /// detach the store's capture target. Deleting the notebook deletes its
  /// `notebook_tags` rows, so the next capture recreates it (C3, find-or-create).
  @discardableResult
  public func ensureQuickMemoNotebook() throws -> Notebook {
    let result = try driver.withDatabase { database in
      try database.transaction { db -> (notebook: Notebook, created: Bool) in
        try requireEnabledActingUser(in: db)
        let notebookIds = try quickMemoNotebookIds(in: db)
        if notebookIds.count > 1 {
          throw NoteServiceError.invalidInput(
            "multiple notebooks carry \(NoteStoreSchema.quickMemoNotebookKindTag)"
          )
        }
        if let notebookId = notebookIds.first {
          return (try requireNotebook(notebookId, in: db), false)
        }

        let notebookId = NotebookID.generate()
        let now = NoteStoreClock.system.now()
        // Unlike the long-term-memory bootstrap this insert names `library_id`:
        // capture runs as a scoped request principal, so the notebook belongs in
        // the caller's library exactly as `createNote`'s own notebook insert
        // places it, not in whatever the DDL default happens to be.
        try db.execute(
          """
          INSERT INTO notebooks (
            notebook_id, title, read_only, owner_user_id, library_id, created_by,
            updated_by, created_at, updated_at, meta_json
          ) VALUES (?, ?, 0, ?, ?, ?, ?, ?, ?, NULL)
          """,
          bindings: [
            .id(notebookId),
            .text(Self.quickMemoNotebookTitle),
            .id(writeOwnerUserId()),
            .id(writeLibraryId()),
            .id(writeOwnerUserId()),
            .id(writeOwnerUserId()),
            .text(now),
            .text(now)
          ]
        )
        try applyNotebookTag(
          notebookId: notebookId,
          tagId: NoteStoreSchema.quickMemoNotebookKindTagId,
          provenance: .system,
          assignedBy: "kaiba-note",
          deletable: false,
          in: db
        )
        return (try requireNotebook(notebookId, in: db), true)
      }
    }
    // Only the run that actually created it announces the notebook. A viewer
    // open on the first capture would otherwise never learn the notebook
    // exists: `createNote` reports `note-created` against an existing notebook
    // id, which says nothing about a notebook the client has not listed yet.
    if result.created {
      publishChange(NoteChangeEvent(
        kind: NoteChangeEventKind.notebookCreated,
        notebookId: result.notebook.notebookId
      ))
    }
    return result.notebook
  }

  /// Writes one captured thought into the Quick Memos notebook.
  ///
  /// Deliberately a thin composition (C4): resolve the notebook, then hand the
  /// body to the ordinary `createNote`. Auto-action enqueue plus dispatch and
  /// the `note-created` change event are `createNote`'s, unmodified, which is
  /// how a captured note gets auto-tagged and how an open viewer refreshes.
  @discardableResult
  public func captureQuickMemo(bodyMarkdown: String, title: String? = nil) throws -> Note {
    guard !bodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw NoteServiceError.invalidInput("quick memo body must not be empty")
    }
    // A blank title is not a title: collapse it so `createNote` derives one from
    // the body and records `titleSource = .derived`, instead of persisting an
    // explicit empty heading.
    let explicitTitle = title.flatMap { candidate -> String? in
      let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    let notebook = try ensureQuickMemoNotebook()
    return try createNote(
      notebookId: notebook.notebookId,
      title: explicitTitle,
      bodyMarkdown: bodyMarkdown
    )
  }
}

/// Notebooks carrying the quick-memo kind tag, newest-agnostic and ordered so
/// the invariant check is deterministic. Reads `notebook_tags` by `tag_id`,
/// which `idx_notebook_tags_tag` covers.
func quickMemoNotebookIds(in database: SQLiteDatabase) throws -> [NotebookID] {
  try database.query(
    """
    SELECT notebook_id
    FROM notebook_tags
    WHERE tag_id = ?
    ORDER BY notebook_id
    """,
    bindings: [.id(NoteStoreSchema.quickMemoNotebookKindTagId)]
  ).compactMap { $0.identifier("notebook_id", as: NotebookID.self) }
}
