import Foundation
import XCTest
@testable import AppCore
import AppGraphQL
@testable import AppServer

#if canImport(Network)

/// Explicit opt-in: runs real provider calls and retains its fresh database as evidence.
final class LiveMemoChatScenarioTests: XCTestCase {
  func testFreshDatabaseLunaMemoBranchLifecycle() async throws {
    guard ProcessInfo.processInfo.environment["KAIBA_LIVE_LUNA_SCENARIO"] == "1" else {
      throw XCTSkip("Set KAIBA_LIVE_LUNA_SCENARIO=1 to invoke the real local GPT-5.6 Luna gateway")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("kaiba-live-luna-\(UUID().uuidString)")
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    let fixture = try LiveMemoScenarioServer(root: root)
    try await fixture.start()
    liveScenarioLog("database=\(root.path) endpoint=\(fixture.endpoint)")
    do {
      try await runLifecycle(fixture)
      let hold = Int(ProcessInfo.processInfo.environment["KAIBA_LIVE_UI_HOLD_SECONDS"] ?? "0") ?? 0
      if hold > 0 {
        liveScenarioLog("UI_READY endpoint=\(fixture.endpoint) holdSeconds=\(hold)")
        for _ in 0..<hold {
          if FileManager.default.fileExists(atPath: root.appendingPathComponent("ui-finished").path) { break }
          try await Task.sleep(for: .seconds(1))
        }
      }
      await fixture.stop()
    } catch {
      await fixture.stop()
      throw error
    }
  }

  private func runLifecycle(_ fixture: LiveMemoScenarioServer) async throws {
    XCTAssertTrue(try fixture.service.listNotes().isEmpty)
    let source = try await fixture.operation("""
      mutation($input: CreateNoteInput!) {
        createNote(input: $input) { result { accepted status diagnostics } note { noteId notebookId } }
      }
      """, field: "createNote", variables: ["input": [
        "bodyMarkdown": "# Luna scenario document\nThe project code is ORCHID731. Answer from supplied context only. Never use tools."
      ]])
    let document = try XCTUnwrap(source["note"] as? [String: Any])
    let sourceId = try XCTUnwrap(document["noteId"] as? String)
    let documentId = try XCTUnwrap(document["notebookId"] as? String)
    let documentType = try await fixture.notebookType(documentId)
    XCTAssertEqual(documentType, "DOCUMENT")
    let memoId = try await fixture.memo(noteId: sourceId, text: "The memo code is WILLOW842.")
    let parentId = try await fixture.openMemo(memoId)
    let reopenedParent = try await fixture.openMemo(memoId)
    let parentType = try await fixture.notebookType(parentId)
    let initialCalls = await fixture.invoker.count()
    XCTAssertEqual(reopenedParent, parentId)
    XCTAssertEqual(parentType, "AGENT_CHAT")
    XCTAssertEqual(initialCalls, 0, "Saving/opening a plain memo must never dispatch")
    liveScenarioLog("sourceNotebook=\(documentId) memoNotebook=\(parentId)")

    let first = try await fixture.send(parentId, question: "What are the project and memo codes? Reply only with those two codes.")
    try fixture.assertAnswer(first, contains: ["ORCHID731", "WILLOW842"])
    let attachment = Data("The attachment code is CEDAR953.".utf8).base64EncodedString()
    let anchor = try await fixture.send(parentId, question: "Read the attached reference. Reply exactly REFERENCE_READ; do not repeat its code.", attachments: [[
      "originalFilename": "reference.txt", "mediaType": "text/plain", "contentBase64": attachment
    ]])
    try fixture.assertAnswer(anchor, contains: ["REFERENCE_READ"])
    _ = try await fixture.send(parentId, question: "A later fact: the future code is FUTURE164. Reply exactly LATER_READ.")
    let branchMemo = try await fixture.memo(noteId: anchor, text: "The branch code is BIRCH275.")
    let branchId = try await fixture.openMemo(branchMemo)
    let snapshot = try XCTUnwrap(fixture.service.agentChatSubjectSnapshot(
      conversationNotebookId: XCTUnwrap(NotebookID(rawValue: branchId)), editMode: false
    ).markdown)
    for token in ["ORCHID731", "WILLOW842", "CEDAR953", "REFERENCE_READ"] {
      XCTAssertTrue(snapshot.contains(token), "Missing inherited context: \(token)")
    }
    XCTAssertFalse(snapshot.contains("FUTURE164"), "Branch must exclude turns after its anchor")
    _ = try fixture.service.updateNoteBody(
      noteId: XCTUnwrap(NoteID(rawValue: sourceId)), bodyMarkdown: "The source changed after branching: CHANGED497."
    )
    XCTAssertEqual(try fixture.service.agentChatSubjectSnapshot(
      conversationNotebookId: XCTUnwrap(NotebookID(rawValue: branchId)), editMode: false
    ).markdown, snapshot)
    let parentNotebookID = try XCTUnwrap(NotebookID(rawValue: parentId))
    let parentCount = try fixture.service.listNotes(notebookId: parentNotebookID).count
    let branchTurn = try await fixture.send(branchId, question: "List the project, memo, attachment and branch codes from context. If no future code is present, also output NO_FUTURE. Do not use tools.")
    try fixture.assertAnswer(branchTurn, contains: ["ORCHID731", "WILLOW842", "CEDAR953", "BIRCH275", "NO_FUTURE"])
    XCTAssertEqual(try fixture.service.listNotes(notebookId: parentNotebookID).count, parentCount)
    let branchTurnID = try XCTUnwrap(NoteID(rawValue: branchTurn))
    let branchAnswer = try fixture.service.getNote(branchTurnID).bodyMarkdown
    XCTAssertFalse(try XCTUnwrap(NoteService.assistantMarkdown(fromTurnBody: branchAnswer)).contains("FUTURE164"))
    let nestedMemo = try await fixture.memo(noteId: branchTurn, text: "The nested code is MAPLE386.")
    let nestedId = try await fixture.openMemo(nestedMemo)
    let nestedTurn = try await fixture.send(nestedId, question: "List every project, memo, attachment, branch and nested code available in context. Do not use tools.")
    try fixture.assertAnswer(nestedTurn, contains: ["ORCHID731", "WILLOW842", "CEDAR953", "BIRCH275", "MAPLE386"])
    let callsBeforeRestart = await fixture.invoker.count()
    XCTAssertEqual(callsBeforeRestart, 5)

    await fixture.stop()
    let restarted = try LiveMemoScenarioServer(root: fixture.root, invoker: fixture.invoker)
    try await restarted.start()
    do {
      let reopenedBranch = try await restarted.openMemo(branchMemo)
      let reopenedDocumentType = try await restarted.notebookType(documentId)
      let reopenedNestedType = try await restarted.notebookType(nestedId)
      XCTAssertEqual(reopenedBranch, branchId)
      XCTAssertEqual(reopenedDocumentType, "DOCUMENT")
      XCTAssertEqual(reopenedNestedType, "AGENT_CHAT")
      XCTAssertEqual(try restarted.service.getNote(branchTurnID).bodyMarkdown, branchAnswer)
      let resumed = try await restarted.send(nestedId, question: "After reopening, what was the attachment code? Reply with only that code.")
      try restarted.assertAnswer(resumed, contains: ["CEDAR953"])
      let callsAfterRestart = await fixture.invoker.count()
      XCTAssertEqual(callsAfterRestart, 6)
      liveScenarioLog("COMPLETE: empty database, types, memo-only, context, attachment, branch cutoff, independence, nested branch, idempotency, restart; 6 real Luna replies. XCTest determines pass/fail.")
      await restarted.stop()
    } catch {
      await restarted.stop()
      throw error
    }
    try await fixture.start()
  }
}

private actor LiveLunaInvoker: AgentInvoking {
  private var calls = 0
  private let gateway = AgentGatewayCLIInvoker(vendor: "codex", model: "gpt-5.6-luna", executionMode: .local)

  func count() -> Int { calls }

  func invoke(_ request: AgentInvocationRequest) async throws -> AgentInvocationResult {
    calls += 1
    let result = try await gateway.invoke(request)
    liveScenarioLog("providerReply[\(calls)]=\(result.markdown)")
    return result
  }
}

private func liveScenarioLog(_ message: String) {
  FileHandle.standardOutput.write(Data("LIVE_SCENARIO \(message)\n".utf8))
}

private final class LiveMemoScenarioServer {
  let root: URL
  let invoker: LiveLunaInvoker
  let service: NoteService
  let server: KaibaLocalHTTPServer
  private(set) var endpoint = ""

  init(root: URL, invoker: LiveLunaInvoker = LiveLunaInvoker()) throws {
    self.root = root
    self.invoker = invoker
    let bare = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
    var service = bare
    service.autoActionDispatcher = KaibaAutoActionDispatcher(
      service: bare, invoker: invoker, provider: "codex", model: "gpt-5.6-luna"
    )
    try service.configureAutoAction(
      actionId: NoteStoreSchema.agentChatReplyActionId, trigger: .noteCreated,
      workflowId: NoteStoreSchema.agentChatReplyWorkflowId, enabled: true
    )
    self.service = service
    let executor = NoteGraphQLDocumentExecutor(service: GraphQLNoteGraphQLService(
      service: service, agentInvoker: invoker, agentProvider: "codex", agentModel: "gpt-5.6-luna"
    ))
    let handler = DeterministicServerRouteHandler(
      graphQLExecutor: executor, allowUnauthenticatedNoteAPI: true, noteService: service
    )
    let adapter = DeterministicServerHTTPAdapter(routeHandler: handler, context: ServerRequestContext(serviceName: "kaiba"))
    let router = KaibaStaticSPAHTTPRouter(
      service: adapter, webRoot: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("web/dist")
    )
    server = KaibaLocalHTTPServer(routeHandler: router)
  }

  func start() async throws {
    endpoint = "http://127.0.0.1:\(try await server.startForTesting(host: "127.0.0.1"))"
  }

  func stop() async {
    await service.drainAutoActionDispatches()
    await server.stop()
  }

  func operation(_ query: String, field: String, variables: [String: Any]) async throws -> [String: Any] {
    var request = URLRequest(url: try XCTUnwrap(URL(string: endpoint + "/graphql")))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
    let (data, response) = try await URLSession.shared.data(for: request)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertNil(body["errors"], String(describing: body))
    let payload = try XCTUnwrap((body["data"] as? [String: Any])?[field] as? [String: Any], String(describing: body))
    XCTAssertEqual((payload["result"] as? [String: Any])?["accepted"] as? Bool, true, String(describing: payload))
    return payload
  }

  func notebookType(_ identifier: String) async throws -> String {
    let payload = try await operation("""
      query($id: String!) { notebook(notebookId: $id) { result { accepted status } value { type } } }
      """, field: "notebook", variables: ["id": identifier])
    return try XCTUnwrap((payload["value"] as? [String: Any])?["type"] as? String)
  }

  func memo(noteId: String, text: String) async throws -> String {
    let payload = try await operation("""
      mutation($input: AddNoteCommentInput!) { addNoteComment(input: $input) {
        result { accepted status diagnostics } comment { commentId }
      } }
      """, field: "addNoteComment", variables: ["input": ["noteId": noteId, "bodyMarkdown": text]])
    return try XCTUnwrap((payload["comment"] as? [String: Any])?["commentId"] as? String)
  }

  func openMemo(_ identifier: String) async throws -> String {
    let payload = try await operation("""
      mutation($id: String!) { openMemoNotebook(commentId: $id) {
        result { accepted status diagnostics } notebook { notebookId type }
      } }
      """, field: "openMemoNotebook", variables: ["id": identifier])
    XCTAssertEqual((payload["notebook"] as? [String: Any])?["type"] as? String, "AGENT_CHAT")
    return try XCTUnwrap((payload["notebook"] as? [String: Any])?["notebookId"] as? String)
  }

  func send(_ notebookId: String, question: String, attachments: [[String: String]] = []) async throws -> String {
    let query = """
      mutation($input: SendAgentChatMessageInput!) { sendAgentChatMessage(input: $input) {
        result { accepted status diagnostics } conversationNotebookId turnNoteId agentStatus
      } }
      """
    let variables: [String: Any] = ["input": [
      "conversationNotebookId": notebookId, "userMarkdown": question, "model": "gpt-5.6-luna",
      "idempotencyKey": UUID().uuidString, "attachments": attachments
    ]]
    let payload = try await operation(query, field: "sendAgentChatMessage", variables: variables)
    let turnId = try XCTUnwrap(payload["turnNoteId"] as? String)
    await service.drainAutoActionDispatches()
    let replay = try await operation(query, field: "sendAgentChatMessage", variables: variables)
    XCTAssertEqual(replay["turnNoteId"] as? String, turnId)
    XCTAssertEqual(replay["agentStatus"] as? String, "answered")
    return turnId
  }

  func assertAnswer(_ identifier: String, contains tokens: [String]) throws {
    let note = try service.getNote(XCTUnwrap(NoteID(rawValue: identifier)))
    XCTAssertEqual(NoteService.chatTurnState(of: note)?.status, .answered)
    XCTAssertEqual(NoteService.chatTurnState(of: note)?.model, "gpt-5.6-luna")
    let answer = try XCTUnwrap(NoteService.assistantMarkdown(fromTurnBody: note.bodyMarkdown))
    for token in tokens {
      XCTAssertTrue(answer.contains(token), "Expected \(token) in live answer: \(answer)")
    }
  }
}

#endif
