import Foundation
@testable import AppCore
import XCTest

final class NoteRetrievalTextTests: NoteTestCase {
  func testRetrievalTextJoinsBodyAndSearchText() {
    XCTAssertEqual(noteRetrievalText(bodyMarkdown: "body", searchText: nil), "body")
    XCTAssertEqual(noteRetrievalText(bodyMarkdown: "body", searchText: ""), "body")
    XCTAssertEqual(noteRetrievalText(bodyMarkdown: "", searchText: "ocr"), "ocr")
    XCTAssertEqual(noteRetrievalText(bodyMarkdown: "b", searchText: "o"), "b\n\no")
  }

  func testDocumentPageTextMigrationOnlyMovesUnmigratedPageBodies() {
    let pageMeta = #"{"documentPage":{"pageNumber":1,"ocrState":"complete","analysis":{"writingMode":"unknown","binding":"unknown"},"originFileId":"file-1"}}"#
    XCTAssertEqual(
      documentPageTextMigration(bodyMarkdown: "ocr", searchText: nil, metaJSON: pageMeta).bodyMarkdown,
      ""
    )
    XCTAssertEqual(
      documentPageTextMigration(bodyMarkdown: "ocr", searchText: nil, metaJSON: pageMeta).searchText,
      "ocr"
    )
    XCTAssertEqual(
      documentPageTextMigration(bodyMarkdown: "body", searchText: "existing", metaJSON: pageMeta).bodyMarkdown,
      "body"
    )
    XCTAssertEqual(
      documentPageTextMigration(bodyMarkdown: "body", searchText: nil, metaJSON: "{}").bodyMarkdown,
      "body"
    )
    XCTAssertEqual(
      documentPageTextMigration(bodyMarkdown: "body", searchText: nil, metaJSON: "{").bodyMarkdown,
      "body"
    )
  }

  func testDocumentPageMetadataMustDecodeImportedPageMetadata() {
    let valid = #"{"documentPage":{"pageNumber":1,"ocrState":"complete","analysis":{"writingMode":"unknown","binding":"unknown"},"originFileId":"file-1"}}"#
    let missingOrigin = #"{"documentPage":{"pageNumber":1,"ocrState":"complete","analysis":{"writingMode":"unknown","binding":"unknown"}}}"#
    XCTAssertTrue(isDocumentPageMetaJSON(valid))
    XCTAssertFalse(isDocumentPageMetaJSON(nil))
    XCTAssertFalse(isDocumentPageMetaJSON("{}"))
    XCTAssertFalse(isDocumentPageMetaJSON("{"))
    XCTAssertFalse(isDocumentPageMetaJSON(missingOrigin))
  }

  func testSearchTextReadersAndServiceRetrievalAccessors() throws {
    let driver = try makeNoteDriver()
    let service = try NoteService(driver: driver)
    let normal = try service.createNote(bodyMarkdown: "plain body")
    let page = try service.createNotebookWithNotes(
      title: "Pages",
      pages: [NotePageDraft(
        bodyMarkdown: "",
        readOnly: false,
        metaJSON: #"{"documentPage":{"pageNumber":1,"ocrState":"complete","analysis":{"writingMode":"unknown","binding":"unknown"},"originFileId":"file-1"}}"#,
        searchText: "hidden OCR"
      )]
    ).notes[0]

    try driver.withDatabase { database in
      XCTAssertEqual(try noteSearchText(page.noteId, in: database), "hidden OCR")
      XCTAssertNil(try noteSearchText(normal.noteId, in: database))
      XCTAssertNil(try noteSearchText(NoteID("missing"), in: database))
      XCTAssertEqual(
        try noteSearchTexts([page.noteId, normal.noteId, NoteID("missing")], in: database),
        [page.noteId: "hidden OCR"]
      )
      XCTAssertEqual(try noteSearchTexts([], in: database), [:])
    }
    XCTAssertEqual(try service.retrievalText(for: page), "hidden OCR")
    XCTAssertEqual(try service.retrievalTexts(for: [page, normal]), [
      page.noteId: "hidden OCR",
      normal.noteId: "plain body"
    ])
    XCTAssertEqual(try service.retrievalTexts(for: [page, page]), [page.noteId: "hidden OCR"])
  }
}
