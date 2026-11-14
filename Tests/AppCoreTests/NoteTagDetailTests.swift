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
    _ = try service.defineTagClass(classId: "person-test", label: "Person Test")
    let parent = try service.defineTag(name: "tanaka", classId: "person-test")
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
    XCTAssertEqual(detail.tagClass?.classId, "person-test")
    XCTAssertEqual(detail.noteCount, 2, "parent tag must count descendant-tagged notes")
    XCTAssertEqual(detail.notebookCount, 1)
    XCTAssertNil(detail.memoNotebookId, "no memo notebook exists before ensure")
    _ = child
  }

  func testTagDetailRejectsUnknownTag() throws {
    let service = try makeService()
    XCTAssertThrowsError(try service.tagDetail(tagId: "tag-missing")) { error in
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
    XCTAssertNil(try service.tagMemoSubjectTagId(notebookId: "notebook-missing"))
  }

  func testEnsureTagMemoNotebookIsAtomicForConcurrentCallers() async throws {
    let observer = TagDetailChangeObserver()
    let dispatcher = TagDetailRecordingDispatcher()
    let service = try NoteService(
      driver: makeNoteDriver(), autoActionDispatcher: dispatcher, changeObserver: observer
    )
    let tag = try service.defineTag(name: "concurrent-tag-memo")
    _ = try service.configureAutoAction(
      actionId: "tag-memo-created",
      trigger: .notebookCreated,
      workflowId: "tag-memo-workflow",
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
        bindings: [.text(tag.tagId)]
      )
    }
    XCTAssertEqual(persisted.count, 1)
    XCTAssertEqual(
      observer.events.filter { $0.kind == NoteChangeEventKind.notebookCreated }.count,
      1
    )
    await service.drainAutoActionDispatches()
    XCTAssertEqual(
      dispatcher.records().filter { $0.action.actionId == "tag-memo-created" }.count,
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
        bindings: [.text(tag.tagId)]
      )
    }
    XCTAssertTrue(notebooks.isEmpty)
  }

  func testTagContextMarkdownGroundsOnTaggedNotes() throws {
    let service = try makeService()
    let tag = try service.defineTag(name: "meiji", classId: "topic")
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
