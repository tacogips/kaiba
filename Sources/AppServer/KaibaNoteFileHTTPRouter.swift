import Foundation

import AppCore
import AppGraphQL

/// Serves stored note attachments as raw bytes at `GET /files/<fileId>`.
///
/// The GraphQL surface can only carry base64 payloads, so image-heavy views
/// (note carousels, imported page snapshots) fetch the blob over this route
/// instead. Everything outside `/files` is delegated to `service`, which lets
/// the router wrap the SPA/static handler and be consulted first.
///
/// Bearer auth mirrors `GET /note/events`: the configured authenticator decides,
/// and with no authenticator the route answers 503 unless the server was started
/// with `--allow-unauthenticated`.
public struct KaibaNoteFileHTTPRouter: KaibaHTTPRouteHandling {
  public static let pathNamespace = "/files"

  public var service: any KaibaHTTPRouteHandling
  public var noteService: NoteService
  public var s3Profiles: [S3StorageProfile]
  public var authenticator: (any NoteAPIAuthenticating)?
  public var allowUnauthenticated: Bool

  public init(
    service: any KaibaHTTPRouteHandling,
    noteService: NoteService,
    s3Profiles: [S3StorageProfile] = [],
    authenticator: (any NoteAPIAuthenticating)? = nil,
    allowUnauthenticated: Bool = false
  ) {
    self.service = service
    self.noteService = noteService
    self.s3Profiles = s3Profiles
    self.authenticator = authenticator
    self.allowUnauthenticated = allowUnauthenticated
  }

  public func response(for request: KaibaHTTPRequest) async -> KaibaHTTPResponse {
    guard let fileId = Self.fileId(inPath: request.path) else {
      return await service.response(for: request)
    }
    guard request.method == "GET" || request.method == "HEAD" else {
      return .json(status: 405, .object([
        "error": .string("unsupported method"),
        "method": .string(request.method),
        "path": .string(request.path)
      ]))
    }
    if let rejection = await authenticationRejection(for: request) {
      return rejection
    }
    guard !fileId.isEmpty else {
      return Self.notFoundResponse(fileId: fileId)
    }
    let record: FileRecord
    let content: Data
    do {
      record = try noteService.getFileRecord(fileId: fileId)
      content = try noteService.resolveFileContent(fileId: fileId, s3Profiles: s3Profiles)
    } catch NoteServiceError.notFound {
      return Self.notFoundResponse(fileId: fileId)
    } catch {
      logNoteAPIServerError("note file read failed", error: error)
      return .json(status: 500, .object([
        "error": .string("note file could not be read"),
        "fileId": .string(fileId)
      ]))
    }
    return KaibaHTTPResponse(
      status: 200,
      headers: [
        "Content-Type": Self.headerSafeMediaType(record.mediaType),
        "Content-Length": String(content.count),
        "Cache-Control": "private, max-age=3600"
      ],
      body: content
    )
  }

  private func authenticationRejection(for request: KaibaHTTPRequest) async -> KaibaHTTPResponse? {
    guard let authenticator else {
      return allowUnauthenticated
        ? nil
        : .json(
          status: 503,
          .object(noteAPIUnavailableResponse("note API authentication is not configured").body)
        )
    }
    let envelope = ServerRequestEnvelope(
      method: request.method,
      path: request.path,
      headers: request.headers,
      body: request.body.isEmpty ? nil : request.body,
      query: request.query
    )
    let context = ServerRequestContext(serviceName: "kaiba").withHeaders(from: request.headers)
    switch await authenticator.authenticate(request: envelope, context: context) {
    case .accepted:
      return nil
    case let .rejected(rejection):
      return .json(status: rejection.status, .object(rejection.body))
    }
  }

  /// The single path component after `/files`, or nil when the request is not
  /// addressed to this route at all.
  static func fileId(inPath path: String) -> String? {
    guard path == pathNamespace || path.hasPrefix(pathNamespace + "/") else {
      return nil
    }
    let remainder = path.dropFirst(pathNamespace.count).drop(while: { $0 == "/" })
    guard !remainder.contains("/") else {
      return nil
    }
    return String(remainder)
  }

  /// Stored media types are caller-supplied at attach time, so control
  /// characters are dropped before the value reaches a response header.
  private static func headerSafeMediaType(_ mediaType: String) -> String {
    let sanitized = mediaType.filter { character in
      character.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
    let trimmed = sanitized.trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty ? "application/octet-stream" : trimmed
  }

  private static func notFoundResponse(fileId: String) -> KaibaHTTPResponse {
    .json(status: 404, .object([
      "error": .string("note file was not found"),
      "fileId": .string(fileId)
    ]))
  }
}
