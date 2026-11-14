import Foundation

public struct KaibaControlPlaneResult: Codable, Equatable, Sendable {
  public var accepted: Bool
  public var status: KaibaOperationStatus
  public var diagnostics: [String]

  public init(accepted: Bool, status: KaibaOperationStatus, diagnostics: [String] = []) {
    self.accepted = accepted
    self.status = status
    self.diagnostics = diagnostics
  }
}

public struct KaibaTag: Codable, Equatable, Sendable {
  public var tagId: KaibaTagID
  public var name: String
  public var classId: String?
  public var parentTagId: KaibaTagID?
  public var isSystem: Bool
  public var createdAt: String
}

public struct KaibaTagClass: Codable, Equatable, Sendable {
  public var classId: String
  public var label: String
  public var description: String?
  public var isSystem: Bool
  public var createdAt: String
}

public struct KaibaTagInput: Codable, Equatable, Sendable {
  public var name: String
  public var classId: String?

  public init(name: String, classId: String? = nil) {
    self.name = name
    self.classId = classId
  }
}

public struct KaibaTagAssignment: Codable, Equatable, Sendable {
  public var tag: KaibaTag
  public var provenance: String
  public var assignedBy: String?
  public var deletable: Bool
  public var createdAt: String
}

public struct KaibaNote: Codable, Equatable, Sendable {
  public var noteId: KaibaNoteID
  public var notebookId: KaibaNotebookID
  public var noteNumber: Int
  public var title: String?
  public var bodyMarkdown: String
  public var readOnly: Bool
  public var createdAt: String
  public var updatedAt: String
  public var metaJSON: String?
  public var tags: [KaibaTagAssignment]
  public var createdBy: String?
  public var updatedBy: String?
}

public struct KaibaNotebook: Codable, Equatable, Sendable {
  public var notebookId: KaibaNotebookID
  public var title: String
  public var readOnly: Bool
  public var createdAt: String
  public var updatedAt: String
  public var metaJSON: String?
  public var tags: [KaibaTagAssignment]
  public var firstNotePreview: String?
  public var noteCount: Int?
  public var libraryId: String?
  public var ownerUserId: String?
  public var createdBy: String?
  public var updatedBy: String?
}

public struct KaibaFile: Codable, Equatable, Sendable {
  public var fileId: KaibaFileID
  public var storageKind: String
  public var localPath: String?
  public var s3Profile: String?
  public var s3Bucket: String?
  public var s3Key: String?
  public var mediaType: String
  public var byteSize: Int
  public var sha256: String
  public var originalFilename: String?
  public var createdAt: String
  public var migratedAt: String?

  public var s3URL: String? {
    guard storageKind == "s3", let s3Bucket, let s3Key else { return nil }
    return "s3://\(s3Bucket)/\(s3Key)"
  }
}

public struct KaibaFileAttachment: Codable, Equatable, Sendable {
  public var noteId: KaibaNoteID?
  public var notebookId: KaibaNotebookID?
  public var file: KaibaFile
  public var role: KaibaAttachmentRole
  public var position: Int?
}

public struct KaibaComment: Codable, Equatable, Sendable {
  public var commentId: KaibaCommentID
  public var noteId: KaibaNoteID?
  public var notebookId: KaibaNotebookID?
  public var bodyMarkdown: String
  public var author: String
  public var createdAt: String
}

public struct KaibaNoteLink: Codable, Equatable, Sendable {
  public var fromNoteId: KaibaNoteID
  public var toNoteId: KaibaNoteID
  public var linkKind: String
  public var provenance: String
  public var createdAt: String
}

public struct KaibaConversation: Codable, Equatable, Sendable {
  public var notebookId: KaibaNotebookID
  public var title: String
  public var updatedAt: String
  public var turnCount: Int
  public var subjectNoteId: KaibaNoteID?
  public var subjectNotebookId: KaibaNotebookID?
}

public struct KaibaConversationTurn: Codable, Equatable, Sendable {
  public var userMarkdown: String
  public var assistantMarkdown: String
  public var sourceNoteIds: [KaibaNoteID]

  public init(
    userMarkdown: String,
    assistantMarkdown: String,
    sourceNoteIds: [KaibaNoteID] = []
  ) {
    self.userMarkdown = userMarkdown
    self.assistantMarkdown = assistantMarkdown
    self.sourceNoteIds = sourceNoteIds
  }
}

public struct KaibaNoteSearchResult: Codable, Equatable, Sendable {
  public var note: KaibaNote
  public var snippet: String
  public var rank: Double
  public var matchedTags: [KaibaTag]
  public var isLinkedNeighbor: Bool
  public var termCoverage: Double
}

public struct KaibaNoteGraphNeighbor: Codable, Equatable, Sendable {
  public var seedNoteId: KaibaNoteID
  public var note: KaibaNote
  public var edgeKind: String
  public var weight: Double
  public var hopCount: Int
  public var pathNoteIds: [KaibaNoteID]
}

public struct KaibaOperationPayload: Codable, Equatable, Sendable {
  public var result: KaibaControlPlaneResult
  public var note: KaibaNote?
  public var notebook: KaibaNotebook?
  public var notes: [KaibaNote]?
  public var file: KaibaFile?
  public var noteFiles: [KaibaFileAttachment]?
  public var notebookFiles: [KaibaFileAttachment]?
  public var comment: KaibaComment?
  public var link: KaibaNoteLink?
  public var tag: KaibaTag?
  public var tagClass: KaibaTagClass?

  public init(
    result: KaibaControlPlaneResult,
    note: KaibaNote? = nil,
    notebook: KaibaNotebook? = nil,
    notes: [KaibaNote]? = nil,
    file: KaibaFile? = nil,
    noteFiles: [KaibaFileAttachment]? = nil,
    notebookFiles: [KaibaFileAttachment]? = nil,
    comment: KaibaComment? = nil,
    link: KaibaNoteLink? = nil,
    tag: KaibaTag? = nil,
    tagClass: KaibaTagClass? = nil
  ) {
    self.result = result
    self.note = note
    self.notebook = notebook
    self.notes = notes
    self.file = file
    self.noteFiles = noteFiles
    self.notebookFiles = notebookFiles
    self.comment = comment
    self.link = link
    self.tag = tag
    self.tagClass = tagClass
  }
}

public struct KaibaInlineAttachment: Codable, Equatable, Sendable {
  public var bytes: Data
  public var mediaType: String
  public var originalFilename: String?
  public var role: KaibaAttachmentRole?

  public init(
    bytes: Data,
    mediaType: String,
    originalFilename: String? = nil,
    role: KaibaAttachmentRole? = nil
  ) {
    self.bytes = bytes
    self.mediaType = mediaType
    self.originalFilename = originalFilename
    self.role = role
  }
}

public struct KaibaIngestPage: Codable, Equatable, Sendable {
  public var bodyMarkdown: String
  public var readOnly: Bool
  public var tags: [KaibaTagInput]
  public var metaJSON: String?
  public var noteNumber: Int?
  public var pageImage: KaibaInlineAttachment?

  public init(
    bodyMarkdown: String,
    readOnly: Bool = true,
    tags: [KaibaTagInput] = [],
    metaJSON: String? = nil,
    noteNumber: Int? = nil,
    pageImage: KaibaInlineAttachment? = nil
  ) {
    self.bodyMarkdown = bodyMarkdown
    self.readOnly = readOnly
    self.tags = tags
    self.metaJSON = metaJSON
    self.noteNumber = noteNumber
    self.pageImage = pageImage
  }
}

public struct KaibaLongTermMemoryEntry: Codable, Equatable, Sendable {
  public var bodyMarkdown: String
  public var topicTags: [String]
  public var sourceNoteIds: [KaibaNoteID]
  public var relatedNoteIds: [KaibaNoteID]
  public var periodStart: String?
  public var periodEnd: String?
  public var metaJSON: String?

  public init(
    bodyMarkdown: String,
    topicTags: [String] = [],
    sourceNoteIds: [KaibaNoteID] = [],
    relatedNoteIds: [KaibaNoteID] = [],
    periodStart: String? = nil,
    periodEnd: String? = nil,
    metaJSON: String? = nil
  ) {
    self.bodyMarkdown = bodyMarkdown
    self.topicTags = topicTags
    self.sourceNoteIds = sourceNoteIds
    self.relatedNoteIds = relatedNoteIds
    self.periodStart = periodStart
    self.periodEnd = periodEnd
    self.metaJSON = metaJSON
  }
}

public struct KaibaLongTermMemoryAppendPayload: Codable, Equatable, Sendable {
  public var result: KaibaControlPlaneResult
  public var notes: [KaibaNote]
  public var idempotentReplay: Bool
}

public struct KaibaLongTermMemoryRecallHit: Codable, Equatable, Sendable {
  public var note: KaibaNote
  public var snippet: String
  public var rank: Double
  public var isAssociation: Bool
  public var edgeKind: String?
  public var weight: Double?
  public var hopCount: Int?
  public var pathNoteIds: [KaibaNoteID]
}

public struct KaibaValuePayload<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
  public var result: KaibaControlPlaneResult
  public var value: Value?

  public init(result: KaibaControlPlaneResult, value: Value?) {
    self.result = result
    self.value = value
  }
}
