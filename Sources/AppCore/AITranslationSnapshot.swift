public enum AITranslationStatus: String, Codable, Equatable, Sendable {
  case pending
  case completed
  case failed
  case cancelled
}

public struct AITranslationState: Equatable, Sendable {
  public var sourceNotebookId: NotebookID
  public var targetLanguage: String
  public var status: AITranslationStatus
  public var errorMessage: String?
  public var continuationSourceNoteId: NoteID?
  /// Non-prunable per-notebook source token captured when the current cursor
  /// pass begins. It is transactionally verifiable, so same-clock edits,
  /// deletions, and action-history pruning cannot complete stale work.
  public var sourceNotebookRevision: Int64?

  public init(
    sourceNotebookId: NotebookID,
    targetLanguage: String,
    status: AITranslationStatus,
    errorMessage: String? = nil,
    continuationSourceNoteId: NoteID? = nil,
    sourceNotebookRevision: Int64? = nil
  ) {
    self.sourceNotebookId = sourceNotebookId
    self.targetLanguage = targetLanguage
    self.status = status
    self.errorMessage = errorMessage
    self.continuationSourceNoteId = continuationSourceNoteId
    self.sourceNotebookRevision = sourceNotebookRevision
  }
}

public enum AITranslationReconciliationLimits {
  public static let maximumRounds = 8
  public static let maximumProviderInvocations = 128
  public static let maximumElapsed: Duration = .seconds(300)
}

public enum AITranslationChunkResult: Sendable {
  case completed(Notebook)
  /// A bounded page completed but durable work remains. Reconciliation is
  /// required only when the source revision changed or forced a cursor reset;
  /// ordinary keyset pagination must not consume the churn-round budget.
  case pending(Notebook, reconciliationRequired: Bool)
}

struct TranslationRunSnapshot {
  let sourceNotebookId: NotebookID
  let libraryId: LibraryID?
  let sourceNotes: [TranslationSourceNote]
  let sourceNotebookRevision: Int64
  let restartRequired: Bool
  let reachedEndOfSources: Bool
  let completionTailSourceNote: TranslationSourceNote?
  let translatedSourceContentHashes: [NoteID: Set<String>]
  let translatedSourceOutputCounts: [NoteID: Int]
}

struct TranslationSourceNote: Sendable {
  let noteId: NoteID
  let noteNumber: Int
  let bodyMarkdown: String
}

enum TranslationOutputInsertResult {
  case current(prunedObsoleteOutputs: Bool)
  case sourceChanged
  case created(note: Note, dispatches: [QueuedAutoActionDispatch])
  case replaced(note: Note, dispatches: [QueuedAutoActionDispatch])
}
