import Foundation
@testable import AppCore
import XCTest

final class NotebookTitleTests: NoteTestCase {
  func testImportedPDFDefaultsToFilenameAndCanBeRenamedWithoutChangingItsPages() throws {
    let service = try makeService()
    let source = try XCTUnwrap(Bundle.module.resourceURL).appendingPathComponent("Fixtures/sample.pdf")
    let imported = try service.importDocumentPages(
      at: source.path, processor: DocumentPageProcessor(recognizer: VisionDocumentPageRecognizer()), maximumOCRPages: 0
    )
    XCTAssertEqual(imported.notebook.title, "sample.pdf")
    let before = try service.listNotes(notebookId: imported.notebook.notebookId)
    let renamed = try service.renameNotebook(notebookId: imported.notebook.notebookId, title: "  Study material  ")
    XCTAssertEqual(renamed.title, "Study material")
    XCTAssertTrue(renamed.readOnly)
    XCTAssertEqual(try service.listNotes(notebookId: renamed.notebookId), before)
    XCTAssertTrue(try service.checkStore().isHealthy)
    XCTAssertTrue(try service.searchNotes(query: "Study material").contains { $0.note.notebookId == renamed.notebookId })
    _ = try service.undoLastAction()
    XCTAssertEqual(try service.getNotebook(renamed.notebookId).title, "sample.pdf")
    _ = try service.redoLastAction()
    XCTAssertEqual(try service.getNotebook(renamed.notebookId).title, "Study material")
    XCTAssertTrue(try service.checkStore().isHealthy)
    XCTAssertEqual(try service.resolveFileContent(fileId: imported.sourceFile.file.fileId), try Data(contentsOf: source))
  }

  func testRenameRejectsEmptyTitleAndAnotherAccountsNotebook() throws {
    let service = try makeService()
    let notebook = try service.createNotebook(title: "Original")
    XCTAssertThrowsError(try service.renameNotebook(notebookId: notebook.notebookId, title: " \n "))
    let other = try service.createUser(email: "other@example.com", displayName: "Other")
    XCTAssertThrowsError(try service.scoped(to: other.userId).renameNotebook(notebookId: notebook.notebookId, title: "Changed"))
    XCTAssertEqual(try service.getNotebook(notebook.notebookId).title, "Original")
  }
}
