import Foundation

extension NoteService {
  static func savedBranchContext(_ notebook: Notebook) throws -> String? {
    guard let metaJSON = notebook.metaJSON else { return nil }
    return try JSONValue(parsing: metaJSON)["kaibaChat"]?["branchContext"]?.asString
  }

  /// Store the fork's starting context in the same transaction as its creation.
  /// Later parent replies and edits must not silently change a branch's history.
  func agentBranchContext(
    noteId: NoteID,
    notebook: Notebook,
    in database: SQLiteDatabase
  ) throws -> String? {
    guard notebook.type == .agentChat else { return nil }
    let note = try requireNote(noteId, in: database)
    let inherited = try agentChatInheritedContext(notebook, in: database)
    let rows = try database.query(
      """
      SELECT note_id, body_markdown FROM notes
      WHERE notebook_id = ? AND note_number <= ?
      ORDER BY note_number, note_id
      """,
      bindings: [.id(notebook.notebookId), .int(Int64(note.noteNumber))]
    )
    let sections = try rows.map { row in
      guard let turnId = row.identifier("note_id", as: NoteID.self) else {
        throw NoteServiceError.invalidRow("branch turn is missing its note ID")
      }
      return (row["body_markdown"] ?? "") + (try chatFileContext(noteId: turnId, in: database))
    }
    return "# Inherited context\n\(inherited)\n\n# Parent conversation through branch point\n"
      + sections.joined(separator: "\n\n")
  }

  func agentChatInheritedContext(_ notebook: Notebook, in database: SQLiteDatabase) throws -> String {
    guard let subject = try chatSubject(notebookId: notebook.notebookId, in: database) else {
      throw NoteServiceError.invalidInput("parent chat is missing its subject")
    }
    if let saved = try Self.savedBranchContext(notebook) { return saved }
    switch subject {
    case let .note(noteId):
      return try noteChatContext(requireNote(noteId, in: database), in: database)
    case let .notebook(notebookId):
      return try notebookContextMarkdown(notebookId: notebookId, in: database)
    }
  }

  /// Read attachments under the caller's authorized database snapshot. Persist
  /// their text in branches so future file removal cannot change inherited context.
  func chatFileContext(noteId: NoteID, in database: SQLiteDatabase) throws -> String {
    _ = try requireNote(noteId, in: database)
    let rows = try database.query(
      """
      SELECT f.*, nf.note_id, nf.role, nf.position
      FROM note_files nf JOIN files f ON f.file_id = nf.file_id
      WHERE nf.note_id = ? ORDER BY nf.position, f.file_id
      """,
      bindings: [.id(noteId)]
    )
    var context = ""
    for row in rows {
      let file = try fileRecord(from: row)
      let data = try LocalNoteFileStore(noteRoot: noteRootPath()).read(record: file)
      guard let text = String(data: data, encoding: .utf8) else {
        throw NoteServiceError.invalidInput("chat attachment must be UTF-8 text")
      }
      let filename = promptMetadata(file.originalFilename ?? file.fileId.rawValue)
      let mediaType = promptMetadata(file.mediaType)
      context += "<attachment filename=\"\(filename)\" media-type=\"\(mediaType)\">\n\(text)\n</attachment>\n"
    }
    return context.isEmpty ? "" : "\n<untrusted-attachments>\n\(context)</untrusted-attachments>"
  }
}
