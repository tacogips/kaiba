import Foundation
@testable import AppCore
import XCTest

final class DocumentPageImportTests: NoteTestCase {
  func testDeferredPDFOCRRendersTemporaryImageAndKeepsPageMemosSeparate() throws {
    let service = try makeService()
    let source = try makeMixedPDFTextFixture()
    defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
    let result = try service.importDocumentPages(
      at: source.path, processor: DocumentPageProcessor(recognizer: ImportRecognizer()), maximumOCRPages: 0
    )
    XCTAssertEqual(result.notes.count, 2)
    let page = result.notes[1]
    let recognizer = TemporaryPDFRecognizer()
    let complete = try service.recognizeDocumentPage(noteId: page.noteId, recognizer: recognizer)
    XCTAssertEqual(try NoteService.importedPageMetadata(complete).ocrState, "complete")
    XCTAssertEqual(try service.driver.withDatabase { try noteSearchText(page.noteId, in: $0) }, "Second page\n\nSearchable text")
    XCTAssertNotNil(recognizer.imageURL)
    XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(recognizer.imageURL).path))
    XCTAssertTrue(try service.listFiles(noteId: page.noteId).isEmpty)
    XCTAssertEqual(try service.resolveFileContent(fileId: result.sourceFile.file.fileId), try Data(contentsOf: source))
    XCTAssertEqual(try service.driver.withDatabase { try $0.query("SELECT file_id FROM files").count }, 1)
    let firstChat = try service.startAgentConversation(subjectNoteId: result.notes[0].noteId)
    let secondChat = try service.startAgentConversation(subjectNoteId: page.noteId)
    XCTAssertNotEqual(firstChat.notebookId, secondChat.notebookId)
    let context = try service.documentPageChatAdditions(subjectNoteId: page.noteId, libraryId: XCTUnwrap(result.notebook.libraryId), query: "Second")
    XCTAssertTrue(try XCTUnwrap(context).images.isEmpty)
  }

  func testPDFStoresOnlyOriginalAndPlainSearchText() throws {
    let service = try makeService()
    let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
    try Data("source".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }
    let result = try service.importDocumentPages(
      at: source.path,
      processor: DocumentPageProcessor(recognizer: ImportRecognizer(), analyzer: ImportAnalyzer(), extractor: ImportExtractor()),
      maximumOCRPages: 2
    )
    XCTAssertEqual(result.notebook.title, source.lastPathComponent)
    XCTAssertEqual(result.notes.map(\.noteNumber), [1, 2, 3])
    XCTAssertEqual(result.notes.map(\.bodyMarkdown), ["", "", ""])
    for (index, note) in result.notes.enumerated() {
      let persisted = try service.getNote(note.noteId)
      XCTAssertEqual(persisted, note)
      let metadata = try JSONValue(parsing: XCTUnwrap(persisted.metaJSON))
      let page = try XCTUnwrap(metadata.asObject?["documentPage"]?.asObject)
      XCTAssertEqual(page["ocrState"]?.asString, index < 2 ? "complete" : "pending")
      XCTAssertNil(page["pendingBodySHA256"])
      XCTAssertEqual(
        try service.driver.withDatabase { try noteSearchText(note.noteId, in: $0) },
        index < 2 ? "Recognized page\n\nBody" : ""
      )
      XCTAssertTrue(try service.listFiles(noteId: note.noteId).isEmpty)
      XCTAssertEqual(page["originFileId"]?.asString, result.sourceFile.file.fileId.rawValue)
      XCTAssertEqual(page["originMediaType"]?.asString, "application/pdf")
    }
    XCTAssertEqual(try service.resolveFileContent(fileId: result.sourceFile.file.fileId), Data("source".utf8))
    let analysis = try JSONValue(parsing: XCTUnwrap(result.notes[0].metaJSON)).asObject?["documentPage"]?.asObject?["analysis"]?.asObject
    XCTAssertEqual(analysis?["binding"]?.asString, "right")
    XCTAssertEqual(analysis?["writingMode"]?.asString, "vertical")
  }

  func testDeferredOCRCompletesSearchTextAndDoesNotRecordBodyHistory() throws {
    let service = try makeService()
    let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
    try Data("source".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }
    let result = try service.importDocumentPages(
      at: source.path, processor: DocumentPageProcessor(recognizer: ImportRecognizer(), extractor: ImportExtractor()), maximumOCRPages: 0
    )
    let pending = try XCTUnwrap(result.notes.last)
    let completed = try service.recognizeDocumentPage(noteId: pending.noteId, recognizer: ImportRecognizer(), analyzer: ImportAnalyzer())
    XCTAssertEqual(completed.bodyMarkdown, "")
    XCTAssertEqual(try service.driver.withDatabase { try noteSearchText(completed.noteId, in: $0) }, "Recognized page\n\nBody")
    XCTAssertTrue(try service.searchNotes(query: "Recognized").contains { $0.note.noteId == pending.noteId })
    XCTAssertFalse(try service.actionHistory().contains { $0.kind == .noteBodyUpdated && $0.entityId == pending.noteId.rawValue })
    XCTAssertEqual(try NoteService.importedPageMetadata(completed).ocrState, "complete")
    XCTAssertEqual(try NoteService.importedPageMetadata(completed).analysis.language, "ja")
    XCTAssertThrowsError(try service.recognizeDocumentPage(noteId: pending.noteId, recognizer: ImportRecognizer()))
  }

  func testDeferredOCRPrependsToExistingSearchText() throws {
    let service = try makeService()
    let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
    try Data("source".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }
    let imported = try service.importDocumentPages(at: source.path, processor: DocumentPageProcessor(recognizer: ImportRecognizer()), maximumOCRPages: 0)
    let note = try XCTUnwrap(imported.notes.first)
    try service.driver.withDatabase { db in
      let previous = try ftsPayload(noteId: note.noteId, in: db)
      try db.execute("UPDATE notes SET search_text = ? WHERE note_id = ?", bindings: [.text("legacy text ![Figure 1](/files/f1)"), .id(note.noteId)])
      try refreshFTS(noteId: note.noteId, previous: previous, in: db)
    }
    let completed = try service.recognizeDocumentPage(noteId: note.noteId, recognizer: ImportRecognizer())
    XCTAssertEqual(try service.driver.withDatabase { try noteSearchText(completed.noteId, in: $0) }, "Recognized page\n\nBody\n\nlegacy text ![Figure 1](/files/f1)")
    XCTAssertEqual(completed.bodyMarkdown, "")
  }

  func testDeferredOCRRejectsEditedPage() throws {
    let service = try makeService()
    let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
    try Data("source".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }
    let result = try service.importDocumentPages(
      at: source.path, processor: DocumentPageProcessor(recognizer: ImportRecognizer(), extractor: ImportExtractor()), maximumOCRPages: 0
    )
    _ = try service.setNotebookReadOnly(notebookId: result.notebook.notebookId, readOnly: false)
    let noteId = result.notes[0].noteId
    XCTAssertThrowsError(try service.updateNoteBody(noteId: noteId, bodyMarkdown: "My own writing")) { error in
      XCTAssertEqual(error as? NoteServiceError, .invalidInput("document page text is managed by OCR; use a comment to annotate the page"))
    }
    XCTAssertNoThrow(try service.recognizeDocumentPage(noteId: noteId, recognizer: ImportRecognizer()))
  }

  func testRealDownloadedTextPDFPersistsEveryPageWithoutRasterAttachments() throws {
    guard let path = ProcessInfo.processInfo.environment["KAIBA_TEST_IMPORT_PDF"] else {
      throw XCTSkip("Set KAIBA_TEST_IMPORT_PDF for the real PDF import test")
    }
    let service = try makeService()
    let result = try service.importDocumentPages(
      at: path, processor: DocumentPageProcessor(recognizer: VisionDocumentPageRecognizer()), maximumOCRPages: 2
    )
    XCTAssertGreaterThan(result.notes.count, 2)
    for note in result.notes {
      let metadata = try JSONValue(parsing: XCTUnwrap(note.metaJSON))
      XCTAssertEqual(metadata.asObject?["documentPage"]?.asObject?["ocrState"]?.asString, "complete")
      XCTAssertEqual(try NoteService.importedPageMetadata(note).textSource, "pdf-text")
      let originals = try service.listFiles(noteId: note.noteId).filter { $0.role == .sourcePageImage }
      XCTAssertTrue(originals.isEmpty)
      let page = try NoteService.importedPageMetadata(note)
      XCTAssertEqual(page.originFileId, result.sourceFile.file.fileId.rawValue)
      XCTAssertEqual(page.originMediaType, "application/pdf")
    }
    print("Persisted real PDF: \(result.notes.count) notes, native text extracted, one original PDF, no page image attachments")
  }

  func testFileLinkFailureRollsBackNotebookNotesAndStagedFiles() throws {
    let service = try makeService()
    try service.driver.withDatabase { db in
      try db.execute("CREATE TRIGGER fail_page_file BEFORE INSERT ON note_files BEGIN SELECT RAISE(ABORT, 'test failure'); END")
    }
    let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
    try Data("image".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }
    let before = try service.driver.withDatabase { try $0.query("SELECT notebook_id FROM notebooks") }
    XCTAssertThrowsError(try service.importDocumentPages(
      at: source.path, processor: DocumentPageProcessor(recognizer: ImportRecognizer()), maximumOCRPages: 0
    ))
    let after = try service.driver.withDatabase { try $0.query("SELECT notebook_id FROM notebooks") }
    XCTAssertEqual(after.count, before.count)
    XCTAssertTrue(try service.driver.withDatabase { try $0.query("SELECT file_id FROM files") }.isEmpty)
    let root = URL(fileURLWithPath: service.noteRootPath()).appendingPathComponent("files")
    let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
    let files = (enumerator?.allObjects as? [URL] ?? []).filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    XCTAssertTrue(files.isEmpty)
  }

  func testConcurrentEditDuringOCRIsNotOverwritten() throws {
    let service = try makeService()
    let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
    try Data("image".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }
    let result = try service.importDocumentPages(
      at: source.path, processor: DocumentPageProcessor(recognizer: ImportRecognizer()), maximumOCRPages: 0
    )
    _ = try service.setNotebookReadOnly(notebookId: result.notebook.notebookId, readOnly: false)
    let noteId = result.notes[0].noteId
    let recognizer = EditingRecognizer(service: service, noteId: noteId)
    XCTAssertThrowsError(try service.recognizeDocumentPage(noteId: noteId, recognizer: recognizer))
    XCTAssertEqual(try service.getNote(noteId).bodyMarkdown, "")
    XCTAssertEqual(try service.driver.withDatabase { try noteSearchText(noteId, in: $0) }, "")
    XCTAssertEqual(try NoteService.importedPageMetadata(service.getNote(noteId)).ocrState, "pending")
  }

  func testStandalonePNGImportStoresOCROnlyAsSearchTextAndSupportsPendingLimit() throws {
    let service = try makeService()
    let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
    let bytes = Data("synthetic PNG bytes".utf8)
    try bytes.write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }
    let complete = try service.importDocumentPages(at: source.path, processor: DocumentPageProcessor(recognizer: ImportRecognizer()))
    let note = try XCTUnwrap(complete.notes.first)
    XCTAssertEqual(complete.notes.count, 1)
    XCTAssertEqual(note.bodyMarkdown, "")
    XCTAssertEqual(try service.driver.withDatabase { try noteSearchText(note.noteId, in: $0) }, "Recognized page\n\nBody")
    let files = try service.listFiles(noteId: note.noteId)
    XCTAssertEqual(files.count, 1)
    XCTAssertEqual(files.first?.role, .sourcePageImage)
    XCTAssertEqual(try service.resolveFileContent(fileId: XCTUnwrap(files.first).file.fileId), bytes)
    XCTAssertTrue(try service.searchNotes(query: "Recognized").contains { $0.note.noteId == note.noteId })

    let pending = try service.importDocumentPages(at: source.path, processor: DocumentPageProcessor(recognizer: ImportRecognizer()), maximumOCRPages: 0)
    let pendingNote = try XCTUnwrap(pending.notes.first)
    XCTAssertEqual(pendingNote.bodyMarkdown, "")
    XCTAssertEqual(try service.driver.withDatabase { try noteSearchText(pendingNote.noteId, in: $0) }, "")
    XCTAssertEqual(try NoteService.importedPageMetadata(pendingNote).ocrState, "pending")
  }

  func testPageLimitConfigurationRoundTripsAndRejectsInvalidValues() throws {
    let decoder = JSONDecoder()
    for value in ["0", "3", "\"all\""] {
      let limit = try decoder.decode(DocumentOCRPageLimit.self, from: Data(value.utf8))
      XCTAssertEqual(try decoder.decode(DocumentOCRPageLimit.self, from: JSONEncoder().encode(limit)), limit)
    }
    for value in ["-1", "1.5", "\"3\"", "true"] {
      XCTAssertThrowsError(try decoder.decode(DocumentOCRPageLimit.self, from: Data(value.utf8)))
    }
  }

  func testLegacyPendingBodyDigestMetadataStillDecodes() throws {
    let json = Data(
      #"{"pageNumber":1,"ocrState":"pending","analysis":{"isDocument":null,"language":null,"writingMode":"unknown","binding":"unknown","title":null},"originFileId":"origin","pendingBodySHA256":"legacy-digest"}"#.utf8
    )
    let metadata = try JSONDecoder().decode(ImportedPageMetadata.self, from: json)
    XCTAssertEqual(metadata.pendingBodySHA256, "legacy-digest")
  }
}

private struct ImportRecognizer: DocumentPageRecognizing {
  func recognize(imageURL: URL) throws -> String { "Recognized page\n\nBody" }
}

private final class TemporaryPDFRecognizer: DocumentPageRecognizing, @unchecked Sendable {
  var imageURL: URL?
  func recognize(imageURL: URL) throws -> String {
    self.imageURL = imageURL
    let data = try Data(contentsOf: imageURL)
    XCTAssertEqual(Array(data.prefix(2)), [0xff, 0xd8])
    return "Second page\n\nSearchable text"
  }
}

private struct ImportAnalyzer: DocumentPageAnalyzing {
  func analyze(imageURL: URL) throws -> DocumentPageAnalysis {
    DocumentPageAnalysis(isDocument: true, language: "ja", writingMode: .vertical, binding: .right, title: "Analyzed book title")
  }
}

private struct ImportExtractor: DocumentImageExtracting {
  func extractImages(fileURL: URL, sourceFormat: String) throws -> DocumentImageExtractionResult {
    DocumentImageExtractionResult(images: [
      DocumentExtractedImage(pageNumber: 1, kind: .pageCapture, data: Data("origin 1".utf8), mediaType: "image/png", suggestedFilename: "1.png"),
      DocumentExtractedImage(pageNumber: 2, kind: .pageCapture, data: Data("origin 2".utf8), mediaType: "image/png", suggestedFilename: "2.png"),
      DocumentExtractedImage(pageNumber: 2, kind: .embedded, data: Data("figure".utf8), mediaType: "image/png", suggestedFilename: "figure.png"),
      DocumentExtractedImage(pageNumber: 3, kind: .pageCapture, data: Data("origin 3".utf8), mediaType: "image/png", suggestedFilename: "3.png")
    ], pageTexts: ["", "", ""])
  }
}

private struct EditingRecognizer: DocumentPageRecognizing {
  var service: NoteService
  var noteId: NoteID
  func recognize(imageURL: URL) throws -> String {
    try service.driver.withDatabase { db in
      try db.execute("UPDATE notes SET updated_at = 'concurrent change' WHERE note_id = ?", bindings: [.id(noteId)])
    }
    return "OCR must not overwrite the edit"
  }
}
