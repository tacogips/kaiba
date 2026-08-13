private let sqliteConstraintPrimaryCode: Int32 = 19
private let sqliteUniqueConstraintMessage = "unique constraint failed"

func isSQLiteUniqueConstraintViolation(_ error: SQLiteError) -> Bool {
  error.operation == .execute
    && error.code == sqliteConstraintPrimaryCode
    && error.message.lowercased().contains(sqliteUniqueConstraintMessage)
}

func requireNotebook(_ notebookId: String, in database: SQLiteDatabase) throws -> Notebook {
  let rows = try database.query(
    """
    SELECT notebook_id, title, read_only, created_at, updated_at,
      CASE WHEN meta_json IS NULL THEN NULL ELSE json(meta_json) END AS meta_json
    FROM notebooks
    WHERE notebook_id = ?
    LIMIT 1
    """,
    bindings: [.text(notebookId)]
  )
  guard let row = rows.first else {
    throw NoteServiceError.notFound("notebook not found: \(notebookId)")
  }
  var notebook = try notebook(from: row, in: database)
  try enrichNotebookListMetadata(&notebook, in: database)
  return notebook
}

func requireNote(_ noteId: String, in database: SQLiteDatabase) throws -> Note {
  let rows = try database.query(
    """
    SELECT note_id, notebook_id, note_number, title, body_markdown, read_only,
      created_at, updated_at,
      CASE WHEN meta_json IS NULL THEN NULL ELSE json(meta_json) END AS meta_json
    FROM notes
    WHERE note_id = ?
    LIMIT 1
    """,
    bindings: [.text(noteId)]
  )
  guard let row = rows.first else {
    throw NoteServiceError.notFound("note not found: \(noteId)")
  }
  return try note(from: row, in: database)
}

@discardableResult
func requireWritableNote(_ noteId: String, in database: SQLiteDatabase) throws -> Note {
  let note = try requireNote(noteId, in: database)
  let notebook = try requireNotebook(note.notebookId, in: database)
  guard !note.readOnly, !notebook.readOnly else {
    throw NoteServiceError.readOnly(noteId)
  }
  return note
}

@discardableResult
func requireWritableNotebook(_ notebookId: String, in database: SQLiteDatabase) throws -> Notebook {
  let notebook = try requireNotebook(notebookId, in: database)
  guard !notebook.readOnly else {
    throw NoteServiceError.readOnly(notebookId)
  }
  return notebook
}

func requireNotes(_ noteIds: [String], in database: SQLiteDatabase) throws -> [String: Note] {
  let orderedNoteIds = orderedUnique(noteIds)
  guard !orderedNoteIds.isEmpty else {
    return [:]
  }
  let rows = try database.query(
    """
    SELECT note_id, notebook_id, note_number, title, body_markdown, read_only,
      created_at, updated_at,
      CASE WHEN meta_json IS NULL THEN NULL ELSE json(meta_json) END AS meta_json
    FROM notes
    WHERE note_id IN (\(placeholders(count: orderedNoteIds.count)))
    """,
    bindings: orderedNoteIds.map(SQLiteValue.text)
  )
  let hydratedNotes = try notes(from: rows, in: database)
  var notesById: [String: Note] = [:]
  notesById.reserveCapacity(hydratedNotes.count)
  for note in hydratedNotes {
    notesById[note.noteId] = note
  }
  return notesById
}

func findTag(name: String, in database: SQLiteDatabase) throws -> Tag? {
  let rows = try database.query(
    """
    SELECT tag_id, name, class_id, parent_tag_id, is_system, created_at
    FROM tags
    WHERE name = ?
    ORDER BY tag_id
    """,
    bindings: [.text(name)]
  )
  guard rows.count <= 1 else {
    throw NoteServiceError.invalidInput("tag name is ambiguous: \(name)")
  }
  return try rows.first.map(tag(from:))
}

func requireTag(name: String, in database: SQLiteDatabase) throws -> Tag {
  guard let tag = try findTag(name: name, in: database) else {
    throw NoteServiceError.notFound("tag not found: \(name)")
  }
  return tag
}

func requireTag(id tagId: String, in database: SQLiteDatabase) throws -> Tag {
  let rows = try database.query(
    """
    SELECT tag_id, name, class_id, parent_tag_id, is_system, created_at
    FROM tags
    WHERE tag_id = ?
    """,
    bindings: [.text(tagId)]
  )
  guard let row = rows.first else {
    throw NoteServiceError.notFound("tag not found: \(tagId)")
  }
  return try tag(from: row)
}

func findFolderTag(
  name: String,
  parentTagId: String?,
  in database: SQLiteDatabase
) throws -> Tag? {
  let parentPredicate = parentTagId == nil ? "parent_tag_id IS NULL" : "parent_tag_id = ?"
  let rows = try database.query(
    """
    SELECT tag_id, name, class_id, parent_tag_id, is_system, created_at
    FROM tags
    WHERE name = ? AND class_id = 'folder' AND \(parentPredicate)
    """,
    bindings: [.text(name)] + (parentTagId.map { [.text($0)] } ?? [])
  )
  guard rows.count <= 1 else {
    throw NoteServiceError.invalidInput("duplicate sibling folder name: \(name)")
  }
  return try rows.first.map(tag(from:))
}

func findNonFolderTag(name: String, in database: SQLiteDatabase) throws -> Tag? {
  let rows = try database.query(
    """
    SELECT tag_id, name, class_id, parent_tag_id, is_system, created_at
    FROM tags
    WHERE name = ? AND (class_id IS NULL OR class_id <> 'folder')
    ORDER BY tag_id
    """,
    bindings: [.text(name)]
  )
  guard rows.count <= 1 else {
    throw NoteServiceError.invalidInput("non-folder tag name is ambiguous: \(name)")
  }
  return try rows.first.map(tag(from:))
}

func requireNonFolderTag(name: String, in database: SQLiteDatabase) throws -> Tag {
  guard let tag = try findNonFolderTag(name: name, in: database) else {
    throw NoteServiceError.notFound("non-folder tag not found: \(name)")
  }
  return tag
}

func notebook(from row: SQLiteRow, in database: SQLiteDatabase) throws -> Notebook {
  guard let notebookId = row["notebook_id"],
        let title = row["title"],
        let createdAt = row["created_at"],
        let updatedAt = row["updated_at"] else {
    throw NoteServiceError.invalidRow("notebook row is missing required fields")
  }
  return Notebook(
    notebookId: notebookId,
    title: title,
    readOnly: row["read_only"] == "1",
    createdAt: createdAt,
    updatedAt: updatedAt,
    metaJSON: row["meta_json"] ?? nil,
    tags: try notebookTags(notebookId: notebookId, in: database)
  )
}

func note(from row: SQLiteRow, in database: SQLiteDatabase) throws -> Note {
  guard let noteId = row["note_id"] else {
    throw NoteServiceError.invalidRow("note row is missing note_id")
  }
  return try note(from: row, tags: noteTags(noteId: noteId, in: database))
}

func notes(from rows: [SQLiteRow], in database: SQLiteDatabase) throws -> [Note] {
  let noteIds = rows.compactMap { $0["note_id"] }
  let tagsByNoteId = try noteTags(noteIds: noteIds, in: database)
  return try rows.map { row in
    guard let noteId = row["note_id"] else {
      throw NoteServiceError.invalidRow("note row is missing note_id")
    }
    return try note(from: row, tags: tagsByNoteId[noteId] ?? [])
  }
}

private func note(from row: SQLiteRow, tags: [TagAssignment]) throws -> Note {
  guard let noteId = row["note_id"],
        let notebookId = row["notebook_id"],
        let noteNumberText = row["note_number"],
        let noteNumber = Int(noteNumberText),
        let bodyMarkdown = row["body_markdown"],
        let createdAt = row["created_at"],
        let updatedAt = row["updated_at"] else {
    throw NoteServiceError.invalidRow("note row is missing required fields")
  }
  return Note(
    noteId: noteId,
    notebookId: notebookId,
    noteNumber: noteNumber,
    title: row["title"] ?? nil,
    bodyMarkdown: bodyMarkdown,
    readOnly: row["read_only"] == "1",
    createdAt: createdAt,
    updatedAt: updatedAt,
    metaJSON: row["meta_json"] ?? nil,
    tags: tags
  )
}

func tag(from row: SQLiteRow) throws -> Tag {
  guard let tagId = row["tag_id"],
        let name = row["name"],
        let createdAt = row["created_at"] else {
    throw NoteServiceError.invalidRow("tag row is missing required fields")
  }
  return Tag(
    tagId: tagId,
    name: name,
    classId: row["class_id"] ?? nil,
    parentTagId: row["parent_tag_id"] ?? nil,
    isSystem: row["is_system"] == "1",
    createdAt: createdAt
  )
}
