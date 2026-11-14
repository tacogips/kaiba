import Foundation
import AppCore

public struct GraphQLUpdateNoteInput: Codable, Equatable, Sendable {
  public var noteId: NoteID
  public var bodyMarkdown: String
  public var originatingActionId: AutoActionID?

  public init(noteId: NoteID, bodyMarkdown: String, originatingActionId: AutoActionID? = nil) {
    self.noteId = noteId
    self.bodyMarkdown = bodyMarkdown
    self.originatingActionId = originatingActionId
  }
}

public struct GraphQLApplyNoteTagsInput: Codable, Equatable, Sendable {
  public var noteId: NoteID
  public var tags: [GraphQLNoteTagInput]
  public var provenance: String?
  public var assignedBy: String?

  public init(
    noteId: NoteID,
    tags: [GraphQLNoteTagInput],
    provenance: String? = nil,
    assignedBy: String? = nil
  ) {
    self.noteId = noteId
    self.tags = tags
    self.provenance = provenance
    self.assignedBy = assignedBy
  }
}

public struct GraphQLApplyNotebookTagsInput: Codable, Equatable, Sendable {
  public var notebookId: NotebookID
  public var tags: [String]
  public var provenance: String?
  public var assignedBy: String?

  public init(
    notebookId: NotebookID,
    tags: [String],
    provenance: String? = nil,
    assignedBy: String? = nil
  ) {
    self.notebookId = notebookId
    self.tags = tags
    self.provenance = provenance
    self.assignedBy = assignedBy
  }
}

public struct GraphQLApplyNotebookTagIdsInput: Codable, Equatable, Sendable {
  public var notebookId: NotebookID
  public var tagIds: [TagID]
  public var provenance: String?
  public var assignedBy: String?

  public init(
    notebookId: NotebookID,
    tagIds: [TagID],
    provenance: String? = nil,
    assignedBy: String? = nil
  ) {
    self.notebookId = notebookId
    self.tagIds = tagIds
    self.provenance = provenance
    self.assignedBy = assignedBy
  }
}

public struct GraphQLAddNoteCommentInput: Codable, Equatable, Sendable {
  public var noteId: NoteID
  public var bodyMarkdown: String
  public var author: String?

  public init(noteId: NoteID, bodyMarkdown: String, author: String? = nil) {
    self.noteId = noteId
    self.bodyMarkdown = bodyMarkdown
    self.author = author
  }
}

public struct GraphQLAddNotebookCommentInput: Codable, Equatable, Sendable {
  public var notebookId: NotebookID
  public var bodyMarkdown: String
  public var author: String?

  public init(notebookId: NotebookID, bodyMarkdown: String, author: String? = nil) {
    self.notebookId = notebookId
    self.bodyMarkdown = bodyMarkdown
    self.author = author
  }
}

public struct GraphQLSetAppSettingInput: Codable, Equatable, Sendable {
  public var key: String
  public var valueJSON: String

  public init(key: String, valueJSON: String) {
    self.key = key
    self.valueJSON = valueJSON
  }
}

public struct GraphQLSetUserAgentCredentialInput: Codable, Equatable, Sendable {
  public var provider: String
  public var apiKey: String
  public var defaultModel: String
  public var baseURL: String?
  public var enabled: Bool?

  public init(provider: String, apiKey: String, defaultModel: String, baseURL: String? = nil, enabled: Bool? = nil) {
    self.provider = provider
    self.apiKey = apiKey
    self.defaultModel = defaultModel
    self.baseURL = baseURL
    self.enabled = enabled
  }
}

public struct GraphQLLinkNotesInput: Codable, Equatable, Sendable {
  public var fromNoteId: NoteID
  public var toNoteId: NoteID
  public var linkKind: String?
  public var provenance: String?
}

public struct GraphQLAttachNoteFileInput: Codable, Equatable, Sendable {
  public var noteId: NoteID
  public var contentBase64: String
  public var role: String?
  public var mediaType: String
  public var originalFilename: String?
  public var position: Int?

  public init(
    noteId: NoteID,
    contentBase64: String,
    role: String? = nil,
    mediaType: String,
    originalFilename: String? = nil,
    position: Int? = nil
  ) {
    self.noteId = noteId
    self.contentBase64 = contentBase64
    self.role = role
    self.mediaType = mediaType
    self.originalFilename = originalFilename
    self.position = position
  }
}

public struct GraphQLConfigureNoteAutoActionInput: Codable, Equatable, Sendable {
  public var actionId: AutoActionID
  public var trigger: String
  public var workflowId: WorkflowID
  public var filterJSON: String?
  public var enabled: Bool?
  public var position: Int?
}

public struct GraphQLNoteConversationTurnInput: Codable, Equatable, Sendable {
  public var userMarkdown: String
  public var assistantMarkdown: String
  public var sourceNoteIds: [NoteID]

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    userMarkdown = try container.decode(String.self, forKey: .userMarkdown)
    assistantMarkdown = try container.decode(String.self, forKey: .assistantMarkdown)
    sourceNoteIds = try container.decodeIfPresent([NoteID].self, forKey: .sourceNoteIds) ?? []
  }

  public var noteTurn: NoteConversationTurn {
    NoteConversationTurn(
      userMarkdown: userMarkdown,
      assistantMarkdown: assistantMarkdown,
      sourceNoteIds: sourceNoteIds
    )
  }
}

public struct GraphQLSaveNoteConversationInput: Codable, Equatable, Sendable {
  public var title: String
  public var transcript: [GraphQLNoteConversationTurnInput]
  public var assignedBy: String?
  public var originatingActionId: AutoActionID?
}

/// The subject is a note (`subjectNoteId`) or a whole notebook
/// (`subjectNotebookId`); exactly one is required when starting a new
/// conversation, and neither is needed when `conversationNotebookId` names an
/// existing one.
public struct GraphQLSendAgentChatMessageInput: Codable, Equatable, Sendable {
  public var subjectNoteId: NoteID?
  public var subjectNotebookId: NotebookID?
  public var conversationNotebookId: NotebookID?
  public var userMarkdown: String
  public var idempotencyKey: String?
  public var model: String?
  /// "memo" (default) or "edit"; validated against `AgentChatTurnMode`.
  public var mode: String?
  public var attachments: [GraphQLAgentChatAttachmentInput]?

  public init(
    subjectNoteId: NoteID? = nil,
    subjectNotebookId: NotebookID? = nil,
    conversationNotebookId: NotebookID? = nil,
    userMarkdown: String,
    idempotencyKey: String? = nil,
    model: String? = nil,
    mode: String? = nil,
    attachments: [GraphQLAgentChatAttachmentInput]? = nil
  ) {
    self.subjectNoteId = subjectNoteId
    self.subjectNotebookId = subjectNotebookId
    self.conversationNotebookId = conversationNotebookId
    self.userMarkdown = userMarkdown
    self.idempotencyKey = idempotencyKey
    self.model = model
    self.mode = mode
    self.attachments = attachments
  }
}

public struct GraphQLAgentChatAttachmentInput: Codable, Equatable, Sendable {
  public var contentBase64: String
  public var mediaType: String
  public var originalFilename: String

  public init(contentBase64: String, mediaType: String, originalFilename: String) {
    self.contentBase64 = contentBase64
    self.mediaType = mediaType
    self.originalFilename = originalFilename
  }
}

public struct GraphQLRequestTagExtractionInput: Codable, Equatable, Sendable {
  public var noteId: NoteID?
  public var notebookId: NotebookID?

  public init(noteId: NoteID? = nil, notebookId: NotebookID? = nil) {
    self.noteId = noteId
    self.notebookId = notebookId
  }
}

public struct GraphQLRequestNotebookTranslationInput: Codable, Equatable, Sendable {
  public var notebookId: NotebookID
  public var targetLanguage: String
  public var title: String?

  public init(notebookId: NotebookID, targetLanguage: String, title: String? = nil) {
    self.notebookId = notebookId
    self.targetLanguage = targetLanguage
    self.title = title
  }
}

public struct GraphQLMigrateNoteFileStorageInput: Codable, Equatable, Sendable {
  public var fileId: FileID
  public var s3ProfileName: String?
  public var s3Endpoint: String?
  public var s3Region: String?
  public var s3Bucket: String?
  public var s3AccessKeyIdEnv: String?
  public var s3SecretAccessKeyEnv: String?
  public var s3SessionTokenEnv: String?
  public var s3KeyPrefix: String?

  public init(
    fileId: FileID,
    s3ProfileName: String? = nil,
    s3Endpoint: String? = nil,
    s3Region: String? = nil,
    s3Bucket: String? = nil,
    s3AccessKeyIdEnv: String? = nil,
    s3SecretAccessKeyEnv: String? = nil,
    s3SessionTokenEnv: String? = nil,
    s3KeyPrefix: String? = nil
  ) {
    self.fileId = fileId
    self.s3ProfileName = s3ProfileName
    self.s3Endpoint = s3Endpoint
    self.s3Region = s3Region
    self.s3Bucket = s3Bucket
    self.s3AccessKeyIdEnv = s3AccessKeyIdEnv
    self.s3SecretAccessKeyEnv = s3SecretAccessKeyEnv
    self.s3SessionTokenEnv = s3SessionTokenEnv
    self.s3KeyPrefix = s3KeyPrefix
  }

  func storageProfile(
    allowedProfiles: [S3StorageProfile],
    environment: [String: String],
    allowRawInput: Bool,
    rawEnvironmentAllowlist: Set<String>
  ) throws -> S3StorageProfile {
    if let s3ProfileName {
      if !allowRawInput && hasRawStorageProfileFields {
        throw NoteGraphQLDocumentExecutorError.invalidVariable("raw S3 fields are not allowed with s3ProfileName")
      }
      if !hasRawStorageProfileFields || !allowRawInput {
        guard let profile = allowedProfiles.first(where: { $0.name == s3ProfileName }) else {
          throw NoteGraphQLDocumentExecutorError.invalidVariable("unknown s3ProfileName: \(s3ProfileName)")
        }
        return profile
      }
    }
    guard allowRawInput else {
      throw NoteGraphQLDocumentExecutorError.invalidVariable("s3ProfileName is required")
    }
    guard let s3Endpoint, let endpoint = URL(string: s3Endpoint) else {
      throw NoteGraphQLDocumentExecutorError.invalidVariable("s3Endpoint")
    }
    guard let s3Region, !s3Region.isEmpty else {
      throw NoteGraphQLDocumentExecutorError.invalidVariable("s3Region")
    }
    guard let s3Bucket, !s3Bucket.isEmpty else {
      throw NoteGraphQLDocumentExecutorError.invalidVariable("s3Bucket")
    }
    let accessKeyIdEnv = s3AccessKeyIdEnv ?? "AWS_ACCESS_KEY_ID"
    let secretAccessKeyEnv = s3SecretAccessKeyEnv ?? "AWS_SECRET_ACCESS_KEY"
    let requestedEnvironmentNames = Set([accessKeyIdEnv, secretAccessKeyEnv] + [s3SessionTokenEnv].compactMap { $0 })
    guard requestedEnvironmentNames.isSubset(of: rawEnvironmentAllowlist) else {
      throw NoteGraphQLDocumentExecutorError.invalidVariable("raw S3 environment variable is not allowed")
    }
    return try S3StorageProfile.environmentBacked(
      name: s3ProfileName ?? "default-s3",
      endpoint: endpoint,
      region: s3Region,
      bucket: s3Bucket,
      accessKeyIdEnv: accessKeyIdEnv,
      secretAccessKeyEnv: secretAccessKeyEnv,
      sessionTokenEnv: s3SessionTokenEnv,
      keyPrefix: s3KeyPrefix ?? "",
      environment: environment
    )
  }

  private var hasRawStorageProfileFields: Bool {
    s3Endpoint != nil
      || s3Region != nil
      || s3Bucket != nil
      || s3AccessKeyIdEnv != nil
      || s3SecretAccessKeyEnv != nil
      || s3SessionTokenEnv != nil
      || s3KeyPrefix != nil
  }
}

public struct GraphQLReclaimNoteFileStorageInput: Codable, Equatable, Sendable {
  public var graceHours: Int?
  public var s3ProfileName: String?
  public var s3Endpoint: String?
  public var s3Region: String?
  public var s3Bucket: String?
  public var s3AccessKeyIdEnv: String?
  public var s3SecretAccessKeyEnv: String?
  public var s3SessionTokenEnv: String?
  public var s3KeyPrefix: String?

  public init(
    graceHours: Int? = nil,
    s3ProfileName: String? = nil,
    s3Endpoint: String? = nil,
    s3Region: String? = nil,
    s3Bucket: String? = nil,
    s3AccessKeyIdEnv: String? = nil,
    s3SecretAccessKeyEnv: String? = nil,
    s3SessionTokenEnv: String? = nil,
    s3KeyPrefix: String? = nil
  ) {
    self.graceHours = graceHours
    self.s3ProfileName = s3ProfileName
    self.s3Endpoint = s3Endpoint
    self.s3Region = s3Region
    self.s3Bucket = s3Bucket
    self.s3AccessKeyIdEnv = s3AccessKeyIdEnv
    self.s3SecretAccessKeyEnv = s3SecretAccessKeyEnv
    self.s3SessionTokenEnv = s3SessionTokenEnv
    self.s3KeyPrefix = s3KeyPrefix
  }

  /// Resolves the S3 profile used to delete orphaned S3 objects, or `nil` when
  /// no S3 endpoint was supplied (a local-only GC pass).
  func optionalStorageProfile(
    allowedProfiles: [S3StorageProfile],
    environment: [String: String],
    allowRawInput: Bool,
    rawEnvironmentAllowlist: Set<String>
  ) throws -> S3StorageProfile? {
    guard s3Endpoint != nil || s3ProfileName != nil else {
      return nil
    }
    return try GraphQLMigrateNoteFileStorageInput(
      fileId: FileID(""),
      s3ProfileName: s3ProfileName,
      s3Endpoint: s3Endpoint,
      s3Region: s3Region,
      s3Bucket: s3Bucket,
      s3AccessKeyIdEnv: s3AccessKeyIdEnv,
      s3SecretAccessKeyEnv: s3SecretAccessKeyEnv,
      s3SessionTokenEnv: s3SessionTokenEnv,
      s3KeyPrefix: s3KeyPrefix
    ).storageProfile(
      allowedProfiles: allowedProfiles,
      environment: environment,
      allowRawInput: allowRawInput,
      rawEnvironmentAllowlist: rawEnvironmentAllowlist
    )
  }
}

public struct GraphQLMigrateAllNoteFilesInput: Codable, Equatable, Sendable {
  public var s3ProfileName: String?
  public var s3Endpoint: String?
  public var s3Region: String?
  public var s3Bucket: String?
  public var s3AccessKeyIdEnv: String?
  public var s3SecretAccessKeyEnv: String?
  public var s3SessionTokenEnv: String?
  public var s3KeyPrefix: String?

  public init(
    s3ProfileName: String? = nil,
    s3Endpoint: String? = nil,
    s3Region: String? = nil,
    s3Bucket: String? = nil,
    s3AccessKeyIdEnv: String? = nil,
    s3SecretAccessKeyEnv: String? = nil,
    s3SessionTokenEnv: String? = nil,
    s3KeyPrefix: String? = nil
  ) {
    self.s3ProfileName = s3ProfileName
    self.s3Endpoint = s3Endpoint
    self.s3Region = s3Region
    self.s3Bucket = s3Bucket
    self.s3AccessKeyIdEnv = s3AccessKeyIdEnv
    self.s3SecretAccessKeyEnv = s3SecretAccessKeyEnv
    self.s3SessionTokenEnv = s3SessionTokenEnv
    self.s3KeyPrefix = s3KeyPrefix
  }

  func storageProfile(
    allowedProfiles: [S3StorageProfile],
    environment: [String: String],
    allowRawInput: Bool,
    rawEnvironmentAllowlist: Set<String>
  ) throws -> S3StorageProfile {
    try GraphQLMigrateNoteFileStorageInput(
      fileId: FileID(""),
      s3ProfileName: s3ProfileName,
      s3Endpoint: s3Endpoint,
      s3Region: s3Region,
      s3Bucket: s3Bucket,
      s3AccessKeyIdEnv: s3AccessKeyIdEnv,
      s3SecretAccessKeyEnv: s3SecretAccessKeyEnv,
      s3SessionTokenEnv: s3SessionTokenEnv,
      s3KeyPrefix: s3KeyPrefix
    ).storageProfile(
      allowedProfiles: allowedProfiles,
      environment: environment,
      allowRawInput: allowRawInput,
      rawEnvironmentAllowlist: rawEnvironmentAllowlist
    )
  }
}
