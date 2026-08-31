import Foundation

import AppCore
@testable import AppServer
import XCTest

final class AgentReplyStreamRouteValidationTests: XCTestCase {
  func testAgentReplyStreamRejectsOwnedNonChatTurnBeforePolling() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/AppServerTests/AgentReplyStreamRouteValidationTests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
    let note = try service.createNote(bodyMarkdown: "# Ordinary note")
    let handler = DeterministicServerRouteHandler(
      allowUnauthenticatedNoteAPI: true,
      noteService: service,
      agentReplyStreamHub: AgentReplyStreamHub()
    )

    let response = await handler.route(
      ServerRequestEnvelope(
        method: "GET",
        path: "/note/agent-stream",
        query: "turn=\(note.noteId.rawValue)&timeoutMs=0"
      ),
      context: .init(serviceName: "test")
    )

    XCTAssertEqual(response.status, 404)
    XCTAssertEqual(response.body["error"], .string("agent chat turn not found"))
  }
}
