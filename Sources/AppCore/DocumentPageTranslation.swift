import Foundation

/// A saved derived note linked to its source page, independent of notebook position.
public struct DocumentPageTranslation: Codable, Equatable, Sendable {
  public var noteId: NoteID
  public var notebookId: NotebookID
  public var sourceNoteId: NoteID
  public var targetLanguage: String
  public var text: String
}

public extension NoteService {
  func documentPageTranslations(noteId: NoteID) throws -> [DocumentPageTranslation] {
    try driver.withDatabase { db in
      let source = try requireNote(noteId, in: db)
      let rows = try db.query(
        """
        SELECT n.note_id FROM notes n JOIN notebooks b ON b.notebook_id = n.notebook_id
        WHERE json_extract(n.meta_json, '$.kaibaTranslation.sourceNoteId') = ?
          AND b.owner_user_id = (SELECT owner_user_id FROM notebooks WHERE notebook_id = ?)
          AND b.library_id IS (SELECT library_id FROM notebooks WHERE notebook_id = ?)
        ORDER BY n.created_at DESC, n.note_id
        """,
        bindings: [.id(noteId), .id(source.notebookId), .id(source.notebookId)]
      )
      return try rows.compactMap { row in
        guard let id = row.identifier("note_id", as: NoteID.self) else { return nil }
        let note = try requireNote(id, in: db)
        let notebook = try requireNotebook(note.notebookId, in: db)
        guard let state = Self.translationState(of: notebook), state.sourceNotebookId == source.notebookId else {
          return nil
        }
        return DocumentPageTranslation(
          noteId: id, notebookId: note.notebookId, sourceNoteId: noteId,
          targetLanguage: state.targetLanguage, text: note.bodyMarkdown
        )
      }
    }
  }
}
