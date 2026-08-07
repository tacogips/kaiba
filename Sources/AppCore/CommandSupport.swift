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
  var cursor: CommandCursor
}

enum OutputMode: String {
  case text
  case json
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

func renderJSON(_ object: Any) throws -> String {
  let data = try JSONSerialization.data(
    withJSONObject: object,
    options: [.prettyPrinted, .sortedKeys]
  )
  return String(data: data, encoding: .utf8) ?? "{}"
}

func jsonObject(_ tag: Tag) -> [String: Any] {
  var object: [String: Any] = [
    "tagId": tag.tagId,
    "name": tag.name,
    "isSystem": tag.isSystem,
    "createdAt": tag.createdAt
  ]
  object["classId"] = tag.classId
  object["parentTagId"] = tag.parentTagId
  object["statusSetId"] = tag.statusSetId
  return object
}

func jsonObject(_ assignment: TagAssignment) -> [String: Any] {
  var object = jsonObject(assignment.tag)
  object["provenance"] = assignment.provenance.rawValue
  object["assignedBy"] = assignment.assignedBy
  object["deletable"] = assignment.deletable
  return object
}

func jsonObject(_ note: Note) -> [String: Any] {
  var object: [String: Any] = [
    "noteId": note.noteId,
    "notebookId": note.notebookId,
    "noteNumber": note.noteNumber,
    "bodyMarkdown": note.bodyMarkdown,
    "readOnly": note.readOnly,
    "createdAt": note.createdAt,
    "updatedAt": note.updatedAt,
    "tags": note.tags.map(jsonObject)
  ]
  object["title"] = note.title
  return object
}

func jsonObject(_ notebook: Notebook) -> [String: Any] {
  var object: [String: Any] = [
    "notebookId": notebook.notebookId,
    "title": notebook.title,
    "progress": notebook.progress,
    "readOnly": notebook.readOnly,
    "createdAt": notebook.createdAt,
    "updatedAt": notebook.updatedAt,
    "tags": notebook.tags.map(jsonObject)
  ]
  object["firstNotePreview"] = notebook.firstNotePreview
  object["noteCount"] = notebook.noteCount
  return object
}

func jsonObject(_ file: FileRecord) -> [String: Any] {
  var object: [String: Any] = [
    "fileId": file.fileId,
    "storageKind": file.storageKind.rawValue,
    "mediaType": file.mediaType,
    "byteSize": file.byteSize,
    "sha256": file.sha256,
    "createdAt": file.createdAt
  ]
  object["localPath"] = file.localPath
  object["s3Profile"] = file.s3Profile
  object["s3Bucket"] = file.s3Bucket
  object["s3Key"] = file.s3Key
  object["originalFilename"] = file.originalFilename
  object["migratedAt"] = file.migratedAt
  return object
}

func jsonObject(_ comment: NoteComment) -> [String: Any] {
  [
    "commentId": comment.commentId,
    "noteId": comment.noteId,
    "bodyMarkdown": comment.bodyMarkdown,
    "author": comment.author,
    "createdAt": comment.createdAt
  ]
}

func jsonObject(_ link: NoteLink) -> [String: Any] {
  [
    "fromNoteId": link.fromNoteId,
    "toNoteId": link.toNoteId,
    "linkKind": link.linkKind,
    "provenance": link.provenance.rawValue,
    "createdAt": link.createdAt
  ]
}

func jsonObject(_ result: NoteSearchResult) -> [String: Any] {
  var object = jsonObject(result.note)
  object["snippet"] = result.snippet
  object["rank"] = result.rank
  object["matchedTags"] = result.matchedTags.map(jsonObject)
  object["isLinkedNeighbor"] = result.isLinkedNeighbor
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
  let progress = notebook.progress == "none" ? "" : "  [\(notebook.progress)]"
  let preview = notebook.firstNotePreview.map { "  \u{2014} \($0)" } ?? ""
  return "\(notebook.notebookId)  \(notebook.createdAt)  \(notebook.title)\(count)\(progress)\(preview)"
}
