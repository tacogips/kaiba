import Foundation
import AppCore
import AppGraphQL
import KaibaClient
import XCTest
@testable import AppServer

private struct SchemaAuthenticator: NoteAPIAuthenticating {
  func authenticate(
    request: ServerRequestEnvelope,
    context: ServerRequestContext
  ) async -> NoteAPIAuthenticationResult {
    guard context.bearerToken == "schema-token" else {
      return .rejected(noteAPIUnauthorizedResponse("schema authentication failed"))
    }
    return .accepted(NoteAPIAuthenticatedClient(
      clientId: APIClientID("schema-client"),
      displayName: "Schema client",
      userId: NoteStoreSchema.defaultUserId
    ))
  }
}

final class GraphQLSchemaAuthorizationTests: XCTestCase {
  func testSchemaIntrospectionRequiresAndAcceptsBearerAuthentication() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/schema-auth-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
    let router = DeterministicServerRouteHandler(
      graphQLExecutor: NoteGraphQLDocumentExecutor(
        service: GraphQLNoteGraphQLService(service: service)
      ),
      noteAPIAuthenticator: SchemaAuthenticator()
    )
    let request = ServerRequestEnvelope(
      method: "POST",
      path: "/graphql",
      body: try JSONEncoder().encode(JSONValue.object([
        "query": .string(KaibaSchemaIntrospectionV1.document),
        "operationName": .string("KaibaSchemaIntrospectionV1")
      ]))
    )

    let anonymous = await router.route(request, context: ServerRequestContext())
    XCTAssertEqual(anonymous.status, 401)

    let authorized = await router.route(
      request,
      context: ServerRequestContext(bearerToken: "schema-token")
    )
    XCTAssertEqual(authorized.status, 200)
    XCTAssertNotNil(authorized.body["data"])
    XCTAssertNil(authorized.body["errors"])
  }

  func testSchemaIntrospectionMissingAuthenticatorAndExplicitUnauthenticatedPolicy() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/schema-policy-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
    let executor = NoteGraphQLDocumentExecutor(service: GraphQLNoteGraphQLService(service: service))
    let request = ServerRequestEnvelope(
      method: "POST",
      path: "/graphql",
      body: try JSONEncoder().encode(JSONValue.object([
        "query": .string(KaibaSchemaIntrospectionV1.document),
        "operationName": .string("KaibaSchemaIntrospectionV1")
      ]))
    )

    let protected = DeterministicServerRouteHandler(graphQLExecutor: executor)
    let unavailable = await protected.route(request, context: ServerRequestContext())
    XCTAssertEqual(unavailable.status, 503)

    let explicitlyOpen = DeterministicServerRouteHandler(
      graphQLExecutor: executor,
      allowUnauthenticatedNoteAPI: true
    )
    let response = await explicitlyOpen.route(request, context: ServerRequestContext())
    XCTAssertEqual(response.status, 200)
    XCTAssertNotNil(response.body["data"])
  }
}
