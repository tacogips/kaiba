import Foundation

/// Runs a translation job against the agent seam. One invocation per source
/// note keeps every prompt bounded; notes whose stored translation already
/// matches the current source text are skipped, so an outbox retry resumes
/// where the failed attempt stopped instead of re-translating (and re-paying
/// for) finished pages. A job completes only after a full pass during which
/// the notebook revision did not move, so notes added or edited while a
/// provider is running are included before the job becomes final.
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

  /// One-shot entry point (the CLI): creates the job and runs it to completion.
  public func translateNotebook(
    notebookId: NotebookID,
    targetLanguage: String,
    pageStart: Int? = nil,
    pageEnd: Int? = nil
  ) async throws -> TranslationJob {
    let job = try service.startTranslationJob(
      notebookId: notebookId, targetLanguage: targetLanguage, pageStart: pageStart, pageEnd: pageEnd
    )
    return try await run(jobId: job.jobId)
  }

  /// Processes at most one bounded, durable chunk. Each translation is
  /// committed before the next provider call; the cursor and pass revision
  /// live on the job and can be resumed by a later outbox lease.
  public func runChunk(jobId: TranslationJobID) async throws -> AITranslationChunkResult {
    let job = try service.getTranslationJob(jobId)
    guard job.status == .pending || job.status == .failed else {
      return .completed(job)
    }
    if job.status == .failed {
      try service.setTranslationJobStatus(jobId, status: .pending)
    }
    let snapshot = try translationRunSnapshot(job: try service.getTranslationJob(jobId))
    if let sourcePageObserver {
      await sourcePageObserver(snapshot.sourceNotes.count)
    }
    let deadline = reconciliationNow() + AITranslationReconciliationLimits.maximumElapsed
    var providerInvocations = 0
    var cursor = snapshot.restarted ? nil : job.continuationNoteId
    var sourceChanged = false
    var reachedEnd = snapshot.reachedEndOfSources

    func requireDeadline() throws {
      guard reconciliationNow() < deadline else {
        throw AgentInvocationError.failed("translation source set did not converge within the reconciliation budget")
      }
    }

    for note in snapshot.sourceNotes {
      let sourceContentHash = NoteService.translationSourceContentHash(note.text)
      // Blank pages (or pages whose OCR is still pending) have nothing to
      // translate; a current translation needs no new provider call.
      guard !note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            note.existingSourceContentHash != sourceContentHash else {
        cursor = note.noteId
        continue
      }
      guard providerInvocations < AITranslationReconciliationLimits.maximumProviderInvocations else {
        reachedEnd = false
        break
      }
      try requireDeadline()
      providerInvocations += 1
      let translated = try await translate(bodyMarkdown: note.text, targetLanguage: job.targetLanguage)
      try requireDeadline()
      guard try service.storeNoteTranslationIfSourceCurrent(
        jobId: jobId,
        noteId: note.noteId,
        expectedSourceContentHash: sourceContentHash,
        body: translated
      ) else {
        // Several edits can share a clock tick, so a failed hash comparison
        // always restarts the pass instead of trusting timestamps.
        sourceChanged = true
        break
      }
      cursor = note.noteId
    }
    try requireDeadline()
    let advanced = try service.advanceTranslationJob(
      jobId,
      passRevision: snapshot.passRevision,
      cursor: cursor,
      reachedEnd: reachedEnd,
      sourceChanged: sourceChanged
    )
    if advanced.job.status == .completed {
      return .completed(advanced.job)
    }
    return .pending(advanced.job, reconciliationRequired: snapshot.restarted || advanced.restarted)
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

  /// Reads the next chunk of the current pass. A pass begins with the
  /// notebook revision captured on the job; when that revision has moved the
  /// pass restarts from the first note.
  private func translationRunSnapshot(job: TranslationJob) throws -> TranslationRunSnapshot {
    try service.driver.withDatabase { database in
      try database.transaction { db in
        _ = try service.requireNotebook(job.notebookId, in: db)
        let revision = try NoteService.notebookRevision(job.notebookId, in: db)
        let restarted = job.sourceRevision.map { $0 != revision } ?? false
        let cursorNoteId = restarted ? nil : job.continuationNoteId
        var predicate = ""
        var bindings: [SQLiteValue] = [.text(job.targetLanguage), .id(job.notebookId)]
        if let start = job.pageStart, let end = job.pageEnd {
          predicate += " AND n.note_number BETWEEN ? AND ?"
          bindings += [.int(Int64(start)), .int(Int64(end))]
        }
        if let cursorNoteId,
           let cursorNumber = try db.query(
             "SELECT note_number FROM notes WHERE note_id = ? AND notebook_id = ? LIMIT 1",
             bindings: [.id(cursorNoteId), .id(job.notebookId)]
           ).first?["note_number"].flatMap(Int64.init) {
          predicate += " AND (n.note_number > ? OR (n.note_number = ? AND n.note_id > ?))"
          bindings += [.int(cursorNumber), .int(cursorNumber), .id(cursorNoteId)]
        }
        bindings.append(.int(Int64(AITranslationReconciliationLimits.maximumProviderInvocations)))
        let sourceNotes = try db.query(
          """
          SELECT n.note_id, n.body_markdown, page.text AS page_text, t.source_sha256
          FROM notes n
          LEFT JOIN document_pages page ON page.note_id = n.note_id
          LEFT JOIN note_translations t ON t.note_id = n.note_id AND t.language = ?
          WHERE n.notebook_id = ?\(predicate)
          ORDER BY n.note_number, n.note_id
          LIMIT ?
          """,
          bindings: bindings
        ).map { row -> TranslationSourceNote in
          guard let noteId = row.identifier("note_id", as: NoteID.self),
                let bodyMarkdown = row["body_markdown"] else {
            throw NoteServiceError.invalidRow("translation source row is missing required fields")
          }
          return TranslationSourceNote(
            noteId: noteId,
            text: noteRetrievalText(bodyMarkdown: bodyMarkdown, pageText: row["page_text"]),
            existingSourceContentHash: row["source_sha256"]
          )
        }
        return TranslationRunSnapshot(
          passRevision: revision,
          restarted: restarted,
          sourceNotes: sourceNotes,
          reachedEndOfSources: sourceNotes.count < AITranslationReconciliationLimits.maximumProviderInvocations
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
