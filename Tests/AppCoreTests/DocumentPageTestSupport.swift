import Foundation
@testable import AppCore

/// Inserts a `files` row standing in for a page original, so synthetic
/// `document_pages` rows can satisfy their foreign key without a real import.
@discardableResult
func insertSyntheticOriginFile(
  _ service: NoteService,
  fileId: FileID = FileID.generate(),
  mediaType: String = "application/pdf"
) throws -> FileID {
  try service.driver.withDatabase { database in
    try database.execute(
      """
      INSERT INTO files (file_id, storage_kind, local_path, media_type, byte_size, sha256, created_at)
      VALUES (?, 'local', ?, ?, 0, 'synthetic', '2026-10-24T00:00:00.000Z')
      """,
      bindings: [.id(fileId), .text("files/\(fileId.rawValue)"), .text(mediaType)]
    )
  }
  return fileId
}

/// A page draft whose OCR version is `text`; an empty text is still pending.
func syntheticPageDraft(
  pageNumber: Int = 1,
  originFileId: FileID,
  originMediaType: String = "application/pdf",
  text: String,
  textStatus: DocumentPageTextStatus? = nil,
  textSource: DocumentPageTextSource? = nil,
  readOnly: Bool = true
) -> NotePageDraft {
  let status = textStatus ?? (text.isEmpty ? .pending : .complete)
  return NotePageDraft(
    bodyMarkdown: "",
    readOnly: readOnly,
    noteNumber: pageNumber,
    documentPage: DocumentPageDraft(
      page: DocumentPage(
        pageNumber: pageNumber,
        originFileId: originFileId,
        originMediaType: originMediaType,
        textExtractionMode: originMediaType == "application/pdf" ? .preferPDFText : nil,
        textStatus: status,
        textSource: status == .complete ? (textSource ?? .ocr) : nil
      ),
      text: text
    )
  )
}
