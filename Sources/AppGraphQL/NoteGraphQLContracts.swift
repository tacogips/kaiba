import Foundation

import AppCore

public struct GraphQLNoteTagDTO: Codable, Equatable, Sendable {
  public var tagId: String
  public var name: String
  public var classId: String?
  public var parentTagId: String?
  public var statusSetId: String?
  public var isSystem: Bool
  public var createdAt: String

  public init(tag: Tag) {
    tagId = tag.tagId
    name = tag.name
    classId = tag.classId
    parentTagId = tag.parentTagId
    statusSetId = tag.statusSetId
    isSystem = tag.isSystem
    createdAt = tag.createdAt
  }
}

public struct GraphQLNoteTagClassDTO: Codable, Equatable, Sendable {
  public var classId: String
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

public struct GraphQLKanbanStatusDTO: Codable, Equatable, Sendable {
  public var statusId: String
  public var name: String
  public var category: String
  public var position: Int

  public init(status: KanbanStatus) {
    statusId = status.statusId
    name = status.name
    category = status.category.rawValue
    position = status.position
  }
}

public struct GraphQLKanbanStatusSetDTO: Codable, Equatable, Sendable {
  public var setId: String
  public var name: String
  public var isSystem: Bool
  public var statuses: [GraphQLKanbanStatusDTO]

  public init(set: KanbanStatusSet) {
    setId = set.setId
    name = set.name
    isSystem = set.isSystem
    statuses = set.statuses.map(GraphQLKanbanStatusDTO.init)
  }
}

public struct GraphQLKanbanStatusInput: Codable, Equatable, Sendable {
  public var statusId: String?
  public var name: String
  public var category: String

  public init(statusId: String? = nil, name: String, category: String) {
    self.statusId = statusId
    self.name = name
    self.category = category
  }

  public func upsert() throws -> KanbanStatusUpsert {
    guard let parsed = KanbanStatusCategory(rawValue: category) else {
      throw NoteServiceError.invalidInput("unsupported kanban status category: \(category)")
    }
    return KanbanStatusUpsert(statusId: statusId, name: name, category: parsed)
  }
}

public struct GraphQLKanbanStatusReassignmentInput: Codable, Equatable, Sendable {
  public var removedName: String
  public var reassignTo: String

  public init(removedName: String, reassignTo: String) {
    self.removedName = removedName
    self.reassignTo = reassignTo
  }
}

public struct GraphQLNotebookDTO: Codable, Equatable, Sendable {
  public var notebookId: String
  public var title: String
  public var progress: String
  public var readOnly: Bool
  public var createdAt: String
  public var updatedAt: String
  public var metaJSON: String?
  public var tags: [GraphQLNoteTagAssignmentDTO]
  public var firstNotePreview: String?
  public var noteCount: Int?

  public init(notebook: Notebook) {
    notebookId = notebook.notebookId
    title = notebook.title
    progress = notebook.progress
    readOnly = notebook.readOnly
    createdAt = notebook.createdAt
    updatedAt = notebook.updatedAt
    metaJSON = notebook.metaJSON
    tags = notebook.tags.map(GraphQLNoteTagAssignmentDTO.init)
    firstNotePreview = notebook.firstNotePreview
    noteCount = notebook.noteCount
  }
}

public struct GraphQLNoteDTO: Codable, Equatable, Sendable {
  public var noteId: String
  public var notebookId: String
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
  public var fileId: String
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
  public var noteId: String
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
  public var commentId: String
  public var noteId: String
  public var bodyMarkdown: String
  public var author: String
  public var createdAt: String

  public init(comment: NoteComment) {
    commentId = comment.commentId
    noteId = comment.noteId
    bodyMarkdown = comment.bodyMarkdown
    author = comment.author
    createdAt = comment.createdAt
  }
}

public struct GraphQLNoteLinkDTO: Codable, Equatable, Sendable {
  public var fromNoteId: String
  public var toNoteId: String
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
  public var seedNoteId: String
  public var note: GraphQLNoteDTO
  public var edgeKind: String
  public var weight: Double
  public var hopCount: Int
  public var pathNoteIds: [String]

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
  public var targetNoteId: String
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
  public var actionId: String
  public var trigger: String
  public var workflowId: String
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

public struct GraphQLNoteTagInput: Codable, Equatable, Sendable {
  public var name: String
  public var classId: String?

  public init(name: String, classId: String? = nil) {
    self.name = name
    self.classId = classId
  }

  public var noteInput: NoteTagInput {
    NoteTagInput(name: name, classId: classId)
  }
}

public struct GraphQLCreateNoteInput: Codable, Equatable, Sendable {
  public var notebookId: String?
  public var notebookTitle: String?
  public var title: String?
  public var bodyMarkdown: String
  public var readOnly: Bool
  public var tags: [GraphQLNoteTagInput]
  public var provenance: String
  public var assignedBy: String?
  public var metaJSON: String?
  public var originatingActionId: String?

  public init(
    notebookId: String? = nil,
    notebookTitle: String? = nil,
    title: String? = nil,
    bodyMarkdown: String,
    readOnly: Bool = false,
    tags: [GraphQLNoteTagInput] = [],
    provenance: String = NoteProvenance.human.rawValue,
    assignedBy: String? = nil,
    metaJSON: String? = nil,
    originatingActionId: String? = nil
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
    notebookId = try container.decodeIfPresent(String.self, forKey: .notebookId)
    notebookTitle = try container.decodeIfPresent(String.self, forKey: .notebookTitle)
    title = try container.decodeIfPresent(String.self, forKey: .title)
    bodyMarkdown = try container.decode(String.self, forKey: .bodyMarkdown)
    readOnly = try container.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
    tags = try container.decodeIfPresent([GraphQLNoteTagInput].self, forKey: .tags) ?? []
    provenance = try container.decodeIfPresent(String.self, forKey: .provenance) ?? NoteProvenance.human.rawValue
    assignedBy = try container.decodeIfPresent(String.self, forKey: .assignedBy)
    metaJSON = try container.decodeIfPresent(String.self, forKey: .metaJSON)
    originatingActionId = try container.decodeIfPresent(String.self, forKey: .originatingActionId)
  }
}

public struct GraphQLCreateNotebookInput: Codable, Equatable, Sendable {
  public var title: String
  public var kindTagName: String?
  public var folderPath: [String]?
  public var metaJSON: String?
  public var originatingActionId: String?

  public init(
    title: String,
    kindTagName: String? = nil,
    folderPath: [String]? = nil,
    metaJSON: String? = nil,
    originatingActionId: String? = nil
  ) {
    self.title = title
    self.kindTagName = kindTagName
    self.folderPath = folderPath
    self.metaJSON = metaJSON
    self.originatingActionId = originatingActionId
  }
}

public struct GraphQLDefineNoteTagClassInput: Codable, Equatable, Sendable {
  public var classId: String
  public var label: String
  public var description: String?

  public init(classId: String, label: String, description: String? = nil) {
    self.classId = classId
    self.label = label
    self.description = description
  }
}

public struct GraphQLDefineNoteTagInput: Codable, Equatable, Sendable {
  public var name: String
  public var classId: String?
  public var parentTagId: String?
  public var createOnly: Bool

  public init(
    name: String,
    classId: String? = nil,
    parentTagId: String? = nil,
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
    classId = try container.decodeIfPresent(String.self, forKey: .classId)
    parentTagId = try container.decodeIfPresent(String.self, forKey: .parentTagId)
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
  public var fileId: String
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
  public var deletedFileIds: [String]
  public var sweptPaths: [String]

  public init(
    result: GraphQLControlPlaneResult,
    deletedFileIds: [String] = [],
    sweptPaths: [String] = []
  ) {
    self.result = result
    self.deletedFileIds = deletedFileIds
    self.sweptPaths = sweptPaths
  }
}
