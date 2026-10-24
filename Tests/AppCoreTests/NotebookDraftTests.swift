import XCTest
@testable import AppCore

final class NotebookDraftTests: NoteTestCase {
  func testAtomicDraftUpdatesKeepIDsAndReplayWithoutDuplicateNotes() throws {
    let service = try makeService()
    let book = try service.createNotebookWithNotes(title: "F", pages: [NotePageDraft(bodyMarkdown: "F", readOnly: false)])
    let id = book.notebook.notebookId
    _ = try service.saveNotebookDraft(notebookId: id, title: "Field notebook", bodies: ["Field notebook", "Second", ""])
    let firstSave = try service.listNotes(notebookId: id)
    XCTAssertEqual(firstSave.map(\.bodyMarkdown), ["Field notebook", "Second", ""])
    XCTAssertEqual(firstSave.first?.noteId, book.notes.first?.noteId)
    _ = try service.saveNotebookDraft(notebookId: id, title: "Field notebook", bodies: ["Field notebook", "Second", ""])
    XCTAssertEqual(try service.listNotes(notebookId: id).map(\.noteId), firstSave.map(\.noteId))
    _ = try service.saveNotebookDraft(notebookId: id, title: "Renamed", bodies: ["Renamed\nMergedUniqueMarker"])
    XCTAssertEqual(try service.listNotes(notebookId: id).count, 1)
    XCTAssertEqual(try service.getNotebook(id).title, "Renamed")
    XCTAssertEqual(try service.searchNotes(query: "MergedUniqueMarker").first?.note.noteId, book.notes.first?.noteId)
  }

  func testDraftRejectsReadOnlyAndForeignNotebookWithoutPartialWrites() throws {
    let service = try makeService()
    let book = try service.createNotebookWithNotes(title: "Original", pages: [NotePageDraft(bodyMarkdown: "First", readOnly: false), NotePageDraft(bodyMarkdown: "Locked", readOnly: true)])
    XCTAssertThrowsError(try service.saveNotebookDraft(notebookId: book.notebook.notebookId, title: "Changed", bodies: ["Overwrite"]))
    XCTAssertEqual(try service.listNotes(notebookId: book.notebook.notebookId).first?.bodyMarkdown, "First")
    let other = try service.createUser(email: "other-draft@example.com", displayName: "Other")
    XCTAssertThrowsError(try service.scoped(to: other.userId).saveNotebookDraft(notebookId: book.notebook.notebookId, title: "Changed", bodies: ["Overwrite"]))
    XCTAssertEqual(try service.getNotebook(book.notebook.notebookId).title, "Original")
  }
}
