import Foundation
@testable import AppCore
import XCTest

/// `design-docs/specs/user-agent-tools.md`, UA4: the toolbox is the kaiba API
/// under the acting user's scope, refuses to touch its own transcript, and
/// reports failures as error results rather than throwing.
final class KaibaAgentToolboxTests: NoteTestCase {
  private func call(_ name: String, _ input: JSONObject = [:], id: String = "call-1") -> AgentToolCall {
    AgentToolCall(id: id, name: name, input: .object(input))
  }

  private func payload(_ result: AgentToolResult, file: StaticString = #filePath, line: UInt = #line) throws -> JSONObject {
    XCTAssertFalse(result.isError, "unexpected tool error: \(result.content)", file: file, line: line)
    return try XCTUnwrap(JSONValue(parsing: result.content).asObject, file: file, line: line)
  }

  func testDefinitionsCoverTheSpecifiedToolSet() throws {
    let toolbox = KaibaAgentToolbox(service: try makeService())
    XCTAssertEqual(
      toolbox.definitions.map(\.name),
      [
        "search_notes", "get_note", "list_notebooks", "get_notebook", "create_notebook", "create_note",
        "update_note_body", "add_comment", "apply_note_tags", "remove_note_tag", "list_tags",
        "link_notes", "delete_note", "undo_last_action"
      ]
    )
    for definition in toolbox.definitions {
      XCTAssertEqual(definition.inputSchema["type"]?.asString, "object", definition.name)
      XCTAssertNotNil(definition.inputSchema["properties"]?.asObject, definition.name)
    }
  }

  func testReadToolsSeeOnlyTheActingUsersNotes() async throws {
    let operatorService = try makeService()
    let alice = try operatorService.createUser(email: "alice@example.com", displayName: "Alice")
    let bob = try operatorService.createUser(email: "bob@example.com", displayName: "Bob")
    let aliceService = operatorService.scoped(to: alice.userId)
    let note = try aliceService.createNote(bodyMarkdown: "# Quarterly plan\nShip the personal agent.")

    let aliceTools = KaibaAgentToolbox(service: aliceService)
    let search = try payload(await aliceTools.execute(call("search_notes", ["query": .string("personal agent")])))
    let results = try XCTUnwrap(search["results"]?.asArray)
    XCTAssertEqual(results.first?["note_id"]?.asString, note.noteId.rawValue)

    let read = try payload(await aliceTools.execute(call("get_note", ["note_id": .id(note.noteId)])))
    XCTAssertEqual(read["body_markdown"]?.asString, "# Quarterly plan\nShip the personal agent.")
    XCTAssertNotNil(read["comments"]?.asArray)

    let bobTools = KaibaAgentToolbox(service: operatorService.scoped(to: bob.userId))
    let denied = await bobTools.execute(call("get_note", ["note_id": .id(note.noteId)]))
    XCTAssertTrue(denied.isError)
    XCTAssertTrue(denied.content.hasPrefix("not found"), denied.content)
    let bobSearch = try payload(await bobTools.execute(call("search_notes", ["query": .string("personal agent")])))
    XCTAssertEqual(bobSearch["results"]?.asArray?.count, 0)
  }

  func testWriteToolsRoundTripWithAIProvenanceAndUndo() async throws {
    let operatorService = try makeService()
    let alice = try operatorService.createUser(email: "alice@example.com", displayName: "Alice")
    let service = operatorService.scoped(to: alice.userId)
    let tools = KaibaAgentToolbox(service: service)

    let notebook = try payload(await tools.execute(call("create_notebook", ["title": .string("Agent notebook")])))
    let notebookId = NotebookID(try XCTUnwrap(notebook["notebook_id"]?.asString))

    let created = try payload(await tools.execute(call("create_note", [
      "notebook_id": .id(notebookId),
      "body_markdown": .string("# Draft\nFirst version."),
      "tags": .array([.string("topic-a"), .object(["name": .string("project-x")])])
    ])))
    let noteId = NoteID(try XCTUnwrap(created["note_id"]?.asString))
    let stored = try service.getNote(noteId)
    XCTAssertEqual(stored.notebookId, notebookId)
    XCTAssertEqual(Set(stored.tags.map(\.tag.name)), ["topic-a", "project-x"])
    XCTAssertTrue(stored.tags.allSatisfy { $0.provenance == .ai })

    _ = try payload(await tools.execute(call("update_note_body", [
      "note_id": .id(noteId), "body_markdown": .string("# Draft\nSecond version.")
    ])))
    XCTAssertEqual(try service.getNote(noteId).bodyMarkdown, "# Draft\nSecond version.")

    _ = try payload(await tools.execute(call("add_comment", [
      "note_id": .id(noteId), "body_markdown": .string("Reviewed by the agent.")
    ])))
    XCTAssertEqual(try service.listComments(noteId: noteId).map(\.author), [KaibaAgentToolbox.commentAuthor])

    _ = try payload(await tools.execute(call("remove_note_tag", ["note_id": .id(noteId), "tag": .string("topic-a")])))
    XCTAssertEqual(try service.getNote(noteId).tags.map(\.tag.name), ["project-x"])

    let other = try service.createNote(notebookId: notebookId, bodyMarkdown: "# Other\nRelated.")
    let linked = try payload(await tools.execute(call("link_notes", [
      "from_note_id": .id(noteId), "to_note_id": .id(other.noteId)
    ])))
    XCTAssertEqual(linked["link_kind"]?.asString, "related")

    let tags = try payload(await tools.execute(call("list_tags")))
    XCTAssertTrue(try XCTUnwrap(tags["tags"]?.asArray).contains { $0["name"]?.asString == "project-x" })

    let listed = try payload(await tools.execute(call("get_notebook", ["notebook_id": .id(notebookId)])))
    XCTAssertEqual(listed["notes"]?.asArray?.count, 2)

    _ = try payload(await tools.execute(call("delete_note", ["note_id": .id(other.noteId)])))
    XCTAssertThrowsError(try service.getNote(other.noteId))
    let undone = try payload(await tools.execute(call("undo_last_action")))
    XCTAssertEqual(undone["undone"]?.asBool, true)
    XCTAssertNoThrow(try service.getNote(other.noteId))
  }

  func testAgentCannotWriteIntoItsOwnConversation() async throws {
    let operatorService = try makeService()
    let alice = try operatorService.createUser(email: "alice@example.com", displayName: "Alice")
    let service = operatorService.scoped(to: alice.userId)
    let subject = try service.createNote(bodyMarkdown: "# Subject\nBody.")
    let conversation = try service.startAgentConversation(subjectNoteId: subject.noteId)
    let turn = try service.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "Do something",
      agentAvailable: false
    )
    let tools = KaibaAgentToolbox(service: service)
    let linksBefore = try service.listLinks(noteId: turn.noteId)

    for blocked in [
      call("update_note_body", ["note_id": .id(turn.noteId), "body_markdown": .string("overwritten")]),
      call("add_comment", ["note_id": .id(turn.noteId), "body_markdown": .string("hi")]),
      call("apply_note_tags", ["note_id": .id(turn.noteId), "tags": .array([.string("x")])]),
      call("delete_note", ["note_id": .id(turn.noteId)]),
      call("create_note", ["notebook_id": .id(conversation.notebookId), "body_markdown": .string("injected")]),
      call("link_notes", ["from_note_id": .id(subject.noteId), "to_note_id": .id(turn.noteId)]),
      call("link_notes", ["from_note_id": .id(turn.noteId), "to_note_id": .id(subject.noteId)])
    ] {
      let result = await tools.execute(blocked)
      XCTAssertTrue(result.isError, blocked.name)
      XCTAssertTrue(result.content.contains("agent conversation"), "\(blocked.name): \(result.content)")
    }
    XCTAssertEqual(try service.getNote(turn.noteId).bodyMarkdown, turn.bodyMarkdown)
    XCTAssertEqual(try service.listLinks(noteId: turn.noteId), linksBefore)
    // Reading the transcript is still allowed.
    let transcriptRead = await tools.execute(call("get_note", ["note_id": .id(turn.noteId)]))
    XCTAssertFalse(transcriptRead.isError)
  }

  /// `design-docs/specs/note-retrieval-fusion.md`, RF5: the search tool can
  /// filter by tag, reach graph neighbours, and reports term coverage.
  func testSearchNotesHonoursTagsIncludeLinkedAndReportsCoverage() async throws {
    let service = try makeService()
    let tagged = try service.createNote(
      bodyMarkdown: "# Tagged\nplanning session",
      tags: [NoteTagInput(name: "keep", classId: TagClassID("topic"))]
    )
    _ = try service.createNote(bodyMarkdown: "# Untagged\nplanning session")
    let neighbour = try service.createNote(
      bodyMarkdown: "# Neighbour\ncontext only",
      tags: [NoteTagInput(name: "keep", classId: TagClassID("topic"))]
    )
    _ = try service.linkNotes(from: tagged.noteId, to: neighbour.noteId)
    let tools = KaibaAgentToolbox(service: service)

    let search = try payload(await tools.execute(call("search_notes", [
      "query": .string("planning session"),
      "tags": .array([.string("keep")]),
      "include_linked": .bool(true)
    ])))
    let results = try XCTUnwrap(search["results"]?.asArray)

    XCTAssertEqual(results.map { $0["note_id"]?.asString }, [tagged.noteId.rawValue, neighbour.noteId.rawValue])
    XCTAssertEqual(results.map { $0["is_linked_neighbor"]?.asBool }, [false, true])
    XCTAssertEqual(results.first?["term_coverage"]?.asDouble, 1)

    let partial = try payload(await tools.execute(call("search_notes", [
      "query": .string("planning nonsenseterm")
    ])))
    let partialResults = try XCTUnwrap(partial["results"]?.asArray)
    XCTAssertEqual(partialResults.count, 2)
    XCTAssertEqual(partialResults.first?["term_coverage"]?.asDouble, 0.5)
  }

  func testInvalidInputsAndUnknownToolsAreErrorResults() async throws {
    let tools = KaibaAgentToolbox(service: try makeService())
    let unknown = await tools.execute(call("drop_everything"))
    XCTAssertTrue(unknown.isError)
    XCTAssertEqual(unknown.content, "unknown tool: drop_everything")

    let missing = await tools.execute(call("search_notes"))
    XCTAssertTrue(missing.isError)
    XCTAssertTrue(missing.content.contains("query is required"))

    let outOfRange = await tools.execute(call("search_notes", ["query": .string("x"), "limit": .integer(500)]))
    XCTAssertTrue(outOfRange.isError)
    XCTAssertTrue(outOfRange.content.contains("limit must be an integer in 1...50"))

    let malformedSearchTags = await tools.execute(call("search_notes", [
      "query": .string("x"), "tags": .string("keep")
    ]))
    XCTAssertTrue(malformedSearchTags.isError)
    XCTAssertTrue(malformedSearchTags.content.contains("tags must be an array of strings"))

    let malformedIncludeLinked = await tools.execute(call("search_notes", [
      "query": .string("x"), "include_linked": .string("yes")
    ]))
    XCTAssertTrue(malformedIncludeLinked.isError)
    XCTAssertTrue(malformedIncludeLinked.content.contains("include_linked must be a boolean"))

    let malformedTags = await tools.execute(call("create_note", [
      "body_markdown": .string("x"), "tags": .array([.integer(1)])
    ]))
    XCTAssertTrue(malformedTags.isError)
  }

  func testLargeBodiesAreBoundedWithAMarker() async throws {
    let service = try makeService()
    let big = String(repeating: "abcdefghij", count: 10_000)
    let note = try service.createNote(bodyMarkdown: "# Big\n" + big)
    let tools = KaibaAgentToolbox(service: service)
    let result = await tools.execute(call("get_note", ["note_id": .id(note.noteId)]))
    XCTAssertFalse(result.isError)
    XCTAssertLessThanOrEqual(result.content.utf8.count, AgentToolOutputLimits.maximumResultBytes)
    XCTAssertTrue(result.content.contains("truncated by kaiba"))
    // The body is bounded inside the document, so the payload the model
    // receives is still complete JSON with every other field intact.
    let document = try XCTUnwrap(JSONValue(parsing: result.content).asObject)
    XCTAssertEqual(document["note_id"]?.asString, note.noteId.rawValue)
    XCTAssertNotNil(document["tags"]?.asArray)
    XCTAssertNotNil(document["comments"]?.asArray)
    XCTAssertTrue(document["body_markdown"]?.asString?.hasSuffix(AgentToolOutputLimits.truncationMarker) == true)

    let multibyte = String(repeating: "日本語", count: 100)
    let bounded = AgentToolOutputLimits.bounded(multibyte, maximumBytes: 200)
    XCTAssertLessThanOrEqual(bounded.utf8.count, 200)
    XCTAssertTrue(bounded.hasSuffix(AgentToolOutputLimits.truncationMarker))
    XCTAssertNotNil(bounded.data(using: .utf8))
  }
}
