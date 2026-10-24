import Foundation

public struct DocumentPageText: Codable, Equatable, Sendable {
  public var pageNumber: Int
  public var text: String
  public var textSource: String?
  public var ocrState: String
}

public extension NoteService {
  func documentPageText(noteId: NoteID) throws -> DocumentPageText {
    try driver.withDatabase { db in
      let note = try requireNote(noteId, in: db)
      let metadata = try Self.importedPageMetadata(note)
      return DocumentPageText(
        pageNumber: metadata.pageNumber, text: try noteSearchText(noteId, in: db) ?? "",
        textSource: metadata.textSource, ocrState: metadata.ocrState
      )
    }
  }
}
