import Foundation

/// The closed set of versions a document page can be read in
/// (`design-docs/specs/note-store-schema-v25.md`). Every case has dedicated
/// storage; a new version is added by adding its case, its storage in the ERD
/// and its API field, never by registering a type at runtime.
public enum DocumentPageVersionKind: String, Codable, CaseIterable, Equatable, Sendable {
  /// The retained PDF page or page image (`document_pages.origin_file_id`).
  case original
  /// Extracted text: native PDF text or OCR (`document_pages.text`).
  case ocr
  /// One translated body per language (`note_translations`).
  case translated
}

public enum DocumentPageTextStatus: String, Codable, Equatable, Sendable {
  case pending
  case complete
}

public enum DocumentPageTextSource: String, Codable, Equatable, Sendable {
  case pdfText = "pdf-text"
  case ocr
}

/// An imported physical page. The extracted text is loaded on its own
/// (`documentPageText`), so hydrating a page list never pulls every page body.
public struct DocumentPage: Codable, Equatable, Sendable {
  public var pageNumber: Int
  public var originFileId: FileID
  /// `files.media_type` of the original: `application/pdf` for a page of the
  /// retained PDF, an image type when the image itself is the page.
  public var originMediaType: String
  public var textExtractionMode: PDFTextExtractionMode?
  public var textStatus: DocumentPageTextStatus
  public var textSource: DocumentPageTextSource?
  public var analysis: DocumentPageAnalysis

  public init(
    pageNumber: Int,
    originFileId: FileID,
    originMediaType: String,
    textExtractionMode: PDFTextExtractionMode? = nil,
    textStatus: DocumentPageTextStatus,
    textSource: DocumentPageTextSource? = nil,
    analysis: DocumentPageAnalysis = DocumentPageAnalysis()
  ) {
    self.pageNumber = pageNumber
    self.originFileId = originFileId
    self.originMediaType = originMediaType
    self.textExtractionMode = textExtractionMode
    self.textStatus = textStatus
    self.textSource = textSource
    self.analysis = analysis
  }

  public var isPDFPage: Bool {
    originMediaType == DocumentPage.pdfMediaType
  }

  static let pdfMediaType = "application/pdf"
}

private let documentPageSelect = """
  SELECT dp.note_id, dp.page_number, dp.origin_file_id, f.media_type AS origin_media_type,
    dp.text_extraction_mode, dp.text_status, dp.text_source, json(dp.analysis_json) AS analysis_json
  FROM document_pages dp
  INNER JOIN files f ON f.file_id = dp.origin_file_id
  """

func documentPages(noteIds: [NoteID], in database: SQLiteDatabase) throws -> [NoteID: DocumentPage] {
  let ids = orderedUnique(noteIds)
  guard !ids.isEmpty else { return [:] }
  let rows = try database.query(
    "\(documentPageSelect) WHERE dp.note_id IN (\(placeholders(count: ids.count)))",
    bindings: ids.sqliteBindings
  )
  var pages: [NoteID: DocumentPage] = [:]
  for row in rows {
    guard let noteId = row.identifier("note_id", as: NoteID.self) else {
      throw NoteServiceError.invalidRow("document page row is missing note_id")
    }
    pages[noteId] = try documentPage(from: row)
  }
  return pages
}

func documentPage(noteId: NoteID, in database: SQLiteDatabase) throws -> DocumentPage? {
  try documentPages(noteIds: [noteId], in: database)[noteId]
}

private func documentPage(from row: SQLiteRow) throws -> DocumentPage {
  guard let pageNumber = row["page_number"].flatMap(Int.init),
        let originFileId = row.identifier("origin_file_id", as: FileID.self),
        let originMediaType = row["origin_media_type"],
        let textStatus = row["text_status"].flatMap(DocumentPageTextStatus.init(rawValue:)),
        let analysisJSON = row["analysis_json"] else {
    throw NoteServiceError.invalidRow("document page row is missing required fields")
  }
  return DocumentPage(
    pageNumber: pageNumber,
    originFileId: originFileId,
    originMediaType: originMediaType,
    textExtractionMode: row["text_extraction_mode"].flatMap(PDFTextExtractionMode.init(rawValue:)),
    textStatus: textStatus,
    textSource: row["text_source"].flatMap(DocumentPageTextSource.init(rawValue:)),
    analysis: try JSONDecoder().decode(DocumentPageAnalysis.self, from: Data(analysisJSON.utf8))
  )
}

func insertDocumentPage(
  noteId: NoteID,
  page: DocumentPage,
  text: String,
  in database: SQLiteDatabase
) throws {
  try database.execute(
    """
    INSERT INTO document_pages (
      note_id, origin_file_id, page_number, text_extraction_mode,
      text, text_status, text_source, analysis_json
    ) VALUES (?, ?, ?, ?, ?, ?, ?, jsonb(?))
    """,
    bindings: [
      .id(noteId),
      .id(page.originFileId),
      .int(Int64(page.pageNumber)),
      .optionalText(page.textExtractionMode?.rawValue),
      .text(text),
      .text(page.textStatus.rawValue),
      .optionalText(page.textSource?.rawValue),
      .text(try documentPageAnalysisJSON(page.analysis))
    ]
  )
}

func documentPageAnalysisJSON(_ analysis: DocumentPageAnalysis) throws -> String {
  guard let json = String(bytes: try JSONEncoder().encode(analysis), encoding: .utf8) else {
    throw NoteServiceError.invalidInput("document page analysis JSON must be UTF-8")
  }
  return json
}

/// The extracted (OCR version) text of a page, or nil for a note that is not
/// a document page.
func storedDocumentPageText(_ noteId: NoteID, in database: SQLiteDatabase) throws -> String? {
  try database.query(
    "SELECT text FROM document_pages WHERE note_id = ? LIMIT 1",
    bindings: [.id(noteId)]
  ).first?["text"]
}

func storedDocumentPageTexts(_ noteIds: [NoteID], in database: SQLiteDatabase) throws -> [NoteID: String] {
  guard !noteIds.isEmpty else { return [:] }
  let rows = try database.query(
    "SELECT note_id, text FROM document_pages WHERE note_id IN (\(placeholders(count: noteIds.count)))",
    bindings: noteIds.sqliteBindings
  )
  return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
    guard let noteId = row.identifier("note_id", as: NoteID.self), let text = row["text"] else {
      return nil
    }
    return (noteId, text)
  })
}
