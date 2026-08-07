import Foundation
import AppCore

public struct GraphQLUpdateNoteInput: Codable, Equatable, Sendable {
  public var noteId: String
  public var bodyMarkdown: String
  public var originatingActionId: String?

  public init(noteId: String, bodyMarkdown: String, originatingActionId: String? = nil) {
    self.noteId = noteId
    self.bodyMarkdown = bodyMarkdown
    self.originatingActionId = originatingActionId
  }
}

public struct GraphQLApplyNoteTagsInput: Codable, Equatable, Sendable {
  public var noteId: String
  public var tags: [GraphQLNoteTagInput]
  public var provenance: String?
  public var assignedBy: String?

  public init(
    noteId: String,
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
  public var notebookId: String
  public var tags: [String]
  public var provenance: String?
  public var assignedBy: String?

  public init(
    notebookId: String,
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
  public var notebookId: String
  public var tagIds: [String]
  public var provenance: String?
  public var assignedBy: String?

  public init(
    notebookId: String,
    tagIds: [String],
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
  public var noteId: String
  public var bodyMarkdown: String
  public var author: String?

  public init(noteId: String, bodyMarkdown: String, author: String? = nil) {
    self.noteId = noteId
    self.bodyMarkdown = bodyMarkdown
    self.author = author
  }
}

public struct GraphQLLinkNotesInput: Codable, Equatable, Sendable {
  public var fromNoteId: String
  public var toNoteId: String
  public var linkKind: String?
  public var provenance: String?
}

public struct GraphQLAttachNoteFileInput: Codable, Equatable, Sendable {
  public var noteId: String
  public var contentBase64: String
  public var role: String?
  public var mediaType: String
  public var originalFilename: String?
  public var position: Int?

  public init(
    noteId: String,
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
  public var actionId: String
  public var trigger: String
  public var workflowId: String
  public var filterJSON: String?
  public var enabled: Bool?
  public var position: Int?
}

public struct GraphQLNoteConversationTurnInput: Codable, Equatable, Sendable {
  public var userMarkdown: String
  public var assistantMarkdown: String
  public var sourceNoteIds: [String]

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    userMarkdown = try container.decode(String.self, forKey: .userMarkdown)
    assistantMarkdown = try container.decode(String.self, forKey: .assistantMarkdown)
    sourceNoteIds = try container.decodeIfPresent([String].self, forKey: .sourceNoteIds) ?? []
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
  public var originatingActionId: String?
}

public struct GraphQLMigrateNoteFileStorageInput: Codable, Equatable, Sendable {
  public var fileId: String
  public var s3ProfileName: String?
  public var s3Endpoint: String?
  public var s3Region: String?
  public var s3Bucket: String?
  public var s3AccessKeyIdEnv: String?
  public var s3SecretAccessKeyEnv: String?
  public var s3SessionTokenEnv: String?
  public var s3KeyPrefix: String?

  public init(
    fileId: String,
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
      fileId: "",
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
      fileId: "",
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
