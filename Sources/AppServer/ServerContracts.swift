import Foundation

import AppGraphQL
import AppCore

public actor NoteLongPollAdmission {
  public static let maximumWaitersPerPrincipal = 16
  public static let maximumWaiters = 256
  private var principals: [UUID: String] = [:]

  public init() {}

  public func acquire(principalId: String) -> UUID? {
    guard principals.count < Self.maximumWaiters,
      principals.values.filter({ $0 == principalId }).count < Self.maximumWaitersPerPrincipal
    else { return nil }
    let token = UUID()
    principals[token] = principalId
    return token
  }

  public func release(_ token: UUID) {
    principals.removeValue(forKey: token)
  }
}

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
  public var headers: [String: String]
  public var body: JSONObject

  public init(
    status: Int,
    contentType: String = "application/json",
    headers: [String: String] = [:],
    body: JSONObject
  ) {
    self.status = status
    self.contentType = contentType
    self.headers = headers
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
  /// `serve --allow-unauthenticated --as-admin`: a request that presented no
  /// credential acts as the seeded admin account and reaches every library.
  /// Off by default, because an open port would otherwise hand out the
  /// libraries an operator marked `auth_required`
  /// (`design-docs/specs/library.md`).
  public var unauthenticatedActsAsAdmin: Bool
  /// The store reader used by non-GraphQL routes that expose note metadata or
  /// content. It is scoped per authenticated request before every read.
  public var noteService: NoteService?
  public var noteChangeFeed: NoteChangeFeed?
  public var agentReplyStreamHub: AgentReplyStreamHub?
  public var longPollAdmission: NoteLongPollAdmission
  public var agentTokenIssuer: (any KaibaAgentTokenIssuing)?

  public static let defaultAgentTokenTTLSeconds = 300
  public static let maximumAgentTokenTTLSeconds = 900

  public init(
    graphQLExecutor: (any GraphQLDocumentExecuting)? = nil,
    noteAPIAuthenticator: (any NoteAPIAuthenticating)? = nil,
    allowUnauthenticatedNoteAPI: Bool = false,
    unauthenticatedActsAsAdmin: Bool = false,
    noteService: NoteService? = nil,
    noteChangeFeed: NoteChangeFeed? = nil,
    agentReplyStreamHub: AgentReplyStreamHub? = nil,
    longPollAdmission: NoteLongPollAdmission = NoteLongPollAdmission(),
    agentTokenIssuer: (any KaibaAgentTokenIssuing)? = nil
  ) {
    self.graphQLExecutor = graphQLExecutor
    self.noteAPIAuthenticator = noteAPIAuthenticator
    self.allowUnauthenticatedNoteAPI = allowUnauthenticatedNoteAPI
    self.unauthenticatedActsAsAdmin = unauthenticatedActsAsAdmin
    self.noteService = noteService
    self.noteChangeFeed = noteChangeFeed
    self.agentReplyStreamHub = agentReplyStreamHub
    self.longPollAdmission = longPollAdmission
    self.agentTokenIssuer = agentTokenIssuer
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
    case ("POST", "/note/agent-token"):
      response = await routeAgentToken(request, context: contextWithHeaders)
    case (_, "/"), (_, "/overview"), (_, "/healthz"), (_, "/graphql"), (_, "/note/register"),
      (_, "/note/events"), (_, "/note/agent-stream"), (_, "/note/agent-token"):
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
          // account (`design-docs/specs/library.md`). `--as-admin` is the
          // operator saying this port is theirs: the marker is dropped, so a
          // credential-less request reaches what the admin account reaches.
          isUnauthenticatedRequest: authenticatedNoteAPIClient == nil && !unauthenticatedActsAsAdmin
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

  /// Long-poll change feed for live note views. Suspends until an owner-visible
  /// event arrives or the (capped) timeout lapses, then returns an opaque
  /// successor cursor. Reusing the request cursor replays its prepared batch;
  /// using the successor acknowledges it and advances the event stream.
  private func routeNoteEvents(
    _ request: ServerRequestEnvelope,
    context: ServerRequestContext
  ) async -> ServerResponseDescriptor {
    guard let noteChangeFeed else {
      return .init(status: 404, body: [
        "error": .string("note events are not enabled")
      ])
    }
    let authenticatedClient: NoteAPIAuthenticatedClient?
    if let noteAPIAuthenticator {
      switch await noteAPIAuthenticator.authenticate(request: request, context: context) {
      case let .accepted(client):
        authenticatedClient = client
      case let .rejected(response):
        return response
      }
    } else if !allowUnauthenticatedNoteAPI {
      return noteAPIUnavailableResponse("note API authentication is not configured")
    } else {
      authenticatedClient = nil
    }
    guard let reader = scopedNoteAPIService(for: authenticatedClient) else {
      return noteAPIUnavailableResponse("note API ownership scope is not configured")
    }
    let parameters = request.queryParameters
    let since = parameters["since"]
    let timeoutMilliseconds = min(
      parameters["timeoutMs"].flatMap(UInt64.init) ?? NoteEventPollLimits.defaultTimeoutMilliseconds,
      NoteEventPollLimits.maximumTimeoutMilliseconds
    )
    let userId = authenticatedClient?.userId ?? NoteStoreSchema.defaultUserId
    let principalId: String
    if let authenticatedClient {
      principalId = "authenticated:\(authenticatedClient.userId.rawValue):\(authenticatedClient.clientId.rawValue)"
    } else {
      principalId = "unauthenticated:\(userId.rawValue)"
    }
    let eventAuthorizer: @Sendable (NoteChangeEvent) throws -> Bool = { event in
      try noteEventIsVisible(event, reader: reader, ownerUserId: userId)
    }
    let polled: NoteChangeFeedPoll
    do {
      polled = try await noteChangeFeed.poll(
        since: since,
        principalId: principalId,
        timeoutNanoseconds: timeoutMilliseconds * 1_000_000,
        eventAuthorizer: eventAuthorizer
      )
    } catch NoteChangeFeedError.cursorCapacityReached {
      return .init(status: 429, body: ["error": .string("note event cursor capacity reached")])
    } catch NoteChangeFeedError.waiterCapacityReached {
      return .init(status: 429, body: ["error": .string("note event poll capacity reached")])
    } catch {
      logNoteAPIServerError("note event authorization failed", error: error)
      return .init(status: 500, body: ["error": .string("note event authorization failed")])
    }
    if let rejection = await reauthenticateSuspendedNoteAPIRequest(
      request: request,
      context: context,
      expectedClient: authenticatedClient
    ) {
      // The feed retains a prepared response under the request cursor until
      // the client uses its successor cursor, so a rejected post-poll request
      // cannot consume an owner-visible batch.
      return rejection
    }
    let events: [NoteChangeEvent]
    do {
      // A library membership change can occur while post-poll credential
      // reauthentication is suspended. Reapply the current owner/library
      // decision immediately before serializing the retained batch.
      events = try polled.events.filter(eventAuthorizer)
    } catch {
      // The prepared batch remains bound to the request cursor until its
      // successor is used, so an operational authorization error is retryable.
      logNoteAPIServerError("note event authorization failed", error: error)
      return .init(status: 500, body: ["error": .string("note event authorization failed")])
    }
    return .init(status: 200, headers: ["Cache-Control": "private, no-store"], body: [
      "revision": .string(polled.revision),
      "resync": .bool(polled.resync),
      "events": .array(events.map(noteChangeEventJSON))
    ])
  }

  /// Long-poll chunk feed for a generating chat reply. `turn` names the turn
  /// note; `cursor` is an opaque stream-generation resume token. The response
  /// carries the chunks past the cursor, the new cursor, and whether the reply
  /// finished (with its final status).
  private func routeAgentReplyStream(
    _ request: ServerRequestEnvelope,
    context: ServerRequestContext
  ) async -> ServerResponseDescriptor {
    guard let agentReplyStreamHub else {
      return .init(status: 404, body: [
        "error": .string("agent reply streaming is not enabled")
      ])
    }
    let authenticatedClient: NoteAPIAuthenticatedClient?
    if let noteAPIAuthenticator {
      switch await noteAPIAuthenticator.authenticate(request: request, context: context) {
      case let .accepted(client):
        authenticatedClient = client
      case let .rejected(response):
        return response
      }
    } else if !allowUnauthenticatedNoteAPI {
      return noteAPIUnavailableResponse("note API authentication is not configured")
    } else {
      authenticatedClient = nil
    }
    guard let reader = scopedNoteAPIService(for: authenticatedClient) else {
      return noteAPIUnavailableResponse("note API ownership scope is not configured")
    }
    let parameters = request.queryParameters
    guard let turnNoteId = parameters["turn"].flatMap({ NoteID(validating: $0) }) else {
      return .init(status: 400, body: [
        "error": .string("turn query parameter is required")
      ])
    }
    do {
      let turn = try reader.getNote(turnNoteId)
      guard NoteService.chatTurnState(of: turn) != nil else {
        return .init(status: 404, body: ["error": .string("agent chat turn not found")])
      }
    } catch NoteServiceError.notFound {
      return .init(status: 404, body: ["error": .string("agent chat turn not found")])
    } catch {
      logNoteAPIServerError("agent stream authorization failed", error: error)
      return .init(status: 500, body: ["error": .string("agent stream authorization failed")])
    }
    let cursor = parameters["cursor"].flatMap(Int.init) ?? 0
    let timeoutMilliseconds = min(
      parameters["timeoutMs"].flatMap(UInt64.init) ?? NoteEventPollLimits.defaultTimeoutMilliseconds,
      NoteEventPollLimits.maximumTimeoutMilliseconds
    )
    let principalId = authenticatedClient.map {
      "authenticated:\($0.userId.rawValue):\($0.clientId.rawValue)"
    } ?? "unauthenticated:\(NoteStoreSchema.defaultUserId.rawValue)"
    guard let admissionToken = await longPollAdmission.acquire(principalId: principalId) else {
      return .init(status: 429, body: ["error": .string("agent stream principal poll capacity reached")])
    }
    defer { Task { await longPollAdmission.release(admissionToken) } }
    let polled = await agentReplyStreamHub.poll(
      turnNoteId: turnNoteId,
      cursor: cursor,
      timeoutNanoseconds: timeoutMilliseconds * 1_000_000,
      deferTerminalAcknowledgement: true
    )
    if polled.status == "overloaded" {
      return .init(status: 429, body: ["error": .string("agent stream poll capacity reached")])
    }
    if let rejection = await reauthenticateSuspendedNoteAPIRequest(
      request: request,
      context: context,
      expectedClient: authenticatedClient
    ) {
      await agentReplyStreamHub.acknowledgeTerminalDelivery(
        turnNoteId: turnNoteId,
        poll: polled,
        delivered: false
      )
      return rejection
    }
    do {
      // Authorize inside the terminal-delivery admission operation. It runs
      // after any acknowledgement suspension and has no later route await
      // before this response is constructed, closing the final TOCTOU window.
      let authorized = try await agentReplyStreamHub.authorizeAndAcknowledgeTerminalDelivery(
        turnNoteId: turnNoteId,
        poll: polled
      ) {
        do {
          _ = try reader.getNote(turnNoteId)
          for libraryId in polled.requiredLibraryIds {
            try reader.requireLibraryAccess(libraryId)
          }
          return true
        } catch NoteServiceError.notFound {
          return false
        }
      }
      guard authorized else {
        return .init(status: 404, body: ["error": .string("agent chat turn not found")])
      }
    } catch {
      await agentReplyStreamHub.acknowledgeTerminalDelivery(
        turnNoteId: turnNoteId,
        poll: polled,
        delivered: false
      )
      logNoteAPIServerError("agent stream authorization failed", error: error)
      return .init(status: 500, body: ["error": .string("agent stream authorization failed")])
    }
    var body: JSONObject = [
      "cursor": .integer(Int64(polled.cursor)),
      "chunks": .array(polled.chunks.map(JSONValue.string)),
      "done": .bool(polled.done),
      "resync": .bool(polled.resync)
    ]
    body["status"] = polled.status.map(JSONValue.string) ?? .null
    body["message"] = polled.message.map(JSONValue.string) ?? .null
    return .init(status: 200, headers: ["Cache-Control": "private, no-store"], body: body)
  }

  /// A long poll can outlive its credential. Reauthenticate after it wakes so
  /// revocation or account disablement between request admission and response
  /// delivery cannot release personalized data. The client identity must also
  /// remain stable, preventing an authenticator from silently switching the
  /// response to a different principal.
  private func reauthenticateSuspendedNoteAPIRequest(
    request: ServerRequestEnvelope,
    context: ServerRequestContext,
    expectedClient: NoteAPIAuthenticatedClient?
  ) async -> ServerResponseDescriptor? {
    guard let noteAPIAuthenticator else {
      return allowUnauthenticatedNoteAPI
        ? nil
        : noteAPIUnavailableResponse("note API authentication is not configured")
    }
    guard let expectedClient else {
      return noteAPIUnauthorizedResponse("note API credential changed during long poll")
    }
    switch await noteAPIAuthenticator.authenticate(request: request, context: context) {
    case let .accepted(client):
      guard client.clientId == expectedClient.clientId,
        client.userId == expectedClient.userId else {
        return noteAPIUnauthorizedResponse("note API credential changed during long poll")
      }
      return nil
    case let .rejected(response):
      return response
    }
  }

  private func routeAgentToken(
    _ request: ServerRequestEnvelope,
    context: ServerRequestContext
  ) async -> ServerResponseDescriptor {
    guard let agentTokenIssuer else {
      return .init(status: 404, body: ["error": .string("agent token issuance is not enabled")])
    }
    guard let noteAPIAuthenticator else {
      return noteAPIUnavailableResponse("note API authentication is not configured")
    }
    let client: NoteAPIAuthenticatedClient
    switch await noteAPIAuthenticator.authenticate(request: request, context: context) {
    case let .accepted(authenticatedClient):
      client = authenticatedClient
    case let .rejected(response):
      return response
    }
    guard request.hasJSONContentType else {
      return .init(status: 415, body: [
        "error": .string("agent token requests require Content-Type: application/json")
      ])
    }
    let ttlSeconds: Int
    if let body = request.body, !body.isEmpty {
      guard let value = try? JSONDecoder().decode(JSONValue.self, from: body),
            case let .object(object) = value else {
        return .init(status: 400, body: ["error": .string("agent token request body must be a JSON object")])
      }
      if let requestedTTL = object["ttlSeconds"] {
        guard let value = requestedTTL.asInt,
              value > 0,
              value <= Self.maximumAgentTokenTTLSeconds else {
          return .init(status: 400, body: ["error": .string("ttlSeconds must be a positive integer no greater than \(Self.maximumAgentTokenTTLSeconds)")])
        }
        ttlSeconds = value
      } else {
        ttlSeconds = Self.defaultAgentTokenTTLSeconds
      }
    } else {
      ttlSeconds = Self.defaultAgentTokenTTLSeconds
    }
    do {
      let issue = try agentTokenIssuer.issueAgentToken(userId: client.userId, ttlSeconds: ttlSeconds)
      return .init(status: 200, headers: ["Cache-Control": "no-store"], body: [
        "token": .string(issue.token),
        "userId": .string(client.userId.rawValue),
        "expiresAt": .string(String(issue.expiresAt)),
        "ttlSeconds": .integer(Int64(ttlSeconds))
      ])
    } catch KaibaAgentTokenIssuingError.accountUnavailable {
      return noteAPIUnauthorizedResponse("note API bearer token is invalid or revoked")
    } catch {
      logNoteAPIServerError("agent-token issuance failed", error: error)
      return .init(status: 500, body: ["error": .string("agent token could not be issued")])
    }
  }

  private func scopedNoteAPIService(for client: NoteAPIAuthenticatedClient?) -> NoteService? {
    noteService?
      .scoped(to: client?.userId ?? NoteStoreSchema.defaultUserId)
      .unauthenticated(client == nil && !unauthenticatedActsAsAdmin)
  }
}

private extension ServerRequestEnvelope {
  var hasJSONContentType: Bool {
    guard let value = headers.first(where: {
      $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame
    })?.value else {
      return false
    }
    guard let mediaType = value
      .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
      .first?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !mediaType.isEmpty else {
      return false
    }
    return mediaType.caseInsensitiveCompare("application/json") == .orderedSame
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

private func noteEventIsVisible(
  _ event: NoteChangeEvent,
  reader: NoteService,
  ownerUserId: UserID
) throws -> Bool {
  guard let notebookId = event.notebookId else {
    return false
  }
  do {
    _ = try reader.getNotebook(notebookId)
    return true
  } catch NoteServiceError.notFound {
    // Deleted notebooks have no row to resolve. Their internal snapshots are
    // the only route to an owner-visible deletion refresh.
  }
  guard event.kind == NoteChangeEventKind.notebookDeleted,
        event.ownerUserId == ownerUserId,
        let libraryId = event.libraryId else {
    return false
  }
  return try reader.listLibraries().contains { $0.libraryId == libraryId }
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
