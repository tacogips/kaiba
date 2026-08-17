func enrichNotebookListMetadata(_ notebook: inout Notebook, in database: SQLiteDatabase) throws {
  notebook.firstNotePreview = try firstNotePreview(notebookId: notebook.notebookId, in: database)
  notebook.noteCount = try notebookNoteCount(notebookId: notebook.notebookId, in: database)
}

func enrichNotebookListMetadata(_ notebooks: inout [Notebook], in database: SQLiteDatabase) throws {
  let notebookIds = notebooks.map(\.notebookId)
  guard !notebookIds.isEmpty else {
    return
  }
  let previews = try firstNotePreviews(notebookIds: notebookIds, in: database)
  let counts = try notebookNoteCounts(notebookIds: notebookIds, in: database)
  for index in notebooks.indices {
    let notebookId = notebooks[index].notebookId
    notebooks[index].firstNotePreview = previews[notebookId]
    notebooks[index].noteCount = counts[notebookId] ?? 0
  }
}

private func notebookNoteCount(notebookId: NotebookID, in database: SQLiteDatabase) throws -> Int {
  let rows = try database.query(
    """
    SELECT COUNT(*) AS note_count
    FROM notes
    WHERE notebook_id = ?
    """,
    bindings: [.id(notebookId)]
  )
  guard let rawCount = rows.first?["note_count"], let count = Int(rawCount) else {
    throw NoteServiceError.invalidRow("note count row is missing required fields")
  }
  return count
}

private func firstNotePreviews(notebookIds: [NotebookID], in database: SQLiteDatabase) throws -> [NotebookID: String] {
  let rows = try database.query(
    """
    SELECT outer_notes.notebook_id, outer_notes.body_markdown
    FROM notes AS outer_notes
    WHERE outer_notes.notebook_id IN (\(noteStatPlaceholders(count: notebookIds.count)))
      AND outer_notes.note_id = (
        SELECT inner_notes.note_id
        FROM notes AS inner_notes
        WHERE inner_notes.notebook_id = outer_notes.notebook_id
        ORDER BY inner_notes.note_number, inner_notes.note_id
        LIMIT 1
      )
    """,
    bindings: notebookIds.sqliteBindings
  )
  var previews: [NotebookID: String] = [:]
  for row in rows {
    guard let notebookId = row.identifier("notebook_id", as: NotebookID.self), let body = row["body_markdown"] else {
      throw NoteServiceError.invalidRow("first note preview row is missing required fields")
    }
    previews[notebookId] = notebookPreviewText(body)
  }
  return previews
}

private func notebookNoteCounts(notebookIds: [NotebookID], in database: SQLiteDatabase) throws -> [NotebookID: Int] {
  let rows = try database.query(
    """
    SELECT notebook_id, COUNT(*) AS note_count
    FROM notes
    WHERE notebook_id IN (\(noteStatPlaceholders(count: notebookIds.count)))
    GROUP BY notebook_id
    """,
    bindings: notebookIds.sqliteBindings
  )
  var counts: [NotebookID: Int] = [:]
  for row in rows {
    guard let notebookId = row.identifier("notebook_id", as: NotebookID.self),
          let rawCount = row["note_count"],
          let count = Int(rawCount) else {
      throw NoteServiceError.invalidRow("note count row is missing required fields")
    }
    counts[notebookId] = count
  }
  return counts
}

private func noteStatPlaceholders(count: Int) -> String {
  Array(repeating: "?", count: count).joined(separator: ", ")
}

func notebookPreviewText(_ body: String) -> String {
  String(body.replacingOccurrences(of: "\n", with: " ").prefix(160))
}
