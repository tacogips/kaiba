import Foundation
@testable import AppCore
import XCTest

final class DocumentImportFormatRegressionTests: NoteTestCase {
  func testHeadingSplitImportsAndNormalNotesRemainEditableMarkdown() throws {
    let markdown = "# Chapter One\n\nAlpha body\n\n# Chapter Two\n\nBeta body"
    for format in ["epub", "docx", "html", "md", "txt"] {
      let service = try makeService()
      let source = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(UUID().uuidString).\(format)")
      try Data("synthetic source".utf8).write(to: source)
      defer { try? FileManager.default.removeItem(at: source) }

      let imported = try service.importDocument(
        at: source.path,
        converter: RegressionConverter(markdown: markdown, format: format),
        imageExtractor: RegressionImageExtractor()
      )

      XCTAssertEqual(imported.notes.count, 2, format)
      XCTAssertTrue(imported.notes[0].bodyMarkdown.contains("Alpha body"), format)
      XCTAssertTrue(imported.notes[1].bodyMarkdown.contains("Beta body"), format)
      _ = try service.setNotebookReadOnly(notebookId: imported.notebook.notebookId, readOnly: false)
      for note in imported.notes {
        XCTAssertNil(try service.driver.withDatabase {
          try $0.query("SELECT search_text FROM notes WHERE note_id = ?", bindings: [.id(note.noteId)]).first?["search_text"]
        }, format)
        XCTAssertFalse((note.metaJSON ?? "").contains("documentPage"), format)
        XCTAssertNoThrow(try service.updateNoteBody(noteId: note.noteId, bodyMarkdown: note.bodyMarkdown + "\n\nEdited"), format)
      }
      let result = try XCTUnwrap(service.searchNotes(query: "Alpha").first { $0.note.noteId == imported.notes[0].noteId })
      XCTAssertTrue(result.snippet.contains("Alpha body"), format)
    }

    let service = try makeService()
    let note = try service.createNote(bodyMarkdown: "Normal note body")
    XCTAssertEqual(try service.updateNoteBody(noteId: note.noteId, bodyMarkdown: "Normal note edited").bodyMarkdown, "Normal note edited")
    XCTAssertTrue(try service.searchNotes(query: "edited").contains { $0.note.noteId == note.noteId })
  }
}

private struct RegressionConverter: DocumentConverting {
  var markdown: String
  var format: String
  func convert(inputPath: String) throws -> DocumentConversionResult {
    DocumentConversionResult(markdown: markdown, sourceFormat: format)
  }
}

private struct RegressionImageExtractor: DocumentImageExtracting {
  func extractImages(fileURL: URL, sourceFormat: String) throws -> DocumentImageExtractionResult { .empty }
}
