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

  func testMoveNotebookRefusesAnUnreachableDestinationWithoutChangingItsLibrary() throws {
    let service = try makeService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let aliceService = service.scoped(to: alice.userId)
    let notebook = try aliceService.createNotebook(title: "Alice notebook")
    _ = try service.createLibrary(name: "hidden-move-destination", authRequired: true)

    for destination in ["hidden-move-destination", "missing-move-destination"] {
      XCTAssertThrowsError(try aliceService.moveNotebook(notebook.notebookId, toLibrary: destination)) { error in
        XCTAssertEqual(error as? NoteServiceError, .notFound("library not found"))
      }
    }

    XCTAssertEqual(
      try service.getNotebook(notebook.notebookId).libraryId,
      NoteStoreSchema.defaultLibraryId
    )
    XCTAssertEqual(
      try aliceService.getNotebook(notebook.notebookId).libraryId,
      NoteStoreSchema.defaultLibraryId
    )
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

  func testLibraryMembershipDoesNotOverrideNotebookOwnership() throws {
    let fixture = try makeFixture()
    let user = try fixture.service.createUser(email: "alice@example.com", displayName: "Alice")
    let alice = fixture.service.scoped(to: user.userId)

    // Authentication is not reach: the account has to be granted the library
    // (`design-docs/specs/library.md`).
    XCTAssertThrowsError(try alice.getNote(fixture.privateNoteId))
    XCTAssertTrue(try alice.searchNotes(query: "classified").isEmpty)

    try fixture.service.grantLibraryAccess(libraryName: "shared", userId: user.userId)

    XCTAssertThrowsError(try alice.getNote(fixture.privateNoteId))
    XCTAssertTrue(try alice.searchNotes(query: "classified").isEmpty)
  }

  // An admin reaches every library, but a scoped request still cannot cross a
  // notebook owner boundary (`design-docs/specs/multi-user.md`).
  func testAnAdminDoesNotOverrideNotebookOwnership() throws {
    let fixture = try makeFixture()
    let user = try fixture.service.createUser(
      email: "root@example.com",
      displayName: "Root",
      isAdmin: true
    )
    let admin = fixture.service.scoped(to: user.userId)

    XCTAssertThrowsError(try admin.getNote(fixture.privateNoteId))
    XCTAssertTrue(try admin.searchNotes(query: "classified").isEmpty)
    XCTAssertTrue(try admin.listLibraries().contains { $0.libraryId == fixture.privateLibraryId })
  }

  func testForeignNotebookByIdIsRefusedToOrdinaryAndSeededAdminAccounts() throws {
    let service = try makeService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let bob = try service.createUser(email: "bob@example.com", displayName: "Bob")
    let notebook = try service.scoped(to: alice.userId).createNotebook(title: "Alice notebook")

    for scoped in [service.scoped(to: bob.userId), service.scoped(to: NoteStoreSchema.defaultUserId)] {
      XCTAssertThrowsError(try scoped.getNotebook(notebook.notebookId)) { error in
        XCTAssertEqual(error as? NoteServiceError, .notFound("notebook not found: \(notebook.notebookId)"))
      }
    }
    XCTAssertEqual(try service.getNotebook(notebook.notebookId).notebookId, notebook.notebookId)
  }

  // Admin role changes library reach on the next call, but ownership stays
  // closed both before and after demotion.
  func testDemotingAnAdminDoesNotOpenNotebookOwnership() throws {
    let fixture = try makeFixture()
    let user = try fixture.service.createUser(
      email: "root@example.com",
      displayName: "Root",
      isAdmin: true
    )
    let admin = fixture.service.scoped(to: user.userId)
    XCTAssertThrowsError(try admin.getNote(fixture.privateNoteId))

    try fixture.service.setUserAdmin(userId: user.userId, isAdmin: false)

    XCTAssertThrowsError(try admin.getNote(fixture.privateNoteId))
    XCTAssertFalse(try admin.listLibraries().contains { $0.libraryId == fixture.privateLibraryId })
  }

  func testForeignReadOnlyRowsAreIndistinguishableFromMissingRows() throws {
    let service = try makeService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let bob = try service.createUser(email: "bob@example.com", displayName: "Bob")
    let aliceService = service.scoped(to: alice.userId)
    let bobService = service.scoped(to: bob.userId)
    let notebook = try aliceService.createNotebook(title: "Alice read-only")
    let note = try aliceService.createNote(notebookId: notebook.notebookId, bodyMarkdown: "Read-only")
    try aliceService.setReadOnly(noteId: note.noteId, readOnly: true)
    try aliceService.setNotebookReadOnly(notebookId: notebook.notebookId, readOnly: true)

    XCTAssertThrowsError(try bobService.updateNoteBody(noteId: note.noteId, bodyMarkdown: "no")) { error in
      guard case .notFound = error as? NoteServiceError else {
        return XCTFail("expected notFound, got \(error)")
      }
    }
    XCTAssertThrowsError(try bobService.createNote(notebookId: notebook.notebookId, bodyMarkdown: "no")) { error in
      XCTAssertEqual(error as? NoteServiceError, .notFound("notebook not found: \(notebook.notebookId)"))
    }
  }

  func testOrdinaryAndAdminScopesFilterEveryNamedBulkOwnershipSurface() throws {
    let service = try makeService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let bob = try service.createUser(email: "bob@example.com", displayName: "Bob")
    let aliceService = service.scoped(to: alice.userId)
    let bobService = service.scoped(to: bob.userId)
    let adminService = service.scoped(to: NoteStoreSchema.defaultUserId)
    let tag = try service.defineTag(name: "cross-owner")
    let aliceNote = try aliceService.createNote(
      bodyMarkdown: "# Alice\nprivate lexical marker",
      tags: [NoteTagInput(name: "cross-owner")]
    )
    _ = try aliceService.addComment(noteId: aliceNote.noteId, bodyMarkdown: "private tag comment")
    _ = try aliceService.applyNotebookTags(
      notebookId: aliceNote.notebookId,
      tags: ["cross-owner"],
      provenance: .human,
      assignedBy: "test"
    )
    _ = try aliceService.addNotebookComment(
      notebookId: aliceNote.notebookId,
      bodyMarkdown: "private notebook tag comment"
    )
    _ = try aliceService.startAgentConversation(subjectNoteId: aliceNote.noteId)
    let aliceCandidate = try aliceService.createNote(bodyMarkdown: "# Alice candidate\nprivate proposal candidate")
    let bobNote = try bobService.createNote(bodyMarkdown: "# Bob\nprivate lexical marker")
    let adminNote = try adminService.createNote(bodyMarkdown: "# Root\nprivate lexical marker")
    _ = try service.linkNotes(from: bobNote.noteId, to: aliceNote.noteId)
    _ = try service.linkNotes(from: adminNote.noteId, to: aliceNote.noteId)
    _ = try service.linkNotes(from: aliceNote.noteId, to: aliceCandidate.noteId)
    let bobConversation = try bobService.startAgentConversation(subjectNoteId: bobNote.noteId)
    let adminConversation = try adminService.startAgentConversation(subjectNoteId: adminNote.noteId)

    for (scoped, ownNote, ownConversation) in [
      (bobService, bobNote, bobConversation),
      (adminService, adminNote, adminConversation)
    ] {
      XCTAssertFalse(try scoped.listNotes().contains { $0.noteId == aliceNote.noteId })
      XCTAssertFalse(try scoped.searchNotes(query: "private lexical marker").contains { $0.note.noteId == aliceNote.noteId })
      XCTAssertTrue(try scoped.searchComments(query: "private tag comment").isEmpty)
      XCTAssertFalse(try scoped.graphNeighbors(noteIds: [ownNote.noteId]).contains { $0.note.noteId == aliceNote.noteId })
      XCTAssertTrue(try scoped.proposeLinks(noteId: ownNote.noteId).isEmpty)
      XCTAssertTrue(try scoped.listTagComments(tagId: tag.tagId).isEmpty)
      let detail = try scoped.tagDetail(tagId: tag.tagId)
      XCTAssertEqual(detail.noteCount, 0)
      XCTAssertEqual(detail.notebookCount, 0)
      XCTAssertNil(detail.memoNotebookId)
      XCTAssertTrue(try scoped.listAgentConversations(subjectNoteId: aliceNote.noteId).isEmpty)
      XCTAssertEqual(
        try scoped.listAgentConversations(subjectNoteId: ownNote.noteId).map(\.notebook.notebookId),
        [ownConversation.notebookId]
      )
    }

    XCTAssertFalse(try service.listTagComments(tagId: tag.tagId).isEmpty)
    XCTAssertTrue(try service.proposeLinks(noteId: bobNote.noteId).contains { $0.targetNote.noteId == aliceCandidate.noteId })
  }

  func testSeededAdminSearchCommentsScopesNoteAnchoredRowsWithoutNotebookId() throws {
    let service = try makeService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let seededAdmin = service.scoped(to: NoteStoreSchema.defaultUserId)
    let ownNote = try seededAdmin.createNote(bodyMarkdown: "Seeded admin note")
    let foreignNote = try service.scoped(to: alice.userId).createNote(bodyMarkdown: "Alice note")
    let ownCommentId = CommentID.generate()
    let foreignCommentId = CommentID.generate()
    let now = NoteStoreClock.system.now()

    try service.driver.withDatabase { database in
      for (commentId, noteId) in [(ownCommentId, ownNote.noteId), (foreignCommentId, foreignNote.noteId)] {
        try database.execute(
          """
          INSERT INTO note_comments (comment_id, note_id, notebook_id, body_markdown, author, created_at)
          VALUES (?, ?, NULL, ?, ?, ?)
          """,
          bindings: [
            .id(commentId), .id(noteId), .text("note anchored memo"), .text("test"), .text(now)
          ]
        )
      }
    }

    let scoped = try seededAdmin.searchComments(query: "note anchored memo")
    XCTAssertEqual(scoped.map(\.commentId), [ownCommentId])
    XCTAssertEqual(scoped.first?.noteId, ownNote.noteId)
    XCTAssertNil(scoped.first?.notebookId)
    XCTAssertEqual(
      Set(try service.searchComments(query: "note anchored memo").map(\.commentId)),
      Set([ownCommentId, foreignCommentId])
    )
  }

  func testScopedLinksCommentsAndOrphanFilesEnforceOwnership() throws {
    let service = try makeService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let bob = try service.createUser(email: "bob@example.com", displayName: "Bob")
    let aliceService = service.scoped(to: alice.userId)
    let bobService = service.scoped(to: bob.userId)
    let aliceNote = try aliceService.createNote(bodyMarkdown: "Alice note")
    let aliceComment = try aliceService.addComment(noteId: aliceNote.noteId, bodyMarkdown: "Alice comment")
    let bobNote = try bobService.createNote(bodyMarkdown: "Bob note")

    XCTAssertThrowsError(try bobService.listComments(noteId: aliceNote.noteId))
    XCTAssertThrowsError(try bobService.listLinks(noteId: aliceNote.noteId))
    XCTAssertThrowsError(try bobService.addComment(noteId: aliceNote.noteId, bodyMarkdown: "forbidden"))
    XCTAssertThrowsError(try bobService.promoteCommentToNotebook(noteId: aliceNote.noteId, commentId: aliceComment.commentId))
    XCTAssertThrowsError(try bobService.linkNotes(from: bobNote.noteId, to: aliceNote.noteId))
    XCTAssertThrowsError(try bobService.linkNotes(from: aliceNote.noteId, to: bobNote.noteId))
    XCTAssertNotNil(try bobService.driver.withDatabase { try requireNotes([aliceNote.noteId], in: $0) }[aliceNote.noteId])

    let bobReadOnly = try bobService.createNote(bodyMarkdown: "Bob read-only")
    try bobService.setReadOnly(noteId: bobReadOnly.noteId, readOnly: true)
    XCTAssertNoThrow(try bobService.linkNotes(from: bobReadOnly.noteId, to: bobNote.noteId))
    XCTAssertFalse(try service.listComments(noteId: aliceNote.noteId).isEmpty)

    let bytes = Data("orphan bytes".utf8)
    let attachment = try aliceService.attachFile(
      noteId: aliceNote.noteId,
      data: bytes,
      mediaType: "text/plain"
    )
    XCTAssertThrowsError(try bobService.getFileRecord(fileId: attachment.file.fileId))
    try service.deleteNote(noteId: aliceNote.noteId)
    XCTAssertThrowsError(try aliceService.getFileRecord(fileId: attachment.file.fileId))
    XCTAssertEqual(try service.resolveFileContent(fileId: attachment.file.fileId), bytes)
  }

  func testScopedLinksAndGraphTraversalDoNotCrossOwnerBoundaries() throws {
    let service = try makeService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let bob = try service.createUser(email: "bob@example.com", displayName: "Bob")
    let aliceService = service.scoped(to: alice.userId)
    let bobService = service.scoped(to: bob.userId)
    let seed = try aliceService.createNote(bodyMarkdown: "# Seed\nscarlet")
    let destination = try aliceService.createNote(bodyMarkdown: "# Destination\ncobalt")
    let foreignIntermediate = try bobService.createNote(bodyMarkdown: "# Intermediate\namber")

    // Store-wide workflows can create a cross-owner bridge. Scoped reads must
    // neither list that edge nor traverse through it to the owned destination.
    _ = try service.linkNotes(from: seed.noteId, to: foreignIntermediate.noteId)
    _ = try service.linkNotes(from: foreignIntermediate.noteId, to: destination.noteId)

    XCTAssertEqual(try service.listLinks(noteId: seed.noteId).count, 1)
    XCTAssertTrue(try aliceService.listLinks(noteId: seed.noteId).isEmpty)
    XCTAssertTrue(try bobService.listLinks(noteId: foreignIntermediate.noteId).isEmpty)

    let neighbors = try aliceService.graphNeighbors(noteIds: [seed.noteId], maxDepth: 2)
    XCTAssertFalse(neighbors.contains { $0.note.noteId == destination.noteId })
    XCTAssertFalse(neighbors.contains { $0.pathNoteIds.contains(foreignIntermediate.noteId) })
    XCTAssertTrue(try aliceService.proposeLinks(noteId: seed.noteId).isEmpty)
  }

  func testScopedGraphCandidatesAreFilteredBeforeExplicitEdgeLimit() throws {
    let service = try makeService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let bob = try service.createUser(email: "bob@example.com", displayName: "Bob")
    let aliceService = service.scoped(to: alice.userId)
    let bobService = service.scoped(to: bob.userId)
    let seed = try aliceService.createNote(bodyMarkdown: "Alice seed")
    let bridge = try aliceService.createNote(bodyMarkdown: "Alice reachable bridge")
    let destination = try aliceService.createNote(bodyMarkdown: "Alice reachable proposal")
    let foreignNotebook = try bobService.createNotebook(title: "Foreign saturation")
    let now = NoteStoreClock.system.now()

    try service.driver.withDatabase { database in
      try database.transaction { db in
        for index in 0..<NoteGraphPolicy.sourceCandidateLimit {
          let foreignId = NoteID(String(format: "000-foreign-%03d", index))
          try db.execute(
            """
            INSERT INTO notes (
              note_id, notebook_id, note_number, title, title_source, body_markdown,
              read_only, created_by, updated_by, created_at, updated_at, meta_json
            ) VALUES (?, ?, ?, ?, 'explicit', ?, 0, ?, ?, ?, ?, NULL)
            """,
            bindings: [
              .id(foreignId), .id(foreignNotebook.notebookId), .int(Int64(index + 1)),
              .text("Foreign \(index)"), .text("foreign saturation"), .id(bob.userId),
              .id(bob.userId), .text(now), .text(now)
            ]
          )
          _ = try linkNotesInDatabase(
            from: seed.noteId,
            to: foreignId,
            linkKind: "related",
            provenance: .system,
            in: db
          )
        }
        _ = try linkNotesInDatabase(
          from: seed.noteId,
          to: bridge.noteId,
          linkKind: "related",
          provenance: .system,
          in: db
        )
        _ = try linkNotesInDatabase(
          from: bridge.noteId,
          to: destination.noteId,
          linkKind: "related",
          provenance: .system,
          in: db
        )
      }
    }

    XCTAssertTrue(try aliceService.graphNeighbors(noteIds: [seed.noteId], maxDepth: 2)
      .contains { $0.note.noteId == destination.noteId })
    XCTAssertTrue(try aliceService.proposeLinks(noteId: seed.noteId)
      .contains { $0.targetNote.noteId == destination.noteId })
  }

  func testScopedLongTermMemoryAPIsAndDiscoveredMemoryNoteAreRefused() throws {
    let service = try makeService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let aliceService = service.scoped(to: alice.userId)
    let source = try aliceService.createNote(bodyMarkdown: "Alice source for consolidation")
    let memory = try XCTUnwrap(try service.appendLongTermMemoryNotes(
      [LongTermMemoryEntryInput(
        bodyMarkdown: "Store-wide consolidated memory",
        sourceNoteIds: [source.noteId]
      )],
      idempotencyKey: "scoped-memory-refusal"
    ).notes.first)

    // The unscoped processor can discover and use the internal memory note;
    // holding that id must not make it readable by a scoped user.
    XCTAssertTrue(try service.listLinks(noteId: source.noteId).contains { link in
      link.fromNoteId == memory.noteId || link.toNoteId == memory.noteId
    })
    XCTAssertThrowsError(try aliceService.getNote(memory.noteId))
    XCTAssertThrowsError(try aliceService.longTermMemoryNotebook())
    XCTAssertThrowsError(try aliceService.listLongTermMemoryNotes())
    XCTAssertThrowsError(try aliceService.recallLongTermMemories(query: "consolidated"))
  }

  func testDefaultAndUnauthenticatedScopesCannotDiscoverInternalLongTermMemory() throws {
    let service = try makeService()
    let source = try service.createNote(bodyMarkdown: "Default-account memory source")
    let memory = try XCTUnwrap(try service.appendLongTermMemoryNotes(
      [LongTermMemoryEntryInput(
        bodyMarkdown: "Internal default-account consolidated memory",
        sourceNoteIds: [source.noteId]
      )],
      idempotencyKey: "default-memory-refusal"
    ).notes.first)
    let defaultScoped = service.scoped(to: NoteStoreSchema.defaultUserId)
    let unauthenticated = defaultScoped.unauthenticated()

    XCTAssertEqual(try service.getNote(memory.noteId).noteId, memory.noteId)
    XCTAssertFalse(try service.listLinks(noteId: source.noteId).isEmpty)
    for scoped in [defaultScoped, unauthenticated, service.unauthenticated()] {
      XCTAssertThrowsError(try scoped.getNote(memory.noteId))
      XCTAssertTrue(try scoped.listNotes().allSatisfy { $0.notebookId != memory.notebookId })
      XCTAssertTrue(try scoped.searchNotes(query: "consolidated memory").isEmpty)
      XCTAssertTrue(try scoped.listLinks(noteId: source.noteId).isEmpty)
      XCTAssertFalse(try scoped.listNotebooks().contains { $0.notebookId == memory.notebookId })
    }
  }

  func testScopedCommentSearchAndTagCommentsHideInternalLongTermMemory() throws {
    let service = try makeService()
    let topic = try service.defineTag(name: "internal-memory-comment-topic")
    let memory = try XCTUnwrap(try service.appendLongTermMemoryNotes(
      [LongTermMemoryEntryInput(
        bodyMarkdown: "Internal memory comment source",
        topicTags: [topic.name]
      )],
      idempotencyKey: "internal-memory-comment-refusal"
    ).notes.first)
    let noteComment = try service.addComment(
      noteId: memory.noteId,
      bodyMarkdown: "Internal memory note comment"
    )
    let notebookComment = try service.addNotebookComment(
      notebookId: memory.notebookId,
      bodyMarkdown: "Internal memory notebook comment"
    )

    XCTAssertEqual(
      Set(try service.searchComments(query: "Internal memory").map(\.commentId)),
      Set([noteComment.commentId, notebookComment.commentId])
    )
    XCTAssertEqual(
      try service.listTagComments(tagId: topic.tagId).map(\.comment.commentId),
      [noteComment.commentId]
    )
    XCTAssertEqual(
      try service.listTagComments(tagId: NoteStoreSchema.longTermMemoryNotebookKindTagId)
        .map(\.comment.commentId),
      [notebookComment.commentId]
    )
    XCTAssertEqual(try service.tagDetail(tagId: topic.tagId).noteCount, 1)
    XCTAssertEqual(
      try service.tagDetail(tagId: NoteStoreSchema.longTermMemoryNotebookKindTagId).notebookCount,
      1
    )

    let defaultScoped = service.scoped(to: NoteStoreSchema.defaultUserId)
    for scoped in [defaultScoped, defaultScoped.unauthenticated(), service.unauthenticated()] {
      XCTAssertTrue(try scoped.searchComments(query: "Internal memory").isEmpty)
      XCTAssertTrue(try scoped.listTagComments(tagId: topic.tagId).isEmpty)
      XCTAssertTrue(
        try scoped.listTagComments(tagId: NoteStoreSchema.longTermMemoryNotebookKindTagId).isEmpty
      )
      XCTAssertEqual(try scoped.tagDetail(tagId: topic.tagId).noteCount, 0)
      XCTAssertEqual(
        try scoped.tagDetail(tagId: NoteStoreSchema.longTermMemoryNotebookKindTagId).notebookCount,
        0
      )
    }
  }

  // The seeded default user is an admin, and an unauthenticated note-API
  // request resolves to it — so without the marker that request would inherit
  // every library. The marker is what keeps an open port at the open
  // libraries (`design-docs/specs/library.md`).
  func testAnUnauthenticatedRequestIsCappedEvenThoughItActsAsTheAdmin() throws {
    let fixture = try makeFixture()

    XCTAssertTrue(try fixture.service.defaultUser().isAdmin)
    XCTAssertThrowsError(try fixture.anonymous.getNote(fixture.privateNoteId))
    XCTAssertFalse(
      try fixture.anonymous.listLibraries().contains { $0.libraryId == fixture.privateLibraryId }
    )

    // `serve --allow-unauthenticated --as-admin` drops the marker, and the
    // same account then reaches what an admin reaches.
    let asAdmin = fixture.service.scoped(to: NoteStoreSchema.defaultUserId).unauthenticated(false)
    XCTAssertEqual(try asAdmin.getNote(fixture.privateNoteId).noteId, fixture.privateNoteId)
  }

  func testForeignNoteTagRemovalIsIndistinguishableFromMissingOrProtectedAssignments() throws {
    let service = try makeService()
    let alice = try service.createUser(email: "tag-owner@example.com", displayName: "Tag Owner")
    let bob = try service.createUser(email: "tag-outsider@example.com", displayName: "Tag Outsider")
    let owner = service.scoped(to: alice.userId)
    let outsider = service.scoped(to: bob.userId)
    let note = try owner.createNote(bodyMarkdown: "# Private\nTags")
    try owner.applyTags(
      noteId: note.noteId,
      tags: [NoteTagInput(name: "human-assignment")],
      provenance: .human
    )
    try owner.applyTags(
      noteId: note.noteId,
      tags: [NoteTagInput(name: "ai-assignment")],
      provenance: .ai
    )
    try owner.applyTags(
      noteId: note.noteId,
      tags: [NoteTagInput(name: "locked-assignment")],
      provenance: .ai
    )
    try service.driver.withDatabase { database in
      try database.execute(
        "UPDATE note_tags SET deletable = 0 WHERE note_id = ? AND tag_id = ?",
        bindings: [
          .id(note.noteId),
          .id(try requireTag(name: "locked-assignment", in: database).tagId)
        ]
      )
    }

    let removals: [() throws -> Note] = [
      { try outsider.removeTag(noteId: note.noteId, tagName: "missing-assignment", removedBy: .ai) },
      { try outsider.removeTag(noteId: note.noteId, tagName: "human-assignment", removedBy: .ai) },
      { try outsider.removeTag(noteId: note.noteId, tagName: "ai-assignment", removedBy: .human) },
      { try outsider.removeTag(noteId: note.noteId, tagName: "locked-assignment", removedBy: .human) }
    ]
    for remove in removals {
      XCTAssertThrowsError(try remove()) { error in
        guard case NoteServiceError.notFound = error else {
          return XCTFail("expected notFound, got \(error)")
        }
      }
    }
  }

  func testForeignNotebookTagRemovalIsIndistinguishableForNameAndIdRequests() throws {
    let service = try makeService()
    let alice = try service.createUser(email: "notebook-tag-owner@example.com", displayName: "Owner")
    let bob = try service.createUser(email: "notebook-tag-outsider@example.com", displayName: "Outsider")
    let owner = service.scoped(to: alice.userId)
    let outsider = service.scoped(to: bob.userId)
    let notebook = try owner.createNotebook(title: "Private tags")
    let human = try service.defineTag(name: "human-notebook-assignment")
    let ai = try service.defineTag(name: "ai-notebook-assignment")
    let locked = try service.defineTag(name: "locked-notebook-assignment")
    try owner.applyNotebookTagIds(
      notebookId: notebook.notebookId,
      tagIds: [human.tagId],
      provenance: .human
    )
    try owner.applyNotebookTagIds(
      notebookId: notebook.notebookId,
      tagIds: [ai.tagId, locked.tagId],
      provenance: .ai
    )
    try service.driver.withDatabase { database in
      try database.execute(
        "UPDATE notebook_tags SET deletable = 0 WHERE notebook_id = ? AND tag_id = ?",
        bindings: [.id(notebook.notebookId), .id(locked.tagId)]
      )
    }

    let removals: [() throws -> Notebook] = [
      { try outsider.removeNotebookTag(notebookId: notebook.notebookId, tagName: "missing-notebook-assignment", removedBy: .ai) },
      { try outsider.removeNotebookTag(notebookId: notebook.notebookId, tagName: human.name, removedBy: .ai) },
      { try outsider.removeNotebookTagById(notebookId: notebook.notebookId, tagId: ai.tagId, removedBy: .human) },
      { try outsider.removeNotebookTagById(notebookId: notebook.notebookId, tagId: locked.tagId, removedBy: .human) }
    ]
    for remove in removals {
      XCTAssertThrowsError(try remove()) { error in
        guard case NoteServiceError.notFound = error else {
          return XCTFail("expected notFound, got \(error)")
        }
      }
    }
  }
}
