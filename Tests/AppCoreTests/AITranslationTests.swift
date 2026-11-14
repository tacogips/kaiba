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

  init(
    failOnCallIndices: Set<Int> = [],
    reply: @escaping (String) -> String = { "translated: \($0)" }
  ) {
    self.failOnCallIndices = failOnCallIndices
    self.reply = reply
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
    if failOnCallIndices.contains(index) {
      throw AgentInvocationError.failed("stub translation failure")
    }
    return AgentInvocationResult(markdown: reply(request.turns.last?.markdown ?? ""))
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
