import Foundation
@testable import AppCore
import XCTest

// Per-account authorization for a library (`design-docs/specs/library.md`).
// `auth_required` decides whether a caller with no credential gets in;
// `library_members` decides which accounts do. Both halves are enforced on
// every path that returns content, not just on the catalog.

final class NoteLibraryMemberTests: NoteTestCase {
  private struct Fixture {
    var service: NoteService
    var alice: NoteUser
    var bob: NoteUser
    var closedLibraryId: LibraryID
    var closedNoteId: NoteID
    var openNoteId: NoteID
  }

  private func makeFixture() throws -> Fixture {
    let service = try makeService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let bob = try service.createUser(email: "bob@example.com", displayName: "Bob")
    let closed = try service.createLibrary(name: "closed", authRequired: true)
    let closedNote = try service.scoped(toLibrary: closed.libraryId)
      .createNote(bodyMarkdown: "# Closed\nmember-only body")
    let openNote = try service.createNote(bodyMarkdown: "# Open\nopen body")
    try service.grantLibraryAccess(libraryName: "closed", userId: alice.userId)
    return Fixture(
      service: service,
      alice: alice,
      bob: bob,
      closedLibraryId: closed.libraryId,
      closedNoteId: closedNote.noteId,
      openNoteId: openNote.noteId
    )
  }

  func testAMemberReachesTheLibraryAndANonMemberDoesNot() throws {
    let fixture = try makeFixture()
    let alice = fixture.service.scoped(to: fixture.alice.userId)
    let bob = fixture.service.scoped(to: fixture.bob.userId)

    XCTAssertEqual(try alice.listLibraries().map(\.name).sorted(), ["closed", "default"])
    XCTAssertEqual(try bob.listLibraries().map(\.name), ["default"])
  }

  func testANonMemberCannotFetchByIdSearchOrTraverse() throws {
    let fixture = try makeFixture()
    let bob = fixture.service.scoped(to: fixture.bob.userId)

    XCTAssertThrowsError(try bob.getNote(fixture.closedNoteId))
    XCTAssertTrue(try bob.searchNotes(query: "member-only").isEmpty)
    XCTAssertFalse(try bob.listNotes().compactMap(\.title).contains("Closed"))

    // A link out of the open library must not carry the closed note back.
    _ = try fixture.service.linkNotes(from: fixture.openNoteId, to: fixture.closedNoteId)
    let neighbors = try bob.graphNeighbors(noteIds: [fixture.openNoteId])
    XCTAssertFalse(neighbors.map(\.note.noteId).contains(fixture.closedNoteId))
  }

  func testAMemberReadsWhatANonMemberCannot() throws {
    let fixture = try makeFixture()
    let alice = fixture.service.scoped(to: fixture.alice.userId)

    XCTAssertEqual(try alice.getNote(fixture.closedNoteId).noteId, fixture.closedNoteId)
    XCTAssertEqual(try alice.searchNotes(query: "member-only").count, 1)
  }

  func testRevokingAccessClosesEveryPathAgain() throws {
    let fixture = try makeFixture()
    let alice = fixture.service.scoped(to: fixture.alice.userId)
    XCTAssertEqual(try alice.getNote(fixture.closedNoteId).noteId, fixture.closedNoteId)

    try fixture.service.revokeLibraryAccess(libraryName: "closed", userId: fixture.alice.userId)

    XCTAssertThrowsError(try alice.getNote(fixture.closedNoteId))
    XCTAssertTrue(try alice.searchNotes(query: "member-only").isEmpty)
    XCTAssertEqual(try alice.listLibraries().map(\.name), ["default"])
    // The notebooks stay put: revoking access hides work, it does not delete it.
    XCTAssertEqual(try fixture.service.getNote(fixture.closedNoteId).noteId, fixture.closedNoteId)
  }

  func testTheCreatorOfALibraryIsItsOwner() throws {
    let service = try makeService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let scoped = service.scoped(to: alice.userId)

    let library = try scoped.createLibrary(name: "aliceonly", authRequired: true)

    // Otherwise an authenticated caller would lock itself out of what it made.
    XCTAssertEqual(try scoped.getNotebook(
      try scoped.scoped(toLibrary: library.libraryId).createNotebook(title: "Mine").notebookId
    ).title, "Mine")
    let members = try service.listLibraryMembers(libraryName: "aliceonly")
    XCTAssertEqual(members.map(\.userId), [alice.userId])
    XCTAssertEqual(members.first?.role, .owner)
  }

  func testAnOpenLibraryNeedsNoGrant() throws {
    let service = try makeService()
    let bob = try service.createUser(email: "bob@example.com", displayName: "Bob")
    let open = try service.createLibrary(name: "open", authRequired: false)
    let note = try service.scoped(toLibrary: open.libraryId).createNote(bodyMarkdown: "# Open\nbody")

    let scoped = service.scoped(to: bob.userId)

    XCTAssertEqual(try scoped.getNote(note.noteId).noteId, note.noteId)
    XCTAssertTrue(try scoped.listLibraries().map(\.name).contains("open"))
  }

  func testClosingAnOpenLibraryImmediatelyExcludesNonMembers() throws {
    let service = try makeService()
    let bob = try service.createUser(email: "bob@example.com", displayName: "Bob")
    let open = try service.createLibrary(name: "open", authRequired: false)
    let note = try service.scoped(toLibrary: open.libraryId).createNote(bodyMarkdown: "# Open\nbody")
    let scoped = service.scoped(to: bob.userId)
    XCTAssertEqual(try scoped.getNote(note.noteId).noteId, note.noteId)

    try service.updateLibrary(name: "open", authRequired: true)

    XCTAssertThrowsError(try scoped.getNote(note.noteId))
  }

  func testGrantIsIdempotentAndPromotesRole() throws {
    let fixture = try makeFixture()

    try fixture.service.grantLibraryAccess(
      libraryName: "closed",
      userId: fixture.alice.userId,
      role: .owner
    )

    let members = try fixture.service.listLibraryMembers(libraryName: "closed")
    XCTAssertEqual(members.filter { $0.userId == fixture.alice.userId }.count, 1)
    XCTAssertEqual(members.first { $0.userId == fixture.alice.userId }?.role, .owner)
  }

  func testGrantAndRevokeRejectUnknownSubjects() throws {
    let fixture = try makeFixture()

    XCTAssertThrowsError(try fixture.service.grantLibraryAccess(
      libraryName: "closed",
      userId: UserID("user-missing")
    ))
    XCTAssertThrowsError(try fixture.service.grantLibraryAccess(
      libraryName: "missing",
      userId: fixture.alice.userId
    ))
    XCTAssertThrowsError(try fixture.service.revokeLibraryAccess(
      libraryName: "closed",
      userId: fixture.bob.userId
    ))
  }

  func testANonMemberCannotReadTheRoster() throws {
    let fixture = try makeFixture()
    let bob = fixture.service.scoped(to: fixture.bob.userId)

    // Who can reach a library is as private as the library itself.
    XCTAssertThrowsError(try bob.listLibraryMembers(libraryName: "closed"))
    XCTAssertNoThrow(try fixture.service.scoped(to: fixture.alice.userId)
      .listLibraryMembers(libraryName: "closed"))
  }

  func testUnauthenticatedCallerIsUnaffectedByMembership() throws {
    let fixture = try makeFixture()
    // Membership grants an *account* access; a caller with no credential has
    // no account, so an auth-required library stays closed to it either way.
    let anonymous = fixture.service.scoped(to: fixture.alice.userId).unauthenticated()

    XCTAssertThrowsError(try anonymous.getNote(fixture.closedNoteId))
    XCTAssertEqual(try anonymous.listLibraries().map(\.name), ["default"])
  }

  func testLibrariesForUserReportsOneAccountsReach() throws {
    let fixture = try makeFixture()

    XCTAssertEqual(
      try fixture.service.libraries(forUser: fixture.alice.userId).map(\.name).sorted(),
      ["closed", "default"]
    )
    XCTAssertEqual(
      try fixture.service.libraries(forUser: fixture.bob.userId).map(\.name),
      ["default"]
    )
  }
}
