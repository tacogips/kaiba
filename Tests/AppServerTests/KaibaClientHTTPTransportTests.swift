import Foundation
import KaibaClient
import XCTest
@testable import AppServer

private actor TransportRequestRecorder {
  private(set) var requests: [AppServer.KaibaHTTPRequest] = []

  func record(_ request: AppServer.KaibaHTTPRequest) {
    requests.append(request)
  }
}

private actor TimedOutRouteRecorder {
  private var entered = false
  private var cancelled = false
  private var entryWaiters: [CheckedContinuation<Void, Never>] = []
  private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

  func holdRequest() async -> AppServer.KaibaHTTPResponse {
    entered = true
    let entryWaiters = entryWaiters
    self.entryWaiters.removeAll()
    entryWaiters.forEach { $0.resume() }
    do {
      try await Task.sleep(for: .seconds(60))
      return AppServer.KaibaHTTPResponse(status: 200, body: Data(#"{"data":{"ok":true}}"#.utf8))
    } catch {
      cancelled = true
      let cancellationWaiters = cancellationWaiters
      self.cancellationWaiters.removeAll()
      cancellationWaiters.forEach { $0.resume() }
      return AppServer.KaibaHTTPResponse(status: 499, body: Data())
    }
  }

  func waitUntilEntered() async {
    guard !entered else { return }
    await withCheckedContinuation { entryWaiters.append($0) }
  }

  func waitUntilCancelled() async {
    guard !cancelled else { return }
    await withCheckedContinuation { cancellationWaiters.append($0) }
  }
}

final class KaibaClientHTTPTransportTests: XCTestCase {
  func testClientTimeoutCancelsTheConnectionOwnedServerRouteTask() async throws {
    let recorder = TimedOutRouteRecorder()
    let handler = AnyKaibaHTTPRouteHandler { _ in
      await recorder.holdRequest()
    }
    let server = KaibaLocalHTTPServer(routeHandler: handler)
    let port = try await server.startForTesting()
    defer { Task { await server.stop() } }
    let client = try KaibaClient(
      endpoint: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)")),
      authentication: .unauthenticated,
      configuration: try KaibaClientConfiguration(requestTimeout: 0.05)
    )

    let request = Task { () -> Error? in
      do {
        _ = try await client.execute(KaibaGraphQLRequest(document: "query { ok }"))
        return nil
      } catch {
        return error
      }
    }
    await recorder.waitUntilEntered()
    let error = await request.value
    guard let clientError = error as? KaibaClientError else {
      return XCTFail("expected a client timeout error, got \(String(describing: error))")
    }
    XCTAssertEqual(clientError.code, "connection_failed")
    await recorder.waitUntilCancelled()
    try await waitUntilRouteTaskCount(server, equals: 0)
    await server.stop()
  }

  func testURLSessionTransportRefusesRedirectWithoutForwardingBearer() async throws {
    let recorder = TransportRequestRecorder()
    let handler = AnyKaibaHTTPRouteHandler { request in
      await recorder.record(request)
      if request.path == "/graphql" {
        return AppServer.KaibaHTTPResponse(
          status: 302,
          headers: ["Location": "http://127.0.0.1:1/redirected"],
          body: Data("sentinel-redirect-body".utf8)
        )
      }
      return AppServer.KaibaHTTPResponse(status: 200, body: Data(#"{"data":{"ok":true}}"#.utf8))
    }
    let server = KaibaLocalHTTPServer(routeHandler: handler)
    let port = try await server.startForTesting()
    defer { Task { await server.stop() } }
    let client = try KaibaClient(
      endpoint: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)")),
      authentication: .bearer(try KaibaBearerToken("sentinel-redirect-token"))
    )

    do {
      _ = try await client.execute(KaibaGraphQLRequest(document: "query { ok }"))
      XCTFail("redirect must fail")
    } catch let error as KaibaClientError {
      XCTAssertEqual(error.code, "http_failed")
      XCTAssertFalse(error.description.contains("sentinel-redirect-token"))
      XCTAssertFalse(error.description.contains("sentinel-redirect-body"))
    }
    let requests = await recorder.requests
    XCTAssertEqual(requests.map(\.path), ["/graphql"])
    XCTAssertEqual(requests.first?.headers["authorization"], "Bearer sentinel-redirect-token")
    await server.stop()
  }

  func testURLSessionTransportCancelsAResponseBeyondTheConfiguredBound() async throws {
    let handler = AnyKaibaHTTPRouteHandler { _ in
      AppServer.KaibaHTTPResponse(
        status: 200,
        headers: ["Content-Type": "application/json"],
        body: Data(repeating: 0x61, count: 256 * 1_024)
      )
    }
    let server = KaibaLocalHTTPServer(routeHandler: handler)
    let port = try await server.startForTesting()
    defer { Task { await server.stop() } }
    let client = try KaibaClient(
      endpoint: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)")),
      authentication: .unauthenticated,
      configuration: try KaibaClientConfiguration(maximumResponseBytes: 1_024)
    )

    do {
      _ = try await client.execute(KaibaGraphQLRequest(document: "query { ok }"))
      XCTFail("oversized response must fail")
    } catch let error as KaibaClientError {
      XCTAssertEqual(error.code, "invalid_response")
    }
    await server.stop()
  }

  private func waitUntilRouteTaskCount(
    _ server: KaibaLocalHTTPServer,
    equals expectedCount: Int,
    timeout: Duration = .seconds(2)
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while server.activeRouteTaskCountForTesting != expectedCount {
      guard clock.now < deadline else {
        XCTFail("server route-task count did not reach \(expectedCount); current \(server.activeRouteTaskCountForTesting)")
        return
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}
