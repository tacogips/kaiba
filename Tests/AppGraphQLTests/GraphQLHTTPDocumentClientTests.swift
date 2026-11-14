import Foundation
import AppCore
import Testing

@testable import AppGraphQL

/// Records the outgoing request and replays a canned response, so client
/// behavior is testable without a network.
private final class RecordingTransport: GraphQLHTTPTransporting, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [GraphQLHTTPRequest] = []
  private let result: Result<GraphQLHTTPResponse, Error>

  init(result: Result<GraphQLHTTPResponse, Error>) {
    self.result = result
  }

  func send(_ request: GraphQLHTTPRequest) async throws -> GraphQLHTTPResponse {
    record(request)
    return try result.get()
  }

  private func record(_ request: GraphQLHTTPRequest) {
    lock.lock()
    defer { lock.unlock() }
    recorded.append(request)
  }

  var requests: [GraphQLHTTPRequest] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }
}

private struct TransportFailure: Error {}

private func decodedObject(_ data: Data) throws -> JSONObject? {
  guard case let .object(object) = try JSONDecoder().decode(JSONValue.self, from: data) else {
    return nil
  }
  return object
}

private func makeClient(
  result: Result<GraphQLHTTPResponse, Error>,
  bearerToken: String? = nil
) throws -> (GraphQLHTTPDocumentClient, RecordingTransport) {
  let transport = RecordingTransport(result: result)
  let endpoint = try #require(URL(string: "http://127.0.0.1:8420/graphql"))
  return (
    GraphQLHTTPDocumentClient(endpoint: endpoint, bearerToken: bearerToken, transport: transport),
    transport
  )
}

@Test func httpClientPostsDocumentWithBearerTokenAndVariables() async throws {
  let responseBody = Data(#"{"data":{"tags":{"value":[]}}}"#.utf8)
  let (client, transport) = try makeClient(
    result: .success(GraphQLHTTPResponse(statusCode: 200, body: responseBody)),
    bearerToken: "secret-token"
  )

  let response = await client.execute(GraphQLDocumentRequest(
    query: "query Tags($limit: Int) { tags { value { name } } }",
    variables: ["limit": .integer(5)],
    operationName: "Tags"
  ))

  #expect(response.handled)
  #expect(response.status == 200)
  #expect(response.body["data"] == .object(["tags": .object(["value": .array([])])]))

  let request = try #require(transport.requests.first)
  #expect(request.url.absoluteString == "http://127.0.0.1:8420/graphql")
  #expect(request.headers["authorization"] == "Bearer secret-token")
  #expect(request.headers["content-type"] == "application/json")
  let payload = try #require(try decodedObject(request.body))
  #expect(payload["query"] == .string("query Tags($limit: Int) { tags { value { name } } }"))
  #expect(payload["variables"] == .object(["limit": .integer(5)]))
  #expect(payload["operationName"] == .string("Tags"))
}

@Test func httpClientOmitsAuthorizationAndEmptyVariables() async throws {
  let (client, transport) = try makeClient(
    result: .success(GraphQLHTTPResponse(statusCode: 200, body: Data("{}".utf8)))
  )

  _ = await client.execute(GraphQLDocumentRequest(query: "{ tags { value { name } } }"))

  let request = try #require(transport.requests.first)
  #expect(request.headers["authorization"] == nil)
  let payload = try #require(try decodedObject(request.body))
  #expect(payload["variables"] == nil)
  #expect(payload["operationName"] == nil)
}

@Test func httpClientPassesThroughRemoteErrorStatus() async throws {
  let body = Data(#"{"errors":[{"message":"unauthorized"}]}"#.utf8)
  let (client, _) = try makeClient(
    result: .success(GraphQLHTTPResponse(statusCode: 401, body: body))
  )

  let response = await client.execute(GraphQLDocumentRequest(query: "{ tags { value { name } } }"))

  #expect(response.handled)
  #expect(response.status == 401)
  #expect(response.body["errors"] != nil)
}

@Test func httpClientMapsNonJSONResponseToGatewayError() async throws {
  let (client, _) = try makeClient(
    result: .success(GraphQLHTTPResponse(statusCode: 200, body: Data("not-json".utf8)))
  )

  let response = await client.execute(GraphQLDocumentRequest(query: "{ tags { value { name } } }"))

  #expect(response.handled)
  #expect(response.status == 502)
  #expect(response.body["errors"] != nil)
}

@Test func httpClientMapsTransportFailureToGatewayError() async throws {
  let (client, _) = try makeClient(result: .failure(TransportFailure()))

  let response = await client.execute(GraphQLDocumentRequest(query: "{ tags { value { name } } }"))

  #expect(response.handled)
  #expect(response.status == 502)
  #expect(response.body["errors"] != nil)
}

@Test func endpointURLAppendsGraphQLRouteOnlyForBareServerURLs() throws {
  let bare = try #require(URL(string: "http://127.0.0.1:8420"))
  #expect(
    GraphQLHTTPDocumentClient.endpointURL(from: bare).absoluteString
      == "http://127.0.0.1:8420/graphql"
  )
  let slash = try #require(URL(string: "http://127.0.0.1:8420/"))
  #expect(
    GraphQLHTTPDocumentClient.endpointURL(from: slash).absoluteString
      == "http://127.0.0.1:8420/graphql"
  )
  let custom = try #require(URL(string: "http://127.0.0.1:8420/api/graphql"))
  #expect(GraphQLHTTPDocumentClient.endpointURL(from: custom) == custom)
}
