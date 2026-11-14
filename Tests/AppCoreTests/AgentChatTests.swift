import Foundation
@testable import AppCore
import XCTest

private struct StubChatInvoker: AgentInvoking {
  var reply: String
  var error: AgentInvocationError?

  func invoke(_ request: AgentInvocationRequest) async throws -> AgentInvocationResult {
    if let error {
      throw error
    }
    return AgentInvocationResult(markdown: reply)
  }
}

private actor CapturingChatInvoker: AgentInvoking {
  private var requests: [AgentInvocationRequest] = []

  func invoke(_ request: AgentInvocationRequest) async throws -> AgentInvocationResult {
    requests.append(request)
    return AgentInvocationResult(markdown: "captured")
  }

  func latestRequest() -> AgentInvocationRequest? {
    requests.last
  }
}

private actor FailingCapturingChatInvoker: AgentInvoking {
  private var requests: [AgentInvocationRequest] = []

  func invoke(_ request: AgentInvocationRequest) async throws -> AgentInvocationResult {
    requests.append(request)
    throw AgentInvocationError.failed("retry requested")
  }

  func latestRequest() -> AgentInvocationRequest? {
    requests.last
  }
}

private final class AttachmentObservingDispatcher: AutoActionDispatching, @unchecked Sendable {
  private let lock = NSLock()
  private var observedAttachmentCounts: [Int] = []
  var service: NoteService?

  func dispatch(_ record: AutoActionDispatchRecord) async throws -> AutoActionDispatchOutcome {
    guard record.action.actionId == NoteStoreSchema.agentChatReplyActionId,
      let noteId = record.event.noteId,
      let service
    else {
      return .succeeded
    }
    let count = try service.listFiles(noteId: noteId).count
    lock.withLock {
      observedAttachmentCounts.append(count)
    }
    return .succeeded
  }

  func counts() -> [Int] {
    lock.withLock { observedAttachmentCounts }
  }
}

private final class FailSecondChatAttachmentStore: NoteFileStore, @unchecked Sendable {
  private let lock = NSLock()
  private var storeCount = 0
  private var deletedRecords: [FileRecord] = []

  func store(data: Data, fileId: String) throws -> StoredNoteFile {
    lock.withLock { storeCount += 1 }
    guard lock.withLock({ storeCount }) == 1 else {
      throw NoteServiceError.invalidInput("injected attachment store failure")
    }
    return StoredNoteFile(
      locator: NoteFileLocator(storageKind: .local, localPath: "injected/\(fileId)"),
      byteSize: Int64(data.count),
      sha256: sha256Hex(data)
    )
  }

  func read(record: FileRecord) throws -> Data { Data() }

  func delete(record: FileRecord) throws {
    lock.withLock { deletedRecords.append(record) }
  }

  var deletedCount: Int { lock.withLock { deletedRecords.count } }
}

final class AgentChatTests: NoteTestCase {
  func testStartConversationBindsSubjectAndKind() throws {
    let service = try makeService()
    let subject = try service.createNote(bodyMarkdown: "# The Document\nContent.")
    let conversation = try service.startAgentConversation(subjectNoteId: subject.noteId)

    XCTAssertTrue(conversation.title.contains("The Document"))
    XCTAssertTrue(conversation.tags.contains {
      $0.tag.name == NoteStoreSchema.agentConversationNotebookKindTag
    })
    XCTAssertEqual(
      try service.chatSubjectNoteId(notebookId: conversation.notebookId),
      subject.noteId
    )
  }

  func testPendingTurnLifecycleCompleteAndFail() throws {
    let service = try makeService()
    let subject = try service.createNote(bodyMarkdown: "# Subject\nBody.")
    let conversation = try service.startAgentConversation(subjectNoteId: subject.noteId)

    let turn = try service.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "What is this about?",
      agentAvailable: true
    )
    var state = try XCTUnwrap(NoteService.chatTurnState(of: turn))
    XCTAssertEqual(state.status, .pending)
    XCTAssertEqual(state.userMarkdown, "What is this about?")
    XCTAssertTrue(turn.bodyMarkdown.contains("_(no reply yet)_"))

    let links = try service.listLinks(noteId: turn.noteId)
    XCTAssertTrue(links.contains {
      $0.toNoteId == subject.noteId && $0.linkKind == "source-citation"
    })

    let answered = try service.completeAgentChatTurn(
      turnNoteId: turn.noteId,
      assistantMarkdown: "It is about testing."
    )
    state = try XCTUnwrap(NoteService.chatTurnState(of: answered))
    XCTAssertEqual(state.status, .answered)
    XCTAssertTrue(answered.bodyMarkdown.contains("It is about testing."))
    XCTAssertEqual(
      NoteService.assistantMarkdown(fromTurnBody: answered.bodyMarkdown),
      "It is about testing."
    )

    let secondTurn = try service.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "Another question",
      agentAvailable: true
    )
    let failed = try service.failAgentChatTurn(
      turnNoteId: secondTurn.noteId,
      message: "model exploded"
    )
    let failedState = try XCTUnwrap(NoteService.chatTurnState(of: failed))
    XCTAssertEqual(failedState.status, .failed)
    XCTAssertEqual(failedState.errorMessage, "model exploded")
  }

  func testUnavailableStatusWhenAgentMissing() throws {
    let service = try makeService()
    let subject = try service.createNote(bodyMarkdown: "# Subject\nBody.")
    let conversation = try service.startAgentConversation(subjectNoteId: subject.noteId)
    let turn = try service.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "Anyone there?",
      agentAvailable: false
    )
    XCTAssertEqual(NoteService.chatTurnState(of: turn)?.status, .unavailable)
  }

  func testIdempotentSendReplaysExistingTurn() throws {
    let service = try makeService()
    let subject = try service.createNote(bodyMarkdown: "# Subject\nBody.")
    let conversation = try service.startAgentConversation(subjectNoteId: subject.noteId)
    let first = try service.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "Same question",
      agentAvailable: true,
      idempotencyKey: "key-1"
    )
    let replay = try service.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "Same question",
      agentAvailable: true,
      idempotencyKey: "key-1"
    )
    XCTAssertEqual(first.noteId, replay.noteId)
    XCTAssertEqual(try service.listNotes(notebookId: conversation.notebookId).count, 1)
  }

  func testTurnSnapshotsModelAndPersistsValidatedAttachmentsBeforeDispatch() throws {
    let service = try makeService()
    let subject = try service.createNote(bodyMarkdown: "# Subject\nBody.")
    let conversation = try service.startAgentConversation(subjectNoteId: subject.noteId)
    let attachment = try AgentChatAttachmentValidation.validate(
      data: Data("reference data".utf8),
      declaredMediaType: "text/plain; charset=utf-8",
      originalFilename: "reference.txt"
    )
    let turn = try service.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "Question",
      agentAvailable: false,
      idempotencyKey: "model-attachment",
      model: "configured-model",
      attachments: [attachment]
    )
    XCTAssertEqual(NoteService.chatTurnState(of: turn)?.model, "configured-model")
    XCTAssertEqual(try service.listFiles(noteId: turn.noteId).map(\.file.originalFilename), ["reference.txt"])

    let replay = try service.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "Question",
      agentAvailable: false,
      idempotencyKey: "model-attachment",
      model: "different-model"
    )
    XCTAssertEqual(replay.noteId, turn.noteId)
    XCTAssertEqual(NoteService.chatTurnState(of: replay)?.model, "configured-model")
  }

  func testAttachmentValidationRejectsUnsafeAndOversizedInput() throws {
    XCTAssertThrowsError(try AgentChatAttachmentValidation.validate(
      data: Data("text".utf8), declaredMediaType: "text/html", originalFilename: "unsafe.html"
    ))
    XCTAssertThrowsError(try AgentChatAttachmentValidation.validate(
      data: Data("text".utf8), declaredMediaType: "text/plain", originalFilename: "../unsafe.txt"
    ))
    XCTAssertThrowsError(try AgentChatAttachmentValidation.validate(
      data: Data(), declaredMediaType: "text/plain", originalFilename: "empty.txt"
    ))
    XCTAssertThrowsError(try AgentChatAttachmentValidation.validate(
      data: Data([0xFF]), declaredMediaType: "text/plain", originalFilename: "invalid.txt"
    ))
    XCTAssertThrowsError(try AgentChatAttachmentValidation.validate(
      data: Data("text".utf8), declaredMediaType: "text/plain", originalFilename: String(repeating: "名", count: 128)
    ))
    XCTAssertNoThrow(try AgentChatAttachmentValidation.validate(
      data: Data("text".utf8),
      declaredMediaType: "text/plain",
      originalFilename: String(repeating: "a", count: 251) + ".txt"
    ))
    XCTAssertThrowsError(try AgentChatAttachmentValidation.validate(
      data: Data("text".utf8),
      declaredMediaType: "text/plain",
      originalFilename: String(repeating: "a", count: 252) + ".txt"
    ))
    let large = try AgentChatAttachmentValidation.validate(
      data: Data(repeating: 65, count: AgentChatAttachmentValidation.maximumAggregateBytes + 1),
      declaredMediaType: "text/plain", originalFilename: "large.txt"
    )
    XCTAssertThrowsError(try AgentChatAttachmentValidation.validate([large]))
  }

  func testAttachmentCollectionRejectsExcessFilesAndDuplicateContent() throws {
    let attachment = try AgentChatAttachmentValidation.validate(
      data: Data("same".utf8), declaredMediaType: "text/plain", originalFilename: "same.txt"
    )
    XCTAssertThrowsError(try AgentChatAttachmentValidation.validate([attachment, attachment]))
    let five = try (0..<5).map { index in
      try AgentChatAttachmentValidation.validate(
        data: Data("file \(index)".utf8), declaredMediaType: "text/plain", originalFilename: "\(index).txt"
      )
    }
    XCTAssertThrowsError(try AgentChatAttachmentValidation.validate(five))
  }

  func testAttachmentValidationAcceptsExactAggregateBoundaryAndRejectsOneByteOver() throws {
    let exactAttachments = try (0..<4).map { index in
      try AgentChatAttachmentValidation.validate(
        data: Data(repeating: 65, count: AgentChatAttachmentValidation.maximumAggregateBytes / 4),
        declaredMediaType: "text/plain",
        originalFilename: "boundary-\(index).txt"
      )
    }
    XCTAssertNoThrow(try AgentChatAttachmentValidation.validate(exactAttachments))
    let oneByteOver = try (0..<4).map { index in
      try AgentChatAttachmentValidation.validate(
        data: Data(
          repeating: 66,
          count: AgentChatAttachmentValidation.maximumAggregateBytes / 4 + (index == 3 ? 1 : 0)
        ),
        declaredMediaType: "text/plain",
        originalFilename: "one-byte-over-\(index).txt"
      )
    }
    XCTAssertThrowsError(try AgentChatAttachmentValidation.validate(oneByteOver))
  }

  func testAttachmentContextUsesGlobalBudgetAndEscapesUntrustedMetadata() async throws {
    let service = try makeService()
    let subject = try service.createNote(bodyMarkdown: "# Subject\nBody.")
    let conversation = try service.startAgentConversation(subjectNoteId: subject.noteId)
    let priorAttachment = try AgentChatAttachmentValidation.validate(
      data: Data(repeating: 65, count: AgentChatAttachmentValidation.maximumAggregateBytes),
      declaredMediaType: "text/plain",
      originalFilename: "prior.txt"
    )
    _ = try service.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "Earlier question",
      agentAvailable: false,
      attachments: [priorAttachment]
    )
    let currentAttachment = try AgentChatAttachmentValidation.validate(
      data: Data("current".utf8),
      declaredMediaType: "text/plain",
      originalFilename: "current&\"<.txt"
    )
    let current = try service.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "Current question",
      agentAvailable: true,
      attachments: [currentAttachment]
    )
    let invoker = CapturingChatInvoker()
    try await service.generateAgentChatReply(turnNoteId: current.noteId, invoker: invoker)
    let capturedRequest = await invoker.latestRequest()
    let request = try XCTUnwrap(capturedRequest)
    let markdown = try XCTUnwrap(request.turns.last?.markdown)
    XCTAssertTrue(markdown.contains("filename=\"current%26%22%3C.txt\""))
    XCTAssertTrue(markdown.contains("<attachment omitted=\"budget\" filename=\"prior.txt\""))
    XCTAssertFalse(markdown.contains(String(repeating: "A", count: 64)))
  }

  func testAttachmentBlobsAreCleanedWhenTurnTransactionFails() throws {
    let service = try makeService()
    let subject = try service.createNote(bodyMarkdown: "# Subject\nBody.")
    let attachment = try AgentChatAttachmentValidation.validate(
      data: Data("rollback".utf8),
      declaredMediaType: "text/plain",
      originalFilename: "rollback.txt"
    )
    let dispatchCount = try service.listAutoActionDispatchAttempts().count
    XCTAssertThrowsError(try service.appendPendingAgentChatTurn(
      conversationNotebookId: subject.notebookId,
      userMarkdown: "Question",
      agentAvailable: true,
      attachments: [attachment]
    ))
    XCTAssertEqual(try service.listNotes(notebookId: subject.notebookId).map(\.noteId), [subject.noteId])
    XCTAssertEqual(try service.listAutoActionDispatchAttempts().count, dispatchCount)
    let filesRoot = URL(fileURLWithPath: service.noteRootPath(), isDirectory: true)
      .appendingPathComponent("files", isDirectory: true)
    let entries = (FileManager.default.enumerator(
      at: filesRoot,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    )?.allObjects as? [URL] ?? []).filter {
      (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
    XCTAssertTrue(entries.isEmpty)
  }

  func testInjectedAttachmentStoreFailureCleansStagedBlobBeforeAnyTurnOrDispatch() async throws {
    let fileStore = FailSecondChatAttachmentStore()
    var service = try makeService()
    service.chatAttachmentFileStore = fileStore
    let subject = try service.createNote(bodyMarkdown: "# Subject\nBody.")
    let conversation = try service.startAgentConversation(subjectNoteId: subject.noteId)
    let dispatcher = AttachmentObservingDispatcher()
    service.autoActionDispatcher = dispatcher
    dispatcher.service = service
    try service.configureAutoAction(
      actionId: NoteStoreSchema.agentChatReplyActionId,
      trigger: .noteCreated,
      workflowId: NoteStoreSchema.agentChatReplyWorkflowId,
      enabled: true
    )
    await service.drainAutoActionDispatches()
    let dispatchCount = try service.listAutoActionDispatchAttempts().count
    let observedCounts = dispatcher.counts()
    let attachments = try ["first.txt", "second.txt"].map { filename in
      try AgentChatAttachmentValidation.validate(
        data: Data(filename.utf8), declaredMediaType: "text/plain", originalFilename: filename
      )
    }

    XCTAssertThrowsError(try service.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "Question",
      agentAvailable: true,
      attachments: attachments
    ))
    XCTAssertEqual(fileStore.deletedCount, 1)
    XCTAssertTrue(try service.listNotes(notebookId: conversation.notebookId).isEmpty)
    XCTAssertEqual(try service.listAutoActionDispatchAttempts().count, dispatchCount)
    XCTAssertEqual(dispatcher.counts(), observedCounts)
  }

  func testDispatchObservesCommittedChatAttachmentAssociations() async throws {
    let dispatcher = AttachmentObservingDispatcher()
    var service = try makeService()
    let subject = try service.createNote(bodyMarkdown: "# Subject\nBody.")
    service.autoActionDispatcher = dispatcher
    dispatcher.service = service
    try service.configureAutoAction(
      actionId: NoteStoreSchema.agentChatReplyActionId,
      trigger: .noteCreated,
      workflowId: NoteStoreSchema.agentChatReplyWorkflowId,
      enabled: true
    )
    let conversation = try service.startAgentConversation(subjectNoteId: subject.noteId)
    let attachment = try AgentChatAttachmentValidation.validate(
      data: Data("available before dispatch".utf8), declaredMediaType: "text/plain", originalFilename: "context.txt"
    )
    _ = try service.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "Question",
      agentAvailable: true,
      attachments: [attachment]
    )
    await service.drainAutoActionDispatches()
    XCTAssertEqual(dispatcher.counts(), [1])
  }

  func testAttachmentContextIncludesExactBoundaryCurrentFilesWithinFramingBudget() async throws {
    let service = try makeService()
    let subject = try service.createNote(bodyMarkdown: "# Subject\nBody.")
    let conversation = try service.startAgentConversation(subjectNoteId: subject.noteId)
    let attachmentBytes = AgentChatAttachmentValidation.maximumAggregateBytes / 4
    let attachments = try (0..<4).map { index in
      try AgentChatAttachmentValidation.validate(
        data: Data(repeating: 65, count: attachmentBytes),
        declaredMediaType: "text/plain",
        originalFilename: String(repeating: "\"", count: 250) + "\(index).txt"
      )
    }
    let turn = try service.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "Question",
      agentAvailable: true,
      attachments: attachments
    )
    let invoker = CapturingChatInvoker()
    try await service.generateAgentChatReply(turnNoteId: turn.noteId, invoker: invoker)
    let capturedRequest = await invoker.latestRequest()
    let request = try XCTUnwrap(capturedRequest)
    let markdown = try XCTUnwrap(request.turns.last?.markdown)
    let framingBytes = markdown.utf8.count - "Question".utf8.count - (attachmentBytes * 4)
    XCTAssertLessThanOrEqual(framingBytes, AgentChatAttachmentValidation.maximumPromptFramingBytes)
    XCTAssertEqual(markdown.components(separatedBy: "<attachment filename=").count - 1, 4)
    XCTAssertTrue(markdown.hasSuffix("</untrusted-attachments>"))
  }

  func testAttachmentContextPreservesCurrentThenNewestPriorFileOrder() async throws {
    let service = try makeService()
    let subject = try service.createNote(bodyMarkdown: "# Subject\nBody.")
    let conversation = try service.startAgentConversation(subjectNoteId: subject.noteId)
    func attachment(_ name: String) throws -> AgentChatAttachment {
      try AgentChatAttachmentValidation.validate(
        data: Data(name.utf8), declaredMediaType: "text/plain", originalFilename: name
      )
    }
    _ = try service.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId, userMarkdown: "Older", agentAvailable: false,
      attachments: [try attachment("old-a.txt"), try attachment("old-b.txt")]
    )
    _ = try service.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId, userMarkdown: "Newer", agentAvailable: false,
      attachments: [try attachment("new.txt")]
    )
    let current = try service.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId, userMarkdown: "Current", agentAvailable: true,
      attachments: [try attachment("current-a.txt"), try attachment("current-b.txt")]
    )
    let invoker = CapturingChatInvoker()
    try await service.generateAgentChatReply(turnNoteId: current.noteId, invoker: invoker)
    let capturedRequest = await invoker.latestRequest()
    let request = try XCTUnwrap(capturedRequest)
    let markdown = try XCTUnwrap(request.turns.last?.markdown)
    let offsets = try ["current-a.txt", "current-b.txt", "new.txt", "old-a.txt", "old-b.txt"].map {
      try XCTUnwrap(markdown.range(of: $0)?.lowerBound)
    }.map { markdown.distance(from: markdown.startIndex, to: $0) }
    XCTAssertEqual(offsets, offsets.sorted())
  }

  func testRetryPreservesSnapshottedModelAndAttachmentContext() async throws {
    let service = try makeService()
    let subject = try service.createNote(bodyMarkdown: "# Subject\nBody.")
    let conversation = try service.startAgentConversation(subjectNoteId: subject.noteId)
    let attachment = try AgentChatAttachmentValidation.validate(
      data: Data("retry attachment".utf8),
      declaredMediaType: "text/plain",
      originalFilename: "retry.txt"
    )
    let turn = try service.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "Question",
      agentAvailable: true,
      model: "snapshot-model",
      attachments: [attachment]
    )
    let failing = FailingCapturingChatInvoker()
    do {
      try await service.generateAgentChatReply(turnNoteId: turn.noteId, invoker: failing)
      XCTFail("expected initial invocation failure")
    } catch {}
    let firstCapturedRequest = await failing.latestRequest()
    let firstRequest = try XCTUnwrap(firstCapturedRequest)
    let retry = CapturingChatInvoker()
    try await service.generateAgentChatReply(turnNoteId: turn.noteId, invoker: retry)
    let retryCapturedRequest = await retry.latestRequest()
    let retryRequest = try XCTUnwrap(retryCapturedRequest)
    XCTAssertEqual(retryRequest.model, "snapshot-model")
    XCTAssertEqual(retryRequest.turns, firstRequest.turns)
  }

  func testRejectsNonConversationNotebookAndEmptyMessage() throws {
    let service = try makeService()
    let note = try service.createNote(bodyMarkdown: "# Plain\nBody.")
    XCTAssertThrowsError(try service.appendPendingAgentChatTurn(
      conversationNotebookId: note.notebookId,
      userMarkdown: "hello",
      agentAvailable: true
    ))
    let conversation = try service.startAgentConversation(subjectNoteId: note.noteId)
    XCTAssertThrowsError(try service.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "   ",
      agentAvailable: true
    ))
  }

  func testListAgentConversationsFindsBySubject() throws {
    let service = try makeService()
    let subject = try service.createNote(bodyMarkdown: "# Subject\nBody.")
    let other = try service.createNote(bodyMarkdown: "# Other\nBody.")
    let conversationA = try service.startAgentConversation(subjectNoteId: subject.noteId)
    _ = try service.startAgentConversation(subjectNoteId: other.noteId)
    _ = try service.appendPendingAgentChatTurn(
      conversationNotebookId: conversationA.notebookId,
      userMarkdown: "Q1",
      agentAvailable: false
    )

    let conversations = try service.listAgentConversations(subjectNoteId: subject.noteId)
    XCTAssertEqual(conversations.count, 1)
    XCTAssertEqual(conversations[0].notebook.notebookId, conversationA.notebookId)
    XCTAssertEqual(conversations[0].turnCount, 1)
  }

  func testGenerateReplyCompletesPendingTurnAndSkipsAnswered() async throws {
    let service = try makeService()
    let subject = try service.createNote(bodyMarkdown: "# Subject\nDocument content.")
    let conversation = try service.startAgentConversation(subjectNoteId: subject.noteId)
    let turn = try service.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "Summarize this.",
      agentAvailable: true
    )
    try await service.generateAgentChatReply(
      turnNoteId: turn.noteId,
      invoker: StubChatInvoker(reply: "A concise summary.")
    )
    let answered = try service.getNote(turn.noteId)
    XCTAssertEqual(NoteService.chatTurnState(of: answered)?.status, .answered)
    XCTAssertTrue(answered.bodyMarkdown.contains("A concise summary."))

    // A retry must not re-invoke (an error invoker would throw).
    try await service.generateAgentChatReply(
      turnNoteId: turn.noteId,
      invoker: StubChatInvoker(reply: "", error: .failed("must not be called"))
    )
    XCTAssertEqual(
      NoteService.chatTurnState(of: try service.getNote(turn.noteId))?.status,
      .answered
    )
  }

  func testGenerateReplyFailureMarksTurnFailedAndStaysRetryable() async throws {
    let service = try makeService()
    let subject = try service.createNote(bodyMarkdown: "# Subject\nBody.")
    let conversation = try service.startAgentConversation(subjectNoteId: subject.noteId)
    let turn = try service.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "Question",
      agentAvailable: true
    )
    do {
      try await service.generateAgentChatReply(
        turnNoteId: turn.noteId,
        invoker: StubChatInvoker(reply: "", error: .unavailable("down"))
      )
      XCTFail("expected throw")
    } catch {}
    XCTAssertEqual(
      NoteService.chatTurnState(of: try service.getNote(turn.noteId))?.status,
      .failed
    )

    // A later retry succeeds and answers the turn.
    try await service.generateAgentChatReply(
      turnNoteId: turn.noteId,
      invoker: StubChatInvoker(reply: "Recovered answer.")
    )
    XCTAssertEqual(
      NoteService.chatTurnState(of: try service.getNote(turn.noteId))?.status,
      .answered
    )
  }

  // MARK: - Note edit mode

  func testNoteEditReplyParsesBodyAndCommentary() {
    let reply = """
    Intro remark.
    <kaiba-note-body>
    # Revised
    New content.
    </kaiba-note-body>
    Tightened the wording.
    """
    let parsed = NoteService.noteEditReply(from: reply)
    XCTAssertEqual(parsed.bodyMarkdown, "# Revised\nNew content.")
    XCTAssertTrue(parsed.commentary.contains("Intro remark."))
    XCTAssertTrue(parsed.commentary.contains("Tightened the wording."))

    let plain = NoteService.noteEditReply(from: "Which section should change?")
    XCTAssertNil(plain.bodyMarkdown)
    XCTAssertEqual(plain.commentary, "Which section should change?")

    // A blank replacement or an unterminated marker must never blank the note.
    XCTAssertNil(NoteService.noteEditReply(from: "<kaiba-note-body>\n  \n</kaiba-note-body>").bodyMarkdown)
    XCTAssertNil(NoteService.noteEditReply(from: "<kaiba-note-body>\n# Half").bodyMarkdown)
  }

  func testAppendEditTurnSnapshotsModeAndRequiresWritableNoteSubject() throws {
    let service = try makeService()
    let subject = try service.createNote(bodyMarkdown: "# Subject\nBody.")
    let conversation = try service.startAgentConversation(subjectNoteId: subject.noteId)

    let turn = try service.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "Fix the title",
      agentAvailable: true,
      mode: .edit
    )
    XCTAssertEqual(NoteService.chatTurnState(of: turn)?.mode, .edit)
    let answered = try service.completeAgentChatTurn(
      turnNoteId: turn.noteId,
      assistantMarkdown: "Done."
    )
    XCTAssertEqual(NoteService.chatTurnState(of: answered)?.mode, .edit)

    _ = try service.setReadOnly(noteId: subject.noteId, readOnly: true)
    XCTAssertThrowsError(try service.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "Edit a locked note",
      agentAvailable: true,
      mode: .edit
    ))
    _ = try service.setReadOnly(noteId: subject.noteId, readOnly: false)
    _ = try service.setNotebookReadOnly(notebookId: subject.notebookId, readOnly: true)
    XCTAssertThrowsError(try service.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "Edit inside a locked notebook",
      agentAvailable: true,
      mode: .edit
    ))
    // Memo turns stay available on exactly the subjects edit mode refuses.
    XCTAssertNoThrow(try service.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "A memo question about a locked note",
      agentAvailable: true
    ))

    let other = try service.createNote(bodyMarkdown: "# Other\nBody.")
    let notebookConversation = try service.startAgentConversation(subjectNotebookId: other.notebookId)
    XCTAssertThrowsError(try service.appendPendingAgentChatTurn(
      conversationNotebookId: notebookConversation.notebookId,
      userMarkdown: "Edit the notebook",
      agentAvailable: true,
      mode: .edit
    ))
  }

  func testGenerateEditReplyAppliesBodyAndRecordsSummary() async throws {
    let service = try makeService()
    let subject = try service.createNote(bodyMarkdown: "# Subject\nOriginal body.")
    let conversation = try service.startAgentConversation(subjectNoteId: subject.noteId)
    let turn = try service.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "Reword the body",
      agentAvailable: true,
      mode: .edit
    )
    let reply = """
    <kaiba-note-body>
    # Subject
    Reworded body.
    </kaiba-note-body>
    Reworded the body as requested.
    """
    try await service.generateAgentChatReply(
      turnNoteId: turn.noteId,
      invoker: StubChatInvoker(reply: reply)
    )
    XCTAssertEqual(
      try service.getNote(subject.noteId).bodyMarkdown,
      "# Subject\nReworded body."
    )
    let answered = try service.getNote(turn.noteId)
    XCTAssertEqual(NoteService.chatTurnState(of: answered)?.status, .answered)
    XCTAssertTrue(answered.bodyMarkdown.contains("Reworded the body as requested."))
    XCTAssertFalse(answered.bodyMarkdown.contains(NoteService.noteEditBodyOpening))
  }

  func testGenerateEditReplyUsesEditPromptAndPlainReplyLeavesNoteUntouched() async throws {
    let service = try makeService()
    let subject = try service.createNote(bodyMarkdown: "# Subject\nOriginal body.")
    let conversation = try service.startAgentConversation(subjectNoteId: subject.noteId)
    let turn = try service.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "Improve it somehow",
      agentAvailable: true,
      mode: .edit
    )
    let invoker = CapturingChatInvoker()
    try await service.generateAgentChatReply(turnNoteId: turn.noteId, invoker: invoker)
    let capturedRequest = await invoker.latestRequest()
    let request = try XCTUnwrap(capturedRequest)
    XCTAssertEqual(request.systemPrompt, NoteService.noteEditSystemPrompt)

    // "captured" carries no markers: the reply lands as a plain answer and the
    // note is untouched.
    XCTAssertEqual(try service.getNote(subject.noteId).bodyMarkdown, "# Subject\nOriginal body.")
    let answered = try service.getNote(turn.noteId)
    XCTAssertEqual(NoteService.chatTurnState(of: answered)?.status, .answered)
    XCTAssertTrue(answered.bodyMarkdown.contains("captured"))
  }

  func testGenerateEditReplyFailsWhenNoteLockedAfterAccept() async throws {
    let service = try makeService()
    let subject = try service.createNote(bodyMarkdown: "# Subject\nOriginal body.")
    let conversation = try service.startAgentConversation(subjectNoteId: subject.noteId)
    let turn = try service.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "Reword the body",
      agentAvailable: true,
      mode: .edit
    )
    _ = try service.setReadOnly(noteId: subject.noteId, readOnly: true)
    let reply = "<kaiba-note-body>\n# Subject\nReworded.\n</kaiba-note-body>"
    do {
      try await service.generateAgentChatReply(
        turnNoteId: turn.noteId,
        invoker: StubChatInvoker(reply: reply)
      )
      XCTFail("expected the locked note to refuse the edit")
    } catch {}
    XCTAssertEqual(
      NoteService.chatTurnState(of: try service.getNote(turn.noteId))?.status,
      .failed
    )
    XCTAssertEqual(try service.getNote(subject.noteId).bodyMarkdown, "# Subject\nOriginal body.")
  }
}
