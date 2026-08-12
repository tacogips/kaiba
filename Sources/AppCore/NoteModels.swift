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

public enum KanbanStatusCategory: String, Codable, Equatable, Sendable, CaseIterable {
  case none
  case pending
  case progress
  case review
  case done
}

public struct KanbanStatus: Equatable, Sendable {
  public var statusId: String
  public var setId: String
  public var name: String
  public var category: KanbanStatusCategory
  public var position: Int

  public init(statusId: String, setId: String, name: String, category: KanbanStatusCategory, position: Int) {
    self.statusId = statusId
    self.setId = setId
    self.name = name
    self.category = category
    self.position = position
  }
}

public struct KanbanStatusSet: Equatable, Sendable {
  public var setId: String
  public var name: String
  public var isSystem: Bool
  public var statuses: [KanbanStatus]

  public init(setId: String, name: String, isSystem: Bool, statuses: [KanbanStatus]) {
    self.setId = setId
    self.name = name
    self.isSystem = isSystem
    self.statuses = statuses
  }
}

public struct Notebook: Equatable, Sendable {
  public var notebookId: String
  public var title: String
  public var progress: String
  public var readOnly: Bool
  public var createdAt: String
  public var updatedAt: String
  public var metaJSON: String?
  public var tags: [TagAssignment]
  public var firstNotePreview: String?
  public var noteCount: Int?

  public init(
    notebookId: String,
    title: String,
    progress: String = "none",
    readOnly: Bool = false,
    createdAt: String,
    updatedAt: String,
    metaJSON: String? = nil,
    tags: [TagAssignment] = [],
    firstNotePreview: String? = nil,
    noteCount: Int? = nil
  ) {
    self.notebookId = notebookId
    self.title = title
    self.progress = progress
    self.readOnly = readOnly
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.metaJSON = metaJSON
    self.tags = tags
    self.firstNotePreview = firstNotePreview
    self.noteCount = noteCount
  }
}

public struct Note: Equatable, Sendable {
  public var noteId: String
  public var notebookId: String
  public var noteNumber: Int
  public var title: String?
  public var bodyMarkdown: String
  public var readOnly: Bool
  public var createdAt: String
  public var updatedAt: String
  public var metaJSON: String?
  public var tags: [TagAssignment]

  public init(
    noteId: String,
    notebookId: String,
    noteNumber: Int,
    title: String?,
    bodyMarkdown: String,
    readOnly: Bool,
    createdAt: String,
    updatedAt: String,
    metaJSON: String? = nil,
    tags: [TagAssignment] = []
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
  public var classId: String
  public var label: String
  public var description: String?
  public var isSystem: Bool
  public var createdAt: String

  public init(classId: String, label: String, description: String?, isSystem: Bool, createdAt: String) {
    self.classId = classId
    self.label = label
    self.description = description
    self.isSystem = isSystem
    self.createdAt = createdAt
  }
}

public struct Tag: Equatable, Sendable {
  public var tagId: String
  public var name: String
  public var classId: String?
  public var parentTagId: String?
  public var statusSetId: String?
  public var isSystem: Bool
  public var createdAt: String

  public init(
    tagId: String,
    name: String,
    classId: String?,
    parentTagId: String? = nil,
    statusSetId: String? = nil,
    isSystem: Bool,
    createdAt: String
  ) {
    self.tagId = tagId
    self.name = name
    self.classId = classId
    self.parentTagId = parentTagId
    self.statusSetId = statusSetId
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
  public var fileId: String
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
    fileId: String,
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
  public var noteId: String
  public var file: FileRecord
  public var role: NoteFileRole
  public var position: Int

  public init(noteId: String, file: FileRecord, role: NoteFileRole, position: Int) {
    self.noteId = noteId
    self.file = file
    self.role = role
    self.position = position
  }
}

public struct NotebookFileAttachment: Equatable, Sendable {
  public var notebookId: String
  public var file: FileRecord
  public var role: NotebookFileRole

  public init(notebookId: String, file: FileRecord, role: NotebookFileRole) {
    self.notebookId = notebookId
    self.file = file
    self.role = role
  }
}

/// A memo. Anchored to a note (`noteId` set) or to a whole notebook
/// (`noteId` nil); `notebookId` names the containing notebook either way.
public struct NoteComment: Equatable, Sendable {
  public var commentId: String
  public var noteId: String?
  public var notebookId: String?
  public var bodyMarkdown: String
  public var author: String
  public var createdAt: String

  public init(
    commentId: String,
    noteId: String?,
    notebookId: String? = nil,
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
  public var fromNoteId: String
  public var toNoteId: String
  public var linkKind: String
  public var provenance: NoteProvenance
  public var createdAt: String

  public init(
    fromNoteId: String,
    toNoteId: String,
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
  public var actionId: String
  public var trigger: NoteAutoActionTrigger
  public var workflowId: String
  public var filterJSON: String?
  public var enabled: Bool
  public var position: Int
  public var createdAt: String

  public init(
    actionId: String,
    trigger: NoteAutoActionTrigger,
    workflowId: String,
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
}

public struct AutoActionDispatchAttempt: Codable, Equatable, Sendable {
  public var dispatchId: String
  public var record: AutoActionDispatchRecord
  public var status: AutoActionDispatchStatus
  public var attemptCount: Int
  public var lastError: String?
  public var createdAt: String
  public var updatedAt: String

  public init(
    dispatchId: String,
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

public struct NoteAPIClient: Codable, Equatable, Sendable {
  public var clientId: String
  public var displayName: String
  public var tokenHash: String
  public var createdAt: String
  public var lastSeenAt: String?
  public var revokedAt: String?

  public init(
    clientId: String,
    displayName: String,
    tokenHash: String,
    createdAt: String,
    lastSeenAt: String? = nil,
    revokedAt: String? = nil
  ) {
    self.clientId = clientId
    self.displayName = displayName
    self.tokenHash = tokenHash
    self.createdAt = createdAt
    self.lastSeenAt = lastSeenAt
    self.revokedAt = revokedAt
  }
}

public struct NoteSearchResult: Equatable, Sendable {
  public var note: Note
  public var snippet: String
  public var rank: Double
  public var matchedTags: [Tag]
  public var isLinkedNeighbor: Bool

  public init(
    note: Note,
    snippet: String,
    rank: Double,
    matchedTags: [Tag],
    isLinkedNeighbor: Bool = false
  ) {
    self.note = note
    self.snippet = snippet
    self.rank = rank
    self.matchedTags = matchedTags
    self.isLinkedNeighbor = isLinkedNeighbor
  }
}

public struct NoteTagInput: Equatable, Sendable {
  public var name: String
  public var classId: String?

  public init(name: String, classId: String? = nil) {
    self.name = name
    self.classId = classId
  }
}

public struct NoteConversationTurn: Equatable, Sendable {
  public var userMarkdown: String
  public var assistantMarkdown: String
  public var sourceNoteIds: [String]

  public init(userMarkdown: String, assistantMarkdown: String, sourceNoteIds: [String] = []) {
    self.userMarkdown = userMarkdown
    self.assistantMarkdown = assistantMarkdown
    self.sourceNoteIds = sourceNoteIds
  }
}

public struct NoteConversationSourceLinks: Equatable, Sendable {
  public var sourceNoteIds: [String]
  public var linkKind: String
  public var provenance: NoteProvenance
  public var allowMissingSourceNotes: Bool

  public init(
    sourceNoteIds: [String],
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
