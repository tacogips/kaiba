import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct KaibaHTTPRequest: Equatable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable {
  public var url: URL
  public var headers: [String: String]
  public var body: Data
  public var timeout: TimeInterval

  public init(url: URL, headers: [String: String], body: Data, timeout: TimeInterval) {
    self.url = url
    self.headers = headers
    self.body = body
    self.timeout = timeout
  }

  public var description: String {
    "KaibaHTTPRequest(endpoint: \(redactedEndpoint), headerNames: \(headerNames), "
      + "bodyByteCount: \(body.count), timeout: \(timeout))"
  }

  public var debugDescription: String { description }

  public var customMirror: Mirror {
    Mirror(self, children: [
      "endpoint": redactedEndpoint,
      "headerNames": headerNames,
      "bodyByteCount": body.count,
      "timeout": timeout
    ], displayStyle: .struct)
  }

  private var redactedEndpoint: String {
    KaibaAuthentication.unauthenticated.redactedEndpointDiagnostic(url.absoluteString)
  }

  private var headerNames: [String] {
    headers.keys.sorted()
  }
}

public struct KaibaHTTPResponse: Equatable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable {
  public var statusCode: Int
  public var body: Data

  public init(statusCode: Int, body: Data) {
    self.statusCode = statusCode
    self.body = body
  }

  public var description: String {
    "KaibaHTTPResponse(statusCode: \(statusCode), bodyByteCount: \(body.count))"
  }

  public var debugDescription: String { description }

  public var customMirror: Mirror {
    Mirror(self, children: [
      "statusCode": statusCode,
      "bodyByteCount": body.count
    ], displayStyle: .struct)
  }
}

public protocol KaibaHTTPTransporting: Sendable {
  func send(_ request: KaibaHTTPRequest, maximumResponseBytes: Int) async throws -> KaibaHTTPResponse
}

public struct URLSessionKaibaHTTPTransport: @unchecked Sendable, KaibaHTTPTransporting {
  private let protocolClasses: [AnyClass]?

  public init() {
    protocolClasses = nil
  }

  init(protocolClasses: [AnyClass]) {
    self.protocolClasses = protocolClasses
  }

  public func send(_ request: KaibaHTTPRequest, maximumResponseBytes: Int) async throws -> KaibaHTTPResponse {
    try KaibaClientConfiguration.validateRequestTimeout(request.timeout)
    let delegate = BoundedResponseDelegate(maximumResponseBytes: maximumResponseBytes)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = request.timeout
    configuration.timeoutIntervalForResource = request.timeout
    if let protocolClasses {
      configuration.protocolClasses = protocolClasses
    }
    let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout)
    urlRequest.httpMethod = "POST"
    urlRequest.httpBody = request.body
    request.headers.forEach { urlRequest.setValue($1, forHTTPHeaderField: $0) }
    let preparedRequest = urlRequest
    return try await withThrowingTaskGroup(of: KaibaHTTPResponse.self) { group in
      group.addTask {
        try await withTaskCancellationHandler {
          try await delegate.start(session: session, request: preparedRequest)
        } onCancel: {
          delegate.cancel()
          session.invalidateAndCancel()
        }
      }
      group.addTask {
        try await Task.sleep(for: .seconds(request.timeout))
        throw URLError(.timedOut)
      }
      defer { group.cancelAll() }
      guard let response = try await group.next() else {
        throw URLError(.unknown)
      }
      return response
    }
  }
}

private final class BoundedResponseDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private let maximumResponseBytes: Int
  private var body = Data()
  private var statusCode = 0
  private var continuation: CheckedContinuation<KaibaHTTPResponse, Error>?
  private var completed = false

  init(maximumResponseBytes: Int) {
    self.maximumResponseBytes = maximumResponseBytes
  }

  func start(session: URLSession, request: URLRequest) async throws -> KaibaHTTPResponse {
    try await withCheckedThrowingContinuation { continuation in
      lock.lock()
      guard !completed else {
        lock.unlock()
        continuation.resume(throwing: CancellationError())
        return
      }
      self.continuation = continuation
      lock.unlock()
      session.dataTask(with: request).resume()
    }
  }

  func cancel() {
    lock.lock()
    guard !completed else { lock.unlock(); return }
    completed = true
    let continuation = continuation
    self.continuation = nil
    lock.unlock()
    continuation?.resume(throwing: CancellationError())
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    lock.lock()
    statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
    lock.unlock()
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    lock.lock()
    guard !completed else { lock.unlock(); return }
    if body.count + data.count > maximumResponseBytes {
      completed = true
      let continuation = continuation
      self.continuation = nil
      let byteCount = body.count + data.count
      let statusCode = statusCode
      lock.unlock()
      dataTask.cancel()
      continuation?.resume(throwing: KaibaClientError.invalidResponse(
        status: statusCode,
        byteCount: byteCount
      ))
      return
    }
    body.append(data)
    lock.unlock()
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    lock.lock()
    guard !completed else { lock.unlock(); return }
    completed = true
    let continuation = continuation
    self.continuation = nil
    let response = KaibaHTTPResponse(statusCode: statusCode, body: body)
    lock.unlock()
    if let error {
      continuation?.resume(throwing: error)
    } else {
      continuation?.resume(returning: response)
    }
  }
}
