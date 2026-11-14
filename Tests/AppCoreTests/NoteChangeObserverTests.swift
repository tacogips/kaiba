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
  func testSetNotebookProgressPublishesAChangeEventCarryingFolderScope() throws {
    let observer = RecordingNoteChangeObserver()
    let service = try NoteService(driver: makeNoteDriver(), changeObserver: observer)
    _ = try service.defineTag(name: "proj/alpha", classId: "folder")
    let notebook = try service.createNotebook(title: "Card")
    try service.applyNotebookTags(
      notebookId: notebook.notebookId,
      tags: ["proj/alpha"],
      provenance: .human
    )

    _ = try service.setNotebookProgress(notebookId: notebook.notebookId, progress: "progress")

    let progressEvents = observer.events.filter { $0.kind == NoteChangeEventKind.notebookProgress }
    XCTAssertEqual(progressEvents.count, 1)
    XCTAssertEqual(progressEvents.first?.notebookId, notebook.notebookId)
    XCTAssertEqual(progressEvents.first?.tagNames, ["proj/alpha"])
  }

  func testARejectedProgressWritePublishesNothing() throws {
    let observer = RecordingNoteChangeObserver()
    let service = try NoteService(driver: makeNoteDriver(), changeObserver: observer)
    let notebook = try service.createNotebook(title: "Card")
    let baseline = observer.events.count

    XCTAssertThrowsError(
      try service.setNotebookProgress(notebookId: notebook.notebookId, progress: "not-a-status")
    )
    XCTAssertEqual(observer.events.count, baseline, "a failed transaction must not publish")
  }

  func testSetNotebookReadOnlyPublishesLockAndUnlockEvents() throws {
    let observer = RecordingNoteChangeObserver()
    let service = try NoteService(driver: makeNoteDriver(), changeObserver: observer)
    _ = try service.defineTag(name: "proj/locked", classId: "folder")
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
    _ = try service.defineTag(name: "proj/alpha", classId: "folder")
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
    // A removal still names the tag it left so that board wakes up too.
    XCTAssertEqual(observer.events[2].tagNames, ["proj/alpha"])
  }

  func testStatusSetMutationsPublishTheStatusSetsKind() throws {
    let observer = RecordingNoteChangeObserver()
    let service = try NoteService(driver: makeNoteDriver(), changeObserver: observer)
    let set = try service.createKanbanStatusSet(
      name: "Delivery",
      statuses: [
        KanbanStatusUpsert(name: "queued", category: .pending),
        KanbanStatusUpsert(name: "shipped", category: .done)
      ]
    )
    try service.deleteKanbanStatusSet(setId: set.setId)

    XCTAssertEqual(
      observer.events.map(\.kind),
      [NoteChangeEventKind.statusSets, NoteChangeEventKind.statusSets]
    )
  }

  func testAServiceWithoutAnObserverStillMutates() throws {
    let service = try NoteService(driver: makeNoteDriver())
    let notebook = try service.createNotebook(title: "Card")
    let updated = try service.setNotebookProgress(notebookId: notebook.notebookId, progress: "progress")
    XCTAssertEqual(updated.progress, "progress")
  }
}
