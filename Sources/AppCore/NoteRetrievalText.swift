import Foundation

/// The text a note contributes to search, AI context and content hashes: its
/// body plus, for a document page, the extracted (OCR version) text.
func noteRetrievalText(bodyMarkdown: String, pageText: String?) -> String {
  guard let pageText, !pageText.isEmpty else { return bodyMarkdown }
  guard !bodyMarkdown.isEmpty else { return pageText }
  return bodyMarkdown + "\n\n" + pageText
}

extension NoteService {
  static func isDocumentPageNote(_ note: Note) -> Bool {
    note.documentPage != nil
  }

  func retrievalText(for note: Note) throws -> String {
    try driver.withDatabase { database in
      noteRetrievalText(
        bodyMarkdown: note.bodyMarkdown,
        pageText: try storedDocumentPageText(note.noteId, in: database)
      )
    }
  }

  func retrievalTexts(for notes: [Note]) throws -> [NoteID: String] {
    guard !notes.isEmpty else { return [:] }
    return try driver.withDatabase { database in
      let pageTexts = try storedDocumentPageTexts(notes.map(\.noteId), in: database)
      var retrievalTexts: [NoteID: String] = [:]
      for note in notes {
        retrievalTexts[note.noteId] = noteRetrievalText(
          bodyMarkdown: note.bodyMarkdown,
          pageText: pageTexts[note.noteId]
        )
      }
      return retrievalTexts
    }
  }
}
