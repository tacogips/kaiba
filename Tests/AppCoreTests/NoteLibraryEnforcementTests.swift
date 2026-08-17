import Foundation
@testable import AppCore
import XCTest

// Library reachability below the catalog (`design-docs/specs/library.md`).
// Holding an id must not be enough: a caller that cannot see the library gets
// the same "not found" a caller with a bogus id gets, on every path that
// returns content — by id, by search, by graph, and by file.
//
// These tests are the boundary itself. A regression here is a content leak,
// not a cosmetic bug.

final class NoteLibraryEnforcementTests: NoteTestCase {
  private struct Fixture {
    var service: NoteService
    var anonymous: NoteService
    var privateNoteId: NoteID
    var privateNotebookId: NotebookID
    var publicNoteId: NoteID
    var privateLibraryId: LibraryID
  }

  private func makeFixture() throws -> Fixture {
    let service = try makeService()
    let shared = try service.createLibrary(name: "shared", authRequired: true)
    let sharedService = service.scoped(toLibrary: shared.libraryId)
    let privateNote = try sharedService.createNote(
      bodyMarkdown: "# Private\nclassified body",
      tags: [NoteTagInput(name: "secret")]
    )
    let publicNote = try service.createNote(bodyMarkdown: "# Public\nopen body")
    return Fixture(
      service: service,
      // What an `--allow-unauthenticated` note-API request looks like.
      anonymous: service.scoped(to: NoteStoreSchema.defaultUserId).unauthenticated(),
      privateNoteId: privateNote.noteId,
      privateNotebookId: privateNote.notebookId,
      publicNoteId: publicNote.noteId,
      privateLibraryId: shared.libraryId
    )
  }

  func testFetchByIdIsRefusedForAnUnreachableLibrary() throws {
    let fixture = try makeFixture()

    XCTAssertThrowsError(try fixture.anonymous.getNote(fixture.privateNoteId)) { error in
      XCTAssertEqual(error as? NoteServiceError, .notFound("note not found: \(fixture.privateNoteId)"))
    }
    XCTAssertThrowsError(try fixture.anonymous.getNotebook(fixture.privateNotebookId))
    XCTAssertThrowsError(try fixture.anonymous.listNotes(notebookId: fixture.privateNotebookId))
    // The reachable note still resolves, so this is a boundary and not an outage.
    XCTAssertEqual(try fixture.anonymous.getNote(fixture.publicNoteId).noteId, fixture.publicNoteId)
  }

  func testRefusalIsIndistinguishableFromAMissingRow() throws {
    let fixture = try makeFixture()

    var hidden: Error?
    var missing: Error?
    XCTAssertThrowsError(try fixture.anonymous.getNote(fixture.privateNoteId)) { hidden = $0 }
    XCTAssertThrowsError(try fixture.anonymous.getNote(NoteID("note-does-not-exist"))) { missing = $0 }

    // Same error case, so nothing in the answer confirms that the id exists.
    switch (hidden as? NoteServiceError, missing as? NoteServiceError) {
    case (.notFound, .notFound): break
    default: XCTFail("expected both to be notFound, got \(String(describing: hidden)) and \(String(describing: missing))")
    }
  }

  func testWritesByIdAreRefusedForAnUnreachableLibrary() throws {
    let fixture = try makeFixture()

    XCTAssertThrowsError(try fixture.anonymous.updateNoteBody(
      noteId: fixture.privateNoteId,
      bodyMarkdown: "# Overwritten"
    ))
    XCTAssertThrowsError(try fixture.anonymous.deleteNote(noteId: fixture.privateNoteId))
    XCTAssertThrowsError(try fixture.anonymous.setReadOnly(noteId: fixture.privateNoteId, readOnly: true))
    XCTAssertThrowsError(try fixture.anonymous.addComment(
      noteId: fixture.privateNoteId,
      bodyMarkdown: "leak"
    ))
    // Unchanged on disk.
    XCTAssertEqual(try fixture.service.getNote(fixture.privateNoteId).bodyMarkdown, "# Private\nclassified body")
  }

  func testRelationsAndCommentsAreRefusedForAnUnreachableLibrary() throws {
    let fixture = try makeFixture()
    _ = try fixture.service.addComment(noteId: fixture.privateNoteId, bodyMarkdown: "memo")

    XCTAssertThrowsError(try fixture.anonymous.listComments(noteId: fixture.privateNoteId))
    XCTAssertThrowsError(try fixture.anonymous.listNotebookComments(notebookId: fixture.privateNotebookId))
    XCTAssertThrowsError(try fixture.anonymous.listLinks(noteId: fixture.privateNoteId))
    XCTAssertTrue(try fixture.anonymous.searchComments(query: "memo").isEmpty)
    XCTAssertFalse(try fixture.service.searchComments(query: "memo").isEmpty)
  }

  func testSearchDoesNotReturnNotesFromAnUnreachableLibrary() throws {
    let fixture = try makeFixture()

    let anonymousHits = try fixture.anonymous.searchNotes(query: "classified")
    XCTAssertTrue(anonymousHits.isEmpty)
    // Same query, reachable caller: the note is there, so the query itself works.
    XCTAssertEqual(try fixture.service.searchNotes(query: "classified").count, 1)

    // Tag- and notebook-filtered variants take different query builders.
    XCTAssertTrue(try fixture.anonymous.searchNotes(query: "", tagFilter: ["secret"]).isEmpty)
    XCTAssertTrue(try fixture.anonymous.searchNotes(query: "→", tagFilter: ["secret"]).isEmpty)
  }

  func testCrossNotebookListingIsScopedToReachableLibraries() throws {
    let fixture = try makeFixture()

    let titles = try fixture.anonymous.listNotes().map { $0.title ?? "" }

    XCTAssertTrue(titles.contains("Public"))
    XCTAssertFalse(titles.contains("Private"))
  }

  func testGraphTraversalDoesNotCrossIntoAnUnreachableLibrary() throws {
    let fixture = try makeFixture()
    // A link from the open note into the closed one: the traversal must not
    // carry the closed note back out.
    _ = try fixture.service.linkNotes(from: fixture.publicNoteId, to: fixture.privateNoteId)

    let neighbors = try fixture.anonymous.graphNeighbors(noteIds: [fixture.publicNoteId])
    XCTAssertFalse(neighbors.map(\.note.noteId).contains(fixture.privateNoteId))
    XCTAssertTrue(try fixture.service.graphNeighbors(noteIds: [fixture.publicNoteId])
      .map(\.note.noteId).contains(fixture.privateNoteId))

    // Seeding the traversal with the hidden note is refused outright.
    XCTAssertThrowsError(try fixture.anonymous.graphNeighbors(noteIds: [fixture.privateNoteId]))

    let linked = try fixture.anonymous.searchNotes(query: "open", includeLinked: true)
    XCTAssertFalse(linked.map(\.note.noteId).contains(fixture.privateNoteId))
  }

  func testFilesOfAnUnreachableNoteAreRefused() throws {
    let fixture = try makeFixture()
    let payload = Data("classified bytes".utf8)
    let attachment = try fixture.service.storeNoteFileAttachment(
      noteId: fixture.privateNoteId,
      data: payload,
      role: .related,
      mediaType: "text/plain",
      originalFilename: "secret.txt",
      position: 0,
      requiresWritableNote: true
    )

    XCTAssertThrowsError(try fixture.anonymous.getFileRecord(fileId: attachment.file.fileId))
    XCTAssertThrowsError(try fixture.anonymous.resolveFileContent(fileId: attachment.file.fileId))
    XCTAssertThrowsError(try fixture.anonymous.listFiles(noteId: fixture.privateNoteId))
    XCTAssertEqual(try fixture.service.resolveFileContent(fileId: attachment.file.fileId), payload)
  }

  func testASelectedLibraryCannotReachAnotherOne() throws {
    let fixture = try makeFixture()
    let scoped = fixture.service.scoped(toLibrary: fixture.privateLibraryId)

    // Authenticated, but acting in one library: the other one is out of reach
    // for it too, so a selection is a real scope and not just a filter.
    XCTAssertThrowsError(try scoped.getNote(fixture.publicNoteId))
    XCTAssertEqual(try scoped.getNote(fixture.privateNoteId).noteId, fixture.privateNoteId)
    XCTAssertTrue(try scoped.searchNotes(query: "open").isEmpty)
  }

  func testAuthenticatedCallerReachesTheLibraryOnlyOnceGranted() throws {
    let fixture = try makeFixture()
    let user = try fixture.service.createUser(email: "alice@example.com", displayName: "Alice")
    let alice = fixture.service.scoped(to: user.userId)

    // Authentication is not reach: the account has to be granted the library
    // (`design-docs/specs/library.md`).
    XCTAssertThrowsError(try alice.getNote(fixture.privateNoteId))
    XCTAssertTrue(try alice.searchNotes(query: "classified").isEmpty)

    try fixture.service.grantLibraryAccess(libraryName: "shared", userId: user.userId)

    XCTAssertEqual(try alice.getNote(fixture.privateNoteId).noteId, fixture.privateNoteId)
    XCTAssertEqual(try alice.searchNotes(query: "classified").count, 1)
  }
}
