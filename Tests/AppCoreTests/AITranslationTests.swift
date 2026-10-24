import Foundation
@testable import AppCore
import XCTest

/// Echoes the last user turn with a prefix so tests can assert per-note
/// translation without a real agent; optionally fails on selected calls to
/// exercise the resume path.
private final class RecordingTranslationInvoker: AgentInvoking, @unchecked Sendable {
  private let lock = NSLock()
  private(set) var requests: [AgentInvocationRequest] = []
  var failOnCallIndices: Set<Int>
  var reply: (String) -> String
  var onInvoke: ((AgentInvocationRequest) throws -> Void)?

  init(
    failOnCallIndices: Set<Int> = [],
    reply: @escaping (String) -> String = { "translated: \($0)" },
    onInvoke: ((AgentInvocationRequest) throws -> Void)? = nil
  ) {
    self.failOnCallIndices = failOnCallIndices
    self.reply = reply
    self.onInvoke = onInvoke
  }

  private func record(_ request: AgentInvocationRequest) -> Int {
    lock.lock()
    defer { lock.unlock() }
    let index = requests.count
    requests.append(request)
    return index
  }

  func invoke(_ request: AgentInvocationRequest) async throws -> AgentInvocationResult {
    let index = record(request)
    try onInvoke?(request)
    if failOnCallIndices.contains(index) {
      throw AgentInvocationError.failed("stub translation failure")
    }
    return AgentInvocationResult(markdown: reply(request.turns.last?.markdown ?? ""))
  }
}

private final class ManualTranslationReconciliationClock: @unchecked Sendable {
  private let lock = NSLock()
  private let origin = ContinuousClock().now
  private var elapsed = Duration.zero

  func now() -> ContinuousClock.Instant {
    lock.withLock { origin.advanced(by: elapsed) }
  }

  func advance(by duration: Duration) {
    lock.withLock {
      elapsed += duration
    }
  }
}

private actor TranslationSourcePageRecorder {
  private var pageSizes: [Int] = []

  func record(_ pageSize: Int) {
    pageSizes.append(pageSize)
  }

  func values() -> [Int] {
    pageSizes
  }
}

final class AITranslationTests: NoteTestCase {
  func testStartTranslationJobCreatesPendingJob() throws {
    let service = try makeService()
    let ingest = try service.createNotebookWithNotes(
      title: "Guide",
      pages: [
        NotePageDraft(bodyMarkdown: "# One\nBody."),
        NotePageDraft(bodyMarkdown: "# Two\nText.")
      ]
    )
    let notebooksBefore = try service.listNotebooks().count
    let job = try service.startTranslationJob(
      notebookId: ingest.notebook.notebookId,
      targetLanguage: "  English "
    )
    XCTAssertEqual(job.notebookId, ingest.notebook.notebookId)
    XCTAssertEqual(job.targetLanguage, "English")
    XCTAssertEqual(job.status, .pending)
    XCTAssertNil(job.pageStart)
    XCTAssertNil(job.pageEnd)
    XCTAssertNil(job.errorMessage)
    XCTAssertNil(job.continuationNoteId)
    XCTAssertEqual(try service.translationJobs(notebookId: ingest.notebook.notebookId), [job])
    // A translation is a version of the source notes, never a new notebook.
    XCTAssertEqual(try service.listNotebooks().count, notebooksBefore)
  }

  func testStartTranslationJobRejectsEmptySourceOrLanguage() throws {
    let service = try makeService()
    let empty = try service.createNotebook(title: "Empty")
    XCTAssertThrowsError(try service.startTranslationJob(
      notebookId: empty.notebookId,
      targetLanguage: "English"
    ))
    let ingest = try service.createNotebookWithNotes(
      title: "Guide",
      pages: [NotePageDraft(bodyMarkdown: "# One\nBody.")]
    )
    XCTAssertThrowsError(try service.startTranslationJob(
      notebookId: ingest.notebook.notebookId,
      targetLanguage: "   "
    ))
    XCTAssertTrue(try service.translationJobs(notebookId: ingest.notebook.notebookId).isEmpty)
  }

  func testTranslationsStayInTheProtectedSourceLibrary() async throws {
    let service = try makeService()
    let protectedLibrary = try service.createLibrary(
      name: "protected-translation-source",
      authRequired: true
    )
    let protectedService = service.scoped(toLibrary: protectedLibrary.libraryId)
    let source = try protectedService.createNotebookWithNotes(
      title: "Protected guide",
      pages: [NotePageDraft(bodyMarkdown: "# Protected\nDo not publish.")]
    )
    let job = try await AITranslationService(
      service: protectedService,
      invoker: RecordingTranslationInvoker()
    ).translateNotebook(notebookId: source.notebook.notebookId, targetLanguage: "English")
    XCTAssertEqual(job.status, .completed)
    XCTAssertEqual(
      try protectedService.noteTranslations(noteId: source.notes[0].noteId).map(\.body),
      ["translated: # Protected\nDo not publish."]
    )

    let unauthenticated = service.scoped(to: NoteStoreSchema.defaultUserId).unauthenticated()
    XCTAssertThrowsError(try unauthenticated.noteTranslations(noteId: source.notes[0].noteId)) { error in
      guard case .notFound = error as? NoteServiceError else {
        return XCTFail("expected protected translations to be notFound, got \(error)")
      }
    }
    XCTAssertThrowsError(try unauthenticated.getTranslationJob(job.jobId)) { error in
      guard case .notFound = error as? NoteServiceError else {
        return XCTFail("expected protected translation job to be notFound, got \(error)")
      }
    }
  }

  func testTranslateNotebookStoresOneTranslationPerNoteInOrder() async throws {
    let service = try makeService()
    let ingest = try service.createNotebookWithNotes(
      title: "Guide",
      pages: [
        NotePageDraft(bodyMarkdown: "# One\nBody."),
        NotePageDraft(bodyMarkdown: "# Two\nText.")
      ]
    )
    let invoker = RecordingTranslationInvoker()
    let translation = AITranslationService(
      service: service,
      invoker: invoker,
      provider: "openrouter",
      model: "test-model"
    )
    let job = try await translation.translateNotebook(
      notebookId: ingest.notebook.notebookId,
      targetLanguage: "English"
    )
    XCTAssertEqual(job.status, .completed)
    XCTAssertNil(job.continuationNoteId)
    XCTAssertNil(job.sourceRevision)
    let translations = try ingest.notes.map { try service.noteTranslations(noteId: $0.noteId) }
    XCTAssertEqual(translations.map { $0.map(\.body) }, [
      ["translated: # One\nBody."],
      ["translated: # Two\nText."]
    ])
    XCTAssertEqual(translations.flatMap { $0.map(\.language) }, ["English", "English"])
    XCTAssertTrue(translations.allSatisfy { $0.allSatisfy(\.isCurrent) })
    // Source notes are never edited and no output notes are created.
    XCTAssertEqual(
      try service.listNotes(notebookId: ingest.notebook.notebookId, limit: 10, offset: 0).map(\.bodyMarkdown),
      ["# One\nBody.", "# Two\nText."]
    )
    XCTAssertEqual(invoker.requests.map { $0.turns.last?.markdown }, ["# One\nBody.", "# Two\nText."])
    for request in invoker.requests {
      XCTAssertEqual(request.purpose, .translation)
      XCTAssertTrue(request.systemPrompt.contains("English"))
      XCTAssertEqual(request.provider, "openrouter")
      XCTAssertEqual(request.model, "test-model")
      XCTAssertNil(request.contextMarkdown)
    }
  }

  func testSecondLanguageAddsAVersionAndEditMarksTranslationsStale() async throws {
    let service = try makeService()
    let ingest = try service.createNotebookWithNotes(
      title: "Guide",
      pages: [NotePageDraft(bodyMarkdown: "# One\nBody.", readOnly: false)]
    )
    let translation = AITranslationService(service: service, invoker: RecordingTranslationInvoker())
    _ = try await translation.translateNotebook(notebookId: ingest.notebook.notebookId, targetLanguage: "English")
    _ = try await translation.translateNotebook(notebookId: ingest.notebook.notebookId, targetLanguage: "Japanese")
    let noteId = ingest.notes[0].noteId
    XCTAssertEqual(try service.noteTranslations(noteId: noteId).map(\.language), ["English", "Japanese"])
    XCTAssertTrue(try service.noteTranslations(noteId: noteId).allSatisfy(\.isCurrent))

    _ = try service.updateNoteBody(noteId: noteId, bodyMarkdown: "# One\nEdited.")
    XCTAssertEqual(try service.noteTranslations(noteId: noteId).map(\.isCurrent), [false, false])

    // Re-running one language replaces that version in place; the other stays stale.
    let invoker = RecordingTranslationInvoker()
    _ = try await AITranslationService(service: service, invoker: invoker)
      .translateNotebook(notebookId: ingest.notebook.notebookId, targetLanguage: "Japanese")
    XCTAssertEqual(invoker.requests.count, 1)
    let versions = try service.noteTranslations(noteId: noteId)
    XCTAssertEqual(versions.map(\.language), ["English", "Japanese"])
    XCTAssertEqual(versions.map(\.isCurrent), [false, true])
    XCTAssertEqual(versions[1].body, "translated: # One\nEdited.")
  }

  func testSearchFindsTheSourceNoteByItsTranslation() async throws {
    let service = try makeService()
    let ingest = try service.createNotebookWithNotes(
      title: "Guide",
      pages: [NotePageDraft(bodyMarkdown: "# Original\nQuelle.")]
    )
    _ = try await AITranslationService(
      service: service,
      invoker: RecordingTranslationInvoker(reply: { _ in "zebracrossing translated text" })
    ).translateNotebook(notebookId: ingest.notebook.notebookId, targetLanguage: "English")
    let hits = try service.searchNotes(query: "zebracrossing")
    XCTAssertEqual(hits.map(\.note.noteId), [ingest.notes[0].noteId])
  }

  func testDeletingSourceCascadesTranslationsAndUndoRestoresThem() async throws {
    let service = try makeService()
    let ingest = try service.createNotebookWithNotes(
      title: "Guide",
      pages: [NotePageDraft(bodyMarkdown: "# One\nBody.", readOnly: false)]
    )
    _ = try await AITranslationService(service: service, invoker: RecordingTranslationInvoker())
      .translateNotebook(notebookId: ingest.notebook.notebookId, targetLanguage: "English")
    let noteId = ingest.notes[0].noteId
    let before = try service.noteTranslations(noteId: noteId)
    XCTAssertEqual(before.count, 1)

    try service.deleteNote(noteId: noteId)
    let remaining = try service.driver.withDatabase { database in
      try database.query("SELECT COUNT(*) AS count FROM note_translations").first?["count"]
    }
    XCTAssertEqual(remaining, "0")

    _ = try XCTUnwrap(try service.undoLastAction())
    XCTAssertEqual(try service.noteTranslations(noteId: noteId), before)
    XCTAssertEqual(try service.searchNotes(query: "translated").map(\.note.noteId), [noteId])
  }

  func testRunResumesAfterFailureWithoutRetranslating() async throws {
    let service = try makeService()
    let ingest = try service.createNotebookWithNotes(
      title: "Guide",
      pages: [
        NotePageDraft(bodyMarkdown: "# One\nBody."),
        NotePageDraft(bodyMarkdown: "# Two\nText.")
      ]
    )
    let pending = try service.startTranslationJob(
      notebookId: ingest.notebook.notebookId,
      targetLanguage: "English"
    )
    do {
      _ = try await AITranslationService(
        service: service,
        invoker: RecordingTranslationInvoker(failOnCallIndices: [1])
      ).run(jobId: pending.jobId)
      XCTFail("expected the stubbed second translation call to fail")
    } catch {}
    let failed = try service.getTranslationJob(pending.jobId)
    XCTAssertEqual(failed.status, .failed)
    XCTAssertTrue(failed.errorMessage?.contains("stub translation failure") == true)
    XCTAssertEqual(try service.noteTranslations(noteId: ingest.notes[0].noteId).count, 1)
    XCTAssertTrue(try service.noteTranslations(noteId: ingest.notes[1].noteId).isEmpty)

    let resuming = RecordingTranslationInvoker()
    let job = try await AITranslationService(service: service, invoker: resuming).run(jobId: pending.jobId)
    XCTAssertEqual(job.status, .completed)
    XCTAssertNil(job.errorMessage)
    // Only the untranslated second note is translated on resume.
    XCTAssertEqual(resuming.requests.map { $0.turns.last?.markdown }, ["# Two\nText."])
    XCTAssertEqual(
      try ingest.notes.flatMap { try service.noteTranslations(noteId: $0.noteId).map(\.body) },
      ["translated: # One\nBody.", "translated: # Two\nText."]
    )
  }

  func testRunResumesAfterEarlierSourceIsDeleted() async throws {
    let service = try makeService()
    let ingest = try service.createNotebookWithNotes(
      title: "Guide",
      pages: [
        NotePageDraft(bodyMarkdown: "# One\nBody."),
        NotePageDraft(bodyMarkdown: "# Two\nText.")
      ]
    )
    let pending = try service.startTranslationJob(
      notebookId: ingest.notebook.notebookId,
      targetLanguage: "English"
    )
    do {
      _ = try await AITranslationService(
        service: service,
        invoker: RecordingTranslationInvoker(failOnCallIndices: [1])
      ).run(jobId: pending.jobId)
      XCTFail("expected the second source translation to fail")
    } catch {}

    try service.driver.withDatabase { database in
      try database.transaction { db in
        try deleteNoteRows(noteId: ingest.notes[0].noteId, in: db)
      }
    }
    let resuming = RecordingTranslationInvoker()
    let completed = try await AITranslationService(service: service, invoker: resuming).run(jobId: pending.jobId)

    XCTAssertEqual(completed.status, .completed)
    XCTAssertEqual(resuming.requests.map { $0.turns.last?.markdown }, ["# Two\nText."])
    XCTAssertEqual(
      try service.noteTranslations(noteId: ingest.notes[1].noteId).map(\.body),
      ["translated: # Two\nText."]
    )
  }

  func testRunTranslatesSourceAddedDuringProviderInvocationBeforeCompletion() async throws {
    let service = try makeService()
    let source = try service.createNotebookWithNotes(
      title: "Guide",
      pages: [NotePageDraft(bodyMarkdown: "# Initial\nBody.")]
    )
    let pending = try service.startTranslationJob(
      notebookId: source.notebook.notebookId,
      targetLanguage: "English"
    )
    let addedSourceMarkdown = "# Added during translation\nBody."
    let invoker = RecordingTranslationInvoker(onInvoke: { request in
      guard request.turns.last?.markdown == "# Initial\nBody." else {
        return
      }
      _ = try service.createNote(
        notebookId: source.notebook.notebookId,
        bodyMarkdown: addedSourceMarkdown
      )
    })

    let completed = try await AITranslationService(service: service, invoker: invoker).run(jobId: pending.jobId)

    XCTAssertEqual(completed.status, .completed)
    XCTAssertEqual(invoker.requests.count, 2)
    let notes = try service.listNotes(notebookId: source.notebook.notebookId, limit: 10, offset: 0)
    XCTAssertEqual(
      try notes.flatMap { try service.noteTranslations(noteId: $0.noteId).map(\.body) },
      ["translated: # Initial\nBody.", "translated: \(addedSourceMarkdown)"]
    )
  }

  func testRunCompletesAfterProviderDeletesSourceBeforeTranslationWrite() async throws {
    let service = try makeService()
    let source = try service.createNotebookWithNotes(
      title: "Guide",
      pages: [NotePageDraft(bodyMarkdown: "# Deleted during translation\nBody.")]
    )
    let pending = try service.startTranslationJob(
      notebookId: source.notebook.notebookId,
      targetLanguage: "English"
    )
    let invoker = RecordingTranslationInvoker(onInvoke: { request in
      guard request.turns.last?.markdown == "# Deleted during translation\nBody." else {
        return
      }
      try service.driver.withDatabase { database in
        try database.transaction { db in
          try deleteNoteRows(noteId: source.notes[0].noteId, in: db)
        }
      }
    })

    let completed = try await AITranslationService(service: service, invoker: invoker).run(jobId: pending.jobId)

    XCTAssertEqual(completed.status, .completed)
    XCTAssertEqual(invoker.requests.count, 1)
    let stored = try service.driver.withDatabase { database in
      try database.query("SELECT COUNT(*) AS count FROM note_translations").first?["count"]
    }
    XCTAssertEqual(stored, "0")
  }

  func testRunRetranslatesAChangedSourceBeforeCompletion() async throws {
    let service = try makeService()
    let source = try service.createNotebookWithNotes(
      title: "Guide",
      pages: [NotePageDraft(bodyMarkdown: "# Initial\nBody.", readOnly: false)]
    )
    let pending = try service.startTranslationJob(
      notebookId: source.notebook.notebookId,
      targetLanguage: "English"
    )
    let updatedSourceMarkdown = "# Updated during translation\nBody."
    let invoker = RecordingTranslationInvoker(onInvoke: { request in
      guard request.turns.last?.markdown == "# Initial\nBody." else {
        return
      }
      _ = try service.updateNoteBody(
        noteId: source.notes[0].noteId,
        bodyMarkdown: updatedSourceMarkdown
      )
    })

    let completed = try await AITranslationService(service: service, invoker: invoker).run(jobId: pending.jobId)

    XCTAssertEqual(completed.status, .completed)
    XCTAssertEqual(invoker.requests.map { $0.turns.last?.markdown }, [
      "# Initial\nBody.",
      updatedSourceMarkdown
    ])
    let versions = try service.noteTranslations(noteId: source.notes[0].noteId)
    XCTAssertEqual(versions.map(\.body), ["translated: \(updatedSourceMarkdown)"])
    XCTAssertEqual(versions.map(\.isCurrent), [true])
  }

  func testRunFailsWithinReconciliationBudgetWhenSourceNeverConverges() async throws {
    let service = try makeService()
    let source = try service.createNotebookWithNotes(
      title: "Churning guide",
      pages: [NotePageDraft(bodyMarkdown: "# Initial\nBody.", readOnly: false)]
    )
    let pending = try service.startTranslationJob(
      notebookId: source.notebook.notebookId,
      targetLanguage: "English"
    )
    var version = 0
    let invoker = RecordingTranslationInvoker(onInvoke: { _ in
      version += 1
      _ = try service.updateNoteBody(
        noteId: source.notes[0].noteId,
        bodyMarkdown: "# Churn \(version)\nBody."
      )
    })

    do {
      _ = try await AITranslationService(service: service, invoker: invoker).run(jobId: pending.jobId)
      XCTFail("expected repeated source churn to consume one bounded dispatch attempt")
    } catch AgentInvocationError.failed(let message) {
      XCTAssertTrue(message.contains("reconciliation budget"))
    }
    XCTAssertEqual(invoker.requests.count, AITranslationReconciliationLimits.maximumRounds)
    let job = try service.getTranslationJob(pending.jobId)
    XCTAssertEqual(job.status, .failed)
    XCTAssertTrue(job.errorMessage?.contains("reconciliation budget") == true)
  }

  func testRunStopsWhenElapsedBudgetExpiresDuringChurnReconciliation() async throws {
    let service = try makeService()
    let source = try service.createNotebookWithNotes(
      title: "Slow guide",
      pages: [NotePageDraft(bodyMarkdown: "# Initial\nBody.", readOnly: false)]
    )
    let pending = try service.startTranslationJob(
      notebookId: source.notebook.notebookId,
      targetLanguage: "English"
    )
    let clock = ManualTranslationReconciliationClock()
    let invoker = RecordingTranslationInvoker(onInvoke: { request in
      switch request.turns.last?.markdown {
      case "# Initial\nBody.":
        _ = try service.updateNoteBody(
          noteId: source.notes[0].noteId,
          bodyMarkdown: "# Changed\nBody."
        )
      case "# Changed\nBody.":
        clock.advance(by: AITranslationReconciliationLimits.maximumElapsed)
      default:
        break
      }
    })
    let translation = AITranslationService(
      service: service,
      invoker: invoker,
      reconciliationNow: { clock.now() }
    )

    do {
      _ = try await translation.run(jobId: pending.jobId)
      XCTFail("expected elapsed reconciliation budget to stop the current dispatch")
    } catch AgentInvocationError.failed(let message) {
      XCTAssertTrue(message.contains("reconciliation budget"))
    }

    XCTAssertEqual(invoker.requests.count, 2)
    XCTAssertTrue(try service.noteTranslations(noteId: source.notes[0].noteId).isEmpty)
    let job = try service.getTranslationJob(pending.jobId)
    XCTAssertEqual(job.status, .failed)
    XCTAssertTrue(job.errorMessage?.contains("reconciliation budget") == true)
  }

  func testRunTranslatesStableSourceSetBeyondReconciliationProviderLimit() async throws {
    let service = try makeService()
    let sourceCount = AITranslationReconciliationLimits.maximumProviderInvocations + 1
    let source = try service.createNotebookWithNotes(
      title: "Large stable guide",
      pages: (0..<sourceCount).map { index in
        NotePageDraft(bodyMarkdown: "# Source \(index)\nBody.")
      }
    )
    let pending = try service.startTranslationJob(
      notebookId: source.notebook.notebookId,
      targetLanguage: "English"
    )
    let invoker = RecordingTranslationInvoker()
    let pageRecorder = TranslationSourcePageRecorder()

    let completed = try await AITranslationService(
      service: service,
      invoker: invoker,
      sourcePageObserver: { pageSize in
        await pageRecorder.record(pageSize)
      }
    ).run(jobId: pending.jobId)

    XCTAssertEqual(completed.status, .completed)
    XCTAssertEqual(invoker.requests.count, sourceCount)
    let observedPageSizes = await pageRecorder.values()
    XCTAssertEqual(
      observedPageSizes,
      [AITranslationReconciliationLimits.maximumProviderInvocations, 1]
    )
    XCTAssertEqual(try storedTranslationCount(service), sourceCount)
  }

  func testQueuedStableLargeTranslationContinuesInDurableBoundedChunks() async throws {
    let driver = try makeNoteDriver()
    let invoker = RecordingTranslationInvoker()
    let dispatcher = KaibaAutoActionDispatcher(
      service: try NoteService(driver: driver),
      invoker: invoker
    )
    let service = try NoteService(driver: driver, autoActionDispatcher: dispatcher)
    let sourceCount = AITranslationReconciliationLimits.maximumProviderInvocations + 1
    let source = try service.createNotebookWithNotes(
      title: "Queued large stable guide",
      pages: (0..<sourceCount).map { index in
        NotePageDraft(bodyMarkdown: "# Queued source \(index)\nBody.")
      }
    )

    let (job, queued) = try service.requestNotebookTranslation(
      notebookId: source.notebook.notebookId,
      targetLanguage: "English"
    )
    XCTAssertTrue(queued)
    let jobId = try XCTUnwrap(job).jobId
    await service.drainAutoActionDispatches()

    let pendingJob = try service.getTranslationJob(jobId)
    XCTAssertEqual(pendingJob.status, .pending)
    XCTAssertNotNil(pendingJob.continuationNoteId)
    XCTAssertEqual(invoker.requests.count, AITranslationReconciliationLimits.maximumProviderInvocations)
    XCTAssertEqual(try service.retryPendingAutoActionDispatches(), 1)
    await service.drainAutoActionDispatches()

    XCTAssertEqual(try service.getTranslationJob(jobId).status, .completed)
    let dispatch = try XCTUnwrap(
      try service.listAutoActionDispatchAttempts().first(where: {
        $0.record.event.translationJobId == jobId
          && $0.record.action.workflowId == NoteStoreSchema.notebookTranslationWorkflowId
      })
    )
    XCTAssertEqual(dispatch.status, .dispatched)
    XCTAssertEqual(dispatch.attemptCount, 1)
    XCTAssertEqual(try service.retryPendingAutoActionDispatches(), 0)
    XCTAssertEqual(invoker.requests.count, sourceCount)
  }

  func testQueuedTranslationSourceChurnConsumesDurableRetryBudget() async throws {
    let driver = try makeNoteDriver()
    var version = 0
    let dispatcher = KaibaAutoActionDispatcher(
      service: try NoteService(driver: driver),
      invoker: RecordingTranslationInvoker(onInvoke: { _ in
        version += 1
        let source = try NoteService(driver: driver).listNotebooks().first {
          $0.title == "Queued churning guide"
        }
        let sourceNote = try XCTUnwrap(
          try NoteService(driver: driver).listNotes(
            notebookId: try XCTUnwrap(source).notebookId,
            limit: 1,
            offset: 0
          ).first
        )
        _ = try NoteService(driver: driver).updateNoteBody(
          noteId: sourceNote.noteId,
          bodyMarkdown: "# Churn \(version)\nBody."
        )
      })
    )
    let service = try NoteService(driver: driver, autoActionDispatcher: dispatcher)
    let source = try service.createNotebookWithNotes(
      title: "Queued churning guide",
      pages: [NotePageDraft(bodyMarkdown: "# Initial\nBody.", readOnly: false)]
    )
    let (job, queued) = try service.requestNotebookTranslation(
      notebookId: source.notebook.notebookId,
      targetLanguage: "English"
    )
    XCTAssertTrue(queued)
    let jobId = try XCTUnwrap(job).jobId

    for attempt in 1...maximumAutoActionDispatchAttempts {
      if attempt > 1 {
        XCTAssertEqual(try service.retryPendingAutoActionDispatches(), 1)
      }
      await service.drainAutoActionDispatches()
      let dispatch = try XCTUnwrap(
        try service.listAutoActionDispatchAttempts().first(where: {
          $0.record.event.translationJobId == jobId
            && $0.record.action.workflowId == NoteStoreSchema.notebookTranslationWorkflowId
        })
      )
      XCTAssertEqual(dispatch.status, .pending)
      XCTAssertEqual(dispatch.attemptCount, attempt)
      XCTAssertTrue(
        dispatch.lastError?.contains("reconciliation consumes an auto-action retry") == true,
        "unexpected dispatch error: \(dispatch.lastError ?? "nil")"
      )
    }

    XCTAssertEqual(try service.retryPendingAutoActionDispatches(), 0)
    let finalDispatch = try XCTUnwrap(try service.listAutoActionDispatchAttempts().first)
    XCTAssertEqual(finalDispatch.attemptCount, maximumAutoActionDispatchAttempts)
    XCTAssertEqual(finalDispatch.status, .pending)
  }

  func testAgentExecutionAdmissionBoundsGlobalAndPrincipalSlots() {
    let admission = AgentExecutionAdmission(
      maximumConcurrentExecutions: 2,
      maximumConcurrentExecutionsPerPrincipal: 1
    )
    let alice = admission.acquire(principalId: "user:alice")
    XCTAssertNotNil(alice)
    XCTAssertNil(admission.acquire(principalId: "user:alice"))
    let bob = admission.acquire(principalId: "user:bob")
    XCTAssertNotNil(bob)
    XCTAssertNil(admission.acquire(principalId: "user:carol"))
    if let alice { admission.release(alice) }
    XCTAssertNotNil(admission.acquire(principalId: "user:alice"))
  }

  func testRunReplacesTranslationInPlaceAfterPostWriteSourceEdit() async throws {
    var service = try makeService()
    let source = try service.createNotebookWithNotes(
      title: "Guide",
      pages: [NotePageDraft(bodyMarkdown: "# Initial\nBody.", readOnly: false)]
    )
    let pending = try service.startTranslationJob(
      notebookId: source.notebook.notebookId,
      targetLanguage: "English"
    )
    let initialOutput = "translated: # Initial\nBody."
    let updatedSourceMarkdown = "# Updated after output\nBody."
    let originalSourceUpdatedAt = source.notebook.updatedAt
    let mutationService = service
    service.translationOutputPostCommitHook = { output in
      guard output.noteId == source.notes[0].noteId, output.body == initialOutput else {
        return
      }
      _ = try mutationService.updateNoteBody(
        noteId: source.notes[0].noteId,
        bodyMarkdown: updatedSourceMarkdown
      )
      // Preserve the prior timestamp to prove completion relies on the durable
      // notebook revision rather than a wall-clock change.
      try mutationService.driver.withDatabase { database in
        try database.transaction { db in
          try db.execute(
            "UPDATE notebooks SET updated_at = ? WHERE notebook_id = ?",
            bindings: [.text(originalSourceUpdatedAt), .id(source.notebook.notebookId)]
          )
        }
      }
    }

    let invoker = RecordingTranslationInvoker()
    let completed = try await AITranslationService(service: service, invoker: invoker).run(jobId: pending.jobId)

    XCTAssertEqual(completed.status, .completed)
    XCTAssertEqual(invoker.requests.map { $0.turns.last?.markdown }, [
      "# Initial\nBody.",
      updatedSourceMarkdown
    ])
    let versions = try service.noteTranslations(noteId: source.notes[0].noteId)
    XCTAssertEqual(versions.map(\.body), ["translated: \(updatedSourceMarkdown)"])
    XCTAssertEqual(versions.map(\.isCurrent), [true])
    XCTAssertEqual(try storedTranslationCount(service), 1)
  }

  func testRunRetranslatesAgentChatReplyCommittedAfterOutput() async throws {
    var service = try makeService()
    let subject = try service.createNote(bodyMarkdown: "# Subject\nBody.")
    let conversation = try service.startAgentConversation(subjectNoteId: subject.noteId)
    let turn = try service.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "What changed?",
      agentAvailable: true
    )
    let initialTurn = try service.getNote(turn.noteId)
    let pending = try service.startTranslationJob(
      notebookId: conversation.notebookId,
      targetLanguage: "English"
    )
    let mutationService = service
    service.translationOutputPostCommitHook = { output in
      guard output.noteId == turn.noteId,
        output.body == "translated: \(initialTurn.bodyMarkdown)"
      else {
        return
      }
      _ = try mutationService.completeAgentChatTurn(
        turnNoteId: turn.noteId,
        assistantMarkdown: "The reply committed after translation output."
      )
    }

    let invoker = RecordingTranslationInvoker()
    let completed = try await AITranslationService(service: service, invoker: invoker).run(jobId: pending.jobId)

    let answeredTurn = try service.getNote(turn.noteId)
    XCTAssertEqual(completed.status, .completed)
    XCTAssertEqual(invoker.requests.map { $0.turns.last?.markdown }, [
      initialTurn.bodyMarkdown,
      answeredTurn.bodyMarkdown
    ])
    XCTAssertEqual(
      try service.noteTranslations(noteId: turn.noteId).map(\.body),
      ["translated: \(answeredTurn.bodyMarkdown)"]
    )
  }

  func testRunCompletesAfterPostWriteSourceDeletion() async throws {
    var service = try makeService()
    let source = try service.createNotebookWithNotes(
      title: "Guide",
      pages: [NotePageDraft(bodyMarkdown: "# Deleted after output\nBody.", readOnly: false)]
    )
    let pending = try service.startTranslationJob(
      notebookId: source.notebook.notebookId,
      targetLanguage: "English"
    )
    let mutationService = service
    service.translationOutputPostCommitHook = { output in
      guard output.noteId == source.notes[0].noteId else { return }
      try mutationService.deleteNote(noteId: source.notes[0].noteId)
    }

    let invoker = RecordingTranslationInvoker()
    let completed = try await AITranslationService(service: service, invoker: invoker).run(jobId: pending.jobId)

    XCTAssertEqual(completed.status, .completed)
    XCTAssertEqual(invoker.requests.count, 1)
    XCTAssertEqual(try storedTranslationCount(service), 0)
  }

  func testCompletedTranslationRunIsIdempotent() async throws {
    let service = try makeService()
    let ingest = try service.createNotebookWithNotes(
      title: "Guide",
      pages: [NotePageDraft(bodyMarkdown: "# One\nBody.")]
    )
    let invoker = RecordingTranslationInvoker()
    let translation = AITranslationService(service: service, invoker: invoker)
    let job = try await translation.translateNotebook(
      notebookId: ingest.notebook.notebookId,
      targetLanguage: "English"
    )
    let rerun = try await translation.run(jobId: job.jobId)
    XCTAssertEqual(rerun.status, .completed)
    XCTAssertEqual(invoker.requests.count, 1)

    // A new job over unchanged sources completes without provider calls.
    let again = try await translation.translateNotebook(
      notebookId: ingest.notebook.notebookId,
      targetLanguage: "English"
    )
    XCTAssertEqual(again.status, .completed)
    XCTAssertEqual(invoker.requests.count, 1)
  }

  func testCancelledJobIsNeverRun() async throws {
    let service = try makeService()
    let ingest = try service.createNotebookWithNotes(
      title: "Guide",
      pages: [NotePageDraft(bodyMarkdown: "# One\nBody.")]
    )
    let pending = try service.startTranslationJob(
      notebookId: ingest.notebook.notebookId,
      targetLanguage: "English"
    )
    let cancelled = try service.setTranslationJobStatus(pending.jobId, status: .cancelled, errorMessage: "stop")
    XCTAssertEqual(cancelled.status, .cancelled)
    XCTAssertEqual(cancelled.errorMessage, "stop")

    let invoker = RecordingTranslationInvoker()
    let result = try await AITranslationService(service: service, invoker: invoker).run(jobId: pending.jobId)
    XCTAssertEqual(result.status, .cancelled)
    XCTAssertTrue(invoker.requests.isEmpty)
    XCTAssertTrue(try service.noteTranslations(noteId: ingest.notes[0].noteId).isEmpty)
  }

  func testRequestWithoutDispatcherCreatesNothing() throws {
    let service = try makeService()
    let ingest = try service.createNotebookWithNotes(
      title: "Guide",
      pages: [NotePageDraft(bodyMarkdown: "# One\nBody.")]
    )
    let (job, queued) = try service.requestNotebookTranslation(
      notebookId: ingest.notebook.notebookId,
      targetLanguage: "English"
    )
    XCTAssertNil(job)
    XCTAssertFalse(queued)
    XCTAssertTrue(try service.translationJobs(notebookId: ingest.notebook.notebookId).isEmpty)
  }

  func testRequestWithDispatcherRunsTranslationToCompletion() async throws {
    let driver = try makeNoteDriver()
    let invoker = RecordingTranslationInvoker()
    let dispatcher = KaibaAutoActionDispatcher(
      service: try NoteService(driver: driver),
      invoker: invoker
    )
    let service = try NoteService(driver: driver, autoActionDispatcher: dispatcher)
    let ingest = try service.createNotebookWithNotes(
      title: "Guide",
      pages: [
        NotePageDraft(bodyMarkdown: "# One\nBody."),
        NotePageDraft(bodyMarkdown: "# Two\nText.")
      ]
    )
    let (pending, queued) = try service.requestNotebookTranslation(
      notebookId: ingest.notebook.notebookId,
      targetLanguage: "Japanese"
    )
    XCTAssertTrue(queued)
    let jobId = try XCTUnwrap(pending).jobId
    await service.drainAutoActionDispatches()
    XCTAssertEqual(try service.getTranslationJob(jobId).status, .completed)
    XCTAssertEqual(
      try ingest.notes.flatMap { try service.noteTranslations(noteId: $0.noteId).map(\.language) },
      ["Japanese", "Japanese"]
    )
  }

  func testNormalizedReplyStripsOnlyWholeDocumentFence() {
    XCTAssertEqual(
      AITranslationService.normalizedReply("```markdown\n# Title\ntext\n```"),
      "# Title\ntext"
    )
    let withInnerFence = "# Doc\n```swift\nlet a = 1\n```"
    XCTAssertEqual(AITranslationService.normalizedReply(withInnerFence), withInnerFence)
    let fencedWithInnerFence = "```\n# Doc\n```swift\nlet a = 1\n```\n```"
    XCTAssertEqual(
      AITranslationService.normalizedReply(fencedWithInnerFence),
      fencedWithInnerFence
    )
  }

  func testDecodesTranslateConfiguration() throws {
    let json = """
    {
      "ai": {
        "agent": { "backend": "agent-gateway-cli", "provider": "openrouter", "model": "m" },
        "translate": {
          "provider": "anthropic",
          "model": "claude-sonnet-5",
          "defaultTargetLanguage": "Japanese"
        }
      }
    }
    """
    let configuration = try JSONDecoder().decode(
      KaibaConfiguration.self,
      from: Data(json.utf8)
    )
    XCTAssertEqual(configuration.ai?.translate?.provider, "anthropic")
    XCTAssertEqual(configuration.ai?.translate?.model, "claude-sonnet-5")
    XCTAssertEqual(configuration.ai?.translate?.defaultTargetLanguage, "Japanese")
  }

  private func storedTranslationCount(_ service: NoteService) throws -> Int {
    try service.driver.withDatabase { database in
      Int(try database.query("SELECT COUNT(*) AS count FROM note_translations").first?["count"] ?? "") ?? -1
    }
  }
}
