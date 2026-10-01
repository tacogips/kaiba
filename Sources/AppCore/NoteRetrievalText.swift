import Foundation

func noteRetrievalText(bodyMarkdown: String, searchText: String?) -> String {
  guard let searchText, !searchText.isEmpty else { return bodyMarkdown }
  guard !bodyMarkdown.isEmpty else { return searchText }
  return bodyMarkdown + "\n\n" + searchText
}

func noteSearchText(_ noteId: NoteID, in database: SQLiteDatabase) throws -> String? {
  try database.query(
    "SELECT search_text FROM notes WHERE note_id = ? LIMIT 1",
    bindings: [.id(noteId)]
  ).first?["search_text"]
}

func noteSearchTexts(_ noteIds: [NoteID], in database: SQLiteDatabase) throws -> [NoteID: String] {
  guard !noteIds.isEmpty else { return [:] }
  let rows = try database.query(
    "SELECT note_id, search_text FROM notes WHERE note_id IN (\(placeholders(count: noteIds.count)))",
    bindings: noteIds.sqliteBindings
  )
  return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
    guard let noteId = row.identifier("note_id", as: NoteID.self),
          let searchText = row["search_text"] else { return nil }
    return (noteId, searchText)
  })
}

func isDocumentPageMetaJSON(_ metaJSON: String?) -> Bool {
  guard let metaJSON else { return false }
  let note = Note(
    noteId: NoteID("metadata-check"),
    notebookId: NotebookID("metadata-check"),
    noteNumber: 0,
    title: nil,
    bodyMarkdown: "",
    readOnly: true,
    createdAt: "",
    updatedAt: "",
    metaJSON: metaJSON
  )
  return (try? NoteService.importedPageMetadata(note)) != nil
}

func documentPageTextMigration(
  bodyMarkdown: String,
  searchText: String?,
  metaJSON: String?
) -> (bodyMarkdown: String, searchText: String?) {
  guard isDocumentPageMetaJSON(metaJSON), searchText == nil else {
    return (bodyMarkdown, searchText)
  }
  return ("", bodyMarkdown)
}

extension NoteService {
  static func isDocumentPageNote(_ note: Note) -> Bool {
    (try? importedPageMetadata(note)) != nil
  }

  func retrievalText(for note: Note) throws -> String {
    try driver.withDatabase { database in
      noteRetrievalText(
        bodyMarkdown: note.bodyMarkdown,
        searchText: try noteSearchText(note.noteId, in: database)
      )
    }
  }

  func retrievalTexts(for notes: [Note]) throws -> [NoteID: String] {
    guard !notes.isEmpty else { return [:] }
    return try driver.withDatabase { database in
      let searchTexts = try noteSearchTexts(notes.map(\.noteId), in: database)
      var retrievalTexts: [NoteID: String] = [:]
      for note in notes {
        retrievalTexts[note.noteId] = noteRetrievalText(
          bodyMarkdown: note.bodyMarkdown,
          searchText: searchTexts[note.noteId]
        )
      }
      return retrievalTexts
    }
  }
}
