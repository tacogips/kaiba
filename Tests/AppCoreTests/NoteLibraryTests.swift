import Foundation
@testable import AppCore
import XCTest

// Library behavior (`design-docs/specs/library.md`): a store is created with
// one default library that requires no authentication, every notebook belongs
// to exactly one library, and a caller that presented no credential reaches
// only the libraries that do not require authentication.

final class NoteLibraryTests: NoteTestCase {
  func testFreshStoreSeedsExactlyOneOpenDefaultLibrary() throws {
    let service = try makeService()

    let libraries = try service.listLibraries()
    XCTAssertEqual(libraries.count, 1)
    let defaultLibrary = try service.defaultLibrary()
    XCTAssertEqual(defaultLibrary.libraryId, NoteStoreSchema.defaultLibraryId)
    XCTAssertEqual(defaultLibrary.name, NoteStoreSchema.defaultLibraryName)
    XCTAssertTrue(defaultLibrary.isDefault)
    // Seeded open, so a store keeps answering exactly as it did before
    // libraries existed until an operator marks something.
    XCTAssertFalse(defaultLibrary.authRequired)
  }

  func testPreparingAnExistingStoreKeepsOneDefaultLibrary() throws {
    let driver = try makeNoteDriver()
    try NoteStoreSchema.prepare(on: driver)
    try NoteStoreSchema.prepare(on: driver)

    try driver.withDatabase { database in
      let defaults = try database.query("SELECT library_id FROM libraries WHERE is_default = 1")
      XCTAssertEqual(
        defaults.compactMap { $0.identifier("library_id", as: LibraryID.self) },
        [NoteStoreSchema.defaultLibraryId]
      )
    }
  }

  func testNotebooksLandInTheDefaultLibraryWithoutASelection() throws {
    let service = try makeService()

    let notebook = try service.createNotebook(title: "Unselected")

    XCTAssertEqual(
      try libraryId(of: notebook.notebookId, service: service),
      NoteStoreSchema.defaultLibraryId
    )
  }

  func testSelectedLibraryTakesWritesAndFiltersReads() throws {
    let service = try makeService()
    let shared = try service.createLibrary(name: "Shared", title: "Shared", authRequired: true)

    let sharedService = service.scoped(toLibrary: shared.libraryId)
    let inShared = try sharedService.createNotebook(title: "In shared")
    _ = try service.createNotebook(title: "In default")

    XCTAssertEqual(try libraryId(of: inShared.notebookId, service: service), shared.libraryId)
    XCTAssertEqual(try sharedService.listNotebooks().map(\.title), ["In shared"])
    // The unscoped operator value spans every library.
    XCTAssertTrue(try service.listNotebooks().map(\.title).contains("In default"))
    XCTAssertTrue(try service.listNotebooks().map(\.title).contains("In shared"))
  }

  func testNameIsNormalizedAndUnique() throws {
    let service = try makeService()

    let created = try service.createLibrary(name: "  Shared  ")
    XCTAssertEqual(created.name, "shared")
    XCTAssertNotNil(try service.library(name: "SHARED"))
    XCTAssertThrowsError(try service.createLibrary(name: "shared"))
    XCTAssertThrowsError(try service.createLibrary(name: "bad name"))
    XCTAssertThrowsError(try service.createLibrary(name: "  "))
  }

  func testCreateDefaultsToRequiringAuthentication() throws {
    let service = try makeService()

    let library = try service.createLibrary(name: "shared")

    XCTAssertTrue(library.authRequired)
  }

  func testUnauthenticatedCallerSeesOnlyOpenLibrariesAndTheirNotebooks() throws {
    let service = try makeService()
    let shared = try service.createLibrary(name: "shared", authRequired: true)
    let open = try service.createLibrary(name: "open", authRequired: false)
    _ = try service.scoped(toLibrary: shared.libraryId).createNotebook(title: "Private")
    _ = try service.scoped(toLibrary: open.libraryId).createNotebook(title: "Public")

    // An `--allow-unauthenticated` note-API request: it still acts as the
    // default user, so only the explicit marker separates it from a sign-in.
    let anonymous = service.scoped(to: NoteStoreSchema.defaultUserId).unauthenticated()

    XCTAssertEqual(try anonymous.listLibraries().map(\.name).sorted(), ["default", "open"])
    let titles = try anonymous.listNotebooks().map(\.title)
    XCTAssertTrue(titles.contains("Public"))
    XCTAssertFalse(titles.contains("Private"))
  }

  /// Authentication alone is not reach: an account sees the open libraries and
  /// the ones it was granted (`NoteLibraryMemberTests` covers the grant side).
  func testAuthenticatedCallerSeesOpenLibrariesUntilGranted() throws {
    let service = try makeService()
    _ = try service.createLibrary(name: "shared", authRequired: true)
    let user = try service.createUser(email: "alice@example.com", displayName: "Alice")

    let scoped = service.scoped(to: user.userId)
    XCTAssertEqual(try scoped.listLibraries().map(\.name), ["default"])

    try service.grantLibraryAccess(libraryName: "shared", userId: user.userId)

    XCTAssertEqual(try scoped.listLibraries().map(\.name).sorted(), ["default", "shared"])
  }

  func testUpdateChangesTitleAndAuthRequirement() throws {
    let service = try makeService()
    _ = try service.createLibrary(name: "shared", title: "Old", authRequired: true)

    let updated = try service.updateLibrary(name: "shared", title: "New", authRequired: false)

    XCTAssertEqual(updated.title, "New")
    XCTAssertFalse(updated.authRequired)
    XCTAssertThrowsError(try service.updateLibrary(name: "shared", title: "   "))
  }

  func testDeleteRefusesNonEmptyAndDefaultLibraries() throws {
    let service = try makeService()
    let shared = try service.createLibrary(name: "shared")
    _ = try service.scoped(toLibrary: shared.libraryId).createNotebook(title: "Held")

    XCTAssertThrowsError(try service.deleteLibrary(name: "shared"))
    XCTAssertThrowsError(try service.deleteLibrary(name: NoteStoreSchema.defaultLibraryName))
    XCTAssertNotNil(try service.library(name: "shared"))
  }

  func testDeleteRemovesAnEmptyLibrary() throws {
    let service = try makeService()
    _ = try service.createLibrary(name: "shared")

    try service.deleteLibrary(name: "shared")

    XCTAssertNil(try service.library(name: "shared"))
  }

  func testMoveReParentsANotebookAndKeepsItsNotes() throws {
    let service = try makeService()
    let shared = try service.createLibrary(name: "shared")
    let created = try service.createNote(
      bodyMarkdown: "# Moved\nbody",
      tags: [NoteTagInput(name: "idea")]
    )

    let library = try service.moveNotebook(created.notebookId, toLibrary: "shared")

    XCTAssertEqual(library.libraryId, shared.libraryId)
    XCTAssertEqual(try libraryId(of: created.notebookId, service: service), shared.libraryId)
    let notes = try service.listNotes(notebookId: created.notebookId)
    XCTAssertEqual(notes.count, 1)
    XCTAssertEqual(notes.first?.tags.count, 1)
    let moved = try service.listNotebooks().first { $0.notebookId == created.notebookId }
    XCTAssertEqual(moved?.libraryId, shared.libraryId)
  }

  func testMoveRejectsAnUnknownLibraryOrNotebook() throws {
    let service = try makeService()
    let created = try service.createNote(bodyMarkdown: "# Note")

    XCTAssertThrowsError(try service.moveNotebook(created.notebookId, toLibrary: "missing"))
    XCTAssertThrowsError(try service.moveNotebook(NotebookID("notebook-missing"), toLibrary: "default"))
  }

  func testDeletingALibraryLeavesTheDefaultLibraryIntact() throws {
    let service = try makeService()
    let shared = try service.createLibrary(name: "shared")
    _ = try service.scoped(toLibrary: shared.libraryId).createNotebook(title: "Held")

    try service.moveNotebook(
      try XCTUnwrap(try service.listNotebooks().first { $0.title == "Held" }).notebookId,
      toLibrary: NoteStoreSchema.defaultLibraryName
    )
    try service.deleteLibrary(name: "shared")

    XCTAssertEqual(try service.listLibraries().map(\.name), ["default"])
  }

  private func libraryId(of notebookId: NotebookID, service: NoteService) throws -> LibraryID? {
    try service.driver.withDatabase { database in
      try database.query(
        "SELECT library_id FROM notebooks WHERE notebook_id = ?",
        bindings: [.id(notebookId)]
      ).first?.identifier("library_id", as: LibraryID.self)
    }
  }
}
