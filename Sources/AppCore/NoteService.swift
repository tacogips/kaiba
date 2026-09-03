import Foundation

public enum NoteServiceError: Error, Equatable, Sendable {
  case notFound(String)
  /// A scoped principal was disabled after work had already been queued. The
  /// dispatcher treats this as a terminal safety cancellation rather than a
  /// retryable provider failure.
  case accountUnavailable(String)
  case readOnly(String)
  case protectedTag(String)
  case invalidInput(String)
  case invalidRow(String)
  /// An undo/redo target no longer matches the store — the entity changed,
  /// moved, or vanished since the entry was recorded
  /// (`design-docs/specs/action-history-undo.md`, U6).
  case conflict(String)
}

public struct NoteService: Sendable {
  static let maximumNotebookTagFilterGroups = 64
  static let maximumNotebookTagFilterNames = 256
  static let maximumExpandedNotebookTagFilterNames = 900

  public var driver: NoteDatabaseDriving
  public var autoActionDispatcher: AutoActionDispatching?
  public var autoActionDiagnosticRecorder: (any NoteAutoActionFilterDiagnosticRecording)?
  /// Shared by service copies and request adapters to bound all externally
  /// executing agent work for this store.
  public var agentExecutionAdmission: AgentExecutionAdmission
  /// Internal test seam for staged agent-chat attachment rollback. Production
  /// always uses the local store, and persisted reads remain unchanged.
  var chatAttachmentFileStore: (any NoteFileStore)?
  /// Internal test seam that simulates a subject mutation at the pre-insert
  /// boundary of agent-conversation creation. Production leaves this nil;
  /// tests use it to prove the transaction rejects an invalidated snapshot.
  var agentChatCreationPreinsertHook: (@Sendable (SQLiteDatabase) throws -> Void)?
  /// Internal test seam that simulates a source-library mutation at the
  /// pre-insert boundary of translation-notebook creation. Production leaves
  /// this nil; tests use it to prove the transaction rejects a stale source
  /// snapshot before it can create a less-restricted derived notebook.
  var translationCreationPreinsertHook: (@Sendable (SQLiteDatabase) throws -> Void)?
  /// Internal test seam that runs after translation output commits but before
  /// the run attempts completion. It proves a post-write source edit replaces
  /// obsolete output rather than leaving two visible translations.
  var translationOutputPostCommitHook: (@Sendable (Note) throws -> Void)?
  /// Internal test seam for the edit reply's final turn write. It executes
  /// inside the same transaction as the replacement body, proving a failed
  /// completion cannot leave a retryable turn with a committed edit.
  var agentChatEditPrecompletionHook: (@Sendable (SQLiteDatabase) throws -> Void)?
  /// Internal test seam that runs after API-client listing authorizes the
  /// caller but before its query. It proves the authorization and listing
  /// remain in the same transaction under a concurrent standing change.
  var apiClientListAfterAuthorizationHook: (@Sendable (SQLiteDatabase) throws -> Void)?
  /// Internal test seam for account-list authorization. It runs inside the
  /// same immediate transaction as the global account query so tests can
  /// prove a concurrent demotion cannot interleave between them.
  var userListAfterAuthorizationHook: (@Sendable (SQLiteDatabase) throws -> Void)?
  /// Internal test seam for retry and recovery control-plane work. It runs
  /// after administrator authorization but before selecting or mutating
  /// store-global dispatch rows, within the same immediate transaction.
  var autoActionMaintenanceAuthHook: (@Sendable (SQLiteDatabase) throws -> Void)?
  /// Internal test seam for read-only global auto-action control-plane work.
  /// It runs after administrator authorization and before the query inside the
  /// same immediate transaction, so standing changes cannot interleave.
  var autoActionListAfterAuthorizationHook: (@Sendable (SQLiteDatabase) throws -> Void)?
  /// Internal test seam that pauses a leased stream after its database lease
  /// validation but before stream admission. It proves a recovered lease owns
  /// every later chunk and terminal side effect.
  var agentReplyStreamPostLeaseValidationHook: (@Sendable (AgentReplyStreamLease) async -> Void)?
  /// Internal test seam immediately before an AI provider admission check. It
  /// lets revocation tests disable the originating account at the last safe
  /// boundary without giving production code another asynchronous gap.
  var providerInvocationPreAdmissionHook: (@Sendable () async -> Void)?
  /// Window after which a live in-flight dispatch lease is treated as stale by
  /// the recovery path. A running attempt heartbeats its lease on a fraction of
  /// this window so a long workflow is never reclaimed out from under it.
  public var autoActionDispatchLeaseStaleness: TimeInterval
  /// Present only while executing a claimed auto-action.  Write paths consult
  /// it inside their own database transactions so a worker that lost its
  /// lease cannot persist provider-derived state after recovery reclaims the
  /// outbox row.
  var activeAutoActionDispatchLease: AutoActionDispatchLease?
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
    agentExecutionAdmission: AgentExecutionAdmission = AgentExecutionAdmission(),
    autoActionDispatchLeaseStaleness: TimeInterval = defaultAutoActionDispatchLeaseStaleness,
    changeObserver: (any NoteChangeObserving)? = nil
  ) throws {
    self.driver = driver
    self.autoActionDispatcher = autoActionDispatcher
    self.autoActionDiagnosticRecorder = autoActionDiagnosticRecorder
    self.agentExecutionAdmission = agentExecutionAdmission
    self.chatAttachmentFileStore = nil
    self.agentChatCreationPreinsertHook = nil
    self.translationCreationPreinsertHook = nil
    self.translationOutputPostCommitHook = nil
    self.agentChatEditPrecompletionHook = nil
    self.apiClientListAfterAuthorizationHook = nil
    self.userListAfterAuthorizationHook = nil
    self.autoActionMaintenanceAuthHook = nil
    self.agentReplyStreamPostLeaseValidationHook = nil
    self.providerInvocationPreAdmissionHook = nil
    self.autoActionDispatchLeaseStaleness = autoActionDispatchLeaseStaleness
    self.activeAutoActionDispatchLease = nil
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
    libraryId: LibraryID? = nil,
    originatingActionId: AutoActionID? = nil
  ) throws -> Notebook {
    let result = try driver.withDatabase { database in
      try database.transaction { db in
        try insertNotebook(
          title: title,
          kindTagName: kindTagName,
          folderPath: folderPath,
          metaJSON: metaJSON,
          libraryId: libraryId,
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
    libraryId: LibraryID? = nil,
    originatingActionId: AutoActionID?,
    in db: SQLiteDatabase
  ) throws -> (notebook: Notebook, dispatches: [QueuedAutoActionDispatch]) {
    let now = NoteStoreClock.system.now()
    let notebookId = NotebookID.generate()
    let destinationLibraryId = libraryId ?? writeLibraryId()
    guard try isReachable(libraryId: destinationLibraryId, in: db) else {
      throw NoteServiceError.notFound("library not found: \(destinationLibraryId)")
    }
    try db.execute(
      """
      INSERT INTO notebooks (
        notebook_id, title, owner_user_id, library_id, created_by, updated_by,
        created_at, updated_at, meta_json
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, jsonb(?))
      """,
      bindings: [
        .id(notebookId), .text(title), .id(writeOwnerUserId()),
        .id(destinationLibraryId),
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
    try recordAction(
      NoteActionRecord(
        kind: .notebookCreated,
        provenance: originatingActionId == nil ? .human : .system,
        entityType: .notebook,
        entityId: notebookId.rawValue,
        notebookId: notebookId,
        display: ["title": .string(title)],
        undoable: true
      ),
      in: db
    )
    let dispatches = try enqueueAutoActions(
      for: makeAutoActionEvent(
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
    originatingActionId: AutoActionID? = nil,
    derivedFromNotebookId: NotebookID? = nil
  ) throws -> Note {
    let result = try driver.withDatabase { database in
      try database.transaction { db in
        try requireEnabledActingUser(in: db)
        let now = NoteStoreClock.system.now()
        let notebookId: NotebookID
        let createdNotebookId: NotebookID?
        if let requestedNotebookId {
          let notebook = try requireNotebook(requestedNotebookId, in: db)
          guard !notebook.readOnly else {
            throw NoteServiceError.readOnly(requestedNotebookId.rawValue)
          }
          if let derivedFromNotebookId {
            let source = try requireNotebook(derivedFromNotebookId, in: db)
            guard source.libraryId == notebook.libraryId else {
              throw NoteServiceError.conflict(
                "derived note source and destination libraries no longer match"
              )
            }
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
        if let createdNotebookId {
          try recordAction(
            NoteActionRecord(
              kind: .notebookCreated,
              provenance: provenance,
              entityType: .notebook,
              entityId: createdNotebookId.rawValue,
              notebookId: createdNotebookId,
              display: ["title": .optionalString(try requireNotebook(createdNotebookId, in: db).title)],
              undoable: true
            ),
            in: db
          )
        }
        try recordAction(
          NoteActionRecord(
            kind: .noteCreated,
            provenance: provenance,
            entityType: .note,
            entityId: noteId.rawValue,
            notebookId: note.notebookId,
            display: ["title": .optionalString(note.title)],
            undoable: true
          ),
          in: db
        )
        var dispatches: [QueuedAutoActionDispatch] = []
        if let createdNotebookId {
          dispatches.append(contentsOf: try enqueueAutoActions(
            for: makeAutoActionEvent(
              trigger: .notebookCreated,
              notebookId: createdNotebookId,
              originatingActionId: originatingActionId
            ),
            in: db
          ))
        }
        dispatches.append(contentsOf: try enqueueAutoActions(
          for: makeAutoActionEvent(
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
    // Recorded but not undoable (U10): a bulk ingest's cascade snapshot would
    // embed every page body.
    try recordAction(
      NoteActionRecord(
        kind: .notebookIngested,
        provenance: provenance,
        entityType: .notebook,
        entityId: notebookId.rawValue,
        notebookId: notebookId,
        display: [
          "title": .string(title),
          "noteCount": .integer(Int64(notes.count))
        ],
        undoable: false
      ),
      in: db
    )
    var dispatches = try enqueueAutoActions(
      for: makeAutoActionEvent(
        trigger: .notebookCreated,
        notebookId: ingestResult.notebook.notebookId,
        originatingActionId: originatingActionId
      ),
      in: db
    )
    for note in ingestResult.notes {
      dispatches.append(contentsOf: try enqueueAutoActions(
        for: makeAutoActionEvent(
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
      let expandedTagFilterIds = try expandedTagFilterIds(names: tagFilter, in: database)
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
      appendOwnerScopePredicate(
        alias: "notes",
        actingUserId: actingUserId,
        predicates: &predicates,
        bindings: &bindings
      )
      if isUnauthenticatedPrincipal, actingUserId == nil {
        appendLongTermMemoryExclusionPredicate(
          alias: "notes",
          excludesLongTermMemory: true,
          predicates: &predicates,
          bindings: &bindings
        )
      }
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
    provenance: NoteProvenance = .human,
    originatingActionId: AutoActionID? = nil
  ) throws -> Note {
    let result = try driver.withDatabase { database in
      try database.transaction { db in
        try updateNoteBodyInDatabase(
          noteId: noteId,
          bodyMarkdown: bodyMarkdown,
          provenance: provenance,
          originatingActionId: originatingActionId,
          in: db
        )
      }
    }
    dispatchQueuedAutoActions(result.dispatches)
    publishChange(NoteChangeEvent(
      kind: NoteChangeEventKind.noteUpdated,
      notebookId: result.note.notebookId
    ))
    return result.note
  }

  /// Performs the guarded note-body mutation inside a caller-owned database
  /// transaction. Agent edit replies use this to validate their immutable
  /// provider-context snapshot in the same transaction as the replacement.
  func updateNoteBodyInDatabase(
    noteId: NoteID,
    bodyMarkdown: String,
    provenance: NoteProvenance,
    originatingActionId: AutoActionID?,
    in database: SQLiteDatabase
  ) throws -> (note: Note, dispatches: [QueuedAutoActionDispatch]) {
    try requireEnabledActingUser(in: database)
    let existing = try requireWritableNote(noteId, in: database)
    let previous = try ftsPayload(noteId: noteId, in: database)
    let now = NoteStoreClock.system.now()
    // Explicit titles (set via the `title` argument on create) are preserved
    // across body edits; only derived titles are re-derived from the new body.
    let titleSource = try noteTitleSource(noteId: noteId, in: database)
    let updatedTitle = titleSource == .explicit
      ? existing.title
      : (noteTitle(from: bodyMarkdown) ?? existing.title)
    try database.execute(
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
    try database.execute(
      "UPDATE notebooks SET updated_at = ?, updated_by = owner_user_id WHERE notebook_id = ?",
      bindings: [.text(now), .id(existing.notebookId)]
    )
    try refreshFTS(noteId: noteId, previous: previous, in: database)
    let note = try requireNote(noteId, in: database)
    let bodyPatch = makeNoteBodyPatch(from: existing.bodyMarkdown, to: bodyMarkdown)
    if bodyPatch != nil || updatedTitle != existing.title {
      var delta: JSONObject = [:]
      if let bodyPatch {
        delta["body"] = bodyPatch.jsonValue
      }
      if updatedTitle != existing.title {
        delta["title"] = .object([
          "before": .optionalString(existing.title),
          "after": .optionalString(updatedTitle)
        ])
      }
      try recordAction(
        NoteActionRecord(
          kind: .noteBodyUpdated,
          provenance: provenance,
          entityType: .note,
          entityId: noteId.rawValue,
          notebookId: note.notebookId,
          display: ["title": .optionalString(note.title)],
          delta: .object(delta),
          undoable: true
        ),
        in: database
      )
    }
    let dispatches = try enqueueAutoActions(
      for: makeAutoActionEvent(
        trigger: .noteUpdated,
        notebookId: note.notebookId,
        noteId: note.noteId,
        noteBodyMarkdown: note.bodyMarkdown,
        originatingActionId: originatingActionId
      ),
      in: database
    )
    return (note: note, dispatches: dispatches)
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

func deleteTranslationOutputs(sourceNoteId: NoteID, in database: SQLiteDatabase) throws {
  let outputIds = try database.query(
    """
    SELECT note_id FROM notes
    WHERE json_extract(meta_json, '$.kaibaTranslation.sourceNoteId') = ?
    """,
    bindings: [.id(sourceNoteId)]
  ).compactMap { $0.identifier("note_id", as: NoteID.self) }
  for outputId in outputIds {
    try deleteNoteRows(noteId: outputId, in: database)
  }
}
