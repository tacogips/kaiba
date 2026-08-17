import CryptoKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct S3NoteFileStore: NoteFileStore {
  public var profile: S3StorageProfile
  public var httpClient: S3HTTPClient
  public var now: @Sendable () -> Date

  public init(
    profile: S3StorageProfile,
    httpClient: S3HTTPClient = URLSessionS3HTTPClient(),
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.profile = profile
    self.httpClient = httpClient
    self.now = now
  }

  public func store(data: Data, fileId: FileID) throws -> StoredNoteFile {
    let key = storageKey(for: fileId)
    let request = try signedRequest(method: "PUT", key: key, body: data, contentType: "application/octet-stream")
    let response = try httpClient.send(request)
    guard (200..<300).contains(response.statusCode) else {
      throw NoteFileStoreError.s3HTTPFailure(statusCode: response.statusCode, message: "s3 put failed")
    }
    return StoredNoteFile(
      locator: NoteFileLocator(
        storageKind: .s3,
        s3Profile: profile.name,
        s3Bucket: profile.bucket,
        s3Key: key
      ),
      byteSize: Int64(data.count),
      sha256: sha256Hex(data)
    )
  }

  public func read(record: FileRecord) throws -> Data {
    guard record.storageKind == .s3 else {
      throw NoteFileStoreError.unsupportedStorageKind(record.storageKind)
    }
    guard let key = s3Key(from: record) else {
      throw NoteFileStoreError.missingS3Locator(record.fileId)
    }
    let response = try httpClient.send(try signedRequest(method: "GET", key: key, body: Data()))
    guard (200..<300).contains(response.statusCode) else {
      throw NoteFileStoreError.s3HTTPFailure(statusCode: response.statusCode, message: "s3 get failed")
    }
    let actual = sha256Hex(response.body)
    guard actual == record.sha256 else {
      throw NoteFileStoreError.checksumMismatch(expected: record.sha256, actual: actual)
    }
    return response.body
  }

  public func read(record: FileRecord, httpClient: any AsyncS3HTTPClient) async throws -> Data {
    guard record.storageKind == .s3 else {
      throw NoteFileStoreError.unsupportedStorageKind(record.storageKind)
    }
    guard let key = s3Key(from: record) else {
      throw NoteFileStoreError.missingS3Locator(record.fileId)
    }
    let response = try await httpClient.send(try signedRequest(method: "GET", key: key, body: Data()))
    guard (200..<300).contains(response.statusCode) else {
      throw NoteFileStoreError.s3HTTPFailure(statusCode: response.statusCode, message: "s3 get failed")
    }
    let actual = sha256Hex(response.body)
    guard actual == record.sha256 else {
      throw NoteFileStoreError.checksumMismatch(expected: record.sha256, actual: actual)
    }
    return response.body
  }

  public func delete(record: FileRecord) throws {
    guard record.storageKind == .s3 else {
      throw NoteFileStoreError.unsupportedStorageKind(record.storageKind)
    }
    guard let key = s3Key(from: record) else {
      throw NoteFileStoreError.missingS3Locator(record.fileId)
    }
    let response = try httpClient.send(try signedRequest(method: "DELETE", key: key, body: Data()))
    guard (200..<300).contains(response.statusCode) || response.statusCode == 404 else {
      throw NoteFileStoreError.s3HTTPFailure(statusCode: response.statusCode, message: "s3 delete failed")
    }
  }

  private func storageKey(for fileId: FileID) -> String {
    let trimmedPrefix = profile.keyPrefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard !trimmedPrefix.isEmpty else {
      return fileId.rawValue
    }
    return "\(trimmedPrefix)/\(fileId)"
  }

  private func s3Key(from record: FileRecord) -> String? {
    guard let key = record.s3Key else {
      return nil
    }
    guard record.s3Bucket == profile.bucket else {
      return nil
    }
    guard record.s3Profile == profile.name else {
      return nil
    }
    return key
  }

  private func signedRequest(
    method: String,
    key: String,
    body: Data,
    contentType: String? = nil
  ) throws -> S3HTTPRequest {
    let requestTarget = try requestTarget(for: key)
    let timestamp = S3Timestamp(date: now())
    let payloadHash = sha256Hex(body)
    var headers = [
      "host": try hostHeader(for: requestTarget.url),
      "x-amz-content-sha256": payloadHash,
      "x-amz-date": timestamp.full
    ]
    if let contentType {
      headers["content-type"] = contentType
    }
    if let sessionToken = profile.sessionToken {
      headers["x-amz-security-token"] = sessionToken
    }
    headers["authorization"] = authorizationHeader(
      method: method,
      canonicalURI: requestTarget.canonicalURI,
      canonicalQuery: requestTarget.canonicalQuery,
      headers: headers,
      payloadHash: payloadHash,
      timestamp: timestamp
    )
    return S3HTTPRequest(method: method, url: requestTarget.url, headers: headers, body: body)
  }

  private func authorizationHeader(
    method: String,
    canonicalURI: String,
    canonicalQuery: String,
    headers: [String: String],
    payloadHash: String,
    timestamp: S3Timestamp
  ) -> String {
    let sortedHeaders = headers.keys.sorted()
    let canonicalHeaders = sortedHeaders
      .map { "\($0):\(headers[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")\n" }
      .joined()
    let signedHeaders = sortedHeaders.joined(separator: ";")
    let canonicalRequest = [
      method,
      canonicalURI,
      canonicalQuery,
      canonicalHeaders,
      signedHeaders,
      payloadHash
    ].joined(separator: "\n")
    let credentialScope = "\(timestamp.short)/\(profile.region)/s3/aws4_request"
    let stringToSign = [
      "AWS4-HMAC-SHA256",
      timestamp.full,
      credentialScope,
      sha256Hex(Data(canonicalRequest.utf8))
    ].joined(separator: "\n")
    let signingKey = s3SigningKey(date: timestamp.short, region: profile.region, secret: profile.secretAccessKey)
    let signature = hmacSHA256Hex(key: signingKey, message: Data(stringToSign.utf8))
    return """
    AWS4-HMAC-SHA256 Credential=\(profile.accessKeyId)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)
    """
  }

  private func requestTarget(for key: String) throws -> S3RequestTarget {
    guard var components = URLComponents(url: profile.endpoint, resolvingAgainstBaseURL: false) else {
      throw NoteFileStoreError.invalidEndpoint(profile.endpoint.absoluteString)
    }
    let escapedKey = key.split(separator: "/", omittingEmptySubsequences: false)
      .map(s3URIEncode)
      .joined(separator: "/")
    let canonicalURI = "/\(s3URIEncode(profile.bucket))/\(escapedKey)"
    components.percentEncodedPath = canonicalURI
    guard let url = components.url else {
      throw NoteFileStoreError.invalidEndpoint(profile.endpoint.absoluteString)
    }
    return S3RequestTarget(
      url: url,
      canonicalURI: canonicalURI,
      canonicalQuery: canonicalQuery(from: components.percentEncodedQuery)
    )
  }

  private func hostHeader(for url: URL) throws -> String {
    guard let host = url.host else {
      throw NoteFileStoreError.invalidEndpoint(url.absoluteString)
    }
    if let port = url.port {
      return "\(host):\(port)"
    }
    return host
  }
}

private struct S3RequestTarget {
  var url: URL
  var canonicalURI: String
  var canonicalQuery: String
}

private func canonicalQuery(from percentEncodedQuery: String?) -> String {
  guard let percentEncodedQuery, !percentEncodedQuery.isEmpty else {
    return ""
  }
  return percentEncodedQuery
    .split(separator: "&", omittingEmptySubsequences: false)
    .map(String.init)
    .sorted()
    .joined(separator: "&")
}

private func s3URIEncode(_ value: some StringProtocol) -> String {
  value.utf8.map { byte in
    if isS3Unreserved(byte) {
      return String(UnicodeScalar(byte))
    }
    return String(format: "%%%02X", byte)
  }.joined()
}

private func isS3Unreserved(_ byte: UInt8) -> Bool {
  switch byte {
  case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x2E, 0x5F, 0x7E:
    return true
  default:
    return false
  }
}

public struct URLSessionS3HTTPClient: S3HTTPClient, AsyncS3HTTPClient {
  public init() {}

  public func send(_ request: S3HTTPRequest) throws -> S3HTTPResponse {
    var urlRequest = URLRequest(url: request.url)
    urlRequest.httpMethod = request.method
    urlRequest.httpBody = request.body.isEmpty ? nil : request.body
    for (name, value) in request.headers {
      urlRequest.setValue(value, forHTTPHeaderField: name)
    }

    let box = URLSessionS3HTTPResultBox()
    let semaphore = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: urlRequest) { data, response, error in
      box.store(data: data, response: response, error: error)
      semaphore.signal()
    }.resume()
    semaphore.wait()
    let result = box.result()
    if let error = result.error {
      throw error
    }
    let statusCode = (result.response as? HTTPURLResponse)?.statusCode ?? 0
    return S3HTTPResponse(statusCode: statusCode, body: result.data ?? Data())
  }

  public func send(_ request: S3HTTPRequest) async throws -> S3HTTPResponse {
    var urlRequest = URLRequest(url: request.url)
    urlRequest.httpMethod = request.method
    urlRequest.httpBody = request.body.isEmpty ? nil : request.body
    for (name, value) in request.headers {
      urlRequest.setValue(value, forHTTPHeaderField: name)
    }

    let (data, response) = try await URLSession.shared.data(for: urlRequest)
    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
    return S3HTTPResponse(statusCode: statusCode, body: data)
  }
}

private final class URLSessionS3HTTPResultBox: @unchecked Sendable {
  private let lock = NSLock()
  private var dataValue: Data?
  private var responseValue: URLResponse?
  private var errorValue: Error?

  func store(data: Data?, response: URLResponse?, error: Error?) {
    lock.lock()
    dataValue = data
    responseValue = response
    errorValue = error
    lock.unlock()
  }

  func result() -> URLSessionS3HTTPResult {
    lock.lock()
    defer { lock.unlock() }
    return URLSessionS3HTTPResult(data: dataValue, response: responseValue, error: errorValue)
  }
}

private struct URLSessionS3HTTPResult {
  var data: Data?
  var response: URLResponse?
  var error: Error?
}

private struct S3Timestamp {
  var short: String
  var full: String

  init(date: Date) {
    let shortFormatter = DateFormatter()
    shortFormatter.calendar = Calendar(identifier: .gregorian)
    shortFormatter.locale = Locale(identifier: "en_US_POSIX")
    shortFormatter.timeZone = TimeZone(secondsFromGMT: 0)
    shortFormatter.dateFormat = "yyyyMMdd"
    short = shortFormatter.string(from: date)

    let fullFormatter = DateFormatter()
    fullFormatter.calendar = Calendar(identifier: .gregorian)
    fullFormatter.locale = Locale(identifier: "en_US_POSIX")
    fullFormatter.timeZone = TimeZone(secondsFromGMT: 0)
    fullFormatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    full = fullFormatter.string(from: date)
  }
}

private func s3SigningKey(date: String, region: String, secret: String) -> Data {
  let dateKey = hmacSHA256(key: Data("AWS4\(secret)".utf8), message: Data(date.utf8))
  let dateRegionKey = hmacSHA256(key: dateKey, message: Data(region.utf8))
  let dateRegionServiceKey = hmacSHA256(key: dateRegionKey, message: Data("s3".utf8))
  return hmacSHA256(key: dateRegionServiceKey, message: Data("aws4_request".utf8))
}

private func hmacSHA256(key: Data, message: Data) -> Data {
  Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
}

private func hmacSHA256Hex(key: Data, message: Data) -> String {
  hmacSHA256(key: key, message: message).map { String(format: "%02x", $0) }.joined()
}
