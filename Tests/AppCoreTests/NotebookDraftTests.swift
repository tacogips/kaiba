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

extension NotebookDraftTests {
  func testMiddleInsertAndDeletePreserveFollowingNoteTagsCommentsAndSearchIdentity() throws {
    let service = try makeService()
    let book = try service.createNotebookWithNotes(title: "Notebook", pages: ["A", "B", "C unchanged marker"].map { NotePageDraft(bodyMarkdown: $0, readOnly: false) })
    let first = try XCTUnwrap(book.notes.first)
    let second = book.notes[1]
    let third = book.notes[2]
    _ = try service.applyTags(noteId: third.noteId, tags: [NoteTagInput(name: "retained-topic")], provenance: .human)
    let memo = try service.addComment(noteId: third.noteId, bodyMarkdown: "Retained page memo")
    let bodies = ["Edited A", "New inserted section", "B", "C unchanged marker"]
    _ = try service.saveNotebookDraft(notebookId: book.notebook.notebookId, title: "Notebook", bodies: bodies)
    let saved = try service.listNotes(notebookId: book.notebook.notebookId)
    XCTAssertEqual(saved.map(\.noteNumber), [1, 2, 3, 4])
    XCTAssertEqual(saved[0].noteId, first.noteId)
    XCTAssertEqual(saved[2].noteId, second.noteId)
    XCTAssertEqual(saved[3].noteId, third.noteId)
    XCTAssertFalse(book.notes.map(\.noteId).contains(saved[1].noteId))
    XCTAssertEqual(saved[3].tags.map(\.tag.name), ["retained-topic"])
    XCTAssertEqual(try service.listComments(noteId: third.noteId).map(\.commentId), [memo.commentId])
    _ = try service.saveNotebookDraft(notebookId: book.notebook.notebookId, title: "Notebook", bodies: bodies)
    XCTAssertEqual(try service.listNotes(notebookId: book.notebook.notebookId).map(\.noteId), saved.map(\.noteId))
    _ = try service.saveNotebookDraft(notebookId: book.notebook.notebookId, title: "Notebook", bodies: ["Edited A", "C unchanged marker"])
    let reduced = try service.listNotes(notebookId: book.notebook.notebookId)
    XCTAssertEqual(reduced.map(\.noteId), [first.noteId, third.noteId])
    XCTAssertEqual(reduced.map(\.noteNumber), [1, 2])
    XCTAssertEqual(reduced[1].tags.map(\.tag.name), ["retained-topic"])
    XCTAssertEqual(try service.listComments(noteId: third.noteId).map(\.commentId), [memo.commentId])
    XCTAssertEqual(try service.searchNotes(query: "unchanged marker").first?.note.noteId, third.noteId)
  }

  func testReorderingSectionsPreservesTheirOriginalIdentities() throws {
    let service = try makeService()
    let book = try service.createNotebookWithNotes(title: "Notebook", pages: ["A", "B", "C"].map { NotePageDraft(bodyMarkdown: $0, readOnly: false) })
    _ = try service.saveNotebookDraft(notebookId: book.notebook.notebookId, title: "Notebook", bodies: ["C", "A", "B"])
    let saved = try service.listNotes(notebookId: book.notebook.notebookId)
    XCTAssertEqual(saved.map(\.noteId), [book.notes[2].noteId, book.notes[0].noteId, book.notes[1].noteId])
    XCTAssertEqual(saved.map(\.noteNumber), [1, 2, 3])
  }

  func testMoreThanOneThousandSectionsSaveAndReplayWithoutChangingIDs() throws {
    let service = try makeService()
    let book = try service.createNotebookWithNotes(title: "Large", pages: [NotePageDraft(bodyMarkdown: "Page 1", readOnly: false)])
    let bodies = (1...1001).map { "Page \($0)" }
    _ = try service.saveNotebookDraft(notebookId: book.notebook.notebookId, title: "Large", bodies: bodies)
    let saved = try service.listNotes(notebookId: book.notebook.notebookId, limit: 2000)
    XCTAssertEqual(saved.count, 1001)
    XCTAssertEqual(saved.first?.noteId, book.notes.first?.noteId)
    XCTAssertEqual(saved.last?.noteNumber, 1001)
    _ = try service.saveNotebookDraft(notebookId: book.notebook.notebookId, title: "Large", bodies: bodies)
    XCTAssertEqual(try service.listNotes(notebookId: book.notebook.notebookId, limit: 2000).map(\.noteId), saved.map(\.noteId))
    XCTAssertThrowsError(try service.saveNotebookDraft(notebookId: book.notebook.notebookId, title: "Large", bodies: Array(repeating: "x", count: NoteService.maximumDraftNoteCount + 1)))
    XCTAssertEqual(try service.listNotes(notebookId: book.notebook.notebookId, limit: 2000).count, 1001)
  }
}
