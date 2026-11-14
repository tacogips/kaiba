import Foundation

public enum NoteServiceError: Error, Equatable, Sendable {
  case notFound(String)
  case readOnly(String)
  case protectedTag(String)
  case invalidInput(String)
  case invalidRow(String)
}

public struct NoteService: Sendable {
  static let maximumNotebookTagFilterGroups = 64
  static let maximumNotebookTagFilterNames = 256
  static let maximumExpandedNotebookTagFilterNames = 900

  public var driver: NoteDatabaseDriving
  public var autoActionDispatcher: AutoActionDispatching?
  public var autoActionDiagnosticRecorder: (any NoteAutoActionFilterDiagnosticRecording)?
  /// Internal test seam for staged agent-chat attachment rollback. Production
  /// always uses the local store, and persisted reads remain unchanged.
  var chatAttachmentFileStore: (any NoteFileStore)?
  /// Window after which a live in-flight dispatch lease is treated as stale by
  /// the recovery path. A running attempt heartbeats its lease on a fraction of
  /// this window so a long workflow is never reclaimed out from under it.
  public var autoActionDispatchLeaseStaleness: TimeInterval
  /// Notified after each committed mutation visible to live clients. Nil
  /// disables the change feed entirely.
  public var changeObserver: (any NoteChangeObserving)?
  /// Shared registry of background dispatch tasks fired by this service value,
  /// awaited by `drainAutoActionDispatches()`.
  let autoActionDispatchTasks: AutoActionDispatchTaskTracker
  /// The account this service value acts as: new notebooks take it as owner and
  /// notebook reads are filtered to it. Nil is the unscoped view the CLI and
  /// internal bootstrap paths use. Set with `scoped(to:)`.
  public internal(set) var actingUserId: UserID?
  /// The library this service value acts in: new notebooks land in it and
  /// notebook reads are filtered to it. Nil selects the default library for
  /// writes and leaves reads spanning every library the caller may see
  /// (`design-docs/specs/library.md`). Set with `scoped(toLibrary:)`.
  public internal(set) var actingLibraryId: LibraryID?
  /// True when the caller presented no credential at all — an
  /// `--allow-unauthenticated` note-API request, which still acts as the
  /// default user. Such a caller sees only the libraries that do not require
  /// authentication. The local CLI is not one of these: an operator with the
  /// store file already has every library (`design-docs/specs/library.md`).
  public internal(set) var isUnauthenticatedPrincipal: Bool

  public init(
    driver: NoteDatabaseDriving,
    autoActionDispatcher: AutoActionDispatching? = nil,
    autoActionDiagnosticRecorder: (any NoteAutoActionFilterDiagnosticRecording)? = nil,
    autoActionDispatchLeaseStaleness: TimeInterval = defaultAutoActionDispatchLeaseStaleness,
    changeObserver: (any NoteChangeObserving)? = nil
  ) throws {
    self.driver = driver
    self.autoActionDispatcher = autoActionDispatcher
    self.autoActionDiagnosticRecorder = autoActionDiagnosticRecorder
    self.chatAttachmentFileStore = nil
    self.autoActionDispatchLeaseStaleness = autoActionDispatchLeaseStaleness
    self.changeObserver = changeObserver
    self.autoActionDispatchTasks = AutoActionDispatchTaskTracker()
    self.actingUserId = nil
    self.actingLibraryId = nil
    self.isUnauthenticatedPrincipal = false
    try NoteStoreSchema.prepare(on: driver)
    try bootstrapLongTermMemoryNotebook()
    // Recovery+retry is no longer run from init; it is an explicit entry point
    // (`recoverAndRetryAutoActionDispatches`) invoked by `kaiba serve` at
    // startup and from its periodic maintenance tick.
  }

  @discardableResult
  public func createNotebook(
    title: String,
    kindTagName: String? = nil,
    folderPath: [String] = [],
    metaJSON: String? = nil,
    originatingActionId: AutoActionID? = nil
  ) throws -> Notebook {
    let result = try driver.withDatabase { database in
      try database.transaction { db in
        try insertNotebook(
          title: title,
          kindTagName: kindTagName,
          folderPath: folderPath,
          metaJSON: metaJSON,
          originatingActionId: originatingActionId,
          in: db
        )
      }
    }
    dispatchQueuedAutoActions(result.dispatches)
    publishChange(NoteChangeEvent(
      kind: NoteChangeEventKind.notebookCreated,
      notebookId: result.notebook.notebookId,
      tagNames: folderTagNames(of: result.notebook)
    ))
    return result.notebook
  }

  /// Creates the notebook record, its optional system tags, and queued
  /// notebook-created actions on an already-open transaction. Callers publish
  /// the change and dispatch the returned actions only after that transaction
  /// commits.
  func insertNotebook(
    title: String,
    kindTagName: String?,
    folderPath: [String] = [],
    metaJSON: String?,
    originatingActionId: AutoActionID?,
    in db: SQLiteDatabase
  ) throws -> (notebook: Notebook, dispatches: [QueuedAutoActionDispatch]) {
    let now = NoteStoreClock.system.now()
    let notebookId = NotebookID.generate()
    try db.execute(
      """
      INSERT INTO notebooks (
        notebook_id, title, owner_user_id, library_id, created_by, updated_by,
        created_at, updated_at, meta_json
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, jsonb(?))
      """,
      bindings: [
        .id(notebookId), .text(title), .id(writeOwnerUserId()),
        .id(writeLibraryId()),
        .id(writeOwnerUserId()), .id(writeOwnerUserId()),
        .text(now), .text(now), .optionalText(metaJSON)
      ]
    )
    if let kindTagName {
      let kindTag = try ensureNotebookKindTag(kindTagName, in: db)
      try applyNotebookTag(
        notebookId: notebookId, tagId: kindTag.tagId, provenance: .system,
        assignedBy: "kaiba-note", deletable: false, in: db
      )
    }
    if let leaf = try defineNotebookFolderPath(folderPath, in: db) {
      try applyNotebookTag(
        notebookId: notebookId, tagId: leaf.tagId, provenance: .system,
        assignedBy: "kaiba-note", deletable: false, in: db
      )
    }
    let notebook = try requireNotebook(notebookId, in: db)
    let dispatches = try enqueueAutoActions(
      for: NoteAutoActionEvent(
        trigger: .notebookCreated,
        notebookId: notebook.notebookId,
        originatingActionId: originatingActionId
      ),
      in: db
    )
    return (notebook, dispatches)
  }

  /// Creates or reuses a hierarchy of `folder` tags without silently changing
  /// an existing tag's class or parent. Every component is resolved only among
  /// folder siblings under the current parent.
  private func defineNotebookFolderPath(_ rawPath: [String], in db: SQLiteDatabase) throws -> Tag? {
    let path = rawPath.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    guard path.allSatisfy({ component in
      !component.isEmpty
        && component != "."
        && component != ".."
        && !component.contains("/")
        && !component.contains("\\")
        && !component.contains("\0")
    }) else {
      throw NoteServiceError.invalidInput("folder path components must be non-empty safe names")
    }
    var parent: Tag?
    for name in path {
      if let existing = try findFolderTag(name: name, parentTagId: parent?.tagId, in: db) {
        parent = existing
        continue
      }
      _ = try requireTagClass(classId: .folder, in: db)
      let tagId = TagID.generate()
      if let parent { try validateTagParent(childTagId: tagId, parentTagId: parent.tagId, in: db) }
      do {
        try db.execute(
          "INSERT INTO tags (tag_id, name, class_id, parent_tag_id, is_system, created_at) VALUES (?, ?, 'folder', ?, 0, ?)",
          bindings: [.id(tagId), .text(name), .optionalID(parent?.tagId), .text(NoteStoreClock.system.now())]
        )
        parent = try requireTag(id: tagId, in: db)
      } catch let error as SQLiteError where isSQLiteUniqueConstraintViolation(error) {
        guard let raced = try findFolderTag(name: name, parentTagId: parent?.tagId, in: db) else {
          throw error
        }
        parent = raced
      }
    }
    return parent
  }

  @discardableResult
  public func createNote(
    notebookId requestedNotebookId: NotebookID? = nil,
    notebookTitle: String? = nil,
    notebookKindTagName: String? = nil,
    title: String? = nil,
    bodyMarkdown: String,
    readOnly: Bool = false,
    tags: [NoteTagInput] = [],
    provenance: NoteProvenance = .human,
    assignedBy: String? = nil,
    metaJSON: String? = nil,
    originatingActionId: AutoActionID? = nil
  ) throws -> Note {
    let result = try driver.withDatabase { database in
      try database.transaction { db in
        let now = NoteStoreClock.system.now()
        let notebookId: NotebookID
        let createdNotebookId: NotebookID?
        if let requestedNotebookId {
          let notebook = try requireNotebook(requestedNotebookId, in: db)
          guard !notebook.readOnly else {
            throw NoteServiceError.readOnly(requestedNotebookId.rawValue)
          }
          notebookId = requestedNotebookId
          createdNotebookId = nil
        } else {
          let derivedTitle = title ?? noteTitle(from: bodyMarkdown) ?? notebookTitle ?? "Untitled"
          notebookId = NotebookID.generate()
          createdNotebookId = notebookId
          try db.execute(
            """
            INSERT INTO notebooks (
              notebook_id, title, owner_user_id, library_id, created_by, updated_by,
              created_at, updated_at, meta_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL)
            """,
            bindings: [
              .id(notebookId), .text(derivedTitle), .id(writeOwnerUserId()),
              .id(writeLibraryId()),
              .id(writeOwnerUserId()), .id(writeOwnerUserId()),
              .text(now), .text(now)
            ]
          )
          if let notebookKindTagName {
            let kindTag = try ensureNotebookKindTag(notebookKindTagName, in: db)
            try applyNotebookTag(
              notebookId: notebookId,
              tagId: kindTag.tagId,
              provenance: .system,
              assignedBy: "kaiba-note",
              deletable: false,
              in: db
            )
          }
        }

        let noteNumber = try nextNoteNumber(notebookId: notebookId, in: db)
        let noteId = NoteID.generate()
        let noteTitle = title ?? noteTitle(from: bodyMarkdown)
        let titleSource: NoteTitleSource = title == nil ? .derived : .explicit
        try db.execute(
          """
          INSERT INTO notes (
            note_id, notebook_id, note_number, title, title_source, body_markdown,
            read_only, created_by, updated_by, created_at, updated_at, meta_json
          ) VALUES (
            ?, ?, ?, ?, ?, ?, ?,
            (SELECT owner_user_id FROM notebooks WHERE notebook_id = ?),
            (SELECT owner_user_id FROM notebooks WHERE notebook_id = ?),
            ?, ?, jsonb(?)
          )
          """,
          bindings: [
            .id(noteId),
            .id(notebookId),
            .int(Int64(noteNumber)),
            .optionalText(noteTitle),
            .text(titleSource.rawValue),
            .text(bodyMarkdown),
            .int(readOnly ? 1 : 0),
            .id(notebookId),
            .id(notebookId),
            .text(now),
            .text(now),
            .optionalText(metaJSON)
          ]
        )
        try db.execute(
          "UPDATE notebooks SET updated_at = ?, updated_by = owner_user_id WHERE notebook_id = ?",
          bindings: [.text(now), .id(notebookId)]
        )
        for tag in tags {
          try applyTag(
            noteId: noteId,
            tag: tag,
            provenance: provenance,
            assignedBy: assignedBy,
            deletable: true,
            in: db
          )
        }
        try refreshFTS(noteId: noteId, previous: nil, in: db)
        let note = try requireNote(noteId, in: db)
        var dispatches: [QueuedAutoActionDispatch] = []
        if let createdNotebookId {
          dispatches.append(contentsOf: try enqueueAutoActions(
            for: NoteAutoActionEvent(
              trigger: .notebookCreated,
              notebookId: createdNotebookId,
              originatingActionId: originatingActionId
            ),
            in: db
          ))
        }
        dispatches.append(contentsOf: try enqueueAutoActions(
          for: NoteAutoActionEvent(
            trigger: .noteCreated,
            notebookId: note.notebookId,
            noteId: note.noteId,
            noteBodyMarkdown: note.bodyMarkdown,
            originatingActionId: originatingActionId
          ),
          in: db
        ))
        return (note: note, dispatches: dispatches, createdNotebookId: createdNotebookId)
      }
    }
    dispatchQueuedAutoActions(result.dispatches)
    if let createdNotebookId = result.createdNotebookId {
      publishChange(NoteChangeEvent(
        kind: NoteChangeEventKind.notebookCreated,
        notebookId: createdNotebookId
      ))
    } else {
      publishChange(NoteChangeEvent(
        kind: NoteChangeEventKind.noteCreated,
        notebookId: result.note.notebookId
      ))
    }
    return result.note
  }

  @discardableResult
  public func createNotebookWithNotes(
    title: String,
    kindTagName: String? = nil,
    metaJSON: String? = nil,
    pages: [NotePageDraft],
    notebookReadOnly: Bool = false,
    provenance: NoteProvenance = .system,
    assignedBy: String? = "kaiba-note-ingest",
    originatingActionId: AutoActionID? = nil
  ) throws -> NotebookIngestResult {
    guard !pages.isEmpty else {
      throw NoteServiceError.invalidInput("notebook ingest pages must not be empty")
    }
    try validateNotebookIngestPageNumbers(pages)
    let result = try driver.withDatabase { database in
      try database.transaction { db in
        try insertNotebookWithNotes(
          title: title,
          kindTagName: kindTagName,
          metaJSON: metaJSON,
          pages: pages,
          notebookReadOnly: notebookReadOnly,
          provenance: provenance,
          assignedBy: assignedBy,
          originatingActionId: originatingActionId,
          in: db
        )
      }
    }
    dispatchQueuedAutoActions(result.dispatches)
    publishChange(NoteChangeEvent(
      kind: NoteChangeEventKind.notebookCreated,
      notebookId: result.ingestResult.notebook.notebookId,
      tagNames: folderTagNames(of: result.ingestResult.notebook)
    ))
    return result.ingestResult
  }

  /// Inserts a notebook plus its notes against an already-open transaction `db`.
  ///
  /// This is the shared body extracted from `createNotebookWithNotes` (byte-for-byte
  /// behavior preserved). Callers that need to compose the notebook/note inserts with
  /// additional writes in the *same* transaction (e.g. `promoteCommentToNotebook`
  /// inlining a `note_links` INSERT) call this helper directly and dispatch the returned
  /// auto-actions after the transaction commits. Never open a nested transaction here.
  private func insertNotebookWithNotes(
    title: String,
    kindTagName: String?,
    metaJSON: String?,
    pages: [NotePageDraft],
    notebookReadOnly: Bool,
    provenance: NoteProvenance,
    assignedBy: String?,
    originatingActionId: AutoActionID?,
    in db: SQLiteDatabase
  ) throws -> (ingestResult: NotebookIngestResult, dispatches: [QueuedAutoActionDispatch]) {
    let now = NoteStoreClock.system.now()
    let notebookId = NotebookID.generate()
    try db.execute(
      """
      INSERT INTO notebooks (
        notebook_id, title, read_only, owner_user_id, library_id, created_by, updated_by,
        created_at, updated_at, meta_json
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, jsonb(?))
      """,
      bindings: [
        .id(notebookId),
        .text(title),
        .int(notebookReadOnly ? 1 : 0),
        .id(writeOwnerUserId()),
        .id(writeLibraryId()),
        .id(writeOwnerUserId()),
        .id(writeOwnerUserId()),
        .text(now),
        .text(now),
        .optionalText(metaJSON)
      ]
    )
    if let kindTagName {
      let kindTag = try ensureNotebookKindTag(kindTagName, in: db)
      try applyNotebookTag(
        notebookId: notebookId,
        tagId: kindTag.tagId,
        provenance: .system,
        assignedBy: "kaiba-note",
        deletable: false,
        in: db
      )
    }

    var notes: [Note] = []
    for (index, page) in pages.enumerated() {
      let noteNumber = page.noteNumber ?? index + 1
      let noteId = NoteID.generate()
      let noteTitle = noteTitle(from: page.bodyMarkdown)
      try db.execute(
        """
        INSERT INTO notes (
          note_id, notebook_id, note_number, title, title_source, body_markdown,
          read_only, created_by, updated_by, created_at, updated_at, meta_json
        ) VALUES (
          ?, ?, ?, ?, 'derived', ?, ?,
          (SELECT owner_user_id FROM notebooks WHERE notebook_id = ?),
          (SELECT owner_user_id FROM notebooks WHERE notebook_id = ?),
          ?, ?, jsonb(?)
        )
        """,
        bindings: [
          .id(noteId),
          .id(notebookId),
          .int(Int64(noteNumber)),
          .optionalText(noteTitle),
          .text(page.bodyMarkdown),
          .int(page.readOnly ? 1 : 0),
          .id(notebookId),
          .id(notebookId),
          .text(now),
          .text(now),
          .optionalText(page.metaJSON)
        ]
      )
      for tag in page.tags {
        try applyTag(
          noteId: noteId,
          tag: tag,
          provenance: provenance,
          assignedBy: assignedBy,
          deletable: true,
          in: db
        )
      }
      try refreshFTS(noteId: noteId, previous: nil, in: db)
      notes.append(try requireNote(noteId, in: db))
    }
    let ingestResult = NotebookIngestResult(notebook: try requireNotebook(notebookId, in: db), notes: notes)
    var dispatches = try enqueueAutoActions(
      for: NoteAutoActionEvent(
        trigger: .notebookCreated,
        notebookId: ingestResult.notebook.notebookId,
        originatingActionId: originatingActionId
      ),
      in: db
    )
    for note in ingestResult.notes {
      dispatches.append(contentsOf: try enqueueAutoActions(
        for: NoteAutoActionEvent(
          trigger: .noteCreated,
          notebookId: ingestResult.notebook.notebookId,
          noteId: note.noteId,
          noteBodyMarkdown: note.bodyMarkdown,
          originatingActionId: originatingActionId
        ),
        in: db
      ))
    }
    return (ingestResult: ingestResult, dispatches: dispatches)
  }

  /// Promotes a note comment into a freshly created notebook whose first note carries the
  /// comment body, linking the source note to that new note — all in ONE transaction.
  ///
  /// The notebook/note inserts reuse `insertNotebookWithNotes(…, in: db)` and the
  /// `note_links` row is inlined (copied from `linkNotes`) against the same `db`, so a
  /// partial failure rolls the whole promotion back (SR-001). The two self-transacting
  /// public methods (`createNotebookWithNotes`, `linkNotes`) are intentionally NOT composed.
  @discardableResult
  public func promoteCommentToNotebook(
    noteId: NoteID,
    commentId: CommentID,
    notebookTitle: String? = nil,
    linkKind: String = "related",
    provenance: NoteProvenance = .human,
    assignedBy: String? = "kaiba-note-ui"
  ) throws -> (notebook: Notebook, note: Note) {
    let result = try driver.withDatabase { database in
      try database.transaction { db -> (notebook: Notebook, note: Note, dispatches: [QueuedAutoActionDispatch]) in
        _ = try requireNote(noteId, in: db)
        let commentRows = try db.query(
          """
          SELECT body_markdown
          FROM note_comments
          WHERE comment_id = ? AND note_id = ?
          LIMIT 1
          """,
          bindings: [.id(commentId), .id(noteId)]
        )
        guard let commentRow = commentRows.first,
              let commentBody = commentRow["body_markdown"] else {
          throw NoteServiceError.invalidInput("comment \(commentId) does not belong to note \(noteId)")
        }
        let resolvedTitle = promoteCommentNotebookTitle(explicit: notebookTitle, commentBody: commentBody)
        let inserted = try insertNotebookWithNotes(
          title: resolvedTitle,
          kindTagName: nil,
          metaJSON: nil,
          pages: [NotePageDraft(bodyMarkdown: commentBody, readOnly: false)],
          notebookReadOnly: false,
          provenance: provenance,
          assignedBy: assignedBy,
          originatingActionId: nil,
          in: db
        )
        guard let newNote = inserted.ingestResult.notes.first else {
          throw NoteServiceError.invalidInput("promote produced no note for comment \(commentId)")
        }
        // Inlined from `linkNotes` (NoteService+Relations.swift) so the link is written in
        // the SAME transaction as the notebook/note inserts. Keep the ON CONFLICT upsert
        // guards verbatim.
        let now = NoteStoreClock.system.now()
        try db.execute(
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
            .id(noteId),
            .id(newNote.noteId),
            .text(linkKind),
            .text(provenance.rawValue),
            .text(now)
          ]
        )
        return (
          notebook: inserted.ingestResult.notebook,
          note: newNote,
          dispatches: inserted.dispatches
        )
      }
    }
    dispatchQueuedAutoActions(result.dispatches)
    return (notebook: result.notebook, note: result.note)
  }

  public func getNotebook(_ notebookId: NotebookID) throws -> Notebook {
    try driver.withDatabase { database in
      try requireNotebook(notebookId, in: database)
    }
  }

  public func getNote(_ noteId: NoteID) throws -> Note {
    try driver.withDatabase { database in
      try requireNote(noteId, in: database)
    }
  }

  public func listNotes(notebookId: NotebookID, limit: Int = 100, offset: Int = 0) throws -> [Note] {
    try driver.withDatabase { database in
      _ = try requireNotebook(notebookId, in: database)
      let rows = try database.query(
        """
        SELECT note_id, notebook_id, note_number, title, body_markdown, read_only,
          created_at, updated_at,
          CASE WHEN meta_json IS NULL THEN NULL ELSE json(meta_json) END AS meta_json
        FROM notes
        WHERE notebook_id = ?
        ORDER BY note_number, note_id
        LIMIT ? OFFSET ?
        """,
        bindings: [.id(notebookId), .int(Int64(limit)), .int(Int64(offset))]
      )
      return try notes(from: rows, in: database)
    }
  }

  public func listNotes(
    limit: Int = 100,
    offset: Int = 0,
    notebookId: NotebookID? = nil,
    tagFilter: [String] = []
  ) throws -> [Note] {
    try driver.withDatabase { database in
      let expandedTagFilterIds = try expandedLegacyTagFilterIds(tagFilter, in: database)
      guard tagFilter.isEmpty || !expandedTagFilterIds.isEmpty else {
        return []
      }
      var predicates: [String] = []
      var bindings: [SQLiteValue] = []
      // The cross-notebook feed spans libraries, so it carries the same scope
      // the catalog does (`design-docs/specs/library.md`).
      appendLibraryScopePredicate(
        alias: "notes",
        reachableLibraryIds: try reachableLibraryIds(in: database),
        predicates: &predicates,
        bindings: &bindings
      )
      if let notebookId {
        _ = try requireNotebook(notebookId, in: database)
        predicates.append("notebook_id = ?")
        bindings.append(.id(notebookId))
      }
      if !expandedTagFilterIds.isEmpty {
        predicates.append(
          """
          EXISTS (
            SELECT 1
            FROM note_tags nt
            WHERE nt.note_id = notes.note_id
              AND nt.tag_id IN (\(placeholders(count: expandedTagFilterIds.count)))
          )
          """
        )
        bindings.append(contentsOf: expandedTagFilterIds.sqliteBindings)
      }
      let whereClause = predicates.isEmpty ? "" : "WHERE \(predicates.joined(separator: " AND "))"
      // A notebook-scoped listing returns the notebook's pages in their intrinsic
      // order (note_number); `created_at DESC` is reserved for the cross-notebook
      // feed, where recency is the only meaningful ordering.
      let orderClause = notebookId == nil ? "created_at DESC, note_id" : "note_number, note_id"
      bindings.append(.int(Int64(limit)))
      bindings.append(.int(Int64(offset)))
      let rows = try database.query(
        """
        SELECT note_id, notebook_id, note_number, title, body_markdown, read_only,
          created_at, updated_at,
          CASE WHEN meta_json IS NULL THEN NULL ELSE json(meta_json) END AS meta_json
        FROM notes
        \(whereClause)
        ORDER BY \(orderClause)
        LIMIT ? OFFSET ?
        """,
        bindings: bindings
      )
      return try notes(from: rows, in: database)
    }
  }

  @discardableResult
  public func updateNoteBody(
    noteId: NoteID,
    bodyMarkdown: String,
    originatingActionId: AutoActionID? = nil
  ) throws -> Note {
    let result = try driver.withDatabase { database in
      try database.transaction { db in
        let existing = try requireWritableNote(noteId, in: db)
        let previous = try ftsPayload(noteId: noteId, in: db)
        let now = NoteStoreClock.system.now()
        // Explicit titles (set via the `title` argument on create) are preserved
        // across body edits; only derived titles are re-derived from the new body.
        let titleSource = try noteTitleSource(noteId: noteId, in: db)
        let updatedTitle = titleSource == .explicit
          ? existing.title
          : (noteTitle(from: bodyMarkdown) ?? existing.title)
        try db.execute(
          """
          UPDATE notes
          SET title = ?, body_markdown = ?, updated_at = ?,
            updated_by = (SELECT owner_user_id FROM notebooks WHERE notebook_id = notes.notebook_id)
          WHERE note_id = ?
          """,
          bindings: [
            .optionalText(updatedTitle),
            .text(bodyMarkdown),
            .text(now),
            .id(noteId)
          ]
        )
        try db.execute(
          "UPDATE notebooks SET updated_at = ?, updated_by = owner_user_id WHERE notebook_id = ?",
          bindings: [.text(now), .id(existing.notebookId)]
        )
        try refreshFTS(noteId: noteId, previous: previous, in: db)
        let note = try requireNote(noteId, in: db)
        let dispatches = try enqueueAutoActions(
          for: NoteAutoActionEvent(
            trigger: .noteUpdated,
            notebookId: note.notebookId,
            noteId: note.noteId,
            noteBodyMarkdown: note.bodyMarkdown,
            originatingActionId: originatingActionId
          ),
          in: db
        )
        return (note: note, dispatches: dispatches)
      }
    }
    dispatchQueuedAutoActions(result.dispatches)
    publishChange(NoteChangeEvent(
      kind: NoteChangeEventKind.noteUpdated,
      notebookId: result.note.notebookId
    ))
    return result.note
  }

  @discardableResult
  public func applyTags(
    noteId: NoteID,
    tags: [NoteTagInput],
    provenance: NoteProvenance,
    assignedBy: String? = nil
  ) throws -> Note {
    let note = try driver.withDatabase { database in
      try database.transaction { db in
        _ = try requireNote(noteId, in: db)
        let previous = try ftsPayload(noteId: noteId, in: db)
        for tag in tags {
          try applyTag(
            noteId: noteId,
            tag: tag,
            provenance: provenance,
            assignedBy: assignedBy,
            deletable: true,
            in: db
          )
        }
        try refreshFTS(noteId: noteId, previous: previous, in: db)
        return try requireNote(noteId, in: db)
      }
    }
    // Tag assignments drive inline tag underlining, the tag detail pane, and
    // the tag catalog, so other clients need waking just like notebook tags.
    publishChange(NoteChangeEvent(
      kind: NoteChangeEventKind.noteTags,
      notebookId: note.notebookId
    ))
    return note
  }

  @discardableResult
  public func removeTag(noteId: NoteID, tagName: String, removedBy provenance: NoteProvenance) throws -> Note {
    let result = try driver.withDatabase { database in
      try database.transaction { db -> (note: Note, removed: Bool) in
        let existing = try tagAssignment(noteId: noteId, tagName: tagName, in: db)
        guard let existing else {
          return (try requireNote(noteId, in: db), false)
        }
        guard existing.deletable else {
          throw NoteServiceError.protectedTag(tagName)
        }
        if provenance == .ai, existing.provenance == .human {
          throw NoteServiceError.protectedTag(tagName)
        }
        let previous = try ftsPayload(noteId: noteId, in: db)
        try db.execute(
          """
          DELETE FROM note_tags
          WHERE note_id = ? AND tag_id = ?
          """,
          bindings: [.id(noteId), .id(existing.tag.tagId)]
        )
        try refreshFTS(noteId: noteId, previous: previous, in: db)
        return (try requireNote(noteId, in: db), true)
      }
    }
    if result.removed {
      publishChange(NoteChangeEvent(
        kind: NoteChangeEventKind.noteTags,
        notebookId: result.note.notebookId
      ))
    }
    return result.note
  }

}

/// Resolves the title for a comment-promoted notebook: an explicit non-empty title wins,
/// otherwise the shared note-title heuristic on the comment body, falling back to
/// "Comment notebook". The result is capped at 120 characters.
func promoteCommentNotebookTitle(explicit: String?, commentBody: String) -> String {
  let trimmedExplicit = explicit?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  let base = trimmedExplicit.isEmpty
    ? (noteTitle(from: commentBody) ?? "Comment notebook")
    : trimmedExplicit
  return String(base.prefix(120))
}

func applyNotebookTag(
  notebookId: NotebookID,
  tagName: String,
  provenance: NoteProvenance,
  assignedBy: String?,
  deletable: Bool,
  allowsLongTermMemoryIdentityCreation: Bool = false,
  in database: SQLiteDatabase
) throws {
  let tag: Tag
  if let existing = try findTag(name: tagName, in: database) {
    tag = existing
  } else {
    try ensureTag(NoteTagInput(name: tagName), in: database)
    tag = try requireTag(name: tagName, in: database)
  }
  try applyNotebookTag(
    notebookId: notebookId,
    tagId: tag.tagId,
    provenance: provenance,
    assignedBy: assignedBy,
    deletable: deletable,
    allowsLongTermMemoryIdentityCreation: allowsLongTermMemoryIdentityCreation,
    in: database
  )
}

func applyNotebookTag(
  notebookId: NotebookID,
  tagId: TagID,
  provenance: NoteProvenance,
  assignedBy: String?,
  deletable: Bool,
  allowsLongTermMemoryIdentityCreation: Bool = false,
  in database: SQLiteDatabase
) throws {
  let tag = try requireTag(id: tagId, in: database)
  if tag.tagId == NoteStoreSchema.longTermMemoryNotebookKindTagId {
    try validateLongTermMemoryNotebookTagAssignment(
      notebookId: notebookId,
      allowsIdentityCreation: allowsLongTermMemoryIdentityCreation,
      in: database
    )
  }
  let existing = try notebookTagAssignment(notebookId: notebookId, tagId: tagId, in: database)
  if let existing, existing.provenance == .system, provenance != .system {
    return
  }
  try database.execute(
    """
    INSERT INTO notebook_tags (
      notebook_id, tag_id, provenance, assigned_by, deletable, created_at
    ) VALUES (?, ?, ?, ?, ?, ?)
    ON CONFLICT(notebook_id, tag_id) DO UPDATE SET
      provenance = CASE
        WHEN notebook_tags.provenance = 'system' THEN notebook_tags.provenance
        ELSE excluded.provenance
      END,
      assigned_by = CASE
        WHEN notebook_tags.provenance = 'system' THEN notebook_tags.assigned_by
        ELSE excluded.assigned_by
      END,
      deletable = CASE
        WHEN notebook_tags.deletable = 0 THEN 0
        ELSE excluded.deletable
      END
    """,
    bindings: [
      .id(notebookId),
      .id(tag.tagId),
      .text(provenance.rawValue),
      .optionalText(assignedBy),
      .int(deletable ? 1 : 0),
      .text(NoteStoreClock.system.now())
    ]
  )
}

func applyTag(
  noteId: NoteID,
  tag: NoteTagInput,
  provenance: NoteProvenance,
  assignedBy: String?,
  deletable: Bool,
  in database: SQLiteDatabase
) throws {
  try ensureTag(tag, in: database)
  let existing = try tagAssignment(noteId: noteId, tagName: tag.name, in: database)
  if let existing, existing.provenance == .human, provenance == .ai {
    return
  }
  if let existing, existing.provenance == .system, provenance != .system {
    return
  }
  let storedTag = try requireNonFolderTag(name: tag.name, in: database)
  try database.execute(
    """
    INSERT INTO note_tags (
      note_id, tag_id, provenance, assigned_by, deletable, created_at
    ) VALUES (?, ?, ?, ?, ?, ?)
    ON CONFLICT(note_id, tag_id) DO UPDATE SET
      provenance = CASE
        WHEN note_tags.provenance = 'system' THEN note_tags.provenance
        ELSE excluded.provenance
      END,
      assigned_by = CASE
        WHEN note_tags.provenance = 'system' THEN note_tags.assigned_by
        ELSE excluded.assigned_by
      END,
      deletable = CASE
        WHEN note_tags.deletable = 0 THEN 0
        ELSE excluded.deletable
      END
    """,
    bindings: [
      .id(noteId),
      .id(storedTag.tagId),
      .text(provenance.rawValue),
      .optionalText(assignedBy),
      .int(deletable ? 1 : 0),
      .text(NoteStoreClock.system.now())
    ]
  )
}

func ensureTag(_ tag: NoteTagInput, in database: SQLiteDatabase) throws {
  if let classId = tag.classId, !classId.isEmpty {
    _ = try requireTagClass(classId: classId, in: database)
  }
  if let existing = try findNonFolderTag(name: tag.name, in: database) {
    if existing.classId == nil, let classId = tag.classId, !classId.isEmpty {
      try database.execute(
        "UPDATE tags SET class_id = ? WHERE tag_id = ?",
        bindings: [.id(classId), .id(existing.tagId)]
      )
    }
    return
  }
  do {
    try database.execute(
      """
      INSERT INTO tags (tag_id, name, class_id, is_system, created_at)
      VALUES (?, ?, ?, 0, ?)
      """,
      bindings: [
        .id(TagID.generate()),
        .text(tag.name),
        .optionalID(tag.classId),
        .text(NoteStoreClock.system.now())
      ]
    )
  } catch let error as SQLiteError where isSQLiteUniqueConstraintViolation(error) {
    guard try findNonFolderTag(name: tag.name, in: database) != nil else {
      throw error
    }
  }
}

func deleteNoteRows(noteId: NoteID, in database: SQLiteDatabase) throws {
  if let previous = try ftsPayload(noteId: noteId, in: database) {
    try database.execute(
      """
      INSERT INTO note_fts(note_fts, rowid, title, body, tags)
      VALUES('delete', ?, ?, ?, ?)
      """,
      bindings: [.int(previous.rowId), .text(previous.title), .text(previous.body), .text(previous.tags)]
    )
  }
  try database.execute("DELETE FROM note_fts_map WHERE note_id = ?", bindings: [.id(noteId)])
  try database.execute("DELETE FROM note_tags WHERE note_id = ?", bindings: [.id(noteId)])
  try database.execute("DELETE FROM note_files WHERE note_id = ?", bindings: [.id(noteId)])
  try database.execute(
    "DELETE FROM note_links WHERE from_note_id = ? OR to_note_id = ?",
    bindings: [.id(noteId), .id(noteId)]
  )
  try database.execute("DELETE FROM note_comments WHERE note_id = ?", bindings: [.id(noteId)])
  try database.execute("DELETE FROM notes WHERE note_id = ?", bindings: [.id(noteId)])
}
