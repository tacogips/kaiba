import Foundation

public enum NoteProvenance: String, Codable, Equatable, Sendable {
  case human
  case ai
  case system
}

public enum NoteFileStorageKind: String, Codable, Equatable, Sendable {
  case local
  case s3
}

public enum NoteFileRole: String, Codable, Equatable, Sendable {
  case embedded
  case related
  case sourcePageImage = "source-page-image"
}

public enum NotebookFileRole: String, Codable, Equatable, Sendable {
  case sourceDocument = "source-document"
  case related
}

public enum NoteAutoActionTrigger: String, Codable, Equatable, Sendable {
  case noteCreated = "note-created"
  case noteUpdated = "note-updated"
  case notebookCreated = "notebook-created"
}

public struct Notebook: Equatable, Sendable {
  public var notebookId: NotebookID
  public var title: String
  public var readOnly: Bool
  public var createdAt: String
  public var updatedAt: String
  public var metaJSON: String?
  public var tags: [TagAssignment]
  public var firstNotePreview: String?
  public var noteCount: Int?
  /// The library this notebook belongs to. Optional on the model rather than
  /// on the row: a notebook always has one, but the reads that do not select
  /// it leave it nil rather than inventing the default
  /// (`design-docs/specs/library.md`).
  public var libraryId: LibraryID?
  public var ownerUserId: UserID?
  public var createdBy: UserID?
  public var updatedBy: UserID?

  public init(
    notebookId: NotebookID,
    title: String,
    readOnly: Bool = false,
    createdAt: String,
    updatedAt: String,
    metaJSON: String? = nil,
    tags: [TagAssignment] = [],
    firstNotePreview: String? = nil,
    noteCount: Int? = nil,
    libraryId: LibraryID? = nil,
    ownerUserId: UserID? = nil,
    createdBy: UserID? = nil,
    updatedBy: UserID? = nil
  ) {
    self.notebookId = notebookId
    self.title = title
    self.readOnly = readOnly
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.metaJSON = metaJSON
    self.tags = tags
    self.firstNotePreview = firstNotePreview
    self.noteCount = noteCount
    self.libraryId = libraryId
    self.ownerUserId = ownerUserId
    self.createdBy = createdBy
    self.updatedBy = updatedBy
  }
}

/// A named set of notebooks. `authRequired` answers one question — may an
/// unauthenticated caller see this library at all — and per-user reach inside
/// it remains notebook ownership (`design-docs/specs/library.md`).
public struct NoteLibrary: Codable, Equatable, Sendable {
  public var libraryId: LibraryID
  public var name: String
  public var title: String
  public var authRequired: Bool
  public var isDefault: Bool
  public var createdAt: String
  public var createdBy: UserID?
  public var notebookCount: Int?

  public init(
    libraryId: LibraryID,
    name: String,
    title: String,
    authRequired: Bool,
    isDefault: Bool = false,
    createdAt: String,
    createdBy: UserID? = nil,
    notebookCount: Int? = nil
  ) {
    self.libraryId = libraryId
    self.name = name
    self.title = title
    self.authRequired = authRequired
    self.isDefault = isDefault
    self.createdAt = createdAt
    self.createdBy = createdBy
    self.notebookCount = notebookCount
  }
}

public struct Note: Equatable, Sendable {
  public var noteId: NoteID
  public var notebookId: NotebookID
  public var noteNumber: Int
  public var title: String?
  public var bodyMarkdown: String
  public var readOnly: Bool
  public var createdAt: String
  public var updatedAt: String
  public var metaJSON: String?
  public var tags: [TagAssignment]
  public var createdBy: UserID?
  public var updatedBy: UserID?

  public init(
    noteId: NoteID,
    notebookId: NotebookID,
    noteNumber: Int,
    title: String?,
    bodyMarkdown: String,
    readOnly: Bool,
    createdAt: String,
    updatedAt: String,
    metaJSON: String? = nil,
    tags: [TagAssignment] = [],
    createdBy: UserID? = nil,
    updatedBy: UserID? = nil
  ) {
    self.noteId = noteId
    self.notebookId = notebookId
    self.noteNumber = noteNumber
    self.title = title
    self.bodyMarkdown = bodyMarkdown
    self.readOnly = readOnly
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.metaJSON = metaJSON
    self.tags = tags
    self.createdBy = createdBy
    self.updatedBy = updatedBy
  }
}

public struct NotePageDraft: Equatable, Sendable {
  public var bodyMarkdown: String
  public var readOnly: Bool
  public var tags: [NoteTagInput]
  public var metaJSON: String?
  public var noteNumber: Int?

  public init(
    bodyMarkdown: String,
    readOnly: Bool = true,
    tags: [NoteTagInput] = [],
    metaJSON: String? = nil,
    noteNumber: Int? = nil
  ) {
    self.bodyMarkdown = bodyMarkdown
    self.readOnly = readOnly
    self.tags = tags
    self.metaJSON = metaJSON
    self.noteNumber = noteNumber
  }
}

public struct NotebookIngestResult: Equatable, Sendable {
  public var notebook: Notebook
  public var notes: [Note]

  public init(notebook: Notebook, notes: [Note]) {
    self.notebook = notebook
    self.notes = notes
  }
}

public struct TagClass: Equatable, Sendable {
  public var classId: TagClassID
  public var label: String
  public var description: String?
  public var isSystem: Bool
  public var createdAt: String

  public init(classId: TagClassID, label: String, description: String?, isSystem: Bool, createdAt: String) {
    self.classId = classId
    self.label = label
    self.description = description
    self.isSystem = isSystem
    self.createdAt = createdAt
  }
}

public struct Tag: Equatable, Sendable {
  public var tagId: TagID
  public var name: String
  public var classId: TagClassID?
  public var parentTagId: TagID?
  public var isSystem: Bool
  public var createdAt: String

  public init(
    tagId: TagID,
    name: String,
    classId: TagClassID?,
    parentTagId: TagID? = nil,
    isSystem: Bool,
    createdAt: String
  ) {
    self.tagId = tagId
    self.name = name
    self.classId = classId
    self.parentTagId = parentTagId
    self.isSystem = isSystem
    self.createdAt = createdAt
  }
}

public struct TagAssignment: Equatable, Sendable {
  public var tag: Tag
  public var provenance: NoteProvenance
  public var assignedBy: String?
  public var deletable: Bool
  public var createdAt: String

  public init(
    tag: Tag,
    provenance: NoteProvenance,
    assignedBy: String?,
    deletable: Bool,
    createdAt: String
  ) {
    self.tag = tag
    self.provenance = provenance
    self.assignedBy = assignedBy
    self.deletable = deletable
    self.createdAt = createdAt
  }
}

public struct FileRecord: Equatable, Sendable {
  public var fileId: FileID
  public var storageKind: NoteFileStorageKind
  public var localPath: String?
  public var s3Profile: String?
  public var s3Bucket: String?
  public var s3Key: String?
  public var mediaType: String
  public var byteSize: Int64
  public var sha256: String
  public var originalFilename: String?
  public var createdAt: String
  public var migratedAt: String?

  public init(
    fileId: FileID,
    storageKind: NoteFileStorageKind,
    localPath: String?,
    s3Profile: String?,
    s3Bucket: String?,
    s3Key: String?,
    mediaType: String,
    byteSize: Int64,
    sha256: String,
    originalFilename: String?,
    createdAt: String,
    migratedAt: String?
  ) {
    self.fileId = fileId
    self.storageKind = storageKind
    self.localPath = localPath
    self.s3Profile = s3Profile
    self.s3Bucket = s3Bucket
    self.s3Key = s3Key
    self.mediaType = mediaType
    self.byteSize = byteSize
    self.sha256 = sha256
    self.originalFilename = originalFilename
    self.createdAt = createdAt
    self.migratedAt = migratedAt
  }
}

public struct NoteFileAttachment: Equatable, Sendable {
  public var noteId: NoteID
  public var file: FileRecord
  public var role: NoteFileRole
  public var position: Int

  public init(noteId: NoteID, file: FileRecord, role: NoteFileRole, position: Int) {
    self.noteId = noteId
    self.file = file
    self.role = role
    self.position = position
  }
}

public struct NotebookFileAttachment: Equatable, Sendable {
  public var notebookId: NotebookID
  public var file: FileRecord
  public var role: NotebookFileRole

  public init(notebookId: NotebookID, file: FileRecord, role: NotebookFileRole) {
    self.notebookId = notebookId
    self.file = file
    self.role = role
  }
}

/// A memo. Anchored to a note (`noteId` set) or to a whole notebook
/// (`noteId` nil); `notebookId` names the containing notebook either way.
public struct NoteComment: Equatable, Sendable {
  public var commentId: CommentID
  public var noteId: NoteID?
  public var notebookId: NotebookID?
  public var bodyMarkdown: String
  public var author: String
  public var createdAt: String

  public init(
    commentId: CommentID,
    noteId: NoteID?,
    notebookId: NotebookID? = nil,
    bodyMarkdown: String,
    author: String,
    createdAt: String
  ) {
    self.commentId = commentId
    self.noteId = noteId
    self.notebookId = notebookId
    self.bodyMarkdown = bodyMarkdown
    self.author = author
    self.createdAt = createdAt
  }
}

public struct NoteLink: Equatable, Sendable {
  public var fromNoteId: NoteID
  public var toNoteId: NoteID
  public var linkKind: String
  public var provenance: NoteProvenance
  public var createdAt: String

  public init(
    fromNoteId: NoteID,
    toNoteId: NoteID,
    linkKind: String,
    provenance: NoteProvenance,
    createdAt: String
  ) {
    self.fromNoteId = fromNoteId
    self.toNoteId = toNoteId
    self.linkKind = linkKind
    self.provenance = provenance
    self.createdAt = createdAt
  }
}

public enum NoteListSort: String, Codable, Equatable, Sendable, CaseIterable {
  case createdAtDesc
  case createdAtAsc
  case updatedAtDesc
  case title
}

public struct NoteLinkProposal: Equatable, Sendable {
  public var targetNote: Note
  public var linkKind: String
  public var reason: String
  public var source: String

  public init(targetNote: Note, linkKind: String = "related", reason: String, source: String = "deterministic") {
    self.targetNote = targetNote
    self.linkKind = linkKind
    self.reason = reason
    self.source = source
  }
}

public struct AutoAction: Codable, Equatable, Sendable {
  public var actionId: AutoActionID
  public var trigger: NoteAutoActionTrigger
  public var workflowId: WorkflowID
  public var filterJSON: String?
  public var enabled: Bool
  public var position: Int
  public var createdAt: String

  public init(
    actionId: AutoActionID,
    trigger: NoteAutoActionTrigger,
    workflowId: WorkflowID,
    filterJSON: String? = nil,
    enabled: Bool = true,
    position: Int = 0,
    createdAt: String
  ) {
    self.actionId = actionId
    self.trigger = trigger
    self.workflowId = workflowId
    self.filterJSON = filterJSON
    self.enabled = enabled
    self.position = position
    self.createdAt = createdAt
  }
}

public enum AutoActionDispatchStatus: String, Codable, Equatable, Sendable {
  case pending
  case inFlight = "in_flight"
  case dispatched
  case cancelled
}

public struct AutoActionDispatchAttempt: Codable, Equatable, Sendable {
  public var dispatchId: AutoActionDispatchID
  public var record: AutoActionDispatchRecord
  public var status: AutoActionDispatchStatus
  public var attemptCount: Int
  public var lastError: String?
  public var createdAt: String
  public var updatedAt: String

  public init(
    dispatchId: AutoActionDispatchID,
    record: AutoActionDispatchRecord,
    status: AutoActionDispatchStatus,
    attemptCount: Int,
    lastError: String?,
    createdAt: String,
    updatedAt: String
  ) {
    self.dispatchId = dispatchId
    self.record = record
    self.status = status
    self.attemptCount = attemptCount
    self.lastError = lastError
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

/// An account. A store always holds at least the default user, which every
/// unauthenticated request acts as (`design-docs/specs/multi-user.md`).
public struct NoteUser: Codable, Equatable, Sendable {
  public var userId: UserID
  public var email: String?
  public var displayName: String
  public var isDefault: Bool
  /// Reaches every library, and owns whatever an unauthenticated host writes.
  /// A store always has at least one (`design-docs/specs/multi-user.md`).
  public var isAdmin: Bool
  public var createdAt: String
  public var disabledAt: String?

  public init(
    userId: UserID,
    email: String? = nil,
    displayName: String,
    isDefault: Bool = false,
    isAdmin: Bool = false,
    createdAt: String,
    disabledAt: String? = nil
  ) {
    self.userId = userId
    self.email = email
    self.displayName = displayName
    self.isDefault = isDefault
    self.isAdmin = isAdmin
    self.createdAt = createdAt
    self.disabledAt = disabledAt
  }

  public var isEnabled: Bool {
    disabledAt == nil
  }
}

public struct NoteAPIClient: Codable, Equatable, Sendable {
  public var clientId: APIClientID
  public var displayName: String
  public var tokenHash: String
  /// The account this credential acts as.
  public var userId: UserID
  public var createdAt: String
  public var lastSeenAt: String?
  public var revokedAt: String?

  public init(
    clientId: APIClientID,
    displayName: String,
    tokenHash: String,
    userId: UserID,
    createdAt: String,
    lastSeenAt: String? = nil,
    revokedAt: String? = nil
  ) {
    self.clientId = clientId
    self.displayName = displayName
    self.tokenHash = tokenHash
    self.userId = userId
    self.createdAt = createdAt
    self.lastSeenAt = lastSeenAt
    self.revokedAt = revokedAt
  }
}

public struct NoteSearchResult: Equatable, Sendable {
  public var note: Note
  public var snippet: String
  /// Retriever-specific score: bm25 (lower is better) for a strict full-text
  /// hit, a reciprocal-rank-fusion score for a relaxed hit, personalized
  /// PageRank mass for a graph neighbour, and 1 for a substring fallback hit.
  public var rank: Double
  public var matchedTags: [Tag]
  public var isLinkedNeighbor: Bool
  /// Fraction of the query's indexable terms the note matched: 1 for a full
  /// match, `m/n` for a relaxed match
  /// (`design-docs/specs/note-retrieval-fusion.md`, RF2).
  public var termCoverage: Double

  public init(
    note: Note,
    snippet: String,
    rank: Double,
    matchedTags: [Tag],
    isLinkedNeighbor: Bool = false,
    termCoverage: Double = 1
  ) {
    self.note = note
    self.snippet = snippet
    self.rank = rank
    self.matchedTags = matchedTags
    self.isLinkedNeighbor = isLinkedNeighbor
    self.termCoverage = termCoverage
  }
}

public struct NoteTagInput: Equatable, Sendable {
  public var name: String
  public var classId: TagClassID?

  public init(name: String, classId: TagClassID? = nil) {
    self.name = name
    self.classId = classId
  }
}

public struct NoteConversationTurn: Equatable, Sendable {
  public var userMarkdown: String
  public var assistantMarkdown: String
  public var sourceNoteIds: [NoteID]

  public init(userMarkdown: String, assistantMarkdown: String, sourceNoteIds: [NoteID] = []) {
    self.userMarkdown = userMarkdown
    self.assistantMarkdown = assistantMarkdown
    self.sourceNoteIds = sourceNoteIds
  }
}

public struct NoteConversationSourceLinks: Equatable, Sendable {
  public var sourceNoteIds: [NoteID]
  public var linkKind: String
  public var provenance: NoteProvenance
  public var allowMissingSourceNotes: Bool

  public init(
    sourceNoteIds: [NoteID],
    linkKind: String = "source-citation",
    provenance: NoteProvenance = .ai,
    allowMissingSourceNotes: Bool = false
  ) {
    self.sourceNoteIds = sourceNoteIds
    self.linkKind = linkKind
    self.provenance = provenance
    self.allowMissingSourceNotes = allowMissingSourceNotes
  }
}

public struct SavedConversation: Equatable, Sendable {
  public var notebook: Notebook
  public var notes: [Note]

  public init(notebook: Notebook, notes: [Note]) {
    self.notebook = notebook
    self.notes = notes
  }
}
