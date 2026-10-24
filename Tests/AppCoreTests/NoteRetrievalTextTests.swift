import Foundation
@testable import AppCore
import XCTest

final class NoteRetrievalTextTests: NoteTestCase {
  func testRetrievalTextJoinsBodyAndPageText() {
    XCTAssertEqual(noteRetrievalText(bodyMarkdown: "body", pageText: nil), "body")
    XCTAssertEqual(noteRetrievalText(bodyMarkdown: "body", pageText: ""), "body")
    XCTAssertEqual(noteRetrievalText(bodyMarkdown: "", pageText: "ocr"), "ocr")
    XCTAssertEqual(noteRetrievalText(bodyMarkdown: "b", pageText: "o"), "b\n\no")
  }

  func testPageTextReadersAndServiceRetrievalAccessors() throws {
    let driver = try makeNoteDriver()
    let service = try NoteService(driver: driver)
    let normal = try service.createNote(bodyMarkdown: "plain body")
    let page = try service.createNotebookWithNotes(
      title: "Pages",
      pages: [syntheticPageDraft(originFileId: try insertSyntheticOriginFile(service), text: "hidden OCR", readOnly: false)]
    ).notes[0]

    try driver.withDatabase { database in
      XCTAssertEqual(try storedDocumentPageText(page.noteId, in: database), "hidden OCR")
      XCTAssertNil(try storedDocumentPageText(normal.noteId, in: database))
      XCTAssertNil(try storedDocumentPageText(NoteID("missing"), in: database))
      XCTAssertEqual(
        try storedDocumentPageTexts([page.noteId, normal.noteId, NoteID("missing")], in: database),
        [page.noteId: "hidden OCR"]
      )
      XCTAssertEqual(try storedDocumentPageTexts([], in: database), [:])
    }
    XCTAssertEqual(try service.retrievalText(for: page), "hidden OCR")
    XCTAssertEqual(try service.retrievalTexts(for: [page, normal]), [
      page.noteId: "hidden OCR",
      normal.noteId: "plain body"
    ])
    XCTAssertEqual(try service.retrievalTexts(for: [page, page]), [page.noteId: "hidden OCR"])
    XCTAssertEqual(page.documentPage?.textStatus, .complete)
    XCTAssertTrue(NoteService.isDocumentPageNote(page))
    XCTAssertFalse(NoteService.isDocumentPageNote(normal))
  }
}
