import Foundation

/// Sequential argument reader with option extraction shared by all commands.
public struct CommandCursor: Sendable {
  private(set) var remaining: [String]

  public init(arguments: [String]) {
    remaining = arguments
  }

  public mutating func next() -> String? {
    guard !remaining.isEmpty else {
      return nil
    }
    return remaining.removeFirst()
  }

  /// Removes every occurrence of `option <value>` and returns the last value.
  public mutating func extractOption(_ option: String) throws -> String? {
    var value: String?
    while let index = remaining.firstIndex(of: option) {
      guard index + 1 < remaining.count else {
        throw AppCommand.Error.missingValue(option)
      }
      value = remaining[index + 1]
      remaining.removeSubrange(index...(index + 1))
    }
    return value
  }

  /// Removes every occurrence of `option <value>` and returns all values in order.
  public mutating func extractOptionValues(_ option: String) throws -> [String] {
    var values: [String] = []
    while let index = remaining.firstIndex(of: option) {
      guard index + 1 < remaining.count else {
        throw AppCommand.Error.missingValue(option)
      }
      values.append(remaining[index + 1])
      remaining.removeSubrange(index...(index + 1))
    }
    return values
  }

  public mutating func extractFlag(_ flag: String) -> Bool {
    var found = false
    while let index = remaining.firstIndex(of: flag) {
      found = true
      remaining.remove(at: index)
    }
    return found
  }

  /// Removes a bare literal argument (e.g. `-` for stdin) if present.
  public mutating func extractLiteral(_ literal: String) -> Bool {
    guard let index = remaining.firstIndex(of: literal) else {
      return false
    }
    remaining.remove(at: index)
    return true
  }

  /// Reads `option <id>` as a typed identifier. The CLI is one of the places a
  /// raw string legitimately becomes an id, and blank text is rejected here
  /// rather than reaching the store as a lookup key that matches nothing.
  public mutating func extractIdentifierOption<Identifier: KaibaIdentifier>(
    _ option: String,
    as type: Identifier.Type = Identifier.self
  ) throws -> Identifier? {
    guard let raw = try extractOption(option) else {
      return nil
    }
    guard let identifier = Identifier(validating: raw) else {
      throw AppCommand.Error.invalidUsage("\(option) expects an id, got an empty value")
    }
    return identifier
  }

  /// Reads the next positional argument as a typed identifier.
  public mutating func nextIdentifier<Identifier: KaibaIdentifier>(
    as type: Identifier.Type = Identifier.self
  ) -> Identifier? {
    next().flatMap { Identifier(validating: $0) }
  }

  public mutating func extractIntOption(_ option: String) throws -> Int? {
    guard let raw = try extractOption(option) else {
      return nil
    }
    guard let value = Int(raw) else {
      throw AppCommand.Error.invalidUsage("\(option) expects an integer, got: \(raw)")
    }
    return value
  }

  /// Fails when unconsumed arguments remain (typo protection).
  public func finish() throws {
    if let stray = remaining.first {
      if stray.hasPrefix("-") {
        throw AppCommand.Error.unknownArgument(stray)
      }
      throw AppCommand.Error.invalidUsage("unexpected argument: \(stray)")
    }
  }
}

struct CommandContext {
  var noteRoot: String
  var configuration: KaibaConfiguration
  var cursor: CommandCursor
  /// The `--jwt` credential, verified once the store is open. Nil runs the
  /// command unscoped, which is the operator view of the whole store.
  var authToken: String?
  /// The `--library` selection (or `KAIBA_LIBRARY`), resolved to a library id
  /// once the store is open. Nil writes to the default library and reads
  /// across every library the caller may see.
  var librarySelection: String?
}

enum OutputMode: String {
  case text
  case json
}

/// Runs one async call from a synchronous command. The CLI entry point is not
/// async, and the rest of the package bridges the same way (see
/// `TursoHTTPDatabase.perform`).
func runBlocking<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
  let box = BlockingResultBox<T>()
  let semaphore = DispatchSemaphore(value: 0)
  Task {
    do {
      box.store(.success(try await work()))
    } catch {
      box.store(.failure(error))
    }
    semaphore.signal()
  }
  semaphore.wait()
  return try box.take()
}

private final class BlockingResultBox<T: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var result: Result<T, Swift.Error>?

  func store(_ value: Result<T, Swift.Error>) {
    lock.lock()
    defer { lock.unlock() }
    result = value
  }

  func take() throws -> T {
    lock.lock()
    defer { lock.unlock() }
    guard let result else {
      throw NoteServiceError.invalidInput("background work did not complete")
    }
    return try result.get()
  }
}

extension CommandCursor {
  mutating func extractSort() throws -> NoteListSort {
    guard let raw = try extractOption("--sort") else {
      return .createdAtDesc
    }
    switch raw {
    case "created-desc": return .createdAtDesc
    case "created-asc": return .createdAtAsc
    case "updated-desc": return .updatedAtDesc
    case "title": return .title
    default:
      throw AppCommand.Error.invalidUsage(
        "--sort expects created-desc, created-asc, updated-desc, or title; got: \(raw)"
      )
    }
  }

  mutating func extractOutputMode() throws -> OutputMode {
    guard let raw = try extractOption("--output") else {
      return .text
    }
    guard let mode = OutputMode(rawValue: raw) else {
      throw AppCommand.Error.invalidUsage("--output expects json or text, got: \(raw)")
    }
    return mode
  }
}

extension AppCommand {
  func makeService(root noteRoot: String) throws -> NoteService {
    try FileManager.default.createDirectory(
      atPath: noteRoot,
      withIntermediateDirectories: true
    )
    return try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: noteRoot))
  }

  /// Opens the store for a command, scoped to the `--jwt` account when one was
  /// supplied. Every write the command makes is then attributed to that user
  /// and every catalog read is filtered to it, which is what lets an agent run
  /// `kaiba` as the person who asked it to
  /// (`design-docs/specs/note-api-auth.md`).
  func makeService(_ context: CommandContext) throws -> NoteService {
    try FileManager.default.createDirectory(
      atPath: context.noteRoot,
      withIntermediateDirectories: true
    )
    let service = try NoteService(driver: KaibaConfigurationLoader.makeDriver(
      configuration: context.configuration.database,
      noteRoot: context.noteRoot,
      environment: environment
    ))
    var resolved = service
    if let authToken = context.authToken {
      let user = try service.resolveAuthToken(authToken)
      resolved = service.scoped(to: user.userId)
    }
    return try applyLibrarySelection(context.librarySelection, to: resolved)
  }

  /// Resolves `--library` against what the caller may see. An unscoped caller
  /// naming an authenticated library is refused with the same message as a
  /// missing one, so the selection cannot be used to probe for libraries that
  /// are hidden from it (`design-docs/specs/library.md`).
  private func applyLibrarySelection(
    _ selection: String?,
    to service: NoteService
  ) throws -> NoteService {
    guard let selection else {
      return service
    }
    let normalized = try normalizedLibraryName(selection)
    guard let library = try service.listLibraries().first(where: { $0.name == normalized }) else {
      throw AppCommand.Error.invalidUsage("library not found: \(selection)")
    }
    return service.scoped(toLibrary: library.libraryId)
  }

  /// Reads a body from `--body`, `--body-file`, or stdin when `-` is present.
  func readBody(cursor: inout CommandCursor, required: Bool) throws -> String? {
    let inline = try cursor.extractOption("--body")
    let file = try cursor.extractOption("--body-file")
    let stdinRequested = cursor.extractLiteral("-")
    let provided = [inline != nil, file != nil, stdinRequested].filter { $0 }
    guard provided.count <= 1 else {
      throw AppCommand.Error.invalidUsage("use only one of --body, --body-file, or -")
    }
    if let inline {
      return inline
    }
    if let file {
      return try String(
        contentsOf: URL(fileURLWithPath: (file as NSString).expandingTildeInPath),
        encoding: .utf8
      )
    }
    if stdinRequested {
      let data = FileHandle.standardInput.readDataToEndOfFile()
      guard let body = String(data: data, encoding: .utf8) else {
        throw AppCommand.Error.invalidUsage("stdin is not valid UTF-8")
      }
      return body
    }
    if required {
      throw AppCommand.Error.invalidUsage("a body is required (--body, --body-file, or -)")
    }
    return nil
  }
}

// MARK: - Rendering

/// Renders `--output json`. Values are `JSONValue` rather than `Any`, so a
/// type the JSON writer cannot represent is a compile error instead of a
/// crash inside `JSONSerialization`.
func renderJSON(_ value: JSONValue) throws -> String {
  try value.encodedString(prettyPrinted: true)
}

func renderJSON(_ object: JSONObject) throws -> String {
  try renderJSON(.object(object))
}

func renderJSON(_ objects: [JSONObject]) throws -> String {
  try renderJSON(.array(objects.map(JSONValue.object)))
}

/// Optional members are dropped rather than written as null, which is the
/// shape these payloads have always had.
func jsonObject(_ tag: Tag) -> JSONObject {
  var object: JSONObject = [
    "tagId": .id(tag.tagId),
    "name": .string(tag.name),
    "isSystem": .bool(tag.isSystem),
    "createdAt": .string(tag.createdAt)
  ]
  object["classId"] = tag.classId.map(JSONValue.id)
  object["parentTagId"] = tag.parentTagId.map(JSONValue.id)
  return object
}

func jsonObject(_ assignment: TagAssignment) -> JSONObject {
  var object = jsonObject(assignment.tag)
  object["provenance"] = .string(assignment.provenance.rawValue)
  object["assignedBy"] = assignment.assignedBy.map(JSONValue.string)
  object["deletable"] = .bool(assignment.deletable)
  return object
}

func jsonObject(_ note: Note) -> JSONObject {
  var object: JSONObject = [
    "noteId": .id(note.noteId),
    "notebookId": .id(note.notebookId),
    "noteNumber": .integer(Int64(note.noteNumber)),
    "bodyMarkdown": .string(note.bodyMarkdown),
    "readOnly": .bool(note.readOnly),
    "createdAt": .string(note.createdAt),
    "updatedAt": .string(note.updatedAt),
    "tags": .array(note.tags.map { .object(jsonObject($0)) })
  ]
  object["title"] = note.title.map(JSONValue.string)
  object["metaJSON"] = note.metaJSON.map(JSONValue.string)
  return object
}

func jsonObject(_ notebook: Notebook) -> JSONObject {
  var object: JSONObject = [
    "notebookId": .id(notebook.notebookId),
    "title": .string(notebook.title),
    "readOnly": .bool(notebook.readOnly),
    "createdAt": .string(notebook.createdAt),
    "updatedAt": .string(notebook.updatedAt),
    "tags": .array(notebook.tags.map { .object(jsonObject($0)) })
  ]
  object["firstNotePreview"] = notebook.firstNotePreview.map(JSONValue.string)
  object["noteCount"] = notebook.noteCount.map { .integer(Int64($0)) }
  return object
}

func jsonObject(_ file: FileRecord) -> JSONObject {
  var object: JSONObject = [
    "fileId": .id(file.fileId),
    "storageKind": .string(file.storageKind.rawValue),
    "mediaType": .string(file.mediaType),
    "byteSize": .integer(file.byteSize),
    "sha256": .string(file.sha256),
    "createdAt": .string(file.createdAt)
  ]
  object["localPath"] = file.localPath.map(JSONValue.string)
  object["s3Profile"] = file.s3Profile.map(JSONValue.string)
  object["s3Bucket"] = file.s3Bucket.map(JSONValue.string)
  object["s3Key"] = file.s3Key.map(JSONValue.string)
  object["originalFilename"] = file.originalFilename.map(JSONValue.string)
  object["migratedAt"] = file.migratedAt.map(JSONValue.string)
  return object
}

func jsonObject(_ comment: NoteComment) -> JSONObject {
  [
    "commentId": .id(comment.commentId),
    "noteId": .optionalID(comment.noteId),
    "notebookId": .optionalID(comment.notebookId),
    "bodyMarkdown": .string(comment.bodyMarkdown),
    "author": .string(comment.author),
    "createdAt": .string(comment.createdAt)
  ]
}

func jsonObject(_ link: NoteLink) -> JSONObject {
  [
    "fromNoteId": .id(link.fromNoteId),
    "toNoteId": .id(link.toNoteId),
    "linkKind": .string(link.linkKind),
    "provenance": .string(link.provenance.rawValue),
    "createdAt": .string(link.createdAt)
  ]
}

func jsonObject(_ result: NoteSearchResult) -> JSONObject {
  var object = jsonObject(result.note)
  object["snippet"] = .string(result.snippet)
  object["rank"] = .number(result.rank)
  object["matchedTags"] = .array(result.matchedTags.map { .object(jsonObject($0)) })
  object["isLinkedNeighbor"] = .bool(result.isLinkedNeighbor)
  object["termCoverage"] = .number(result.termCoverage)
  return object
}

func renderTagLine(_ assignment: TagAssignment) -> String {
  let provenance = assignment.provenance == .human ? "" : "(\(assignment.provenance.rawValue))"
  return "#\(assignment.tag.name)\(provenance)"
}

func renderNoteLine(_ note: Note) -> String {
  let title = note.title ?? note.bodyMarkdown
    .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
    .first.map(String.init) ?? "(empty)"
  let tags = note.tags.isEmpty ? "" : "  " + note.tags.map(renderTagLine).joined(separator: " ")
  let readOnly = note.readOnly ? "  [read-only]" : ""
  return "\(note.noteId)  \(note.createdAt)  \(title)\(readOnly)\(tags)"
}

func renderNotebookLine(_ notebook: Notebook) -> String {
  let count = notebook.noteCount.map { " (\($0) notes)" } ?? ""
  let preview = notebook.firstNotePreview.map { "  \u{2014} \($0)" } ?? ""
  return "\(notebook.notebookId)  \(notebook.createdAt)  \(notebook.title)\(count)\(preview)"
}
