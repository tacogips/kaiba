import Foundation
import AppCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct GraphQLHTTPRequest: Equatable, Sendable {
  public var url: URL
  public var headers: [String: String]
  public var body: Data

  public init(url: URL, headers: [String: String], body: Data) {
    self.url = url
    self.headers = headers
    self.body = body
  }
}

public struct GraphQLHTTPResponse: Equatable, Sendable {
  public var statusCode: Int
  public var body: Data

  public init(statusCode: Int, body: Data) {
    self.statusCode = statusCode
    self.body = body
  }
}

public protocol GraphQLHTTPTransporting: Sendable {
  func send(_ request: GraphQLHTTPRequest) async throws -> GraphQLHTTPResponse
}

public struct URLSessionGraphQLHTTPTransport: GraphQLHTTPTransporting {
  public init() {}

  public func send(_ request: GraphQLHTTPRequest) async throws -> GraphQLHTTPResponse {
    var urlRequest = URLRequest(url: request.url)
    urlRequest.httpMethod = "POST"
    urlRequest.httpBody = request.body
    for (name, value) in request.headers {
      urlRequest.setValue(value, forHTTPHeaderField: name)
    }
    let (data, response) = try await URLSession.shared.data(for: urlRequest)
    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
    return GraphQLHTTPResponse(statusCode: statusCode, body: data)
  }
}

/// Executes note GraphQL documents against a remote kaiba server's
/// `POST /graphql` endpoint. It adopts `GraphQLDocumentExecuting` so callers
/// can swap the in-process `NoteGraphQLDocumentExecutor` and remote execution
/// behind the same interface.
public struct GraphQLHTTPDocumentClient: GraphQLDocumentExecuting {
  public var endpoint: URL
  public var bearerToken: String?
  public var transport: any GraphQLHTTPTransporting

  public init(
    endpoint: URL,
    bearerToken: String? = nil,
    transport: any GraphQLHTTPTransporting = URLSessionGraphQLHTTPTransport()
  ) {
    self.endpoint = endpoint
    self.bearerToken = bearerToken
    self.transport = transport
  }

  public func execute(_ request: GraphQLDocumentRequest) async -> GraphQLDocumentExecutionResponse {
    var payload: JSONObject = ["query": .string(request.query)]
    if !request.variables.isEmpty {
      payload["variables"] = .object(request.variables)
    }
    if let operationName = request.operationName {
      payload["operationName"] = .string(operationName)
    }
    var headers = [
      "content-type": "application/json",
      "accept": "application/json"
    ]
    if let bearerToken {
      headers["authorization"] = "Bearer \(bearerToken)"
    }
    do {
      let body = try JSONEncoder().encode(JSONValue.object(payload))
      let response = try await transport.send(
        GraphQLHTTPRequest(url: endpoint, headers: headers, body: body)
      )
      guard
        let value = try? JSONDecoder().decode(JSONValue.self, from: response.body),
        case let .object(object) = value
      else {
        return GraphQLDocumentExecutionResponse(
          handled: true,
          status: 502,
          body: Self.errorsBody(
            "remote graphql response was not a JSON object (HTTP \(response.statusCode))"
          )
        )
      }
      return GraphQLDocumentExecutionResponse(
        handled: true,
        status: response.statusCode,
        body: object
      )
    } catch {
      return GraphQLDocumentExecutionResponse(
        handled: true,
        status: 502,
        body: Self.errorsBody("remote graphql request failed: \(error)")
      )
    }
  }

  /// A bare server URL (empty or "/" path) targets the standard /graphql
  /// route; an explicit path is kept verbatim.
  public static func endpointURL(from url: URL) -> URL {
    let path = url.path
    guard path.isEmpty || path == "/" else {
      return url
    }
    return url.appendingPathComponent("graphql")
  }

  private static func errorsBody(_ message: String) -> JSONObject {
    ["errors": .array([.object(["message": .string(message)])])]
  }
}
