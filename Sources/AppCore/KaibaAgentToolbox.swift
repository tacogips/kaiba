import Foundation

/// Kaiba's note operations exposed to a personal agent as typed tools
/// (`design-docs/specs/user-agent-tools.md`, UA4). The toolbox holds a
/// `NoteService` already scoped to the acting user and fenced to the outbox
/// lease, so every ownership, library, read-only, and account rule the
/// GraphQL API enforces applies to the agent unchanged.
public struct KaibaAgentToolbox: AgentToolExecuting {
  public static let assignedBy = "agent"
  public static let commentAuthor = "agent"

  let service: NoteService

  init(service: NoteService) {
    self.service = service
  }

  public var definitions: [AgentToolDefinition] {
    KaibaAgentToolSchema.definitions
  }

  public func execute(_ call: AgentToolCall) async -> AgentToolResult {
    do {
      let payload = try run(call)
      return AgentToolResult(
        callId: call.id,
        content: AgentToolOutputLimits.bounded(try payload.encodedString())
      )
    } catch {
      return AgentToolResult(
        callId: call.id,
        content: AgentToolOutputLimits.bounded(Self.errorMessage(for: error)),
        isError: true
      )
    }
  }

  static func errorMessage(for error: Error) -> String {
    switch error {
    case let toolError as AgentToolError:
      return toolError.description
    case let NoteServiceError.notFound(message):
      return "not found: \(message)"
    case let NoteServiceError.readOnly(message):
      return "read-only: \(message)"
    case let NoteServiceError.protectedTag(message):
      return "protected tag: \(message)"
    case let NoteServiceError.invalidInput(message):
      return "invalid input: \(message)"
    case let NoteServiceError.conflict(message):
      return "conflict: \(message)"
    case let NoteServiceError.accountUnavailable(message):
      return "account unavailable: \(message)"
    case let NoteServiceError.invalidRow(message):
      return "store error: \(message)"
    default:
      return "tool failed: \(error)"
    }
  }

  // MARK: - Dispatch

  private func run(_ call: AgentToolCall) throws -> JSONValue {
    let input = KaibaAgentToolInput(call.input)
    switch call.name {
    case "search_notes": return try searchNotes(input)
    case "get_note": return try getNote(input)
    case "list_notebooks": return try listNotebooks(input)
    case "get_notebook": return try getNotebook(input)
    case "create_notebook": return try createNotebook(input)
    case "create_note": return try createNote(input)
    case "update_note_body": return try updateNoteBody(input)
    case "add_comment": return try addComment(input)
    case "apply_note_tags": return try applyNoteTags(input)
    case "remove_note_tag": return try removeNoteTag(input)
    case "list_tags": return try listTags()
    case "link_notes": return try linkNotes(input)
    case "delete_note": return try deleteNote(input)
    case "undo_last_action": return try undoLastAction()
    default:
      throw AgentToolError.unknownTool(call.name)
    }
  }

  // MARK: - Read tools

  private func searchNotes(_ input: KaibaAgentToolInput) throws -> JSONValue {
    let query = try input.requiredString("query")
    let notebookId = try input.optionalIdentifier("notebook_id", as: NotebookID.self)
    let tagFilter = try input.optionalStringArray("tags")
    let includeLinked = try input.optionalBool("include_linked", default: false)
    let limit = try input.optionalInt("limit", default: 10, range: 1...50)
    let results = try service.searchNotes(
      query: query,
      tagFilter: tagFilter,
      notebookId: notebookId,
      includeLinked: includeLinked,
      depth: 1,
      limit: limit
    )
    return .object([
      "query": .string(query),
      "results": .array(results.map { result in
        .object([
          "note_id": .id(result.note.noteId),
          "notebook_id": .id(result.note.notebookId),
          "title": result.note.title.map(JSONValue.string) ?? .null,
          "snippet": .string(result.snippet),
          "updated_at": .string(result.note.updatedAt),
          "term_coverage": .number(result.termCoverage),
          "is_linked_neighbor": .bool(result.isLinkedNeighbor),
          "tags": Self.tagNames(result.note.tags)
        ])
      })
    ])
  }

  private func getNote(_ input: KaibaAgentToolInput) throws -> JSONValue {
    let noteId = try input.requiredIdentifier("note_id", as: NoteID.self)
    let note = try service.getNote(noteId)
    let comments = try service.listComments(noteId: noteId)
    let links = try service.listLinks(noteId: noteId)
    var payload = Self.noteJSON(note, includeBody: true)
    payload["comments"] = .array(comments.map { comment in
      .object([
        "comment_id": .id(comment.commentId),
        "author": .string(comment.author),
        "body_markdown": .string(comment.bodyMarkdown),
        "created_at": .string(comment.createdAt)
      ])
    })
    payload["links"] = .array(links.map { link in
      .object([
        "from_note_id": .id(link.fromNoteId),
        "to_note_id": .id(link.toNoteId),
        "link_kind": .string(link.linkKind)
      ])
    })
    return .object(payload)
  }

  private func listNotebooks(_ input: KaibaAgentToolInput) throws -> JSONValue {
    let limit = try input.optionalInt("limit", default: 50, range: 1...200)
    let offset = try input.optionalInt("offset", default: 0, range: 0...1_000_000)
    let notebooks = try service.listNotebooks(limit: limit, offset: offset)
    return .object([
      "notebooks": .array(notebooks.map { .object(Self.notebookJSON($0)) })
    ])
  }

  private func getNotebook(_ input: KaibaAgentToolInput) throws -> JSONValue {
    let notebookId = try input.requiredIdentifier("notebook_id", as: NotebookID.self)
    let limit = try input.optionalInt("limit", default: 100, range: 1...200)
    let offset = try input.optionalInt("offset", default: 0, range: 0...1_000_000)
    let notebook = try service.getNotebook(notebookId)
    let notes = try service.listNotes(notebookId: notebookId, limit: limit, offset: offset)
    var payload = Self.notebookJSON(notebook)
    payload["notes"] = .array(notes.map { note in
      var summary = Self.noteJSON(note, includeBody: false)
      summary["preview"] = .string(String(note.bodyMarkdown.prefix(240)))
      return .object(summary)
    })
    return .object(payload)
  }

  private func listTags() throws -> JSONValue {
    let tags = try service.listTags()
    return .object([
      "tags": .array(tags.map { tag in
        .object([
          "tag_id": .id(tag.tagId),
          "name": .string(tag.name),
          "class_id": tag.classId.map(JSONValue.id) ?? .null,
          "parent_tag_id": tag.parentTagId.map(JSONValue.id) ?? .null
        ])
      })
    ])
  }

  // MARK: - Write tools

  private func createNotebook(_ input: KaibaAgentToolInput) throws -> JSONValue {
    let title = try input.requiredString("title")
    let notebook = try service.createNotebook(title: title)
    return .object(Self.notebookJSON(notebook))
  }

  private func createNote(_ input: KaibaAgentToolInput) throws -> JSONValue {
    let body = try input.requiredString("body_markdown")
    let notebookId = try input.optionalIdentifier("notebook_id", as: NotebookID.self)
    let notebookTitle = try input.optionalString("notebook_title")
    let title = try input.optionalString("title")
    let tags = try input.tagInputs("tags")
    if let notebookId {
      try assertAgentWritableNotebook(notebookId)
    }
    let note = try service.createNote(
      notebookId: notebookId,
      notebookTitle: notebookTitle,
      title: title,
      bodyMarkdown: body,
      tags: tags,
      provenance: .ai,
      assignedBy: Self.assignedBy
    )
    return .object(Self.noteJSON(note, includeBody: false))
  }

  private func updateNoteBody(_ input: KaibaAgentToolInput) throws -> JSONValue {
    let noteId = try input.requiredIdentifier("note_id", as: NoteID.self)
    let body = try input.requiredString("body_markdown")
    try assertAgentWritableNote(noteId)
    let note = try service.updateNoteBody(noteId: noteId, bodyMarkdown: body, provenance: .ai)
    return .object(Self.noteJSON(note, includeBody: false))
  }

  private func addComment(_ input: KaibaAgentToolInput) throws -> JSONValue {
    let noteId = try input.requiredIdentifier("note_id", as: NoteID.self)
    let body = try input.requiredString("body_markdown")
    try assertAgentWritableNote(noteId)
    let comment = try service.addComment(
      noteId: noteId,
      bodyMarkdown: body,
      author: Self.commentAuthor
    )
    return .object([
      "comment_id": .id(comment.commentId),
      "note_id": .id(noteId),
      "created_at": .string(comment.createdAt)
    ])
  }

  private func applyNoteTags(_ input: KaibaAgentToolInput) throws -> JSONValue {
    let noteId = try input.requiredIdentifier("note_id", as: NoteID.self)
    let tags = try input.tagInputs("tags")
    guard !tags.isEmpty else {
      throw AgentToolError.invalidInput("tags must contain at least one tag")
    }
    try assertAgentWritableNote(noteId)
    let note = try service.applyTags(
      noteId: noteId,
      tags: tags,
      provenance: .ai,
      assignedBy: Self.assignedBy
    )
    return .object(Self.noteJSON(note, includeBody: false))
  }

  private func removeNoteTag(_ input: KaibaAgentToolInput) throws -> JSONValue {
    let noteId = try input.requiredIdentifier("note_id", as: NoteID.self)
    let tagName = try input.requiredString("tag")
    try assertAgentWritableNote(noteId)
    let note = try service.removeTag(noteId: noteId, tagName: tagName, removedBy: .ai)
    return .object(Self.noteJSON(note, includeBody: false))
  }

  private func linkNotes(_ input: KaibaAgentToolInput) throws -> JSONValue {
    let fromNoteId = try input.requiredIdentifier("from_note_id", as: NoteID.self)
    let toNoteId = try input.requiredIdentifier("to_note_id", as: NoteID.self)
    let linkKind = try input.optionalString("link_kind") ?? "related"
    try assertAgentWritableNote(fromNoteId)
    try assertAgentWritableNote(toNoteId)
    let link = try service.linkNotes(
      from: fromNoteId,
      to: toNoteId,
      linkKind: linkKind,
      provenance: .ai
    )
    return .object([
      "from_note_id": .id(link.fromNoteId),
      "to_note_id": .id(link.toNoteId),
      "link_kind": .string(link.linkKind)
    ])
  }

  private func deleteNote(_ input: KaibaAgentToolInput) throws -> JSONValue {
    let noteId = try input.requiredIdentifier("note_id", as: NoteID.self)
    try assertAgentWritableNote(noteId)
    try service.deleteNote(noteId: noteId)
    return .object(["deleted_note_id": .id(noteId)])
  }

  private func undoLastAction() throws -> JSONValue {
    guard let result = try service.undoLastAction() else {
      return .object(["undone": .bool(false), "reason": .string("nothing to undo")])
    }
    return .object([
      "undone": .bool(true),
      "action": .string(result.target.action),
      "entity_type": .string(result.target.entityType.rawValue),
      "entity_id": .string(result.target.entityId),
      "display": result.target.display
    ])
  }

  // MARK: - Guards and projections

  /// The agent may not write into an agent-conversation notebook: those notes
  /// are the chat transcript the runtime itself manages.
  private func assertAgentWritableNotebook(_ notebookId: NotebookID) throws {
    let notebook = try service.getNotebook(notebookId)
    if notebook.tags.contains(where: { $0.tag.name == NoteStoreSchema.agentConversationNotebookKindTag }) {
      throw AgentToolError.rejected(
        "notebook \(notebookId) is an agent conversation; the agent cannot modify its own transcript"
      )
    }
  }

  private func assertAgentWritableNote(_ noteId: NoteID) throws {
    let note = try service.getNote(noteId)
    try assertAgentWritableNotebook(note.notebookId)
  }

  static func tagNames(_ tags: [TagAssignment]) -> JSONValue {
    .array(tags.map { assignment in
      .object([
        "name": .string(assignment.tag.name),
        "class_id": assignment.tag.classId.map(JSONValue.id) ?? .null,
        "provenance": .string(assignment.provenance.rawValue)
      ])
    })
  }

  static func noteJSON(_ note: Note, includeBody: Bool) -> JSONObject {
    var object: JSONObject = [
      "note_id": .id(note.noteId),
      "notebook_id": .id(note.notebookId),
      "note_number": .integer(Int64(note.noteNumber)),
      "title": note.title.map(JSONValue.string) ?? .null,
      "read_only": .bool(note.readOnly),
      "created_at": .string(note.createdAt),
      "updated_at": .string(note.updatedAt),
      "tags": tagNames(note.tags)
    ]
    if includeBody {
      object["body_markdown"] = .string(AgentToolOutputLimits.bounded(
        note.bodyMarkdown,
        maximumBytes: AgentToolOutputLimits.maximumNoteBodyBytes
      ))
    }
    return object
  }

  static func notebookJSON(_ notebook: Notebook) -> JSONObject {
    [
      "notebook_id": .id(notebook.notebookId),
      "title": .string(notebook.title),
      "read_only": .bool(notebook.readOnly),
      "note_count": notebook.noteCount.map { .integer(Int64($0)) } ?? .null,
      "created_at": .string(notebook.createdAt),
      "updated_at": .string(notebook.updatedAt),
      "tags": tagNames(notebook.tags)
    ]
  }
}

/// Typed access to a tool call's JSON input with tool-facing error messages.
struct KaibaAgentToolInput {
  let value: JSONValue

  init(_ value: JSONValue) {
    self.value = value
  }

  private var object: JSONObject {
    value.asObject ?? [:]
  }

  func requiredString(_ key: String) throws -> String {
    guard let raw = object[key]?.asString else {
      throw AgentToolError.invalidInput("\(key) is required and must be a string")
    }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw AgentToolError.invalidInput("\(key) must not be empty")
    }
    return raw
  }

  func optionalString(_ key: String) throws -> String? {
    guard let present = object[key], !present.isNull else {
      return nil
    }
    guard let string = present.asString else {
      throw AgentToolError.invalidInput("\(key) must be a string")
    }
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : string
  }

  func optionalBool(_ key: String, default defaultValue: Bool) throws -> Bool {
    guard let present = object[key], !present.isNull else {
      return defaultValue
    }
    guard let flag = present.asBool else {
      throw AgentToolError.invalidInput("\(key) must be a boolean")
    }
    return flag
  }

  /// Non-empty trimmed strings; an absent or null key yields an empty list.
  func optionalStringArray(_ key: String) throws -> [String] {
    guard let present = object[key], !present.isNull else {
      return []
    }
    guard let items = present.asArray else {
      throw AgentToolError.invalidInput("\(key) must be an array of strings")
    }
    return try items.map { item in
      guard let value = item.asString else {
        throw AgentToolError.invalidInput("\(key) entries must be strings")
      }
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else {
        throw AgentToolError.invalidInput("\(key) entries must not be empty")
      }
      return trimmed
    }
  }

  func optionalInt(_ key: String, default defaultValue: Int, range: ClosedRange<Int>) throws -> Int {
    guard let present = object[key], !present.isNull else {
      return defaultValue
    }
    guard let number = present.asInt, range.contains(number) else {
      throw AgentToolError.invalidInput("\(key) must be an integer in \(range.lowerBound)...\(range.upperBound)")
    }
    return number
  }

  func requiredIdentifier<Identifier: KaibaIdentifier>(_ key: String, as type: Identifier.Type) throws -> Identifier {
    let raw = try requiredString(key).trimmingCharacters(in: .whitespacesAndNewlines)
    return Identifier(raw)
  }

  func optionalIdentifier<Identifier: KaibaIdentifier>(_ key: String, as type: Identifier.Type) throws -> Identifier? {
    guard let raw = try optionalString(key) else {
      return nil
    }
    return Identifier(raw.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  /// Tags as `["name", ...]` or `[{"name": ..., "class_id": ...}, ...]`.
  func tagInputs(_ key: String) throws -> [NoteTagInput] {
    guard let present = object[key], !present.isNull else {
      return []
    }
    guard let items = present.asArray else {
      throw AgentToolError.invalidInput("\(key) must be an array")
    }
    return try items.map { item in
      if let name = item.asString {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
          throw AgentToolError.invalidInput("\(key) entries must not be empty")
        }
        return NoteTagInput(name: trimmed)
      }
      guard let entry = item.asObject, let name = entry["name"]?.asString else {
        throw AgentToolError.invalidInput("\(key) entries must be strings or objects with a name")
      }
      let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else {
        throw AgentToolError.invalidInput("\(key) entries must not be empty")
      }
      let classId = entry["class_id"]?.asString.map { TagClassID($0) }
      return NoteTagInput(name: trimmed, classId: classId)
    }
  }
}
