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
  /// See `DeterministicServerRouteHandler.unauthenticatedActsAsAdmin`.
  public var unauthenticatedActsAsAdmin: Bool

  public init(
    service: any KaibaHTTPRouteHandling,
    noteService: NoteService,
    s3Profiles: [S3StorageProfile] = [],
    authenticator: (any NoteAPIAuthenticating)? = nil,
    allowUnauthenticated: Bool = false,
    unauthenticatedActsAsAdmin: Bool = false
  ) {
    self.service = service
    self.noteService = noteService
    self.s3Profiles = s3Profiles
    self.authenticator = authenticator
    self.allowUnauthenticated = allowUnauthenticated
    self.unauthenticatedActsAsAdmin = unauthenticatedActsAsAdmin
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
    let outcome = await authenticationOutcome(for: request)
    let authenticatedClient: NoteAPIAuthenticatedClient?
    switch outcome {
    case let .rejected(rejection):
      return rejection
    case let .authenticated(client):
      authenticatedClient = client
    case .unauthenticated:
      authenticatedClient = nil
    }
    guard !fileId.isEmpty else {
      return Self.notFoundResponse(fileId: fileId)
    }
    // Scope the reader to the authenticated account so `requireReachableFile`
    // applies the same per-account library membership the GraphQL executor does
    // (`NoteGraphQLDocumentExecutor` scopes to `actingUserId`); serving raw
    // bytes must not be the one route that skips it (`design-docs/specs/library.md`).
    // An `--allow-unauthenticated` reader reaches only files in open libraries,
    // unless `--as-admin` says this port acts as the admin account.
    let isUnauthenticated = authenticatedClient == nil && !unauthenticatedActsAsAdmin
    let reader = noteService
      .scoped(to: authenticatedClient?.userId)
      .unauthenticated(isUnauthenticated)
    let record: FileRecord
    let content: Data
    do {
      record = try reader.getFileRecord(fileId: fileId)
      content = try reader.resolveFileContent(fileId: fileId, s3Profiles: s3Profiles)
    } catch NoteServiceError.notFound {
      return Self.notFoundResponse(fileId: fileId)
    } catch {
      logNoteAPIServerError("note file read failed", error: error)
      return .json(status: 500, .object([
        "error": .string("note file could not be read"),
        "fileId": .string(fileId.rawValue)
      ]))
    }
    // A stored blob is content the note author supplied, so it is served as an
    // inert download, never as an active document on kaiba's own origin: an
    // attacker-chosen `text/html`/`image/svg+xml` attachment would otherwise
    // run script that can read the SPA's bearer token. Only known-inert types
    // keep their declared value; everything else is forced to a generic binary
    // download, and a strict CSP plus `Content-Disposition: attachment` back
    // that up even for the allowlisted types.
    let (contentType, disposition) = Self.responseContentType(for: record.mediaType)
    return KaibaHTTPResponse(
      status: 200,
      headers: [
        "Content-Type": contentType,
        "Content-Length": String(content.count),
        "Cache-Control": "private, max-age=3600",
        "Content-Disposition": disposition,
        "Content-Security-Policy": "default-src 'none'; sandbox",
        "X-Content-Type-Options": "nosniff"
      ],
      body: content
    )
  }

  /// Whether the request carried a credential. "Allowed through without one"
  /// and "authenticated" are different answers: only the second one may reach
  /// a library that requires authentication.
  enum AuthenticationOutcome: Equatable {
    case authenticated(NoteAPIAuthenticatedClient)
    case unauthenticated
    case rejected(KaibaHTTPResponse)
  }

  private func authenticationOutcome(for request: KaibaHTTPRequest) async -> AuthenticationOutcome {
    guard let authenticator else {
      return allowUnauthenticated
        ? .unauthenticated
        : .rejected(.json(
          status: 503,
          .object(noteAPIUnavailableResponse("note API authentication is not configured").body)
        ))
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
    case let .accepted(client):
      return .authenticated(client)
    case let .rejected(rejection):
      return .rejected(.json(status: rejection.status, .object(rejection.body)))
    }
  }

  /// The single path component after `/files`, or nil when the request is not
  /// addressed to this route at all.
  static func fileId(inPath path: String) -> FileID? {
    guard path == pathNamespace || path.hasPrefix(pathNamespace + "/") else {
      return nil
    }
    let remainder = path.dropFirst(pathNamespace.count).drop(while: { $0 == "/" })
    guard !remainder.contains("/") else {
      return nil
    }
    return FileID(validating: String(remainder))
  }

  /// Media types the viewer renders inline and that cannot carry active
  /// content. Notably excludes `text/html`, `application/xhtml+xml`, and
  /// `image/svg+xml`, all of which can execute script on kaiba's origin.
  static let inlineRenderableMediaTypes: Set<String> = [
    "image/png", "image/jpeg", "image/gif", "image/webp", "image/avif",
    "image/bmp", "image/x-icon", "image/tiff", "application/pdf",
    "text/plain", "audio/mpeg", "audio/ogg", "audio/wav", "video/mp4", "video/webm"
  ]

  /// Resolves the response content type and disposition for a stored blob. A
  /// media type is caller-supplied at attach time, so an unrecognized or
  /// non-inert one is forced to a generic binary download; recognized inert
  /// types render inline but still download rather than navigate.
  static func responseContentType(for mediaType: String) -> (contentType: String, disposition: String) {
    let sanitized = mediaType.filter { character in
      character.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
    let base = sanitized.split(separator: ";", maxSplits: 1).first.map(String.init) ?? sanitized
    let normalized = base.trimmingCharacters(in: .whitespaces).lowercased()
    guard inlineRenderableMediaTypes.contains(normalized) else {
      return ("application/octet-stream", "attachment")
    }
    return (normalized, "inline")
  }

  private static func notFoundResponse(fileId: FileID) -> KaibaHTTPResponse {
    .json(status: 404, .object([
      "error": .string("note file was not found"),
      "fileId": .string(fileId.rawValue)
    ]))
  }
}
