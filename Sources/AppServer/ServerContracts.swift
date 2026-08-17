import Foundation

import AppGraphQL
import AppCore

public struct ServerRequestEnvelope: Equatable, Sendable {
  public var method: String
  public var path: String
  public var headers: [String: String]
  public var body: Data?
  /// Raw request-target query string, without the leading `?`.
  public var query: String?

  public init(
    method: String,
    path: String,
    headers: [String: String] = [:],
    body: Data? = nil,
    query: String? = nil
  ) {
    self.method = method
    self.path = path
    self.headers = headers
    self.body = body
    self.query = query
  }

  public var queryParameters: [String: String] {
    guard let query, !query.isEmpty else {
      return [:]
    }
    var parameters: [String: String] = [:]
    for pair in query.split(separator: "&", omittingEmptySubsequences: true) {
      let pieces = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard let name = String(pieces[0]).removingPercentEncoding, !name.isEmpty else {
        continue
      }
      let rawValue = pieces.count == 2 ? String(pieces[1]).replacingOccurrences(of: "+", with: " ") : ""
      parameters[name] = rawValue.removingPercentEncoding ?? rawValue
    }
    return parameters
  }
}

public struct ServerResponseDescriptor: Equatable, Sendable {
  public var status: Int
  public var contentType: String
  public var body: JSONObject

  public init(status: Int, contentType: String = "application/json", body: JSONObject) {
    self.status = status
    self.contentType = contentType
    self.body = body
  }
}

public struct ServerRequestContext: Equatable, Sendable {
  public var serviceName: String
  public var bearerToken: String?
  public var managerSessionId: String?
  public var inheritedEnvironment: [String: String]

  public init(
    serviceName: String = "kaiba",
    bearerToken: String? = nil,
    managerSessionId: String? = nil,
    inheritedEnvironment: [String: String] = [:]
  ) {
    self.serviceName = serviceName
    self.bearerToken = bearerToken
    self.managerSessionId = managerSessionId
    self.inheritedEnvironment = inheritedEnvironment
  }

  public var sanitizedEnvironment: [String: String] {
    let strippedKeys: Set<String> = [
      "KAIBA_MANAGER_SESSION_ID",
      "KAIBA_WORKFLOW_ID",
      "KAIBA_WORKFLOW_EXECUTION_ID"
    ]
    return inheritedEnvironment.filter { key, _ in
      !key.hasPrefix("KAIBA_MANAGER_") && !strippedKeys.contains(key)
    }
  }
}

public struct GraphQLServerEnvelope: Equatable, Sendable {
  public var query: String
  public var variables: JSONObject
  public var operationName: String?

  public init(query: String, variables: JSONObject = [:], operationName: String? = nil) {
    self.query = query
    self.variables = variables
    self.operationName = operationName
  }
}

public protocol ServerRouteHandling: Sendable {
  func route(_ request: ServerRequestEnvelope, context: ServerRequestContext) async -> ServerResponseDescriptor
}

public struct DeterministicServerRouteHandler: ServerRouteHandling {
  public var graphQLExecutor: (any GraphQLDocumentExecuting)?
  public var noteAPIAuthenticator: (any NoteAPIAuthenticating)?
  public var allowUnauthenticatedNoteAPI: Bool
  public var noteChangeFeed: NoteChangeFeed?
  public var agentReplyStreamHub: AgentReplyStreamHub?

  public init(
    graphQLExecutor: (any GraphQLDocumentExecuting)? = nil,
    noteAPIAuthenticator: (any NoteAPIAuthenticating)? = nil,
    allowUnauthenticatedNoteAPI: Bool = false,
    noteChangeFeed: NoteChangeFeed? = nil,
    agentReplyStreamHub: AgentReplyStreamHub? = nil
  ) {
    self.graphQLExecutor = graphQLExecutor
    self.noteAPIAuthenticator = noteAPIAuthenticator
    self.allowUnauthenticatedNoteAPI = allowUnauthenticatedNoteAPI
    self.noteChangeFeed = noteChangeFeed
    self.agentReplyStreamHub = agentReplyStreamHub
  }

  public func route(_ request: ServerRequestEnvelope, context: ServerRequestContext) async -> ServerResponseDescriptor {
    let normalizedMethod = request.method.uppercased()
    let contextWithHeaders = context.withHeaders(from: request.headers)
    let response: ServerResponseDescriptor
    switch (normalizedMethod, request.path) {
    case ("GET", "/"), ("GET", "/overview"):
      response = .init(status: 200, body: [
        "service": .string(context.serviceName),
        "route": .string(request.path),
        "readOnly": .bool(true)
      ])
    case ("GET", "/healthz"):
      response = .init(status: 200, body: [
        "service": .string(context.serviceName),
        "status": .string("ok")
      ])
    case ("POST", "/graphql"):
      response = await routeGraphQL(request, context: contextWithHeaders)
    case ("GET", "/note/register"):
      response = await routeNoteRegistrationChallenge(request, context: contextWithHeaders)
    case ("POST", "/note/register"):
      response = await routeNoteRegistration(request, context: contextWithHeaders)
    case ("GET", "/note/events"):
      response = await routeNoteEvents(request, context: contextWithHeaders)
    case ("GET", "/note/agent-stream"):
      response = await routeAgentReplyStream(request, context: contextWithHeaders)
    case (_, "/"), (_, "/overview"), (_, "/healthz"), (_, "/graphql"), (_, "/note/register"),
      (_, "/note/events"), (_, "/note/agent-stream"):
      response = .init(status: 405, body: [
        "error": .string("unsupported method"),
        "method": .string(normalizedMethod),
        "path": .string(request.path)
      ])
    default:
      response = .init(status: 404, body: [
        "error": .string("unknown path"),
        "path": .string(request.path)
      ])
    }
    return response
  }

  public func parseGraphQLEnvelope(_ request: ServerRequestEnvelope) -> GraphQLEnvelopeParseResult {
    guard let body = request.body, !body.isEmpty else {
      return .failure("graphql request body is required")
    }
    guard let value = try? JSONDecoder().decode(JSONValue.self, from: body), case let .object(object) = value else {
      return .failure("graphql request body must be a JSON object")
    }
    guard case let .string(rawQuery)? = object["query"] else {
      return .failure("graphql request body must include a non-empty query string")
    }
    let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else {
      return .failure("graphql request body must include a non-empty query string")
    }
    guard query.utf8.count <= NoteGraphQLDocumentLimits.maximumDocumentUTF8Bytes else {
      return .failure("graphql query exceeds the maximum supported size")
    }
    let variables: JSONObject
    if let rawVariables = object["variables"] {
      if case .null = rawVariables {
        variables = [:]
      } else if case let .object(variableObject) = rawVariables {
        variables = variableObject
      } else {
        return .failure("graphql variables must be an object when present")
      }
    } else {
      variables = [:]
    }
    let operationName: String?
    if let rawOperationName = object["operationName"] {
      switch rawOperationName {
      case .null:
        operationName = nil
      case let .string(value):
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        operationName = trimmed.isEmpty ? nil : trimmed
      default:
        return .failure("graphql operationName must be a string when present")
      }
    } else {
      operationName = nil
    }
    if let operationName, !noteGraphQLNamedOperationNames(in: query).contains(operationName) {
      return .failure("graphql operationName '\(operationName)' was not found in query")
    }
    return .success(.init(query: query, variables: variables, operationName: operationName))
  }

  private func routeGraphQL(_ request: ServerRequestEnvelope, context: ServerRequestContext) async -> ServerResponseDescriptor {
    switch parseGraphQLEnvelope(request) {
    case let .failure(message):
      return .init(status: 400, body: [
        "error": .string(message),
        "graphql": .object([
          "errors": .array([.object(["message": .string(message)])])
        ])
      ])
    case let .success(envelope):
      var authenticatedNoteAPIClient: NoteAPIAuthenticatedClient?
      if graphQLExecutor != nil, noteGraphQLRequiresAuthentication(
        in: envelope.query,
        operationName: envelope.operationName
      ) {
        if let noteAPIAuthenticator {
          switch await noteAPIAuthenticator.authenticate(request: request, context: context) {
          case let .accepted(client):
            authenticatedNoteAPIClient = client
          case let .rejected(response):
            return response
          }
        } else if !allowUnauthenticatedNoteAPI {
          return noteAPIUnavailableResponse("note API authentication is not configured")
        }
      }
      if let graphQLExecutor {
        let executed = await graphQLExecutor.execute(GraphQLDocumentRequest(
          query: envelope.query,
          variables: envelope.variables,
          operationName: envelope.operationName,
          environment: context.sanitizedEnvironment,
          authenticatedClientId: authenticatedNoteAPIClient?.clientId,
          // Every note-API request acts as an account. Without a credential
          // that is the default user, which is what an unauthenticated host
          // has always effectively been (`design-docs/specs/multi-user.md`).
          actingUserId: authenticatedNoteAPIClient?.userId ?? NoteStoreSchema.defaultUserId,
          transportCredential: context.bearerToken.map(GraphQLTransportCredential.init),
          // Only the transport knows the request arrived without a credential:
          // it acts as the default user either way, so libraries that require
          // authentication have to be excluded from this marker, not from the
          // account (`design-docs/specs/library.md`).
          isUnauthenticatedRequest: authenticatedNoteAPIClient == nil
        ))
        if executed.handled {
          return .init(status: executed.status, body: executed.body)
        }
        return graphQLExecutionErrorResponse(message: "unsupported GraphQL operation")
      }
      return .init(status: 200, body: [
        "graphql": .object([
          "delegated": .bool(true),
          "query": .string(envelope.query),
          "variables": .object(envelope.variables),
          "operationName": envelope.operationName.map(JSONValue.string) ?? .null,
          "schema": .string(GraphQLContractProjector.schemaContract)
        ]),
        "context": .object([
          "bearerTokenPresent": .bool(context.bearerToken != nil),
          "managerSessionId": context.managerSessionId.map(JSONValue.string) ?? .null,
          "sanitizedEnvironmentKeys": .array(context.sanitizedEnvironment.keys.sorted().map(JSONValue.string))
        ])
      ])
    }
  }

  private func graphQLExecutionErrorResponse(message: String) -> ServerResponseDescriptor {
    .init(status: 400, body: [
      "error": .string(message),
      "graphql": .object([
        "errors": .array([.object(["message": .string(message)])])
      ])
    ])
  }

  private func routeNoteRegistration(
    _ request: ServerRequestEnvelope,
    context: ServerRequestContext
  ) async -> ServerResponseDescriptor {
    guard let registrar = noteAPIAuthenticator as? NoteAPIClientRegistering else {
      return .init(status: 404, body: [
        "error": .string("note API registration is not enabled")
      ])
    }
    return await registrar.redeemRegistrationCode(request: request, context: context)
  }

  private func routeNoteRegistrationChallenge(
    _ request: ServerRequestEnvelope,
    context: ServerRequestContext
  ) async -> ServerResponseDescriptor {
    guard let registrar = noteAPIAuthenticator as? NoteAPIClientRegistering else {
      return .init(status: 404, body: [
        "error": .string("note API registration is not enabled")
      ])
    }
    return await registrar.createRegistrationChallenge(request: request, context: context)
  }

  /// Long-poll change feed for live note views. Suspends until the store's
  /// revision passes `since` or the (capped) timeout lapses, then answers with
  /// the current revision and the events the caller has not seen.
  private func routeNoteEvents(
    _ request: ServerRequestEnvelope,
    context: ServerRequestContext
  ) async -> ServerResponseDescriptor {
    guard let noteChangeFeed else {
      return .init(status: 404, body: [
        "error": .string("note events are not enabled")
      ])
    }
    if let noteAPIAuthenticator {
      switch await noteAPIAuthenticator.authenticate(request: request, context: context) {
      case .accepted:
        break
      case let .rejected(response):
        return response
      }
    } else if !allowUnauthenticatedNoteAPI {
      return noteAPIUnavailableResponse("note API authentication is not configured")
    }
    let parameters = request.queryParameters
    let since = parameters["since"].flatMap(UInt64.init) ?? 0
    let timeoutMilliseconds = min(
      parameters["timeoutMs"].flatMap(UInt64.init) ?? NoteEventPollLimits.defaultTimeoutMilliseconds,
      NoteEventPollLimits.maximumTimeoutMilliseconds
    )
    let polled = await noteChangeFeed.poll(
      since: since,
      timeoutNanoseconds: timeoutMilliseconds * 1_000_000
    )
    return .init(status: 200, body: [
      "revision": .integer(Int64(polled.revision)),
      "events": .array(polled.events.map(noteChangeEventJSON))
    ])
  }

  /// Long-poll chunk feed for a generating chat reply. `turn` names the turn
  /// note; `cursor` is the number of chunks the caller has already seen. The
  /// response carries the chunks past the cursor, the new cursor, and whether
  /// the reply finished (with its final status).
  private func routeAgentReplyStream(
    _ request: ServerRequestEnvelope,
    context: ServerRequestContext
  ) async -> ServerResponseDescriptor {
    guard let agentReplyStreamHub else {
      return .init(status: 404, body: [
        "error": .string("agent reply streaming is not enabled")
      ])
    }
    if let noteAPIAuthenticator {
      switch await noteAPIAuthenticator.authenticate(request: request, context: context) {
      case .accepted:
        break
      case let .rejected(response):
        return response
      }
    } else if !allowUnauthenticatedNoteAPI {
      return noteAPIUnavailableResponse("note API authentication is not configured")
    }
    let parameters = request.queryParameters
    guard let turnNoteId = parameters["turn"].flatMap({ NoteID(validating: $0) }) else {
      return .init(status: 400, body: [
        "error": .string("turn query parameter is required")
      ])
    }
    let cursor = parameters["cursor"].flatMap(Int.init) ?? 0
    let timeoutMilliseconds = min(
      parameters["timeoutMs"].flatMap(UInt64.init) ?? NoteEventPollLimits.defaultTimeoutMilliseconds,
      NoteEventPollLimits.maximumTimeoutMilliseconds
    )
    let polled = await agentReplyStreamHub.poll(
      turnNoteId: turnNoteId,
      cursor: cursor,
      timeoutNanoseconds: timeoutMilliseconds * 1_000_000
    )
    var body: JSONObject = [
      "cursor": .integer(Int64(polled.cursor)),
      "chunks": .array(polled.chunks.map(JSONValue.string)),
      "done": .bool(polled.done)
    ]
    body["status"] = polled.status.map(JSONValue.string) ?? .null
    body["message"] = polled.message.map(JSONValue.string) ?? .null
    return .init(status: 200, body: body)
  }
}

public enum NoteEventPollLimits {
  public static let defaultTimeoutMilliseconds: UInt64 = 25_000
  public static let maximumTimeoutMilliseconds: UInt64 = 30_000
}

private func noteChangeEventJSON(_ event: NoteChangeEvent) -> JSONValue {
  .object([
    "kind": .string(event.kind),
    "notebookId": event.notebookId.map { JSONValue.string($0.rawValue) } ?? .null,
    "tagNames": .array(event.tagNames.map(JSONValue.string))
  ])
}

public enum GraphQLEnvelopeParseResult: Equatable, Sendable {
  case success(GraphQLServerEnvelope)
  case failure(String)
}

extension ServerRequestContext {
  func withHeaders(from headers: [String: String]) -> ServerRequestContext {
    var copy = self
    var lowercased: [String: String] = [:]
    for key in headers.keys.sorted() {
      lowercased[key.lowercased()] = headers[key]
    }
    if let authorization = lowercased["authorization"], authorization.lowercased().hasPrefix("bearer ") {
      copy.bearerToken = String(authorization.dropFirst("Bearer ".count))
    }
    if let managerSessionId = lowercased["x-kaiba-manager-session-id"] {
      copy.managerSessionId = managerSessionId
    }
    return copy
  }
}
