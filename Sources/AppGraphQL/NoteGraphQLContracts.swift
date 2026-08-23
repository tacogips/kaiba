import Foundation

import AppCore

public struct GraphQLNoteTagDTO: Codable, Equatable, Sendable {
  public var tagId: TagID
  public var name: String
  public var classId: TagClassID?
  public var parentTagId: TagID?
  public var isSystem: Bool
  public var createdAt: String

  public init(tag: Tag) {
    tagId = tag.tagId
    name = tag.name
    classId = tag.classId
    parentTagId = tag.parentTagId
    isSystem = tag.isSystem
    createdAt = tag.createdAt
  }
}

public struct GraphQLNoteTagClassDTO: Codable, Equatable, Sendable {
  public var classId: TagClassID
  public var label: String
  public var description: String?
  public var isSystem: Bool
  public var createdAt: String

  public init(tagClass: TagClass) {
    classId = tagClass.classId
    label = tagClass.label
    description = tagClass.description
    isSystem = tagClass.isSystem
    createdAt = tagClass.createdAt
  }
}

public struct GraphQLNoteTagAssignmentDTO: Codable, Equatable, Sendable {
  public var tag: GraphQLNoteTagDTO
  public var provenance: String
  public var assignedBy: String?
  public var deletable: Bool
  public var createdAt: String

  public init(assignment: TagAssignment) {
    tag = GraphQLNoteTagDTO(tag: assignment.tag)
    provenance = assignment.provenance.rawValue
    assignedBy = assignment.assignedBy
    deletable = assignment.deletable
    createdAt = assignment.createdAt
  }
}

public struct GraphQLNotebookDTO: Codable, Equatable, Sendable {
  public var notebookId: NotebookID
  public var title: String
  public var readOnly: Bool
  public var createdAt: String
  public var updatedAt: String
  public var metaJSON: String?
  public var tags: [GraphQLNoteTagAssignmentDTO]
  public var firstNotePreview: String?
  public var noteCount: Int?

  public var libraryId: LibraryID?

  public init(notebook: Notebook) {
    notebookId = notebook.notebookId
    title = notebook.title
    readOnly = notebook.readOnly
    createdAt = notebook.createdAt
    updatedAt = notebook.updatedAt
    metaJSON = notebook.metaJSON
    tags = notebook.tags.map(GraphQLNoteTagAssignmentDTO.init)
    firstNotePreview = notebook.firstNotePreview
    noteCount = notebook.noteCount
    libraryId = notebook.libraryId
  }
}

/// A library as the API reports it (`design-docs/specs/library.md`). Carries
/// no credential material: `authRequired` is a policy flag, and the scope a
/// library reads secrets from lives in the CLI's `library env`.
public struct GraphQLNoteLibraryDTO: Codable, Equatable, Sendable {
  public var libraryId: LibraryID
  public var name: String
  public var title: String
  public var authRequired: Bool
  public var isDefault: Bool
  public var createdAt: String
  public var notebookCount: Int?

  public init(library: NoteLibrary) {
    libraryId = library.libraryId
    name = library.name
    title = library.title
    authRequired = library.authRequired
    isDefault = library.isDefault
    createdAt = library.createdAt
    notebookCount = library.notebookCount
  }
}

public struct GraphQLNoteDTO: Codable, Equatable, Sendable {
  public var noteId: NoteID
  public var notebookId: NotebookID
  public var noteNumber: Int
  public var title: String?
  public var bodyMarkdown: String
  public var readOnly: Bool
  public var createdAt: String
  public var updatedAt: String
  public var metaJSON: String?
  public var tags: [GraphQLNoteTagAssignmentDTO]

  public init(note: Note) {
    noteId = note.noteId
    notebookId = note.notebookId
    noteNumber = note.noteNumber
    title = note.title
    bodyMarkdown = note.bodyMarkdown
    readOnly = note.readOnly
    createdAt = note.createdAt
    updatedAt = note.updatedAt
    metaJSON = note.metaJSON
    tags = note.tags.map(GraphQLNoteTagAssignmentDTO.init)
  }
}

public struct GraphQLNoteFileDTO: Codable, Equatable, Sendable {
  public var fileId: FileID
  public var storageKind: String
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

  public init(file: FileRecord) {
    fileId = file.fileId
    storageKind = file.storageKind.rawValue
    localPath = file.localPath
    s3Profile = file.s3Profile
    s3Bucket = file.s3Bucket
    s3Key = file.s3Key
    mediaType = file.mediaType
    byteSize = file.byteSize
    sha256 = file.sha256
    originalFilename = file.originalFilename
    createdAt = file.createdAt
    migratedAt = file.migratedAt
  }
}

public struct GraphQLNoteFileAttachmentDTO: Codable, Equatable, Sendable {
  public var noteId: NoteID
  public var file: GraphQLNoteFileDTO
  public var role: String
  public var position: Int

  public init(attachment: NoteFileAttachment) {
    noteId = attachment.noteId
    file = GraphQLNoteFileDTO(file: attachment.file)
    role = attachment.role.rawValue
    position = attachment.position
  }
}

public struct GraphQLNoteCommentDTO: Codable, Equatable, Sendable {
  public var commentId: CommentID
  /// Nil for a notebook-level memo (anchored to the notebook, not a note).
  public var noteId: NoteID?
  public var notebookId: NotebookID?
  public var bodyMarkdown: String
  public var author: String
  public var createdAt: String

  public init(comment: NoteComment) {
    commentId = comment.commentId
    noteId = comment.noteId
    notebookId = comment.notebookId
    bodyMarkdown = comment.bodyMarkdown
    author = comment.author
    createdAt = comment.createdAt
  }
}

public struct GraphQLTagDetailDTO: Codable, Equatable, Sendable {
  public var tag: GraphQLNoteTagDTO
  public var tagClass: GraphQLNoteTagClassDTO?
  public var noteCount: Int
  public var notebookCount: Int
  public var memoNotebookId: NotebookID?

  public init(detail: TagDetail) {
    tag = GraphQLNoteTagDTO(tag: detail.tag)
    tagClass = detail.tagClass.map(GraphQLNoteTagClassDTO.init)
    noteCount = detail.noteCount
    notebookCount = detail.notebookCount
    memoNotebookId = detail.memoNotebookId
  }
}

public struct GraphQLTagCommentDTO: Codable, Equatable, Sendable {
  public var comment: GraphQLNoteCommentDTO
  public var noteTitle: String?
  public var notebookTitle: String?

  public init(attributed: TagAttributedComment) {
    comment = GraphQLNoteCommentDTO(comment: attributed.comment)
    noteTitle = attributed.noteTitle
    notebookTitle = attributed.notebookTitle
  }
}

public struct GraphQLNoteLinkDTO: Codable, Equatable, Sendable {
  public var fromNoteId: NoteID
  public var toNoteId: NoteID
  public var linkKind: String
  public var provenance: String
  public var createdAt: String

  public init(link: NoteLink) {
    fromNoteId = link.fromNoteId
    toNoteId = link.toNoteId
    linkKind = link.linkKind
    provenance = link.provenance.rawValue
    createdAt = link.createdAt
  }
}

public struct GraphQLNoteSearchResultDTO: Codable, Equatable, Sendable {
  public var note: GraphQLNoteDTO
  public var snippet: String
  public var rank: Double
  public var matchedTags: [GraphQLNoteTagDTO]
  public var isLinkedNeighbor: Bool

  public init(result: NoteSearchResult) {
    note = GraphQLNoteDTO(note: result.note)
    snippet = result.snippet
    rank = result.rank
    matchedTags = result.matchedTags.map(GraphQLNoteTagDTO.init)
    isLinkedNeighbor = result.isLinkedNeighbor
  }
}

public struct GraphQLNoteGraphNeighborDTO: Codable, Equatable, Sendable {
  public var seedNoteId: NoteID
  public var note: GraphQLNoteDTO
  public var edgeKind: String
  public var weight: Double
  public var hopCount: Int
  public var pathNoteIds: [NoteID]

  public init(result: NoteGraphNeighbor) {
    seedNoteId = result.seedNoteId
    note = GraphQLNoteDTO(note: result.note)
    edgeKind = result.edgeKind.rawValue
    weight = result.weight
    hopCount = result.hopCount
    pathNoteIds = result.pathNoteIds
  }
}

public struct GraphQLNoteLinkProposalDTO: Codable, Equatable, Sendable {
  public var targetNote: GraphQLNoteDTO
  public var targetNoteId: NoteID
  public var linkKind: String
  public var reason: String
  public var source: String

  public init(proposal: NoteLinkProposal) {
    targetNote = GraphQLNoteDTO(note: proposal.targetNote)
    targetNoteId = proposal.targetNote.noteId
    linkKind = proposal.linkKind
    reason = proposal.reason
    source = proposal.source
  }
}

public struct GraphQLNoteAutoActionDTO: Codable, Equatable, Sendable {
  public var actionId: AutoActionID
  public var trigger: String
  public var workflowId: WorkflowID
  public var filterJSON: String?
  public var enabled: Bool
  public var position: Int
  public var createdAt: String

  public init(action: AutoAction) {
    actionId = action.actionId
    trigger = action.trigger.rawValue
    workflowId = action.workflowId
    filterJSON = action.filterJSON
    enabled = action.enabled
    position = action.position
    createdAt = action.createdAt
  }
}

public struct GraphQLAgentConversationDTO: Codable, Equatable, Sendable {
  public var notebookId: NotebookID
  public var title: String
  public var updatedAt: String
  public var turnCount: Int
  /// Nil for a notebook-scoped conversation.
  public var subjectNoteId: NoteID?
  public var subjectNotebookId: NotebookID?

  public init(conversation: AgentChatConversation) {
    notebookId = conversation.notebook.notebookId
    title = conversation.notebook.title
    updatedAt = conversation.notebook.updatedAt
    turnCount = conversation.turnCount
    subjectNoteId = conversation.subjectNoteId
    subjectNotebookId = conversation.subjectNotebookId
  }
}

public struct GraphQLAgentModelDTO: Codable, Equatable, Sendable {
  public var modelId: String
  public var displayName: String?
  public var description: String?

  public init(model: AgentGatewayModelInfo) {
    modelId = model.modelId
    displayName = model.name
    description = model.description
  }

  public init(modelId: String) {
    self.modelId = modelId
  }
}

public struct GraphQLAgentModelsResult: Codable, Equatable, Sendable {
  public var result: GraphQLControlPlaneResult
  public var models: [GraphQLAgentModelDTO]
  public var discoveryAvailable: Bool
  public var configuredModel: String?

  public init(
    result: GraphQLControlPlaneResult,
    models: [GraphQLAgentModelDTO],
    discoveryAvailable: Bool,
    configuredModel: String?
  ) {
    self.result = result
    self.models = models
    self.discoveryAvailable = discoveryAvailable
    self.configuredModel = configuredModel
  }
}

public struct GraphQLAppSettingResult: Codable, Equatable, Sendable {
  public var result: GraphQLControlPlaneResult
  public var key: String
  /// Nil when the setting has never been stored.
  public var valueJSON: String?

  public init(result: GraphQLControlPlaneResult, key: String, valueJSON: String? = nil) {
    self.result = result
    self.key = key
    self.valueJSON = valueJSON
  }
}

public struct GraphQLAgenticSearchResult: Codable, Equatable, Sendable {
  public var result: GraphQLControlPlaneResult
  /// "ok", "agent-unavailable", or "failed".
  public var status: String
  public var answerMarkdown: String?

  public init(
    result: GraphQLControlPlaneResult,
    status: String,
    answerMarkdown: String? = nil
  ) {
    self.result = result
    self.status = status
    self.answerMarkdown = answerMarkdown
  }
}

public struct GraphQLAgentChatMessageResult: Codable, Equatable, Sendable {
  public var result: GraphQLControlPlaneResult
  public var conversationNotebookId: NotebookID?
  public var turnNoteId: NoteID?
  public var agentStatus: String

  public init(
    result: GraphQLControlPlaneResult,
    conversationNotebookId: NotebookID? = nil,
    turnNoteId: NoteID? = nil,
    agentStatus: String
  ) {
    self.result = result
    self.conversationNotebookId = conversationNotebookId
    self.turnNoteId = turnNoteId
    self.agentStatus = agentStatus
  }
}

public struct GraphQLTagExtractionRequestResult: Codable, Equatable, Sendable {
  public var result: GraphQLControlPlaneResult
  public var status: String

  public init(result: GraphQLControlPlaneResult, status: String) {
    self.result = result
    self.status = status
  }
}

public struct GraphQLNotebookTranslationRequestResult: Codable, Equatable, Sendable {
  public var result: GraphQLControlPlaneResult
  public var translationNotebookId: NotebookID?
  public var status: String

  public init(
    result: GraphQLControlPlaneResult,
    translationNotebookId: NotebookID? = nil,
    status: String
  ) {
    self.result = result
    self.translationNotebookId = translationNotebookId
    self.status = status
  }
}

public struct GraphQLNoteTagInput: Codable, Equatable, Sendable {
  public var name: String
  public var classId: TagClassID?

  public init(name: String, classId: TagClassID? = nil) {
    self.name = name
    self.classId = classId
  }

  public var noteInput: NoteTagInput {
    NoteTagInput(name: name, classId: classId)
  }
}

public struct GraphQLCreateNoteInput: Codable, Equatable, Sendable {
  public var notebookId: NotebookID?
  public var notebookTitle: String?
  public var title: String?
  public var bodyMarkdown: String
  public var readOnly: Bool
  public var tags: [GraphQLNoteTagInput]
  public var provenance: String
  public var assignedBy: String?
  public var metaJSON: String?
  public var originatingActionId: AutoActionID?

  public init(
    notebookId: NotebookID? = nil,
    notebookTitle: String? = nil,
    title: String? = nil,
    bodyMarkdown: String,
    readOnly: Bool = false,
    tags: [GraphQLNoteTagInput] = [],
    provenance: String = NoteProvenance.human.rawValue,
    assignedBy: String? = nil,
    metaJSON: String? = nil,
    originatingActionId: AutoActionID? = nil
  ) {
    self.notebookId = notebookId
    self.notebookTitle = notebookTitle
    self.title = title
    self.bodyMarkdown = bodyMarkdown
    self.readOnly = readOnly
    self.tags = tags
    self.provenance = provenance
    self.assignedBy = assignedBy
    self.metaJSON = metaJSON
    self.originatingActionId = originatingActionId
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    notebookId = try container.decodeIfPresent(NotebookID.self, forKey: .notebookId)
    notebookTitle = try container.decodeIfPresent(String.self, forKey: .notebookTitle)
    title = try container.decodeIfPresent(String.self, forKey: .title)
    bodyMarkdown = try container.decode(String.self, forKey: .bodyMarkdown)
    readOnly = try container.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
    tags = try container.decodeIfPresent([GraphQLNoteTagInput].self, forKey: .tags) ?? []
    provenance = try container.decodeIfPresent(String.self, forKey: .provenance) ?? NoteProvenance.human.rawValue
    assignedBy = try container.decodeIfPresent(String.self, forKey: .assignedBy)
    metaJSON = try container.decodeIfPresent(String.self, forKey: .metaJSON)
    originatingActionId = try container.decodeIfPresent(AutoActionID.self, forKey: .originatingActionId)
  }
}

public struct GraphQLCreateNotebookInput: Codable, Equatable, Sendable {
  public var title: String
  public var kindTagName: String?
  public var folderPath: [String]?
  public var metaJSON: String?
  public var originatingActionId: AutoActionID?

  public init(
    title: String,
    kindTagName: String? = nil,
    folderPath: [String]? = nil,
    metaJSON: String? = nil,
    originatingActionId: AutoActionID? = nil
  ) {
    self.title = title
    self.kindTagName = kindTagName
    self.folderPath = folderPath
    self.metaJSON = metaJSON
    self.originatingActionId = originatingActionId
  }
}

public struct GraphQLDefineNoteTagClassInput: Codable, Equatable, Sendable {
  public var classId: TagClassID
  public var label: String
  public var description: String?

  public init(classId: TagClassID, label: String, description: String? = nil) {
    self.classId = classId
    self.label = label
    self.description = description
  }
}

public struct GraphQLDefineNoteTagInput: Codable, Equatable, Sendable {
  public var name: String
  public var classId: TagClassID?
  public var parentTagId: TagID?
  public var createOnly: Bool

  public init(
    name: String,
    classId: TagClassID? = nil,
    parentTagId: TagID? = nil,
    createOnly: Bool = false
  ) {
    self.name = name
    self.classId = classId
    self.parentTagId = parentTagId
    self.createOnly = createOnly
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    name = try container.decode(String.self, forKey: .name)
    classId = try container.decodeIfPresent(TagClassID.self, forKey: .classId)
    parentTagId = try container.decodeIfPresent(TagID.self, forKey: .parentTagId)
    createOnly = try container.decodeIfPresent(Bool.self, forKey: .createOnly) ?? false
  }
}

public struct GraphQLNoteMutationResult: Codable, Equatable, Sendable {
  public var result: GraphQLControlPlaneResult
  public var note: GraphQLNoteDTO?
  public var notebook: GraphQLNotebookDTO?
  public var notes: [GraphQLNoteDTO]
  public var tag: GraphQLNoteTagDTO?
  public var tagClass: GraphQLNoteTagClassDTO?
  public var file: GraphQLNoteFileDTO?
  public var comment: GraphQLNoteCommentDTO?
  public var link: GraphQLNoteLinkDTO?
  public var autoAction: GraphQLNoteAutoActionDTO?

  public init(
    result: GraphQLControlPlaneResult,
    note: GraphQLNoteDTO? = nil,
    notebook: GraphQLNotebookDTO? = nil,
    notes: [GraphQLNoteDTO] = [],
    tag: GraphQLNoteTagDTO? = nil,
    tagClass: GraphQLNoteTagClassDTO? = nil,
    file: GraphQLNoteFileDTO? = nil,
    comment: GraphQLNoteCommentDTO? = nil,
    link: GraphQLNoteLinkDTO? = nil,
    autoAction: GraphQLNoteAutoActionDTO? = nil
  ) {
    self.result = result
    self.note = note
    self.notebook = notebook
    self.notes = notes
    self.tag = tag
    self.tagClass = tagClass
    self.file = file
    self.comment = comment
    self.link = link
    self.autoAction = autoAction
  }
}

public struct GraphQLNoteFileMigrationFailureDTO: Codable, Equatable, Sendable {
  public var fileId: FileID
  public var message: String

  public init(_ failure: NoteFileMigrationFailure) {
    fileId = failure.fileId
    message = failure.message
  }
}

public struct GraphQLNoteFileMigrationResult: Codable, Equatable, Sendable {
  public var result: GraphQLControlPlaneResult
  public var migrated: [GraphQLNoteFileDTO]
  public var failures: [GraphQLNoteFileMigrationFailureDTO]
  public var cleanupFailures: [GraphQLNoteFileMigrationFailureDTO]

  public init(
    result: GraphQLControlPlaneResult,
    migrated: [GraphQLNoteFileDTO] = [],
    failures: [GraphQLNoteFileMigrationFailureDTO] = [],
    cleanupFailures: [GraphQLNoteFileMigrationFailureDTO] = []
  ) {
    self.result = result
    self.migrated = migrated
    self.failures = failures
    self.cleanupFailures = cleanupFailures
  }
}

public struct GraphQLNoteFileReclamationResult: Codable, Equatable, Sendable {
  public var result: GraphQLControlPlaneResult
  public var deletedFileIds: [FileID]
  public var sweptPaths: [String]

  public init(
    result: GraphQLControlPlaneResult,
    deletedFileIds: [FileID] = [],
    sweptPaths: [String] = []
  ) {
    self.result = result
    self.deletedFileIds = deletedFileIds
    self.sweptPaths = sweptPaths
  }
}

public struct GraphQLNoteStoreCheckResult: Codable, Equatable, Sendable {
  public var result: GraphQLControlPlaneResult
  public var schemaVersion: Int
  public var healthy: Bool
  public var integrityMessages: [String]
  public var foreignKeyViolations: [String]
  public var searchIndexHealthy: Bool
  public var notesMissingFromSearchIndex: [NoteID]
  public var orphanedSearchIndexRows: Int
  public var unreferencedFiles: Int
  public var searchIndexRepaired: Bool

  public init(result: GraphQLControlPlaneResult, report: NoteStoreCheckReport) {
    self.result = result
    self.schemaVersion = report.schemaVersion
    self.healthy = report.isHealthy
    self.integrityMessages = report.integrityMessages
    self.foreignKeyViolations = report.foreignKeyViolations
    self.searchIndexHealthy = report.searchIndexHealthy
    self.notesMissingFromSearchIndex = report.notesMissingFromSearchIndex
    self.orphanedSearchIndexRows = report.orphanedSearchIndexRows
    self.unreferencedFiles = report.unreferencedFiles
    self.searchIndexRepaired = report.searchIndexRepaired
  }
}

public struct GraphQLNoteStoreOptimizationResult: Codable, Equatable, Sendable {
  public var result: GraphQLControlPlaneResult
  public var vacuumed: Bool
  public var bytesBefore: Int64
  public var bytesAfter: Int64
  public var freelistPagesBefore: Int64
  public var freelistPagesAfter: Int64

  public init(result: GraphQLControlPlaneResult, report: NoteStoreOptimizationReport) {
    self.result = result
    self.vacuumed = report.vacuumed
    self.bytesBefore = report.bytesBefore
    self.bytesAfter = report.bytesAfter
    self.freelistPagesBefore = report.freelistPagesBefore
    self.freelistPagesAfter = report.freelistPagesAfter
  }
}
