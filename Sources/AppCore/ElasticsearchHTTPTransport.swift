import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif

protocol ElasticsearchHTTPTransport: Sendable {
  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionElasticsearchTransport: ElasticsearchHTTPTransport {
  static var supportsInsecureTLS: Bool {
    #if canImport(Security)
    true
    #else
    false
    #endif
  }

  private let session: URLSession

  init(insecureTrustHost: String? = nil) {
    if let insecureTrustHost {
      #if canImport(Security)
      session = URLSession(configuration: .default, delegate: ElasticsearchTrustDelegate(host: insecureTrustHost), delegateQueue: nil)
      #else
      session = .shared
      #endif
    } else {
      session = .shared
    }
  }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw SearchEngineError.invalidResponse("response was not HTTP")
    }
    return (data, httpResponse)
  }
}

#if canImport(Security)
private final class ElasticsearchTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
  private let host: String

  init(host: String) {
    self.host = host.lowercased()
  }

  func urlSession(
    _ session: URLSession,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
          challenge.protectionSpace.host.lowercased() == host,
          let trust = challenge.protectionSpace.serverTrust else {
      completionHandler(.performDefaultHandling, nil)
      return
    }
    completionHandler(.useCredential, URLCredential(trust: trust))
  }
}
#endif
