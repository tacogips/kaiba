import Foundation
@testable import AppCore
import XCTest

final class NoteLongTermMemoryTests: NoteTestCase {
  func testBootstrapCreatesOneCanonicalNotebookAndIsIdempotent() throws {
    let root = try makeNoteRoot(function: #function)
    let driver = SQLiteNoteDatabaseDriver(noteRoot: root)
    let firstService = try NoteService(driver: driver)
    let first = try firstService.longTermMemoryNotebook()

    XCTAssertEqual(first.title, "Kaiba Long-Term Memory")
    XCTAssertFalse(first.readOnly)
    XCTAssertTrue(first.tags.contains { $0.tag.name == NoteStoreSchema.longTermMemoryNotebookKindTag })

    let secondService = try NoteService(driver: driver)
    let second = try secondService.longTermMemoryNotebook()
    XCTAssertEqual(second.notebookId, first.notebookId)
    XCTAssertEqual(
      try secondService.listNotebooks().filter {
        $0.tags.contains { $0.tag.name == NoteStoreSchema.longTermMemoryNotebookKindTag }
      }.count,
      1
    )
  }

  func testPublicNotebookKindPathsCannotCreateSecondLongTermMemoryIdentity() throws {
    let root = try makeNoteRoot(function: #function)
    let driver = SQLiteNoteDatabaseDriver(noteRoot: root)
    let service = try NoteService(driver: driver)
    let canonical = try service.longTermMemoryNotebook()
    let reservedTag = NoteStoreSchema.longTermMemoryNotebookKindTag

    XCTAssertReservedLongTermMemoryTag {
      try service.createNotebook(title: "Blocked notebook", kindTagName: reservedTag)
    }
    XCTAssertReservedLongTermMemoryTag {
      try service.createNote(
        notebookTitle: "Blocked note notebook",
        notebookKindTagName: reservedTag,
        bodyMarkdown: "Blocked note"
      )
    }
    XCTAssertReservedLongTermMemoryTag {
      try service.createNotebookWithNotes(
        title: "Blocked ingest notebook",
        kindTagName: reservedTag,
        pages: [NotePageDraft(bodyMarkdown: "Blocked page")]
      )
    }
    let ordinary = try service.createNotebook(title: "Ordinary notebook")
    XCTAssertReservedLongTermMemoryTag {
      try service.applyNotebookTags(
        notebookId: ordinary.notebookId,
        tags: [reservedTag],
        provenance: .human
      )
    }
    let reservedTagId = try XCTUnwrap(service.listTags().first { $0.name == reservedTag }?.tagId)
    XCTAssertReservedLongTermMemoryTag {
      try service.applyNotebookTagIds(
        notebookId: ordinary.notebookId,
        tagIds: [reservedTagId],
        provenance: .human
      )
    }

    XCTAssertEqual(
      try service.listNotebooks(tagFilterIdGroups: [[reservedTagId]]).map(\.notebookId),
      [canonical.notebookId]
    )
    let reopened = try NoteService(driver: driver)
    XCTAssertEqual(try reopened.longTermMemoryNotebook().notebookId, canonical.notebookId)
  }

  func testBootstrapRejectsMultipleLongTermMemoryTaggedNotebooks() throws {
    let root = try makeNoteRoot(function: #function)
    let driver = SQLiteNoteDatabaseDriver(noteRoot: root)
    let service = try NoteService(driver: driver)
    let duplicate = try service.createNotebook(title: "Duplicate long-term memory")
    try driver.withDatabase { database in
      try database.execute(
        """
        INSERT INTO notebook_tags (
          notebook_id, tag_id, provenance, assigned_by, deletable, created_at
        )
        SELECT ?, tag_id, 'system', 'test-fixture', 0, '2026-08-01T00:00:00Z'
        FROM tags WHERE name = ? AND class_id = 'document-kind'
        """,
        bindings: [
          .id(duplicate.notebookId),
          .text(NoteStoreSchema.longTermMemoryNotebookKindTag)
        ]
      )
    }

    XCTAssertThrowsError(try NoteService(driver: driver)) { error in
      guard case let NoteServiceError.invalidInput(message) = error else {
        return XCTFail("expected duplicate long-term-memory invariant failure, got \(error)")
      }
      XCTAssertTrue(message.contains("multiple notebooks"))
      XCTAssertTrue(message.contains(NoteStoreSchema.longTermMemoryNotebookKindTag))
    }
  }

  func testBootstrapRejectsNoncanonicalLongTermMemoryAssignment() throws {
    let root = try makeNoteRoot(function: #function)
    let driver = SQLiteNoteDatabaseDriver(noteRoot: root)
    let service = try NoteService(driver: driver)
    let canonical = try service.longTermMemoryNotebook()
    try driver.withDatabase { database in
      try database.execute(
        """
        UPDATE notebook_tags
        SET provenance = 'human', assigned_by = 'user', deletable = 1
        WHERE notebook_id = ?
        """,
        bindings: [.id(canonical.notebookId)]
      )
    }

    XCTAssertThrowsError(try NoteService(driver: driver)) { error in
      guard case let NoteServiceError.invalidInput(message) = error else {
        return XCTFail("expected canonical assignment rejection, got \(error)")
      }
      XCTAssertTrue(message.contains("canonical long-term-memory bootstrap"))
    }
  }

  func testSameNamedFolderDoesNotCollideWithLongTermMemoryIdentity() throws {
    let root = try makeNoteRoot(function: #function)
    let driver = SQLiteNoteDatabaseDriver(noteRoot: root)
    let service = try NoteService(driver: driver)
    let canonical = try service.longTermMemoryNotebook()

    let folderNotebook = try service.createNotebook(
      title: "Reserved display name folder",
      folderPath: [NoteStoreSchema.longTermMemoryNotebookKindTag]
    )
    let folder = try XCTUnwrap(folderNotebook.tags.first?.tag)
    XCTAssertEqual(folder.name, NoteStoreSchema.longTermMemoryNotebookKindTag)
    XCTAssertEqual(folder.classId, TagClassID("folder"))
    XCTAssertNotEqual(folder.tagId, NoteStoreSchema.longTermMemoryNotebookKindTagId)

    let reopened = try NoteService(driver: driver)
    XCTAssertEqual(try reopened.longTermMemoryNotebook().notebookId, canonical.notebookId)
  }

  func testAppendPersistsMetadataTagsAndResolvableSourceAndRelatedLinks() throws {
    let service = try makeService(function: #function)
    let sourceNotebook = try service.createNotebook(title: "Short-term source")
    let source = try service.createNote(
      notebookId: sourceNotebook.notebookId,
      bodyMarkdown: "Standup transcript for the payments migration"
    )
    let related = try service.createNote(
      notebookId: sourceNotebook.notebookId,
      bodyMarkdown: "Design note for the payments migration"
    )
    let periodStart = Date(timeIntervalSince1970: 1_760_000_000)
    let periodEnd = Date(timeIntervalSince1970: 1_760_600_000)

    let result = try service.appendLongTermMemoryNotes(
      [
        LongTermMemoryEntryInput(
          bodyMarkdown: "# Payments migration\n\nThe team converged on a staged cutover.",
          topicTags: ["payments", "migration"],
          sourceNoteIds: [source.noteId, NoteID("note-deleted-source")],
          relatedNoteIds: [related.noteId, NoteID("note-deleted-related")],
          periodStart: periodStart,
          periodEnd: periodEnd,
          metaJSON: #"{"consolidatedBy":"weekly-rollup"}"#
        )
      ],
      idempotencyKey: "payments-week-42"
    )

    XCTAssertFalse(result.idempotentReplay)
    let memory = try XCTUnwrap(result.notes.first)
    XCTAssertEqual(memory.notebookId, try service.longTermMemoryNotebook().notebookId)
    XCTAssertEqual(Set(memory.tags.map(\.tag.name)), ["payments", "migration"])
    XCTAssertTrue(memory.tags.allSatisfy { $0.provenance == .system })
    XCTAssertTrue(memory.tags.allSatisfy { $0.assignedBy == "kaiba-long-term-memory" })

    let metadata = try metaObject(memory)
    XCTAssertEqual(metadata["longTermMemoryVersion"]?.asInt, 1)
    XCTAssertEqual(metadata["entryKind"]?.asString, "long-term-memory")
    XCTAssertEqual(metadata["consolidatedBy"]?.asString, "weekly-rollup")
    XCTAssertEqual(
      metadata["sourceNoteIds"],
      .strings([source.noteId.rawValue, "note-deleted-source"])
    )
    XCTAssertEqual(metadata["unresolvedRelatedNoteIds"], .strings(["note-deleted-related"]))
    XCTAssertEqual(metadata["periodStart"]?.asString, longTermMemoryTimestamp(periodStart))
    XCTAssertEqual(metadata["periodEnd"]?.asString, longTermMemoryTimestamp(periodEnd))

    let links = try service.listLinks(noteId: memory.noteId)
    XCTAssertEqual(
      Set(links.map { LinkFingerprint(link: $0) }),
      [
        LinkFingerprint(to: source.noteId.rawValue, kind: "memory-source", provenance: .system),
        LinkFingerprint(to: related.noteId.rawValue, kind: "related", provenance: .system)
      ]
    )
  }

  func testAppendReplayWithSameKeyReturnsExistingNotesWithoutDuplicating() throws {
    let service = try makeService(function: #function)
    let entries = [
      LongTermMemoryEntryInput(bodyMarkdown: "First consolidated memory", topicTags: ["alpha"]),
      LongTermMemoryEntryInput(bodyMarkdown: "Second consolidated memory", topicTags: ["beta"])
    ]

    let first = try service.appendLongTermMemoryNotes(entries, idempotencyKey: "retry-safe-batch")
    let replay = try service.appendLongTermMemoryNotes(entries, idempotencyKey: "retry-safe-batch")

    XCTAssertFalse(first.idempotentReplay)
    XCTAssertTrue(replay.idempotentReplay)
    XCTAssertEqual(replay.notes.map(\.noteId), first.notes.map(\.noteId))
    XCTAssertEqual(try service.listLongTermMemoryNotes(limit: 50).count, 2)

    let distinct = try service.appendLongTermMemoryNotes(entries, idempotencyKey: "second-batch")
    XCTAssertFalse(distinct.idempotentReplay)
    XCTAssertNotEqual(distinct.notes.map(\.noteId), first.notes.map(\.noteId))
    XCTAssertEqual(try service.listLongTermMemoryNotes(limit: 50).count, 4)
  }

  func testAppendRollsBackTheWholeBatchWhenALaterEntryIsUnusable() throws {
    let service = try makeService(function: #function)

    XCTAssertThrowsError(
      try service.appendLongTermMemoryNotes(
        [
          LongTermMemoryEntryInput(bodyMarkdown: "Persisted only if the batch commits"),
          LongTermMemoryEntryInput(bodyMarkdown: "Broken metadata", metaJSON: "not-json")
        ],
        idempotencyKey: "rollback-batch"
      )
    ) { error in
      guard case let NoteServiceError.invalidInput(message) = error else {
        return XCTFail("expected metadata rejection, got \(error)")
      }
      XCTAssertTrue(message.contains("must encode a JSON object"))
    }

    XCTAssertTrue(try service.listLongTermMemoryNotes(limit: 50).isEmpty)
  }

  func testAppendRejectsEmptyBatchAndReservedTopicTagPrefixes() throws {
    let service = try makeService(function: #function)

    XCTAssertThrowsError(
      try service.appendLongTermMemoryNotes([], idempotencyKey: "empty")
    )
    XCTAssertThrowsError(
      try service.appendLongTermMemoryNotes(
        [LongTermMemoryEntryInput(
          bodyMarkdown: "Reserved tag",
          topicTags: ["notebook-kind:user-memo"]
        )],
        idempotencyKey: "reserved-tag"
      )
    ) { error in
      guard case let NoteServiceError.invalidInput(message) = error else {
        return XCTFail("expected reserved topic tag rejection, got \(error)")
      }
      XCTAssertTrue(message.contains("reserved prefix"))
    }
    XCTAssertThrowsError(
      try service.appendLongTermMemoryNotes(
        [LongTermMemoryEntryInput(bodyMarkdown: "Missing key")],
        idempotencyKey: "   "
      )
    )

    XCTAssertTrue(try service.listLongTermMemoryNotes(limit: 50).isEmpty)
  }

  func testListAppliesPeriodWindowTagFiltersAndClampsLimit() throws {
    let service = try makeService(function: #function)
    let january = Date(timeIntervalSince1970: 1_767_225_600)
    let february = Date(timeIntervalSince1970: 1_769_904_000)
    let march = Date(timeIntervalSince1970: 1_772_323_200)
    _ = try service.appendLongTermMemoryNotes(
      [
        LongTermMemoryEntryInput(
          bodyMarkdown: "January rollup",
          topicTags: ["payments", "rollup"],
          periodStart: january,
          periodEnd: january.addingTimeInterval(86_400)
        ),
        LongTermMemoryEntryInput(
          bodyMarkdown: "February rollup",
          topicTags: ["payments"],
          periodStart: february,
          periodEnd: february.addingTimeInterval(86_400)
        ),
        LongTermMemoryEntryInput(
          bodyMarkdown: "March rollup",
          topicTags: ["rollup"],
          periodStart: march,
          periodEnd: march.addingTimeInterval(86_400)
        )
      ],
      idempotencyKey: "quarterly"
    )

    XCTAssertEqual(try bodies(service.listLongTermMemoryNotes(limit: 50)).count, 3)
    XCTAssertEqual(
      try bodies(service.listLongTermMemoryNotes(periodStart: february, limit: 50)),
      ["March rollup", "February rollup"]
    )
    XCTAssertEqual(
      try bodies(service.listLongTermMemoryNotes(
        periodEnd: february.addingTimeInterval(86_400),
        limit: 50
      )),
      ["February rollup", "January rollup"]
    )
    XCTAssertEqual(
      try bodies(service.listLongTermMemoryNotes(
        tagFilters: ["payments", "rollup"],
        limit: 50
      )),
      ["January rollup"]
    )
    // The batch shares one creation timestamp, so recency ordering falls through
    // to the deterministic id suffix: the last entry appended sorts first.
    XCTAssertEqual(
      try bodies(service.listLongTermMemoryNotes(limit: 0)),
      ["March rollup"]
    )
    XCTAssertEqual(try service.listLongTermMemoryNotes(limit: 10_000).count, 3)
  }

  func testRecallReturnsOnlyLongTermNotesUntilAssociationsAreRequested() throws {
    let service = try makeService(function: #function)
    let sourceNotebook = try service.createNotebook(title: "Short-term source")
    let source = try service.createNote(
      notebookId: sourceNotebook.notebookId,
      bodyMarkdown: "Raw standup log about the payments cutover rehearsal"
    )
    let memory = try XCTUnwrap(
      try service.appendLongTermMemoryNotes(
        [LongTermMemoryEntryInput(
          bodyMarkdown: "Consolidated view of the payments cutover decisions",
          topicTags: ["payments"],
          sourceNoteIds: [source.noteId]
        )],
        idempotencyKey: "payments-recall"
      ).notes.first
    )

    let direct = try service.recallLongTermMemories(query: "payments cutover")
    XCTAssertEqual(direct.map(\.note.noteId), [memory.noteId])
    XCTAssertTrue(direct.allSatisfy { !$0.isAssociation })
    XCTAssertFalse(try XCTUnwrap(direct.first).snippet.isEmpty)

    let expanded = try service.recallLongTermMemories(
      query: "payments cutover",
      includeAssociations: true
    )
    XCTAssertEqual(expanded.first?.note.noteId, memory.noteId)
    let association = try XCTUnwrap(expanded.first { $0.isAssociation })
    XCTAssertEqual(association.note.noteId, source.noteId)
    XCTAssertEqual(association.edgeKind, .explicitLink)
    XCTAssertEqual(association.hopCount, 1)
    XCTAssertEqual(association.pathNoteIds, [memory.noteId, source.noteId])
    XCTAssertEqual(association.weight, association.rank)
  }

  func testRecallFindsNothingForUnrelatedQueries() throws {
    let service = try makeService(function: #function)
    _ = try service.appendLongTermMemoryNotes(
      [LongTermMemoryEntryInput(bodyMarkdown: "Consolidated payments memory")],
      idempotencyKey: "unrelated"
    )

    XCTAssertTrue(try service.recallLongTermMemories(query: "hydroponics").isEmpty)
  }

  func testAssociationLinkingCreatesAiLinksAndSkipsAlreadyLinkedProposals() throws {
    let service = try makeService(function: #function)
    let sourceNotebook = try service.createNotebook(title: "Short-term source")
    let source = try service.createNote(
      notebookId: sourceNotebook.notebookId,
      bodyMarkdown: "Standup log referencing the cutover rehearsal"
    )
    let neighbor = try service.createNote(
      notebookId: sourceNotebook.notebookId,
      bodyMarkdown: "Follow-up ticket opened from that rehearsal"
    )
    _ = try service.linkNotes(from: source.noteId, to: neighbor.noteId)
    let memory = try XCTUnwrap(
      try service.appendLongTermMemoryNotes(
        [LongTermMemoryEntryInput(
          bodyMarkdown: "Consolidated view of the payments cutover decisions",
          sourceNoteIds: [source.noteId]
        )],
        idempotencyKey: "association-linking"
      ).notes.first
    )

    let created = try service.linkLongTermMemoryAssociations(noteId: memory.noteId)
    XCTAssertTrue(created.contains { $0.toNoteId == neighbor.noteId })
    XCTAssertTrue(created.allSatisfy { $0.linkKind == "memory-association" })
    XCTAssertTrue(created.allSatisfy { $0.provenance == .ai })
    XCTAssertFalse(created.contains { $0.toNoteId == source.noteId })

    let replay = try service.linkLongTermMemoryAssociations(noteId: memory.noteId)
    XCTAssertFalse(replay.contains { $0.toNoteId == neighbor.noteId })
    XCTAssertEqual(
      try service.listLinks(noteId: memory.noteId).filter {
        $0.linkKind == "memory-association" && $0.toNoteId == neighbor.noteId
      }.count,
      1
    )
  }

  func testAssociationLinkingRejectsNotesOutsideTheCanonicalNotebook() throws {
    let service = try makeService(function: #function)
    let notebook = try service.createNotebook(title: "Ordinary notebook")
    let note = try service.createNote(notebookId: notebook.notebookId, bodyMarkdown: "Ordinary note")

    XCTAssertThrowsError(try service.linkLongTermMemoryAssociations(noteId: note.noteId)) { error in
      guard case let NoteServiceError.invalidInput(message) = error else {
        return XCTFail("expected notebook membership rejection, got \(error)")
      }
      XCTAssertTrue(message.contains("does not belong to the long-term-memory notebook"))
    }
  }

  private func bodies(_ notes: [Note]) -> [String] {
    notes.map(\.bodyMarkdown)
  }

  private func metaObject(_ note: Note) throws -> JSONValue {
    let metaJSON = try XCTUnwrap(note.metaJSON)
    return try JSONValue(parsing: metaJSON)
  }
}

private struct LinkFingerprint: Hashable {
  var to: String
  var kind: String
  var provenance: NoteProvenance

  init(to: String, kind: String, provenance: NoteProvenance) {
    self.to = to
    self.kind = kind
    self.provenance = provenance
  }

  init(link: NoteLink) {
    self.init(to: link.toNoteId.rawValue, kind: link.linkKind, provenance: link.provenance)
  }
}

private func XCTAssertReservedLongTermMemoryTag<T>(
  file: StaticString = #filePath,
  line: UInt = #line,
  operation: () throws -> T
) {
  XCTAssertThrowsError(try operation(), file: file, line: line) { error in
    guard case let NoteServiceError.invalidInput(message) = error else {
      return XCTFail("expected reserved long-term-memory rejection, got \(error)", file: file, line: line)
    }
    XCTAssertTrue(message.contains(NoteStoreSchema.longTermMemoryNotebookKindTag), file: file, line: line)
    XCTAssertTrue(message.contains("canonical long-term-memory notebook"), file: file, line: line)
  }
}
