import Foundation
import Testing
@testable import KaibaClient

private actor RecordingTransport: KaibaHTTPTransporting {
  var requests: [KaibaHTTPRequest] = []
  let response: KaibaHTTPResponse

  init(response: KaibaHTTPResponse) {
    self.response = response
  }

  func send(_ request: KaibaHTTPRequest, maximumResponseBytes: Int) async throws -> KaibaHTTPResponse {
    requests.append(request)
    return response
  }
}

private struct CredentialPathPayload: Decodable, Sendable {
  let values: [String: Int]
}

@Suite("KaibaClient")
struct KaibaClientTests {
  @Test func normalizesEndpointAndSendsBearer() async throws {
    let transport = RecordingTransport(response: KaibaHTTPResponse(
      statusCode: 200,
      body: Data(#"{"data":{"ok":true}}"#.utf8)
    ))
    let client = try KaibaClient(
      endpoint: URL(string: "http://LOCALHOST:80/")!,
      authentication: .bearer(try KaibaBearerToken("sentinel-token")),
      transport: transport
    )
    let response = try await client.execute(KaibaGraphQLRequest(document: "query { ok }"))
    #expect(client.endpoint.description == "http://localhost/graphql")
    #expect(response.data == .object(["ok": .bool(true)]))
    let request = await transport.requests.first
    #expect(request?.headers["authorization"] == "Bearer sentinel-token")
  }

  @Test func enforcesRemotePoliciesAndTokenRedaction() throws {
    #expect(throws: KaibaClientError.self) {
      try KaibaClient(
        endpoint: URL(string: "http://example.com")!,
        authentication: .unauthenticated
      )
    }
    let token = try KaibaBearerToken("sentinel-token")
    #expect(token.description == "<redacted>")
    #expect(String(reflecting: token) == "<redacted>")
    var dumpedToken = ""
    dump(token, to: &dumpedToken)
    #expect(!dumpedToken.contains("sentinel-token"))
    #expect(Mirror(reflecting: token).children.allSatisfy {
      !String(reflecting: $0.value).contains("sentinel-token")
    })
    let authentication = KaibaAuthentication.bearer(token)
    #expect(!String(describing: authentication).contains("sentinel-token"))
    #expect(!String(reflecting: authentication).contains("sentinel-token"))
    let errors: [KaibaClientError] = [
      .connectionFailed(-1),
      .authFailed(401),
      .httpFailed(500),
      .invalidResponse(status: 200, byteCount: 10),
      .graphqlFailed([KaibaGraphQLError(message: "server rejected request")], partialData: nil),
      .decodingFailed("data.root"),
      .schemaUnavailable("schema invalid")
    ]
    #expect(errors.allSatisfy { !$0.description.contains("sentinel-token") })
  }

  @Test func transportValuesUseOpaqueDiagnostics() throws {
    let requestSecrets = [
      "private-endpoint-path",
      "sentinel-transport-token",
      "private-header-value",
      "private-request-body"
    ]
    let request = KaibaHTTPRequest(
      url: try #require(URL(string: "https://example.com/private-endpoint-path")),
      headers: [
        "authorization": "Bearer sentinel-transport-token",
        "x-safe-name": "private-header-value"
      ],
      body: Data("private-request-body".utf8),
      timeout: 10
    )
    var requestDump = ""
    dump(request, to: &requestDump)
    let requestOutputs = [
      request.description,
      request.debugDescription,
      String(reflecting: request),
      requestDump
    ] + Mirror(reflecting: request).children.map { String(reflecting: $0.value) }

    for output in requestOutputs {
      for secret in requestSecrets {
        #expect(!output.contains(secret))
      }
    }
    #expect(request.description.contains("https://example.com/<redacted>"))
    #expect(request.description.contains("authorization"))
    #expect(request.description.contains("bodyByteCount: 20"))

    let response = KaibaHTTPResponse(
      statusCode: 200,
      body: Data("private-response-body".utf8)
    )
    var responseDump = ""
    dump(response, to: &responseDump)
    let responseOutputs = [
      response.description,
      response.debugDescription,
      String(reflecting: response),
      responseDump
    ] + Mirror(reflecting: response).children.map { String(reflecting: $0.value) }
    #expect(responseOutputs.allSatisfy { !$0.contains("private-response-body") })
    #expect(response.description == "KaibaHTTPResponse(statusCode: 200, bodyByteCount: 21)")
  }

  @Test func parsesFiltersAndRendersDeterministically() throws {
    let schema = try KaibaGraphQLSchema.parseSDL("""
    scalar JSON
    type Query { note(id: ID!): Note! notes: [Note!]! }
    type Note { id: ID! metadata: JSON }
    """)
    let selected = try schema.selecting(matching: "Query.note$")
    #expect(selected.queryFields.map(\.name) == ["note"])
    #expect(selected.types.map(\.name).contains("Note"))
    #expect(KaibaSchemaRenderer.text(selected).contains("type Query"))
    #expect(try KaibaSchemaRenderer.json(selected).contains(#""filter" : "Query.note$""#))
  }

  @Test func sanitizesGraphQLErrorsWithoutRetainingCredentialsOrBodies() async throws {
    let response = #"""
    {
      "errors": [{
        "message": "sentinel-token {\"proxy_authorization\": \"Bearer other-secret\\\" remaining-message-secret\"}; \"überAuthorizationHeader\" = [Bearer unicode-message-secret\\] remaining-unicode-message-secret]; https://sentinel-user:sentinel-password@example.com/private\nbody",
        "locations": [{"line": 7, "column": 11}, {"line": 0, "column": 3}],
        "path": ["{'proxyAuthorizationHeader': [Bearer path-secret\\] remaining-path-secret]}", "認証AuthorizationHeader = \"Bearer unicode-path-secret\\\" remaining-unicode-path-secret\""],
        "extensions": {
          "code": "\\\"redirect_http_authorization_header\\\":(Bearer extension-secret\\) remaining-extension-secret)",
          "secret": "hidden"
        }
      }],
      "data": {"private": "sentinel-token"}
    }
    """#
    let transport = RecordingTransport(response: KaibaHTTPResponse(
      statusCode: 200,
      body: Data(response.utf8)
    ))
    let client = try KaibaClient(
      endpoint: URL(string: "http://localhost")!,
      authentication: .bearer(try KaibaBearerToken("sentinel-token")),
      transport: transport
    )
    do {
      _ = try await client.execute(KaibaGraphQLRequest(document: "query { private }"))
      Issue.record("expected GraphQL failure")
    } catch let error as KaibaClientError {
      guard case let .graphqlFailed(errors, partialData) = error else {
        Issue.record("expected graphql_failed")
        return
      }
      let rendered = String(describing: errors)
      #expect(!rendered.contains("sentinel-token"))
      #expect(!rendered.contains("other-secret"))
      #expect(!rendered.contains("remaining-message-secret"))
      #expect(!rendered.contains("unicode-message-secret"))
      #expect(!rendered.contains("remaining-unicode-message-secret"))
      #expect(!rendered.contains("path-secret"))
      #expect(!rendered.contains("remaining-path-secret"))
      #expect(!rendered.contains("unicode-path-secret"))
      #expect(!rendered.contains("remaining-unicode-path-secret"))
      #expect(!rendered.contains("extension-secret"))
      #expect(!rendered.contains("remaining-extension-secret"))
      #expect(!rendered.contains("sentinel-user"))
      #expect(!rendered.contains("sentinel-password"))
      #expect(rendered.contains("https://<redacted>@example.com/private"))
      #expect(!rendered.contains("hidden"))
      #expect(errors.first?.extensions == ["code": .string("<redacted>")])
      #expect(errors.first?.locations == [KaibaGraphQLErrorLocation(line: 7, column: 11)])
      #expect(partialData?.objectValue?["private"] == .string("sentinel-token"))
      #expect(!error.description.contains("sentinel-token"))
      assertCredentialAbsent("sentinel-token", from: error, associatedValue: errors)
    }
  }

  @Test func sanitizesCredentialBearingGraphQLAndTypedDecodingPaths() async throws {
    let tokenValue = "sentinel-path-token"
    let token = try KaibaBearerToken(tokenValue)
    let graphqlResponse = #"{"errors":[{"message":"rejected","path":["Authorization: Bearer sentinel-path-token",2]}]}"#
    let graphqlClient = try KaibaClient(
      endpoint: URL(string: "http://localhost")!,
      authentication: .bearer(token),
      transport: RecordingTransport(response: KaibaHTTPResponse(
        statusCode: 200,
        body: Data(graphqlResponse.utf8)
      ))
    )
    do {
      _ = try await graphqlClient.execute(KaibaGraphQLRequest(document: "query { private }"))
      Issue.record("expected GraphQL failure")
    } catch let error as KaibaClientError {
      guard case let .graphqlFailed(errors, _) = error else {
        Issue.record("expected graphql_failed")
        return
      }
      #expect(errors.first?.path == [.string("<redacted>"), .integer(2)])
      assertCredentialAbsent(tokenValue, from: error, associatedValue: errors)
    }

    let decodingResponse = #"{"data":{"values":{"Authorization: Bearer sentinel-path-token":"wrong-type"}}}"#
    let decodingClient = try KaibaClient(
      endpoint: URL(string: "http://localhost")!,
      authentication: .bearer(token),
      transport: RecordingTransport(response: KaibaHTTPResponse(
        statusCode: 200,
        body: Data(decodingResponse.utf8)
      ))
    )
    do {
      _ = try await decodingClient.execute(
        KaibaGraphQLRequest(document: "query { values }"),
        as: CredentialPathPayload.self
      )
      Issue.record("expected decoding failure")
    } catch let error as KaibaClientError {
      guard case let .decodingFailed(path) = error else {
        Issue.record("expected decoding_failed")
        return
      }
      #expect(path == "values.<redacted>")
      assertCredentialAbsent(tokenValue, from: error, associatedValue: path)
    }
  }

  @Test func rejectsNonGraphQLPathComponentsAsInvalidResponse() async throws {
    let malformedComponents = [
      #"{"nested":["sentinel-path-token"]}"#,
      #"["sentinel-path-token"]"#,
      "true",
      "null",
      "1.5"
    ]
    for component in malformedComponents {
      let response = "{\"errors\":[{\"message\":\"rejected\",\"path\":[\(component)]}]}"
      let transport = RecordingTransport(response: KaibaHTTPResponse(
        statusCode: 200,
        body: Data(response.utf8)
      ))
      let client = try KaibaClient(
        endpoint: URL(string: "http://localhost")!,
        authentication: .bearer(try KaibaBearerToken("sentinel-path-token")),
        transport: transport
      )
      do {
        _ = try await client.execute(KaibaGraphQLRequest(document: "query { private }"))
        Issue.record("expected invalid response for path component \(component)")
      } catch let error as KaibaClientError {
        #expect(error.code == "invalid_response")
        assertCredentialAbsent("sentinel-path-token", from: error, associatedValue: error)
      }
    }
  }

  @Test func operationStatusesUseCanonicalServerSpellings() throws {
    let decoder = JSONDecoder()
    let encoder = JSONEncoder()
    #expect(try decoder.decode(KaibaOperationStatus.self, from: Data(#""not_found""#.utf8)) == .notFound)
    #expect(try decoder.decode(KaibaOperationStatus.self, from: Data(#""invalid_request""#.utf8)) == .invalidRequest)
    #expect(String(data: try encoder.encode(KaibaOperationStatus.notFound), encoding: .utf8) == #""not_found""#)
    #expect(String(data: try encoder.encode(KaibaOperationStatus.invalidRequest), encoding: .utf8) == #""invalid_request""#)
  }

  @Test func requestEncodingFailuresMapToInvalidRequestWithoutTransport() async throws {
    for value in [Double.nan, Double.infinity, -Double.infinity] {
      let arbitraryTransport = RecordingTransport(response: KaibaHTTPResponse(
        statusCode: 200,
        body: Data(#"{"data":{"ok":true}}"#.utf8)
      ))
      let arbitraryClient = try KaibaClient(
        endpoint: URL(string: "http://localhost")!,
        authentication: .unauthenticated,
        transport: arbitraryTransport
      )
      do {
        _ = try await arbitraryClient.execute(KaibaGraphQLRequest(
          document: "query NonFinite($value: Float!) { echo(value: $value) }",
          variables: ["value": .double(value)]
        ))
        Issue.record("expected arbitrary request encoding failure")
      } catch let error as KaibaClientError {
        #expect(error.code == "invalid_request")
      }
      #expect(await arbitraryTransport.requests.isEmpty)

      let recallTransport = RecordingTransport(response: KaibaHTTPResponse(
        statusCode: 200,
        body: Data(#"{"data":{"root":{}}}"#.utf8)
      ))
      let recallClient = try KaibaClient(
        endpoint: URL(string: "http://localhost")!,
        authentication: .unauthenticated,
        transport: recallTransport
      )
      do {
        _ = try await recallClient.recallLongTermMemory(query: "memory", recencyWeight: value)
        Issue.record("expected typed recall encoding failure")
      } catch let error as KaibaClientError {
        #expect(error.code == "invalid_request")
      }
      #expect(await recallTransport.requests.isEmpty)
    }
  }
}

private func assertCredentialAbsent(
  _ credential: String,
  from error: KaibaClientError,
  associatedValue: some Any
) {
  var dumpedError = ""
  dump(error, to: &dumpedError)
  var dumpedAssociatedValue = ""
  dump(associatedValue, to: &dumpedAssociatedValue)
  let mirroredErrorChildren = Mirror(reflecting: error).children.map {
    String(reflecting: $0.value)
  }
  let renderedValues = [
    error.description,
    String(describing: error),
    String(reflecting: error),
    dumpedError,
    String(describing: associatedValue),
    String(reflecting: associatedValue),
    dumpedAssociatedValue
  ] + mirroredErrorChildren
  #expect(renderedValues.allSatisfy { !$0.contains(credential) })
}
