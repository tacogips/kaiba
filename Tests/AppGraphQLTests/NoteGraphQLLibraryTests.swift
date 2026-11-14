import Foundation

import AppGraphQL
import AppCore
import XCTest

// Library visibility over the note API (`design-docs/specs/library.md`). The
// discriminator is the transport's `isUnauthenticatedRequest`, because an
// unauthenticated request already resolves to the default user and the local
// `kaiba graphql` operator path also carries no authenticated client id.

final class NoteGraphQLLibraryTests: XCTestCase {
  func testUnauthenticatedRequestSeesOnlyOpenLibrariesAndTheirNotebooks() async throws {
    let executor = try makeExecutor()

    let libraries = try await libraryNames(from: executor, unauthenticated: true)
    XCTAssertEqual(libraries, ["default"])
    let titles = try await notebookTitles(from: executor, unauthenticated: true)
    XCTAssertTrue(titles.contains("Public"))
    XCTAssertFalse(titles.contains("Private"))
  }

  /// The fixture's library is created by the default user, which makes that
  /// account its owner — so an authenticated request as that account reaches
  /// it. A different account would not (`NoteLibraryMemberTests`).
  func testAuthenticatedRequestSeesTheLibrariesItsAccountIsAMemberOf() async throws {
    let executor = try makeExecutor()

    let libraries = try await libraryNames(from: executor, unauthenticated: false)

    XCTAssertEqual(libraries, ["default", "shared"])
  }

  /// The local operator path (`kaiba graphql`) carries no authenticated client
  /// id either. Inferring the marker from that field hid the operator's own
  /// libraries from them.
  func testLocalOperatorRequestIsNotTreatedAsUnauthenticated() async throws {
    let executor = try makeExecutor()

    let response = await executor.execute(GraphQLDocumentRequest(
      query: "{ libraries { value { name } } }"
    ))

    XCTAssertEqual(try names(in: response), ["default", "shared"])
  }

  /// The note API is the path an outsider actually has. Holding an id must not
  /// be enough there either (`design-docs/specs/library.md`).
  func testUnauthenticatedRequestCannotFetchAHiddenNoteById() async throws {
    let noteService = try makeNoteService(function: #function)
    let shared = try noteService.createLibrary(name: "shared", authRequired: true)
    let hidden = try noteService.scoped(toLibrary: shared.libraryId)
      .createNote(bodyMarkdown: "# Private\nclassified body")
    let executor = NoteGraphQLDocumentExecutor(service: GraphQLNoteGraphQLService(service: noteService))

    let response = await executor.execute(GraphQLDocumentRequest(
      query: "query Note($noteId: String!) { note(noteId: $noteId) { result { accepted status } value { bodyMarkdown } } }",
      variables: ["noteId": .string(hidden.noteId.rawValue)],
      operationName: "Note",
      actingUserId: NoteStoreSchema.defaultUserId,
      isUnauthenticatedRequest: true
    ))

    let rendered = String(describing: response.body)
    XCTAssertFalse(rendered.contains("classified body"))
    XCTAssertFalse(rendered.contains("\"accepted\" : true"))
  }

  func testUnauthenticatedSearchDoesNotSurfaceAHiddenNote() async throws {
    let noteService = try makeNoteService(function: #function)
    let shared = try noteService.createLibrary(name: "shared", authRequired: true)
    _ = try noteService.scoped(toLibrary: shared.libraryId)
      .createNote(bodyMarkdown: "# Private\nclassified body")
    let executor = NoteGraphQLDocumentExecutor(service: GraphQLNoteGraphQLService(service: noteService))

    let response = await executor.execute(GraphQLDocumentRequest(
      query: "{ searchNotes(query: \"classified\") { value { note { bodyMarkdown } } } }",
      actingUserId: NoteStoreSchema.defaultUserId,
      isUnauthenticatedRequest: true
    ))

    XCTAssertFalse(String(describing: response.body).contains("classified body"))
  }

  func testNotebookQueryReportsItsLibrary() async throws {
    let executor = try makeExecutor()

    let response = await executor.execute(GraphQLDocumentRequest(
      query: "{ notebooks(limit: 10) { value { title libraryId } } }"
    ))

    let payload = try graphQLPayload(response.body, field: "notebooks")
    guard case let .array(values)? = payload["value"] else {
      return XCTFail("expected notebooks.value array")
    }
    let libraryIds: [String: LibraryID] = values.reduce(into: [:]) { result, value in
      guard case let .object(object) = value,
            case let .string(title)? = object["title"],
            case let .string(libraryId)? = object["libraryId"] else {
        return
      }
      result[title] = LibraryID(libraryId)
    }
    XCTAssertEqual(libraryIds["Public"], NoteStoreSchema.defaultLibraryId)
    XCTAssertNotNil(libraryIds["Private"])
    XCTAssertNotEqual(libraryIds["Private"], NoteStoreSchema.defaultLibraryId)
  }

  private func makeExecutor(function: String = #function) throws -> NoteGraphQLDocumentExecutor {
    let noteService = try makeNoteService(function: function)
    let shared = try noteService.createLibrary(name: "shared", authRequired: true)
    _ = try noteService.scoped(toLibrary: shared.libraryId).createNotebook(title: "Private")
    _ = try noteService.createNotebook(title: "Public")
    return NoteGraphQLDocumentExecutor(service: GraphQLNoteGraphQLService(service: noteService))
  }

  private func libraryNames(
    from executor: NoteGraphQLDocumentExecutor,
    unauthenticated: Bool
  ) async throws -> [String] {
    let response = await executor.execute(GraphQLDocumentRequest(
      query: "{ libraries { value { name } } }",
      authenticatedClientId: unauthenticated ? nil : APIClientID("client-1"),
      actingUserId: NoteStoreSchema.defaultUserId,
      isUnauthenticatedRequest: unauthenticated
    ))
    return try names(in: response)
  }

  private func notebookTitles(
    from executor: NoteGraphQLDocumentExecutor,
    unauthenticated: Bool
  ) async throws -> [String] {
    let response = await executor.execute(GraphQLDocumentRequest(
      query: "{ notebooks(limit: 10) { value { title } } }",
      authenticatedClientId: unauthenticated ? nil : APIClientID("client-1"),
      actingUserId: NoteStoreSchema.defaultUserId,
      isUnauthenticatedRequest: unauthenticated
    ))
    let payload = try graphQLPayload(response.body, field: "notebooks")
    guard case let .array(values)? = payload["value"] else {
      XCTFail("expected notebooks.value array")
      return []
    }
    return values.compactMap { value in
      guard case let .object(object) = value, case let .string(title)? = object["title"] else {
        return nil
      }
      return title
    }
  }

  private func names(in response: GraphQLDocumentExecutionResponse) throws -> [String] {
    let payload = try graphQLPayload(response.body, field: "libraries")
    guard case let .array(values)? = payload["value"] else {
      XCTFail("expected libraries.value array")
      return []
    }
    return values.compactMap { value in
      guard case let .object(object) = value, case let .string(name)? = object["name"] else {
        return nil
      }
      return name
    }.sorted()
  }

  private func makeNoteService(function: String) throws -> NoteService {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/NoteGraphQLLibraryTests", isDirectory: true)
      .appendingPathComponent(function.replacingOccurrences(of: "()", with: ""), isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
  }

  private func graphQLPayload(_ body: JSONObject, field: String) throws -> JSONObject {
    guard case let .object(data)? = body["data"], case let .object(object)? = data[field] else {
      XCTFail("expected \(field) object")
      return [:]
    }
    return object
  }
}
