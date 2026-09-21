import Foundation
import XCTest

import AppCore
@testable import AppServer

/// Bearer check shaped like the other note-route test authenticators: a token
/// the fixture knows maps to an account, anything else is rejected with the
/// production 401 body.
private struct CaptureAuthenticator: NoteAPIAuthenticating {
  var usersByToken: [String: UserID]

  func authenticate(
    request _: ServerRequestEnvelope,
    context: ServerRequestContext
  ) async -> NoteAPIAuthenticationResult {
    guard let token = context.bearerToken, let userId = usersByToken[token] else {
      return .rejected(noteAPIUnauthorizedResponse("note API bearer token is invalid or revoked"))
    }
    return .accepted(NoteAPIAuthenticatedClient(
      clientId: APIClientID("client-\(userId.rawValue)"),
      displayName: userId.rawValue,
      userId: userId
    ))
  }
}

/// Raises a chosen `NoteServiceError` out of the service the route calls, so
/// every branch of the C6 error mapping is exercised rather than argued for.
///
/// It has to delegate to a real store until `arm()` is called: `NoteService.init`
/// runs `NoteStoreSchema.prepare(on:)` and the long-term-memory bootstrap
/// through this same driver, and a driver that threw from the start would
/// simply fail construction and leave the route answering 503.
private final class ArmedFailureDriver: NoteDatabaseDriving, @unchecked Sendable {
  let databasePath: String
  private let backing: any NoteDatabaseDriving
  private let error: NoteServiceError
  private let lock = NSLock()
  private var armed = false

  init(backing: any NoteDatabaseDriving, error: NoteServiceError) {
    databasePath = backing.databasePath
    self.backing = backing
    self.error = error
  }

  func arm() {
    lock.lock()
    armed = true
    lock.unlock()
  }

  func withDatabase<T>(_ body: (SQLiteDatabase) throws -> T) throws -> T {
    lock.lock()
    let shouldFail = armed
    lock.unlock()
    if shouldFail {
      throw error
    }
    return try backing.withDatabase(body)
  }
}

private struct UnreachableSPAService: KaibaHTTPRouteHandling {
  func response(for request: KaibaHTTPRequest) async -> KaibaHTTPResponse {
    KaibaHTTPResponse.text(status: 599, "service reached for \(request.path)")
  }
}

final class NoteCaptureRouteTests: XCTestCase {
  // MARK: - 201

  func testAuthenticatedCaptureCreatesTheNoteInTheQuickMemosNotebook() async throws {
    let service = try makeService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let handler = DeterministicServerRouteHandler(
      noteAPIAuthenticator: CaptureAuthenticator(usersByToken: ["alice-token": alice.userId]),
      noteService: service
    )

    let response = await handler.route(
      captureRequest(body: #"{"text":"buy oat milk"}"#),
      context: .init(serviceName: "test", bearerToken: "alice-token")
    )

    XCTAssertEqual(response.status, 201)
    XCTAssertEqual(Set(response.body.keys), ["noteId", "notebookId", "noteNumber"])
    guard case let .string(noteId)? = response.body["noteId"],
          case let .string(notebookId)? = response.body["notebookId"] else {
      return XCTFail("expected string ids, got \(response.body)")
    }
    XCTAssertEqual(response.body["noteNumber"], .integer(1))

    // The ids in the body address the real rows, and the note landed in the
    // kind-tagged capture notebook rather than a fresh per-call one.
    let scoped = service.scoped(to: alice.userId)
    let note = try scoped.getNote(NoteID(noteId))
    XCTAssertEqual(note.bodyMarkdown, "buy oat milk")
    XCTAssertEqual(note.notebookId.rawValue, notebookId)
    let notebook = try scoped.getNotebook(NotebookID(notebookId))
    XCTAssertEqual(notebook.title, NoteService.quickMemoNotebookTitle)
  }

  func testRepeatedCapturesAccumulateInOneNotebookAndHonourAnExplicitTitle() async throws {
    let service = try makeService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let handler = DeterministicServerRouteHandler(
      noteAPIAuthenticator: CaptureAuthenticator(usersByToken: ["alice-token": alice.userId]),
      noteService: service
    )
    let context = ServerRequestContext(serviceName: "test", bearerToken: "alice-token")

    let first = await handler.route(captureRequest(body: #"{"text":"one"}"#), context: context)
    let second = await handler.route(
      captureRequest(body: #"{"text":"two","title":"  Groceries  "}"#),
      context: context
    )

    XCTAssertEqual(first.status, 201)
    XCTAssertEqual(second.status, 201)
    XCTAssertEqual(first.body["notebookId"], second.body["notebookId"])
    XCTAssertEqual(first.body["noteNumber"], .integer(1))
    XCTAssertEqual(second.body["noteNumber"], .integer(2))

    guard case let .string(secondId)? = second.body["noteId"] else {
      return XCTFail("expected a note id, got \(second.body)")
    }
    // A title survives the route verbatim apart from trimming.
    let note = try service.scoped(to: alice.userId).getNote(NoteID(secondId))
    XCTAssertEqual(note.title, "Groceries")
  }

  func testUnauthenticatedServingCapturesAsTheDefaultUser() async throws {
    // `serve --allow-unauthenticated`: no authenticator wired, capture acts as
    // the default account exactly as every other note route does (C2).
    let service = try makeService()
    let handler = DeterministicServerRouteHandler(
      allowUnauthenticatedNoteAPI: true,
      noteService: service
    )

    let response = await handler.route(
      captureRequest(body: #"{"text":"from the phone"}"#),
      context: .init(serviceName: "test")
    )

    XCTAssertEqual(response.status, 201)
    guard case let .string(noteId)? = response.body["noteId"] else {
      return XCTFail("expected a note id, got \(response.body)")
    }
    let note = try service.scoped(to: NoteStoreSchema.defaultUserId).getNote(NoteID(noteId))
    XCTAssertEqual(note.bodyMarkdown, "from the phone")
  }

  func testABlankTitleIsCollapsedSoTheBodyDerivesOne() async throws {
    let service = try makeService()
    let handler = DeterministicServerRouteHandler(
      allowUnauthenticatedNoteAPI: true,
      noteService: service
    )

    let response = await handler.route(
      captureRequest(body: #"{"text":"derive me","title":"   "}"#),
      context: .init(serviceName: "test")
    )

    XCTAssertEqual(response.status, 201)
    guard case let .string(noteId)? = response.body["noteId"] else {
      return XCTFail("expected a note id, got \(response.body)")
    }
    let note = try service.scoped(to: NoteStoreSchema.defaultUserId).getNote(NoteID(noteId))
    XCTAssertNotEqual(note.title, "", "a whitespace-only title must not be stored as a heading")
  }

  // MARK: - 400

  func testEveryMalformedBodyAnswersTheSingleC6BadRequestBody() async throws {
    let service = try makeService()
    let handler = DeterministicServerRouteHandler(
      allowUnauthenticatedNoteAPI: true,
      noteService: service
    )
    let expected: JSONObject = [
      "error": .string(DeterministicServerRouteHandler.noteCaptureInvalidBodyMessage)
    ]
    let malformed: [(label: String, body: Data?)] = [
      ("absent body", nil),
      ("empty body", Data()),
      ("not JSON", Data("not json".utf8)),
      ("JSON array", Data("[]".utf8)),
      ("JSON string", Data(#""text""#.utf8)),
      ("missing text", Data(#"{"title":"only a title"}"#.utf8)),
      ("null text", Data(#"{"text":null}"#.utf8)),
      ("numeric text", Data(#"{"text":42}"#.utf8)),
      ("empty text", Data(#"{"text":""}"#.utf8)),
      ("whitespace-only text", Data("{\"text\":\" \\n\\t \"}".utf8)),
      ("numeric title", Data(#"{"text":"ok","title":7}"#.utf8))
    ]

    for (label, body) in malformed {
      let response = await handler.route(
        ServerRequestEnvelope(method: "POST", path: "/note/capture", body: body),
        context: .init(serviceName: "test")
      )
      XCTAssertEqual(response.status, 400, "\(label) should be rejected")
      XCTAssertEqual(response.body, expected, "\(label) must use the one C6 body")
    }

    // A rejected capture must not have created the notebook as a side effect.
    let notebooks = try service.scoped(to: NoteStoreSchema.defaultUserId).listNotebooks()
    XCTAssertFalse(
      notebooks.contains { $0.title == NoteService.quickMemoNotebookTitle },
      "no malformed request may bootstrap the capture notebook"
    )
  }

  func testServiceInvalidInputIsMappedTo400AndNeverTo500() async throws {
    // RF3: `captureQuickMemo` validates the body again as defence in depth, and
    // the C3 singleton invariant fails the same way when two notebooks carry
    // the quick-memo kind tag. Neither may reach the caller as a 500.
    let handler = DeterministicServerRouteHandler(
      allowUnauthenticatedNoteAPI: true,
      noteService: try makeFailingService(
        .invalidInput("multiple notebooks carry notebook-kind:quick-memo")
      )
    )

    let response = await handler.route(
      captureRequest(body: #"{"text":"well formed"}"#),
      context: .init(serviceName: "test")
    )

    XCTAssertEqual(response.status, 400)
    XCTAssertEqual(response.body, [
      "error": .string(DeterministicServerRouteHandler.noteCaptureInvalidBodyMessage)
    ])
    // The store's own wording never reaches the wire.
    XCTAssertFalse(
      describeBody(response).contains("notebook-kind:quick-memo"),
      "the service message must not be echoed: \(response.body)"
    )
  }

  // MARK: - 401

  func testAnInvalidOrAbsentCredentialAnswersTheExisting401Body() async throws {
    let service = try makeService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let handler = DeterministicServerRouteHandler(
      noteAPIAuthenticator: CaptureAuthenticator(usersByToken: ["alice-token": alice.userId]),
      noteService: service
    )
    let expected = noteAPIUnauthorizedResponse("note API bearer token is invalid or revoked")

    for token in [nil, "wrong-token"] {
      let response = await handler.route(
        captureRequest(body: #"{"text":"denied"}"#),
        context: .init(serviceName: "test", bearerToken: token)
      )
      XCTAssertEqual(response.status, 401)
      XCTAssertEqual(response.body, expected.body, "401 must reuse the shared body shape")
    }

    // Rejection happens before any write.
    let notebooks = try service.scoped(to: alice.userId).listNotebooks()
    XCTAssertTrue(notebooks.isEmpty, "an unauthenticated capture must not touch the store")
  }

  func testADisabledAccountAnswers401RatherThan500() async throws {
    let handler = DeterministicServerRouteHandler(
      allowUnauthenticatedNoteAPI: true,
      noteService: try makeFailingService(.accountUnavailable("user is disabled"))
    )

    let response = await handler.route(
      captureRequest(body: #"{"text":"well formed"}"#),
      context: .init(serviceName: "test")
    )

    XCTAssertEqual(response.status, 401)
    XCTAssertEqual(
      response.body,
      noteAPIUnauthorizedResponse("note API bearer token is invalid or revoked").body
    )
  }

  // MARK: - 404

  func testASecondAccountAnswersAGeneric404ThatNamesNoForeignNotebook() async throws {
    // RF1: `quickMemoNotebookIds` is a store-wide lookup while notebook reach is
    // per-account, so once Alice owns the singleton, Bob's capture fails with a
    // service error naming ALICE's notebook id. The route must map that to 404
    // and must not put that id on the wire. The per-account-versus-store-wide
    // C3 decision itself is TASK-009's; the route is not redesigning it here.
    let service = try makeService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let bob = try service.createUser(email: "bob@example.com", displayName: "Bob")
    let handler = DeterministicServerRouteHandler(
      noteAPIAuthenticator: CaptureAuthenticator(usersByToken: [
        "alice-token": alice.userId,
        "bob-token": bob.userId
      ]),
      noteService: service
    )

    let owned = await handler.route(
      captureRequest(body: #"{"text":"alice first"}"#),
      context: .init(serviceName: "test", bearerToken: "alice-token")
    )
    XCTAssertEqual(owned.status, 201)
    guard case let .string(aliceNotebookId)? = owned.body["notebookId"] else {
      return XCTFail("expected Alice's notebook id, got \(owned.body)")
    }

    let refused = await handler.route(
      captureRequest(body: #"{"text":"bob second"}"#),
      context: .init(serviceName: "test", bearerToken: "bob-token")
    )

    XCTAssertEqual(refused.status, 404, "the refusal must not surface as a 500")
    XCTAssertEqual(refused.body, [
      "error": .string(DeterministicServerRouteHandler.noteCaptureNotebookUnavailableMessage)
    ])
    XCTAssertFalse(
      describeBody(refused).contains(aliceNotebookId),
      "a foreign notebook id must never be echoed: \(refused.body)"
    )
  }

  // MARK: - 405

  func testEveryOtherMethodOnTheKnownPathAnswersTheExistingUnsupportedMethodBody() async throws {
    let service = try makeService()
    let handler = DeterministicServerRouteHandler(
      allowUnauthenticatedNoteAPI: true,
      noteService: service
    )

    // GET is the SPA capture page (C5); a server with no web assets has no page
    // to serve, so the known path answers 405 rather than 404.
    for method in ["GET", "PUT", "PATCH", "DELETE", "HEAD"] {
      let response = await handler.route(
        ServerRequestEnvelope(method: method, path: "/note/capture"),
        context: .init(serviceName: "test")
      )
      XCTAssertEqual(response.status, 405, "\(method) /note/capture")
      XCTAssertEqual(response.body, [
        "error": .string("unsupported method"),
        "method": .string(method),
        "path": .string("/note/capture")
      ], "405 must reuse the existing unsupported-method body")
    }

    // A neighbouring unknown path is still a 404, so adding the route did not
    // widen the known-path set.
    let unknown = await handler.route(
      ServerRequestEnvelope(method: "POST", path: "/note/captures"),
      context: .init(serviceName: "test")
    )
    XCTAssertEqual(unknown.status, 404)
    XCTAssertEqual(unknown.body["error"], .string("unknown path"))
  }

  // MARK: - 503

  func testAnUnconfiguredServerAnswersTheExisting503Bodies() async throws {
    // No authenticator and no `--allow-unauthenticated`: the same guard, and the
    // same body, that `routeNoteEvents` and `/graphql` already return.
    let service = try makeService()
    let noAuthenticator = DeterministicServerRouteHandler(noteService: service)
    let authResponse = await noAuthenticator.route(
      captureRequest(body: #"{"text":"nowhere to go"}"#),
      context: .init(serviceName: "test")
    )
    XCTAssertEqual(authResponse.status, 503)
    XCTAssertEqual(
      authResponse.body,
      noteAPIUnavailableResponse("note API authentication is not configured").body
    )

    // Authentication configured, but no store behind it.
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let noStore = DeterministicServerRouteHandler(
      noteAPIAuthenticator: CaptureAuthenticator(usersByToken: ["alice-token": alice.userId])
    )
    let storeResponse = await noStore.route(
      captureRequest(body: #"{"text":"nowhere to go"}"#),
      context: .init(serviceName: "test", bearerToken: "alice-token")
    )
    XCTAssertEqual(storeResponse.status, 503)
    XCTAssertEqual(
      storeResponse.body,
      noteAPIUnavailableResponse("note API ownership scope is not configured").body
    )

    // `--allow-unauthenticated` with no store reaches the same 503, not a crash.
    let openNoStore = DeterministicServerRouteHandler(allowUnauthenticatedNoteAPI: true)
    let openResponse = await openNoStore.route(
      captureRequest(body: #"{"text":"nowhere to go"}"#),
      context: .init(serviceName: "test")
    )
    XCTAssertEqual(openResponse.status, 503)
    XCTAssertEqual(
      openResponse.body,
      noteAPIUnavailableResponse("note API ownership scope is not configured").body
    )
  }

  // MARK: - unexpected failures

  func testAnUnexpectedStoreFailureAnswersAGeneric500() async throws {
    // The remaining `NoteServiceError` cases are not reachable through this
    // route (the capture notebook is never read-only and capture records no
    // undoable conflict), so they are deliberately a logged 500 rather than a
    // silent success. The body still carries no store detail.
    let handler = DeterministicServerRouteHandler(
      allowUnauthenticatedNoteAPI: true,
      noteService: try makeFailingService(
        .invalidRow("notebooks row is malformed at notebook-1234")
      )
    )

    let response = await handler.route(
      captureRequest(body: #"{"text":"well formed"}"#),
      context: .init(serviceName: "test")
    )

    XCTAssertEqual(response.status, 500)
    XCTAssertEqual(response.body, ["error": .string("quick memo could not be captured")])
    XCTAssertFalse(describeBody(response).contains("notebook-1234"))
  }

  // MARK: - C5 SPA bootstrap

  func testTheCapturePageIsServedThroughTheSameBootstrapRewriteAsRegister() async throws {
    let webRoot = try makeDirectory()
    let markup = "<!doctype html><title>kaiba</title>"
    try Data(markup.utf8).write(to: webRoot.appendingPathComponent("index.html"))
    let router = KaibaStaticSPAHTTPRouter(service: UnreachableSPAService(), webRoot: webRoot)

    // `/note/capture` and `/note/register` must resolve identically: both are
    // SPA views living under the `/note` service prefix.
    for path in ["/note/capture", "/note/register"] {
      let response = await router.response(for: KaibaHTTPRequest(method: "GET", path: path))
      XCTAssertEqual(response.status, 200, "GET \(path)")
      XCTAssertEqual(response.body, Data(markup.utf8), "GET \(path)")
      XCTAssertEqual(response.headers["Content-Type"], "text/html; charset=utf-8")
    }

    // POST is the API, so it still reaches the service rather than the page.
    let posted = await router.response(
      for: KaibaHTTPRequest(method: "POST", path: "/note/capture")
    )
    XCTAssertEqual(posted.status, 599, "POST /note/capture must reach the note API")
  }

  func testTheCaptureBootstrapStillRequiresTheAssetToExist() async throws {
    // An API-only deployment has no `index.html`; the rewrite must not invent a
    // page, and it must not fall through to the note API either.
    let router = KaibaStaticSPAHTTPRouter(
      service: UnreachableSPAService(),
      webRoot: try makeDirectory()
    )
    let response = await router.response(
      for: KaibaHTTPRequest(method: "GET", path: "/note/capture")
    )
    XCTAssertEqual(response.status, 404)
  }

  // MARK: - helpers

  private func captureRequest(body: String) -> ServerRequestEnvelope {
    ServerRequestEnvelope(
      method: "POST",
      path: "/note/capture",
      headers: ["Content-Type": "application/json"],
      body: Data(body.utf8)
    )
  }

  private func describeBody(_ response: ServerResponseDescriptor) -> String {
    String(describing: response.body)
  }

  private func makeDirectory(function: String = #function) throws -> URL {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/AppServerTests", isDirectory: true)
      .appendingPathComponent(function.replacingOccurrences(of: "()", with: ""), isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func makeService(function: String = #function) throws -> NoteService {
    try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: makeDirectory(function: function).path))
  }

  /// A fully constructed service whose every subsequent database access raises
  /// `error`, so the route's error mapping is measured on a service that built
  /// exactly as the real one does.
  private func makeFailingService(
    _ error: NoteServiceError,
    function: String = #function
  ) throws -> NoteService {
    let driver = ArmedFailureDriver(
      backing: try SQLiteNoteDatabaseDriver(noteRoot: makeDirectory(function: function).path),
      error: error
    )
    let service = try NoteService(driver: driver)
    driver.arm()
    return service
  }
}
