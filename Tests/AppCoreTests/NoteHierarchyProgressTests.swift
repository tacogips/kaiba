import Foundation
@testable import AppCore
import XCTest

final class NoteHierarchyProgressTests: NoteTestCase {
  func testTagInsertCollisionClassificationRejectsNonConstraintFailures() {
    XCTAssertTrue(isSQLiteUniqueConstraintViolation(SQLiteError(
      operation: .execute,
      code: 19,
      message: "UNIQUE constraint failed: tags.name"
    )))
    XCTAssertFalse(isSQLiteUniqueConstraintViolation(SQLiteError(
      operation: .execute,
      code: 5,
      message: "database is locked"
    )))
    XCTAssertFalse(isSQLiteUniqueConstraintViolation(SQLiteError(
      operation: .query,
      code: 19,
      message: "query constraint"
    )))
    XCTAssertFalse(isSQLiteUniqueConstraintViolation(SQLiteError(
      operation: .execute,
      code: 19,
      message: "FOREIGN KEY constraint failed"
    )))
  }

  func testCreateOnlyTagUsesIdentityDomainWithoutChangingExistingFolder() throws {
    let service = try NoteService(driver: makeNoteDriver())
    let parent = try service.defineTag(name: "Parent", classId: TagClassID("folder"))
    let existing = try service.defineTag(
      name: "Shared",
      classId: TagClassID("folder"),
      parentTagId: parent.tagId
    )

    let topic = try service.defineTag(name: "Shared", classId: TagClassID("topic"), createOnly: true)
    XCTAssertNotEqual(topic.tagId, existing.tagId)
    let persisted = try XCTUnwrap(try service.listTags().first { $0.tagId == existing.tagId })
    XCTAssertEqual(persisted.classId, TagClassID("folder"))
    XCTAssertEqual(persisted.parentTagId, parent.tagId)

    let updated = try service.defineTag(name: "Shared", classId: TagClassID("topic"))
    XCTAssertEqual(updated.tagId, topic.tagId, "non-folder upsert must stay in its identity domain")
    XCTAssertEqual(updated.classId, TagClassID("topic"))
    XCTAssertNil(updated.parentTagId)
  }

  func testHierarchyFiltersNotesAndNotebooksTransitively() throws {
    let service = try NoteService(driver: makeNoteDriver())
    let parent = try service.defineTag(name: "portfolio", classId: TagClassID("topic"))
    let child = try service.defineTag(
      name: "project",
      classId: TagClassID("topic"),
      parentTagId: parent.tagId
    )
    let grandchild = try service.defineTag(
      name: "launch",
      classId: TagClassID("topic"),
      parentTagId: child.tagId
    )
    let leaf = try service.defineTag(name: "standalone", classId: TagClassID("topic"))

    let parentNote = try service.createNote(
      bodyMarkdown: "# Parent\nAlpha parent",
      tags: [NoteTagInput(name: parent.name)]
    )
    let childNote = try service.createNote(
      bodyMarkdown: "# Child\nAlpha child",
      tags: [NoteTagInput(name: child.name)]
    )
    let grandchildNote = try service.createNote(
      bodyMarkdown: "# Grandchild\nAlpha grandchild",
      tags: [NoteTagInput(name: grandchild.name)]
    )
    let leafNote = try service.createNote(
      bodyMarkdown: "# Leaf\nAlpha leaf",
      tags: [NoteTagInput(name: leaf.name)]
    )
    let linkedGrandchildNote = try service.createNote(
      bodyMarkdown: "# Linked Grandchild\nNeighbor only",
      tags: [NoteTagInput(name: grandchild.name)]
    )
    _ = try service.linkNotes(
      from: parentNote.noteId,
      to: linkedGrandchildNote.noteId
    )

    try service.applyNotebookTags(
      notebookId: parentNote.notebookId,
      tags: [parent.name],
      provenance: .human
    )
    try service.applyNotebookTags(
      notebookId: childNote.notebookId,
      tags: [child.name],
      provenance: .human
    )
    try service.applyNotebookTags(
      notebookId: grandchildNote.notebookId,
      tags: [grandchild.name],
      provenance: .human
    )
    try service.applyNotebookTags(
      notebookId: leafNote.notebookId,
      tags: [leaf.name],
      provenance: .human
    )

    XCTAssertEqual(
      Set(try service.listNotes(tagFilter: [parent.name]).map(\.noteId)),
      Set([
        parentNote.noteId,
        childNote.noteId,
        grandchildNote.noteId,
        linkedGrandchildNote.noteId
      ])
    )
    XCTAssertEqual(
      Set(try service.listNotebooks(tagFilter: [parent.name]).map(\.notebookId)),
      Set([parentNote.notebookId, childNote.notebookId, grandchildNote.notebookId])
    )
    XCTAssertEqual(
      Set(try service.searchNotes(query: "Alpha", tagFilter: [parent.name]).map(\.note.noteId)),
      Set([parentNote.noteId, childNote.noteId, grandchildNote.noteId])
    )
    XCTAssertEqual(
      Set(try service.searchNotes(query: "", tagFilter: [parent.name]).map(\.note.noteId)),
      Set([
        parentNote.noteId,
        childNote.noteId,
        grandchildNote.noteId,
        linkedGrandchildNote.noteId
      ])
    )
    XCTAssertEqual(
      Set(try service.searchNotes(query: "Al", tagFilter: [parent.name]).map(\.note.noteId)),
      Set([parentNote.noteId, childNote.noteId, grandchildNote.noteId])
    )
    let linkedResults = try service.searchNotes(
      query: "Alpha",
      tagFilter: [parent.name],
      includeLinked: true
    )
    XCTAssertEqual(
      Set(linkedResults.map(\.note.noteId)),
      Set([
        parentNote.noteId,
        childNote.noteId,
        grandchildNote.noteId,
        linkedGrandchildNote.noteId
      ])
    )
    XCTAssertEqual(
      linkedResults.first { $0.note.noteId == linkedGrandchildNote.noteId }?.isLinkedNeighbor,
      true
    )
    XCTAssertEqual(
      try service.listNotes(tagFilter: [child.name]).map(\.noteId).sorted(),
      [childNote.noteId, grandchildNote.noteId, linkedGrandchildNote.noteId].sorted()
    )
    XCTAssertEqual(try service.listNotes(tagFilter: [leaf.name]).map(\.noteId), [leafNote.noteId])
    XCTAssertTrue(try service.listNotes(tagFilter: ["unknown-tag"]).isEmpty)
    XCTAssertTrue(try service.listNotebooks(tagFilter: ["unknown-tag"]).isEmpty)
  }

  func testLegacyNoteFiltersRejectAmbiguousFolderNamesBeforeIdExpansion() throws {
    let service = try NoteService(driver: makeNoteDriver())
    let work = try service.defineTag(name: "Work", classId: TagClassID("folder"))
    let archive = try service.defineTag(name: "Archive", classId: TagClassID("folder"))
    let workShared = try service.defineTag(
      name: "Shared",
      classId: TagClassID("folder"),
      parentTagId: work.tagId
    )
    let archiveShared = try service.defineTag(
      name: "Shared",
      classId: TagClassID("folder"),
      parentTagId: archive.tagId
    )
    let workTopic = try service.defineTag(
      name: "Work topic",
      classId: TagClassID("topic"),
      parentTagId: workShared.tagId
    )
    let archiveTopic = try service.defineTag(
      name: "Archive topic",
      classId: TagClassID("topic"),
      parentTagId: archiveShared.tagId
    )
    _ = try service.createNote(
      bodyMarkdown: "# Work branch\nShared search text",
      tags: [NoteTagInput(name: workTopic.name)]
    )
    _ = try service.createNote(
      bodyMarkdown: "# Archive branch\nShared search text",
      tags: [NoteTagInput(name: archiveTopic.name)]
    )

    for operation in [
      { try service.listNotes(tagFilter: ["Shared"]).count },
      { try service.searchNotes(query: "Shared", tagFilter: ["Shared"]).count },
      { try service.searchNotes(query: "", tagFilter: ["Shared"]).count }
    ] {
      XCTAssertThrowsError(try operation()) { error in
        guard case let NoteServiceError.invalidInput(message) = error else {
          return XCTFail("expected ambiguous legacy filter failure, got \(error)")
        }
        XCTAssertTrue(message.contains("ambiguous"))
      }
    }
  }

  func testGroupedNotebookFiltersIntersectExpandedUnionsAndPreserveFlatCompatibility() throws {
    let service = try NoteService(driver: makeNoteDriver())
    let folder = try service.defineTag(name: "Work", classId: TagClassID("folder"))
    let child = try service.defineTag(
      name: "Launch",
      classId: TagClassID("folder"),
      parentTagId: folder.tagId
    )
    try service.defineTagClass(classId: TagClassID("priority"), label: "Priority")
    let urgent = try service.defineTag(name: "Urgent", classId: TagClassID("priority"))
    let normal = try service.defineTag(name: "Normal", classId: TagClassID("priority"))
    let launchUrgent = try service.createNotebook(title: "Launch urgent")
    let workNormal = try service.createNotebook(title: "Work normal")
    let urgentOnly = try service.createNotebook(title: "Urgent only")
    try service.applyNotebookTags(
      notebookId: launchUrgent.notebookId,
      tags: [child.name, urgent.name],
      provenance: .human
    )
    try service.applyNotebookTags(
      notebookId: workNormal.notebookId,
      tags: [folder.name, normal.name],
      provenance: .human
    )
    try service.applyNotebookTags(
      notebookId: urgentOnly.notebookId,
      tags: [urgent.name],
      provenance: .human
    )

    XCTAssertEqual(
      try service.listNotebooks(
        tagFilterGroups: [[folder.name], [urgent.name]]
      ).map(\.notebookId),
      [launchUrgent.notebookId]
    )
    XCTAssertEqual(
      Set(try service.listNotebooks(
        tagFilterGroups: [[folder.name], [urgent.name, normal.name]]
      ).map(\.notebookId)),
      Set([launchUrgent.notebookId, workNormal.notebookId])
    )
    XCTAssertTrue(
      try service.listNotebooks(tagFilterGroups: [[folder.name], ["unknown"]]).isEmpty
    )
    XCTAssertTrue(try service.listNotebooks(tagFilterGroups: [[]]).isEmpty)
    XCTAssertTrue(
      try service.listNotebooks(tagFilterGroups: [[], [urgent.name]]).isEmpty
    )
    XCTAssertEqual(
      Set(try service.listNotebooks(tagFilter: [urgent.name]).map(\.notebookId)),
      Set([launchUrgent.notebookId, urgentOnly.notebookId])
    )
    XCTAssertEqual(
      try service.listNotebooks(
        tagFilter: [normal.name],
        tagFilterGroups: [[urgent.name]]
      ).map(\.notebookId).sorted(),
      [launchUrgent.notebookId, urgentOnly.notebookId].sorted()
    )
    XCTAssertEqual(
      try service.listNotebooks(
        tagFilter: [normal.name],
        tagFilterGroups: [[normal.name]],
        tagFilterIdGroups: [[folder.tagId], [urgent.tagId]]
      ).map(\.notebookId),
      [launchUrgent.notebookId]
    )
    XCTAssertTrue(
      try service.listNotebooks(tagFilterIdGroups: [[folder.tagId], [TagID("unknown-id")]]).isEmpty
    )
  }

  func testGroupedNotebookFilterBoundsDeduplicateAndFailClosedBeforeFurtherExpansion() throws {
    let driver = try makeNoteDriver()
    let service = try NoteService(driver: driver)
    let work = try service.defineTag(name: "Work", classId: TagClassID("folder"))
    let notebook = try service.createNotebook(title: "Work notebook")
    try service.applyNotebookTags(
      notebookId: notebook.notebookId,
      tags: [work.name],
      provenance: .human
    )

    XCTAssertTrue(
      try service.listNotebooks(
        tagFilterGroups: [[work.name, work.name], [work.name], []]
      ).isEmpty
    )
    XCTAssertTrue(
      try service.listNotebooks(
        tagFilterGroups: [["unknown"], [work.name]]
      ).isEmpty
    )
    XCTAssertEqual(
      try service.listNotebooks(
        tagFilterIdGroups: [[work.tagId, work.tagId], [work.tagId], []]
      ).map(\.notebookId),
      [notebook.notebookId]
    )

    XCTAssertThrowsError(
      try service.listNotebooks(
        tagFilterGroups: Array(
          repeating: [work.name],
          count: NoteService.maximumNotebookTagFilterGroups + 1
        )
      )
    ) { error in
      XCTAssertEqual(
        error as? NoteServiceError,
        .invalidInput(
          "tagFilterGroups supports at most \(NoteService.maximumNotebookTagFilterGroups) groups"
        )
      )
    }
    XCTAssertThrowsError(
      try service.listNotebooks(
        tagFilterGroups: [Array(
          repeating: work.name,
          count: NoteService.maximumNotebookTagFilterNames + 1
        )]
      )
    ) { error in
      XCTAssertEqual(
        error as? NoteServiceError,
        .invalidInput(
          "tagFilterGroups supports at most \(NoteService.maximumNotebookTagFilterNames) tag names"
        )
      )
    }
    XCTAssertThrowsError(
      try service.listNotebooks(
        tagFilterIdGroups: Array(
          repeating: [work.tagId],
          count: NoteService.maximumNotebookTagFilterGroups + 1
        )
      )
    ) { error in
      XCTAssertEqual(
        error as? NoteServiceError,
        .invalidInput(
          "tagFilterIdGroups supports at most \(NoteService.maximumNotebookTagFilterGroups) groups"
        )
      )
    }
    XCTAssertThrowsError(
      try service.listNotebooks(
        tagFilterIdGroups: [Array(
          repeating: work.tagId,
          count: NoteService.maximumNotebookTagFilterNames + 1
        )]
      )
    ) { error in
      XCTAssertEqual(
        error as? NoteServiceError,
        .invalidInput(
          "tagFilterIdGroups supports at most \(NoteService.maximumNotebookTagFilterNames) tag IDs"
        )
      )
    }
  }

  func testGroupedNotebookFilterRejectsOversizedDescendantExpansion() throws {
    let driver = try makeNoteDriver()
    let service = try NoteService(driver: driver)
    let root = try service.defineTag(name: "Root", classId: TagClassID("folder"))
    try driver.withDatabase { database in
      try database.transaction { transaction in
        for index in 0..<NoteService.maximumExpandedNotebookTagFilterNames {
          try transaction.execute(
            """
            INSERT INTO tags (tag_id, name, class_id, parent_tag_id, is_system, created_at)
            VALUES (?, ?, 'folder', ?, 0, '2026-07-27T00:00:00Z')
            """,
            bindings: [
              .text("child-\(index)"),
              .text("Child \(index)"),
              .id(root.tagId)
            ]
          )
        }
      }
    }

    XCTAssertThrowsError(
      try service.listNotebooks(tagFilterGroups: [[root.name]])
    ) { error in
      XCTAssertEqual(
        error as? NoteServiceError,
        .invalidInput(
          """
          tagFilterGroups expands to at most \
          \(NoteService.maximumExpandedNotebookTagFilterNames) tag names
          """
        )
      )
    }
    XCTAssertThrowsError(
      try service.listNotebooks(tagFilterIdGroups: [[root.tagId]])
    ) { error in
      XCTAssertEqual(
        error as? NoteServiceError,
        .invalidInput(
          """
          tagFilterIdGroups expands to at most \
          \(NoteService.maximumExpandedNotebookTagFilterNames) tag IDs
          """
        )
      )
    }
  }

  func testLegacyNotebookFilterRejectsOversizedDescendantExpansion() throws {
    let driver = try makeNoteDriver()
    let service = try NoteService(driver: driver)
    let root = try service.defineTag(name: "Root", classId: TagClassID("folder"))
    try driver.withDatabase { database in
      try database.transaction { transaction in
        for index in 0..<NoteService.maximumExpandedNotebookTagFilterNames {
          try transaction.execute(
            """
            INSERT INTO tags (tag_id, name, class_id, parent_tag_id, is_system, created_at)
            VALUES (?, ?, 'folder', ?, 0, '2026-07-27T00:00:00Z')
            """,
            bindings: [
              .text("legacy-child-\(index)"),
              .text("Legacy Child \(index)"),
              .id(root.tagId)
            ]
          )
        }
      }
    }

    XCTAssertThrowsError(
      try service.listNotebooks(tagFilter: [root.name])
    ) { error in
      XCTAssertEqual(
        error as? NoteServiceError,
        .invalidInput(
          """
          tagFilterGroups expands to at most \
          \(NoteService.maximumExpandedNotebookTagFilterNames) tag names
          """
        )
      )
    }
  }

  func testCycleRejectionIsAtomicAndDefensiveExpansionTerminates() throws {
    let driver = try makeNoteDriver()
    let service = try NoteService(driver: driver)
    let parent = try service.defineTag(name: "parent")
    let child = try service.defineTag(name: "child", parentTagId: parent.tagId)

    XCTAssertThrowsError(
      try service.defineTag(name: "parent", parentTagId: child.tagId)
    )
    XCTAssertNil(try service.listTags().first { $0.tagId == parent.tagId }?.parentTagId)

    try driver.withDatabase { database in
      try database.execute(
        "UPDATE tags SET parent_tag_id = ? WHERE tag_id = ?",
        bindings: [.id(child.tagId), .id(parent.tagId)]
      )
    }
    let expanded = try driver.withDatabase { database in
      try expandedTagFilterIds([parent.tagId], in: database)
    }
    XCTAssertEqual(Set(expanded), Set([parent.tagId, child.tagId]))
  }

  func testFolderTagsRoundTrip() throws {
    let service = try NoteService(driver: makeNoteDriver())
    let folder = try service.defineTag(name: "Work", classId: TagClassID("folder"))
    let notebook = try service.createNotebook(title: "Quarterly Plan")
    let tagged = try service.applyNotebookTags(
      notebookId: notebook.notebookId,
      tags: [folder.name],
      provenance: .human
    )
    XCTAssertEqual(tagged.tags.first?.tag.classId, TagClassID("folder"))
    XCTAssertEqual(try service.getNotebook(notebook.notebookId), tagged)
  }
}
