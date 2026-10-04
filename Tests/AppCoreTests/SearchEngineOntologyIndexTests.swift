import Foundation
@testable import AppCore
import XCTest

final class SearchEngineOntologyIndexTests: NoteTestCase {
  func testSearchIndexDocumentIncludesOntologyPathsAndLinks() throws {
    let service = try makeService()
    let root = try service.defineTag(name: "ontology-root", classId: .folder)
    let parent = try service.defineTag(name: "ontology-parent", classId: .event, parentTagId: root.tagId)
    let child = try service.defineTag(name: "ontology-child", classId: .person, parentTagId: parent.tagId)
    let subject = try service.createNote(bodyMarkdown: "subject")
    try service.applyTags(noteId: subject.noteId, tags: [NoteTagInput(name: child.name)], provenance: .ai)
    let systemTagId = try service.driver.withDatabase { database in
      guard let tagId = try database.query("SELECT tag_id FROM tags WHERE is_system = 1 ORDER BY tag_id LIMIT 1")
        .first?.identifier("tag_id", as: TagID.self) else {
        throw NoteServiceError.invalidInput("seeded system tag missing")
      }
      try database.execute(
        "INSERT INTO note_tags (note_id, tag_id, provenance, deletable, created_at) VALUES (?, ?, 'system', 0, ?)",
        bindings: [.id(subject.noteId), .id(tagId), .text(NoteStoreClock.system.now())]
      )
      return tagId
    }
    let outgoing = try service.createNote(bodyMarkdown: "outgoing")
    let incoming = try service.createNote(bodyMarkdown: "incoming")
    try service.linkNotes(from: subject.noteId, to: outgoing.noteId)
    try service.linkNotes(from: incoming.noteId, to: subject.noteId)

    let document = try service.driver.withDatabase { database in
      try XCTUnwrap(searchIndexDocument(noteId: subject.noteId, in: database))
    }

    XCTAssertEqual(
      Dictionary(uniqueKeysWithValues: document.tagApplications.map { ($0.tagId, $0.provenance) }),
      [child.tagId: "ai", systemTagId: "system"]
    )
    XCTAssertEqual(Set(document.pathTags.map(\.tagId)), Set([root.tagId, parent.tagId, child.tagId, systemTagId]))
    XCTAssertEqual(Set(document.pathTags.filter(\.isDirect).map(\.tagId)), Set([child.tagId, systemTagId]))
    XCTAssertTrue(document.tagApplications.contains { $0.tagId == systemTagId && $0.provenance == "system" })
    XCTAssertEqual(
      Dictionary(uniqueKeysWithValues: document.pathTags.map { ($0.tagId, $0.tagClass) }),
      [
        root.tagId: TagClassID.folder.rawValue,
        parent.tagId: TagClassID.event.rawValue,
        child.tagId: TagClassID.person.rawValue,
        systemTagId: TagClassID.documentKind.rawValue
      ]
    )
    XCTAssertEqual(document.outgoingLinkNoteIds, [outgoing.noteId])
    XCTAssertEqual(document.incomingLinkNoteIds, [incoming.noteId])
  }

  func testClassChangesAndEnsureTagClassAssignmentEnqueueSubtrees() throws {
    let service = try makeService()
    let child = try service.defineTag(name: "class-change-child", classId: .person)
    let descendant = try service.defineTag(name: "class-change-descendant", parentTagId: child.tagId)
    let first = try service.createNote(bodyMarkdown: "first", tags: [NoteTagInput(name: child.name)])
    let second = try service.createNote(bodyMarkdown: "second", tags: [NoteTagInput(name: descendant.name)])
    _ = try service.activateSearchEngineSync(indexIdentity: "test:v2")
    try clearOutbox(service)

    _ = try service.defineTag(name: child.name, classId: .event)
    XCTAssertEqual(try outboxNotes(service), Set([first.noteId, second.noteId]))
    try clearOutbox(service)
    _ = try service.defineTag(name: child.name, classId: .event)
    XCTAssertTrue(try outboxNotes(service).isEmpty)

    let classless = try service.defineTag(name: "classless-parent")
    let classlessChild = try service.defineTag(name: "classless-child", parentTagId: classless.tagId)
    let third = try service.createNote(bodyMarkdown: "third", tags: [NoteTagInput(name: classlessChild.name)])
    try clearOutbox(service)
    try service.driver.withDatabase { database in
      try database.transaction { db in
        try ensureTag(NoteTagInput(name: classless.name, classId: .person), in: db)
      }
    }
    XCTAssertEqual(try outboxNotes(service), [third.noteId])
  }

  func testLinkWritesPromotionRestoreAndDeleteEnqueueEndpoints() throws {
    let service = try makeService()
    let source = try service.createNote(bodyMarkdown: "source")
    let target = try service.createNote(bodyMarkdown: "target")
    let third = try service.createNote(bodyMarkdown: "third")
    _ = try service.activateSearchEngineSync(indexIdentity: "test:v2")
    try clearOutbox(service)

    try service.linkNotes(from: source.noteId, to: target.noteId)
    XCTAssertEqual(try outboxNotes(service), Set([source.noteId, target.noteId]))
    try clearOutbox(service)

    let comment = try service.addComment(noteId: source.noteId, bodyMarkdown: "promoted comment")
    try clearOutbox(service)
    let promoted = try service.promoteCommentToNotebook(noteId: source.noteId, commentId: comment.commentId)
    XCTAssertEqual(try outboxNotes(service), Set([source.noteId, promoted.note.noteId]))
    try clearOutbox(service)

    try service.linkNotes(from: source.noteId, to: third.noteId)
    try clearOutbox(service)
    try service.deleteNote(noteId: source.noteId)
    XCTAssertEqual(try outboxNotes(service), Set([source.noteId, target.noteId, third.noteId, promoted.note.noteId]))
    try clearOutbox(service)

    _ = try XCTUnwrap(try service.undoLastAction())
    XCTAssertEqual(try outboxNotes(service), Set([source.noteId, target.noteId, third.noteId, promoted.note.noteId]))
  }

  func testNotebookTagWritesEnqueueEveryNoteInNotebook() throws {
    let service = try makeService()
    let notebook = try service.createNotebook(title: "ontology notebook")
    let first = try service.createNote(notebookId: notebook.notebookId, bodyMarkdown: "one")
    let second = try service.createNote(notebookId: notebook.notebookId, bodyMarkdown: "two")
    let tag = try service.defineTag(name: "notebook-ontology-tag")
    _ = try service.activateSearchEngineSync(indexIdentity: "test:v2")
    let expected = Set([first.noteId, second.noteId])

    try service.applyNotebookTags(notebookId: notebook.notebookId, tags: [tag.name], provenance: .human)
    XCTAssertEqual(try outboxNotes(service), expected)
    try clearOutbox(service)
    try service.applyNotebookTagIds(notebookId: notebook.notebookId, tagIds: [tag.tagId], provenance: .human)
    XCTAssertEqual(try outboxNotes(service), expected)
    try clearOutbox(service)
    try service.removeNotebookTag(notebookId: notebook.notebookId, tagName: tag.name, removedBy: .human)
    XCTAssertEqual(try outboxNotes(service), expected)
    try clearOutbox(service)
    try service.applyNotebookTagIds(notebookId: notebook.notebookId, tagIds: [tag.tagId], provenance: .human)
    try clearOutbox(service)
    try service.removeNotebookTagById(notebookId: notebook.notebookId, tagId: tag.tagId, removedBy: .human)
    XCTAssertEqual(try outboxNotes(service), expected)
  }

  func testOntologyAndLinkWritesRemainGatedBeforeActivation() throws {
    let service = try makeService()
    let parent = try service.defineTag(name: "inactive-parent")
    let child = try service.defineTag(name: "inactive-child", parentTagId: parent.tagId)
    let first = try service.createNote(bodyMarkdown: "first", tags: [NoteTagInput(name: child.name)])
    let second = try service.createNote(bodyMarkdown: "second")
    _ = try service.defineTag(name: parent.name, classId: .person)
    try service.linkNotes(from: first.noteId, to: second.noteId)
    let notebook = try service.createNotebook(title: "inactive notebook")
    try service.applyNotebookTags(notebookId: notebook.notebookId, tags: ["inactive-notebook-tag"], provenance: .human)
    XCTAssertEqual(try outboxCount(service), 0)
  }

  private func clearOutbox(_ service: NoteService) throws {
    try service.driver.withDatabase { database in
      try database.execute("DELETE FROM search_index_outbox")
    }
  }

  private func outboxNotes(_ service: NoteService) throws -> Set<NoteID> {
    try service.driver.withDatabase { database in
      Set(try database.query("SELECT note_id FROM search_index_outbox").compactMap {
        $0.identifier("note_id", as: NoteID.self)
      })
    }
  }

  private func outboxCount(_ service: NoteService) throws -> Int {
    try service.driver.withDatabase { database in
      Int(try database.query("SELECT count(*) AS count FROM search_index_outbox").first?["count"] ?? "0") ?? 0
    }
  }
}
