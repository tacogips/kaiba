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
    title: String? = nil
  ) throws -> Notebook {
    let language = targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !language.isEmpty else {
      throw NoteServiceError.invalidInput("translation target language must not be empty")
    }
    let result = try driver.withDatabase { database in
      try database.transaction { db in
        let source = try requireNotebook(sourceNotebookId, in: db)
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
          status: .pending
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
    title: String? = nil
  ) throws -> (notebook: Notebook?, queued: Bool) {
    _ = try getNotebook(sourceNotebookId)
    guard autoActionDispatcher != nil else {
      return (nil, false)
    }
    let notebook = try startNotebookTranslation(
      sourceNotebookId: sourceNotebookId,
      targetLanguage: targetLanguage,
      title: title
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
    let event = NoteAutoActionEvent(
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
      sourceNotebookRevision: translation["sourceNotebookRevision"]?.asInt64
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
        let sourceAdvancedSinceSnapshot: Bool
        if let expectedLastSourceNote {
          sourceAdvancedSinceSnapshot = try db.query(
            """
            SELECT 1 FROM notes
            WHERE notebook_id = ?
              AND (note_number > ? OR (note_number = ? AND note_id > ?))
            LIMIT 1
            """,
            bindings: [
              .id(expectedSourceNotebookId),
              .int(Int64(expectedLastSourceNote.noteNumber)),
              .int(Int64(expectedLastSourceNote.noteNumber)),
              .id(expectedLastSourceNote.noteId)
            ]
          ).isEmpty == false
        } else {
          sourceAdvancedSinceSnapshot = try db.query(
            "SELECT 1 FROM notes WHERE notebook_id = ? LIMIT 1",
            bindings: [.id(expectedSourceNotebookId)]
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
  /// notebook. Equality, rather than ordering, also fails safely for legacy
  /// or corrupted metadata values.
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
          Self.translationSourceContentHash(source.bodyMarkdown) == expectedSourceContentHash
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
          for: NoteAutoActionEvent(
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

/// Runs a notebook translation against the agent seam. One invocation per
/// source note keeps every prompt bounded; already-translated notes are
/// counted and skipped, so an outbox retry resumes where the failed attempt
/// stopped instead of re-translating (and re-paying for) finished pages. A
/// completion transaction checks the current source set, so notes added while
/// a provider is running are included before the translation becomes final.
public struct AITranslationService: Sendable {
  public static let assignedBy = "kaiba-ai-translator"
  /// Per-note cap mirrors the other AI features' context cap.
  static let maximumNoteBytes = 200 * 1024

  public var service: NoteService
  public var invoker: any AgentInvoking
  public var provider: String?
  public var model: String?
  /// Test-only observability for the bounded source-page contract. Production
  /// callers leave this nil.
  public var sourcePageObserver: (@Sendable (Int) async -> Void)?
  /// Injectable monotonic time source for enforcing the reconciliation budget
  /// and deterministically exercising its deadline boundary in tests.
  public var reconciliationNow: @Sendable () -> ContinuousClock.Instant

  public init(
    service: NoteService,
    invoker: any AgentInvoking,
    provider: String? = nil,
    model: String? = nil,
    reconciliationNow: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now },
    sourcePageObserver: (@Sendable (Int) async -> Void)? = nil
  ) {
    self.service = service
    self.invoker = invoker
    self.provider = provider
    self.model = model
    self.reconciliationNow = reconciliationNow
    self.sourcePageObserver = sourcePageObserver
  }

  /// One-shot entry point (the CLI): creates the pending notebook and runs it
  /// to completion.
  public func translateNotebook(
    sourceNotebookId: NotebookID,
    targetLanguage: String,
    title: String? = nil
  ) async throws -> Notebook {
    let pending = try service.startNotebookTranslation(
      sourceNotebookId: sourceNotebookId,
      targetLanguage: targetLanguage,
      title: title
    )
    return try await run(translationNotebookId: pending.notebookId)
  }

  /// Processes at most one bounded, durable translation chunk. Each source
  /// output is committed before the next provider call; continuation progress
  /// lives in notebook metadata and can be resumed by a later outbox lease.
  public func runChunk(
    translationNotebookId: NotebookID,
    originatingActionId: AutoActionID? = NoteService.manualTranslationActionId
  ) async throws -> AITranslationChunkResult {
    let notebook = try service.getNotebook(translationNotebookId)
    guard let state = NoteService.translationState(of: notebook) else {
      throw NoteServiceError.invalidInput(
        "notebook is not a translation notebook: \(translationNotebookId)"
      )
    }
    guard state.status != .completed, state.status != .cancelled else {
      return .completed(notebook)
    }
    let snapshot = try translationRunSnapshot(
      sourceNotebookId: state.sourceNotebookId,
      translationNotebookId: translationNotebookId,
      continuationSourceNoteId: state.continuationSourceNoteId,
      sourceNotebookRevision: state.sourceNotebookRevision
    )
    if let sourcePageObserver {
      await sourcePageObserver(snapshot.sourceNotes.count)
    }
    let deadline = reconciliationNow() + AITranslationReconciliationLimits.maximumElapsed
    var providerInvocations = 0
    var continuationSourceNoteId = snapshot.restartRequired ? nil : state.continuationSourceNoteId
    var sourceSetChangedDuringPage = false

    func requireDeadline() throws {
      guard reconciliationNow() < deadline else {
        throw AgentInvocationError.failed("translation source set did not converge within the reconciliation budget")
      }
    }

    for note in snapshot.sourceNotes {
      let sourceContentHash = NoteService.translationSourceContentHash(note.bodyMarkdown)
      guard snapshot.translatedSourceOutputCounts[note.noteId] != 1
        || snapshot.translatedSourceContentHashes[note.noteId, default: []] != Set([sourceContentHash])
      else {
        continuationSourceNoteId = note.noteId
        continue
      }
      guard providerInvocations < AITranslationReconciliationLimits.maximumProviderInvocations else {
        break
      }
      try requireDeadline()
      providerInvocations += 1
      let translated = try await translate(bodyMarkdown: note.bodyMarkdown, targetLanguage: state.targetLanguage)
      try requireDeadline()
      let outputMatchesCurrentSource = try service.createTranslationOutputIfSourceCurrent(
        translationNotebookId: translationNotebookId,
        sourceNotebookId: snapshot.sourceNotebookId,
        sourceNoteId: note.noteId,
        expectedLibraryId: snapshot.libraryId,
        expectedSourceContentHash: sourceContentHash,
        bodyMarkdown: translated,
        originatingActionId: originatingActionId
      )
      guard outputMatchesCurrentSource else {
        // Source timestamps are intentionally not relied on for this branch:
        // several edits can share a clock tick. A failed content-hash write
        // always restarts the next bounded page from the beginning.
        sourceSetChangedDuringPage = true
        continuationSourceNoteId = nil
        break
      }
      continuationSourceNoteId = note.noteId
    }
    try requireDeadline()
    if !sourceSetChangedDuringPage,
      snapshot.reachedEndOfSources,
      let completed = try service.completeNotebookTranslationIfSourceSnapshotCurrent(
        translationNotebookId,
        expectedSourceNotebookId: snapshot.sourceNotebookId,
        expectedLibraryId: snapshot.libraryId,
        expectedSourceNotebookRevision: snapshot.sourceNotebookRevision,
        expectedLastSourceNote: snapshot.completionTailSourceNote.map {
          (noteId: $0.noteId, noteNumber: $0.noteNumber)
        }
      ) {
      return .completed(completed)
    }
    let pending = try service.setNotebookTranslationContinuation(
      translationNotebookId,
      sourceNoteId: snapshot.reachedEndOfSources ? nil : continuationSourceNoteId,
      expectedSourceNotebookId: snapshot.sourceNotebookId,
      expectedLibraryId: snapshot.libraryId,
      expectedSourceNotebookRevision: snapshot.sourceNotebookRevision
    )
    let continuationRevision = NoteService.translationState(of: pending)?.sourceNotebookRevision
    return .pending(
      pending,
      reconciliationRequired: snapshot.restartRequired
        || sourceSetChangedDuringPage
        || continuationRevision.map {
          NoteService.translationSourceRevisionAdvanced($0, beyond: snapshot.sourceNotebookRevision)
        } == true
    )
  }

  // MARK: - Prompt

  static func systemPrompt(targetLanguage: String) -> String {
    """
    You are a professional translator for a note-taking system. Translate the \
    user's markdown document into \(targetLanguage).
    - Preserve the markdown structure exactly: headings, lists, tables, links, \
    images, and code blocks stay where they are.
    - Never translate code blocks, inline code, URLs, or file paths.
    - Keep proper nouns that are conventionally left untranslated.
    - Reply with ONLY the translated markdown document: no preamble, no \
    explanations, no code fence around the document.
    """
  }

  /// Strips a single code fence wrapping the whole reply (a common model
  /// habit) while leaving documents that legitimately contain fences alone.
  static func normalizedReply(_ reply: String) -> String {
    let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
    var lines = trimmed.components(separatedBy: "\n")
    guard lines.count >= 2,
      lines[0].hasPrefix("```"),
      lines[lines.count - 1] == "```"
    else {
      return trimmed
    }
    lines.removeFirst()
    lines.removeLast()
    guard !lines.contains(where: { $0.hasPrefix("```") }) else {
      return trimmed
    }
    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: - Internals

  private func translate(
    bodyMarkdown: String,
    targetLanguage: String
  ) async throws -> String {
    guard !bodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return bodyMarkdown
    }
    let request = AgentInvocationRequest(
      purpose: .translation,
      systemPrompt: Self.systemPrompt(targetLanguage: targetLanguage),
      turns: [AgentInvocationTurn(role: .user, markdown: Self.capped(bodyMarkdown))],
      contextMarkdown: nil,
      provider: provider,
      model: model
    )
    try await service.admitAutoActionProviderInvocation()
    let reply = try await invoker.invoke(request)
    try AgentReplyOutputLimits.validateFinalReply(reply.markdown)
    let normalized = Self.normalizedReply(reply.markdown)
    guard !normalized.isEmpty else {
      throw AgentInvocationError.failed("translation reply is empty")
    }
    return normalized
  }

  private func translationRunSnapshot(
    sourceNotebookId: NotebookID,
    translationNotebookId: NotebookID,
    continuationSourceNoteId: NoteID?,
    sourceNotebookRevision: Int64?
  ) throws -> TranslationRunSnapshot {
    try service.driver.withDatabase { database in
      try database.transaction { db in
        let source = try service.requireNotebook(sourceNotebookId, in: db)
        let translation = try service.requireNotebook(translationNotebookId, in: db)
        guard source.libraryId == translation.libraryId else {
          throw NoteServiceError.conflict(
            "translation source and destination libraries no longer match"
          )
        }
        let sourceRevision = try NoteService.translationSourceRevision(
          notebookId: sourceNotebookId,
          in: db
        )
        let restartRequired = sourceNotebookRevision.map {
          NoteService.translationSourceRevisionAdvanced(sourceRevision, beyond: $0)
        } ?? false
        let pageCursor = restartRequired ? nil : continuationSourceNoteId
        var cursorNoteNumber: Int?
        var sourceBindings: [SQLiteValue] = [.id(sourceNotebookId)]
        var sourcePredicate = ""
        if let pageCursor {
          let cursorRows = try db.query(
            "SELECT note_number FROM notes WHERE notebook_id = ? AND note_id = ? LIMIT 1",
            bindings: [.id(sourceNotebookId), .id(pageCursor)]
          )
          guard let cursorRow = cursorRows.first,
            let foundCursorNoteNumber = Int(cursorRow.string("note_number"))
          else {
            throw NoteServiceError.conflict("translation source cursor is no longer current")
          }
          cursorNoteNumber = foundCursorNoteNumber
          sourcePredicate = " AND (note_number > ? OR (note_number = ? AND note_id > ?))"
          sourceBindings.append(.int(Int64(foundCursorNoteNumber)))
          sourceBindings.append(.int(Int64(foundCursorNoteNumber)))
          sourceBindings.append(.id(pageCursor))
        }
        sourceBindings.append(.int(Int64(AITranslationReconciliationLimits.maximumProviderInvocations)))
        let sourceNotes = try db.query(
          """
          SELECT note_id, note_number, body_markdown
          FROM notes
          WHERE notebook_id = ?\(sourcePredicate)
          ORDER BY note_number, note_id
          LIMIT ?
          """,
          bindings: sourceBindings
        ).map { row -> TranslationSourceNote in
          guard let noteId = row.identifier("note_id", as: NoteID.self),
            let noteNumber = Int(row.string("note_number")),
            let bodyMarkdown = row["body_markdown"]
          else {
            throw NoteServiceError.invalidRow("translation source row is missing required fields")
          }
          return TranslationSourceNote(
            noteId: noteId,
            noteNumber: noteNumber,
            bodyMarkdown: bodyMarkdown
          )
        }
        var translatedSourceContentHashes: [NoteID: Set<String>] = [:]
        var translatedSourceOutputCounts: [NoteID: Int] = [:]
        let placeholders = Array(repeating: "?", count: sourceNotes.count).joined(separator: ", ")
        var outputBindings: [SQLiteValue] = [.id(translationNotebookId)]
        outputBindings.append(contentsOf: sourceNotes.map { .id($0.noteId) })
        let outputRows = sourceNotes.isEmpty ? [] : try db.query(
          """
          SELECT json_extract(meta_json, '$.kaibaTranslation.sourceNoteId') AS source_note_id,
            json_extract(meta_json, '$.kaibaTranslation.sourceContentHash') AS source_content_hash
          FROM notes
          WHERE notebook_id = ?
            AND json_extract(meta_json, '$.kaibaTranslation.sourceNoteId') IN (\(placeholders))
          """,
          bindings: outputBindings
        )
        for row in outputRows {
          guard let sourceNoteId = row.identifier("source_note_id", as: NoteID.self) else {
            continue
          }
          translatedSourceOutputCounts[sourceNoteId, default: 0] += 1
          if let sourceContentHash = row["source_content_hash"] {
            translatedSourceContentHashes[sourceNoteId, default: []].insert(sourceContentHash)
          }
        }
        let completionTailSourceNote: TranslationSourceNote?
        if let lastSourceNote = sourceNotes.last {
          completionTailSourceNote = lastSourceNote
        } else if let pageCursor, let cursorNoteNumber {
          completionTailSourceNote = TranslationSourceNote(
            noteId: pageCursor,
            noteNumber: cursorNoteNumber,
            bodyMarkdown: ""
          )
        } else {
          completionTailSourceNote = nil
        }
        return TranslationRunSnapshot(
          sourceNotebookId: sourceNotebookId,
          libraryId: source.libraryId,
          sourceNotes: sourceNotes,
          sourceNotebookRevision: sourceRevision,
          restartRequired: restartRequired,
          reachedEndOfSources: sourceNotes.count < AITranslationReconciliationLimits.maximumProviderInvocations,
          completionTailSourceNote: completionTailSourceNote,
          translatedSourceContentHashes: translatedSourceContentHashes,
          translatedSourceOutputCounts: translatedSourceOutputCounts
        )
      }
    }
  }

  private static func capped(_ markdown: String) -> String {
    guard markdown.utf8.count > maximumNoteBytes else {
      return markdown
    }
    return String(markdown.prefix(maximumNoteBytes))
  }
}
