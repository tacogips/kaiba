import Foundation

import AppCore
import AppGraphQL
import XCTest
@testable import AppServer

// `GET /files/<id>` serves raw bytes without going through the GraphQL
// executor, so it is the one route that can cross a library boundary on its
// own (`design-docs/specs/library.md`).

private struct LibrarySentinelHandler: KaibaHTTPRouteHandling {
  func response(for request: KaibaHTTPRequest) async -> KaibaHTTPResponse {
    .text(status: 299, "delegated:\(request.path)")
  }
}

private struct LibraryStubAuthenticator: NoteAPIAuthenticating {
  var acceptedToken: String

  func authenticate(
    request: ServerRequestEnvelope,
    context: ServerRequestContext
  ) async -> NoteAPIAuthenticationResult {
    guard context.bearerToken == acceptedToken else {
      return .rejected(noteAPIUnauthorizedResponse("note API bearer token is invalid or revoked"))
    }
    return .accepted(NoteAPIAuthenticatedClient(
      clientId: APIClientID("client-1"),
      displayName: "tester",
      userId: NoteStoreSchema.defaultUserId
    ))
  }
}

final class KaibaNoteFileHTTPRouterLibraryTests: XCTestCase {
  private let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

  func testUnauthenticatedReaderCannotFetchAFileFromAnAuthenticatedLibrary() async throws {
    let service = try makeService()
    let attachment = try attachPNG(to: service, library: "shared", authRequired: true)
    let router = KaibaNoteFileHTTPRouter(
      service: LibrarySentinelHandler(),
      noteService: service,
      allowUnauthenticated: true
    )

    let response = await router.response(for: KaibaHTTPRequest(
      method: "GET",
      path: "/files/\(attachment.file.fileId)"
    ))

    // The same 404 a bogus id gets: the route must not confirm the file exists.
    XCTAssertEqual(response.status, 404)
    XCTAssertFalse(response.body.contains(pngBytes))
  }

  func testUnauthenticatedReaderStillFetchesAFileFromAnOpenLibrary() async throws {
    let service = try makeService()
    let attachment = try attachPNG(to: service, library: nil, authRequired: false)
    let router = KaibaNoteFileHTTPRouter(
      service: LibrarySentinelHandler(),
      noteService: service,
      allowUnauthenticated: true
    )

    let response = await router.response(for: KaibaHTTPRequest(
      method: "GET",
      path: "/files/\(attachment.file.fileId)"
    ))

    XCTAssertEqual(response.status, 200)
    XCTAssertEqual(response.body, pngBytes)
  }

  func testAuthenticatedReaderFetchesAFileFromAnAuthenticatedLibrary() async throws {
    let service = try makeService()
    let attachment = try attachPNG(to: service, library: "shared", authRequired: true)
    let router = KaibaNoteFileHTTPRouter(
      service: LibrarySentinelHandler(),
      noteService: service,
      authenticator: LibraryStubAuthenticator(acceptedToken: "token-1")
    )

    let response = await router.response(for: KaibaHTTPRequest(
      method: "GET",
      path: "/files/\(attachment.file.fileId)",
      headers: ["Authorization": "Bearer token-1"]
    ))

    XCTAssertEqual(response.status, 200)
    XCTAssertEqual(response.body, pngBytes)
  }

  // `serve --allow-unauthenticated --as-admin`: the operator has said this
  // port acts as the seeded admin, so the bytes follow the queries
  // (`design-docs/specs/library.md`).
  func testAsAdminReaderFetchesAFileFromAnAuthenticatedLibrary() async throws {
    let service = try makeService()
    let attachment = try attachPNG(to: service, library: "shared", authRequired: true)
    let router = KaibaNoteFileHTTPRouter(
      service: LibrarySentinelHandler(),
      noteService: service,
      allowUnauthenticated: true,
      unauthenticatedActsAsAdmin: true
    )

    let response = await router.response(for: KaibaHTTPRequest(
      method: "GET",
      path: "/files/\(attachment.file.fileId)"
    ))

    XCTAssertEqual(response.status, 200)
    XCTAssertEqual(response.body, pngBytes)
  }

  private func attachPNG(
    to service: NoteService,
    library: String?,
    authRequired: Bool
  ) throws -> NoteFileAttachment {
    var writer = service
    if let library {
      let created = try service.createLibrary(name: library, authRequired: authRequired)
      writer = service.scoped(toLibrary: created.libraryId)
    }
    let note = try writer.createNote(bodyMarkdown: "# Illustrated\nBody.")
    return try writer.attachFile(
      noteId: note.noteId,
      data: pngBytes,
      role: .sourcePageImage,
      mediaType: "image/png",
      originalFilename: "page.png"
    )
  }

  private func makeService(function: String = #function) throws -> NoteService {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/AppServerTests", isDirectory: true)
      .appendingPathComponent(function.replacingOccurrences(of: "()", with: ""), isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
  }
}
