import Foundation
import AppCore
import XCTest
@testable import AppGraphQL

final class NoteGraphQLIngestReconciliationTests: XCTestCase {
  func testAutoActionsBecomeEligibleOnlyAfterIngestFinalization() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/ingest-auto-action-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let driver = SQLiteNoteDatabaseDriver(noteRoot: root.path)
    let dispatcher = IngestFinalStateDispatcher(driver: driver)
    let noteService = try NoteService(driver: driver, autoActionDispatcher: dispatcher)
    _ = try noteService.configureAutoAction(
      actionId: AutoActionID("ingest-final-state"),
      trigger: .noteCreated,
      workflowId: WorkflowID("observe-ingest-final-state")
    )
    var graphQL = GraphQLNoteGraphQLService(service: noteService)
    let reconciliationEntered = DispatchSemaphore(value: 0)
    let allowReconciliation = DispatchSemaphore(value: 0)
    graphQL.ingestReadOnlyMutation = { service, noteId, readOnly in
      reconciliationEntered.signal()
      allowReconciliation.wait()
      return try service.setReadOnly(noteId: noteId, readOnly: readOnly)
    }

    let task = Task {
      await graphQL.ingestNotebookPages(GraphQLIngestNotebookPagesInput(
        idempotencyKey: "deferred-auto-action",
        title: "Deferred auto-action ingest",
        pages: [GraphQLIngestNotebookPageInput(
          bodyMarkdown: "# Finalized page",
          pageImage: GraphQLIngestAttachmentInput(
            contentBase64: Data("final attachment".utf8).base64EncodedString(),
            mediaType: "text/plain",
            originalFilename: "final.txt"
          )
        )]
      ))
    }

    XCTAssertEqual(reconciliationEntered.wait(timeout: .now() + 2), .success)
    XCTAssertTrue(try noteService.listAutoActionDispatchAttempts().isEmpty)
    allowReconciliation.signal()
    let result = await task.value
    XCTAssertTrue(result.result.accepted, result.result.diagnostics.joined(separator: "; "))
    await noteService.drainAutoActionDispatches()

    XCTAssertEqual(try noteService.listAutoActionDispatchAttempts().count, 1)
    let observed = try XCTUnwrap(dispatcher.observations().first)
    XCTAssertTrue(observed.readOnly)
    XCTAssertEqual(observed.fileCount, 1)
  }

  func testReadOnlyFailuresRetainAuthoritativeCommittedEvidence() async throws {
    for hasAttachmentFailure in [false, true] {
      for failingCall in 0..<3 {
        try await assertReconciliationFailure(
          failingCall: failingCall,
          hasAttachmentFailure: hasAttachmentFailure
        )
      }
    }
  }

  func testAttachmentFailureKeepsAutoActionsIneligible() async throws {
    let fixture = try makeService(suffix: "attachment-failure")
    var graphQL = fixture.graphQL
    graphQL.ingestNoteAttachmentMutation = { _, _, _, _, _, _, _ in
      throw IngestReconciliationFault.injected
    }
    let result = await graphQL.ingestNotebookPages(GraphQLIngestNotebookPagesInput(
      idempotencyKey: "attachment-failure",
      title: "Attachment fault",
      pages: [GraphQLIngestNotebookPageInput(
        bodyMarkdown: "# Page",
        pageImage: GraphQLIngestAttachmentInput(
          contentBase64: Data("rejected".utf8).base64EncodedString(),
          mediaType: "application/octet-stream",
          originalFilename: "rejected.bin"
        )
      )]
    ))

    XCTAssertFalse(result.result.accepted)
    XCTAssertEqual(result.result.status, "partial-failure")
    await graphQL.service.drainAutoActionDispatches()
    XCTAssertTrue(try graphQL.service.listAutoActionDispatchAttempts().isEmpty)
    XCTAssertTrue(fixture.dispatcher.observations().isEmpty)
  }

  func testReadbackFailuresKeepAutoActionsIneligible() async throws {
    for failingCall in 0..<3 {
      let fixture = try makeService(suffix: "readback-\(failingCall)")
      var graphQL = fixture.graphQL
      let counter = IngestReconciliationCallCounter(failingCall: failingCall)
      graphQL.ingestNoteReadback = { service, noteId in
        if counter.shouldFail() {
          throw IngestReconciliationFault.injected
        }
        return try service.getNote(noteId)
      }

      let result = await graphQL.ingestNotebookPages(GraphQLIngestNotebookPagesInput(
        idempotencyKey: "readback-fault-\(failingCall)",
        title: "Readback fault",
        pages: [1, 2, 3].map { (number: Int) in
          GraphQLIngestNotebookPageInput(bodyMarkdown: "# Page \(number)", noteNumber: number)
        }
      ))

      XCTAssertFalse(result.result.accepted)
      XCTAssertEqual(result.result.status, "partial-failure")
      XCTAssertEqual(result.notes.count, 3)
      await graphQL.service.drainAutoActionDispatches()
      XCTAssertTrue(try graphQL.service.listAutoActionDispatchAttempts().isEmpty)
      XCTAssertTrue(fixture.dispatcher.observations().isEmpty)
    }
  }

  func testCompletionFailurePreservesIdentitiesAndRetryFinalizesTheClaim() async throws {
    let fixture = try makeService(suffix: "completion-recovery")
    var graphQL = fixture.graphQL
    let fault = IngestReconciliationCallCounter(failingCall: 0)
    graphQL.ingestCompletionMutation = { service, identity, ingest, resultJSON, enqueue, actionId in
      if fault.shouldFail() {
        throw IngestReconciliationFault.injected
      }
      try service.completeNotebookIngestRequest(
        identity,
        ingest: ingest,
        resultJSON: resultJSON,
        enqueueAutoActions: enqueue,
        originatingActionId: actionId
      )
    }
    let input = GraphQLIngestNotebookPagesInput(
      idempotencyKey: "completion-recovery",
      title: "Completion recovery",
      pages: [GraphQLIngestNotebookPageInput(
        bodyMarkdown: "# Recoverable page",
        pageImage: GraphQLIngestAttachmentInput(
          contentBase64: Data("recoverable page".utf8).base64EncodedString(),
          mediaType: "image/png",
          originalFilename: "page.png"
        )
      )],
      sourceDocument: GraphQLIngestAttachmentInput(
        contentBase64: Data("recoverable source".utf8).base64EncodedString(),
        mediaType: "application/pdf",
        originalFilename: "source.pdf"
      )
    )

    let initial = await graphQL.ingestNotebookPages(input)
    XCTAssertFalse(initial.result.accepted)
    XCTAssertEqual(initial.result.status, "retryable")
    let notebookId = try XCTUnwrap(initial.notebook?.notebookId)
    let noteIds = initial.notes.map(\.noteId)
    let noteFileIds = initial.noteFiles.map(\.file.fileId)
    let notebookFileIds = initial.notebookFiles.map(\.file.fileId)
    XCTAssertEqual(noteIds.count, 1)
    XCTAssertEqual(noteFileIds.count, 1)
    XCTAssertEqual(notebookFileIds.count, 1)
    XCTAssertFalse(try graphQL.service.listNotebooks().contains { $0.notebookId == notebookId })
    XCTAssertFalse(try graphQL.service.listNotes().contains { noteIds.contains($0.noteId) })

    let recovered = await graphQL.ingestNotebookPages(input)
    XCTAssertTrue(
      recovered.result.accepted,
      "\(recovered.result.status): \(recovered.result.diagnostics.joined(separator: "; "))"
    )
    XCTAssertEqual(recovered.notebook?.notebookId, notebookId)
    XCTAssertEqual(recovered.notes.map(\.noteId), noteIds)
    XCTAssertEqual(recovered.noteFiles.map(\.file.fileId), noteFileIds)
    XCTAssertEqual(recovered.notebookFiles.map(\.file.fileId), notebookFileIds)
    XCTAssertTrue(try graphQL.service.listNotebooks().contains { $0.notebookId == notebookId })
    await graphQL.service.drainAutoActionDispatches()
    XCTAssertEqual(try graphQL.service.listAutoActionDispatchAttempts().count, 1)
    let replay = await graphQL.ingestNotebookPages(input)
    XCTAssertEqual(replay, recovered)
    XCTAssertEqual(try graphQL.service.listAutoActionDispatchAttempts().count, 1)
  }

  func testCompletionAndRecoveryFailuresReleaseExecutionForSameProcessRetry() async throws {
    let fixture = try makeService(suffix: "completion-and-recovery-failure")
    var graphQL = fixture.graphQL
    let completionFault = IngestReconciliationCallCounter(failingCall: 0)
    let recoveryFault = IngestReconciliationCallCounter(failingCall: 0)
    graphQL.ingestCompletionMutation = { service, identity, ingest, resultJSON, enqueue, actionId in
      if completionFault.shouldFail() {
        throw IngestReconciliationFault.injected
      }
      try service.completeNotebookIngestRequest(
        identity,
        ingest: ingest,
        resultJSON: resultJSON,
        enqueueAutoActions: enqueue,
        originatingActionId: actionId
      )
    }
    graphQL.ingestRecoveryMutation = { service, identity, ingest, resultJSON, enqueue, actionId in
      if recoveryFault.shouldFail() {
        throw IngestReconciliationFault.injected
      }
      try service.recordNotebookIngestRecovery(
        identity,
        ingest: ingest,
        resultJSON: resultJSON,
        enqueueAutoActions: enqueue,
        originatingActionId: actionId
      )
    }
    let input = GraphQLIngestNotebookPagesInput(
      idempotencyKey: "completion-and-recovery-failure",
      title: "Completion and recovery failure",
      pages: [GraphQLIngestNotebookPageInput(bodyMarkdown: "# Recoverable page")]
    )

    let initial = await graphQL.ingestNotebookPages(input)
    XCTAssertFalse(initial.result.accepted)
    XCTAssertEqual(initial.result.status, "retryable")
    let notebookId = try XCTUnwrap(initial.notebook?.notebookId)
    let noteIds = initial.notes.map(\.noteId)
    XCTAssertEqual(completionFault.callCount, 1)
    XCTAssertEqual(recoveryFault.callCount, 1)
    XCTAssertFalse(try graphQL.service.listNotebooks().contains { $0.notebookId == notebookId })

    let recovered = await graphQL.ingestNotebookPages(input)
    XCTAssertTrue(
      recovered.result.accepted,
      "\(recovered.result.status): \(recovered.result.diagnostics.joined(separator: "; "))"
    )
    XCTAssertEqual(recovered.notebook?.notebookId, notebookId)
    XCTAssertEqual(recovered.notes.map(\.noteId), noteIds)
    XCTAssertEqual(completionFault.callCount, 2)
    XCTAssertEqual(recoveryFault.callCount, 1)
    XCTAssertTrue(try graphQL.service.listNotebooks().contains { $0.notebookId == notebookId })
    let replay = await graphQL.ingestNotebookPages(input)
    XCTAssertEqual(replay, recovered)
  }

  private func assertReconciliationFailure(
    failingCall: Int,
    hasAttachmentFailure: Bool
  ) async throws {
    let fixture = try makeService(
      suffix: "\(hasAttachmentFailure)-\(failingCall)"
    )
    var graphQL = fixture.graphQL
    let counter = IngestReconciliationCallCounter(failingCall: failingCall)
    graphQL.ingestReadOnlyMutation = { service, noteId, readOnly in
      if counter.shouldFail() {
        throw IngestReconciliationFault.injected
      }
      return try service.setReadOnly(noteId: noteId, readOnly: readOnly)
    }
    if hasAttachmentFailure {
      let attachmentCounter = IngestReconciliationCallCounter(failingCall: 1)
      graphQL.ingestNoteAttachmentMutation = { service, noteId, data, role, mediaType, filename, position in
        if attachmentCounter.shouldFail() {
          throw IngestReconciliationFault.injected
        }
        return try service.attachFile(
          noteId: noteId,
          data: data,
          role: role,
          mediaType: mediaType,
          originalFilename: filename,
          position: position
        )
      }
    }

    let validAttachment = GraphQLIngestAttachmentInput(
      contentBase64: Data("committed".utf8).base64EncodedString(),
      mediaType: "application/octet-stream",
      originalFilename: "committed.bin"
    )
    let failingAttachment = GraphQLIngestAttachmentInput(
      contentBase64: Data("rejected".utf8).base64EncodedString(),
      mediaType: "application/octet-stream",
      originalFilename: "rejected.bin"
    )
    let result = await graphQL.ingestNotebookPages(GraphQLIngestNotebookPagesInput(
      idempotencyKey: "reconciliation-\(hasAttachmentFailure)-\(failingCall)",
      title: "Reconciliation fault",
      pages: [
        GraphQLIngestNotebookPageInput(
          bodyMarkdown: "# First",
          noteNumber: 1,
          pageImage: hasAttachmentFailure ? validAttachment : nil
        ),
        GraphQLIngestNotebookPageInput(
          bodyMarkdown: "# Middle",
          noteNumber: 2,
          pageImage: hasAttachmentFailure ? failingAttachment : nil
        ),
        GraphQLIngestNotebookPageInput(bodyMarkdown: "# Final", noteNumber: 3)
      ],
      sourceDocument: hasAttachmentFailure ? validAttachment : nil
    ))

    XCTAssertFalse(result.result.accepted)
    XCTAssertEqual(result.result.status, "partial-failure")
    XCTAssertNotNil(result.notebook)
    XCTAssertEqual(result.notes.count, 3)
    XCTAssertEqual(Set(result.notes.map(\.noteId)).count, 3)
    XCTAssertEqual(
      result.notes.map(\.readOnly),
      (0..<3).map { $0 != failingCall }
    )
    XCTAssertEqual(result.notebookFiles.count, hasAttachmentFailure ? 1 : 0)
    XCTAssertEqual(result.noteFiles.count, hasAttachmentFailure ? 1 : 0)

    for (index, note) in result.notes.enumerated() {
      XCTAssertEqual(try graphQL.service.getNote(note.noteId).readOnly, index != failingCall)
    }
    await graphQL.service.drainAutoActionDispatches()
    XCTAssertTrue(try graphQL.service.listAutoActionDispatchAttempts().isEmpty)
    XCTAssertTrue(fixture.dispatcher.observations().isEmpty)
  }

  private func makeService(
    suffix: String
  ) throws -> (graphQL: GraphQLNoteGraphQLService, dispatcher: IngestFinalStateDispatcher) {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent(
        "tmp/ingest-reconciliation-\(suffix)-\(UUID().uuidString)",
        isDirectory: true
      )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let driver = SQLiteNoteDatabaseDriver(noteRoot: root.path)
    let dispatcher = IngestFinalStateDispatcher(driver: driver)
    let service = try NoteService(driver: driver, autoActionDispatcher: dispatcher)
    _ = try service.configureAutoAction(
      actionId: AutoActionID("ingest-partial-failure"),
      trigger: .noteCreated,
      workflowId: WorkflowID("must-not-observe-partial-ingest")
    )
    return (GraphQLNoteGraphQLService(service: service), dispatcher)
  }
}

private final class IngestFinalStateDispatcher: AutoActionDispatching, @unchecked Sendable {
  struct Observation {
    var readOnly: Bool
    var fileCount: Int
  }

  private let driver: NoteDatabaseDriving
  private let lock = NSLock()
  private var storedObservations: [Observation] = []

  init(driver: NoteDatabaseDriving) {
    self.driver = driver
  }

  func dispatch(_ record: AutoActionDispatchRecord) async throws -> AutoActionDispatchOutcome {
    let noteId = try XCTUnwrap(record.event.noteId)
    let service = try NoteService(driver: driver)
    let observation = Observation(
      readOnly: try service.getNote(noteId).readOnly,
      fileCount: try service.listFiles(noteId: noteId).count
    )
    lock.withLock {
      storedObservations.append(observation)
    }
    return .succeeded
  }

  func observations() -> [Observation] {
    lock.withLock { storedObservations }
  }
}

private enum IngestReconciliationFault: Error {
  case injected
}

private final class IngestReconciliationCallCounter: @unchecked Sendable {
  private let lock = NSLock()
  private let failingCall: Int
  private var call = 0

  init(failingCall: Int) {
    self.failingCall = failingCall
  }

  func shouldFail() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    defer { call += 1 }
    return call == failingCall
  }

  var callCount: Int {
    lock.withLock { call }
  }
}
