import Foundation
@testable import AppCore
import XCTest

private final class TagDetailChangeObserver: NoteChangeObserving, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [NoteChangeEvent] = []

  func noteStoreDidChange(_ event: NoteChangeEvent) {
    lock.lock()
    recorded.append(event)
    lock.unlock()
  }

  var events: [NoteChangeEvent] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }
}

private final class TagDetailRecordingDispatcher: AutoActionDispatching, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [AutoActionDispatchRecord] = []

  func dispatch(_ record: AutoActionDispatchRecord) async throws -> AutoActionDispatchOutcome {
    lock.withLock {
      recorded.append(record)
    }
    return .succeeded
  }

  func records() -> [AutoActionDispatchRecord] {
    lock.withLock { recorded }
  }
}

final class NoteTagDetailTests: NoteTestCase {
  func testTagDetailCountsAcrossNotebooksWithDescendantExpansion() throws {
    let service = try makeService()
    _ = try service.defineTagClass(classId: TagClassID("person-test"), label: "Person Test")
    let parent = try service.defineTag(name: "tanaka", classId: TagClassID("person-test"))
    let child = try service.defineTag(name: "tanaka-taro", parentTagId: parent.tagId)

    let first = try service.createNote(
      notebookTitle: "Book A",
      bodyMarkdown: "# One\ntanaka appears here"
    )
    _ = try service.applyTags(
      noteId: first.noteId,
      tags: [NoteTagInput(name: "tanaka")],
      provenance: .human,
      assignedBy: "test"
    )
    let second = try service.createNote(
      notebookTitle: "Book B",
      bodyMarkdown: "# Two\nchild tag note"
    )
    _ = try service.applyTags(
      noteId: second.noteId,
      tags: [NoteTagInput(name: "tanaka-taro")],
      provenance: .human,
      assignedBy: "test"
    )
    _ = try service.applyNotebookTags(
      notebookId: second.notebookId,
      tags: ["tanaka"],
      provenance: .human,
      assignedBy: "test"
    )

    let detail = try service.tagDetail(tagId: parent.tagId)

    XCTAssertEqual(detail.tag.tagId, parent.tagId)
    XCTAssertEqual(detail.tagClass?.classId, TagClassID("person-test"))
    XCTAssertEqual(detail.noteCount, 2, "parent tag must count descendant-tagged notes")
    XCTAssertEqual(detail.notebookCount, 1)
    XCTAssertNil(detail.memoNotebookId, "no memo notebook exists before ensure")
    _ = child
  }

  func testTagDetailRejectsUnknownTag() throws {
    let service = try makeService()
    XCTAssertThrowsError(try service.tagDetail(tagId: TagID("tag-missing"))) { error in
      guard case NoteServiceError.notFound = error else {
        return XCTFail("expected notFound, got \(error)")
      }
    }
  }

  func testListTagCommentsAggregatesAcrossNotebooksNewestFirst() throws {
    let service = try makeService()
    let tag = try service.defineTag(name: "sakamoto")

    let tagged = try service.createNote(
      notebookTitle: "Book A",
      bodyMarkdown: "# Tagged\nsakamoto"
    )
    _ = try service.applyTags(
      noteId: tagged.noteId,
      tags: [NoteTagInput(name: "sakamoto")],
      provenance: .human,
      assignedBy: "test"
    )
    let untagged = try service.createNote(
      notebookTitle: "Book B",
      bodyMarkdown: "# Untagged\nno tag"
    )
    let taggedNotebookNote = try service.createNote(
      notebookTitle: "Book C",
      bodyMarkdown: "# Other\nnotebook-tagged"
    )
    _ = try service.applyNotebookTags(
      notebookId: taggedNotebookNote.notebookId,
      tags: ["sakamoto"],
      provenance: .human,
      assignedBy: "test"
    )

    let noteComment = try service.addComment(
      noteId: tagged.noteId,
      bodyMarkdown: "memo on tagged note",
      author: "user"
    )
    _ = try service.addComment(
      noteId: untagged.noteId,
      bodyMarkdown: "memo on untagged note",
      author: "user"
    )
    let notebookComment = try service.addNotebookComment(
      notebookId: taggedNotebookNote.notebookId,
      bodyMarkdown: "memo on tagged notebook",
      author: "user"
    )
    // A note-anchored memo inside a tagged notebook is not part of the tag's
    // history unless the note itself carries the tag.
    _ = try service.addComment(
      noteId: taggedNotebookNote.noteId,
      bodyMarkdown: "memo on untagged note in tagged notebook",
      author: "user"
    )

    let comments = try service.listTagComments(tagId: tag.tagId)

    XCTAssertEqual(
      Set(comments.map(\.comment.commentId)),
      [noteComment.commentId, notebookComment.commentId]
    )
    let createdAts = comments.map(\.comment.createdAt)
    XCTAssertEqual(createdAts, createdAts.sorted(by: >), "newest first")
    let attributedNote = comments.first { $0.comment.commentId == noteComment.commentId }
    XCTAssertEqual(attributedNote?.noteTitle, "Tagged")
    XCTAssertEqual(
      attributedNote?.notebookTitle,
      try service.getNotebook(tagged.notebookId).title
    )
  }

  func testTagCommentsAndCountsRequireCurrentLibraryReach() throws {
    let service = try makeService()
    let defaultService = service.scoped(to: NoteStoreSchema.defaultUserId)
    let tag = try service.defineTag(name: "protected-tag-comment-reach")
    let protectedLibrary = try defaultService.createLibrary(
      name: "protected-tag-comment-reach",
      authRequired: true
    )
    let protectedService = defaultService.scoped(toLibrary: protectedLibrary.libraryId)
    let protectedNote = try protectedService.createNote(
      notebookTitle: "Protected comments",
      bodyMarkdown: "# Protected\nTag comments must stay private."
    )
    _ = try protectedService.applyTags(
      noteId: protectedNote.noteId,
      tags: [NoteTagInput(name: tag.name)],
      provenance: .human,
      assignedBy: "test"
    )
    _ = try protectedService.applyNotebookTags(
      notebookId: protectedNote.notebookId,
      tags: [tag.name],
      provenance: .human,
      assignedBy: "test"
    )
    _ = try protectedService.addComment(noteId: protectedNote.noteId, bodyMarkdown: "protected note comment")
    _ = try protectedService.addNotebookComment(
      notebookId: protectedNote.notebookId,
      bodyMarkdown: "protected notebook comment"
    )

    XCTAssertEqual(try protectedService.listTagComments(tagId: tag.tagId).count, 2)
    XCTAssertEqual(try protectedService.tagDetail(tagId: tag.tagId).noteCount, 1)
    XCTAssertEqual(try protectedService.tagDetail(tagId: tag.tagId).notebookCount, 1)

    let unauthenticated = defaultService.unauthenticated()
    XCTAssertEqual(try unauthenticated.listTagComments(tagId: tag.tagId), [])
    XCTAssertEqual(try unauthenticated.tagDetail(tagId: tag.tagId).noteCount, 0)
    XCTAssertEqual(try unauthenticated.tagDetail(tagId: tag.tagId).notebookCount, 0)

    let defaultLibraryScope = defaultService.scoped(toLibrary: NoteStoreSchema.defaultLibraryId)
    XCTAssertEqual(try defaultLibraryScope.listTagComments(tagId: tag.tagId), [])
    XCTAssertEqual(try defaultLibraryScope.tagDetail(tagId: tag.tagId).noteCount, 0)
    XCTAssertEqual(try defaultLibraryScope.tagDetail(tagId: tag.tagId).notebookCount, 0)

    let alice = try service.createUser(email: "tag-comment-revoked@example.com", displayName: "Alice")
    let aliceService = service.scoped(to: alice.userId)
    let aliceLibrary = try aliceService.createLibrary(
      name: "revoked-tag-comment-reach",
      authRequired: true
    )
    let aliceProtected = aliceService.scoped(toLibrary: aliceLibrary.libraryId)
    let aliceTag = try service.defineTag(name: "revoked-tag-comment-reach")
    let aliceNote = try aliceProtected.createNote(
      notebookTitle: "Alice protected comments",
      bodyMarkdown: "# Alice protected\nMembership can be revoked."
    )
    _ = try aliceProtected.applyTags(
      noteId: aliceNote.noteId,
      tags: [NoteTagInput(name: aliceTag.name)],
      provenance: .human,
      assignedBy: "test"
    )
    _ = try aliceProtected.addComment(noteId: aliceNote.noteId, bodyMarkdown: "revoked member comment")
    try service.revokeLibraryAccess(libraryName: aliceLibrary.name, userId: alice.userId)

    XCTAssertEqual(try aliceService.listTagComments(tagId: aliceTag.tagId), [])
    XCTAssertEqual(try aliceService.tagDetail(tagId: aliceTag.tagId).noteCount, 0)
  }

  func testListTagCommentsExcludesTagMemoNotebookAndPaginates() throws {
    let service = try makeService()
    let tag = try service.defineTag(name: "kishida")
    let tagged = try service.createNote(
      notebookTitle: "Book",
      bodyMarkdown: "# Tagged\nkishida"
    )
    _ = try service.applyTags(
      noteId: tagged.noteId,
      tags: [NoteTagInput(name: "kishida")],
      provenance: .human,
      assignedBy: "test"
    )
    let memoNotebook = try service.ensureTagMemoNotebook(tagId: tag.tagId)
    _ = try service.addNotebookComment(
      notebookId: memoNotebook.notebookId,
      bodyMarkdown: "tag memo (must not appear in history)",
      author: "user"
    )
    let first = try service.addComment(noteId: tagged.noteId, bodyMarkdown: "first", author: "user")
    let second = try service.addComment(noteId: tagged.noteId, bodyMarkdown: "second", author: "user")

    let all = try service.listTagComments(tagId: tag.tagId)
    XCTAssertEqual(Set(all.map(\.comment.commentId)), [first.commentId, second.commentId])

    let page = try service.listTagComments(tagId: tag.tagId, limit: 1, offset: 1)
    XCTAssertEqual(page.count, 1)

    XCTAssertThrowsError(try service.listTagComments(tagId: tag.tagId, limit: 201))
  }

  func testEnsureTagMemoNotebookIsIdempotentAndBound() throws {
    let service = try makeService()
    let tag = try service.defineTag(name: "yamada")

    let created = try service.ensureTagMemoNotebook(tagId: tag.tagId)
    let again = try service.ensureTagMemoNotebook(tagId: tag.tagId)

    XCTAssertEqual(created.notebookId, again.notebookId)
    XCTAssertEqual(created.title, "Tag: yamada")
    let kindTag = created.tags.first {
      $0.tag.name == NoteStoreSchema.tagMemoNotebookKindTag
    }
    XCTAssertNotNil(kindTag, "memo notebook must carry the tag-memo kind tag")
    XCTAssertEqual(try service.tagMemoSubjectTagId(notebookId: created.notebookId), tag.tagId)
    XCTAssertEqual(try service.tagDetail(tagId: tag.tagId).memoNotebookId, created.notebookId)
    XCTAssertThrowsError(try service.tagMemoSubjectTagId(notebookId: NotebookID("notebook-missing"))) { error in
      guard case .notFound = error as? NoteServiceError else {
        return XCTFail("expected notFound, got \(error)")
      }
    }
  }

  func testTagMemoInheritsNotebookTagLibraryAndRejectsMixedTagSources() throws {
    let service = try makeService()
    let protectedLibrary = try service.createLibrary(
      name: "protected-notebook-tag-memo",
      authRequired: true
    )
    let protectedService = service.scoped(toLibrary: protectedLibrary.libraryId)
    let protectedNotebook = try protectedService.createNotebook(title: "Protected notebook tag")
    let protectedTag = try service.defineTag(name: "protected-notebook-tag-source")
    _ = try protectedService.applyNotebookTags(
      notebookId: protectedNotebook.notebookId,
      tags: [protectedTag.name],
      provenance: .human,
      assignedBy: "test"
    )

    let protectedMemo = try protectedService.ensureTagMemoNotebook(tagId: protectedTag.tagId)
    XCTAssertEqual(protectedMemo.libraryId, protectedLibrary.libraryId)
    let unauthenticated = service.scoped(to: NoteStoreSchema.defaultUserId).unauthenticated()
    XCTAssertThrowsError(try unauthenticated.getNotebook(protectedMemo.notebookId)) { error in
      guard case .notFound = error as? NoteServiceError else {
        return XCTFail("expected notFound, got \(error)")
      }
    }

    let mixedTag = try service.defineTag(name: "mixed-notebook-tag-source")
    let openNotebook = try service.createNotebook(title: "Open notebook tag")
    _ = try service.applyNotebookTags(
      notebookId: openNotebook.notebookId,
      tags: [mixedTag.name],
      provenance: .human,
      assignedBy: "test"
    )
    _ = try protectedService.applyNotebookTags(
      notebookId: protectedNotebook.notebookId,
      tags: [mixedTag.name],
      provenance: .human,
      assignedBy: "test"
    )
    XCTAssertThrowsError(try service.ensureTagMemoNotebook(tagId: mixedTag.tagId)) { error in
      guard case .invalidInput = error as? NoteServiceError else {
        return XCTFail("expected invalidInput, got \(error)")
      }
    }
  }

  func testTagMemoKeepsIdentityWhenTaggedSourceMovesLibraries() throws {
    let service = try makeService()
    let defaultService = service.scoped(to: NoteStoreSchema.defaultUserId)
    let tag = try service.defineTag(name: "moving-tag-memo-source")
    let source = try defaultService.createNote(
      notebookTitle: "Moving tag source",
      bodyMarkdown: "# Source\nMoves between libraries."
    )
    _ = try defaultService.applyTags(
      noteId: source.noteId,
      tags: [NoteTagInput(name: tag.name)],
      provenance: .human,
      assignedBy: "test"
    )
    let originalMemo = try defaultService.ensureTagMemoNotebook(tagId: tag.tagId)
    XCTAssertEqual(originalMemo.libraryId, NoteStoreSchema.defaultLibraryId)

    let protectedLibrary = try defaultService.createLibrary(
      name: "moved-tag-memo-source",
      authRequired: true
    )
    _ = try defaultService.moveNotebook(source.notebookId, toLibrary: protectedLibrary.name)
    let protectedService = defaultService.scoped(toLibrary: protectedLibrary.libraryId)

    let movedMemo = try protectedService.ensureTagMemoNotebook(tagId: tag.tagId)
    XCTAssertEqual(movedMemo.notebookId, originalMemo.notebookId)
    XCTAssertEqual(movedMemo.libraryId, protectedLibrary.libraryId)
    XCTAssertEqual(
      try protectedService.tagDetail(tagId: tag.tagId).memoNotebookId,
      originalMemo.notebookId
    )
    let memoRows = try service.driver.withDatabase { database in
      try database.query(
        "SELECT notebook_id FROM notebooks WHERE json_extract(meta_json, '$.kaibaTagMemo.subjectTagId') = ?",
        bindings: [.id(tag.tagId)]
      )
    }
    XCTAssertEqual(memoRows.count, 1)
  }

  func testTagMemoRetainsProtectedLibraryWhenFinalTaggedSourceIsRemoved() throws {
    let service = try makeService()
    let defaultService = service.scoped(to: NoteStoreSchema.defaultUserId)
    let protectedLibrary = try defaultService.createLibrary(
      name: "removed-tag-memo-source",
      authRequired: true
    )
    let protectedService = defaultService.scoped(toLibrary: protectedLibrary.libraryId)
    let tag = try service.defineTag(name: "removed-tag-memo-source")
    let source = try protectedService.createNote(
      notebookTitle: "Protected tagged source",
      bodyMarkdown: "# Protected\nThis tag is removed after memo creation."
    )
    _ = try protectedService.applyTags(
      noteId: source.noteId,
      tags: [NoteTagInput(name: tag.name)],
      provenance: .human,
      assignedBy: "test"
    )
    let original = try protectedService.ensureTagMemoNotebook(tagId: tag.tagId)

    _ = try protectedService.removeTag(
      noteId: source.noteId,
      tagName: tag.name,
      removedBy: .human
    )
    let retained = try defaultService.ensureTagMemoNotebook(tagId: tag.tagId)

    XCTAssertEqual(retained.notebookId, original.notebookId)
    XCTAssertEqual(retained.libraryId, protectedLibrary.libraryId)
    let unauthenticated = defaultService.unauthenticated()
    XCTAssertThrowsError(try unauthenticated.getNotebook(retained.notebookId)) { error in
      guard case .notFound = error as? NoteServiceError else {
        return XCTFail("expected protected memo to remain hidden, got \(error)")
      }
    }
  }

  func testTagMemoDoesNotRehomeAfterAccessToExistingMemoLibraryIsRevoked() throws {
    let service = try makeService()
    let alice = try service.createUser(email: "memo-race-alice@example.com", displayName: "Alice")
    let aliceService = service.scoped(to: alice.userId)
    let privateLibrary = try aliceService.createLibrary(
      name: "revoked-tag-memo-source",
      authRequired: true
    )
    let privateService = aliceService.scoped(toLibrary: privateLibrary.libraryId)
    let tag = try service.defineTag(name: "revoked-tag-memo")
    let source = try privateService.createNote(
      notebookTitle: "Private tag source",
      bodyMarkdown: "# Private\nMoves after memo creation."
    )
    _ = try privateService.applyTags(
      noteId: source.noteId,
      tags: [NoteTagInput(name: tag.name)],
      provenance: .human,
      assignedBy: "test"
    )
    let memo = try privateService.ensureTagMemoNotebook(tagId: tag.tagId)
    _ = try aliceService.moveNotebook(source.notebookId, toLibrary: "default")
    try service.revokeLibraryAccess(libraryName: privateLibrary.name, userId: alice.userId)

    XCTAssertThrowsError(try aliceService.ensureTagMemoNotebook(tagId: tag.tagId)) { error in
      guard case .notFound = error as? NoteServiceError else {
        return XCTFail("expected inaccessible memo to be notFound, got \(error)")
      }
    }
    XCTAssertNil(try aliceService.tagDetail(tagId: tag.tagId).memoNotebookId)
    let persistedLibraryId = try service.driver.withDatabase { database in
      try database.query(
        "SELECT library_id FROM notebooks WHERE notebook_id = ?",
        bindings: [.id(memo.notebookId)]
      ).first?.identifier("library_id", as: LibraryID.self)
    }
    XCTAssertEqual(persistedLibraryId, privateLibrary.libraryId)
  }

  func testTagMemoNotebookIsOwnedPerScopedAccount() throws {
    let service = try makeService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let bob = try service.createUser(email: "bob@example.com", displayName: "Bob")
    let tag = try service.defineTag(name: "shared-memo")
    let aliceService = service.scoped(to: alice.userId)
    let bobService = service.scoped(to: bob.userId)

    let aliceMemo = try aliceService.ensureTagMemoNotebook(tagId: tag.tagId)
    XCTAssertEqual(try aliceService.tagDetail(tagId: tag.tagId).memoNotebookId, aliceMemo.notebookId)
    XCTAssertNil(try bobService.tagDetail(tagId: tag.tagId).memoNotebookId)
    XCTAssertEqual(try aliceService.ensureTagMemoNotebook(tagId: tag.tagId).notebookId, aliceMemo.notebookId)

    let bobMemo = try bobService.ensureTagMemoNotebook(tagId: tag.tagId)
    XCTAssertNotEqual(aliceMemo.notebookId, bobMemo.notebookId)
    XCTAssertEqual(bobMemo.ownerUserId, bob.userId)
    XCTAssertEqual(try bobService.tagDetail(tagId: tag.tagId).memoNotebookId, bobMemo.notebookId)
    XCTAssertEqual(try service.tagDetail(tagId: tag.tagId).memoNotebookId, aliceMemo.notebookId)
  }

  func testTagMemoSubjectRequiresNotebookOwnershipAndLibraryReach() throws {
    let service = try makeService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let bob = try service.createUser(email: "bob@example.com", displayName: "Bob")
    let tag = try service.defineTag(name: "memo-access")
    let aliceService = service.scoped(to: alice.userId)
    let bobService = service.scoped(to: bob.userId)
    let aliceMemo = try aliceService.ensureTagMemoNotebook(tagId: tag.tagId)

    XCTAssertThrowsError(try bobService.tagMemoSubjectTagId(notebookId: aliceMemo.notebookId)) { error in
      guard case .notFound = error as? NoteServiceError else {
        return XCTFail("expected foreign memo to be notFound, got \(error)")
      }
    }

    let privateTag = try service.defineTag(name: "memo-private-access")
    let privateLibrary = try aliceService.createLibrary(name: "memo-private", authRequired: true)
    let privateMemo = try aliceService.scoped(toLibrary: privateLibrary.libraryId)
      .ensureTagMemoNotebook(tagId: privateTag.tagId)
    try service.revokeLibraryAccess(libraryName: privateLibrary.name, userId: alice.userId)

    XCTAssertThrowsError(try aliceService.tagMemoSubjectTagId(notebookId: privateMemo.notebookId)) { error in
      guard case .notFound = error as? NoteServiceError else {
        return XCTFail("expected inaccessible memo to be notFound, got \(error)")
      }
    }
  }

  func testEnsureTagMemoNotebookIsAtomicForConcurrentCallers() async throws {
    let observer = TagDetailChangeObserver()
    let dispatcher = TagDetailRecordingDispatcher()
    let service = try NoteService(
      driver: makeNoteDriver(), autoActionDispatcher: dispatcher, changeObserver: observer
    )
    let tag = try service.defineTag(name: "concurrent-tag-memo")
    _ = try service.configureAutoAction(
      actionId: AutoActionID("tag-memo-created"),
      trigger: .notebookCreated,
      workflowId: WorkflowID("tag-memo-workflow"),
      filterJSON: #"{"notebookKindTag":"notebook-kind:tag-memo"}"#
    )

    let notebooks = try await withThrowingTaskGroup(of: Notebook.self) { group in
      for _ in 0..<16 {
        group.addTask { try service.ensureTagMemoNotebook(tagId: tag.tagId) }
      }
      var values: [Notebook] = []
      for try await notebook in group {
        values.append(notebook)
      }
      return values
    }

    let ids = Set(notebooks.map(\.notebookId))
    XCTAssertEqual(ids.count, 1)
    let persisted = try service.driver.withDatabase { database in
      try database.query(
        "SELECT notebook_id FROM notebooks WHERE json_extract(meta_json, '$.kaibaTagMemo.subjectTagId') = ?",
        bindings: [.id(tag.tagId)]
      )
    }
    XCTAssertEqual(persisted.count, 1)
    XCTAssertEqual(
      observer.events.filter { $0.kind == NoteChangeEventKind.notebookCreated }.count,
      1
    )
    await service.drainAutoActionDispatches()
    XCTAssertEqual(
      dispatcher.records().filter { $0.action.actionId == AutoActionID("tag-memo-created") }.count,
      1
    )
  }

  func testEnsureTagMemoNotebookRollsBackWhenKindTagCreationFails() throws {
    let service = try makeService()
    let tag = try service.defineTag(name: "rollback-tag-memo")
    try service.driver.withDatabase { database in
      try database.execute(
        """
        INSERT INTO tags (tag_id, name, class_id, is_system, created_at)
        VALUES (?, ?, 'topic', 0, ?)
        """,
        bindings: [.text("conflicting-tag-memo-kind"), .text(NoteStoreSchema.tagMemoNotebookKindTag), .text("2026-08-13T00:00:00Z")]
      )
    }

    XCTAssertThrowsError(try service.ensureTagMemoNotebook(tagId: tag.tagId))
    let notebooks = try service.driver.withDatabase { database in
      try database.query(
        "SELECT notebook_id FROM notebooks WHERE json_extract(meta_json, '$.kaibaTagMemo.subjectTagId') = ?",
        bindings: [.id(tag.tagId)]
      )
    }
    XCTAssertTrue(notebooks.isEmpty)
  }

  func testTagContextMarkdownGroundsOnTaggedNotes() throws {
    let service = try makeService()
    let tag = try service.defineTag(name: "meiji", classId: TagClassID("topic"))
    let tagged = try service.createNote(
      notebookTitle: "History",
      bodyMarkdown: "# Meiji Era\nThe restoration began."
    )
    _ = try service.applyTags(
      noteId: tagged.noteId,
      tags: [NoteTagInput(name: "meiji")],
      provenance: .human,
      assignedBy: "test"
    )
    _ = try service.createNote(
      notebookTitle: "Unrelated",
      bodyMarkdown: "# Other\nNot about the era."
    )

    let context = try service.tagContextMarkdown(tagId: tag.tagId)

    XCTAssertTrue(context.hasPrefix("# Tag: meiji (topic)"))
    XCTAssertTrue(context.contains("The restoration began."))
    XCTAssertFalse(context.contains("Not about the era."))
  }

  func testTagContextMarkdownHonorsUTF8ByteBudgetAtScalarBoundaries() throws {
    let service = try makeService()
    let tag = try service.defineTag(name: "日本語")
    let tagged = try service.createNote(notebookTitle: "Book", bodyMarkdown: "😀日本語ABC")
    _ = try service.applyTags(
      noteId: tagged.noteId,
      tags: [NoteTagInput(name: tag.name)],
      provenance: .human,
      assignedBy: "test"
    )

    for limit in [0, 1, 8, 12, 18, 24, 32] {
      let context = try service.tagContextMarkdown(tagId: tag.tagId, limitBytes: limit)
      XCTAssertLessThanOrEqual(context.utf8.count, limit)
      XCTAssertNotNil(String(data: Data(context.utf8), encoding: .utf8))
    }

    let fullHeading = "# Tag: 日本語"
    let truncatedHeading = try service.tagContextMarkdown(
      tagId: tag.tagId,
      limitBytes: fullHeading.utf8.count - 1
    )
    XCTAssertLessThanOrEqual(truncatedHeading.utf8.count, fullHeading.utf8.count - 1)
    XCTAssertTrue(fullHeading.hasPrefix(truncatedHeading))
    let bounded = try service.tagContextMarkdown(tagId: tag.tagId, limitBytes: fullHeading.utf8.count + 10)
    XCTAssertFalse(bounded.contains("\u{FFFD}"))
  }
}
