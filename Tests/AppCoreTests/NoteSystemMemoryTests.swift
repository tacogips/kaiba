import Foundation
@testable import AppCore
import XCTest

final class NoteSystemMemoryTests: NoteTestCase {
  func testBootstrapCreatesOneLockedSystemMemoryNotebookAndIsIdempotent() throws {
    let root = try makeNoteRoot(function: #function)
    let driver = SQLiteNoteDatabaseDriver(noteRoot: root)
    let firstService = try NoteService(driver: driver)
    let first = try firstService.systemMemoryNotebook()

    XCTAssertEqual(first.title, "Kaiba System Memory")
    XCTAssertTrue(first.readOnly)
    XCTAssertTrue(first.tags.contains { $0.tag.name == NoteStoreSchema.systemMemoryNotebookKindTag })

    let secondService = try NoteService(driver: driver)
    let second = try secondService.systemMemoryNotebook()
    XCTAssertEqual(second.notebookId, first.notebookId)
    XCTAssertEqual(
      try secondService.listNotebooks().filter {
        $0.tags.contains { $0.tag.name == NoteStoreSchema.systemMemoryNotebookKindTag }
      }.count,
      1
    )
  }

  func testNotebookReadOnlyRejectsUserWritesButSystemAppendBypassesLock() throws {
    let service = try makeService(function: #function)
    let notebook = try service.systemMemoryNotebook()

    XCTAssertThrowsError(
      try service.createNote(notebookId: notebook.notebookId, bodyMarkdown: "blocked")
    ) { error in
      XCTAssertEqual(error as? NoteServiceError, .readOnly(notebook.notebookId))
    }

    let appended = try service.appendSystemMemoryNote(
      bodyMarkdown: "system context",
      tags: [NoteTagInput(name: "persona:yui")],
      metaJSON: #"{"workflowId":"test","nodeId":"write-context"}"#
    )
    XCTAssertEqual(appended.notebookId, notebook.notebookId)
    XCTAssertEqual(appended.bodyMarkdown, "system context")
    XCTAssertEqual(try service.listSystemMemoryNotes(personaId: "yui", limit: 10).map(\.noteId), [appended.noteId])
  }

  func testPersistedUnlockSurvivesBootstrapAndEnablesUserWrites() throws {
    let root = try makeNoteRoot(function: #function)
    let driver = SQLiteNoteDatabaseDriver(noteRoot: root)
    let firstService = try NoteService(driver: driver)
    let notebook = try firstService.systemMemoryNotebook()
    let unlocked = try firstService.setNotebookReadOnly(notebookId: notebook.notebookId, readOnly: false)
    XCTAssertFalse(unlocked.readOnly)

    let reopenedService = try NoteService(driver: driver)
    XCTAssertFalse(try reopenedService.systemMemoryNotebook().readOnly)
    let note = try reopenedService.createNote(
      notebookId: notebook.notebookId,
      bodyMarkdown: "user-approved context"
    )
    XCTAssertEqual(note.notebookId, notebook.notebookId)
  }

  func testNotebookLockRejectsCreateUpdateAndDeletionWithoutChangingStoredRows() throws {
    let service = try makeService(function: #function)
    let notebook = try service.createNotebook(title: "Locked notebook")
    let note = try service.createNote(
      notebookId: notebook.notebookId,
      bodyMarkdown: "Original body"
    )
    _ = try service.setNotebookReadOnly(notebookId: notebook.notebookId, readOnly: true)

    XCTAssertReadOnly(notebook.notebookId) {
      try service.createNote(notebookId: notebook.notebookId, bodyMarkdown: "Blocked create")
    }
    XCTAssertReadOnly(note.noteId) {
      try service.updateNoteBody(noteId: note.noteId, bodyMarkdown: "Blocked update")
    }
    XCTAssertReadOnly(note.noteId) {
      try service.deleteNote(noteId: note.noteId)
    }
    XCTAssertReadOnly(notebook.notebookId) {
      try service.deleteNotebook(notebookId: notebook.notebookId)
    }

    XCTAssertEqual(try service.getNote(note.noteId).bodyMarkdown, "Original body")
    XCTAssertEqual(try service.getNotebook(notebook.notebookId).notebookId, notebook.notebookId)
  }

  func testNotebookLockRejectsConversationAppend() throws {
    let service = try makeService(function: #function)
    let notebook = try service.createNotebook(title: "Locked conversation")
    _ = try service.setNotebookReadOnly(notebookId: notebook.notebookId, readOnly: true)

    XCTAssertReadOnly(notebook.notebookId) {
      try service.appendConversationTurn(
        notebookId: notebook.notebookId,
        turn: NoteConversationTurn(
          userMarkdown: "User message",
          assistantMarkdown: "Assistant reply"
        )
      )
    }
    XCTAssertTrue(try service.listNotes(notebookId: notebook.notebookId).isEmpty)
  }

  func testNotebookLockAllowsAnnotationAndOrganizationMutations() throws {
    let service = try makeService(function: #function)
    _ = try service.defineTag(name: "project/locked", classId: "folder")
    let notebook = try service.createNotebook(title: "Locked organization")
    let note = try service.createNote(notebookId: notebook.notebookId, bodyMarkdown: "Locked body")
    let otherNotebook = try service.createNotebook(title: "Link target")
    let otherNote = try service.createNote(
      notebookId: otherNotebook.notebookId,
      bodyMarkdown: "Related body"
    )
    _ = try service.setNotebookReadOnly(notebookId: notebook.notebookId, readOnly: true)

    let comment = try service.addComment(noteId: note.noteId, bodyMarkdown: "Allowed comment")
    let link = try service.linkNotes(from: note.noteId, to: otherNote.noteId)
    let taggedNote = try service.applyTags(
      noteId: note.noteId,
      tags: [NoteTagInput(name: "reviewed")],
      provenance: .human
    )
    let taggedNotebook = try service.applyNotebookTags(
      notebookId: notebook.notebookId,
      tags: ["project/locked"],
      provenance: .human
    )
    let progressed = try service.setNotebookProgress(
      notebookId: notebook.notebookId,
      progress: "progress"
    )

    XCTAssertEqual(comment.noteId, note.noteId)
    XCTAssertEqual(link.fromNoteId, note.noteId)
    XCTAssertTrue(taggedNote.tags.contains { $0.tag.name == "reviewed" })
    XCTAssertTrue(taggedNotebook.tags.contains { $0.tag.name == "project/locked" })
    XCTAssertEqual(progressed.progress, "progress")
    XCTAssertTrue(try service.getNotebook(notebook.notebookId).readOnly)
  }

  func testNotebookLockRejectsNoteAndNotebookAttachmentsWithoutStagingFiles() throws {
    let root = try makeNoteRoot(function: #function)
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root))
    let notebook = try service.createNotebook(title: "Locked attachments")
    let note = try service.createNote(notebookId: notebook.notebookId, bodyMarkdown: "Attachment target")
    _ = try service.setNotebookReadOnly(notebookId: notebook.notebookId, readOnly: true)

    XCTAssertReadOnly(note.noteId) {
      try service.attachFile(
        noteId: note.noteId,
        data: Data("note attachment".utf8),
        mediaType: "text/plain",
        originalFilename: "note.txt"
      )
    }
    XCTAssertReadOnly(notebook.notebookId) {
      try service.attachNotebookFile(
        notebookId: notebook.notebookId,
        data: Data("notebook attachment".utf8),
        mediaType: "text/plain",
        originalFilename: "notebook.txt"
      )
    }

    let fileCount = try service.driver.withDatabase { database in
      try database.query("SELECT COUNT(*) AS count FROM files").first?["count"]
    }
    XCTAssertEqual(fileCount, "0")
    XCTAssertTrue(try service.listFiles(noteId: note.noteId).isEmpty)
    XCTAssertTrue(try service.listFiles(notebookId: notebook.notebookId).isEmpty)
    XCTAssertTrue(regularFiles(at: URL(fileURLWithPath: root).appendingPathComponent("files")).isEmpty)
  }

  func testNotebookUnlockDoesNotBypassIndependentNoteLock() throws {
    let service = try makeService(function: #function)
    let notebook = try service.createNotebook(title: "Independent locks")
    let note = try service.createNote(
      notebookId: notebook.notebookId,
      bodyMarkdown: "Locked note",
      readOnly: true
    )
    _ = try service.setNotebookReadOnly(notebookId: notebook.notebookId, readOnly: true)
    _ = try service.setNotebookReadOnly(notebookId: notebook.notebookId, readOnly: false)

    XCTAssertTrue(try service.getNote(note.noteId).readOnly)
    XCTAssertReadOnly(note.noteId) {
      try service.updateNoteBody(noteId: note.noteId, bodyMarkdown: "Still blocked")
    }
    XCTAssertReadOnly(note.noteId) {
      try service.deleteNote(noteId: note.noteId)
    }
    XCTAssertReadOnly(note.noteId) {
      try service.attachFile(
        noteId: note.noteId,
        data: Data("blocked".utf8),
        mediaType: "text/plain"
      )
    }

    _ = try service.setReadOnly(noteId: note.noteId, readOnly: false)
    XCTAssertEqual(
      try service.updateNoteBody(noteId: note.noteId, bodyMarkdown: "Now writable").bodyMarkdown,
      "Now writable"
    )
  }

  func testPublicNotebookKindPathsCannotCreateSecondSystemMemoryIdentity() throws {
    let root = try makeNoteRoot(function: #function)
    let driver = SQLiteNoteDatabaseDriver(noteRoot: root)
    let service = try NoteService(driver: driver)
    let canonical = try service.systemMemoryNotebook()
    let reservedTag = NoteStoreSchema.systemMemoryNotebookKindTag

    XCTAssertReservedSystemMemoryTag {
      try service.createNotebook(title: "Blocked notebook", kindTagName: reservedTag)
    }
    XCTAssertReservedSystemMemoryTag {
      try service.createNote(
        notebookTitle: "Blocked note notebook",
        notebookKindTagName: reservedTag,
        bodyMarkdown: "Blocked note"
      )
    }
    XCTAssertReservedSystemMemoryTag {
      try service.createNotebookWithNotes(
        title: "Blocked ingest notebook",
        kindTagName: reservedTag,
        pages: [NotePageDraft(bodyMarkdown: "Blocked page")]
      )
    }
    let ordinary = try service.createNotebook(title: "Ordinary notebook")
    XCTAssertReservedSystemMemoryTag {
      try service.applyNotebookTags(
        notebookId: ordinary.notebookId,
        tags: [reservedTag],
        provenance: .human
      )
    }
    let reservedTagId = try XCTUnwrap(
      service.listTags().first { $0.name == reservedTag }?.tagId
    )
    XCTAssertReservedSystemMemoryTag {
      try service.applyNotebookTagIds(
        notebookId: ordinary.notebookId,
        tagIds: [reservedTagId],
        provenance: .human
      )
    }

    XCTAssertEqual(
      try service.listNotebooks(tagFilter: [reservedTag]).map(\.notebookId),
      [canonical.notebookId]
    )
    let titles = try service.listNotebooks(limit: 100).map(\.title)
    XCTAssertFalse(titles.contains("Blocked notebook"))
    XCTAssertFalse(titles.contains("Blocked note notebook"))
    XCTAssertFalse(titles.contains("Blocked ingest notebook"))

    let reopened = try NoteService(driver: driver)
    XCTAssertEqual(try reopened.systemMemoryNotebook().notebookId, canonical.notebookId)
  }

  func testSameNamedFolderDoesNotCollideWithSystemMemoryIdentity() throws {
    let root = try makeNoteRoot(function: #function)
    let driver = SQLiteNoteDatabaseDriver(noteRoot: root)
    let service = try NoteService(driver: driver)
    let canonical = try service.systemMemoryNotebook()

    let folderNotebook = try service.createNotebook(
      title: "Reserved display name folder",
      folderPath: [NoteStoreSchema.systemMemoryNotebookKindTag]
    )
    let folder = try XCTUnwrap(folderNotebook.tags.first?.tag)
    XCTAssertEqual(folder.name, NoteStoreSchema.systemMemoryNotebookKindTag)
    XCTAssertEqual(folder.classId, "folder")
    XCTAssertNotEqual(folder.tagId, NoteStoreSchema.systemMemoryNotebookKindTagId)

    let reopened = try NoteService(driver: driver)
    XCTAssertEqual(try reopened.systemMemoryNotebook().notebookId, canonical.notebookId)
    XCTAssertEqual(
      try reopened.listNotebooks(tagFilterIdGroups: [[folder.tagId]]).map(\.notebookId),
      [folderNotebook.notebookId]
    )
  }

  func testBootstrapUsesCanonicalSystemMemoryTagWhenSameNamedFolderAlreadyExists() throws {
    let root = try makeNoteRoot(function: #function)
    let driver = SQLiteNoteDatabaseDriver(noteRoot: root)
    try NoteStoreSchema.prepare(on: driver)
    let folderId = "folder-system-memory-display"
    try driver.withDatabase { database in
      try database.execute(
        """
        INSERT INTO tags (tag_id, name, class_id, is_system, created_at)
        VALUES (?, ?, 'folder', 0, '2026-08-04T00:00:00Z')
        """,
        bindings: [
          .text(folderId),
          .text(NoteStoreSchema.systemMemoryNotebookKindTag)
        ]
      )
    }

    let service = try NoteService(driver: driver)
    let canonical = try service.systemMemoryNotebook()
    XCTAssertTrue(canonical.tags.contains {
      $0.tag.tagId == NoteStoreSchema.systemMemoryNotebookKindTagId
    })
    XCTAssertFalse(canonical.tags.contains { $0.tag.tagId == folderId })
    XCTAssertTrue(try service.listTags().contains {
      $0.tagId == folderId && $0.classId == "folder"
    })
  }

  func testBootstrapRejectsMultipleSystemMemoryTaggedNotebooks() throws {
    let root = try makeNoteRoot(function: #function)
    let driver = SQLiteNoteDatabaseDriver(noteRoot: root)
    let service = try NoteService(driver: driver)
    let duplicate = try service.createNotebook(title: "Duplicate system memory")
    try driver.withDatabase { database in
      try database.execute(
        """
        INSERT INTO notebook_tags (
          notebook_id, tag_id, provenance, assigned_by, deletable, created_at
        )
        SELECT ?, tag_id, 'system', 'test-fixture', 0, '2026-08-01T00:00:00Z'
        FROM tags WHERE name = ?
        """,
        bindings: [
          .text(duplicate.notebookId),
          .text(NoteStoreSchema.systemMemoryNotebookKindTag)
        ]
      )
    }

    XCTAssertThrowsError(try NoteService(driver: driver)) { error in
      guard case let NoteServiceError.invalidInput(message) = error else {
        return XCTFail("expected duplicate system-memory invariant failure, got \(error)")
      }
      XCTAssertTrue(message.contains("multiple notebooks"))
      XCTAssertTrue(message.contains(NoteStoreSchema.systemMemoryNotebookKindTag))
    }
  }

  func testBootstrapRejectsNoncanonicalSystemMemoryAssignment() throws {
    let root = try makeNoteRoot(function: #function)
    let driver = SQLiteNoteDatabaseDriver(noteRoot: root)
    let service = try NoteService(driver: driver)
    let canonical = try service.systemMemoryNotebook()
    try driver.withDatabase { database in
      try database.execute(
        """
        UPDATE notebook_tags
        SET provenance = 'human', assigned_by = 'user', deletable = 1
        WHERE notebook_id = ?
        """,
        bindings: [.text(canonical.notebookId)]
      )
    }

    XCTAssertThrowsError(try NoteService(driver: driver)) { error in
      guard case let NoteServiceError.invalidInput(message) = error else {
        return XCTFail("expected canonical assignment rejection, got \(error)")
      }
      XCTAssertTrue(message.contains("canonical system-memory bootstrap"))
    }
  }

  func testSystemAppendRollsBackNoteAndStagedFilesWhenRelationPersistenceFails() throws {
    let root = try makeNoteRoot(function: #function)
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root))

    XCTAssertThrowsError(
      try service.appendSystemMemoryNote(
        bodyMarkdown: "must roll back",
        tags: [NoteTagInput(name: "persona:yui")],
        relatedNoteIds: ["missing-note"],
        attachments: [
          SystemMemoryAttachmentInput(
            source: .data(Data([1, 2, 3])),
            mediaType: "image/png",
            originalFilename: "rollback.png"
          )
        ]
      )
    )

    XCTAssertTrue(try service.listSystemMemoryNotes(personaId: "yui", limit: 10).isEmpty)
    let filesRoot = URL(fileURLWithPath: root, isDirectory: true)
      .appendingPathComponent("files", isDirectory: true)
    XCTAssertTrue(regularFiles(at: filesRoot).isEmpty)
  }

  func testSystemAppendEnforcesAttachmentCountAndSizeBeforeStaging() throws {
    let root = try makeNoteRoot(function: #function)
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root))
    let tooManyAttachments = (0..<65).map { index in
      SystemMemoryAttachmentInput(
        source: .data(Data([UInt8(index % 255)])),
        mediaType: "application/octet-stream",
        originalFilename: "attachment-\(index).bin",
        position: index
      )
    }

    XCTAssertThrowsError(
      try service.appendSystemMemoryNote(
        bodyMarkdown: "too many attachments",
        tags: [NoteTagInput(name: "persona:yui")],
        attachments: tooManyAttachments
      )
    ) { error in
      guard case let NoteServiceError.invalidInput(message) = error else {
        return XCTFail("expected attachment-count rejection, got \(error)")
      }
      XCTAssertTrue(message.contains("maximum of 64"))
    }

    XCTAssertThrowsError(
      try service.appendSystemMemoryNote(
        bodyMarkdown: "oversized attachment",
        tags: [NoteTagInput(name: "persona:yui")],
        attachments: [SystemMemoryAttachmentInput(
          source: .data(Data(repeating: 0, count: 8 * 1024 * 1024 + 1)),
          mediaType: "application/octet-stream",
          originalFilename: "oversized.bin"
        )]
      )
    ) { error in
      guard case let NoteServiceError.invalidInput(message) = error else {
        return XCTFail("expected attachment-size rejection, got \(error)")
      }
      XCTAssertTrue(message.contains("max 8388608"))
    }

    XCTAssertTrue(try service.listSystemMemoryNotes(personaId: "yui", limit: 10).isEmpty)
    let filesRoot = URL(fileURLWithPath: root, isDirectory: true)
      .appendingPathComponent("files", isDirectory: true)
    XCTAssertTrue(regularFiles(at: filesRoot).isEmpty)
  }

  func testSystemBatchAppendRollsBackEarlierEntriesAndFilesWhenLaterEntryFails() throws {
    let root = try makeNoteRoot(function: #function)
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root))

    XCTAssertThrowsError(
      try service.appendSystemMemoryNotes([
        SystemMemoryNoteInput(
          bodyMarkdown: "must roll back with batch",
          tags: [NoteTagInput(name: "persona:yui")],
          attachments: [SystemMemoryAttachmentInput(
            source: .data(Data([4, 5, 6])),
            mediaType: "image/png",
            originalFilename: "batch-rollback.png"
          )]
        ),
        SystemMemoryNoteInput(
          bodyMarkdown: "later invalid relation",
          tags: [NoteTagInput(name: "persona:yui")],
          relatedNoteIds: ["missing-note"]
        )
      ], idempotencyKey: "batch-rollback")
    )

    XCTAssertTrue(try service.listSystemMemoryNotes(personaId: "yui", limit: 10).isEmpty)
    let fileCount = try service.driver.withDatabase { database in
      try database.query("SELECT COUNT(*) AS count FROM files").first?["count"]
    }
    XCTAssertEqual(fileCount, "0")
    let filesRoot = URL(fileURLWithPath: root, isDirectory: true)
      .appendingPathComponent("files", isDirectory: true)
    XCTAssertTrue(regularFiles(at: filesRoot).isEmpty)
  }

  func testSystemBatchAppendRetryIsIdempotent() throws {
    let root = try makeNoteRoot(function: #function)
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root))
    let inputs = [
      SystemMemoryNoteInput(
        bodyMarkdown: "first retry-safe entry",
        tags: [NoteTagInput(name: "persona:yui")],
        attachments: [SystemMemoryAttachmentInput(
          source: .data(Data([7, 8, 9])),
          mediaType: "image/png",
          originalFilename: "retry.png"
        )]
      ),
      SystemMemoryNoteInput(
        bodyMarkdown: "second retry-safe entry",
        tags: [NoteTagInput(name: "persona:yui")]
      )
    ]

    let first = try service.appendSystemMemoryNotes(inputs, idempotencyKey: "retry-safe-batch")
    let retry = try service.appendSystemMemoryNotes(inputs, idempotencyKey: "retry-safe-batch")

    XCTAssertEqual(retry.map(\.noteId), first.map(\.noteId))
    XCTAssertEqual(try service.listSystemMemoryNotes(personaId: "yui", limit: 10).count, 2)
    let counts = try service.driver.withDatabase { database in
      (
        notes: try database.query("SELECT COUNT(*) AS count FROM notes").first?["count"],
        files: try database.query("SELECT COUNT(*) AS count FROM files").first?["count"]
      )
    }
    XCTAssertEqual(counts.notes, "2")
    XCTAssertEqual(counts.files, "1")
  }
}

private func XCTAssertReservedSystemMemoryTag<T>(
  file: StaticString = #filePath,
  line: UInt = #line,
  operation: () throws -> T
) {
  XCTAssertThrowsError(try operation(), file: file, line: line) { error in
    guard case let NoteServiceError.invalidInput(message) = error else {
      return XCTFail("expected reserved system-memory rejection, got \(error)", file: file, line: line)
    }
    XCTAssertTrue(message.contains(NoteStoreSchema.systemMemoryNotebookKindTag), file: file, line: line)
    XCTAssertTrue(message.contains("canonical system-memory notebook"), file: file, line: line)
  }
}

private func XCTAssertReadOnly<T>(
  _ expectedId: String,
  file: StaticString = #filePath,
  line: UInt = #line,
  operation: () throws -> T
) {
  XCTAssertThrowsError(try operation(), file: file, line: line) { error in
    XCTAssertEqual(error as? NoteServiceError, .readOnly(expectedId), file: file, line: line)
  }
}

private func regularFiles(at root: URL) -> [URL] {
  FileManager.default.enumerator(
    at: root,
    includingPropertiesForKeys: [.isRegularFileKey]
  )?.compactMap { $0 as? URL }.filter { url in
    (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
  } ?? []
}
