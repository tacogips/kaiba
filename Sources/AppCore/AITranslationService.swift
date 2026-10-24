import Foundation

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
        if let state = NoteService.translationState(of: translation),
          let start = state.pageStart, let end = state.pageEnd {
          sourcePredicate = " AND note_number BETWEEN ? AND ?"
          sourceBindings += [.int(Int64(start)), .int(Int64(end))]
        }
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
          sourcePredicate += " AND (note_number > ? OR (note_number = ? AND note_id > ?))"
          sourceBindings.append(.int(Int64(foundCursorNoteNumber)))
          sourceBindings.append(.int(Int64(foundCursorNoteNumber)))
          sourceBindings.append(.id(pageCursor))
        }
        sourceBindings.append(.int(Int64(AITranslationReconciliationLimits.maximumProviderInvocations)))
        let sourceNotes = try db.query(
          """
          SELECT note_id, note_number, body_markdown, search_text
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
            bodyMarkdown: noteRetrievalText(bodyMarkdown: bodyMarkdown, searchText: row["search_text"])
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
