import Foundation
@testable import AppCore
import XCTest

private final class RecordingNoteChangeObserver: NoteChangeObserving, @unchecked Sendable {
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

final class NoteChangeObserverTests: NoteTestCase {
  func testSetNotebookReadOnlyPublishesLockAndUnlockEvents() throws {
    let observer = RecordingNoteChangeObserver()
    let service = try NoteService(driver: makeNoteDriver(), changeObserver: observer)
    _ = try service.defineTag(name: "proj/locked", classId: TagClassID("folder"))
    let notebook = try service.createNotebook(title: "Lockable")
    _ = try service.applyNotebookTags(
      notebookId: notebook.notebookId,
      tags: ["proj/locked"],
      provenance: .human
    )

    _ = try service.setNotebookReadOnly(notebookId: notebook.notebookId, readOnly: true)
    _ = try service.setNotebookReadOnly(notebookId: notebook.notebookId, readOnly: false)

    let events = observer.events.filter { $0.kind == NoteChangeEventKind.notebookReadOnly }
    XCTAssertEqual(events.count, 2)
    XCTAssertEqual(events.map(\.notebookId), [notebook.notebookId, notebook.notebookId])
    XCTAssertEqual(events.map(\.tagNames), [["proj/locked"], ["proj/locked"]])
  }

  func testNotebookLifecycleAndTagMutationsPublishTheirOwnKinds() throws {
    let observer = RecordingNoteChangeObserver()
    let service = try NoteService(driver: makeNoteDriver(), changeObserver: observer)
    _ = try service.defineTag(name: "proj/alpha", classId: TagClassID("folder"))
    let notebook = try service.createNotebook(title: "Card")
    try service.applyNotebookTags(
      notebookId: notebook.notebookId,
      tags: ["proj/alpha"],
      provenance: .human
    )
    try service.removeNotebookTag(
      notebookId: notebook.notebookId,
      tagName: "proj/alpha",
      removedBy: .human
    )
    try service.deleteNotebook(notebookId: notebook.notebookId)

    XCTAssertEqual(observer.events.map(\.kind), [
      NoteChangeEventKind.notebookCreated,
      NoteChangeEventKind.notebookTags,
      NoteChangeEventKind.notebookTags,
      NoteChangeEventKind.notebookDeleted
    ])
    // A removal still names the tag it left for scoped catalog refreshes.
    XCTAssertEqual(observer.events[2].tagNames, ["proj/alpha"])
  }

  func testNoteTagApplyAndRemovePublishNoteTagsEvents() throws {
    let observer = RecordingNoteChangeObserver()
    let service = try NoteService(driver: makeNoteDriver(), changeObserver: observer)
    let note = try service.createNote(bodyMarkdown: "# Tagged\nbody")
    _ = try service.applyTags(
      noteId: note.noteId,
      tags: [NoteTagInput(name: "sakura")],
      provenance: .human,
      assignedBy: "test"
    )
    _ = try service.removeTag(noteId: note.noteId, tagName: "sakura", removedBy: .human)
    // A removal of an absent tag changes nothing and must stay silent.
    _ = try service.removeTag(noteId: note.noteId, tagName: "sakura", removedBy: .human)

    let events = observer.events.filter { $0.kind == NoteChangeEventKind.noteTags }
    XCTAssertEqual(events.count, 2)
    XCTAssertEqual(events.map(\.notebookId), [note.notebookId, note.notebookId])
  }

  func testAServiceWithoutAnObserverStillMutates() throws {
    let service = try NoteService(driver: makeNoteDriver())
    let notebook = try service.createNotebook(title: "Card")
    XCTAssertEqual(try service.getNotebook(notebook.notebookId), notebook)
  }
}
