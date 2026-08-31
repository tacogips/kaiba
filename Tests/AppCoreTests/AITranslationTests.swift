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
  func testStartNotebookTranslationCreatesPendingTranslationNotebook() throws {
    let service = try makeService()
    let ingest = try service.createNotebookWithNotes(
      title: "Guide",
      pages: [
        NotePageDraft(bodyMarkdown: "# One\nBody."),
        NotePageDraft(bodyMarkdown: "# Two\nText.")
      ]
    )
    let pending = try service.startNotebookTranslation(
      sourceNotebookId: ingest.notebook.notebookId,
      targetLanguage: "English"
    )
    XCTAssertEqual(pending.title, "Guide [English]")
    XCTAssertTrue(pending.tags.contains {
      $0.tag.name == NoteStoreSchema.translationNotebookKindTag
    })
    let state = try XCTUnwrap(NoteService.translationState(of: pending))
    XCTAssertEqual(state.sourceNotebookId, ingest.notebook.notebookId)
    XCTAssertEqual(state.targetLanguage, "English")
    XCTAssertEqual(state.status, .pending)
    XCTAssertNil(state.errorMessage)
  }

  func testStartNotebookTranslationRejectsEmptySourceOrLanguage() throws {
    let service = try makeService()
    let empty = try service.createNotebook(title: "Empty")
    XCTAssertThrowsError(try service.startNotebookTranslation(
      sourceNotebookId: empty.notebookId,
      targetLanguage: "English"
    ))
    let ingest = try service.createNotebookWithNotes(
      title: "Guide",
      pages: [NotePageDraft(bodyMarkdown: "# One\nBody.")]
    )
    XCTAssertThrowsError(try service.startNotebookTranslation(
      sourceNotebookId: ingest.notebook.notebookId,
      targetLanguage: "   "
    ))
  }

  func testTranslationNotebookInheritsProtectedSourceLibrary() async throws {
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
    let translation = AITranslationService(
      service: protectedService,
      invoker: RecordingTranslationInvoker()
    )

    let translated = try await translation.translateNotebook(
      sourceNotebookId: source.notebook.notebookId,
      targetLanguage: "English"
    )
    let translatedNote = try XCTUnwrap(
      protectedService.listNotes(notebookId: translated.notebookId, limit: 1, offset: 0).first
    )
    XCTAssertEqual(translated.libraryId, protectedLibrary.libraryId)

    let unauthenticated = service.scoped(to: NoteStoreSchema.defaultUserId).unauthenticated()
    XCTAssertThrowsError(try unauthenticated.getNotebook(translated.notebookId)) { error in
      guard case .notFound = error as? NoteServiceError else {
        return XCTFail("expected protected translation notebook to be notFound, got \(error)")
      }
    }
    XCTAssertThrowsError(try unauthenticated.getNote(translatedNote.noteId)) { error in
      guard case .notFound = error as? NoteServiceError else {
        return XCTFail("expected protected translation note to be notFound, got \(error)")
      }
    }
  }

  func testStartTranslationRejectsSourceLibraryMoveAtCreationBoundary() throws {
    var service = try makeService()
    let source = try service.createNotebookWithNotes(
      title: "Open guide",
      pages: [NotePageDraft(bodyMarkdown: "# Open\nMoves during creation.")]
    )
    let protectedLibrary = try service.createLibrary(
      name: "translation-creation-race",
      authRequired: true
    )
    service.translationCreationPreinsertHook = { database in
      try database.execute(
        "UPDATE notebooks SET library_id = ? WHERE notebook_id = ?",
        bindings: [.id(protectedLibrary.libraryId), .id(source.notebook.notebookId)]
      )
    }

    XCTAssertThrowsError(try service.startNotebookTranslation(
      sourceNotebookId: source.notebook.notebookId,
      targetLanguage: "English"
    )) { error in
      guard case .conflict = error as? NoteServiceError else {
        return XCTFail("expected conflict, got \(error)")
      }
    }
    let translations = try service.driver.withDatabase { database in
      try database.query(
        "SELECT notebook_id FROM notebooks WHERE json_extract(meta_json, '$.kaibaTranslation.sourceNotebookId') = ?",
        bindings: [.id(source.notebook.notebookId)]
      )
    }
    XCTAssertTrue(translations.isEmpty)
  }

  func testTranslationRunRejectsSourceMoveDuringProviderInvocation() async throws {
    let service = try makeService()
    let source = try service.createNotebookWithNotes(
      title: "Open guide",
      pages: [NotePageDraft(bodyMarkdown: "# Open\nMoves during execution.")]
    )
    let pending = try service.startNotebookTranslation(
      sourceNotebookId: source.notebook.notebookId,
      targetLanguage: "English"
    )
    let protectedLibrary = try service.createLibrary(
      name: "translation-execution-race",
      authRequired: true
    )
    let invoker = RecordingTranslationInvoker(onInvoke: { _ in
      _ = try service.moveNotebook(source.notebook.notebookId, toLibrary: protectedLibrary.name)
    })

    do {
      _ = try await AITranslationService(service: service, invoker: invoker).run(
        translationNotebookId: pending.notebookId
      )
      XCTFail("expected source and translation library mismatch")
    } catch let error as NoteServiceError {
      guard case .conflict = error else {
        return XCTFail("expected conflict, got \(error)")
      }
    }
    XCTAssertEqual(invoker.requests.count, 1)
    XCTAssertEqual(
      try service.listNotes(notebookId: pending.notebookId, limit: 10, offset: 0).count,
      0
    )
  }

  func testTranslationFailureDoesNotPersistAfterDestinationMovesOpenDuringProviderInvocation() async throws {
    let service = try makeService()
    let protectedLibrary = try service.createLibrary(
      name: "translation-failure-boundary",
      authRequired: true
    )
    let source = try service.scoped(toLibrary: protectedLibrary.libraryId).createNotebookWithNotes(
      title: "Protected guide",
      pages: [NotePageDraft(bodyMarkdown: "# Protected\nDo not expose provider failures.")]
    )
    let pending = try service.startNotebookTranslation(
      sourceNotebookId: source.notebook.notebookId,
      targetLanguage: "English"
    )
    let sentinel = "provider failure contains protected translation context"
    let invoker = RecordingTranslationInvoker(onInvoke: { _ in
      _ = try service.moveNotebook(
        pending.notebookId,
        toLibrary: NoteStoreSchema.defaultLibraryName
      )
      throw AgentInvocationError.failed(sentinel)
    })

    do {
      _ = try await AITranslationService(service: service, invoker: invoker).run(
        translationNotebookId: pending.notebookId
      )
      XCTFail("expected provider failure")
    } catch AgentInvocationError.failed(let message) {
      XCTAssertEqual(message, sentinel)
    }

    let ownerTranslation = try service.getNotebook(pending.notebookId)
    let ownerState = try XCTUnwrap(NoteService.translationState(of: ownerTranslation))
    XCTAssertEqual(ownerState.status, .pending)
    XCTAssertNil(ownerState.errorMessage)

    let unauthenticated = service.scoped(to: NoteStoreSchema.defaultUserId).unauthenticated()
    let publicTranslation = try unauthenticated.getNotebook(pending.notebookId)
    let publicState = try XCTUnwrap(NoteService.translationState(of: publicTranslation))
    XCTAssertEqual(publicState.status, .pending)
    XCTAssertNil(publicState.errorMessage)
    XCTAssertFalse(publicTranslation.metaJSON?.contains(sentinel) == true)
  }

  func testTranslateNotebookTranslatesEveryNoteInOrder() async throws {
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
    let notebook = try await translation.translateNotebook(
      sourceNotebookId: ingest.notebook.notebookId,
      targetLanguage: "English"
    )
    let state = try XCTUnwrap(NoteService.translationState(of: notebook))
    XCTAssertEqual(state.status, .completed)
    let notes = try service.listNotes(notebookId: notebook.notebookId, limit: 10, offset: 0)
    XCTAssertEqual(
      notes.map(\.bodyMarkdown),
      ["translated: # One\nBody.", "translated: # Two\nText."]
    )
    XCTAssertEqual(
      notes.map { $0.metaJSON?.contains(ingest.notes[0].noteId.rawValue) == true },
      [true, false]
    )
    XCTAssertEqual(invoker.requests.count, 2)
    for request in invoker.requests {
      XCTAssertEqual(request.purpose, .translation)
      XCTAssertTrue(request.systemPrompt.contains("English"))
      XCTAssertEqual(request.provider, "openrouter")
      XCTAssertEqual(request.model, "test-model")
      XCTAssertNil(request.contextMarkdown)
    }
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
    let failing = RecordingTranslationInvoker(failOnCallIndices: [1])
    let pending = try service.startNotebookTranslation(
      sourceNotebookId: ingest.notebook.notebookId,
      targetLanguage: "English"
    )
    let firstAttempt = AITranslationService(service: service, invoker: failing)
    do {
      _ = try await firstAttempt.run(translationNotebookId: pending.notebookId)
      XCTFail("expected the stubbed second translation call to fail")
    } catch {}
    let failedState = try XCTUnwrap(
      NoteService.translationState(of: try service.getNotebook(pending.notebookId))
    )
    XCTAssertEqual(failedState.status, .failed)
    XCTAssertTrue(failedState.errorMessage?.contains("stub translation failure") == true)
    XCTAssertEqual(
      try service.listNotes(notebookId: pending.notebookId, limit: 10, offset: 0).count,
      1
    )

    let resuming = RecordingTranslationInvoker()
    let secondAttempt = AITranslationService(service: service, invoker: resuming)
    let notebook = try await secondAttempt.run(translationNotebookId: pending.notebookId)
    XCTAssertEqual(NoteService.translationState(of: notebook)?.status, .completed)
    // Only the untranslated second note is retranslated on resume.
    XCTAssertEqual(resuming.requests.count, 1)
    XCTAssertEqual(
      try service.listNotes(notebookId: pending.notebookId, limit: 10, offset: 0)
        .map(\.bodyMarkdown),
      ["translated: # One\nBody.", "translated: # Two\nText."]
    )
  }

  func testRunResumesBySourceIdentityAfterEarlierSourceIsDeleted() async throws {
    let service = try makeService()
    let ingest = try service.createNotebookWithNotes(
      title: "Guide",
      pages: [
        NotePageDraft(bodyMarkdown: "# One\nBody."),
        NotePageDraft(bodyMarkdown: "# Two\nText.")
      ]
    )
    let pending = try service.startNotebookTranslation(
      sourceNotebookId: ingest.notebook.notebookId,
      targetLanguage: "English"
    )
    do {
      _ = try await AITranslationService(
        service: service,
        invoker: RecordingTranslationInvoker(failOnCallIndices: [1])
      ).run(translationNotebookId: pending.notebookId)
      XCTFail("expected the second source translation to fail")
    } catch {}

    try service.driver.withDatabase { database in
      try database.transaction { db in
        try deleteNoteRows(noteId: ingest.notes[0].noteId, in: db)
      }
    }
    let resuming = RecordingTranslationInvoker()
    let completed = try await AITranslationService(service: service, invoker: resuming).run(
      translationNotebookId: pending.notebookId
    )

    XCTAssertEqual(NoteService.translationState(of: completed)?.status, .completed)
    XCTAssertEqual(resuming.requests.count, 1)
    let translated = try service.listNotes(notebookId: pending.notebookId, limit: 10, offset: 0)
    XCTAssertEqual(translated.count, 2)
    XCTAssertEqual(
      translated.compactMap { $0.metaJSON?.contains(ingest.notes[1].noteId.rawValue) == true ? $0.bodyMarkdown : nil },
      ["translated: # Two\nText."]
    )
  }

  func testRunTranslatesSourceAddedDuringProviderInvocationBeforeCompletion() async throws {
    let service = try makeService()
    let source = try service.createNotebookWithNotes(
      title: "Guide",
      pages: [NotePageDraft(bodyMarkdown: "# Initial\nBody.")]
    )
    let pending = try service.startNotebookTranslation(
      sourceNotebookId: source.notebook.notebookId,
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

    let completed = try await AITranslationService(service: service, invoker: invoker).run(
      translationNotebookId: pending.notebookId
    )

    XCTAssertEqual(NoteService.translationState(of: completed)?.status, .completed)
    XCTAssertEqual(invoker.requests.count, 2)
    XCTAssertEqual(
      try service.listNotes(notebookId: completed.notebookId, limit: 10, offset: 0)
        .map(\.bodyMarkdown),
      ["translated: # Initial\nBody.", "translated: # Added during translation\nBody."]
    )
  }

  func testRunCompletesAfterProviderDeletesSourceBeforeOutputWrite() async throws {
    let service = try makeService()
    let source = try service.createNotebookWithNotes(
      title: "Guide",
      pages: [NotePageDraft(bodyMarkdown: "# Deleted during translation\nBody.")]
    )
    let pending = try service.startNotebookTranslation(
      sourceNotebookId: source.notebook.notebookId,
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

    let completed = try await AITranslationService(service: service, invoker: invoker).run(
      translationNotebookId: pending.notebookId
    )

    XCTAssertEqual(NoteService.translationState(of: completed)?.status, .completed)
    XCTAssertEqual(invoker.requests.count, 1)
    XCTAssertTrue(try service.listNotes(notebookId: completed.notebookId, limit: 10, offset: 0).isEmpty)
  }

  func testRunRetranslatesAChangedSourceBeforeCompletion() async throws {
    let service = try makeService()
    let source = try service.createNotebookWithNotes(
      title: "Guide",
      pages: [NotePageDraft(bodyMarkdown: "# Initial\nBody.", readOnly: false)]
    )
    let pending = try service.startNotebookTranslation(
      sourceNotebookId: source.notebook.notebookId,
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

    let completed = try await AITranslationService(service: service, invoker: invoker).run(
      translationNotebookId: pending.notebookId
    )

    XCTAssertEqual(NoteService.translationState(of: completed)?.status, .completed)
    XCTAssertEqual(invoker.requests.map { $0.turns.last?.markdown }, [
      "# Initial\nBody.",
      updatedSourceMarkdown
    ])
    let translated = try service.listNotes(notebookId: completed.notebookId, limit: 10, offset: 0)
    XCTAssertEqual(translated.map(\.bodyMarkdown), ["translated: \(updatedSourceMarkdown)"])
    XCTAssertTrue(translated[0].metaJSON?.contains("sourceContentHash") == true)
  }

  func testRunFailsWithinReconciliationBudgetWhenSourceNeverConverges() async throws {
    let service = try makeService()
    let source = try service.createNotebookWithNotes(
      title: "Churning guide",
      pages: [NotePageDraft(bodyMarkdown: "# Initial\nBody.", readOnly: false)]
    )
    let pending = try service.startNotebookTranslation(
      sourceNotebookId: source.notebook.notebookId,
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
      _ = try await AITranslationService(service: service, invoker: invoker).run(
        translationNotebookId: pending.notebookId
      )
      XCTFail("expected repeated source churn to consume one bounded dispatch attempt")
    } catch AgentInvocationError.failed(let message) {
      XCTAssertTrue(message.contains("reconciliation budget"))
    }
    XCTAssertEqual(invoker.requests.count, AITranslationReconciliationLimits.maximumRounds)
    let state = try XCTUnwrap(NoteService.translationState(of: try service.getNotebook(pending.notebookId)))
    XCTAssertEqual(state.status, .failed)
    XCTAssertTrue(state.errorMessage?.contains("reconciliation budget") == true)
  }

  func testRunStopsWhenElapsedBudgetExpiresDuringChurnReconciliation() async throws {
    let service = try makeService()
    let source = try service.createNotebookWithNotes(
      title: "Slow guide",
      pages: [NotePageDraft(bodyMarkdown: "# Initial\nBody.", readOnly: false)]
    )
    let pending = try service.startNotebookTranslation(
      sourceNotebookId: source.notebook.notebookId,
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
      _ = try await translation.run(translationNotebookId: pending.notebookId)
      XCTFail("expected elapsed reconciliation budget to stop the current dispatch")
    } catch AgentInvocationError.failed(let message) {
      XCTAssertTrue(message.contains("reconciliation budget"))
    }

    XCTAssertEqual(invoker.requests.count, 2)
    XCTAssertTrue(try service.listNotes(notebookId: pending.notebookId, limit: 10, offset: 0).isEmpty)
    let state = try XCTUnwrap(NoteService.translationState(of: try service.getNotebook(pending.notebookId)))
    XCTAssertEqual(state.status, .failed)
    XCTAssertTrue(state.errorMessage?.contains("reconciliation budget") == true)
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
    let pending = try service.startNotebookTranslation(
      sourceNotebookId: source.notebook.notebookId,
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
    ).run(
      translationNotebookId: pending.notebookId
    )

    XCTAssertEqual(NoteService.translationState(of: completed)?.status, .completed)
    XCTAssertEqual(invoker.requests.count, sourceCount)
    let observedPageSizes = await pageRecorder.values()
    XCTAssertEqual(
      observedPageSizes,
      [AITranslationReconciliationLimits.maximumProviderInvocations, 1]
    )
    XCTAssertEqual(
      try service.listNotes(notebookId: completed.notebookId, limit: sourceCount + 1, offset: 0).count,
      sourceCount
    )
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

    let (translation, queued) = try service.requestNotebookTranslation(
      sourceNotebookId: source.notebook.notebookId,
      targetLanguage: "English"
    )
    XCTAssertTrue(queued)
    let translationNotebookId = try XCTUnwrap(translation).notebookId
    await service.drainAutoActionDispatches()

    XCTAssertEqual(
      NoteService.translationState(of: try service.getNotebook(translationNotebookId))?.status,
      .pending
    )
    XCTAssertEqual(invoker.requests.count, AITranslationReconciliationLimits.maximumProviderInvocations)
    let pendingState = try XCTUnwrap(
      NoteService.translationState(of: try service.getNotebook(translationNotebookId))
    )
    XCTAssertNotNil(pendingState.continuationSourceNoteId)
    XCTAssertEqual(try service.retryPendingAutoActionDispatches(), 1)
    await service.drainAutoActionDispatches()

    XCTAssertEqual(
      NoteService.translationState(of: try service.getNotebook(translationNotebookId))?.status,
      .completed
    )
    let dispatch = try XCTUnwrap(
      try service.listAutoActionDispatchAttempts().first(where: {
        $0.record.event.notebookId == translationNotebookId
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
    let (translation, queued) = try service.requestNotebookTranslation(
      sourceNotebookId: source.notebook.notebookId,
      targetLanguage: "English"
    )
    XCTAssertTrue(queued)
    let translationNotebookId = try XCTUnwrap(translation).notebookId

    for attempt in 1...maximumAutoActionDispatchAttempts {
      if attempt > 1 {
        XCTAssertEqual(try service.retryPendingAutoActionDispatches(), 1)
      }
      await service.drainAutoActionDispatches()
      let dispatch = try XCTUnwrap(
        try service.listAutoActionDispatchAttempts().first(where: {
          $0.record.event.notebookId == translationNotebookId
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

  func testRunReplacesStaleOutputAfterPostWriteSourceEdit() async throws {
    var service = try makeService()
    let source = try service.createNotebookWithNotes(
      title: "Guide",
      pages: [NotePageDraft(bodyMarkdown: "# Initial\nBody.", readOnly: false)]
    )
    let pending = try service.startNotebookTranslation(
      sourceNotebookId: source.notebook.notebookId,
      targetLanguage: "English"
    )
    let initialOutput = "translated: # Initial\nBody."
    let updatedSourceMarkdown = "# Updated after output\nBody."
    let originalSourceUpdatedAt = source.notebook.updatedAt
    let mutationService = service
    service.translationOutputPostCommitHook = { output in
      guard output.notebookId == pending.notebookId,
        output.bodyMarkdown == initialOutput
      else {
        return
      }
      _ = try mutationService.updateNoteBody(
        noteId: source.notes[0].noteId,
        bodyMarkdown: updatedSourceMarkdown
      )
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
    let completed = try await AITranslationService(service: service, invoker: invoker).run(
      translationNotebookId: pending.notebookId
    )

    XCTAssertEqual(NoteService.translationState(of: completed)?.status, .completed)
    XCTAssertEqual(invoker.requests.map { $0.turns.last?.markdown }, [
      "# Initial\nBody.",
      updatedSourceMarkdown
    ])
    let translated = try service.listNotes(notebookId: completed.notebookId, limit: 10, offset: 0)
    XCTAssertEqual(translated.count, 1)
    XCTAssertEqual(translated.map(\.bodyMarkdown), ["translated: \(updatedSourceMarkdown)"])
    XCTAssertTrue(translated[0].metaJSON?.contains(
      NoteService.translationSourceContentHash(updatedSourceMarkdown)
    ) == true)
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
    let sourceBeforeTranslation = try service.getNotebook(conversation.notebookId)
    let pending = try service.startNotebookTranslation(
      sourceNotebookId: conversation.notebookId,
      targetLanguage: "English"
    )
    let mutationService = service
    service.translationOutputPostCommitHook = { output in
      guard output.notebookId == pending.notebookId,
        output.bodyMarkdown == "translated: \(initialTurn.bodyMarkdown)"
      else {
        return
      }
      _ = try mutationService.completeAgentChatTurn(
        turnNoteId: turn.noteId,
        assistantMarkdown: "The reply committed after translation output."
      )
      // Preserve the prior timestamp to prove completion relies on the durable
      // content revision rather than a wall-clock change.
      try mutationService.driver.withDatabase { database in
        try database.transaction { db in
          try db.execute(
            "UPDATE notebooks SET updated_at = ? WHERE notebook_id = ?",
            bindings: [.text(sourceBeforeTranslation.updatedAt), .id(conversation.notebookId)]
          )
        }
      }
    }

    let invoker = RecordingTranslationInvoker()
    let completed = try await AITranslationService(service: service, invoker: invoker).run(
      translationNotebookId: pending.notebookId
    )

    let answeredTurn = try service.getNote(turn.noteId)
    XCTAssertEqual(NoteService.translationState(of: completed)?.status, .completed)
    XCTAssertEqual(invoker.requests.map { $0.turns.last?.markdown }, [
      initialTurn.bodyMarkdown,
      answeredTurn.bodyMarkdown
    ])
    XCTAssertEqual(
      try service.listNotes(notebookId: completed.notebookId, limit: 10, offset: 0).map(\.bodyMarkdown),
      ["translated: \(answeredTurn.bodyMarkdown)"]
    )
  }

  func testRunCompletesAfterPostWriteSourceDeletion() async throws {
    var service = try makeService()
    let source = try service.createNotebookWithNotes(
      title: "Guide",
      pages: [NotePageDraft(bodyMarkdown: "# Deleted after output\nBody.", readOnly: false)]
    )
    let pending = try service.startNotebookTranslation(
      sourceNotebookId: source.notebook.notebookId,
      targetLanguage: "English"
    )
    let originalSourceUpdatedAt = source.notebook.updatedAt
    let mutationService = service
    service.translationOutputPostCommitHook = { output in
      guard output.notebookId == pending.notebookId else { return }
      try mutationService.deleteNote(noteId: source.notes[0].noteId)
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
    let completed = try await AITranslationService(service: service, invoker: invoker).run(
      translationNotebookId: pending.notebookId
    )

    XCTAssertEqual(NoteService.translationState(of: completed)?.status, .completed)
    XCTAssertEqual(invoker.requests.count, 1)
    XCTAssertTrue(try service.listNotes(notebookId: completed.notebookId, limit: 10, offset: 0).isEmpty)
  }

  func testCompletedTranslationRunIsIdempotent() async throws {
    let service = try makeService()
    let ingest = try service.createNotebookWithNotes(
      title: "Guide",
      pages: [NotePageDraft(bodyMarkdown: "# One\nBody.")]
    )
    let invoker = RecordingTranslationInvoker()
    let translation = AITranslationService(service: service, invoker: invoker)
    let notebook = try await translation.translateNotebook(
      sourceNotebookId: ingest.notebook.notebookId,
      targetLanguage: "English"
    )
    _ = try await translation.run(translationNotebookId: notebook.notebookId)
    XCTAssertEqual(invoker.requests.count, 1)
  }

  func testRequestWithoutDispatcherCreatesNothing() throws {
    let service = try makeService()
    let ingest = try service.createNotebookWithNotes(
      title: "Guide",
      pages: [NotePageDraft(bodyMarkdown: "# One\nBody.")]
    )
    let (notebook, queued) = try service.requestNotebookTranslation(
      sourceNotebookId: ingest.notebook.notebookId,
      targetLanguage: "English"
    )
    XCTAssertNil(notebook)
    XCTAssertFalse(queued)
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
      sourceNotebookId: ingest.notebook.notebookId,
      targetLanguage: "Japanese"
    )
    XCTAssertTrue(queued)
    let pendingNotebookId = try XCTUnwrap(pending).notebookId
    await service.drainAutoActionDispatches()
    let finished = try service.getNotebook(pendingNotebookId)
    XCTAssertEqual(NoteService.translationState(of: finished)?.status, .completed)
    XCTAssertEqual(
      try service.listNotes(notebookId: pendingNotebookId, limit: 10, offset: 0).count,
      2
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

}
