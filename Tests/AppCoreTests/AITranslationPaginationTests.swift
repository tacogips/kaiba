import Foundation
@testable import AppCore
import XCTest

private final class PaginationTranslationInvoker: AgentInvoking, @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var requestCount: Int {
    lock.withLock { count }
  }

  func invoke(_ request: AgentInvocationRequest) async throws -> AgentInvocationResult {
    lock.withLock { count += 1 }
    return AgentInvocationResult(markdown: "translated: \(request.turns.last?.markdown ?? "")")
  }
}

private actor TranslationPaginationPageRecorder {
  private var pageSizes: [Int] = []

  func record(_ pageSize: Int) {
    pageSizes.append(pageSize)
  }

  func values() -> [Int] {
    pageSizes
  }
}

final class AITranslationPaginationTests: NoteTestCase {
  func testRunCompletesAtExact128SourceChunkBoundary() async throws {
    try await assertDirectTranslationCompletesAtExactChunkBoundary(
      sourceCount: AITranslationReconciliationLimits.maximumProviderInvocations
    )
  }

  func testRunCompletesAtExact256SourceChunkBoundary() async throws {
    try await assertDirectTranslationCompletesAtExactChunkBoundary(
      sourceCount: AITranslationReconciliationLimits.maximumProviderInvocations * 2
    )
  }

  func testRunCompletesAtMaximumReconciliationPaginationBoundary() async throws {
    let service = try makeService()
    let sourceCount = AITranslationReconciliationLimits.maximumRounds
      * AITranslationReconciliationLimits.maximumProviderInvocations
    let source = try service.createNotebookWithNotes(
      title: "Maximum direct pagination guide",
      pages: (0..<sourceCount).map { NotePageDraft(bodyMarkdown: "# Source \($0)\nBody.") }
    )
    let pending = try service.startNotebookTranslation(
      sourceNotebookId: source.notebook.notebookId,
      targetLanguage: "English"
    )
    let invoker = PaginationTranslationInvoker()
    let pageRecorder = TranslationPaginationPageRecorder()

    let completed = try await AITranslationService(
      service: service,
      invoker: invoker,
      sourcePageObserver: { pageSize in
        await pageRecorder.record(pageSize)
      }
    ).run(translationNotebookId: pending.notebookId)

    XCTAssertEqual(NoteService.translationState(of: completed)?.status, .completed)
    XCTAssertEqual(invoker.requestCount, sourceCount)
    let observedPageSizes = await pageRecorder.values()
    XCTAssertEqual(
      observedPageSizes,
      Array(
        repeating: AITranslationReconciliationLimits.maximumProviderInvocations,
        count: AITranslationReconciliationLimits.maximumRounds
      ) + [0]
    )
    XCTAssertEqual(
      try service.listNotes(notebookId: completed.notebookId, limit: sourceCount + 1, offset: 0).count,
      sourceCount
    )
  }

  func testQueuedRunCompletesAtExact128SourceChunkBoundary() async throws {
    try await assertQueuedTranslationCompletesAtExactChunkBoundary(
      sourceCount: AITranslationReconciliationLimits.maximumProviderInvocations
    )
  }

  func testQueuedRunCompletesAtExact256SourceChunkBoundary() async throws {
    try await assertQueuedTranslationCompletesAtExactChunkBoundary(
      sourceCount: AITranslationReconciliationLimits.maximumProviderInvocations * 2
    )
  }

  private func assertDirectTranslationCompletesAtExactChunkBoundary(
    sourceCount: Int
  ) async throws {
    let service = try makeService()
    let source = try service.createNotebookWithNotes(
      title: "Exact page guide",
      pages: (0..<sourceCount).map { NotePageDraft(bodyMarkdown: "# Source \($0)\nBody.") }
    )
    let pending = try service.startNotebookTranslation(
      sourceNotebookId: source.notebook.notebookId,
      targetLanguage: "English"
    )
    let invoker = PaginationTranslationInvoker()
    let completed = try await AITranslationService(service: service, invoker: invoker).run(
      translationNotebookId: pending.notebookId
    )

    XCTAssertEqual(NoteService.translationState(of: completed)?.status, .completed)
    XCTAssertEqual(invoker.requestCount, sourceCount)
    XCTAssertEqual(try service.listNotes(
      notebookId: completed.notebookId,
      limit: sourceCount + 1,
      offset: 0
    ).count, sourceCount)
  }

  private func assertQueuedTranslationCompletesAtExactChunkBoundary(
    sourceCount: Int
  ) async throws {
    let driver = try makeNoteDriver()
    let invoker = PaginationTranslationInvoker()
    let dispatcher = KaibaAutoActionDispatcher(
      service: try NoteService(driver: driver),
      invoker: invoker
    )
    let service = try NoteService(driver: driver, autoActionDispatcher: dispatcher)
    let source = try service.createNotebookWithNotes(
      title: "Queued exact page guide",
      pages: (0..<sourceCount).map { NotePageDraft(bodyMarkdown: "# Source \($0)\nBody.") }
    )
    let (translation, queued) = try service.requestNotebookTranslation(
      sourceNotebookId: source.notebook.notebookId,
      targetLanguage: "English"
    )
    XCTAssertTrue(queued)
    let translationNotebookId = try XCTUnwrap(translation).notebookId

    for _ in 0...sourceCount / AITranslationReconciliationLimits.maximumProviderInvocations {
      await service.drainAutoActionDispatches()
      if NoteService.translationState(of: try service.getNotebook(translationNotebookId))?.status == .completed {
        break
      }
      XCTAssertEqual(try service.retryPendingAutoActionDispatches(), 1)
    }

    XCTAssertEqual(
      NoteService.translationState(of: try service.getNotebook(translationNotebookId))?.status,
      .completed
    )
    XCTAssertEqual(invoker.requestCount, sourceCount)
  }
}
