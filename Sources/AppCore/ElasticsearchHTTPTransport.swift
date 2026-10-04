import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

protocol ElasticsearchHTTPTransport: Sendable {
  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionElasticsearchTransport: ElasticsearchHTTPTransport {
  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw SearchEngineError.invalidResponse("response was not HTTP")
    }
    return (data, httpResponse)
  }
}
