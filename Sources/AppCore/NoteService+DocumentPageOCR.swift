import Foundation

public extension NoteService {
  /// Completes deferred OCR from the stored original. Recognition runs outside
  /// the transaction; concurrent note changes cause the final compare-and-write to fail.
  @discardableResult
  func recognizeDocumentPage(
    noteId: NoteID,
    recognizer: any DocumentPageRecognizing,
    analyzer: (any DocumentPageAnalyzing)? = nil
  ) throws -> Note {
    let snapshot = try driver.withDatabase { db in
      try requireEnabledActingUser(in: db)
      return try requirePendingDocumentOCRNote(noteId, in: db)
    }
    guard let page = snapshot.documentPage else {
      throw NoteServiceError.invalidInput("note is not an imported document page")
    }
    let content = try resolveFileContent(fileId: page.originFileId)
    let recognized: String
    let analysis: DocumentPageAnalysis
    let textSource: DocumentPageTextSource
    if page.isPDFPage, page.textExtractionMode != .ocrOnly,
       let native = try PDFDocumentImageExtractor.pageText(pdfData: content, pageNumber: page.pageNumber) {
      recognized = native
      analysis = page.analysis
      textSource = .pdfText
    } else {
      let image = page.isPDFPage
        ? try PDFDocumentImageExtractor.renderPage(pdfData: content, pageNumber: page.pageNumber)
        : DocumentExtractedImage(
          pageNumber: page.pageNumber, kind: .pageCapture, data: content,
          mediaType: page.originMediaType, suggestedFilename: "page"
        )
      let result = try recognizeTemporaryPage(image, recognizer: recognizer, analyzer: analyzer, fallback: page.analysis)
      recognized = result.text
      analysis = result.analysis
      textSource = .ocr
    }
    let outcome = try driver.withDatabase { database in
      try database.transaction { db in
        let current = try requirePendingDocumentOCRNote(noteId, in: db)
        guard current == snapshot else {
          throw NoteServiceError.conflict("page changed while OCR was running; no content was replaced")
        }
        let previous = try ftsPayload(noteId: noteId, in: db)
        let source = try noteTitleSource(noteId: noteId, in: db)
        let title = source == .derived ? (noteTitle(from: recognized) ?? current.title) : current.title
        let now = NoteStoreClock.system.now()
        try db.execute(
          """
          UPDATE document_pages
          SET text = ?, text_status = 'complete', text_source = ?, analysis_json = jsonb(?)
          WHERE note_id = ?
          """,
          bindings: [
            .text(recognized), .text(textSource.rawValue),
            .text(try documentPageAnalysisJSON(analysis)), .id(noteId)
          ]
        )
        try db.execute(
          """
          UPDATE notes
          SET title = ?, updated_at = ?,
            updated_by = (SELECT owner_user_id FROM notebooks WHERE notebook_id = notes.notebook_id)
          WHERE note_id = ?
          """,
          bindings: [.optionalText(title), .text(now), .id(noteId)]
        )
        try db.execute(
          "UPDATE notebooks SET updated_at = ?, updated_by = owner_user_id WHERE notebook_id = ?",
          bindings: [.text(now), .id(current.notebookId)]
        )
        // New page text changes what a translation of this notebook is based on.
        try bumpNotebookRevision(current.notebookId, in: db)
        try refreshFTS(noteId: noteId, previous: previous, in: db)
        let note = try requireNote(noteId, in: db)
        let dispatches = try enqueueAutoActions(
          for: makeAutoActionEvent(
            trigger: .noteUpdated,
            notebookId: note.notebookId,
            noteId: note.noteId,
            noteBodyMarkdown: noteRetrievalText(bodyMarkdown: current.bodyMarkdown, pageText: recognized),
            originatingActionId: nil
          ),
          in: db
        )
        return (note, dispatches)
      }
    }
    dispatchQueuedAutoActions(outcome.1)
    publishChange(NoteChangeEvent(kind: NoteChangeEventKind.noteUpdated, notebookId: outcome.0.notebookId))
    return outcome.0
  }
}

extension NoteService {
  /// The notebook import lock allows completing pending OCR; an explicit note
  /// lock still prevents it. Reachability and ownership checks are mandatory.
  /// The origin file is guaranteed by the `document_pages` foreign key.
  func requirePendingDocumentOCRNote(_ noteId: NoteID, in db: SQLiteDatabase) throws -> Note {
    let note = try requireNote(noteId, in: db)
    try requireNotebookOwnership(note.notebookId, subject: noteId.rawValue, in: db)
    guard !note.readOnly else { throw NoteServiceError.invalidInput("page is read-only") }
    guard let page = note.documentPage else {
      throw NoteServiceError.invalidInput("note is not an imported document page")
    }
    guard page.textStatus == .pending else {
      throw NoteServiceError.conflict("page OCR is already complete")
    }
    return note
  }
}

private func recognizeTemporaryPage(
  _ image: DocumentExtractedImage, recognizer: any DocumentPageRecognizing,
  analyzer: (any DocumentPageAnalyzing)?, fallback: DocumentPageAnalysis
) throws -> (text: String, analysis: DocumentPageAnalysis) {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let imageURL = directory.appendingPathComponent("page")
    .appendingPathExtension(DocumentImageNaming.fileExtension(forMediaType: image.mediaType))
  try image.data.write(to: imageURL)
  let analysis = try analyzer?.analyze(imageURL: imageURL) ?? fallback
  return (try recognizer.recognize(imageURL: imageURL), analysis)
}
