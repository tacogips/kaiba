import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Notebook translation (`design-docs/specs/ai-agent-integration.md`, AI9).
/// A translation is a `notebook-kind:translation` notebook created up front in
/// `pending` state; the translation run then appends one translated note per
/// source note and finally flips the state to `completed` (or `failed`).
/// Translation state lives in notebook meta JSON under `kaibaTranslation`, and
/// every translated note records its source note under the same key, matching
/// the `kaibaChat` precedent. Recovery uses that stable source identity rather
/// than destination-note position, so deleted or reordered sources cannot
/// cause a retry to skip remaining work.

public extension NoteService {
  static let manualTranslationActionId = AutoActionID("manual-notebook-translation")

  /// Creates the pending translation notebook for a source notebook. The run
  /// itself happens in `AITranslationService.run`, synchronously from the CLI
  /// or via the `notebook-translation` auto-action dispatch.
  @discardableResult
  func startNotebookTranslation(
    sourceNotebookId: NotebookID,
    targetLanguage: String,
    title: String? = nil,
    pageStart: Int? = nil,
    pageEnd: Int? = nil
  ) throws -> Notebook {
    switch (pageStart, pageEnd) {
    case (nil, nil): break
    case let (.some(start), .some(end)) where start > 0 && end >= start: break
    default: throw NoteServiceError.invalidInput("translation page range must be positive and inclusive")
    }
    let language = targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !language.isEmpty else {
      throw NoteServiceError.invalidInput("translation target language must not be empty")
    }
    let result = try driver.withDatabase { database in
      try database.transaction { db in
        let source = try requireNotebook(sourceNotebookId, in: db)
        if let pageEnd {
          let last = try db.query("SELECT MAX(note_number) AS last FROM notes WHERE notebook_id = ?",
            bindings: [.id(sourceNotebookId)]).first
          guard pageEnd <= Int(last?.string("last") ?? "0") ?? 0 else {
            throw NoteServiceError.invalidInput("translation page range exceeds the source document")
          }
        }
        let sourceHasNotes = try db.query(
          "SELECT 1 FROM notes WHERE notebook_id = ? LIMIT 1",
          bindings: [.id(sourceNotebookId)]
        ).isEmpty == false
        guard sourceHasNotes else {
          throw NoteServiceError.invalidInput(
            "source notebook has no notes to translate: \(sourceNotebookId)"
          )
        }
        try translationCreationPreinsertHook?(db)
        let currentSource = try requireNotebook(sourceNotebookId, in: db)
        guard currentSource.libraryId == source.libraryId else {
          throw NoteServiceError.conflict(
            "translation source library changed before derived notebook creation"
          )
        }
        let metaJSON = try Self.translationNotebookMetaJSON(state: AITranslationState(
          sourceNotebookId: sourceNotebookId,
          targetLanguage: language,
          status: .pending, pageStart: pageStart, pageEnd: pageEnd
        ))
        // originatingActionId suppresses follow-up auto-actions (auto-tagging
        // has nothing useful to say about an empty pending notebook).
        return try insertNotebook(
          title: title ?? "\(source.title) [\(language)]",
          kindTagName: NoteStoreSchema.translationNotebookKindTag,
          metaJSON: metaJSON,
          libraryId: currentSource.libraryId,
          originatingActionId: Self.manualTranslationActionId,
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

  /// Queues an async translation run (the UI's "translate" button and the
  /// GraphQL `requestNotebookTranslation` mutation). Returns `(nil, false)`
  /// without creating anything when no dispatcher is installed (agent
  /// unavailable), so no pending notebook is ever left with nothing to
  /// drain it.
  func requestNotebookTranslation(
    sourceNotebookId: NotebookID,
    targetLanguage: String,
    title: String? = nil,
    pageStart: Int? = nil,
    pageEnd: Int? = nil
  ) throws -> (notebook: Notebook?, queued: Bool) {
    _ = try getNotebook(sourceNotebookId)
    guard autoActionDispatcher != nil else {
      return (nil, false)
    }
    let notebook = try startNotebookTranslation(
      sourceNotebookId: sourceNotebookId,
      targetLanguage: targetLanguage,
      title: title, pageStart: pageStart, pageEnd: pageEnd
    )
    let action = AutoAction(
      actionId: Self.manualTranslationActionId,
      trigger: .notebookCreated,
      workflowId: NoteStoreSchema.notebookTranslationWorkflowId,
      filterJSON: nil,
      enabled: true,
      position: 0,
      createdAt: NoteStoreClock.system.now()
    )
    let event = makeAutoActionEvent(
      trigger: .notebookCreated,
      notebookId: notebook.notebookId
    )
    let queued = try driver.withDatabase { database in
      try database.transaction { db in
        try enqueueManualAutoActionDispatch(action: action, event: event, in: db)
      }
    }
    dispatchQueuedAutoActions([queued])
    return (notebook, true)
  }

  /// Parses translation state from a notebook's meta JSON; nil for
  /// non-translation notebooks.
  static func translationState(of notebook: Notebook) -> AITranslationState? {
    guard let metaJSON = notebook.metaJSON,
      let root = try? JSONValue(parsing: metaJSON),
      let translation = root["kaibaTranslation"],
      let sourceNotebookId: NotebookID = translation.identifier("sourceNotebookId"),
      let targetLanguage = translation["targetLanguage"]?.asString,
      let statusText = translation["status"]?.asString,
      let status = AITranslationStatus(rawValue: statusText)
    else {
      return nil
    }
    return AITranslationState(
      sourceNotebookId: sourceNotebookId,
      targetLanguage: targetLanguage,
      status: status,
      errorMessage: translation["error"]?.asString,
      continuationSourceNoteId: translation.identifier("continuationSourceNoteId"),
      sourceNotebookRevision: translation["sourceNotebookRevision"]?.asInt64,
      pageStart: translation["pageStart"]?.asInt64.map(Int.init),
      pageEnd: translation["pageEnd"]?.asInt64.map(Int.init)
    )
  }

  /// Rewrites the `kaibaTranslation` status on a translation notebook,
  /// preserving any other meta JSON keys.
  @discardableResult
  func setNotebookTranslationStatus(
    _ notebookId: NotebookID,
    status: AITranslationStatus,
    errorMessage: String? = nil,
    expectedSourceNotebookId: NotebookID? = nil,
    expectedLibraryId: LibraryID? = nil
  ) throws -> Notebook {
    let updated = try driver.withDatabase { database in
      try database.transaction { db -> Notebook in
        try requireEnabledActingUser(in: db)
        let notebook = try requireNotebook(notebookId, in: db)
        guard var state = Self.translationState(of: notebook) else {
          throw NoteServiceError.invalidInput(
            "notebook is not a translation notebook: \(notebookId)"
          )
        }
        if let expectedSourceNotebookId {
          guard state.sourceNotebookId == expectedSourceNotebookId else {
            throw NoteServiceError.conflict("translation source changed during execution")
          }
          let source = try requireNotebook(expectedSourceNotebookId, in: db)
          guard source.libraryId == expectedLibraryId,
            notebook.libraryId == expectedLibraryId
          else {
            throw NoteServiceError.conflict(
              "translation source and destination libraries changed during execution"
            )
          }
        }
        state.status = status
        state.errorMessage = errorMessage
        if status != .pending {
          state.continuationSourceNoteId = nil
          state.sourceNotebookRevision = nil
        }
        let metaJSON = try Self.translationNotebookMetaJSON(
          state: state,
          mergingInto: notebook.metaJSON
        )
        try db.execute(
          "UPDATE notebooks SET meta_json = jsonb(?), updated_at = ?, updated_by = owner_user_id WHERE notebook_id = ?",
          bindings: [
            .text(metaJSON),
            .text(NoteStoreClock.system.now()),
            .id(notebookId)
          ]
        )
        return try requireNotebook(notebookId, in: db)
      }
    }
    publishChange(NoteChangeEvent(
      kind: NoteChangeEventKind.noteUpdated,
      notebookId: notebookId
    ))
    return updated
  }

  /// Persists bounded-chunk progress without changing the durable pending
  /// status. The source/output hashes are still revalidated before each write,
  /// so a stale cursor cannot skip an edited or newly inserted source.
  @discardableResult
  func setNotebookTranslationContinuation(
    _ notebookId: NotebookID,
    sourceNoteId: NoteID?,
    expectedSourceNotebookId: NotebookID,
    expectedLibraryId: LibraryID?,
    expectedSourceNotebookRevision: Int64
  ) throws -> Notebook {
    let updated = try driver.withDatabase { database in
      try database.transaction { db -> Notebook in
        try requireEnabledActingUser(in: db)
        let notebook = try requireNotebook(notebookId, in: db)
        guard var state = Self.translationState(of: notebook) else {
          throw NoteServiceError.invalidInput("notebook is not a translation notebook: \(notebookId)")
        }
        guard state.status == .pending,
          state.sourceNotebookId == expectedSourceNotebookId
        else {
          throw NoteServiceError.conflict("translation state changed during continuation")
        }
        let source = try requireNotebook(expectedSourceNotebookId, in: db)
        guard source.libraryId == expectedLibraryId,
          notebook.libraryId == expectedLibraryId
        else {
          throw NoteServiceError.conflict("translation source and destination libraries changed during continuation")
        }
        let sourceRevision = try Self.translationSourceRevision(
          notebookId: expectedSourceNotebookId,
          in: db
        )
        if !Self.translationSourceRevisionAdvanced(
          sourceRevision,
          beyond: expectedSourceNotebookRevision
        ) {
          state.continuationSourceNoteId = sourceNoteId
          state.sourceNotebookRevision = expectedSourceNotebookRevision
        } else {
          // A source changed while this page was being processed. Restart the
          // next durable page instead of letting a cursor skip altered rows.
          state.continuationSourceNoteId = nil
          state.sourceNotebookRevision = sourceRevision
        }
        state.errorMessage = nil
        try db.execute(
          "UPDATE notebooks SET meta_json = jsonb(?), updated_at = ?, updated_by = owner_user_id WHERE notebook_id = ?",
          bindings: [
            .text(try Self.translationNotebookMetaJSON(state: state, mergingInto: notebook.metaJSON)),
            .text(NoteStoreClock.system.now()),
            .id(notebookId)
          ]
        )
        return try requireNotebook(notebookId, in: db)
      }
    }
    publishChange(NoteChangeEvent(kind: NoteChangeEventKind.noteUpdated, notebookId: notebookId))
    return updated
  }

  /// Marks a translation complete at the end of a full cursor pass only when
  /// the source notebook still has the revision captured at the start of that
  /// pass. This avoids rescanning unbounded source/output sets at completion.
  func completeNotebookTranslationIfSourceSnapshotCurrent(
    _ notebookId: NotebookID,
    expectedSourceNotebookId: NotebookID,
    expectedLibraryId: LibraryID?,
    expectedSourceNotebookRevision: Int64,
    expectedLastSourceNote: (noteId: NoteID, noteNumber: Int)?
  ) throws -> Notebook? {
    let completed = try driver.withDatabase { database in
      try database.transaction { db -> Notebook? in
        try requireEnabledActingUser(in: db)
        let translation = try requireNotebook(notebookId, in: db)
        guard var state = Self.translationState(of: translation) else {
          throw NoteServiceError.invalidInput(
            "notebook is not a translation notebook: \(notebookId)"
          )
        }
        guard state.sourceNotebookId == expectedSourceNotebookId else {
          throw NoteServiceError.conflict("translation source changed during execution")
        }
        let source = try requireNotebook(expectedSourceNotebookId, in: db)
        guard source.libraryId == expectedLibraryId,
          translation.libraryId == expectedLibraryId
        else {
          throw NoteServiceError.conflict(
            "translation source and destination libraries changed during execution"
          )
        }
        guard !Self.translationSourceRevisionAdvanced(
          try Self.translationSourceRevision(
            notebookId: expectedSourceNotebookId,
            in: db
          ),
          beyond: expectedSourceNotebookRevision
        ) else {
          return nil
        }
        let scope = state.pageStart != nil ? " AND note_number BETWEEN ? AND ?" : ""
        let scopeBindings: [SQLiteValue]
        if let start = state.pageStart, let end = state.pageEnd {
          scopeBindings = [.int(Int64(start)), .int(Int64(end))]
        } else { scopeBindings = [] }
        let sourceAdvancedSinceSnapshot: Bool
        if let expectedLastSourceNote {
          sourceAdvancedSinceSnapshot = try db.query(
            """
            SELECT 1 FROM notes
            WHERE notebook_id = ?\(scope)
              AND (note_number > ? OR (note_number = ? AND note_id > ?))
            LIMIT 1
            """,
            bindings: [
              .id(expectedSourceNotebookId)
            ] + scopeBindings + [
              .int(Int64(expectedLastSourceNote.noteNumber)),
              .int(Int64(expectedLastSourceNote.noteNumber)),
              .id(expectedLastSourceNote.noteId)
            ]
          ).isEmpty == false
        } else {
          sourceAdvancedSinceSnapshot = try db.query(
            "SELECT 1 FROM notes WHERE notebook_id = ?\(scope) LIMIT 1",
            bindings: [.id(expectedSourceNotebookId)] + scopeBindings
          ).isEmpty == false
        }
        guard !sourceAdvancedSinceSnapshot else {
          return nil
        }
        state.status = .completed
        state.errorMessage = nil
        state.continuationSourceNoteId = nil
        state.sourceNotebookRevision = nil
        let metaJSON = try Self.translationNotebookMetaJSON(
          state: state,
          mergingInto: translation.metaJSON
        )
        try db.execute(
          "UPDATE notebooks SET meta_json = jsonb(?), updated_at = ?, updated_by = owner_user_id WHERE notebook_id = ?",
          bindings: [
            .text(metaJSON),
            .text(NoteStoreClock.system.now()),
            .id(notebookId)
          ]
        )
        return try requireNotebook(notebookId, in: db)
      }
    }
    if completed != nil {
      publishChange(NoteChangeEvent(
        kind: NoteChangeEventKind.noteUpdated,
        notebookId: notebookId
      ))
    }
    return completed
  }

  static func translationNotebookMetaJSON(
    state: AITranslationState,
    mergingInto existingMetaJSON: String? = nil
  ) throws -> String {
    var root: JSONObject = [:]
    if let existingMetaJSON,
      let existing = (try? JSONValue(parsing: existingMetaJSON))?.asObject {
      root = existing
    }
    var translation: JSONObject = [
      "sourceNotebookId": .id(state.sourceNotebookId),
      "targetLanguage": .string(state.targetLanguage),
      "status": .string(state.status.rawValue)
    ]
    translation["error"] = state.errorMessage.map(JSONValue.string)
    translation["continuationSourceNoteId"] = state.continuationSourceNoteId.map(JSONValue.id)
    translation["sourceNotebookRevision"] = state.sourceNotebookRevision.map(JSONValue.integer)
    translation["pageStart"] = state.pageStart.map { .integer(Int64($0)) }
    translation["pageEnd"] = state.pageEnd.map { .integer(Int64($0)) }
    root["kaibaTranslation"] = .object(translation)
    do {
      return try JSONValue.object(root).encodedString()
    } catch {
      throw NoteServiceError.invalidInput("translation notebook meta JSON must be UTF-8")
    }
  }

  static func translationNoteMetaJSON(
    sourceNoteId: NoteID,
    sourceContentHash: String
  ) throws -> String {
    let root: JSONValue = .object([
      "kaibaTranslation": .object([
        "sourceNoteId": .id(sourceNoteId),
        "sourceContentHash": .string(sourceContentHash)
      ])
    ])
    do {
      return try root.encodedString()
    } catch {
      throw NoteServiceError.invalidInput("translation note meta JSON must be UTF-8")
    }
  }

  static func translationSourceContentHash(_ bodyMarkdown: String) -> String {
    SHA256.hash(data: Data(bodyMarkdown.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  /// A dedicated per-notebook table records the latest action sequence outside
  /// the prunable action-history retention window, unlike wall-clock timestamps
  /// that can collide within a formatting tick.
  static func translationSourceRevision(
    notebookId: NotebookID,
    in database: SQLiteDatabase
  ) throws -> Int64 {
    guard let revisionText = try database.query(
      """
      SELECT COALESCE(r.revision, 0) AS revision
      FROM notebooks n
      LEFT JOIN notebook_translation_revisions r ON r.notebook_id = n.notebook_id
      WHERE n.notebook_id = ?
      LIMIT 1
      """,
      bindings: [.id(notebookId)]
    ).first?["revision"], let revision = Int64(revisionText) else {
      throw NoteServiceError.invalidRow("translation source revision is missing")
    }
    return revision
  }

  /// A durable source token changes whenever an action affects the source
  /// notebook. Equality, rather than ordering, also fails safely for
  /// corrupted metadata values.
  static func translationSourceRevisionAdvanced(_ current: Int64, beyond expected: Int64) -> Bool {
    current != expected
  }

  /// Inserts output only when the source body still matches the provider
  /// snapshot. This keeps a concurrent source edit from being represented as
  /// a current translation. The transaction removes every older output for
  /// this source before writing a new version, so a completed notebook exposes
  /// exactly one translation for each current source note.
  func createTranslationOutputIfSourceCurrent(
    translationNotebookId: NotebookID,
    sourceNotebookId: NotebookID,
    sourceNoteId: NoteID,
    expectedLibraryId: LibraryID?,
    expectedSourceContentHash: String,
    bodyMarkdown: String,
    originatingActionId: AutoActionID?
  ) throws -> Bool {
    let result = try driver.withDatabase { database in
      try database.transaction { db -> TranslationOutputInsertResult in
        try requireEnabledActingUser(in: db)
        let source: Note
        do {
          source = try requireNote(sourceNoteId, in: db)
        } catch let error as NoteServiceError {
          // A provider may finish after its source was deleted. This is not a
          // provider or persistence failure: the captured source set is stale
          // and the run must refresh before deciding whether completion is
          // possible for the remaining sources.
          guard case .notFound = error else {
            throw error
          }
          return .sourceChanged
        }
        guard source.notebookId == sourceNotebookId,
          Self.translationSourceContentHash(noteRetrievalText(
            bodyMarkdown: source.bodyMarkdown, searchText: try noteSearchText(sourceNoteId, in: db)
          )) == expectedSourceContentHash
        else {
          return .sourceChanged
        }
        let sourceNotebook = try requireNotebook(sourceNotebookId, in: db)
        let translation = try requireWritableNotebook(translationNotebookId, in: db)
        guard sourceNotebook.libraryId == expectedLibraryId,
          translation.libraryId == expectedLibraryId
        else {
          throw NoteServiceError.conflict(
            "translation source and destination libraries changed during execution"
          )
        }
        let existing = try db.query(
          """
          SELECT note_id,
            json_extract(meta_json, '$.kaibaTranslation.sourceContentHash') AS source_content_hash
          FROM notes
          WHERE notebook_id = ?
            AND json_extract(meta_json, '$.kaibaTranslation.sourceNoteId') = ?
          """,
          bindings: [.id(translationNotebookId), .id(sourceNoteId)]
        )
        let existingOutputs = try existing.map { row -> (noteId: NoteID, contentHash: String?) in
          guard let noteId = row.identifier("note_id", as: NoteID.self) else {
            throw NoteServiceError.invalidRow("translation output row is missing note_id")
          }
          return (noteId, row["source_content_hash"])
        }
        let retainedOutput = existingOutputs.first {
          $0.contentHash == expectedSourceContentHash
        }
        if let retainedOutput {
          let obsoleteOutputIds = existingOutputs.compactMap { output in
            output.noteId == retainedOutput.noteId ? nil : output.noteId
          }
          for obsoleteOutputId in obsoleteOutputIds {
            try deleteNoteRows(noteId: obsoleteOutputId, in: db)
          }
          if !obsoleteOutputIds.isEmpty {
            try db.execute(
              "UPDATE notebooks SET updated_at = ?, updated_by = owner_user_id WHERE notebook_id = ?",
              bindings: [.text(NoteStoreClock.system.now()), .id(translationNotebookId)]
            )
          }
          return .current(prunedObsoleteOutputs: !obsoleteOutputIds.isEmpty)
        }
        if let replacementOutput = existingOutputs.first {
          let obsoleteOutputIds = existingOutputs.compactMap { output in
            output.noteId == replacementOutput.noteId ? nil : output.noteId
          }
          for obsoleteOutputId in obsoleteOutputIds {
            try deleteNoteRows(noteId: obsoleteOutputId, in: db)
          }
          let updated = try updateNoteBodyInDatabase(
            noteId: replacementOutput.noteId,
            bodyMarkdown: bodyMarkdown,
            provenance: .ai,
            originatingActionId: originatingActionId,
            in: db
          )
          try db.execute(
            "UPDATE notes SET meta_json = jsonb(?) WHERE note_id = ?",
            bindings: [
              .text(try Self.translationNoteMetaJSON(
                sourceNoteId: sourceNoteId,
                sourceContentHash: expectedSourceContentHash
              )),
              .id(replacementOutput.noteId)
            ]
          )
          return .replaced(
            note: try requireNote(replacementOutput.noteId, in: db),
            dispatches: updated.dispatches
          )
        }
        let now = NoteStoreClock.system.now()
        let noteId = NoteID.generate()
        let noteNumber = try nextNoteNumber(notebookId: translationNotebookId, in: db)
        let title = noteTitle(from: bodyMarkdown)
        try db.execute(
          """
          INSERT INTO notes (
            note_id, notebook_id, note_number, title, title_source, body_markdown,
            read_only, created_by, updated_by, created_at, updated_at, meta_json
          ) VALUES (
            ?, ?, ?, ?, ?, ?, 0,
            (SELECT owner_user_id FROM notebooks WHERE notebook_id = ?),
            (SELECT owner_user_id FROM notebooks WHERE notebook_id = ?),
            ?, ?, jsonb(?)
          )
          """,
          bindings: [
            .id(noteId), .id(translationNotebookId), .int(Int64(noteNumber)),
            .optionalText(title), .text(NoteTitleSource.derived.rawValue), .text(bodyMarkdown),
            .id(translationNotebookId), .id(translationNotebookId),
            .text(now), .text(now),
            .text(try Self.translationNoteMetaJSON(
              sourceNoteId: sourceNoteId,
              sourceContentHash: expectedSourceContentHash
            ))
          ]
        )
        try db.execute(
          "UPDATE notebooks SET updated_at = ?, updated_by = owner_user_id WHERE notebook_id = ?",
          bindings: [.text(now), .id(translationNotebookId)]
        )
        try refreshFTS(noteId: noteId, previous: nil, in: db)
        let note = try requireNote(noteId, in: db)
        try recordAction(
          NoteActionRecord(
            kind: .noteCreated,
            provenance: .ai,
            entityType: .note,
            entityId: noteId.rawValue,
            notebookId: translationNotebookId,
            display: ["title": .optionalString(note.title)],
            undoable: true
          ),
          in: db
        )
        let dispatches = try enqueueAutoActions(
          for: makeAutoActionEvent(
            trigger: .noteCreated,
            notebookId: translationNotebookId,
            noteId: noteId,
            noteBodyMarkdown: bodyMarkdown,
            originatingActionId: originatingActionId
          ),
          in: db
        )
        return .created(note: note, dispatches: dispatches)
      }
    }
    switch result {
    case let .created(note, dispatches):
      dispatchQueuedAutoActions(dispatches)
      publishChange(NoteChangeEvent(kind: NoteChangeEventKind.noteCreated, notebookId: note.notebookId))
      try translationOutputPostCommitHook?(note)
      return true
    case let .replaced(note, dispatches):
      dispatchQueuedAutoActions(dispatches)
      publishChange(NoteChangeEvent(kind: NoteChangeEventKind.noteUpdated, notebookId: note.notebookId))
      try translationOutputPostCommitHook?(note)
      return true
    case .sourceChanged:
      return false
    case .current(let prunedObsoleteOutputs):
      if prunedObsoleteOutputs {
        publishChange(NoteChangeEvent(
          kind: NoteChangeEventKind.noteUpdated,
          notebookId: translationNotebookId
        ))
      }
      return true
    }
  }
}
