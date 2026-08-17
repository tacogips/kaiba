import Foundation

/// A committed store change a live view may need to react to. `tagNames` holds
/// the folder-class tags of the affected notebook when they are cheaply
/// available; an empty array means the affected tag scope is unknown.
public struct NoteChangeEvent: Equatable, Sendable {
  public var kind: String
  public var notebookId: NotebookID?
  public var tagNames: [String]

  public init(kind: String, notebookId: NotebookID? = nil, tagNames: [String] = []) {
    self.kind = kind
    self.notebookId = notebookId
    self.tagNames = tagNames
  }
}

public enum NoteChangeEventKind {
  public static let notebookReadOnly = "notebook-read-only"
  public static let notebookCreated = "notebook-created"
  public static let notebookDeleted = "notebook-deleted"
  public static let notebookTags = "notebook-tags"
  public static let noteTags = "note-tags"
  public static let noteCreated = "note-created"
  public static let noteUpdated = "note-updated"
}

/// Sync and fire-and-forget: the mutating thread must never block on a
/// subscriber, so implementations hop to their own executor.
public protocol NoteChangeObserving: Sendable {
  func noteStoreDidChange(_ event: NoteChangeEvent)
}

extension NoteService {
  /// Publishes after a successful transaction only; a throwing mutation never
  /// reaches its publish call.
  func publishChange(_ event: NoteChangeEvent) {
    changeObserver?.noteStoreDidChange(event)
  }
}

func folderTagNames(of notebook: Notebook) -> [String] {
  notebook.tags.filter { $0.tag.classId == .folder }.map(\.tag.name).sorted()
}
