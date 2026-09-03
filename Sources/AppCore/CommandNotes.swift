import Foundation

extension AppCommand {
  func runAdd(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    let notebookId = try cursor.extractIdentifierOption("--notebook", as: NotebookID.self)
    let title = try cursor.extractOption("--title")
    let tagNames = try cursor.extractOptionValues("--tag")
    let readOnly = cursor.extractFlag("--read-only")
    let output = try cursor.extractOutputMode()
    guard let body = try readBody(cursor: &cursor, required: true) else {
      throw Error.invalidUsage("a body is required (--body, --body-file, or -)")
    }
    try cursor.finish()

    let service = try makeService(context)
    let note = try service.createNote(
      notebookId: notebookId,
      title: title,
      bodyMarkdown: body,
      readOnly: readOnly,
      tags: tagNames.map { NoteTagInput(name: $0) },
      provenance: .human,
      assignedBy: "kaiba-cli"
    )
    switch output {
    case .json:
      return try renderJSON(jsonObject(note))
    case .text:
      return "Created note \(note.noteId) in notebook \(note.notebookId) (note #\(note.noteNumber))"
    }
  }

  func runEdit(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    let append = cursor.extractFlag("--append")
    let output = try cursor.extractOutputMode()
    let body = try readBody(cursor: &cursor, required: true)
    guard let noteId = cursor.nextIdentifier(as: NoteID.self), let body else {
      throw Error.invalidUsage("edit requires <note-id> and a body")
    }
    try cursor.finish()

    let service = try makeService(context)
    let newBody: String
    if append {
      let existing = try service.getNote(noteId)
      newBody = existing.bodyMarkdown.isEmpty ? body : existing.bodyMarkdown + "\n\n" + body
    } else {
      newBody = body
    }
    let note = try service.updateNoteBody(noteId: noteId, bodyMarkdown: newBody)
    switch output {
    case .json:
      return try renderJSON(jsonObject(note))
    case .text:
      return "Updated note \(note.noteId)"
    }
  }

  func runShow(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    let output = try cursor.extractOutputMode()
    guard let noteId = cursor.nextIdentifier(as: NoteID.self) else {
      throw Error.invalidUsage("show requires <note-id>")
    }
    try cursor.finish()

    let service = try makeService(context)
    let note = try service.getNote(noteId)
    let comments = try service.listComments(noteId: noteId)
    let files = try service.listFiles(noteId: noteId)
    let links = try service.listLinks(noteId: noteId)

    switch output {
    case .json:
      var object = jsonObject(note)
      object["comments"] = .array(comments.map { .object(jsonObject($0)) })
      object["files"] = .array(files.map { attachment in
        var file = jsonObject(attachment.file)
        file["role"] = .string(attachment.role.rawValue)
        file["position"] = .integer(Int64(attachment.position))
        return .object(file)
      })
      object["links"] = .array(links.map { .object(jsonObject($0)) })
      return try renderJSON(object)
    case .text:
      var lines: [String] = []
      let readOnly = note.readOnly ? "  [read-only]" : ""
      lines.append("note \(note.noteId)  (notebook \(note.notebookId), #\(note.noteNumber))\(readOnly)")
      lines.append("created \(note.createdAt)  updated \(note.updatedAt)")
      if !note.tags.isEmpty {
        lines.append("tags: " + note.tags.map(renderTagLine).joined(separator: " "))
      }
      if !links.isEmpty {
        lines.append("links:")
        for link in links {
          let other = link.fromNoteId == note.noteId ? "-> \(link.toNoteId)" : "<- \(link.fromNoteId)"
          lines.append("  \(other)  (\(link.linkKind))")
        }
      }
      if !files.isEmpty {
        lines.append("files:")
        for attachment in files {
          let name = attachment.file.originalFilename ?? attachment.file.fileId.rawValue
          lines.append(
            "  \(attachment.file.fileId)  \(attachment.role.rawValue)  \(name)  \(attachment.file.mediaType)"
          )
        }
      }
      lines.append("")
      lines.append(note.bodyMarkdown)
      if !comments.isEmpty {
        lines.append("")
        lines.append("comments:")
        for comment in comments {
          lines.append("  [\(comment.createdAt)] \(comment.author): \(comment.bodyMarkdown)")
        }
      }
      return lines.joined(separator: "\n")
    }
  }

  func runList(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    let notebookId = try cursor.extractIdentifierOption("--notebook", as: NotebookID.self)
    let tagFilter = try cursor.extractOptionValues("--tag")
    let limit = try cursor.extractIntOption("--limit") ?? 100
    let offset = try cursor.extractIntOption("--offset") ?? 0
    let output = try cursor.extractOutputMode()
    try cursor.finish()

    let service = try makeService(context)
    let notes = try service.listNotes(
      limit: limit,
      offset: offset,
      notebookId: notebookId,
      tagFilter: tagFilter
    )
    switch output {
    case .json:
      return try renderJSON(notes.map(jsonObject))
    case .text:
      guard !notes.isEmpty else {
        return "No notes."
      }
      return notes.map(renderNoteLine).joined(separator: "\n")
    }
  }

  func runSearch(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    let tagFilter = try cursor.extractOptionValues("--tag")
    let classFilter = try cursor.extractOptionValues("--class")
    let notebookId = try cursor.extractIdentifierOption("--notebook", as: NotebookID.self)
    let includeLinked = cursor.extractFlag("--include-linked")
    let includeMemos = cursor.extractFlag("--memos")
    let sort = try cursor.extractSort()
    let createdAfter = try cursor.extractOption("--created-after")
    let createdBefore = try cursor.extractOption("--created-before")
    let limit = try cursor.extractIntOption("--limit") ?? 20
    let offset = try cursor.extractIntOption("--offset") ?? 0
    let output = try cursor.extractOutputMode()
    guard let query = cursor.next() else {
      throw Error.invalidUsage("search requires <query>")
    }
    try cursor.finish()

    let service = try makeService(context)
    let results = try service.searchNotes(
      query: query,
      tagFilter: tagFilter,
      classFilter: classFilter,
      notebookId: notebookId,
      sort: sort,
      createdAfter: createdAfter,
      createdBefore: createdBefore,
      includeLinked: includeLinked,
      limit: limit,
      offset: offset
    )
    let memoMatches = includeMemos
      ? try service.searchComments(query: query, notebookId: notebookId, limit: min(limit, 200))
      : []
    switch output {
    case .json:
      var payload: [JSONObject] = results.map(jsonObject)
      payload.append(contentsOf: memoMatches.map { memo in
        [
          "kind": .string("memo"),
          "commentId": .id(memo.commentId),
          "noteId": .optionalID(memo.noteId),
          "notebookId": .optionalID(memo.notebookId),
          "author": .string(memo.author),
          "createdAt": .string(memo.createdAt),
          "bodyMarkdown": .string(memo.bodyMarkdown)
        ]
      })
      return try renderJSON(payload)
    case .text:
      guard !results.isEmpty || !memoMatches.isEmpty else {
        return "No matches."
      }
      var lines = results.map { result in
        let linked = result.isLinkedNeighbor ? "  [linked]" : ""
        let partial = result.termCoverage < 1
          ? "  [partial \(Int((result.termCoverage * 100).rounded()))%]"
          : ""
        return renderNoteLine(result.note) + linked + partial + "\n    \(result.snippet)"
      }
      lines.append(contentsOf: memoMatches.map { memo in
        let anchor = memo.noteId.map { "note \($0)" }
          ?? memo.notebookId.map { "notebook \($0)" }
          ?? "unanchored"
        let body = memo.bodyMarkdown.replacingOccurrences(of: "\n", with: " ")
        return "memo \(memo.commentId)  [\(anchor)]\n    \(String(body.prefix(200)))"
      })
      return lines.joined(separator: "\n")
    }
  }

  func runReadOnly(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    let on = cursor.extractFlag("--on")
    let off = cursor.extractFlag("--off")
    guard let noteId = cursor.nextIdentifier(as: NoteID.self), on != off else {
      throw Error.invalidUsage("readonly requires <note-id> and exactly one of --on/--off")
    }
    try cursor.finish()

    let service = try makeService(context)
    let note = try service.setReadOnly(noteId: noteId, readOnly: on)
    return "Note \(note.noteId) is now \(note.readOnly ? "read-only" : "writable")"
  }

  func runDelete(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    guard let noteId = cursor.nextIdentifier(as: NoteID.self) else {
      throw Error.invalidUsage("delete requires <note-id>")
    }
    try cursor.finish()

    let service = try makeService(context)
    try service.deleteNote(noteId: noteId)
    return "Deleted note \(noteId)"
  }
}
