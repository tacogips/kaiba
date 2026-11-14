import Foundation
import Testing
@testable import KaibaClient

private actor EndpointTransport: KaibaHTTPTransporting {
  private(set) var requestCount = 0

  func send(_ request: KaibaHTTPRequest, maximumResponseBytes: Int) async throws -> KaibaHTTPResponse {
    requestCount += 1
    return KaibaHTTPResponse(statusCode: 200, body: Data(#"{"data":{"ok":true}}"#.utf8))
  }
}

@Suite("Kaiba endpoint policy")
struct KaibaEndpointTests {
  struct EndpointExample: Sendable, CustomTestStringConvertible {
    let source: String
    let expected: String
    let loopback: Bool

    var testDescription: String { source }
  }

  @Test(arguments: [
    EndpointExample(source: "http://localhost", expected: "http://localhost/graphql", loopback: true),
    EndpointExample(source: "http://localhost.:80/", expected: "http://localhost./graphql", loopback: true),
    EndpointExample(source: "http://127.42.0.9:80", expected: "http://127.42.0.9/graphql", loopback: true),
    EndpointExample(source: "https://[::1]:443/api/graphql", expected: "https://[::1]/api/graphql", loopback: true),
    EndpointExample(source: "https://EXAMPLE.com:443/custom", expected: "https://example.com/custom", loopback: false)
  ])
  func normalizesEndpoints(example: EndpointExample) throws {
    let endpoint = try KaibaEndpoint(URL(string: example.source)!)
    #expect(endpoint.transportURL.absoluteString == example.expected)
    #expect(endpoint.isLoopback == example.loopback)
  }

  @Test func customPathIsOpaqueInDescriptionsAndReflection() throws {
    let pathCredential = "endpoint-path-secret"
    let endpoint = try KaibaEndpoint(URL(string: "https://example.com/%65ndpoint-path-secret")!)

    #expect(endpoint.description == "https://example.com/<redacted>")
    #expect(!String(describing: endpoint).contains(pathCredential))
    #expect(!String(reflecting: endpoint).contains(pathCredential))
    #expect(Mirror(reflecting: endpoint).children.allSatisfy {
      !String(reflecting: $0.value).contains(pathCredential)
    })
    var dumped = ""
    dump(endpoint, to: &dumped)
    #expect(!dumped.contains(pathCredential))
    #expect(
      endpoint.diagnosticDescription(authentication: .bearer(try KaibaBearerToken("different-header-secret")))
        == "https://example.com/<redacted>"
    )
    #expect(
      endpoint.diagnosticDescription(authentication: .unauthenticated)
        == "https://example.com/<redacted>"
    )
    let canonical = try KaibaEndpoint(URL(string: "https://example.com/graphql")!)
    #expect(
      canonical.diagnosticDescription(authentication: .bearer(try KaibaBearerToken("header-secret")))
        == "https://example.com/graphql"
    )
  }

  @Test(arguments: [
    "ftp://example.com",
    "https://user:secret@example.com",
    "https://example.com/graphql?token=secret",
    "https://example.com/graphql#secret",
    "https://example.com/a/../graphql",
    "https://example.com/a/%2E%2E/graphql",
    "http://localhost:",
    "http://[::1]:",
    "https://example.com:0",
    "https://example.com:65536",
    "https://example.com:999999999999999999999",
    "https://example.com/%00",
    "https://example.com/a%0Ab",
    "http://example.com/graphql"
  ])
  func rejectsUnsafeEndpoints(rawValue: String) {
    do {
      _ = try KaibaEndpoint(URL(string: rawValue)!)
      Issue.record("expected invalid endpoint")
    } catch let error as KaibaClientError {
      #expect(error.code == "invalid_endpoint")
    } catch {
      Issue.record("unexpected error: \(error)")
    }
  }

  @Test(arguments: [
    "http://localhost:",
    "http://[::1]:",
    "https://example.com:0",
    "https://example.com:65536",
    "https://example.com:999999999999999999999",
    "https://example.com/%00",
    "https://example.com/a%0Ab"
  ])
  func rejectsInvalidEndpointBeforeTransport(rawValue: String) async {
    let transport = EndpointTransport()
    do {
      _ = try KaibaClient(
        endpoint: URL(string: rawValue)!,
        authentication: .unauthenticated,
        configuration: try KaibaClientConfiguration(allowRemoteUnauthenticated: true),
        transport: transport
      )
      Issue.record("expected invalid endpoint")
    } catch let error as KaibaClientError {
      #expect(error.code == "invalid_endpoint")
    } catch {
      Issue.record("unexpected error: \(error)")
    }
    #expect(await transport.requestCount == 0)
  }

  @Test func requiresBothRemoteOptInsIndependently() throws {
    let remoteHTTP = URL(string: "http://example.com")!
    #expect(throws: KaibaClientError.self) {
      try KaibaClient(endpoint: remoteHTTP, authentication: .unauthenticated)
    }
    let configuration = try KaibaClientConfiguration(
      transportSecurity: .allowInsecureRemoteHTTP,
      allowRemoteUnauthenticated: true
    )
    let client = try KaibaClient(
      endpoint: remoteHTTP,
      authentication: .unauthenticated,
      configuration: configuration
    )
    #expect(client.endpoint.description == "http://example.com/graphql")
  }

  @Test func bearerRemoteHTTPRequiresOnlyTheTransportOptIn() throws {
    let token = try KaibaBearerToken("endpoint-token")
    #expect(throws: KaibaClientError.self) {
      try KaibaClient(
        endpoint: URL(string: "http://example.com")!,
        authentication: .bearer(token)
      )
    }
    let client = try KaibaClient(
      endpoint: URL(string: "http://example.com")!,
      authentication: .bearer(token),
      configuration: try KaibaClientConfiguration(transportSecurity: .allowInsecureRemoteHTTP)
    )
    #expect(client.endpoint.description == "http://example.com/graphql")
  }

  @Test(arguments: ["", " token", "token ", "token\nvalue", "token\rvalue"])
  func rejectsUnsafeBearerTokens(value: String) {
    #expect(throws: KaibaClientError.self) { try KaibaBearerToken(value) }
  }

  @Test func rejectsInvalidConfigurationBounds() {
    #expect((try? KaibaClientConfiguration(
      requestTimeout: KaibaClientConfiguration.maximumRequestTimeout
    )) != nil)
    #expect(throws: KaibaClientError.self) { try KaibaClientConfiguration(requestTimeout: 0) }
    #expect(throws: KaibaClientError.self) { try KaibaClientConfiguration(requestTimeout: .infinity) }
    #expect(throws: KaibaClientError.self) {
      try KaibaClientConfiguration(
        requestTimeout: KaibaClientConfiguration.maximumRequestTimeout.nextUp
      )
    }
    #expect(throws: KaibaClientError.self) {
      try KaibaClientConfiguration(requestTimeout: Double.greatestFiniteMagnitude)
    }
    #expect(throws: KaibaClientError.self) { try KaibaClientConfiguration(maximumRequestBytes: 0) }
    #expect(throws: KaibaClientError.self) { try KaibaClientConfiguration(maximumResponseBytes: 0) }
  }

  @Test func clientRejectsConfigurationMutatedAfterValidation() throws {
    let validConfiguration = try KaibaClientConfiguration()
    var invalidConfigurations: [KaibaClientConfiguration] = []

    for timeout in [
      0,
      -1,
      .nan,
      .infinity,
      -Double.infinity,
      KaibaClientConfiguration.maximumRequestTimeout.nextUp,
      Double.greatestFiniteMagnitude
    ] {
      var configuration = validConfiguration
      configuration.requestTimeout = timeout
      invalidConfigurations.append(configuration)
    }
    for requestBytes in [0, -1] {
      var configuration = validConfiguration
      configuration.maximumRequestBytes = requestBytes
      invalidConfigurations.append(configuration)
    }
    for responseBytes in [0, -1] {
      var configuration = validConfiguration
      configuration.maximumResponseBytes = responseBytes
      invalidConfigurations.append(configuration)
    }

    for configuration in invalidConfigurations {
      do {
        _ = try KaibaClient(
          endpoint: URL(string: "http://localhost")!,
          authentication: .unauthenticated,
          configuration: configuration
        )
        Issue.record("expected mutated configuration to be rejected")
      } catch let error as KaibaClientError {
        #expect(error.code == "invalid_configuration")
      }
    }
  }
}
