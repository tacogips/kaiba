import Foundation
import XCTest

import AppCore
@testable import AppServer

private struct AgentTokenAuthenticator: NoteAPIAuthenticating {
  let userId: UserID

  func authenticate(request: ServerRequestEnvelope, context: ServerRequestContext) async -> NoteAPIAuthenticationResult {
    guard context.bearerToken == "credential" else {
      return .rejected(noteAPIUnauthorizedResponse("note API bearer token is invalid or revoked"))
    }
    return .accepted(NoteAPIAuthenticatedClient(clientId: APIClientID("client"), displayName: "Client", userId: userId))
  }
}

private struct AgentTokenIssuer: KaibaAgentTokenIssuing {
  func issueAgentToken(userId: UserID, ttlSeconds: Int) throws -> KaibaAgentTokenIssue {
    KaibaAgentTokenIssue(token: "issued-\(userId.rawValue)-\(ttlSeconds)", expiresAt: 1_900_000_000)
  }
}

private struct FailingAgentTokenIssuer: KaibaAgentTokenIssuing {
  let error: KaibaAgentTokenIssuingError

  func issueAgentToken(userId _: UserID, ttlSeconds _: Int) throws -> KaibaAgentTokenIssue {
    throw error
  }
}

final class AgentTokenRouteTests: XCTestCase {
  func testAuthenticatedCallerReceivesOnlyItsOwnBoundedToken() async {
    let userId = UserID("user-alice")
    let handler = DeterministicServerRouteHandler(
      noteAPIAuthenticator: AgentTokenAuthenticator(userId: userId),
      agentTokenIssuer: AgentTokenIssuer()
    )
    let response = await handler.route(
      request("POST", body: #"{"ttlSeconds":120,"userId":"user-bob"}"#),
      context: .init(serviceName: "test")
    )

    XCTAssertEqual(response.status, 200)
    XCTAssertEqual(response.body["userId"], .string(userId.rawValue))
    XCTAssertEqual(response.body["token"], .string("issued-user-alice-120"))
    XCTAssertEqual(response.body["ttlSeconds"], .integer(120))
    XCTAssertEqual(response.body["expiresAt"], .string("1900000000"))
    XCTAssertEqual(response.headers["Cache-Control"], "no-store")
  }

  func testAgentTokenRouteRejectsUnauthenticatedAndInvalidTTL() async {
    let unavailable = DeterministicServerRouteHandler(allowUnauthenticatedNoteAPI: true, agentTokenIssuer: AgentTokenIssuer())
    let unavailableResponse = await unavailable.route(request("POST"), context: .init(serviceName: "test"))
    XCTAssertEqual(unavailableResponse.status, 503)

    let handler = DeterministicServerRouteHandler(
      noteAPIAuthenticator: AgentTokenAuthenticator(userId: UserID("user-alice")),
      agentTokenIssuer: AgentTokenIssuer()
    )
    let unauthorized = await handler.route(ServerRequestEnvelope(method: "POST", path: "/note/agent-token"), context: .init(serviceName: "test"))
    XCTAssertEqual(unauthorized.status, 401)
    let invalid = await handler.route(request("POST", body: #"{"ttlSeconds":901}"#), context: .init(serviceName: "test"))
    XCTAssertEqual(invalid.status, 400)
    let unwired = await DeterministicServerRouteHandler(noteAPIAuthenticator: AgentTokenAuthenticator(userId: UserID("user-alice"))).route(request("POST"), context: .init(serviceName: "test"))
    XCTAssertEqual(unwired.status, 404)
    let wrongMethod = await handler.route(request("GET"), context: .init(serviceName: "test"))
    XCTAssertEqual(wrongMethod.status, 405)
  }

  func testAgentTokenRouteCoversAuthenticationTTLAndIssuerStatusTable() async {
    let userId = UserID("user-alice")
    let authenticated = DeterministicServerRouteHandler(
      noteAPIAuthenticator: AgentTokenAuthenticator(userId: userId),
      agentTokenIssuer: AgentTokenIssuer()
    )
    let noAuthenticator = DeterministicServerRouteHandler(agentTokenIssuer: AgentTokenIssuer())
    let allowUnauthenticatedWithoutAuthenticator = DeterministicServerRouteHandler(
      allowUnauthenticatedNoteAPI: true,
      agentTokenIssuer: AgentTokenIssuer()
    )

    let noAuthenticatorResponse = await noAuthenticator.route(request("POST"), context: .init(serviceName: "test"))
    let allowUnauthenticatedResponse = await allowUnauthenticatedWithoutAuthenticator.route(request("POST"), context: .init(serviceName: "test"))
    let defaultTTLResponse = await authenticated.route(request("POST", body: "{}"), context: .init(serviceName: "test"))
    let decimalTTLResponse = await authenticated.route(request("POST", body: #"{"ttlSeconds":1.5}"#), context: .init(serviceName: "test"))
    let zeroTTLResponse = await authenticated.route(request("POST", body: #"{"ttlSeconds":0}"#), context: .init(serviceName: "test"))
    let negativeTTLResponse = await authenticated.route(request("POST", body: #"{"ttlSeconds":-1}"#), context: .init(serviceName: "test"))
    XCTAssertEqual(noAuthenticatorResponse.status, 503)
    XCTAssertEqual(allowUnauthenticatedResponse.status, 503)
    XCTAssertEqual(defaultTTLResponse.body["ttlSeconds"], .integer(300))
    XCTAssertEqual(decimalTTLResponse.status, 400)
    XCTAssertEqual(zeroTTLResponse.status, 400)
    XCTAssertEqual(negativeTTLResponse.status, 400)

    let disabled = DeterministicServerRouteHandler(
      noteAPIAuthenticator: AgentTokenAuthenticator(userId: userId),
      agentTokenIssuer: FailingAgentTokenIssuer(error: .accountUnavailable)
    )
    let disabledResponse = await disabled.route(request("POST"), context: .init(serviceName: "test"))
    XCTAssertEqual(disabledResponse.status, 401)

    let operationalFailure = DeterministicServerRouteHandler(
      noteAPIAuthenticator: AgentTokenAuthenticator(userId: userId),
      agentTokenIssuer: FailingAgentTokenIssuer(error: .operationFailed)
    )
    let operationalFailureResponse = await operationalFailure.route(request("POST"), context: .init(serviceName: "test"))
    XCTAssertEqual(operationalFailureResponse.status, 500)
  }

  func testAgentTokenRouteRequiresJSONAndHTTPAdapterPreservesNoStore() async {
    let handler = DeterministicServerRouteHandler(
      noteAPIAuthenticator: AgentTokenAuthenticator(userId: UserID("user-alice")),
      agentTokenIssuer: AgentTokenIssuer()
    )

    let missingContentType = await handler.route(
      request("POST", contentType: nil),
      context: .init(serviceName: "test")
    )
    let textContentType = await handler.route(
      request("POST", contentType: "text/plain"),
      context: .init(serviceName: "test")
    )
    let parameterizedJSON = await handler.route(
      request("POST", contentType: "application/json; charset=utf-8"),
      context: .init(serviceName: "test")
    )
    XCTAssertEqual(missingContentType.status, 415)
    XCTAssertEqual(textContentType.status, 415)
    XCTAssertEqual(parameterizedJSON.status, 200)

    let adapter = DeterministicServerHTTPAdapter(
      routeHandler: handler,
      context: .init(serviceName: "test", bearerToken: "credential")
    )
    let response = await adapter.response(for: KaibaHTTPRequest(
      method: "POST",
      path: "/note/agent-token",
      headers: ["Content-Type": "application/json"]
    ))
    XCTAssertEqual(response.status, 200)
    XCTAssertEqual(response.headers["Cache-Control"], "no-store")
  }

  func testAgentTokenRouteRejectsEmptyContentType() async {
    let handler = DeterministicServerRouteHandler(
      noteAPIAuthenticator: AgentTokenAuthenticator(userId: UserID("user-alice")),
      agentTokenIssuer: AgentTokenIssuer()
    )

    let response = await handler.route(
      request("POST", contentType: ""),
      context: .init(serviceName: "test")
    )

    XCTAssertEqual(response.status, 415)
  }

  private func request(
    _ method: String,
    body: String? = nil,
    contentType: String? = "application/json"
  ) -> ServerRequestEnvelope {
    var headers = ["Authorization": "Bearer credential"]
    if let contentType {
      headers["Content-Type"] = contentType
    }
    return ServerRequestEnvelope(
      method: method,
      path: "/note/agent-token",
      headers: headers,
      body: body.map { Data($0.utf8) }
    )
  }
}
