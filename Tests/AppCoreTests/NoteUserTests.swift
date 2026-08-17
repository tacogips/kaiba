import Foundation
@testable import AppCore
import XCTest

// Multi-user store behavior (`design-docs/specs/multi-user.md`): a store is
// created with exactly one default user, every notebook has a real owner, and a
// service scoped to a user sees only that user's catalog.

final class NoteUserTests: NoteTestCase {
  func testFreshStoreSeedsExactlyOneDefaultUser() throws {
    let service = try makeService()

    let users = try service.listUsers()
    XCTAssertEqual(users.count, 1)
    let defaultUser = try service.defaultUser()
    XCTAssertEqual(defaultUser.userId, NoteStoreSchema.defaultUserId)
    XCTAssertTrue(defaultUser.isDefault)
    XCTAssertTrue(defaultUser.isEnabled)
    XCTAssertNil(defaultUser.email)
  }

  func testPreparingAnExistingStoreKeepsOneDefaultUser() throws {
    let driver = try makeNoteDriver()
    try NoteStoreSchema.prepare(on: driver)
    try NoteStoreSchema.prepare(on: driver)

    try driver.withDatabase { database in
      let defaults = try database.query("SELECT user_id FROM users WHERE is_default = 1")
      XCTAssertEqual(defaults.compactMap { $0.identifier("user_id", as: UserID.self) }, [NoteStoreSchema.defaultUserId])
    }
  }

  func testUnscopedWritesBelongToTheDefaultUser() throws {
    let service = try makeService()

    let notebook = try service.createNotebook(title: "Unscoped")

    XCTAssertEqual(try ownerUserId(of: notebook.notebookId, service: service), NoteStoreSchema.defaultUserId)
  }

  func testScopedServiceOwnsItsWritesAndSeesOnlyItsOwnNotebooks() throws {
    let service = try makeService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let bob = try service.createUser(email: "bob@example.com", displayName: "Bob")

    let aliceService = service.scoped(to: alice.userId)
    let bobService = service.scoped(to: bob.userId)
    let aliceNotebook = try aliceService.createNotebook(title: "Alice notebook")
    _ = try bobService.createNotebook(title: "Bob notebook")

    XCTAssertEqual(try ownerUserId(of: aliceNotebook.notebookId, service: service), alice.userId)
    XCTAssertEqual(try aliceService.listNotebooks().map(\.title), ["Alice notebook"])
    XCTAssertEqual(try bobService.listNotebooks().map(\.title), ["Bob notebook"])
    // The unscoped value is the operator view: the whole store, including the
    // long-term memory notebook seeded for the default user.
    let allTitles = try service.listNotebooks(limit: 100).map(\.title)
    XCTAssertTrue(allTitles.contains("Alice notebook"))
    XCTAssertTrue(allTitles.contains("Bob notebook"))
  }

  func testDefaultUserScopeExcludesOtherUsersNotebooks() throws {
    let service = try makeService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
    _ = try service.scoped(to: alice.userId).createNotebook(title: "Alice notebook")
    _ = try service.createNotebook(title: "Default notebook")

    let defaultTitles = try service.scoped(to: NoteStoreSchema.defaultUserId).listNotebooks(limit: 100).map(\.title)
    XCTAssertTrue(defaultTitles.contains("Default notebook"))
    XCTAssertFalse(defaultTitles.contains("Alice notebook"))
  }

  func testEmailIsNormalizedAndUnique() throws {
    let service = try makeService()

    let user = try service.createUser(email: "  Alice@Example.com ", displayName: "Alice")
    XCTAssertEqual(user.email, "alice@example.com")
    XCTAssertEqual(try service.user(email: "ALICE@EXAMPLE.COM")?.userId, user.userId)
    XCTAssertThrowsError(try service.createUser(email: "alice@example.com", displayName: "Alice again"))
    XCTAssertThrowsError(try service.createUser(email: "not-an-address", displayName: "Nobody"))
  }

  func testDisablingHidesAUserButNeverTheDefault() throws {
    let service = try makeService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")

    _ = try service.setUserDisabled(userId: alice.userId, disabled: true)
    XCTAssertFalse(try service.listUsers().contains { $0.userId == alice.userId })
    XCTAssertTrue(try service.listUsers(includeDisabled: true).contains { $0.userId == alice.userId })
    XCTAssertThrowsError(
      try service.setUserDisabled(userId: NoteStoreSchema.defaultUserId, disabled: true)
    )
  }

  func testAPIClientsBelongToAUserAndAuthenticateAsThatUser() throws {
    let service = try makeService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")

    let defaultClient = try service.registerAPIClient(displayName: "CLI", bearerToken: "token-default")
    let aliceClient = try service.registerAPIClient(
      displayName: "Alice web",
      bearerToken: "token-alice",
      userId: alice.userId
    )

    XCTAssertEqual(defaultClient.userId, NoteStoreSchema.defaultUserId)
    XCTAssertEqual(aliceClient.userId, alice.userId)
    XCTAssertEqual(try service.authenticateAPIClient(bearerToken: "token-alice")?.userId, alice.userId)

    _ = try service.setUserDisabled(userId: alice.userId, disabled: true)
    XCTAssertThrowsError(
      try service.registerAPIClient(
        displayName: "Alice again",
        bearerToken: "token-alice-2",
        userId: alice.userId
      )
    )
  }

  func testAPIClientsCannotBelongToAnUnknownUser() throws {
    let service = try makeService()

    XCTAssertThrowsError(
      try service.registerAPIClient(
        displayName: "Ghost",
        bearerToken: "token-ghost",
        userId: UserID("user-does-not-exist")
      )
    )
  }

  func testWritesRecordCreatedByAndUpdatedBy() throws {
    let service = try makeService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let aliceService = service.scoped(to: alice.userId)

    let notebook = try aliceService.createNotebook(title: "Alice notebook")
    let note = try aliceService.createNote(
      notebookId: notebook.notebookId,
      bodyMarkdown: "first body"
    )

    XCTAssertEqual(try attribution(notebook: notebook.notebookId, service: service).createdBy, alice.userId)
    XCTAssertEqual(try attribution(note: note.noteId, service: service).createdBy, alice.userId)
    XCTAssertEqual(try attribution(note: note.noteId, service: service).updatedBy, alice.userId)

    _ = try aliceService.updateNoteBody(noteId: note.noteId, bodyMarkdown: "second body")
    let afterEdit = try attribution(note: note.noteId, service: service)
    XCTAssertEqual(afterEdit.createdBy, alice.userId)
    XCTAssertEqual(afterEdit.updatedBy, alice.userId)
  }

  private func attribution(
    notebook notebookId: NotebookID,
    service: NoteService
  ) throws -> (createdBy: UserID?, updatedBy: UserID?) {
    try service.driver.withDatabase { database in
      let row = try database.query(
        "SELECT created_by, updated_by FROM notebooks WHERE notebook_id = ?",
        bindings: [.id(notebookId)]
      ).first
      return (
        row?.identifier("created_by", as: UserID.self),
        row?.identifier("updated_by", as: UserID.self)
      )
    }
  }

  private func attribution(
    note noteId: NoteID,
    service: NoteService
  ) throws -> (createdBy: UserID?, updatedBy: UserID?) {
    try service.driver.withDatabase { database in
      let row = try database.query(
        "SELECT created_by, updated_by FROM notes WHERE note_id = ?",
        bindings: [.id(noteId)]
      ).first
      return (
        row?.identifier("created_by", as: UserID.self),
        row?.identifier("updated_by", as: UserID.self)
      )
    }
  }

  private func ownerUserId(of notebookId: NotebookID, service: NoteService) throws -> UserID? {
    try service.driver.withDatabase { database in
      try database.query(
        "SELECT owner_user_id FROM notebooks WHERE notebook_id = ?",
        bindings: [.id(notebookId)]
      ).first?.identifier("owner_user_id", as: UserID.self)
    }
  }
}
