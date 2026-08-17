public extension NoteService {
  /// Returns the note's zero-based position in its notebook's stable
  /// `note_number, note_id` order without loading the preceding notes.
  func noteOffsetInNotebook(noteId: NoteID) throws -> Int {
    try driver.withDatabase { database in
      let note = try requireNote(noteId, in: database)
      let rows = try database.query(
        """
        SELECT COUNT(*) AS note_offset
        FROM notes
        WHERE notebook_id = ?
          AND (
            note_number < ?
            OR (note_number = ? AND note_id < ?)
          )
        """,
        bindings: [
          .id(note.notebookId),
          .int(Int64(note.noteNumber)),
          .int(Int64(note.noteNumber)),
          .id(note.noteId)
        ]
      )
      guard let rawOffset = rows.first?["note_offset"], let offset = Int(rawOffset) else {
        throw NoteServiceError.invalidRow("note offset row is missing required fields")
      }
      return offset
    }
  }
}
