import Foundation

/// The OCR version of a page: its extracted text and how it was obtained.
public struct DocumentPageText: Codable, Equatable, Sendable {
  public var pageNumber: Int
  public var text: String
  public var textSource: DocumentPageTextSource?
  public var textStatus: DocumentPageTextStatus
}

public extension NoteService {
  func documentPageText(noteId: NoteID) throws -> DocumentPageText {
    try driver.withDatabase { db in
      let note = try requireNote(noteId, in: db)
      guard let page = note.documentPage else {
        throw NoteServiceError.invalidInput("note is not an imported document page")
      }
      return DocumentPageText(
        pageNumber: page.pageNumber, text: try storedDocumentPageText(noteId, in: db) ?? "",
        textSource: page.textSource, textStatus: page.textStatus
      )
    }
  }
}
