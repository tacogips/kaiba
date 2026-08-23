import Foundation

import AppCore
import AppGraphQL
import XCTest
@testable import AppServer

private struct SentinelHandler: KaibaHTTPRouteHandling {
  func response(for request: KaibaHTTPRequest) async -> KaibaHTTPResponse {
    .text(status: 299, "delegated:\(request.path)")
  }
}

private struct StubAuthenticator: NoteAPIAuthenticating {
  var acceptedToken: String

  func authenticate(
    request: ServerRequestEnvelope,
    context: ServerRequestContext
  ) async -> NoteAPIAuthenticationResult {
    guard context.bearerToken == acceptedToken else {
      return .rejected(noteAPIUnauthorizedResponse("note API bearer token is invalid or revoked"))
    }
    return .accepted(NoteAPIAuthenticatedClient(clientId: APIClientID("client-1"), displayName: "tester", userId: NoteStoreSchema.defaultUserId))
  }
}

private struct AgentModelsAuthenticator: NoteAPIAuthenticating {
  func authenticate(
    request: ServerRequestEnvelope,
    context: ServerRequestContext
  ) async -> NoteAPIAuthenticationResult {
    guard context.bearerToken == "agent-models-token" else {
      return .rejected(noteAPIUnauthorizedResponse("agent model catalog requires authentication"))
    }
    return .accepted(NoteAPIAuthenticatedClient(
      clientId: APIClientID("agent-client"),
      displayName: "Agent client",
      userId: NoteStoreSchema.defaultUserId
    ))
  }
}

final class KaibaNoteFileHTTPRouterTests: XCTestCase {
  private let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

  func testGetServesStoredBytesWithStoredMediaType() async throws {
    let service = try makeService()
    let attachment = try attachPNG(to: service)
    let router = makeRouter(service: service, allowUnauthenticated: true)

    let response = await router.response(for: KaibaHTTPRequest(
      method: "GET",
      path: "/files/\(attachment.file.fileId)"
    ))

    XCTAssertEqual(response.status, 200)
    XCTAssertEqual(response.headers["Content-Type"], "image/png")
    XCTAssertEqual(response.headers["Content-Length"], String(pngBytes.count))
    XCTAssertEqual(response.headers["Cache-Control"], "private, max-age=3600")
    XCTAssertEqual(response.body, pngBytes)
  }

  func testHeadOmitsBodyButKeepsHeaders() async throws {
    let service = try makeService()
    let attachment = try attachPNG(to: service)
    let router = makeRouter(service: service, allowUnauthenticated: true)

    let response = await router.response(for: KaibaHTTPRequest(
      method: "HEAD",
      path: "/files/\(attachment.file.fileId)"
    ))

    XCTAssertEqual(response.status, 200)
    XCTAssertEqual(response.headers["Content-Type"], "image/png")
    let head = response.serialized(forMethod: "HEAD")
    let get = response.serialized(forMethod: "GET")
    XCTAssertEqual(get.count - head.count, pngBytes.count, "HEAD must not carry the payload")
    XCTAssertTrue(text(head).contains("Content-Length: \(pngBytes.count)"))
  }

  func testUnknownFileIdIsNotFound() async throws {
    let service = try makeService()
    let router = makeRouter(service: service, allowUnauthenticated: true)

    let response = await router.response(for: KaibaHTTPRequest(method: "GET", path: "/files/file-missing"))

    XCTAssertEqual(response.status, 404)
    XCTAssertTrue(text(response.body).contains("note file was not found"))
  }

  func testNonReadMethodIsRejected() async throws {
    let service = try makeService()
    let attachment = try attachPNG(to: service)
    let router = makeRouter(service: service, allowUnauthenticated: true)

    let response = await router.response(for: KaibaHTTPRequest(
      method: "POST",
      path: "/files/\(attachment.file.fileId)"
    ))

    XCTAssertEqual(response.status, 405)
  }

  func testMissingAuthenticatorIsServiceUnavailableUnlessAllowed() async throws {
    let service = try makeService()
    let attachment = try attachPNG(to: service)
    let router = makeRouter(service: service, allowUnauthenticated: false)

    let response = await router.response(for: KaibaHTTPRequest(
      method: "GET",
      path: "/files/\(attachment.file.fileId)"
    ))

    XCTAssertEqual(response.status, 503)
    XCTAssertTrue(text(response.body).contains("authentication is not configured"))
  }

  func testBearerTokenIsRequiredWhenAuthenticatorIsConfigured() async throws {
    let service = try makeService()
    let attachment = try attachPNG(to: service)
    var router = makeRouter(service: service, allowUnauthenticated: false)
    router.authenticator = StubAuthenticator(acceptedToken: "good-token")
    let path = "/files/\(attachment.file.fileId)"

    let anonymous = await router.response(for: KaibaHTTPRequest(method: "GET", path: path))
    XCTAssertEqual(anonymous.status, 401)

    let wrongToken = await router.response(for: KaibaHTTPRequest(
      method: "GET",
      path: path,
      headers: ["Authorization": "Bearer nope"]
    ))
    XCTAssertEqual(wrongToken.status, 401)

    let authorized = await router.response(for: KaibaHTTPRequest(
      method: "GET",
      path: path,
      headers: ["Authorization": "Bearer good-token"]
    ))
    XCTAssertEqual(authorized.status, 200)
    XCTAssertEqual(authorized.body, pngBytes)
  }

  func testUnknownFileIdIsNotDisclosedBeforeAuthentication() async throws {
    let service = try makeService()
    var router = makeRouter(service: service, allowUnauthenticated: false)
    router.authenticator = StubAuthenticator(acceptedToken: "good-token")

    let response = await router.response(for: KaibaHTTPRequest(method: "GET", path: "/files/file-missing"))

    XCTAssertEqual(response.status, 401)
  }

  func testRequestsOutsideTheFilesNamespaceAreDelegated() async throws {
    let service = try makeService()
    let router = makeRouter(service: service, allowUnauthenticated: false)

    for path in ["/", "/graphql", "/filesystem", "/files/nested/id"] {
      let response = await router.response(for: KaibaHTTPRequest(method: "GET", path: path))
      XCTAssertEqual(response.status, 299, "\(path) must reach the downstream handler")
      XCTAssertEqual(text(response.body), "delegated:\(path)")
    }
  }

  func testStaticAssetResolverTreatsFilesAsAServiceNamespace() throws {
    let webRoot = try makeDirectory()
    try Data("<html></html>".utf8).write(to: webRoot.appendingPathComponent("index.html"))
    let resolver = KaibaStaticAssetResolver(rootURL: webRoot)

    XCTAssertNil(resolver.response(for: KaibaHTTPRequest(method: "GET", path: "/files/file-1")))
    XCTAssertNil(resolver.response(for: KaibaHTTPRequest(method: "GET", path: "/files")))
    XCTAssertEqual(resolver.response(for: KaibaHTTPRequest(method: "GET", path: "/"))?.status, 200)
  }

  func testControlCharactersInStoredMediaTypeCannotInjectHeaders() async throws {
    let service = try makeService()
    let attachment = try service.attachFile(
      noteId: try service.createNote(bodyMarkdown: "# Note\nBody.").noteId,
      data: pngBytes,
      role: .related,
      mediaType: "image/png\r\nX-Injected: yes",
      originalFilename: "page.png"
    )
    let router = makeRouter(service: service, allowUnauthenticated: true)

    let response = await router.response(for: KaibaHTTPRequest(
      method: "GET",
      path: "/files/\(attachment.file.fileId)"
    ))

    // The tampered type is neither a control-char header-injection vector nor
    // in the render-safe allowlist, so it collapses to a generic download.
    XCTAssertEqual(response.headers["Content-Type"], "application/octet-stream")
    XCTAssertEqual(response.headers["Content-Disposition"], "attachment")
    let headerBlock = text(response.serialized(forMethod: "HEAD"))
    XCTAssertFalse(headerBlock.isEmpty)
    XCTAssertFalse(headerBlock.contains("\r\nX-Injected:"))
  }

  func testAgentModelsGraphQLRequiresBearerAuthenticationAndProjectsCatalog() async throws {
    let noteService = try makeService()
    let graphQLService = GraphQLNoteGraphQLService(
      service: noteService,
      agentProvider: "openai",
      agentModel: "configured-model",
      agentModelCatalog: {
        AgentGatewayModelCatalogResult(
          protocolVersion: "1", vendor: "openai",
          models: [AgentGatewayModelInfo(modelId: "catalog-model", name: "Catalog model")]
        )
      }
    )
    let handler = DeterministicServerRouteHandler(
      graphQLExecutor: NoteGraphQLDocumentExecutor(service: graphQLService),
      noteAPIAuthenticator: AgentModelsAuthenticator()
    )
    let request = ServerRequestEnvelope(
      method: "POST",
      path: "/graphql",
      body: try JSONEncoder().encode(JSONValue.object([
        "query": .string("query { agentModels { result { accepted status } discoveryAvailable configuredModel models { modelId displayName } } }")
      ]))
    )

    let anonymous = await handler.route(request, context: ServerRequestContext())
    XCTAssertEqual(anonymous.status, 401)

    let authorized = await handler.route(
      request,
      context: ServerRequestContext(bearerToken: "agent-models-token")
    )
    XCTAssertEqual(authorized.status, 200)
    let data = try objectValue(authorized.body["data"], field: "data")
    let catalog = try objectValue(data["agentModels"], field: "agentModels")
    XCTAssertEqual(catalog["discoveryAvailable"], .bool(true))
    XCTAssertEqual(catalog["configuredModel"], .string("configured-model"))
  }

  private func text(_ data: Data) -> String {
    String(bytes: data, encoding: .utf8) ?? ""
  }

  private func objectValue(_ value: JSONValue?, field: String) throws -> JSONObject {
    guard case let .object(object)? = value else {
      throw NSError(domain: "KaibaNoteFileHTTPRouterTests", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "expected object at \(field)"
      ])
    }
    return object
  }

  private func makeRouter(service: NoteService, allowUnauthenticated: Bool) -> KaibaNoteFileHTTPRouter {
    KaibaNoteFileHTTPRouter(
      service: SentinelHandler(),
      noteService: service,
      allowUnauthenticated: allowUnauthenticated
    )
  }

  private func attachPNG(to service: NoteService) throws -> NoteFileAttachment {
    let note = try service.createNote(bodyMarkdown: "# Illustrated\nBody.")
    return try service.attachFile(
      noteId: note.noteId,
      data: pngBytes,
      role: .sourcePageImage,
      mediaType: "image/png",
      originalFilename: "page.png"
    )
  }

  private func makeService(function: String = #function) throws -> NoteService {
    try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: try makeDirectory(function: function).path))
  }

  private func makeDirectory(function: String = #function) throws -> URL {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/AppServerTests", isDirectory: true)
      .appendingPathComponent(function.replacingOccurrences(of: "()", with: ""), isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}
