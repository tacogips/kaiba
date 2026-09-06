import Foundation
import AppCore
import XCTest
@testable import AppGraphQL
@testable import AppServer

final class NotebookIngestConcurrencyTests: XCTestCase {
  func testDuplicateWaitersUseOneClaimEachAndStopAfterCancellation() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/ingest-cancellation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let driver = SQLiteNoteDatabaseDriver(noteRoot: root.path)
    let noteService = try NoteService(driver: driver).scoped(to: NoteStoreSchema.defaultUserId)
    let attachmentEntered = DispatchSemaphore(value: 0)
    let allowAttachment = DispatchSemaphore(value: 0)
    var owningGraphQL = GraphQLNoteGraphQLService(service: noteService)
    owningGraphQL.ingestNoteAttachmentMutation = { service, noteId, data, role, mediaType, filename, position in
      attachmentEntered.signal()
      allowAttachment.wait()
      return try service.attachFile(
        noteId: noteId,
        data: data,
        role: role,
        mediaType: mediaType,
        originalFilename: filename,
        position: position
      )
    }
    let input = GraphQLIngestNotebookPagesInput(
      idempotencyKey: "cancelled-duplicate-ingest",
      title: "Cancellation-safe ingest",
      pages: [GraphQLIngestNotebookPageInput(
        bodyMarkdown: "# Cancellation-safe page",
        pageImage: GraphQLIngestAttachmentInput(
          contentBase64: Data("page image".utf8).base64EncodedString(),
          mediaType: "image/png"
        )
      )]
    )
    let owner = Task { await owningGraphQL.ingestNotebookPages(input) }
    XCTAssertEqual(attachmentEntered.wait(timeout: .now() + 2), .success)

    let claimCounter = NotebookIngestClaimCounter()
    var waitingGraphQL = GraphQLNoteGraphQLService(service: noteService)
    waitingGraphQL.ingestClaimInitialBackoff = .seconds(5)
    waitingGraphQL.ingestClaimMaximumBackoff = .seconds(5)
    waitingGraphQL.ingestClaimObserver = { claimCounter.record($0) }
    let configuredWaitingGraphQL = waitingGraphQL
    let waiterCount = 12
    let waiters = (0..<waiterCount).map { _ in
      Task { await configuredWaitingGraphQL.ingestNotebookPages(input) }
    }
    for _ in 0..<waiterCount {
      XCTAssertEqual(claimCounter.pendingObserved.wait(timeout: .now() + 2), .success)
    }
    XCTAssertEqual(claimCounter.claimCount, waiterCount)
    let durableClaimCount = try driver.withDatabase { database in
      try database.query(
        "SELECT COUNT(*) AS count FROM app_settings WHERE setting_key LIKE 'auth.ingest.%'"
      ).first?["count"].flatMap(Int.init)
    }
    XCTAssertEqual(durableClaimCount, 1)

    waiters.forEach { $0.cancel() }
    var cancelledResults: [GraphQLNoteMutationResult] = []
    for waiter in waiters {
      cancelledResults.append(await waiter.value)
    }
    XCTAssertTrue(cancelledResults.allSatisfy { !$0.result.accepted })
    XCTAssertEqual(claimCounter.claimCount, waiterCount)

    let boundedCounter = NotebookIngestClaimCounter()
    var boundedGraphQL = GraphQLNoteGraphQLService(service: noteService)
    boundedGraphQL.ingestClaimMaximumWait = .milliseconds(120)
    boundedGraphQL.ingestClaimInitialBackoff = .milliseconds(20)
    boundedGraphQL.ingestClaimMaximumBackoff = .milliseconds(40)
    boundedGraphQL.ingestClaimObserver = { boundedCounter.record($0) }
    let boundedResult = await boundedGraphQL.ingestNotebookPages(input)
    XCTAssertFalse(boundedResult.result.accepted)
    XCTAssertEqual(boundedResult.result.status, "invalid_request")
    XCTAssertLessThanOrEqual(boundedCounter.claimCount, 5)

    allowAttachment.signal()
    let completed = await owner.value
    XCTAssertTrue(completed.result.accepted)
    let replay = await GraphQLNoteGraphQLService(service: noteService).ingestNotebookPages(input)
    XCTAssertEqual(replay, completed)
    XCTAssertEqual(try noteService.listNotebooks().count, 1)
    XCTAssertEqual(try noteService.listNotes().count, 1)
  }

  func testConcurrentRetryStaysHiddenAndPublishesOneFinalizedEvent() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/ingest-concurrency-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let feed = NoteChangeFeed()
    let noteService = try NoteService(
      driver: SQLiteNoteDatabaseDriver(noteRoot: root.path),
      changeObserver: NoteChangeFeedObserver(feed: feed)
    ).scoped(to: NoteStoreSchema.defaultUserId)
    var graphQL = GraphQLNoteGraphQLService(service: noteService)
    let attachmentEntered = DispatchSemaphore(value: 0)
    let allowAttachment = DispatchSemaphore(value: 0)
    let reconciliationEntered = DispatchSemaphore(value: 0)
    let allowReconciliation = DispatchSemaphore(value: 0)
    graphQL.ingestNoteAttachmentMutation = { service, noteId, data, role, mediaType, filename, position in
      attachmentEntered.signal()
      allowAttachment.wait()
      return try service.attachFile(
        noteId: noteId,
        data: data,
        role: role,
        mediaType: mediaType,
        originalFilename: filename,
        position: position
      )
    }
    graphQL.ingestReadOnlyMutation = { service, noteId, readOnly in
      reconciliationEntered.signal()
      allowReconciliation.wait()
      return try service.setReadOnly(noteId: noteId, readOnly: readOnly)
    }
    let configuredGraphQL = graphQL
    let cursor = try await feed.poll(
      since: nil,
      principalId: "test",
      timeoutNanoseconds: 0,
      eventAuthorizer: { _ in true }
    ).revision
    let initialRevision = await feed.currentRevision
    let input = GraphQLIngestNotebookPagesInput(
      idempotencyKey: "concurrent-ingest",
      title: "Concurrent ingest",
      kindTagName: "pending-kind",
      pages: [GraphQLIngestNotebookPageInput(
        bodyMarkdown: "# Page",
        tags: [GraphQLNoteTagInput(name: "pending-topic")],
        pageImage: GraphQLIngestAttachmentInput(
          contentBase64: Data("page image".utf8).base64EncodedString(),
          mediaType: "image/png"
        )
      )]
    )

    let first = Task { await configuredGraphQL.ingestNotebookPages(input) }
    XCTAssertEqual(attachmentEntered.wait(timeout: .now() + 2), .success)
    let pendingService = noteService.pendingNotebookIngestScope()
    let hiddenNotebook = try XCTUnwrap(try pendingService.listNotebooks().first)
    let hiddenNote = try XCTUnwrap(try pendingService.listNotes().first)
    let pendingTag = try XCTUnwrap(try pendingService.listTags().first { $0.name == "pending-topic" })
    let pendingKindTag = try XCTUnwrap(try pendingService.listTags().first { $0.name == "pending-kind" })
    _ = try pendingService.addComment(
      noteId: hiddenNote.noteId,
      bodyMarkdown: "pending comment",
      author: "test"
    )
    _ = try pendingService.addNotebookComment(
      notebookId: hiddenNotebook.notebookId,
      bodyMarkdown: "pending notebook comment",
      author: "test"
    )
    XCTAssertTrue(try noteService.listNotebooks().isEmpty)
    XCTAssertTrue(try noteService.listNotes().isEmpty)
    XCTAssertTrue(try noteService.actionHistory().isEmpty)
    XCTAssertFalse(try noteService.listTags().contains { $0.name == "pending-topic" })
    XCTAssertFalse(try noteService.listTags().contains { $0.name == "pending-kind" })
    let pendingGraphQLResult = await configuredGraphQL.tags()
    let pendingGraphQLTags = try XCTUnwrap(pendingGraphQLResult.value)
    XCTAssertFalse(pendingGraphQLTags.contains { $0.name == "pending-topic" })
    XCTAssertFalse(pendingGraphQLTags.contains { $0.name == "pending-kind" })
    XCTAssertEqual(try noteService.tagDetail(tagId: pendingTag.tagId).noteCount, 0)
    XCTAssertEqual(try noteService.tagDetail(tagId: pendingKindTag.tagId).notebookCount, 0)
    XCTAssertFalse(try noteService.tagContextMarkdown(tagId: pendingTag.tagId).contains("# Page"))
    XCTAssertTrue(try noteService.listTagComments(tagId: pendingTag.tagId).isEmpty)
    XCTAssertTrue(try noteService.listTagComments(tagId: pendingKindTag.tagId).isEmpty)
    try assertPendingIngestIsHidden(
      service: noteService,
      notebookId: hiddenNotebook.notebookId,
      noteId: hiddenNote.noteId
    )
    let attachmentRevision = await feed.currentRevision
    XCTAssertEqual(attachmentRevision, initialRevision)
    allowAttachment.signal()
    XCTAssertEqual(reconciliationEntered.wait(timeout: .now() + 2), .success)
    let retry = Task { await configuredGraphQL.ingestNotebookPages(input) }
    XCTAssertTrue(try noteService.listNotebooks().isEmpty)
    XCTAssertTrue(try noteService.listNotes().isEmpty)
    XCTAssertTrue(try noteService.actionHistory().isEmpty)
    try assertPendingIngestIsHidden(
      service: noteService,
      notebookId: hiddenNotebook.notebookId,
      noteId: hiddenNote.noteId
    )
    let pendingRevision = await feed.currentRevision
    XCTAssertEqual(pendingRevision, initialRevision)

    allowReconciliation.signal()
    let firstResult = await first.value
    let retryResult = await retry.value
    XCTAssertTrue(firstResult.result.accepted)
    XCTAssertEqual(retryResult, firstResult)
    XCTAssertEqual(try noteService.listNotebooks().count, 1)
    XCTAssertEqual(try noteService.listNotes().count, 1)
    XCTAssertEqual(try noteService.getNotebook(hiddenNotebook.notebookId).notebookId, hiddenNotebook.notebookId)
    XCTAssertEqual(try noteService.getNote(hiddenNote.noteId).noteId, hiddenNote.noteId)
    XCTAssertEqual(try noteService.searchNotes(query: "Page").map(\.note.noteId), [hiddenNote.noteId])
    XCTAssertTrue(try noteService.listTags().contains { $0.name == "pending-topic" })
    XCTAssertTrue(try noteService.listTags().contains { $0.name == "pending-kind" })
    let visibleGraphQLResult = await configuredGraphQL.tags()
    let visibleGraphQLTags = try XCTUnwrap(visibleGraphQLResult.value)
    XCTAssertTrue(visibleGraphQLTags.contains { $0.name == "pending-topic" })
    XCTAssertTrue(visibleGraphQLTags.contains { $0.name == "pending-kind" })
    XCTAssertEqual(try noteService.tagDetail(tagId: pendingTag.tagId).noteCount, 1)
    XCTAssertEqual(try noteService.tagDetail(tagId: pendingKindTag.tagId).notebookCount, 1)
    XCTAssertTrue(try noteService.tagContextMarkdown(tagId: pendingTag.tagId).contains("# Page"))
    XCTAssertEqual(try noteService.listTagComments(tagId: pendingTag.tagId).count, 1)
    XCTAssertEqual(try noteService.listTagComments(tagId: pendingKindTag.tagId).count, 1)
    XCTAssertEqual(try noteService.actionHistory().map(\.kind), [.notebookIngested])

    let deadline = Date().addingTimeInterval(2)
    while await feed.currentRevision == initialRevision, Date() < deadline {
      await Task.yield()
    }
    let poll = try await feed.poll(
      since: cursor,
      principalId: "test",
      timeoutNanoseconds: 0,
      eventAuthorizer: { _ in true }
    )
    XCTAssertEqual(poll.events.map(\.kind), [NoteChangeEventKind.notebookCreated])
    XCTAssertEqual(poll.events.first?.notebookId?.rawValue, firstResult.notebook?.notebookId.rawValue)
  }

  func testWaitingRetryReclaimsClaimAbandonedBeforeNotebookCreation() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/ingest-reclaim-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let noteService = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
      .scoped(to: NoteStoreSchema.defaultUserId)
    let claimedRequestEntered = DispatchSemaphore(value: 0)
    let allowClaimedRequestToFail = DispatchSemaphore(value: 0)
    let waiterObservedPendingClaim = DispatchSemaphore(value: 0)
    let abandonmentCompleted = DispatchSemaphore(value: 0)
    let allowAbandoningInvocationToExit = DispatchSemaphore(value: 0)
    let reclaimedExecutionEntered = DispatchSemaphore(value: 0)
    let allowReclaimedExecution = DispatchSemaphore(value: 0)
    var abandoningGraphQL = GraphQLNoteGraphQLService(service: noteService)
    abandoningGraphQL.ingestBeforeNotebookCreation = {
      claimedRequestEntered.signal()
      allowClaimedRequestToFail.wait()
      throw NotebookIngestConcurrencyFault.beforeNotebookCreation
    }
    abandoningGraphQL.ingestAfterAbandonment = {
      abandonmentCompleted.signal()
      allowAbandoningInvocationToExit.wait()
    }
    var waitingGraphQL = GraphQLNoteGraphQLService(service: noteService)
    waitingGraphQL.ingestClaimObserver = { claim in
      if case .pending = claim {
        waiterObservedPendingClaim.signal()
      }
    }
    waitingGraphQL.ingestBeforeNotebookCreation = {
      reclaimedExecutionEntered.signal()
      allowReclaimedExecution.wait()
    }
    let configuredWaitingGraphQL = waitingGraphQL
    let input = GraphQLIngestNotebookPagesInput(
      idempotencyKey: "abandoned-claim-retry",
      title: "Reclaimed ingest",
      pages: [GraphQLIngestNotebookPageInput(bodyMarkdown: "# Reclaimed page")]
    )

    let abandoned = Task { await abandoningGraphQL.ingestNotebookPages(input) }
    XCTAssertEqual(claimedRequestEntered.wait(timeout: .now() + 2), .success)
    let waiter = Task { await configuredWaitingGraphQL.ingestNotebookPages(input) }
    XCTAssertEqual(waiterObservedPendingClaim.wait(timeout: .now() + 2), .success)
    allowClaimedRequestToFail.signal()
    XCTAssertEqual(abandonmentCompleted.wait(timeout: .now() + 2), .success)
    XCTAssertEqual(reclaimedExecutionEntered.wait(timeout: .now() + 2), .success)
    allowAbandoningInvocationToExit.signal()

    let abandonedResult = await abandoned.value
    let probeObservedClaim = DispatchSemaphore(value: 0)
    let probeExecutionEntered = DispatchSemaphore(value: 0)
    let allowProbeExecution = DispatchSemaphore(value: 0)
    let claimRecorder = NotebookIngestClaimRecorder()
    var probingGraphQL = GraphQLNoteGraphQLService(service: noteService)
    probingGraphQL.ingestClaimObserver = { claim in
      claimRecorder.record(claim)
      probeObservedClaim.signal()
    }
    probingGraphQL.ingestBeforeNotebookCreation = {
      probeExecutionEntered.signal()
      allowProbeExecution.wait()
      throw NotebookIngestConcurrencyFault.beforeNotebookCreation
    }
    let probe = Task { await probingGraphQL.ingestNotebookPages(input) }
    XCTAssertEqual(probeObservedClaim.wait(timeout: .now() + 2), .success)
    if case .pending = claimRecorder.claim {
      // The reclaimed owner remained registered after the old invocation exited.
    } else {
      XCTFail("expected the probe to remain pending behind the reclaimed owner")
    }
    probe.cancel()
    allowProbeExecution.signal()
    _ = await probe.value
    XCTAssertEqual(probeExecutionEntered.wait(timeout: .now()), .timedOut)

    allowReclaimedExecution.signal()
    let reclaimedResult = await waiter.value
    XCTAssertFalse(abandonedResult.result.accepted)
    XCTAssertTrue(reclaimedResult.result.accepted, reclaimedResult.result.diagnostics.joined(separator: "; "))
    XCTAssertEqual(try noteService.listNotebooks().map(\.title), ["Reclaimed ingest"])
    XCTAssertEqual(try noteService.listNotes().count, 1)
    let replay = await GraphQLNoteGraphQLService(service: noteService).ingestNotebookPages(input)
    XCTAssertEqual(replay, reclaimedResult)
  }

  func testRestartResumesAtomicCreatedStateAndPublishesHistoryOnlyAtReveal() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/ingest-restart-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let driver = SQLiteNoteDatabaseDriver(noteRoot: root.path)
    let initialService = try NoteService(driver: driver).scoped(to: NoteStoreSchema.defaultUserId)
    var interruptedGraphQL = GraphQLNoteGraphQLService(service: initialService)
    interruptedGraphQL.ingestAfterNotebookCreation = {
      throw NotebookIngestConcurrencyFault.afterNotebookCreation
    }
    let input = GraphQLIngestNotebookPagesInput(
      idempotencyKey: "restart-after-create",
      title: "Restart-safe ingest",
      pages: [GraphQLIngestNotebookPageInput(
        bodyMarkdown: "# Restart-safe page",
        pageImage: GraphQLIngestAttachmentInput(
          contentBase64: Data("restart image".utf8).base64EncodedString(),
          mediaType: "image/png",
          originalFilename: "page.png"
        )
      )],
      sourceDocument: GraphQLIngestAttachmentInput(
        contentBase64: Data("restart source".utf8).base64EncodedString(),
        mediaType: "application/pdf",
        originalFilename: "source.pdf"
      )
    )

    let interrupted = await interruptedGraphQL.ingestNotebookPages(input)
    XCTAssertFalse(interrupted.result.accepted)
    let hidden = try XCTUnwrap(try initialService.pendingNotebookIngestScope().listNotebooks().first)
    XCTAssertTrue(try initialService.listNotebooks().isEmpty)
    XCTAssertTrue(try initialService.actionHistory().isEmpty)

    let restartedService = try NoteService(driver: driver).scoped(to: NoteStoreSchema.defaultUserId)
    let recovered = await GraphQLNoteGraphQLService(service: restartedService).ingestNotebookPages(input)

    XCTAssertTrue(recovered.result.accepted, recovered.result.diagnostics.joined(separator: "; "))
    XCTAssertEqual(recovered.notebook?.notebookId, hidden.notebookId)
    XCTAssertEqual(try restartedService.listNotebooks().map(\.notebookId), [hidden.notebookId])
    XCTAssertEqual(recovered.noteFiles.count, 1)
    XCTAssertEqual(recovered.notebookFiles.count, 1)
    XCTAssertEqual(try restartedService.actionHistory().map(\.kind), [.notebookIngested])
    let replay = await GraphQLNoteGraphQLService(service: restartedService).ingestNotebookPages(input)
    XCTAssertEqual(replay, recovered)
    XCTAssertEqual(try restartedService.actionHistory().map(\.kind), [.notebookIngested])
  }

  func testRestartReusesAttachmentsCommittedBeforeProcessLoss() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/ingest-attachment-restart-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let driver = SQLiteNoteDatabaseDriver(noteRoot: root.path)
    let initialService = try NoteService(driver: driver).scoped(to: NoteStoreSchema.defaultUserId)
    var interruptedGraphQL = GraphQLNoteGraphQLService(service: initialService)
    interruptedGraphQL.ingestAfterAttachmentPhase = {
      throw NotebookIngestConcurrencyFault.afterAttachmentPhase
    }
    let input = GraphQLIngestNotebookPagesInput(
      idempotencyKey: "restart-after-attachments",
      title: "Attachment restart ingest",
      pages: [GraphQLIngestNotebookPageInput(
        bodyMarkdown: "# Attachment page",
        pageImage: GraphQLIngestAttachmentInput(
          contentBase64: Data("stable page image".utf8).base64EncodedString(),
          mediaType: "image/png",
          originalFilename: "page.png"
        )
      )],
      sourceDocument: GraphQLIngestAttachmentInput(
        contentBase64: Data("stable source document".utf8).base64EncodedString(),
        mediaType: "application/pdf",
        originalFilename: "source.pdf"
      )
    )

    let interrupted = await interruptedGraphQL.ingestNotebookPages(input)
    XCTAssertFalse(interrupted.result.accepted)
    let pending = initialService.pendingNotebookIngestScope()
    let hiddenNotebook = try XCTUnwrap(try pending.listNotebooks().first)
    let hiddenNote = try XCTUnwrap(try pending.listNotes().first)
    let notebookFileId = try XCTUnwrap(try pending.listFiles(notebookId: hiddenNotebook.notebookId).first?.file.fileId)
    let noteFileId = try XCTUnwrap(try pending.listFiles(noteId: hiddenNote.noteId).first?.file.fileId)

    let restartedService = try NoteService(driver: driver).scoped(to: NoteStoreSchema.defaultUserId)
    let recovered = await GraphQLNoteGraphQLService(service: restartedService).ingestNotebookPages(input)

    XCTAssertTrue(recovered.result.accepted, recovered.result.diagnostics.joined(separator: "; "))
    XCTAssertEqual(recovered.notebookFiles.map(\.file.fileId), [notebookFileId])
    XCTAssertEqual(recovered.noteFiles.map(\.file.fileId), [noteFileId])
    XCTAssertEqual(try restartedService.listFiles(notebookId: hiddenNotebook.notebookId).count, 1)
    XCTAssertEqual(try restartedService.listFiles(noteId: hiddenNote.noteId).count, 1)
  }

  func testCommittedResponseReplayAndChangedInputConflict() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/ingest-replay-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let noteService = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
      .scoped(to: NoteStoreSchema.defaultUserId)
    let graphQL = GraphQLNoteGraphQLService(service: noteService)
    let input = GraphQLIngestNotebookPagesInput(
      idempotencyKey: "lost-response-ingest",
      title: "Lost response",
      pages: [GraphQLIngestNotebookPageInput(bodyMarkdown: "# One")]
    )

    _ = await graphQL.ingestNotebookPages(input) // Simulate a committed response lost in transport.
    let replay = await graphQL.ingestNotebookPages(input)
    XCTAssertTrue(replay.result.accepted)
    XCTAssertEqual(try noteService.listNotebooks().count, 1)

    var changed = input
    changed.title = "Changed request"
    let conflict = await graphQL.ingestNotebookPages(changed)
    XCTAssertFalse(conflict.result.accepted)
    XCTAssertEqual(conflict.result.status, "invalid_request")
    XCTAssertEqual(try noteService.listNotebooks().count, 1)
  }

  func testIdempotencyKeyIsIndependentAcrossPrincipals() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/ingest-principal-scope-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
    let secondUser = try service.createUser(
      email: "second-ingest-principal@example.com",
      displayName: "Second ingest principal"
    )
    let firstService = service.scoped(to: NoteStoreSchema.defaultUserId)
    let secondService = service.scoped(to: secondUser.userId)
    let firstInput = GraphQLIngestNotebookPagesInput(
      idempotencyKey: "shared-principal-key",
      title: "First principal ingest",
      pages: [GraphQLIngestNotebookPageInput(bodyMarkdown: "# First principal")]
    )
    let secondInput = GraphQLIngestNotebookPagesInput(
      idempotencyKey: "shared-principal-key",
      title: "Second principal ingest",
      pages: [GraphQLIngestNotebookPageInput(bodyMarkdown: "# Second principal")]
    )

    async let first = GraphQLNoteGraphQLService(service: firstService).ingestNotebookPages(firstInput)
    async let second = GraphQLNoteGraphQLService(service: secondService).ingestNotebookPages(secondInput)
    let (firstResult, secondResult) = await (first, second)

    XCTAssertTrue(firstResult.result.accepted, firstResult.result.diagnostics.joined(separator: "; "))
    XCTAssertTrue(secondResult.result.accepted, secondResult.result.diagnostics.joined(separator: "; "))
    XCTAssertNotEqual(firstResult.notebook?.notebookId, secondResult.notebook?.notebookId)
    XCTAssertEqual(try firstService.listNotebooks().map(\.title), ["First principal ingest"])
    XCTAssertEqual(try secondService.listNotebooks().map(\.title), ["Second principal ingest"])
    let firstReplay = await GraphQLNoteGraphQLService(service: firstService)
      .ingestNotebookPages(firstInput)
    let secondReplay = await GraphQLNoteGraphQLService(service: secondService)
      .ingestNotebookPages(secondInput)
    XCTAssertEqual(firstReplay, firstResult)
    XCTAssertEqual(secondReplay, secondResult)
  }

  func testPendingSearchHitsDoNotConsumeLimitOrOffset() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/ingest-search-page-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
      .scoped(to: NoteStoreSchema.defaultUserId)
    let claim = try service.claimNotebookIngestRequest(
      idempotencyKey: "search-pagination",
      canonicalRequest: Data("search-pagination".utf8)
    )
    guard case let .execute(identity) = claim else {
      return XCTFail("expected a new ingest claim")
    }
    let pendingService = service.pendingNotebookIngestScope()
    let pending = try pendingService.createNotebookWithNotes(
      title: "Pending search ingest",
      metaJSON: try service.pendingNotebookIngestMetadata(callerMetadataJSON: nil, identity: identity),
      pages: [NotePageDraft(
        bodyMarkdown: "# 0 Pending\nshared pagination marker",
        readOnly: false
      )],
      autoActionPolicy: .deferredUntilFinalized
    )
    let visibleNotebook = try service.createNotebook(title: "Visible search notebook")
    let firstVisible = try service.createNote(
      notebookId: visibleNotebook.notebookId,
      title: "1 Visible",
      bodyMarkdown: "shared pagination marker"
    )
    let secondVisible = try service.createNote(
      notebookId: visibleNotebook.notebookId,
      title: "2 Visible",
      bodyMarkdown: "shared pagination marker"
    )
    _ = try pendingService.linkNotes(from: firstVisible.noteId, to: pending.notes[0].noteId)

    XCTAssertEqual(
      try service.searchNotes(query: "shared pagination marker", sort: .title, limit: 1).map(\.note.noteId),
      [firstVisible.noteId]
    )
    XCTAssertEqual(
      try service.searchNotes(
        query: "shared pagination marker",
        sort: .title,
        limit: 1,
        offset: 1
      ).map(\.note.noteId),
      [secondVisible.noteId]
    )
    let linked = try service.searchNotes(
      query: "1 Visible",
      includeLinked: true,
      depth: 1,
      limit: 20
    )
    XCTAssertFalse(linked.contains { $0.note.noteId == pending.notes[0].noteId })
    let forgedMetadata = #"{"_kaibaNotebookIngest":{"state":"pending","scopeKey":"forged"}}"#
    XCTAssertThrowsError(try service.createNotebook(title: "Forged", metaJSON: forgedMetadata))
    XCTAssertThrowsError(try service.createNotebookWithNotes(
      title: "Forged bulk",
      metaJSON: forgedMetadata,
      pages: [NotePageDraft(bodyMarkdown: "# Forged", readOnly: false)]
    ))
  }

  private func assertPendingIngestIsHidden(
    service: NoteService,
    notebookId: NotebookID,
    noteId: NoteID
  ) throws {
    XCTAssertThrowsError(try service.getNotebook(notebookId))
    XCTAssertThrowsError(try service.getNote(noteId))
    XCTAssertTrue(try service.searchNotes(query: "Page").isEmpty)
  }
}

private enum NotebookIngestConcurrencyFault: Error {
  case beforeNotebookCreation
  case afterNotebookCreation
  case afterAttachmentPhase
}

private final class NotebookIngestClaimRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storedClaim: NotebookIngestRequestClaim?

  var claim: NotebookIngestRequestClaim? {
    lock.withLock { storedClaim }
  }

  func record(_ claim: NotebookIngestRequestClaim) {
    lock.withLock { storedClaim = claim }
  }
}

private final class NotebookIngestClaimCounter: @unchecked Sendable {
  let pendingObserved = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var storedClaimCount = 0

  var claimCount: Int {
    lock.withLock { storedClaimCount }
  }

  func record(_ claim: NotebookIngestRequestClaim) {
    lock.withLock { storedClaimCount += 1 }
    if case .pending = claim {
      pendingObserved.signal()
    }
  }
}
