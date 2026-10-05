import AppCore
@testable import AppGraphQL
import Foundation
import XCTest

final class AgenticSearchDiagnosticsGraphQLTests: XCTestCase {
  func testAgentInvocationFailureReturnsOnePublicReasonAndLogsOnce() async throws {
    let capture = LogCapture()
    let service = try makeService(invoker: StubInvoker(response: .failure(.failed("agent-gateway produced no reply (exit 71)"))), log: capture)

    let result = await service.agenticSearch(query: "q")

    XCTAssertEqual(result.status, "failed")
    XCTAssertEqual(result.result.status, "error")
    XCTAssertFalse(result.result.accepted)
    XCTAssertEqual(result.result.diagnostics, ["agent-gateway produced no reply (exit 71)"])
    XCTAssertEqual(capture.lines, ["kaiba: agenticSearch failed: agent-gateway produced no reply (exit 71)"])
  }

  func testUnknownFailureIsRedactedFromDiagnosticsAndLog() async throws {
    let capture = LogCapture()
    let service = try makeService(
      invoker: StubInvoker(response: .failure(.failed("provider said FIXTURE-SECRET at /home/example/x"))),
      log: capture
    )

    let result = await service.agenticSearch(query: "q")

    XCTAssertEqual(result.result.diagnostics, ["agent request failed"])
    XCTAssertEqual(capture.lines, ["kaiba: agenticSearch failed: agent request failed"])
    XCTAssertFalse(capture.lines.joined().contains("FIXTURE-SECRET"))
    XCTAssertFalse(capture.lines.joined().contains("/home/example"))
  }

  func testUnavailableFailureUsesRuntimeUnavailableReason() async throws {
    let capture = LogCapture()
    let service = try makeService(
      invoker: StubInvoker(response: .failure(.unavailable("binary not found: /srv/example/x"))),
      log: capture
    )

    let result = await service.agenticSearch(query: "q")

    XCTAssertEqual(result.result.diagnostics, ["agent runtime is unavailable"])
    XCTAssertEqual(capture.lines, ["kaiba: agenticSearch failed: agent runtime is unavailable"])
  }

  func testInvalidQueryKeepsExistingMappingAndLogsOnce() async throws {
    let capture = LogCapture()
    let service = try makeService(invoker: StubInvoker(response: .reply("answer")), log: capture)

    let result = await service.agenticSearch(query: " \n ")

    XCTAssertEqual(result.status, "failed")
    XCTAssertEqual(result.result.status, "invalid_request")
    XCTAssertFalse(result.result.accepted)
    let diagnostic: String = try XCTUnwrap(result.result.diagnostics.first)
    XCTAssertTrue(diagnostic.hasPrefix("invalid note request:"))
    XCTAssertEqual(capture.lines.count, 1)
  }

  func testSuccessAndMissingInvokerDoNotLog() async throws {
    let successLog = LogCapture()
    let successService = try makeService(invoker: StubInvoker(response: .reply("answer")), log: successLog)
    let success = await successService.agenticSearch(query: "q")
    XCTAssertEqual(success.status, "ok")
    XCTAssertEqual(success.answerMarkdown, "answer")
    XCTAssertTrue(successLog.lines.isEmpty)

    let missingLog = LogCapture()
    let missingService = try makeService(invoker: nil, log: missingLog)
    let missing = await missingService.agenticSearch(query: "q")
    XCTAssertEqual(missing.status, "agent-unavailable")
    XCTAssertTrue(missingLog.lines.isEmpty)
  }

  func testDocumentExecutorReturnsSanitizedDiagnosticsWithoutGraphQLErrors() async throws {
    let capture = LogCapture()
    let service = try makeService(
      invoker: StubInvoker(response: .failure(.failed("agent-gateway produced no reply (exit 71)"))),
      log: capture
    )
    let executor = NoteGraphQLDocumentExecutor(service: service)
    let response = await executor.execute(GraphQLDocumentRequest(query: """
      query { agenticSearch(query: "q", limit: 5) { status answerMarkdown result { accepted status diagnostics } } }
      """))

    XCTAssertTrue(response.handled)
    let data = try XCTUnwrap(response.body["data"]?.asObject)
    let search = try XCTUnwrap(data["agenticSearch"]?.asObject)
    let result = try XCTUnwrap(search["result"]?.asObject)
    let diagnostics: [JSONValue]? = result["diagnostics"]?.asArray
    XCTAssertEqual(diagnostics, [.string("agent-gateway produced no reply (exit 71)")])
    XCTAssertNil(response.body["errors"])
  }

  private func makeService(invoker: (any AgentInvoking)?, log: LogCapture) throws -> GraphQLNoteGraphQLService {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/AppGraphQLTests", isDirectory: true)
      .appendingPathComponent("AgenticSearchDiagnostics", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var service = GraphQLNoteGraphQLService(
      service: try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path)),
      agentInvoker: invoker
    )
    service.agenticSearchFailureLog = { line in log.append(line) }
    return service
  }
}

private enum StubResponse: Sendable {
  case reply(String)
  case failure(AgentInvocationError)
}

private struct StubInvoker: AgentInvoking {
  let response: StubResponse

  func invoke(_ request: AgentInvocationRequest) async throws -> AgentInvocationResult {
    switch response {
    case .reply(let markdown):
      return AgentInvocationResult(markdown: markdown)
    case .failure(let error):
      throw error
    }
  }
}

private final class LogCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var storedLines: [String] = []

  var lines: [String] {
    lock.lock()
    defer { lock.unlock() }
    return storedLines
  }

  func append(_ line: String) {
    lock.lock()
    defer { lock.unlock() }
    storedLines.append(line)
  }
}
