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
  var userId: UserID = NoteStoreSchema.defaultUserId

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
      userId: userId
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

  // Finding 3: an authenticated but non-admin client that is a member of no
  // library must not read a file in an `auth_required` library through the raw
  // bytes route, even though its token authenticates — the route used to skip
  // the per-account membership check the GraphQL executor applies.
  func testAuthenticatedNonMemberCannotFetchAFileFromAnAuthenticatedLibrary() async throws {
    let service = try makeService()
    let attachment = try attachPNG(to: service, library: "shared", authRequired: true)
    let outsider = try service.createUser(email: "outsider@example.com", displayName: "Outsider")
    let router = KaibaNoteFileHTTPRouter(
      service: LibrarySentinelHandler(),
      noteService: service,
      authenticator: LibraryStubAuthenticator(acceptedToken: "token-1", userId: outsider.userId)
    )

    let response = await router.response(for: KaibaHTTPRequest(
      method: "GET",
      path: "/files/\(attachment.file.fileId)",
      headers: ["Authorization": "Bearer token-1"]
    ))

    XCTAssertEqual(response.status, 404)
    XCTAssertFalse(response.body.contains(pngBytes))
  }

  // A member of the library still gets the bytes: scoping must not lock out a
  // legitimate reader.
  func testAuthenticatedMemberFetchesAFileFromAnAuthenticatedLibrary() async throws {
    let service = try makeService()
    let created = try service.createLibrary(name: "shared", authRequired: true)
    let member = try service.createUser(email: "member@example.com", displayName: "Member")
    _ = try service.grantLibraryAccess(libraryName: "shared", userId: member.userId)
    let writer = service.scoped(toLibrary: created.libraryId)
    let note = try writer.createNote(bodyMarkdown: "# Illustrated\nBody.")
    let attachment = try writer.attachFile(
      noteId: note.noteId,
      data: pngBytes,
      role: .sourcePageImage,
      mediaType: "image/png",
      originalFilename: "page.png"
    )
    let router = KaibaNoteFileHTTPRouter(
      service: LibrarySentinelHandler(),
      noteService: service,
      authenticator: LibraryStubAuthenticator(acceptedToken: "token-1", userId: member.userId)
    )

    let response = await router.response(for: KaibaHTTPRequest(
      method: "GET",
      path: "/files/\(attachment.file.fileId)",
      headers: ["Authorization": "Bearer token-1"]
    ))

    XCTAssertEqual(response.status, 200)
    XCTAssertEqual(response.body, pngBytes)
  }

  // Finding 4: an attacker-chosen active media type is served as an inert
  // download, never as an HTML document on kaiba's origin.
  func testHTMLAttachmentIsServedAsInertDownload() async throws {
    let service = try makeService()
    let note = try service.createNote(bodyMarkdown: "# Page\nBody.")
    let html = Data("<script>alert(document.cookie)</script>".utf8)
    let attachment = try service.attachFile(
      noteId: note.noteId,
      data: html,
      role: .related,
      mediaType: "text/html",
      originalFilename: "x.html"
    )
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
    XCTAssertEqual(response.headers["Content-Type"], "application/octet-stream")
    XCTAssertEqual(response.headers["Content-Disposition"], "attachment")
    XCTAssertEqual(response.headers["Content-Security-Policy"], "default-src 'none'; sandbox")
  }

  func testKnownImageTypeRendersInline() {
    let (contentType, disposition) = KaibaNoteFileHTTPRouter.responseContentType(for: "image/png")
    XCTAssertEqual(contentType, "image/png")
    XCTAssertEqual(disposition, "inline")
    let svg = KaibaNoteFileHTTPRouter.responseContentType(for: "image/svg+xml")
    XCTAssertEqual(svg.contentType, "application/octet-stream")
    XCTAssertEqual(svg.disposition, "attachment")
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
