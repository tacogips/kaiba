public enum TranslationJobStatus: String, Codable, Equatable, Sendable {
  case pending
  case completed
  case failed
  case cancelled
}

/// One translation request (`translation_jobs`).
public struct TranslationJob: Codable, Equatable, Sendable {
  public var jobId: TranslationJobID
  public var notebookId: NotebookID
  public var targetLanguage: String
  /// Inclusive note-number (physical page) range; nil translates every note.
  public var pageStart: Int?
  public var pageEnd: Int?
  public var status: TranslationJobStatus
  public var errorMessage: String?
  /// The last note of the current pass that is known to be translated.
  public var continuationNoteId: NoteID?
  /// The notebook revision captured when the current pass began.
  public var sourceRevision: Int64?
  public var createdAt: String
  public var updatedAt: String
}

/// The Translated version of a note in one language (`note_translations`).
public struct NoteTranslation: Codable, Equatable, Sendable {
  public var noteId: NoteID
  public var language: String
  public var body: String
  /// False once the source text changed after this translation was produced.
  public var isCurrent: Bool
  public var updatedAt: String
}

public enum AITranslationReconciliationLimits {
  public static let maximumRounds = 8
  public static let maximumProviderInvocations = 128
  public static let maximumElapsed: Duration = .seconds(300)
}

public enum AITranslationChunkResult: Sendable {
  case completed(TranslationJob)
  /// A bounded chunk finished but work remains. Reconciliation is required
  /// only when the source changed and the pass restarted; ordinary keyset
  /// pagination must not consume the churn-round budget.
  case pending(TranslationJob, reconciliationRequired: Bool)
}

struct TranslationSourceNote: Sendable {
  let noteId: NoteID
  let text: String
  let existingSourceContentHash: String?
}

struct TranslationRunSnapshot {
  let passRevision: Int64
  /// The revision moved since the previous chunk, so this chunk restarted
  /// the pass from the first note.
  let restarted: Bool
  let sourceNotes: [TranslationSourceNote]
  let reachedEndOfSources: Bool
}
