import Foundation
@testable import AppCore
import XCTest

final class NoteServicePromoteCommentTests: NoteTestCase {
  func testPromoteCommentCreatesLinkedNotebookInOneTransaction() throws {
    let service = try makeService()
    let note = try service.createNote(bodyMarkdown: "# Source\n\nOriginal body")
    let comment = try service.addComment(
      noteId: note.noteId,
      bodyMarkdown: "# Follow up\n\nPromote me into a notebook.",
      author: "note-agent"
    )

    let promoted = try service.promoteCommentToNotebook(noteId: note.noteId, commentId: comment.commentId)

    // Notebook + first note carry the comment body.
    XCTAssertEqual(promoted.notebook.title, "Follow up")
    XCTAssertEqual(promoted.note.bodyMarkdown, "# Follow up\n\nPromote me into a notebook.")
    let notebookNotes = try service.listNotes(notebookId: promoted.notebook.notebookId)
    XCTAssertEqual(notebookNotes.map(\.noteId), [promoted.note.noteId])

    // Source note is linked to the new note (related / human).
    let links = try service.listLinks(noteId: note.noteId)
    XCTAssertEqual(links.count, 1)
    XCTAssertEqual(links.first?.fromNoteId, note.noteId)
    XCTAssertEqual(links.first?.toNoteId, promoted.note.noteId)
    XCTAssertEqual(links.first?.linkKind, "related")
    XCTAssertEqual(links.first?.provenance, .human)
  }

  func testPromoteCommentUsesExplicitTitleWhenProvided() throws {
    let service = try makeService()
    let note = try service.createNote(bodyMarkdown: "# Source\n\nBody")
    let comment = try service.addComment(noteId: note.noteId, bodyMarkdown: "# Derived\n\nBody")

    let promoted = try service.promoteCommentToNotebook(
      noteId: note.noteId,
      commentId: comment.commentId,
      notebookTitle: "Explicit Title"
    )

    XCTAssertEqual(promoted.notebook.title, "Explicit Title")
  }

  func testPromoteCommentDerivesTitleFromCommentBody() throws {
    let service = try makeService()
    let note = try service.createNote(bodyMarkdown: "# Source\n\nBody")
    let comment = try service.addComment(noteId: note.noteId, bodyMarkdown: "Plain first line becomes title")

    let promoted = try service.promoteCommentToNotebook(noteId: note.noteId, commentId: comment.commentId)

    XCTAssertEqual(promoted.notebook.title, "Plain first line becomes title")
  }

  func testPromoteCommentFallsBackToDefaultTitle() throws {
    let service = try makeService()
    let note = try service.createNote(bodyMarkdown: "# Source\n\nBody")
    let comment = try service.addComment(noteId: note.noteId, bodyMarkdown: "   \n\t  ")

    let promoted = try service.promoteCommentToNotebook(noteId: note.noteId, commentId: comment.commentId)

    XCTAssertEqual(promoted.notebook.title, "Comment notebook")
  }

  func testPromoteCommentRecordsRequestedProvenanceAndLinkKind() throws {
    let service = try makeService()
    let note = try service.createNote(bodyMarkdown: "# Source\n\nBody")
    let comment = try service.addComment(noteId: note.noteId, bodyMarkdown: "# Note\n\nBody")

    let promoted = try service.promoteCommentToNotebook(
      noteId: note.noteId,
      commentId: comment.commentId,
      linkKind: "source-citation",
      provenance: .ai
    )

    let links = try service.listLinks(noteId: note.noteId)
    XCTAssertEqual(links.first?.toNoteId, promoted.note.noteId)
    XCTAssertEqual(links.first?.linkKind, "source-citation")
    XCTAssertEqual(links.first?.provenance, .ai)
  }

  func testPromoteCommentFromDifferentNoteRejectedAndPersistsNothing() throws {
    let service = try makeService()
    let noteA = try service.createNote(bodyMarkdown: "# A\n\nBody A")
    let noteB = try service.createNote(bodyMarkdown: "# B\n\nBody B")
    let commentOnB = try service.addComment(noteId: noteB.noteId, bodyMarkdown: "# Comment\n\nOn B")

    let notebooksBefore = try service.listNotebooks().count

    // Wrong-note comment id is rejected before any insert; a single transaction guarantees
    // the notebook + first note + link never persist without each other (SR-001).
    XCTAssertThrowsError(try service.promoteCommentToNotebook(
      noteId: noteA.noteId,
      commentId: commentOnB.commentId
    )) { error in
      guard case NoteServiceError.invalidInput = error else {
        return XCTFail("Expected invalidInput, got \(error)")
      }
    }

    XCTAssertEqual(try service.listNotebooks().count, notebooksBefore)
    XCTAssertTrue(try service.listLinks(noteId: noteA.noteId).isEmpty)
  }

  func testPromoteCommentTitleHelperCapsAndFallsBack() {
    XCTAssertEqual(
      promoteCommentNotebookTitle(explicit: "  Explicit  ", commentBody: "# Ignored"),
      "Explicit"
    )
    XCTAssertEqual(
      promoteCommentNotebookTitle(explicit: nil, commentBody: "# Derived Heading"),
      "Derived Heading"
    )
    XCTAssertEqual(
      promoteCommentNotebookTitle(explicit: "   ", commentBody: "    "),
      "Comment notebook"
    )
    XCTAssertEqual(
      promoteCommentNotebookTitle(explicit: String(repeating: "x", count: 200), commentBody: "body").count,
      120
    )
  }
}
