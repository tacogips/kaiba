import Foundation

import AppCore
@testable import AppServer
import XCTest

private struct AuthorizationFailureAuthenticator: NoteAPIAuthenticating {
  let userId: UserID

  func authenticate(
    request _: ServerRequestEnvelope,
    context: ServerRequestContext
  ) async -> NoteAPIAuthenticationResult {
    .accepted(NoteAPIAuthenticatedClient(
      clientId: APIClientID("authorization-failure-client"),
      displayName: "Alice",
      userId: userId
    ))
  }
}

private final class OneShotAuthorizationTableFailureDriver: NoteDatabaseDriving, @unchecked Sendable {
  let databasePath: String
  private let backing: any NoteDatabaseDriving
  private let tableName: String
  private let lock = NSLock()
  private var isArmed = false

  init(backing: any NoteDatabaseDriving, tableName: String) {
    databasePath = backing.databasePath
    self.backing = backing
    self.tableName = tableName
  }

  func arm() {
    lock.lock()
    isArmed = true
    lock.unlock()
  }

  func withDatabase<T>(_ body: (SQLiteDatabase) throws -> T) throws -> T {
    lock.lock()
    let shouldFail = isArmed
    isArmed = false
    lock.unlock()
    guard shouldFail else {
      return try backing.withDatabase(body)
    }
    let hiddenTableName = "injected_\(tableName)"
    return try backing.withDatabase { database in
      try database.execute("ALTER TABLE \(tableName) RENAME TO \(hiddenTableName)")
      do {
        let result = try body(database)
        try database.execute("ALTER TABLE \(hiddenTableName) RENAME TO \(tableName)")
        return result
      } catch {
        try? database.execute("ALTER TABLE \(hiddenTableName) RENAME TO \(tableName)")
        throw error
      }
    }
  }
}

final class NoteEventRouteAuthorizationFailureTests: XCTestCase {
  func testEventFeedRetainsDeliveredBatchWhenReplayAuthorizationReadFails() async throws {
    let service = try makeService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let library = try service.scoped(to: alice.userId).createLibrary(
      name: "private-replay", authRequired: true
    )
    let note = try service.scoped(to: alice.userId)
      .scoped(toLibrary: library.libraryId)
      .createNote(bodyMarkdown: "# Alice\nPrivate")
    let failureDriver = OneShotAuthorizationTableFailureDriver(
      backing: service.driver,
      tableName: "libraries"
    )
    var reader = service
    reader.driver = failureDriver
    let feed = NoteChangeFeed()
    let handler = DeterministicServerRouteHandler(
      noteAPIAuthenticator: AuthorizationFailureAuthenticator(userId: alice.userId),
      noteService: reader,
      noteChangeFeed: feed
    )
    let cursor = try await eventCursor(handler: handler, since: "0")
    await feed.publish(NoteChangeEvent(
      kind: NoteChangeEventKind.noteUpdated,
      notebookId: note.notebookId,
      tagNames: ["alice-visible"]
    ))

    _ = await handler.route(request(since: cursor), context: .init(serviceName: "test"))
    failureDriver.arm()

    let failedReplay = await handler.route(request(since: cursor), context: .init(serviceName: "test"))
    XCTAssertEqual(failedReplay.status, 500)
    XCTAssertNil(failedReplay.body["revision"])

    let retry = await handler.route(request(since: cursor), context: .init(serviceName: "test"))
    XCTAssertEqual(retry.status, 200)
    XCTAssertNotEqual(retry.body["revision"], .string(cursor))
    XCTAssertEqual(retry.body["events"], .array([.object([
      "kind": .string(NoteChangeEventKind.noteUpdated),
      "notebookId": .string(note.notebookId.rawValue),
      "tagNames": .array([.string("alice-visible")])
    ])]))
  }

  func testEventFeedRetriesAfterAdminLibraryAndMembershipAuthorizationReadFailures() async throws {
    for tableName in ["users", "libraries", "library_members"] {
      let service = try makeService()
      let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
      let library = try service.scoped(to: alice.userId).createLibrary(
        name: "private-\(tableName)", authRequired: true
      )
      let note = try service.scoped(to: alice.userId)
        .scoped(toLibrary: library.libraryId)
        .createNote(bodyMarkdown: "# Alice\nPrivate")
      let failureDriver = OneShotAuthorizationTableFailureDriver(
        backing: service.driver,
        tableName: tableName
      )
      var reader = service
      reader.driver = failureDriver
      let feed = NoteChangeFeed()
      let handler = DeterministicServerRouteHandler(
        noteAPIAuthenticator: AuthorizationFailureAuthenticator(userId: alice.userId),
        noteService: reader,
        noteChangeFeed: feed
      )
      let cursor = try await eventCursor(handler: handler, since: "0")

      failureDriver.arm()
      await feed.publish(NoteChangeEvent(
        kind: NoteChangeEventKind.noteUpdated,
        notebookId: note.notebookId,
        tagNames: ["alice-visible"]
      ))

      let failed = await handler.route(
        request(since: cursor), context: .init(serviceName: "test")
      )
      let retry = await handler.route(
        request(since: cursor), context: .init(serviceName: "test")
      )

      XCTAssertEqual(failed.status, 500, "\(tableName) failures must not become notFound")
      XCTAssertNil(failed.body["revision"])
      XCTAssertEqual(retry.status, 200)
      XCTAssertNotEqual(retry.body["revision"], .string(cursor))
      XCTAssertEqual(retry.body["resync"], .bool(false))
      XCTAssertEqual(retry.body["events"], .array([.object([
        "kind": .string(NoteChangeEventKind.noteUpdated),
        "notebookId": .string(note.notebookId.rawValue),
        "tagNames": .array([.string("alice-visible")])
      ])]))
    }
  }

  private func request(since: String) -> ServerRequestEnvelope {
    ServerRequestEnvelope(method: "GET", path: "/note/events", query: "since=\(since)&timeoutMs=0")
  }

  private func eventCursor(
    handler: DeterministicServerRouteHandler,
    since: String
  ) async throws -> String {
    let response = await handler.route(request(since: since), context: .init(serviceName: "test"))
    XCTAssertEqual(response.status, 200)
    guard case let .string(cursor)? = response.body["revision"] else {
      throw NoteServiceError.invalidRow("event reset response has no opaque cursor")
    }
    return cursor
  }

  private func makeService(function: String = #function) throws -> NoteService {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/NoteEventRouteAuthorizationFailureTests", isDirectory: true)
      .appendingPathComponent(function.replacingOccurrences(of: "()", with: ""), isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
  }
}
