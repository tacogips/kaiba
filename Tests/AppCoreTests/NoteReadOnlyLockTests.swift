import Foundation
@testable import AppCore
import XCTest

/// Coverage for the generic notebook read-only lock. These cases were factored
/// out of the removed system-memory suite: the lock is an ordinary notebook
/// feature and outlived the memory subsystem that first needed it.
final class NoteReadOnlyLockTests: NoteTestCase {
  func testPersistedNotebookLockSurvivesReopenAndUnlockRestoresWrites() throws {
    let root = try makeNoteRoot(function: #function)
    let driver = SQLiteNoteDatabaseDriver(noteRoot: root)
    let firstService = try NoteService(driver: driver)
    let notebook = try firstService.createNotebook(title: "Persisted lock")
    _ = try firstService.setNotebookReadOnly(notebookId: notebook.notebookId, readOnly: true)

    let reopenedService = try NoteService(driver: driver)
    XCTAssertTrue(try reopenedService.getNotebook(notebook.notebookId).readOnly)
    XCTAssertReadOnly(notebook.notebookId) {
      try reopenedService.createNote(notebookId: notebook.notebookId, bodyMarkdown: "blocked")
    }

    let unlocked = try reopenedService.setNotebookReadOnly(
      notebookId: notebook.notebookId,
      readOnly: false
    )
    XCTAssertFalse(unlocked.readOnly)
    let note = try reopenedService.createNote(
      notebookId: notebook.notebookId,
      bodyMarkdown: "user-approved content"
    )
    XCTAssertEqual(note.notebookId, notebook.notebookId)
    XCTAssertFalse(try NoteService(driver: driver).getNotebook(notebook.notebookId).readOnly)
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
    XCTAssertTrue(regularLockTestFiles(at: URL(fileURLWithPath: root).appendingPathComponent("files")).isEmpty)
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

private func regularLockTestFiles(at root: URL) -> [URL] {
  FileManager.default.enumerator(
    at: root,
    includingPropertiesForKeys: [.isRegularFileKey]
  )?.compactMap { $0 as? URL }.filter { url in
    (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
  } ?? []
}
