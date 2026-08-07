import Foundation

public struct NoteFileLocator: Equatable, Sendable {
  public var storageKind: NoteFileStorageKind
  public var localPath: String?
  public var s3Profile: String?
  public var s3Bucket: String?
  public var s3Key: String?

  public init(
    storageKind: NoteFileStorageKind,
    localPath: String? = nil,
    s3Profile: String? = nil,
    s3Bucket: String? = nil,
    s3Key: String? = nil
  ) {
    self.storageKind = storageKind
    self.localPath = localPath
    self.s3Profile = s3Profile
    self.s3Bucket = s3Bucket
    self.s3Key = s3Key
  }
}

public struct StoredNoteFile: Equatable, Sendable {
  public var locator: NoteFileLocator
  public var byteSize: Int64
  public var sha256: String

  public init(locator: NoteFileLocator, byteSize: Int64, sha256: String) {
    self.locator = locator
    self.byteSize = byteSize
    self.sha256 = sha256
  }
}

public protocol NoteFileStore: Sendable {
  func store(data: Data, fileId: String) throws -> StoredNoteFile
  func read(record: FileRecord) throws -> Data
  func delete(record: FileRecord) throws
}

public enum NoteFileStoreError: Error, Equatable, Sendable {
  case unsupportedStorageKind(NoteFileStorageKind)
  case missingLocalPath(String)
  case missingS3Locator(String)
  case checksumMismatch(expected: String, actual: String)
  case missingEnvironmentValue(String)
  case s3HTTPFailure(statusCode: Int, message: String)
  case invalidEndpoint(String)
}

public struct S3StorageProfile: Equatable, Sendable {
  public var name: String
  public var endpoint: URL
  public var region: String
  public var bucket: String
  public var accessKeyId: String
  public var secretAccessKey: String
  public var sessionToken: String?
  public var keyPrefix: String

  public init(
    name: String,
    endpoint: URL,
    region: String,
    bucket: String,
    accessKeyId: String,
    secretAccessKey: String,
    sessionToken: String? = nil,
    keyPrefix: String = ""
  ) {
    self.name = name
    self.endpoint = endpoint
    self.region = region
    self.bucket = bucket
    self.accessKeyId = accessKeyId
    self.secretAccessKey = secretAccessKey
    self.sessionToken = sessionToken
    self.keyPrefix = keyPrefix
  }

  public static func environmentBacked(
    name: String,
    endpoint: URL,
    region: String,
    bucket: String,
    accessKeyIdEnv: String,
    secretAccessKeyEnv: String,
    sessionTokenEnv: String? = nil,
    keyPrefix: String = "",
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> S3StorageProfile {
    guard let accessKeyId = environment[accessKeyIdEnv], !accessKeyId.isEmpty else {
      throw NoteFileStoreError.missingEnvironmentValue(accessKeyIdEnv)
    }
    guard let secretAccessKey = environment[secretAccessKeyEnv], !secretAccessKey.isEmpty else {
      throw NoteFileStoreError.missingEnvironmentValue(secretAccessKeyEnv)
    }
    let sessionToken = sessionTokenEnv.flatMap { environment[$0] }
    return S3StorageProfile(
      name: name,
      endpoint: endpoint,
      region: region,
      bucket: bucket,
      accessKeyId: accessKeyId,
      secretAccessKey: secretAccessKey,
      sessionToken: sessionToken,
      keyPrefix: keyPrefix
    )
  }
}

public struct S3HTTPRequest: Equatable, Sendable {
  public var method: String
  public var url: URL
  public var headers: [String: String]
  public var body: Data
}

public struct S3HTTPResponse: Equatable, Sendable {
  public var statusCode: Int
  public var body: Data

  public init(statusCode: Int, body: Data = Data()) {
    self.statusCode = statusCode
    self.body = body
  }
}

public protocol S3HTTPClient: Sendable {
  func send(_ request: S3HTTPRequest) throws -> S3HTTPResponse
}

public protocol AsyncS3HTTPClient: Sendable {
  func send(_ request: S3HTTPRequest) async throws -> S3HTTPResponse
}
