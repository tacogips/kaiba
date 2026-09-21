import Foundation
@testable import AppCore
import XCTest

final class DocumentPageImportTests: NoteTestCase {
  func testPersistsExactPageOriginsPendingStateFiguresAndTitle() throws {
    let service = try makeService()
    let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
    try Data("source".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }
    let result = try service.importDocumentPages(
      at: source.path,
      processor: DocumentPageProcessor(recognizer: ImportRecognizer(), analyzer: ImportAnalyzer(), extractor: ImportExtractor()),
      maximumOCRPages: 1
    )
    XCTAssertEqual(result.notebook.title, "Analyzed book title")
    XCTAssertEqual(result.notes.map(\.noteNumber), [1, 2])
    XCTAssertEqual(result.notes[0].bodyMarkdown, "# Recognized page\nBody")
    XCTAssertEqual(result.notes[1].bodyMarkdown, "\n\n![Figure 1](/files/\(try XCTUnwrap(result.imageFiles.last).file.fileId))")
    for (index, note) in result.notes.enumerated() {
      let persisted = try service.getNote(note.noteId)
      XCTAssertEqual(persisted, note)
      let metadata = try JSONValue(parsing: XCTUnwrap(persisted.metaJSON))
      let page = try XCTUnwrap(metadata.asObject?["documentPage"]?.asObject)
      XCTAssertEqual(page["ocrState"]?.asString, index == 0 ? "complete" : "pending")
      let origin = try XCTUnwrap(service.listFiles(noteId: note.noteId).first { $0.role == .sourcePageImage })
      XCTAssertEqual(page["originFileId"]?.asString, origin.file.fileId.rawValue)
      XCTAssertEqual(origin.position, index + 1)
      XCTAssertEqual(try service.resolveFileContent(fileId: origin.file.fileId), Data("origin \(index + 1)".utf8))
    }
    XCTAssertEqual(try service.resolveFileContent(fileId: result.sourceFile.file.fileId), Data("source".utf8))
    let analysis = try JSONValue(parsing: XCTUnwrap(result.notes[0].metaJSON)).asObject?["documentPage"]?.asObject?["analysis"]?.asObject
    XCTAssertEqual(analysis?["binding"]?.asString, "right")
    XCTAssertEqual(analysis?["writingMode"]?.asString, "vertical")
  }

  func testDeferredOCRCompletesReadOnlyImportAndPreservesFigure() throws {
    let service = try makeService()
    let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
    try Data("source".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }
    let result = try service.importDocumentPages(
      at: source.path, processor: DocumentPageProcessor(recognizer: ImportRecognizer(), extractor: ImportExtractor()), maximumOCRPages: 0
    )
    let pending = result.notes[1]
    let completed = try service.recognizeDocumentPage(noteId: pending.noteId, recognizer: ImportRecognizer(), analyzer: ImportAnalyzer())
    XCTAssertTrue(completed.bodyMarkdown.hasPrefix("# Recognized page\nBody"))
    XCTAssertTrue(completed.bodyMarkdown.hasSuffix(pending.bodyMarkdown))
    XCTAssertEqual(try NoteService.importedPageMetadata(completed).ocrState, "complete")
    XCTAssertEqual(try NoteService.importedPageMetadata(completed).analysis.language, "ja")
    XCTAssertThrowsError(try service.recognizeDocumentPage(noteId: pending.noteId, recognizer: ImportRecognizer()))
  }

  func testDeferredOCRStoresNewFiguresWithText() throws {
    let service = try makeService()
    let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
    try Data("source".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }
    let imported = try service.importDocumentPages(at: source.path, processor: DocumentPageProcessor(recognizer: ImportRecognizer()), maximumOCRPages: 0)
    let note = try service.recognizeDocumentPage(noteId: imported.notes[0].noteId, recognizer: ImportRecognizer(), figureExtractor: DeferredFigure())
    let files = try service.listFiles(noteId: note.noteId)
    let figure = try XCTUnwrap(files.first { $0.role == .embedded })
    XCTAssertTrue(note.bodyMarkdown.contains("![Figure 1](/files/\(figure.file.fileId.rawValue))"))
    XCTAssertEqual(try service.resolveFileContent(fileId: figure.file.fileId), Data("cropped figure".utf8))
    XCTAssertEqual(files.filter { $0.role == .sourcePageImage }.count, 1)
  }

  func testDeferredFigureLinkFailureRollsBackOCRAndRemovesStagedBlob() throws {
    let service = try makeService()
    let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
    try Data("source".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }
    let imported = try service.importDocumentPages(at: source.path, processor: DocumentPageProcessor(recognizer: ImportRecognizer()), maximumOCRPages: 0)
    try service.driver.withDatabase { db in
      try db.execute("CREATE TRIGGER fail_deferred_figure BEFORE INSERT ON note_files BEGIN SELECT RAISE(ABORT, 'test failure'); END")
    }
    let pending = imported.notes[0]
    XCTAssertThrowsError(try service.recognizeDocumentPage(noteId: pending.noteId, recognizer: ImportRecognizer(), figureExtractor: DeferredFigure()))
    XCTAssertEqual(try service.getNote(pending.noteId), pending)
    XCTAssertEqual(try service.listFiles(noteId: pending.noteId).count, 1)
    let filesRoot = URL(fileURLWithPath: service.noteRootPath()).appendingPathComponent("files")
    let enumerator = FileManager.default.enumerator(at: filesRoot, includingPropertiesForKeys: [.isRegularFileKey])
    let files = (enumerator?.allObjects as? [URL] ?? []).filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    XCTAssertEqual(files.count, 2) // source plus page original, no orphaned crop
  }

  func testDeferredOCRRejectsEditedPage() throws {
    let service = try makeService()
    let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
    try Data("source".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }
    let result = try service.importDocumentPages(
      at: source.path, processor: DocumentPageProcessor(recognizer: ImportRecognizer(), extractor: ImportExtractor()), maximumOCRPages: 0
    )
    _ = try service.setNotebookReadOnly(notebookId: result.notebook.notebookId, readOnly: false)
    let noteId = result.notes[0].noteId
    _ = try service.updateNoteBody(noteId: noteId, bodyMarkdown: "My own writing")
    XCTAssertThrowsError(try service.recognizeDocumentPage(noteId: noteId, recognizer: ImportRecognizer()))
    XCTAssertEqual(try service.getNote(noteId).bodyMarkdown, "My own writing")
  }

  func testRealDownloadedPDFPersistsEveryPageWithOnlyTwoOCRCalls() throws {
    guard let path = ProcessInfo.processInfo.environment["KAIBA_TEST_IMPORT_PDF"] else {
      throw XCTSkip("Set KAIBA_TEST_IMPORT_PDF for the real PDF import test")
    }
    let service = try makeService()
    let result = try service.importDocumentPages(
      at: path, processor: DocumentPageProcessor(recognizer: VisionDocumentPageRecognizer()), maximumOCRPages: 2
    )
    XCTAssertGreaterThan(result.notes.count, 2)
    for (index, note) in result.notes.enumerated() {
      let metadata = try JSONValue(parsing: XCTUnwrap(note.metaJSON))
      XCTAssertEqual(metadata.asObject?["documentPage"]?.asObject?["ocrState"]?.asString, index < 2 ? "complete" : "pending")
      let originals = try service.listFiles(noteId: note.noteId).filter { $0.role == .sourcePageImage }
      XCTAssertEqual(originals.count, 1)
      XCTAssertFalse(try service.resolveFileContent(fileId: XCTUnwrap(originals.first).file.fileId).isEmpty)
    }
    print("Persisted real PDF: \(result.notes.count) notes, 2 OCR complete, one origin per note")
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
    XCTAssertEqual(try service.getNote(noteId).bodyMarkdown, "Concurrent edit")
    XCTAssertEqual(try NoteService.importedPageMetadata(service.getNote(noteId)).ocrState, "pending")
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
}

private struct ImportRecognizer: DocumentPageRecognizing {
  func recognize(imageURL: URL) throws -> String { "# Recognized page\nBody" }
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
      DocumentExtractedImage(pageNumber: 2, kind: .embedded, data: Data("figure".utf8), mediaType: "image/png", suggestedFilename: "figure.png")
    ], pageTexts: ["", ""])
  }
}

private struct EditingRecognizer: DocumentPageRecognizing {
  var service: NoteService
  var noteId: NoteID
  func recognize(imageURL: URL) throws -> String {
    _ = try service.updateNoteBody(noteId: noteId, bodyMarkdown: "Concurrent edit")
    return "OCR must not overwrite the edit"
  }
}

private struct DeferredFigure: DocumentPageFigureExtracting {
  func extractFigures(imageURL: URL, pageNumber: Int) throws -> [DocumentExtractedImage] {
    [DocumentExtractedImage(pageNumber: pageNumber, kind: .embedded, data: Data("cropped figure".utf8), mediaType: "image/png", suggestedFilename: "figure.png")]
  }
}
