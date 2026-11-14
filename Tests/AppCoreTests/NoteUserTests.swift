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
    // A store always has an admin, even with no authentication configured:
    // the account an unauthenticated host acts as is that admin.
    XCTAssertTrue(defaultUser.isAdmin)
    XCTAssertEqual(try service.listAdminUsers().map(\.userId), [NoteStoreSchema.defaultUserId])
  }

  func testAdminIsGrantedAndRevoked() throws {
    let service = try makeService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
    XCTAssertFalse(alice.isAdmin)

    let promoted = try service.setUserAdmin(userId: alice.userId, isAdmin: true)
    XCTAssertTrue(promoted.isAdmin)
    XCTAssertEqual(
      try service.listAdminUsers().map(\.userId).sorted(),
      [NoteStoreSchema.defaultUserId, alice.userId].sorted()
    )

    let demoted = try service.setUserAdmin(userId: alice.userId, isAdmin: false)
    XCTAssertFalse(demoted.isAdmin)
    XCTAssertEqual(try service.listAdminUsers().map(\.userId), [NoteStoreSchema.defaultUserId])
  }

  func testAUserCanBeCreatedAsAnAdmin() throws {
    let service = try makeService()

    let alice = try service.createUser(
      email: "alice@example.com",
      displayName: "Alice",
      isAdmin: true
    )

    XCTAssertTrue(alice.isAdmin)
    XCTAssertTrue(try XCTUnwrap(service.user(id: alice.userId)).isAdmin)
  }

  func testScopedNonAdminCannotManageAccountsOrEnumerateUsers() throws {
    let service = try makeService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let bob = try service.createUser(email: "bob@example.com", displayName: "Bob")
    let aliceService = service.scoped(to: alice.userId)

    XCTAssertThrowsError(
      try aliceService.createUser(email: "attacker@example.com", displayName: "Attacker", isAdmin: true)
    ) { error in
      XCTAssertEqual(error as? NoteServiceError, .notFound("control-plane resource not found"))
    }
    XCTAssertThrowsError(try aliceService.setUserDisabled(userId: bob.userId, disabled: true)) { error in
      XCTAssertEqual(error as? NoteServiceError, .notFound("control-plane resource not found"))
    }
    XCTAssertThrowsError(try aliceService.setUserAdmin(userId: alice.userId, isAdmin: true)) { error in
      XCTAssertEqual(error as? NoteServiceError, .notFound("control-plane resource not found"))
    }
    XCTAssertThrowsError(try aliceService.listUsers()) { error in
      XCTAssertEqual(error as? NoteServiceError, .notFound("control-plane resource not found"))
    }
    XCTAssertThrowsError(try aliceService.listAdminUsers()) { error in
      XCTAssertEqual(error as? NoteServiceError, .notFound("control-plane resource not found"))
    }

    let unauthenticated = service.scoped(to: NoteStoreSchema.defaultUserId).unauthenticated()
    XCTAssertThrowsError(try unauthenticated.listUsers()) { error in
      XCTAssertEqual(error as? NoteServiceError, .notFound("control-plane resource not found"))
    }

    XCTAssertEqual(try aliceService.user(id: alice.userId)?.userId, alice.userId)
    XCTAssertEqual(try aliceService.user(email: "alice@example.com")?.userId, alice.userId)
    XCTAssertNil(try aliceService.user(id: bob.userId))
    XCTAssertNil(try aliceService.user(email: "bob@example.com"))
    XCTAssertNil(try unauthenticated.user(id: bob.userId))
    XCTAssertNil(try unauthenticated.user(email: "bob@example.com"))

    let administrator = service.scoped(to: NoteStoreSchema.defaultUserId)
    XCTAssertEqual(try administrator.user(id: bob.userId)?.userId, bob.userId)
    XCTAssertEqual(try administrator.user(email: "bob@example.com")?.userId, bob.userId)
    XCTAssertNotNil(try service.user(id: bob.userId))
    XCTAssertNil(try service.user(email: "attacker@example.com"))
  }

  func testScopedAdministratorMayManageAccounts() throws {
    let service = try makeService()
    let administrator = service.scoped(to: NoteStoreSchema.defaultUserId)

    let user = try administrator.createUser(email: "admin-created@example.com", displayName: "Created")

    XCTAssertTrue(try administrator.listUsers().contains { $0.userId == user.userId })
    XCTAssertTrue(try administrator.setUserAdmin(userId: user.userId, isAdmin: true).isAdmin)
  }

  // The store would otherwise be left with no principal that reaches an
  // authenticated library, and no unauthenticated host to act as one.
  func testTheLastAdminCannotBeDemotedOrDisabled() throws {
    let service = try makeService()

    XCTAssertThrowsError(
      try service.setUserAdmin(userId: NoteStoreSchema.defaultUserId, isAdmin: false)
    ) { error in
      XCTAssertEqual(
        error as? NoteServiceError,
        .invalidInput("the last admin cannot be demoted; promote another user first")
      )
    }
    XCTAssertTrue(try service.defaultUser().isAdmin)

    // With a second admin the first one may step down, and then it is the
    // second one that is pinned.
    let alice = try service.createUser(
      email: "alice@example.com",
      displayName: "Alice",
      isAdmin: true
    )
    try service.setUserAdmin(userId: NoteStoreSchema.defaultUserId, isAdmin: false)
    XCTAssertThrowsError(try service.setUserDisabled(userId: alice.userId, disabled: true)) { error in
      XCTAssertEqual(
        error as? NoteServiceError,
        .invalidInput("the last admin cannot be disabled; promote another user first")
      )
    }
  }

  func testADisabledUserCannotBeMadeAnAdmin() throws {
    let service = try makeService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
    try service.setUserDisabled(userId: alice.userId, disabled: true)

    XCTAssertThrowsError(try service.setUserAdmin(userId: alice.userId, isAdmin: true))
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
    XCTAssertNil(try service.authenticateAPIClient(bearerToken: "token-alice"))
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

  func testScopedNonAdministratorsCannotManageAPIClients() throws {
    let service = try makeService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let bob = try service.createUser(email: "bob@example.com", displayName: "Bob")
    let aliceService = service.scoped(to: alice.userId)

    XCTAssertThrowsError(try aliceService.registerAPIClient(
      displayName: "Escalation",
      bearerToken: "alice-should-not-issue",
      userId: NoteStoreSchema.defaultUserId
    )) { error in
      XCTAssertEqual(error as? NoteServiceError, .notFound("control-plane resource not found"))
    }
    XCTAssertThrowsError(try aliceService.listAPIClients()) { error in
      XCTAssertEqual(error as? NoteServiceError, .notFound("control-plane resource not found"))
    }

    let client = try service.registerAPIClient(
      displayName: "Bob",
      bearerToken: "bob-client",
      userId: bob.userId
    )
    XCTAssertThrowsError(try aliceService.revokeAPIClient(clientId: client.clientId)) { error in
      XCTAssertEqual(error as? NoteServiceError, .notFound("control-plane resource not found"))
    }

    let administrator = service.scoped(to: NoteStoreSchema.defaultUserId)
    XCTAssertEqual(try administrator.listAPIClients().map(\.clientId), [client.clientId])
    XCTAssertNotNil(try administrator.revokeAPIClient(clientId: client.clientId).revokedAt)
    XCTAssertThrowsError(try service.scoped(to: NoteStoreSchema.defaultUserId).unauthenticated()
      .listAPIClients()) { error in
      XCTAssertEqual(error as? NoteServiceError, .notFound("control-plane resource not found"))
    }
  }

  func testDisabledAdministratorCannotListAPIClients() throws {
    let service = try makeService()
    let administrator = try service.createUser(
      email: "admin@example.com",
      displayName: "Administrator",
      isAdmin: true
    )
    _ = try service.registerAPIClient(displayName: "Visible", bearerToken: "visible-client")
    _ = try service.setUserDisabled(userId: administrator.userId, disabled: true)

    XCTAssertThrowsError(try service.scoped(to: administrator.userId).listAPIClients()) { error in
      XCTAssertEqual(error as? NoteServiceError, .accountUnavailable(
        "account is disabled: \(administrator.userId)"
      ))
    }
  }

  func testAPIClientListingHoldsAdministratorAuthorizationAgainstConcurrentDemotion() throws {
    let service = try makeService()
    let administrator = try service.createUser(
      email: "listing-admin@example.com",
      displayName: "Listing Administrator",
      isAdmin: true
    )
    _ = try service.registerAPIClient(displayName: "Visible", bearerToken: "visible-client")
    let databasePath = service.driver.databasePath
    var administratorService = service.scoped(to: administrator.userId)
    administratorService.apiClientListAfterAuthorizationHook = { _ in
      let concurrent = try SQLiteDatabase.open(
        path: databasePath,
        options: SQLiteOpenOptions(
          enableWAL: false,
          busyTimeoutMilliseconds: 0,
          requireJSONB: false,
          requireFTS5: false
        )
      )
      let updateSucceeded: Bool
      do {
        try concurrent.execute(
          "UPDATE users SET is_admin = 0 WHERE user_id = ?",
          bindings: [.id(administrator.userId)]
        )
        updateSucceeded = true
      } catch {
        updateSucceeded = false
      }
      guard !updateSucceeded else {
        throw NoteServiceError.conflict(
          "administrator demotion interleaved between API-client authorization and listing"
        )
      }
    }

    XCTAssertEqual(try administratorService.listAPIClients().count, 1)
    XCTAssertTrue(try XCTUnwrap(service.user(id: administrator.userId)).isAdmin)
  }

  func testAccountListingsHoldAdministratorAuthorizationAgainstConcurrentDemotion() throws {
    let service = try makeService()
    let administrator = try service.createUser(
      email: "account-listing-admin@example.com",
      displayName: "Account Listing Administrator",
      isAdmin: true
    )
    let databasePath = service.driver.databasePath
    var administratorService = service.scoped(to: administrator.userId)
    administratorService.userListAfterAuthorizationHook = { _ in
      let concurrent = try SQLiteDatabase.open(
        path: databasePath,
        options: SQLiteOpenOptions(
          enableWAL: false,
          busyTimeoutMilliseconds: 0,
          requireJSONB: false,
          requireFTS5: false
        )
      )
      let updateSucceeded: Bool
      do {
        try concurrent.execute(
          "UPDATE users SET is_admin = 0 WHERE user_id = ?",
          bindings: [.id(administrator.userId)]
        )
        updateSucceeded = true
      } catch {
        updateSucceeded = false
      }
      guard !updateSucceeded else {
        throw NoteServiceError.conflict(
          "administrator demotion interleaved between account authorization and listing"
        )
      }
    }

    XCTAssertTrue(try administratorService.listUsers().contains { $0.userId == administrator.userId })
    XCTAssertTrue(try administratorService.listAdminUsers().contains { $0.userId == administrator.userId })
    XCTAssertTrue(try XCTUnwrap(service.user(id: administrator.userId)).isAdmin)
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

  func testModelReadsExposeOwnershipAndAttribution() throws {
    let service = try makeService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let aliceService = service.scoped(to: alice.userId)
    let notebook = try aliceService.createNotebook(title: "Alice notebook")
    let note = try aliceService.createNote(notebookId: notebook.notebookId, bodyMarkdown: "body")

    let fetchedNotebook = try aliceService.getNotebook(notebook.notebookId)
    let fetchedNote = try aliceService.getNote(note.noteId)
    XCTAssertEqual(fetchedNotebook.ownerUserId, alice.userId)
    XCTAssertEqual(fetchedNotebook.createdBy, alice.userId)
    XCTAssertEqual(fetchedNotebook.updatedBy, alice.userId)
    XCTAssertEqual(fetchedNote.createdBy, alice.userId)
    XCTAssertEqual(fetchedNote.updatedBy, alice.userId)
    let batch = try aliceService.driver.withDatabase { database in
      try requireNotes([note.noteId], in: database)
    }
    XCTAssertEqual(batch[note.noteId]?.createdBy, alice.userId)
    XCTAssertEqual(batch[note.noteId]?.updatedBy, alice.userId)
    XCTAssertNil(try aliceService.listNotes(notebookId: notebook.notebookId).first?.createdBy)
  }

  func testAttributedHydratorsCoverCatalogSearchGraphMemoryAndConversations() throws {
    let service = try makeService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let aliceService = service.scoped(to: alice.userId)
    let first = try aliceService.createNote(bodyMarkdown: "# First\nattribution search marker")
    let second = try aliceService.createNote(bodyMarkdown: "# Second\ngraph target")
    _ = try aliceService.linkNotes(from: first.noteId, to: second.noteId)

    XCTAssertEqual(try aliceService.listNotebooks().first { $0.notebookId == first.notebookId }?.ownerUserId, alice.userId)
    XCTAssertEqual(try aliceService.searchNotes(query: "attribution search marker").first?.note.createdBy, alice.userId)
    XCTAssertEqual(try aliceService.graphNeighbors(noteIds: [first.noteId]).first?.note.createdBy, alice.userId)

    let conversation = try aliceService.startAgentConversation(subjectNoteId: first.noteId)
    XCTAssertEqual(
      try aliceService.listAgentConversations(subjectNoteId: first.noteId).first?.notebook.ownerUserId,
      alice.userId
    )
    XCTAssertEqual(conversation.createdBy, alice.userId)

    _ = try service.appendLongTermMemoryNotes(
      [LongTermMemoryEntryInput(bodyMarkdown: "# Memory\nattribution memory marker")],
      idempotencyKey: "attribution-memory"
    )
    XCTAssertNotNil(try service.recallLongTermMemories(query: "attribution memory marker").first?.note.createdBy)
    XCTAssertNil(try aliceService.listNotes().first?.createdBy)
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
