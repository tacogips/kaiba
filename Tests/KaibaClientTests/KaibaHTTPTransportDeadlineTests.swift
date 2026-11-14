import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import KaibaClient

private class TricklingURLProtocol: URLProtocol, @unchecked Sendable {
  private let lock = NSLock()
  private var stopped = false

  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let url = request.url,
          let response = HTTPURLResponse(
      url: url,
      statusCode: 200,
      httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json"]
    ) else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    scheduleChunk(remaining: 300)
  }

  override func stopLoading() {
    lock.lock()
    stopped = true
    lock.unlock()
  }

  private func scheduleChunk(remaining: Int) {
    DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(10)) { [weak self] in
      guard let self, self.isActive else { return }
      self.client?.urlProtocol(self, didLoad: Data([0x20]))
      if remaining > 1 {
        self.scheduleChunk(remaining: remaining - 1)
      } else {
        self.client?.urlProtocolDidFinishLoading(self)
      }
    }
  }

  private var isActive: Bool {
    lock.lock()
    defer { lock.unlock() }
    return !stopped
  }
}

@Suite("Kaiba HTTP transport deadline")
struct KaibaHTTPTransportDeadlineTests {
  @Test func rejectsUnrepresentableFiniteTimeoutBeforeStartingURLSession() async throws {
    let transport = URLSessionKaibaHTTPTransport(protocolClasses: [TricklingURLProtocol.self])
    let request = KaibaHTTPRequest(
      url: try #require(URL(string: "https://example.com/graphql")),
      headers: [:],
      body: Data(),
      timeout: Double.greatestFiniteMagnitude
    )

    do {
      _ = try await transport.send(request, maximumResponseBytes: 1_024)
      Issue.record("expected invalid timeout configuration")
    } catch let error as KaibaClientError {
      #expect(error.code == "invalid_configuration")
    }
  }

  @Test func tricklingResponseCannotExtendTheAbsoluteDeadline() async throws {
    let transport = URLSessionKaibaHTTPTransport(protocolClasses: [TricklingURLProtocol.self])
    let request = KaibaHTTPRequest(
      url: try #require(URL(string: "https://example.com/graphql")),
      headers: [:],
      body: Data(),
      timeout: 0.1
    )
    let startedAt = Date()

    do {
      _ = try await transport.send(request, maximumResponseBytes: 1_024)
      Issue.record("expected absolute deadline failure")
    } catch let error as URLError {
      #expect(error.code == .timedOut)
    }

    #expect(Date().timeIntervalSince(startedAt) < 1.5)
  }
}
