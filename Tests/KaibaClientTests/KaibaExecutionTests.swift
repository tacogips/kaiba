import Foundation
import Testing
@testable import KaibaClient

private actor ExecutionTransport: KaibaHTTPTransporting {
  enum Result: Sendable {
    case response(KaibaHTTPResponse)
    case failure(KaibaClientError)
  }

  let result: Result
  private(set) var requests: [KaibaHTTPRequest] = []

  init(_ result: Result) {
    self.result = result
  }

  func send(_ request: KaibaHTTPRequest, maximumResponseBytes: Int) async throws -> KaibaHTTPResponse {
    requests.append(request)
    switch result {
    case let .response(response): return response
    case let .failure(error): throw error
    }
  }
}

private struct NonEquatablePayload: Decodable, Sendable {
  let value: String
}

private actor CancellationTransport: KaibaHTTPTransporting {
  enum Mode: Sendable, CaseIterable {
    case cancellationError
    case cancelledURL
  }

  let mode: Mode
  private(set) var started = false

  init(mode: Mode) {
    self.mode = mode
  }

  func send(_ request: KaibaHTTPRequest, maximumResponseBytes: Int) async throws -> KaibaHTTPResponse {
    started = true
    do {
      try await Task.sleep(for: .seconds(30))
      return KaibaHTTPResponse(statusCode: 200, body: Data(#"{"data":{"ok":true}}"#.utf8))
    } catch {
      switch mode {
      case .cancellationError: throw error
      case .cancelledURL: throw URLError(.cancelled)
      }
    }
  }
}

@Suite("Kaiba execution and readiness")
struct KaibaExecutionTests {
  @Test func callerCancellationPropagatesAcrossTransportErrorForms() async throws {
    for mode in CancellationTransport.Mode.allCases {
      let transport = CancellationTransport(mode: mode)
      let client = try KaibaClient(
        endpoint: URL(string: "http://localhost")!,
        authentication: .unauthenticated,
        transport: transport
      )
      let task = Task {
        try await client.execute(KaibaGraphQLRequest(document: "query { ok }"))
      }
      while !(await transport.started) {
        await Task.yield()
      }
      task.cancel()

      do {
        _ = try await task.value
        Issue.record("expected caller cancellation for \(mode)")
      } catch is CancellationError {
        // Expected: cancellation is not converted to a retryable connection failure.
      } catch {
        Issue.record("unexpected cancellation error for \(mode): \(error)")
      }
    }
  }

  @Test func readinessCancellationPropagatesAcrossTransportErrorForms() async throws {
    for mode in CancellationTransport.Mode.allCases {
      let transport = CancellationTransport(mode: mode)
      let client = try KaibaClient(
        endpoint: URL(string: "http://localhost")!,
        authentication: .unauthenticated,
        transport: transport
      )
      let task = Task {
        try await client.probeReadiness()
      }
      while !(await transport.started) {
        await Task.yield()
      }
      task.cancel()

      do {
        _ = try await task.value
        Issue.record("expected readiness cancellation for \(mode)")
      } catch is CancellationError {
        // Expected: readiness preserves structured cancellation.
      } catch {
        Issue.record("unexpected readiness cancellation error for \(mode): \(error)")
      }
    }
  }

  @Test func genericExecuteAcceptsDecodableSendableValues() async throws {
    let transport = ExecutionTransport(.response(KaibaHTTPResponse(
      statusCode: 200,
      body: Data(#"{"data":{"value":"ok"}}"#.utf8)
    )))
    let client = try KaibaClient(
      endpoint: URL(string: "http://localhost")!,
      authentication: .unauthenticated,
      transport: transport
    )
    let response = try await client.execute(
      KaibaGraphQLRequest(document: "query Named { value }", operationName: "Named"),
      as: NonEquatablePayload.self
    )
    #expect(response.data.value == "ok")
  }

  @Test(arguments: [
    (401, "auth_failed"),
    (403, "auth_failed"),
    (302, "http_failed"),
    (500, "http_failed")
  ])
  func classifiesHTTPFailures(example: (Int, String)) async throws {
    let transport = ExecutionTransport(.response(KaibaHTTPResponse(
      statusCode: example.0,
      body: Data()
    )))
    let client = try KaibaClient(
      endpoint: URL(string: "http://localhost")!,
      authentication: .unauthenticated,
      transport: transport
    )
    do {
      _ = try await client.execute(KaibaGraphQLRequest(document: "query { ok }"))
      Issue.record("expected HTTP failure")
    } catch let error as KaibaClientError {
      #expect(error.code == example.1)
    }
  }

  @Test func readinessUsesOneBoundedStructuralProbe() async throws {
    let transport = ExecutionTransport(.response(KaibaHTTPResponse(
      statusCode: 200,
      body: Data(#"{"data":{"kaibaReadiness":{"result":{"accepted":true,"status":"ok"}}}}"#.utf8)
    )))
    let client = try KaibaClient(
      endpoint: URL(string: "http://localhost")!,
      authentication: .unauthenticated,
      transport: transport
    )
    let readiness = try await client.probeReadiness()
    #expect(readiness.status == .ready)
    #expect(await transport.requests.count == 1)
    #expect(await transport.requests.first?.body.count ?? 0 < 2_048)
  }

  @Test func readinessRedactsTheActiveTokenFromEndpointDiagnostics() async throws {
    let examples = [
      (token: "sentinel-readiness?/token", encodedPath: "sentinel-readiness%3F%2ftoken"),
      (token: "sentinel-unreserved-token", encodedPath: "%73entinel-unreserved-token")
    ]
    for example in examples {
      let transport = ExecutionTransport(.response(KaibaHTTPResponse(
        statusCode: 200,
        body: Data(#"{"data":{"kaibaReadiness":{"result":{"accepted":true,"status":"ok"}}}}"#.utf8)
      )))
      let client = try KaibaClient(
        endpoint: try #require(URL(string: "https://example.com/\(example.encodedPath)")),
        authentication: .bearer(try KaibaBearerToken(example.token)),
        transport: transport
      )

      let readiness = try await client.probeReadiness()
      #expect(readiness.endpoint == "https://example.com/<redacted>")
      #expect(!readiness.endpoint.contains(example.token))
      #expect(!readiness.endpoint.contains(example.encodedPath))
    }
  }

  @Test func readinessKeepsCustomPathsOpaqueIndependentlyOfAuthentication() async throws {
    let endpoint = try #require(URL(string: "https://example.com/path-api-secret"))
    let authentications: [KaibaAuthentication] = [
      .bearer(try KaibaBearerToken("different-header-secret")),
      .unauthenticated
    ]
    for authentication in authentications {
      let transport = ExecutionTransport(.response(KaibaHTTPResponse(
        statusCode: 200,
        body: Data(#"{"data":{"kaibaReadiness":{"result":{"accepted":true,"status":"ok"}}}}"#.utf8)
      )))
      let client = try KaibaClient(
        endpoint: endpoint,
        authentication: authentication,
        configuration: try KaibaClientConfiguration(allowRemoteUnauthenticated: true),
        transport: transport
      )

      let readiness = try await client.probeReadiness()
      #expect(readiness.endpoint == "https://example.com/<redacted>")
      #expect(!readiness.endpoint.contains("path-api-secret"))
    }
  }

  @Test func requestLimitFailsBeforeTransport() async throws {
    let transport = ExecutionTransport(.response(KaibaHTTPResponse(statusCode: 200, body: Data())))
    let configuration = try KaibaClientConfiguration(maximumRequestBytes: 10)
    let client = try KaibaClient(
      endpoint: URL(string: "http://localhost")!,
      authentication: .unauthenticated,
      configuration: configuration,
      transport: transport
    )
    await #expect(throws: KaibaClientError.self) {
      try await client.execute(KaibaGraphQLRequest(document: "query { tooLarge }"))
    }
    #expect(await transport.requests.isEmpty)
  }

  @Test func exactRequestAndResponseByteLimitsAreInclusive() async throws {
    let body = Data(#"{"data":{"ok":true}}"#.utf8)
    let sizingTransport = ExecutionTransport(.response(KaibaHTTPResponse(statusCode: 200, body: body)))
    let sizingClient = try KaibaClient(
      endpoint: URL(string: "http://localhost")!,
      authentication: .unauthenticated,
      transport: sizingTransport
    )
    let request = KaibaGraphQLRequest(document: "query Sized { ok }")
    _ = try await sizingClient.execute(request)
    let requestBytes = try #require(await sizingTransport.requests.first?.body.count)

    let exactTransport = ExecutionTransport(.response(KaibaHTTPResponse(statusCode: 200, body: body)))
    let exactClient = try KaibaClient(
      endpoint: URL(string: "http://localhost")!,
      authentication: .unauthenticated,
      configuration: try KaibaClientConfiguration(
        maximumRequestBytes: requestBytes,
        maximumResponseBytes: body.count
      ),
      transport: exactTransport
    )
    _ = try await exactClient.execute(request)

    let requestOverTransport = ExecutionTransport(.response(KaibaHTTPResponse(statusCode: 200, body: body)))
    let requestOverClient = try KaibaClient(
      endpoint: URL(string: "http://localhost")!,
      authentication: .unauthenticated,
      configuration: try KaibaClientConfiguration(maximumRequestBytes: requestBytes - 1),
      transport: requestOverTransport
    )
    await #expect(throws: KaibaClientError.self) { try await requestOverClient.execute(request) }
    #expect(await requestOverTransport.requests.isEmpty)

    let responseOverClient = try KaibaClient(
      endpoint: URL(string: "http://localhost")!,
      authentication: .unauthenticated,
      configuration: try KaibaClientConfiguration(maximumResponseBytes: body.count - 1),
      transport: ExecutionTransport(.response(KaibaHTTPResponse(statusCode: 200, body: body)))
    )
    await #expect(throws: KaibaClientError.self) { try await responseOverClient.execute(request) }
  }

  @Test func classifiesTransportEnvelopeGraphQLAndDecodeFailures() async throws {
    let examples: [(ExecutionTransport.Result, String)] = [
      (.failure(.connectionFailed(-1001)), "connection_failed"),
      (.response(KaibaHTTPResponse(statusCode: 200, body: Data("not-json".utf8))), "invalid_response"),
      (.response(KaibaHTTPResponse(statusCode: 200, body: Data(#"{"errors":[{"message":"rejected"}],"data":{"value":"partial"}}"#.utf8))), "graphql_failed"),
      (.response(KaibaHTTPResponse(statusCode: 200, body: Data(#"{"data":null}"#.utf8))), "invalid_response")
    ]
    for (result, expectedCode) in examples {
      let client = try KaibaClient(
        endpoint: URL(string: "http://localhost")!,
        authentication: .unauthenticated,
        transport: ExecutionTransport(result)
      )
      do {
        _ = try await client.execute(KaibaGraphQLRequest(document: "query { value }"))
        Issue.record("expected \(expectedCode)")
      } catch let error as KaibaClientError {
        #expect(error.code == expectedCode)
        if case let .graphqlFailed(_, partialData) = error {
          #expect(partialData?.objectValue?["value"] == .string("partial"))
        }
      }
    }

    let decodeClient = try KaibaClient(
      endpoint: URL(string: "http://localhost")!,
      authentication: .unauthenticated,
      transport: ExecutionTransport(.response(KaibaHTTPResponse(
        statusCode: 200,
        body: Data(#"{"data":{"value":7}}"#.utf8)
      )))
    )
    await #expect(throws: KaibaClientError.self) {
      try await decodeClient.execute(
        KaibaGraphQLRequest(document: "query { value }"),
        as: NonEquatablePayload.self
      )
    }
  }

  @Test func readinessClassifiesEveryStableOutcome() async throws {
    let examples: [(ExecutionTransport.Result, KaibaReadinessStatus)] = [
      (.response(KaibaHTTPResponse(statusCode: 200, body: Data(#"{"data":{"kaibaReadiness":{"result":{"accepted":false,"status":"forbidden"}}}}"#.utf8))), .serverRejected),
      (.response(KaibaHTTPResponse(statusCode: 200, body: Data(#"{"data":{"kaibaReadiness":{}}}"#.utf8))), .incompatibleResponse),
      (.response(KaibaHTTPResponse(statusCode: 401, body: Data())), .authFailed),
      (.failure(.connectionFailed(-1003)), .connectionFailed)
    ]
    for (result, expectedStatus) in examples {
      let client = try KaibaClient(
        endpoint: URL(string: "http://localhost")!,
        authentication: .unauthenticated,
        transport: ExecutionTransport(result)
      )
      #expect(try await client.probeReadiness().status == expectedStatus)
    }
  }

  @Test func outgoingRequestIsCanonicalAndOmitsUnauthenticatedHeader() async throws {
    let transport = ExecutionTransport(.response(KaibaHTTPResponse(
      statusCode: 200,
      body: Data(#"{"data":{"value":"ok"}}"#.utf8)
    )))
    let client = try KaibaClient(
      endpoint: URL(string: "http://localhost/custom")!,
      authentication: .unauthenticated,
      transport: transport
    )
    _ = try await client.execute(KaibaGraphQLRequest(
      document: "query Named($id: String!) { value(id: $id) }",
      variables: ["id": .string("n-1")],
      operationName: "Named"
    ))
    let sent = try #require(await transport.requests.first)
    #expect(sent.url.absoluteString == "http://localhost/custom")
    #expect(sent.headers["authorization"] == nil)
    #expect(sent.headers["content-type"] == "application/json")
    let object = try JSONSerialization.jsonObject(with: sent.body) as? [String: Any]
    #expect(object?["query"] as? String == "query Named($id: String!) { value(id: $id) }")
    #expect(object?["operationName"] as? String == "Named")
    #expect((object?["variables"] as? [String: String])?["id"] == "n-1")
  }

}
