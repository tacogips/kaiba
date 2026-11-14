import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Note translation (`design-docs/specs/note-store-schema-v25.md`). A
/// translation is the Translated version of a note: one `note_translations`
/// row per source note and language, replaced in place when the source text
/// changes. A request is a `translation_jobs` row; the run
/// (`AITranslationService`) walks the job's notes in bounded chunks and keeps
/// its cursor and source revision on the job, so an outbox retry resumes
/// where the previous attempt stopped.

public extension NoteService {
  static let manualTranslationActionId = AutoActionID("manual-notebook-translation")

  /// Creates a pending translation job for a notebook. The run itself happens
  /// in `AITranslationService`, synchronously from the CLI or via the
  /// `notebook-translation` auto-action dispatch.
  @discardableResult
  func startTranslationJob(
    notebookId: NotebookID,
    targetLanguage: String,
    pageStart: Int? = nil,
    pageEnd: Int? = nil
  ) throws -> TranslationJob {
    switch (pageStart, pageEnd) {
    case (nil, nil): break
    case let (.some(start), .some(end)) where start > 0 && end >= start: break
    default: throw NoteServiceError.invalidInput("translation page range must be positive and inclusive")
    }
    let language = targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !language.isEmpty else {
      throw NoteServiceError.invalidInput("translation target language must not be empty")
    }
    return try driver.withDatabase { database in
      try database.transaction { db in
        try requireEnabledActingUser(in: db)
        _ = try requireNotebook(notebookId, in: db)
        try requireNotebookOwnership(notebookId, subject: notebookId.rawValue, in: db)
        let last = try db.query(
          "SELECT MAX(note_number) AS last FROM notes WHERE notebook_id = ?",
          bindings: [.id(notebookId)]
        ).first?["last"].flatMap(Int.init)
        guard let last else {
          throw NoteServiceError.invalidInput("source notebook has no notes to translate: \(notebookId)")
        }
        if let pageEnd, pageEnd > last {
          throw NoteServiceError.invalidInput("translation page range exceeds the source document")
        }
        let jobId = TranslationJobID.generate()
        let now = NoteStoreClock.system.now()
        try db.execute(
          """
          INSERT INTO translation_jobs (
            job_id, notebook_id, target_language, page_start, page_end, status,
            requested_by, created_at, updated_at
          ) VALUES (?, ?, ?, ?, ?, 'pending', (SELECT user_id FROM users WHERE user_id = ?), ?, ?)
          """,
          bindings: [
            .id(jobId), .id(notebookId), .text(language),
            pageStart.map { .int(Int64($0)) } ?? .null,
            pageEnd.map { .int(Int64($0)) } ?? .null,
            .id(writeOwnerUserId()), .text(now), .text(now)
          ]
        )
        return try requireTranslationJob(jobId, in: db)
      }
    }
  }

  /// Queues an async translation run (the reader's translate action and the
  /// GraphQL `requestNotebookTranslation` mutation). Returns `(nil, false)`
  /// without creating anything when no dispatcher is installed (agent
  /// unavailable), so no pending job is ever left with nothing to drain it.
  func requestNotebookTranslation(
    notebookId: NotebookID,
    targetLanguage: String,
    pageStart: Int? = nil,
    pageEnd: Int? = nil
  ) throws -> (job: TranslationJob?, queued: Bool) {
    _ = try getNotebook(notebookId)
    guard autoActionDispatcher != nil else {
      return (nil, false)
    }
    let job = try startTranslationJob(
      notebookId: notebookId, targetLanguage: targetLanguage, pageStart: pageStart, pageEnd: pageEnd
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
    var event = makeAutoActionEvent(trigger: .notebookCreated, notebookId: notebookId)
    event.translationJobId = job.jobId
    let queued = try driver.withDatabase { database in
      try database.transaction { db in
        try enqueueManualAutoActionDispatch(action: action, event: event, in: db)
      }
    }
    dispatchQueuedAutoActions([queued])
    return (job, true)
  }

  func getTranslationJob(_ jobId: TranslationJobID) throws -> TranslationJob {
    try driver.withDatabase { db in
      let job = try requireTranslationJob(jobId, in: db)
      _ = try requireNotebook(job.notebookId, in: db)
      return job
    }
  }

  /// Jobs of one notebook, newest first.
  func translationJobs(notebookId: NotebookID) throws -> [TranslationJob] {
    try driver.withDatabase { db in
      _ = try requireNotebook(notebookId, in: db)
      return try db.query(
        "\(translationJobSelect) WHERE notebook_id = ? ORDER BY created_at DESC, job_id",
        bindings: [.id(notebookId)]
      ).map(translationJob(from:))
    }
  }

  /// The Translated versions of a note, one per language, each flagged with
  /// whether it still matches the current source text.
  func noteTranslations(noteId: NoteID) throws -> [NoteTranslation] {
    try driver.withDatabase { db in
      let note = try requireNote(noteId, in: db)
      let currentHash = Self.translationSourceContentHash(
        noteRetrievalText(bodyMarkdown: note.bodyMarkdown, pageText: try storedDocumentPageText(noteId, in: db))
      )
      return try db.query(
        """
        SELECT note_id, language, body, source_sha256, updated_at
        FROM note_translations WHERE note_id = ? ORDER BY language
        """,
        bindings: [.id(noteId)]
      ).map { row in
        guard let language = row["language"], let body = row["body"], let updatedAt = row["updated_at"] else {
          throw NoteServiceError.invalidRow("translation row is missing required fields")
        }
        return NoteTranslation(
          noteId: noteId, language: language, body: body,
          isCurrent: row["source_sha256"] == currentHash, updatedAt: updatedAt
        )
      }
    }
  }

  /// Sets a terminal (or pending) status. Leaving `pending` clears the cursor.
  @discardableResult
  func setTranslationJobStatus(
    _ jobId: TranslationJobID,
    status: TranslationJobStatus,
    errorMessage: String? = nil
  ) throws -> TranslationJob {
    let job = try driver.withDatabase { database in
      try database.transaction { db -> TranslationJob in
        try requireEnabledActingUser(in: db)
        _ = try requireTranslationJob(jobId, in: db)
        try db.execute(
          """
          UPDATE translation_jobs
          SET status = ?, error_message = ?, updated_at = ?,
            continuation_note_id = CASE WHEN ? = 'pending' THEN continuation_note_id END,
            source_revision = CASE WHEN ? = 'pending' THEN source_revision END
          WHERE job_id = ?
          """,
          bindings: [
            .text(status.rawValue), .optionalText(errorMessage), .text(NoteStoreClock.system.now()),
            .text(status.rawValue), .text(status.rawValue), .id(jobId)
          ]
        )
        return try requireTranslationJob(jobId, in: db)
      }
    }
    publishChange(NoteChangeEvent(kind: NoteChangeEventKind.noteUpdated, notebookId: job.notebookId))
    return job
  }

  /// Persists the outcome of one bounded chunk. The job completes only when a
  /// full pass reached the end without a source change and the notebook
  /// revision still equals the one captured when the pass began; a moved
  /// revision restarts the pass from the first note.
  func advanceTranslationJob(
    _ jobId: TranslationJobID,
    passRevision: Int64,
    cursor: NoteID?,
    reachedEnd: Bool,
    sourceChanged: Bool
  ) throws -> (job: TranslationJob, restarted: Bool) {
    let result = try driver.withDatabase { database in
      try database.transaction { db -> (TranslationJob, Bool) in
        try requireEnabledActingUser(in: db)
        let job = try requireTranslationJob(jobId, in: db)
        guard job.status == .pending else {
          throw NoteServiceError.conflict("translation job is no longer pending: \(jobId)")
        }
        let revision = try Self.notebookRevision(job.notebookId, in: db)
        let restarted = sourceChanged || revision != passRevision
        let now = NoteStoreClock.system.now()
        if reachedEnd, !restarted {
          try db.execute(
            """
            UPDATE translation_jobs
            SET status = 'completed', error_message = NULL, continuation_note_id = NULL,
              source_revision = NULL, updated_at = ?
            WHERE job_id = ?
            """,
            bindings: [.text(now), .id(jobId)]
          )
        } else {
          try db.execute(
            """
            UPDATE translation_jobs
            SET continuation_note_id = ?, source_revision = ?, error_message = NULL, updated_at = ?
            WHERE job_id = ?
            """,
            bindings: [
              restarted || reachedEnd ? .null : cursor.map(SQLiteValue.id) ?? .null,
              .int(restarted ? revision : passRevision),
              .text(now), .id(jobId)
            ]
          )
        }
        return (try requireTranslationJob(jobId, in: db), restarted)
      }
    }
    publishChange(NoteChangeEvent(kind: NoteChangeEventKind.noteUpdated, notebookId: result.0.notebookId))
    return (result.0, result.1)
  }

  /// Stores one translation only while the source text still hashes to the
  /// snapshot the provider translated, so a concurrent edit is never
  /// represented as current. Returns false when the source changed or is gone.
  func storeNoteTranslationIfSourceCurrent(
    jobId: TranslationJobID,
    noteId: NoteID,
    expectedSourceContentHash: String,
    body: String
  ) throws -> Bool {
    let stored = try driver.withDatabase { database in
      try database.transaction { db -> NoteTranslation? in
        try requireEnabledActingUser(in: db)
        let job = try requireTranslationJob(jobId, in: db)
        guard job.status == .pending else {
          throw NoteServiceError.conflict("translation job is no longer pending: \(jobId)")
        }
        guard let source = try? loadNote(noteId, in: db), source.notebookId == job.notebookId,
              Self.translationSourceContentHash(
                noteRetrievalText(bodyMarkdown: source.bodyMarkdown, pageText: try storedDocumentPageText(noteId, in: db))
              ) == expectedSourceContentHash else {
          return nil
        }
        let previous = try ftsPayload(noteId: noteId, in: db)
        let now = NoteStoreClock.system.now()
        try db.execute(
          """
          INSERT INTO note_translations (
            note_id, language, body, source_sha256, provenance, created_by, created_at, updated_at
          ) VALUES (?, ?, ?, ?, 'ai', (SELECT user_id FROM users WHERE user_id = ?), ?, ?)
          ON CONFLICT(note_id, language) DO UPDATE SET
            body = excluded.body, source_sha256 = excluded.source_sha256,
            provenance = excluded.provenance, updated_at = excluded.updated_at
          """,
          bindings: [
            .id(noteId), .text(job.targetLanguage), .text(body), .text(expectedSourceContentHash),
            .id(writeOwnerUserId()), .text(now), .text(now)
          ]
        )
        try db.execute(
          "UPDATE translation_jobs SET updated_at = ? WHERE job_id = ?",
          bindings: [.text(now), .id(jobId)]
        )
        try refreshFTS(noteId: noteId, previous: previous, in: db)
        return NoteTranslation(
          noteId: noteId, language: job.targetLanguage, body: body, isCurrent: true, updatedAt: now
        )
      }
    }
    guard let stored else { return false }
    publishChange(NoteChangeEvent(kind: NoteChangeEventKind.noteUpdated, notebookId: try getNote(noteId).notebookId))
    try translationOutputPostCommitHook?(stored)
    return true
  }

  static func translationSourceContentHash(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  /// The notebook's content revision (`notebook_revisions`), 0 before the
  /// first recorded change.
  static func notebookRevision(_ notebookId: NotebookID, in database: SQLiteDatabase) throws -> Int64 {
    try database.query(
      "SELECT revision FROM notebook_revisions WHERE notebook_id = ? LIMIT 1",
      bindings: [.id(notebookId)]
    ).first?["revision"].flatMap(Int64.init) ?? 0
  }
}

extension NoteService {
  func requireTranslationJob(_ jobId: TranslationJobID, in database: SQLiteDatabase) throws -> TranslationJob {
    guard let row = try database.query(
      "\(translationJobSelect) WHERE job_id = ? LIMIT 1",
      bindings: [.id(jobId)]
    ).first else {
      throw NoteServiceError.notFound("translation job not found: \(jobId)")
    }
    return try translationJob(from: row)
  }
}

private let translationJobSelect = """
  SELECT job_id, notebook_id, target_language, page_start, page_end, status, error_message,
    continuation_note_id, source_revision, created_at, updated_at
  FROM translation_jobs
  """

private func translationJob(from row: SQLiteRow) throws -> TranslationJob {
  guard let jobId = row.identifier("job_id", as: TranslationJobID.self),
        let notebookId = row.identifier("notebook_id", as: NotebookID.self),
        let targetLanguage = row["target_language"],
        let status = row["status"].flatMap(TranslationJobStatus.init(rawValue:)),
        let createdAt = row["created_at"],
        let updatedAt = row["updated_at"] else {
    throw NoteServiceError.invalidRow("translation job row is missing required fields")
  }
  return TranslationJob(
    jobId: jobId,
    notebookId: notebookId,
    targetLanguage: targetLanguage,
    pageStart: row["page_start"].flatMap(Int.init),
    pageEnd: row["page_end"].flatMap(Int.init),
    status: status,
    errorMessage: row["error_message"],
    continuationNoteId: row.identifier("continuation_note_id", as: NoteID.self) ?? nil,
    sourceRevision: row["source_revision"].flatMap(Int64.init),
    createdAt: createdAt,
    updatedAt: updatedAt
  )
}
