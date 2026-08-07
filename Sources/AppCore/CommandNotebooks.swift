import Foundation

extension AppCommand {
  func runNotebook(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    guard let subcommand = cursor.next() else {
      throw Error.invalidUsage("notebook requires a subcommand: list|show|create|delete|progress")
    }
    var subContext = context
    subContext.cursor = cursor
    switch subcommand {
    case "list": return try runNotebookList(subContext)
    case "show": return try runNotebookShow(subContext)
    case "create": return try runNotebookCreate(subContext)
    case "delete": return try runNotebookDelete(subContext)
    case "progress": return try runNotebookProgress(subContext)
    case "readonly": return try runNotebookReadOnly(subContext)
    default:
      throw Error.invalidUsage("unknown notebook subcommand: \(subcommand)")
    }
  }

  private func runNotebookReadOnly(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    let on = cursor.extractFlag("--on")
    let off = cursor.extractFlag("--off")
    guard let notebookId = cursor.next(), on != off else {
      throw Error.invalidUsage(
        "notebook readonly requires <notebook-id> and exactly one of --on/--off"
      )
    }
    try cursor.finish()

    let service = try makeService(root: context.noteRoot)
    let notebook = try service.setNotebookReadOnly(notebookId: notebookId, readOnly: on)
    return "Notebook \(notebook.notebookId) is now \(notebook.readOnly ? "read-only" : "writable")"
  }

  private func runNotebookList(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    let tagFilter = try cursor.extractOptionValues("--tag")
    let sort = try cursor.extractSort()
    let createdAfter = try cursor.extractOption("--created-after")
    let createdBefore = try cursor.extractOption("--created-before")
    let limit = try cursor.extractIntOption("--limit") ?? 50
    let offset = try cursor.extractIntOption("--offset") ?? 0
    let output = try cursor.extractOutputMode()
    try cursor.finish()

    let service = try makeService(root: context.noteRoot)
    let notebooks = try service.listNotebooks(
      limit: limit,
      offset: offset,
      tagFilter: tagFilter,
      sort: sort,
      createdAfter: createdAfter,
      createdBefore: createdBefore
    )
    switch output {
    case .json:
      return try renderJSON(notebooks.map(jsonObject))
    case .text:
      guard !notebooks.isEmpty else {
        return "No notebooks."
      }
      return notebooks.map(renderNotebookLine).joined(separator: "\n")
    }
  }

  private func runNotebookShow(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    let output = try cursor.extractOutputMode()
    guard let notebookId = cursor.next() else {
      throw Error.invalidUsage("notebook show requires <notebook-id>")
    }
    try cursor.finish()

    let service = try makeService(root: context.noteRoot)
    let notebook = try service.getNotebook(notebookId)
    let notes = try service.listNotes(notebookId: notebookId)
    let files = try service.listFiles(notebookId: notebookId)
    switch output {
    case .json:
      var object = jsonObject(notebook)
      object["notes"] = notes.map(jsonObject)
      object["files"] = files.map { attachment -> [String: Any] in
        var file = jsonObject(attachment.file)
        file["role"] = attachment.role.rawValue
        return file
      }
      return try renderJSON(object)
    case .text:
      var lines = [renderNotebookLine(notebook)]
      if !notebook.tags.isEmpty {
        lines.append("tags: " + notebook.tags.map(renderTagLine).joined(separator: " "))
      }
      if !files.isEmpty {
        lines.append("files:")
        for attachment in files {
          let name = attachment.file.originalFilename ?? attachment.file.fileId
          lines.append("  \(attachment.file.fileId)  \(attachment.role.rawValue)  \(name)")
        }
      }
      if !notes.isEmpty {
        lines.append("notes:")
        lines.append(contentsOf: notes.map { "  " + renderNoteLine($0) })
      }
      return lines.joined(separator: "\n")
    }
  }

  private func runNotebookCreate(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    let title = try cursor.extractOption("--title")
    let kind = try cursor.extractOption("--kind")
    guard let title else {
      throw Error.invalidUsage("notebook create requires --title")
    }
    try cursor.finish()

    let service = try makeService(root: context.noteRoot)
    let notebook = try service.createNotebook(title: title, kindTagName: kind)
    return "Created notebook \(notebook.notebookId): \(notebook.title)"
  }

  private func runNotebookDelete(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    guard let notebookId = cursor.next() else {
      throw Error.invalidUsage("notebook delete requires <notebook-id>")
    }
    try cursor.finish()

    let service = try makeService(root: context.noteRoot)
    try service.deleteNotebook(notebookId: notebookId)
    return "Deleted notebook \(notebookId)"
  }

  private func runNotebookProgress(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    guard let notebookId = cursor.next(), let progress = cursor.next() else {
      throw Error.invalidUsage("notebook progress requires <notebook-id> <state>")
    }
    try cursor.finish()

    let service = try makeService(root: context.noteRoot)
    let notebook = try service.setNotebookProgress(notebookId: notebookId, progress: progress)
    return "Notebook \(notebook.notebookId) progress: \(notebook.progress)"
  }

  func runComment(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    let body = try cursor.extractOption("--body")
    guard let noteId = cursor.next(), let body else {
      throw Error.invalidUsage("comment requires <note-id> and --body <text>")
    }
    try cursor.finish()

    let service = try makeService(root: context.noteRoot)
    let comment = try service.addComment(noteId: noteId, bodyMarkdown: body)
    return "Added comment \(comment.commentId) to note \(noteId)"
  }

  func runLink(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    let kind = try cursor.extractOption("--kind") ?? "related"
    guard let fromNoteId = cursor.next(), let toNoteId = cursor.next() else {
      throw Error.invalidUsage("link requires <from-note-id> <to-note-id>")
    }
    try cursor.finish()

    let service = try makeService(root: context.noteRoot)
    let link = try service.linkNotes(from: fromNoteId, to: toNoteId, linkKind: kind)
    return "Linked \(link.fromNoteId) -> \(link.toNoteId) (\(link.linkKind))"
  }
}
