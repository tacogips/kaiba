import Foundation
import AppCore
import XCTest

final class NoteServiceNotebookExpansionTests: NoteTestCase {
  func testCompactMetadataPreservesSiblingsAndSourceUpdatedAt() throws {
    let service = try makeService()
    let notebook = try service.createNotebook(
      title: "Plan",
      metaJSON: #"{"other":{"keep":true},"kaibaNote":{"existing":"value"}}"#
    )
    _ = try service.createNote(notebookId: notebook.notebookId, bodyMarkdown: "# Milestone\nDraft it.")
    let before = try service.getNotebookForExpansion(notebook.notebookId)

    let updated = try XCTUnwrap(service.updateNotebookCompactMetadata(
      notebookId: notebook.notebookId,
      compactMetadataJSON: #"{"version":1,"summaryMarkdown":"- Draft it","computedAt":"2026-07-21T00:00:00.000Z","sourceNoteIds":["note-1"],"source":{"updatedAt":"marker","noteCount":1}}"#,
      expectedUpdatedAt: before.updatedAt,
      expectedNoteCount: before.noteCount ?? 0
    ))

    XCTAssertEqual(updated.updatedAt, before.updatedAt)
    let root = try XCTUnwrap(jsonObject(updated.metaJSON))
    XCTAssertEqual(root["other"]?["keep"]?.asBool, true)
    XCTAssertEqual(root["kaibaNote"]?["existing"]?.asString, "value")
    XCTAssertNotNil(root["kaibaNote"]?["notebookCompact"])
  }

  func testCompactMetadataRejectsNonObjectJSONWithoutMutation() throws {
    let service = try makeService()
    let notebook = try service.createNotebook(title: "Plan", metaJSON: #"{"keep":true}"#)

    XCTAssertThrowsError(try service.updateNotebookCompactMetadata(
      notebookId: notebook.notebookId,
      compactMetadataJSON: "[]",
      expectedUpdatedAt: notebook.updatedAt,
      expectedNoteCount: 0
    ))
    XCTAssertEqual(try service.getNotebook(notebook.notebookId).metaJSON, notebook.metaJSON)
  }

  func testCompactMetadataRejectsNonObjectKaibaNoteNamespaceWithoutMutation() throws {
    let service = try makeService()
    let notebook = try service.createNotebook(
      title: "Plan",
      metaJSON: #"{"keep":true,"kaibaNote":"reserved-user-value"}"#
    )

    XCTAssertThrowsError(try service.updateNotebookCompactMetadata(
      notebookId: notebook.notebookId,
      compactMetadataJSON: #"{"version":1}"#,
      expectedUpdatedAt: notebook.updatedAt,
      expectedNoteCount: 0
    ))

    XCTAssertEqual(try service.getNotebook(notebook.notebookId).metaJSON, notebook.metaJSON)
  }

  func testCompactMetadataCompareAndSetRejectsSourceMutationBeforeWrite() throws {
    let service = try makeService()
    let source = try service.createNote(bodyMarkdown: "Initial source")
    let expected = try service.getNotebookForExpansion(source.notebookId)

    _ = try service.createNote(notebookId: source.notebookId, bodyMarkdown: "Concurrent source")
    let published = try service.updateNotebookCompactMetadata(
      notebookId: source.notebookId,
      compactMetadataJSON: #"{"version":1,"summaryMarkdown":"stale"}"#,
      expectedUpdatedAt: expected.updatedAt,
      expectedNoteCount: expected.noteCount ?? 0
    )

    XCTAssertNil(published)
    XCTAssertNil(try service.getNotebook(source.notebookId).metaJSON)
  }

  func testConversationSourceLinksAreAIProvenanceAndAtomic() throws {
    let service = try makeService()
    let source = try service.createNotebookWithNotes(
      title: "Source",
      pages: [
        NotePageDraft(bodyMarkdown: "# One\nFirst"),
        NotePageDraft(bodyMarkdown: "# Two\nSecond")
      ]
    )
    let sourceIds = source.notes.map(\.noteId)
    let saved = try service.saveConversation(
      title: "Expansion",
      transcript: [NoteConversationTurn(userMarkdown: "Expand", assistantMarkdown: "- Summary")],
      notebookMetaJSON: #"{"kaibaNote":{"notebookExpansion":{"version":1}}}"#,
      sourceLinks: NoteConversationSourceLinks(sourceNoteIds: sourceIds),
      assignedBy: "test"
    )
    let seed = try XCTUnwrap(saved.notes.first)
    let seedLinks = try service.listLinks(noteId: seed.noteId)

    XCTAssertEqual(Set(seedLinks.map(\.toNoteId)), Set(sourceIds))
    XCTAssertTrue(seedLinks.allSatisfy { $0.linkKind == "source-citation" && $0.provenance == .ai })
    XCTAssertNotNil(saved.notebook.metaJSON)

    let later = try service.appendConversationTurn(
      notebookId: saved.notebook.notebookId,
      turn: NoteConversationTurn(userMarkdown: "Next?", assistantMarkdown: "Do it."),
      sourceLinks: NoteConversationSourceLinks(sourceNoteIds: sourceIds)
    )
    XCTAssertEqual(Set(try service.listLinks(noteId: later.noteId).map(\.toNoteId)), Set(sourceIds))

    let notebookCount = try service.listNotebooks(limit: 100).count
    XCTAssertThrowsError(try service.saveConversation(
      title: "Broken",
      transcript: [NoteConversationTurn(userMarkdown: "Q", assistantMarkdown: "A")],
      sourceLinks: NoteConversationSourceLinks(sourceNoteIds: [NoteID("missing-note")])
    ))
    XCTAssertEqual(try service.listNotebooks(limit: 100).count, notebookCount)

    let countsBeforeInjectedFailure = try databaseCounts(service)
    try service.driver.withDatabase { database in
      try database.execute(
        """
        CREATE TRIGGER fail_notebook_expansion_link_insert
        BEFORE INSERT ON note_links
        WHEN NEW.provenance = 'ai'
        BEGIN
          SELECT RAISE(ABORT, 'injected notebook expansion link failure');
        END
        """
      )
    }

    XCTAssertThrowsError(try service.saveConversation(
      title: "Injected link failure",
      transcript: [NoteConversationTurn(userMarkdown: "Q", assistantMarkdown: "A")],
      sourceLinks: NoteConversationSourceLinks(sourceNoteIds: sourceIds)
    ))
    XCTAssertEqual(try databaseCounts(service), countsBeforeInjectedFailure)
  }

  func testExpansionTurnPersistenceIsIdempotentAndSurvivesDeletedSources() throws {
    let service = try makeService()
    let source = try service.createNote(bodyMarkdown: "Source")
    let saved = try service.saveConversation(
      title: "Expansion",
      transcript: [NoteConversationTurn(userMarkdown: "Expand", assistantMarkdown: "Summary")],
      sourceLinks: NoteConversationSourceLinks(sourceNoteIds: [source.noteId])
    )
    try service.deleteNote(noteId: source.noteId)
    let links = NoteConversationSourceLinks(
      sourceNoteIds: [source.noteId],
      allowMissingSourceNotes: true
    )

    let first = try service.appendConversationTurn(
      notebookId: saved.notebook.notebookId,
      turn: NoteConversationTurn(userMarkdown: "Next?", assistantMarkdown: "Answer"),
      sourceLinks: links,
      idempotencyKey: "expansion-turn-1"
    )
    let retry = try service.appendConversationTurn(
      notebookId: saved.notebook.notebookId,
      turn: NoteConversationTurn(userMarkdown: "Next?", assistantMarkdown: "Answer"),
      sourceLinks: links,
      idempotencyKey: "expansion-turn-1"
    )

    XCTAssertEqual(retry.noteId, first.noteId)
    XCTAssertEqual(
      try service.listNotes(notebookId: saved.notebook.notebookId, limit: 100).count,
      2
    )
    XCTAssertTrue(try service.listLinks(noteId: first.noteId).isEmpty)
    let metadata = try XCTUnwrap(jsonObject(first.metaJSON))
    let turn = try XCTUnwrap(metadata["kaibaNote"]?["conversationTurn"])
    XCTAssertEqual(turn["idempotencyKey"]?.asString, "expansion-turn-1")
    XCTAssertEqual(turn["missingSourceNoteIds"], .ids([source.noteId]))
  }

  private func databaseCounts(_ service: NoteService) throws -> [String: Int] {
    try service.driver.withDatabase { database in
      var counts: [String: Int] = [:]
      for table in ["notebooks", "notes", "note_links"] {
        let value = try database.query("SELECT COUNT(*) AS count FROM \(table)").first?["count"]
        counts[table] = value.flatMap(Int.init) ?? -1
      }
      return counts
    }
  }

  private func jsonObject(_ json: String?) -> JSONValue? {
    guard let json else {
      return nil
    }
    return try? JSONValue(parsing: json)
  }
}
