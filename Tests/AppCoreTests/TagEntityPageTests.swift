import Foundation
@testable import AppCore
import XCTest

/// The tag entity page's service half
/// (`design-docs/specs/note-capture-and-entity-pages.md`, E1/E2/E4): the
/// canonical-note binding and its validation matrix, the co-occurrence
/// aggregate and the index it must ride, and the undo behaviour of a binding
/// whose note is deleted (finding F1).
private final class TagEntityChangeObserver: NoteChangeObserving, @unchecked Sendable {
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

final class TagEntityPageTests: NoteTestCase {
  // MARK: - Promote and unpromote (E2)

  func testPromoteBindsACanonicalNoteAndPublishesAChange() throws {
    let observer = TagEntityChangeObserver()
    let service = try NoteService(driver: try makeNoteDriver(), changeObserver: observer)
    let tag = try service.defineTag(name: "kaiba", classId: .topic)
    let note = try service.createNote(
      notebookTitle: "Entities",
      title: "Kaiba",
      bodyMarkdown: "The canonical description."
    )

    let promoted = try service.promoteTagCanonicalNote(tagId: tag.tagId, noteId: note.noteId)

    XCTAssertEqual(promoted.noteId, note.noteId)
    XCTAssertEqual(try service.canonicalNote(tagId: tag.tagId)?.noteId, note.noteId)
    // Promotion is a binding, not an assignment: the note must not gain the tag
    // (E3), or the canonical note would also show up as one of its occurrences.
    XCTAssertFalse(try service.getNote(note.noteId).tags.contains { $0.tag.tagId == tag.tagId })
    let promoteEvents = observer.events.filter { $0.tagNames == [tag.name] }
    XCTAssertEqual(promoteEvents.count, 1)
    XCTAssertEqual(promoteEvents.first?.kind, NoteChangeEventKind.noteTags)
    XCTAssertEqual(promoteEvents.first?.notebookId, note.notebookId)
  }

  func testPromoteReplacesTheExistingBinding() throws {
    let service = try makeService()
    let tag = try service.defineTag(name: "kaiba", classId: .topic)
    let first = try service.createNote(notebookTitle: "Entities", bodyMarkdown: "# First")
    let second = try service.createNote(
      notebookId: first.notebookId,
      bodyMarkdown: "# Second, and better"
    )

    _ = try service.promoteTagCanonicalNote(tagId: tag.tagId, noteId: first.noteId)
    _ = try service.promoteTagCanonicalNote(tagId: tag.tagId, noteId: second.noteId)

    // Last promote wins, and the column holds exactly one binding.
    XCTAssertEqual(try service.canonicalNote(tagId: tag.tagId)?.noteId, second.noteId)
    try service.driver.withDatabase { database in
      let bound = try database.query(
        "SELECT tag_id FROM tags WHERE canonical_note_id IS NOT NULL"
      ).compactMap { $0.identifier("tag_id", as: TagID.self) }
      XCTAssertEqual(bound, [tag.tagId])
    }
  }

  func testPromoteRejectsAMissingTagOrAMissingNote() throws {
    let service = try makeService()
    let tag = try service.defineTag(name: "kaiba", classId: .topic)
    let note = try service.createNote(notebookTitle: "Entities", bodyMarkdown: "# Body")

    XCTAssertThrowsError(
      try service.promoteTagCanonicalNote(tagId: TagID("tag-missing"), noteId: note.noteId)
    ) { error in
      XCTAssertEqual(error as? NoteServiceError, .notFound("tag not found: tag-missing"))
    }
    XCTAssertThrowsError(
      try service.promoteTagCanonicalNote(tagId: tag.tagId, noteId: NoteID("note-missing"))
    ) { error in
      guard case .notFound? = error as? NoteServiceError else {
        return XCTFail("expected a not-found error, got \(error)")
      }
    }
    XCTAssertNil(try service.canonicalNote(tagId: tag.tagId))
  }

  func testPromoteRejectsFolderAndNotebookKindTags() throws {
    let service = try makeService()
    let note = try service.createNote(notebookTitle: "Entities", bodyMarkdown: "# Body")
    let folder = try service.defineTag(name: "Projects", classId: .folder)
    let kindTag = try service.driver.withDatabase { database in
      try requireTag(id: NoteStoreSchema.quickMemoNotebookKindTagId, in: database)
    }
    XCTAssertEqual(kindTag.classId, .documentKind)

    XCTAssertThrowsError(
      try service.promoteTagCanonicalNote(tagId: folder.tagId, noteId: note.noteId)
    ) { error in
      XCTAssertEqual(
        error as? NoteServiceError,
        .invalidInput("folder tags cannot carry a canonical note: Projects")
      )
    }
    XCTAssertThrowsError(
      try service.promoteTagCanonicalNote(tagId: kindTag.tagId, noteId: note.noteId)
    ) { error in
      XCTAssertEqual(
        error as? NoteServiceError,
        .invalidInput("notebook kind tags cannot carry a canonical note: \(kindTag.name)")
      )
    }
    try service.driver.withDatabase { database in
      XCTAssertEqual(
        try database.query("SELECT COUNT(*) AS bound FROM tags WHERE canonical_note_id IS NOT NULL")
          .first?["bound"],
        "0"
      )
    }
  }

  func testUnpromoteClearsTheBindingAndPublishes() throws {
    let observer = TagEntityChangeObserver()
    let service = try NoteService(driver: try makeNoteDriver(), changeObserver: observer)
    let tag = try service.defineTag(name: "kaiba", classId: .topic)
    let note = try service.createNote(notebookTitle: "Entities", bodyMarkdown: "# Body")
    _ = try service.promoteTagCanonicalNote(tagId: tag.tagId, noteId: note.noteId)
    let afterPromote = observer.events.count

    let unbound = try service.unpromoteTagCanonicalNote(tagId: tag.tagId)

    XCTAssertEqual(unbound?.noteId, note.noteId)
    XCTAssertNil(try service.canonicalNote(tagId: tag.tagId))
    XCTAssertEqual(observer.events.count, afterPromote + 1)
    XCTAssertEqual(observer.events.last?.tagNames, [tag.name])
    // The note itself survives being unpromoted.
    XCTAssertEqual(try service.getNote(note.noteId).noteId, note.noteId)
  }

  func testUnpromoteOnAnUnboundTagIsANoOpSuccess() throws {
    let observer = TagEntityChangeObserver()
    let service = try NoteService(driver: try makeNoteDriver(), changeObserver: observer)
    let tag = try service.defineTag(name: "kaiba", classId: .topic)

    XCTAssertNil(try service.unpromoteTagCanonicalNote(tagId: tag.tagId))
    XCTAssertNil(try service.unpromoteTagCanonicalNote(tagId: tag.tagId))

    XCTAssertTrue(observer.events.isEmpty)
    XCTAssertThrowsError(try service.unpromoteTagCanonicalNote(tagId: TagID("tag-missing")))
  }

  func testACanonicalNoteOutsideTheCallersReachReadsAsUnbound() throws {
    let service = try makeService()
    let hidden = try service.createLibrary(name: "hidden", authRequired: true)
    let hiddenNote = try service.scoped(toLibrary: hidden.libraryId).createNote(
      notebookTitle: "Hidden",
      bodyMarkdown: "# Classified"
    )
    let tag = try service.defineTag(name: "kaiba", classId: .topic)
    _ = try service.promoteTagCanonicalNote(tagId: tag.tagId, noteId: hiddenNote.noteId)
    let anonymous = service.scoped(to: NoteStoreSchema.defaultUserId).unauthenticated()

    XCTAssertEqual(try service.canonicalNote(tagId: tag.tagId)?.noteId, hiddenNote.noteId)
    XCTAssertNil(try anonymous.canonicalNote(tagId: tag.tagId))
    XCTAssertNil(try anonymous.tagDetail(tagId: tag.tagId).canonicalNote)
    // A caller that cannot see the binding cannot clear it either, and is told
    // nothing about it: the unbound no-op, not an error naming the note.
    XCTAssertNil(try anonymous.unpromoteTagCanonicalNote(tagId: tag.tagId))
    XCTAssertEqual(try service.canonicalNote(tagId: tag.tagId)?.noteId, hiddenNote.noteId)
  }

  // MARK: - Co-occurring tags (E4)

  func testCoOccurringTagsRankBySharedNotesAndExcludeOrganizationalTags() throws {
    let service = try makeService()
    let subject = try service.defineTag(name: "kaiba", classId: .topic)
    _ = try service.defineTag(name: "Projects", classId: .folder)
    let notebook = try service.createNotebook(title: "Entities", folderPath: ["Projects"])
    // Three notes carry the subject: "swift" shares all three, "sqlite" two,
    // "unrelated" none.
    for index in 0..<3 {
      var tags = [NoteTagInput(name: "kaiba"), NoteTagInput(name: "swift")]
      if index < 2 { tags.append(NoteTagInput(name: "sqlite")) }
      _ = try service.createNote(
        notebookId: notebook.notebookId,
        bodyMarkdown: "# Note \(index)",
        tags: tags
      )
    }
    _ = try service.createNote(
      notebookId: notebook.notebookId,
      bodyMarkdown: "# Elsewhere",
      tags: [NoteTagInput(name: "unrelated")]
    )

    let coOccurring = try service.coOccurringTags(tagId: subject.tagId)

    XCTAssertEqual(coOccurring.map(\.tag.name), ["swift", "sqlite"])
    XCTAssertEqual(coOccurring.map(\.noteCount), [3, 2])
    // The subject never co-occurs with itself, the folder tag that files the
    // notebook is organizational, and an unshared tag is absent.
    XCTAssertFalse(coOccurring.contains { $0.tag.name == subject.name })
    XCTAssertFalse(coOccurring.contains { $0.tag.classId == .folder })
    XCTAssertFalse(coOccurring.contains { $0.tag.name == "unrelated" })
  }

  func testCoOccurringTagsExcludeSystemAndNotebookKindTags() throws {
    let service = try makeService()
    let subject = try service.defineTag(name: "kaiba", classId: .topic)
    let note = try service.createNote(
      notebookTitle: "Entities",
      bodyMarkdown: "# Body",
      tags: [NoteTagInput(name: "kaiba"), NoteTagInput(name: "swift")]
    )
    // A system document-kind tag assigned straight onto the note is the case
    // the class filter and the is_system filter each have to catch.
    try service.driver.withDatabase { database in
      try database.execute(
        """
        INSERT INTO note_tags (note_id, tag_id, provenance, assigned_by, deletable, created_at)
        VALUES (?, ?, 'system', 'test', 0, ?)
        """,
        bindings: [
          .id(note.noteId),
          .id(NoteStoreSchema.quickMemoNotebookKindTagId),
          .text(NoteStoreClock.system.now())
        ]
      )
    }

    let coOccurring = try service.coOccurringTags(tagId: subject.tagId)

    XCTAssertEqual(coOccurring.map(\.tag.name), ["swift"])
  }

  func testCoOccurringTagsAreEmptyForATagWithNoNotes() throws {
    let service = try makeService()
    let tag = try service.defineTag(name: "lonely", classId: .topic)

    XCTAssertEqual(try service.coOccurringTags(tagId: tag.tagId).count, 0)
    XCTAssertEqual(try service.coOccurringTags(tagId: tag.tagId, limit: 0).count, 0)
  }

  func testCoOccurringTagsHonourTheLimitAndRejectAnOutOfRangeOne() throws {
    let service = try makeService()
    let subject = try service.defineTag(name: "kaiba", classId: .topic)
    _ = try service.createNote(
      notebookTitle: "Entities",
      bodyMarkdown: "# Body",
      tags: [
        NoteTagInput(name: "kaiba"),
        NoteTagInput(name: "swift"),
        NoteTagInput(name: "sqlite")
      ]
    )

    XCTAssertEqual(try service.coOccurringTags(tagId: subject.tagId, limit: 1).count, 1)
    XCTAssertThrowsError(try service.coOccurringTags(tagId: subject.tagId, limit: 201)) { error in
      XCTAssertEqual(error as? NoteServiceError, .invalidInput("limit must be between 0 and 200"))
    }
    XCTAssertThrowsError(try service.coOccurringTags(tagId: TagID("tag-missing")))
  }

  func testTagDetailCarriesTheCanonicalNoteAndCoOccurrence() throws {
    let service = try makeService()
    let subject = try service.defineTag(name: "kaiba", classId: .topic)
    let note = try service.createNote(
      notebookTitle: "Entities",
      title: "Kaiba",
      bodyMarkdown: "# Kaiba\nthe note itself",
      tags: [NoteTagInput(name: "kaiba"), NoteTagInput(name: "swift")]
    )

    let before = try service.tagDetail(tagId: subject.tagId)
    XCTAssertNil(before.canonicalNote)
    XCTAssertEqual(before.coOccurringTags.map(\.tag.name), ["swift"])
    XCTAssertEqual(before.coOccurringTags.map(\.noteCount), [1])

    _ = try service.promoteTagCanonicalNote(tagId: subject.tagId, noteId: note.noteId)

    let after = try service.tagDetail(tagId: subject.tagId)
    XCTAssertEqual(after.canonicalNote?.noteId, note.noteId)
    XCTAssertEqual(after.canonicalNote?.title, "Kaiba")
    // The counts the payload already carried are unchanged by promotion.
    XCTAssertEqual(after.noteCount, before.noteCount)
    XCTAssertEqual(after.notebookCount, before.notebookCount)
  }

  // MARK: - Query plans (E4, finding F2)

  func testCoOccurrenceQueryRidesTheTagIndexWithoutScanningNoteTags() throws {
    let service = try makeService()
    let subject = try service.defineTag(name: "kaiba", classId: .topic)
    _ = try service.createNote(
      notebookTitle: "Entities",
      bodyMarkdown: "# Body",
      tags: [NoteTagInput(name: "kaiba"), NoteTagInput(name: "swift")]
    )

    let plan = try service.driver.withDatabase { database -> [String] in
      let statement = try XCTUnwrap(
        try service.coOccurringTagsStatement(
          tagId: subject.tagId,
          limit: NoteService.defaultCoOccurringTagLimit,
          in: database
        )
      )
      return try database.query(
        "EXPLAIN QUERY PLAN \(statement.sql)",
        bindings: statement.bindings
      ).compactMap { $0["detail"] }
    }

    XCTAssertFalse(plan.isEmpty)
    XCTAssertTrue(
      plan.contains { $0.contains("idx_note_tags_tag") },
      "the subject side must ride idx_note_tags_tag: \(plan)"
    )
    let scanned = Set(plan.compactMap { step -> String? in
      guard step.hasPrefix("SCAN ") else { return nil }
      return step.split(separator: " ").dropFirst().first.map(String.init)
    })
    // Nothing that grows with the note store may be scanned: not either
    // note_tags alias, not the notes join, not the tag catalog.
    XCTAssertTrue(
      scanned.isDisjoint(with: ["subject", "shared", "note_tags", "n", "notes", "peer", "tags"]),
      "co-occurrence must not scan a store-sized table: \(plan)"
    )
    // The only scan left is the non-correlated pending-ingest exclusion
    // subquery over `notebooks`, evaluated once and bounded by the notebook
    // count. Every scoped read in NoteService+TagDetail already pays it.
    XCTAssertEqual(scanned.subtracting(["notebooks"]), [], "\(plan)")
  }

  func testTheCanonicalNoteReverseLookupRidesItsOwnIndex() throws {
    let service = try makeService()
    let note = try service.createNote(notebookTitle: "Entities", bodyMarkdown: "# Body")
    let tag = try service.defineTag(name: "kaiba", classId: .topic)
    _ = try service.promoteTagCanonicalNote(tagId: tag.tagId, noteId: note.noteId)

    let plan = try service.driver.withDatabase { database in
      // The statement `captureNoteSnapshot` runs for every note deletion
      // (finding F2). Without idx_tags_canonical_note this is a full tag scan.
      try database.query(
        "EXPLAIN QUERY PLAN SELECT tag_id FROM tags WHERE canonical_note_id = ? ORDER BY tag_id",
        bindings: [.id(note.noteId)]
      ).compactMap { $0["detail"] }
    }

    XCTAssertTrue(
      plan.contains { $0.contains("idx_tags_canonical_note") },
      "the reverse lookup must ride idx_tags_canonical_note: \(plan)"
    )
    XCTAssertFalse(plan.contains { $0.hasPrefix("SCAN tags") }, "\(plan)")
  }

  // MARK: - Undo of a deleted canonical note (finding F1)

  func testUndoingANoteDeletionRestoresTheCanonicalBinding() throws {
    let service = try makeService()
    let tag = try service.defineTag(name: "kaiba", classId: .topic)
    let other = try service.defineTag(name: "kaiba-store", classId: .topic)
    let note = try service.createNote(
      notebookTitle: "Entities",
      title: "Kaiba",
      bodyMarkdown: "# Kaiba"
    )
    _ = try service.promoteTagCanonicalNote(tagId: tag.tagId, noteId: note.noteId)
    _ = try service.promoteTagCanonicalNote(tagId: other.tagId, noteId: note.noteId)

    try service.deleteNote(noteId: note.noteId)

    // ON DELETE SET NULL cleared both bindings as the note went (E1).
    XCTAssertNil(try service.canonicalNote(tagId: tag.tagId))
    XCTAssertNil(try service.canonicalNote(tagId: other.tagId))

    XCTAssertNotNil(try service.undoLastAction())

    // Undo puts the note back with every binding it carried.
    XCTAssertEqual(try service.canonicalNote(tagId: tag.tagId)?.noteId, note.noteId)
    XCTAssertEqual(try service.canonicalNote(tagId: other.tagId)?.noteId, note.noteId)
    XCTAssertEqual(try service.tagDetail(tagId: tag.tagId).canonicalNote?.title, "Kaiba")
  }

  func testUndoDoesNotReverseAPromoteMadeAfterTheDeletion() throws {
    let service = try makeService()
    let tag = try service.defineTag(name: "kaiba", classId: .topic)
    let notebook = try service.createNotebook(title: "Entities")
    let original = try service.createNote(notebookId: notebook.notebookId, bodyMarkdown: "# First")
    let replacement = try service.createNote(
      notebookId: notebook.notebookId,
      bodyMarkdown: "# Second"
    )
    _ = try service.promoteTagCanonicalNote(tagId: tag.tagId, noteId: original.noteId)

    try service.deleteNote(noteId: original.noteId)
    _ = try service.promoteTagCanonicalNote(tagId: tag.tagId, noteId: replacement.noteId)

    // The undo target is still the deletion: promotion is not an undoable
    // action, so nothing was pushed on top of it.
    XCTAssertNotNil(try service.undoLastAction())

    XCTAssertNotNil(try service.getNote(original.noteId))
    // Last promote wins (E2): restoring the note must not reverse the newer
    // binding.
    XCTAssertEqual(try service.canonicalNote(tagId: tag.tagId)?.noteId, replacement.noteId)
  }
}
