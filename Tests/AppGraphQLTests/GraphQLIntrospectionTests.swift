import Foundation
import AppCore
import KaibaClient
import XCTest
@testable import AppGraphQL

final class GraphQLIntrospectionTests: XCTestCase {
  func testAuthoritativeSchemaParsesAndCanonicalIntrospectionExecutes() async throws {
    let schema = try KaibaGraphQLSchema.parseSDL(GraphQLContractProjector.schemaContract)
    XCTAssertTrue(schema.queryFields.contains { $0.name == "notes" })
    XCTAssertTrue(schema.queryFields.contains { $0.name == "noteLinks" })
    XCTAssertTrue(schema.mutationFields.contains { $0.name == "attachNotebookFile" })
    XCTAssertEqual(Set(schema.queryFields.map(\.name)), noteGraphQLQueryFields)
    XCTAssertEqual(Set(schema.mutationFields.map(\.name)), noteGraphQLMutationFields)
    XCTAssertLessThanOrEqual(
      KaibaSchemaIntrospectionV1.document.utf8.count,
      NoteGraphQLDocumentLimits.maximumDocumentUTF8Bytes
    )
    XCTAssertEqual(
      KaibaSchemaIntrospectionV1.document.components(separatedBy: "ofType").count - 1,
      8
    )

    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/graphql-introspection-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
    let executor = NoteGraphQLDocumentExecutor(service: GraphQLNoteGraphQLService(service: service))
    let response = await executor.execute(GraphQLDocumentRequest(
      query: KaibaSchemaIntrospectionV1.document,
      operationName: "KaibaSchemaIntrospectionV1"
    ))
    XCTAssertTrue(response.handled)
    XCTAssertNil(response.body["errors"])
    guard case let .object(data)? = response.body["data"],
          case let .object(introspection)? = data["__schema"],
          case let .array(types)? = introspection["types"] else {
      return XCTFail("expected standard __schema response")
    }
    XCTAssertGreaterThan(types.count, 20)
  }

  func testIntrospectionRequiresAuthenticationClassification() {
    XCTAssertTrue(noteGraphQLRequiresAuthentication(
      in: "query Schema { __schema { queryType { name } } }"
    ))
    XCTAssertTrue(noteGraphQLRequiresAuthentication(
      in: "query Type { __type(name: \"Note\") { name } }"
    ))
    XCTAssertFalse(noteGraphQLRequiresAuthentication(
      in: "query Other { unsupported(value: \"__schema\") } # __type"
    ))
    XCTAssertFalse(noteGraphQLRequiresAuthentication(
      in: "query Schema { __schema { queryType { name } } } query Other { unsupported }",
      operationName: "Other"
    ))
  }

  func testIntrospectionProjectsOnlySelectedFieldsAndSupportsTypeVariables() async throws {
    let executor = try makeExecutor()
    let schemaResponse = await executor.execute(GraphQLDocumentRequest(
      query: "query { schema: __schema { queryType { rootName: name } } }"
    ))
    XCTAssertNil(schemaResponse.body["errors"])
    guard case let .object(data)? = schemaResponse.body["data"],
          case let .object(schema)? = data["schema"],
          case let .object(queryType)? = schema["queryType"] else {
      return XCTFail("expected projected schema response")
    }
    XCTAssertEqual(Set(schema.keys), ["queryType"])
    XCTAssertEqual(queryType, ["rootName": .string("Query")])

    let typeResponse = await executor.execute(GraphQLDocumentRequest(
      query: "query Type($name: String!) { __type(name: $name) { kind name } }",
      variables: ["name": .string("Note")],
      operationName: "Type"
    ))
    XCTAssertNil(typeResponse.body["errors"])
    guard case let .object(typeData)? = typeResponse.body["data"],
          case let .object(type)? = typeData["__type"] else {
      return XCTFail("expected __type response")
    }
    XCTAssertEqual(type["name"], .string("Note"))
    XCTAssertEqual(type["kind"], .string("OBJECT"))
  }

  func testIntrospectionRejectsUnknownMalformedAndMixedSelections() async throws {
    let executor = try makeExecutor()
    let documents = [
      "query { __schema { definitelyUnknown } }",
      "query { __schema { queryType } }",
      "query { __schema(argument: true) { queryType { name } } }",
      "mutation { __schema { queryType { name } } }",
      "query { __schema { queryType { name } } notes { result { accepted } } }",
      "query { __type(name: \"Note\", extra: true) { name } }",
      "query { __type(name: \"Missing\") { definitelyUnknown } }"
    ]
    for document in documents {
      let response = await executor.execute(GraphQLDocumentRequest(query: document))
      XCTAssertNotNil(response.body["errors"], document)
    }

    let malformed = await executor.execute(GraphQLDocumentRequest(
      query: "query { __schema { queryType { name }"
    ))
    XCTAssertNotNil(malformed.body["errors"])
  }

  func testCommentsStringsAndUnselectedOperationsDoNotTriggerIntrospection() async throws {
    let request = GraphQLDocumentRequest(
      query: "query Schema { __schema { queryType { name } } } query Other { unsupported(value: \"__type\") } # __schema",
      operationName: "Other"
    )
    XCTAssertNil(graphQLIntrospectionResponse(for: request))
  }

  func testIntrospectionRejectsBreadthAndProjectionAmplification() async throws {
    let executor = try makeExecutor()
    let excessiveSelections = (0...GraphQLIntrospectionLimits.maximumSelectionNodes)
      .map { "alias\($0): name" }
      .joined(separator: " ")
    let selectionResponse = await executor.execute(GraphQLDocumentRequest(
      query: "query { __schema { types { \(excessiveSelections) } } }"
    ))
    XCTAssertEqual(
      introspectionErrorMessage(selectionResponse),
      "introspection query exceeds the selection limit"
    )

    let amplifiedSelections = (0..<400)
      .map { "alias\($0): name" }
      .joined(separator: " ")
    let complexityResponse = await executor.execute(GraphQLDocumentRequest(
      query: "query { __schema { types { \(amplifiedSelections) } } }"
    ))
    XCTAssertEqual(
      introspectionErrorMessage(complexityResponse),
      "introspection query exceeds the complexity limit"
    )
  }

  func testIntrospectionRejectsSerializedResponsesOverTheByteBudget() throws {
    XCTAssertThrowsError(try validateIntrospectionResponseSize(
      ["data": .string(String(repeating: "x", count: 128))],
      maximumBytes: 64
    ))
  }

  private func makeExecutor(function: String = #function) throws -> NoteGraphQLDocumentExecutor {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/graphql-introspection-\(function)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
    return NoteGraphQLDocumentExecutor(service: GraphQLNoteGraphQLService(service: service))
  }

  private func introspectionErrorMessage(
    _ response: GraphQLDocumentExecutionResponse
  ) -> String? {
    guard case let .array(errors)? = response.body["errors"],
          case let .object(error)? = errors.first else {
      return nil
    }
    return error["message"]?.asString
  }
}
