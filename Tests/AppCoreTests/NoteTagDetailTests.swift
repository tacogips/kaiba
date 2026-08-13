import Foundation
@testable import AppCore
import XCTest

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
}
