import Foundation

// Anywhere capture: the write half.
//
// `design-docs/specs/note-capture-and-entity-pages.md` C3 and C4. Every capture
// lands in one accumulating notebook, found by the system kind tag
// `notebook-kind:quick-memo` rather than by title, because titles are
// user-mutable and not unique. "One" is per write principal, not per store
// (C3 delta): each `(owner_user_id, library_id)` pair finds or creates its own
// Quick Memos notebook, which is what lets a second bearer credential capture
// at all. The capture itself is an ordinary `createNote`,
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
  ///
  /// Both the lookup and the invariant are evaluated inside this service
  /// value's write scope (`quickMemoNotebookIds` below): another account's
  /// holder is invisible here, never a multi-holder failure and never a
  /// notebook this caller is then refused.
  @discardableResult
  public func ensureQuickMemoNotebook() throws -> Notebook {
    let result = try driver.withDatabase { database in
      try database.transaction { db -> (notebook: Notebook, created: Bool) in
        try requireEnabledActingUser(in: db)
        let notebookIds = try quickMemoNotebookIds(in: db)
        if notebookIds.count > 1 {
          // Scoped: two holders owned by *this* principal in *this* library.
          // A store defect, reported to the capture route as a 500 (C6 delta),
          // never as a caller error.
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

extension NoteService {
  /// Notebooks carrying the quick-memo kind tag **within this service value's
  /// write scope**, ordered so the invariant check is deterministic.
  ///
  /// C3 delta: the singleton is per write principal, so the lookup joins
  /// `notebooks` and filters on `owner_user_id` and `library_id` bound to
  /// `writeOwnerUserId()` / `writeLibraryId()` — the very identity
  /// `ensureQuickMemoNotebook`'s insert records. Both predicates are required.
  /// Owner alone would still match the same user's holder in a different
  /// library, hand it back, and have `requireNotebook` refuse it for library
  /// reach: the cross-library form of exactly the leak this delta closes.
  ///
  /// Reads `notebook_tags` by `tag_id`, covered by `idx_notebook_tags_tag`,
  /// then joins `notebooks` on its primary key; the scope predicates are a
  /// row lookup per candidate, not a scan.
  func quickMemoNotebookIds(in database: SQLiteDatabase) throws -> [NotebookID] {
    try database.query(
      """
      SELECT notebook_tags.notebook_id AS notebook_id
      FROM notebook_tags
      JOIN notebooks ON notebooks.notebook_id = notebook_tags.notebook_id
      WHERE notebook_tags.tag_id = ?
      AND notebooks.owner_user_id = ?
      AND notebooks.library_id = ?
      ORDER BY notebook_tags.notebook_id
      """,
      bindings: [
        .id(NoteStoreSchema.quickMemoNotebookKindTagId),
        .id(writeOwnerUserId()),
        .id(writeLibraryId())
      ]
    ).compactMap { $0.identifier("notebook_id", as: NotebookID.self) }
  }
}
