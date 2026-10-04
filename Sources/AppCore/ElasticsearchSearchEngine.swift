import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum ElasticsearchAuthorization: Sendable, Equatable {
  case none
  case apiKey(String)
  case basic(username: String, password: String)

  var headerValue: String? {
    switch self {
    case .none:
      nil
    case let .apiKey(key):
      "ApiKey \(key)"
    case let .basic(username, password):
      "Basic \(Data("\(username):\(password)".utf8).base64EncodedString())"
    }
  }
}

public struct ElasticsearchSearchEngine: SearchEngine {
  private let baseURL: URL
  private let indexName: String
  private let authorization: ElasticsearchAuthorization
  private let transport: any ElasticsearchHTTPTransport
  private let requestTimeoutSeconds: Int

  public var indexIdentity: String {
    "elasticsearch:\(SearchEngineFactory.normalizedTarget(baseURL.absoluteString) ?? baseURL.absoluteString)/\(indexName)"
  }

  init(
    baseURL: URL,
    indexPrefix: String,
    authorization: ElasticsearchAuthorization,
    requestTimeoutSeconds: Int = 10,
    verifyTLS: Bool = true,
    transport: (any ElasticsearchHTTPTransport)? = nil
  ) {
    self.baseURL = baseURL
    self.indexName = "\(indexPrefix)-notes-v2"
    self.authorization = authorization
    self.requestTimeoutSeconds = requestTimeoutSeconds
    self.transport = transport ?? URLSessionElasticsearchTransport(insecureTrustHost: verifyTLS ? nil : baseURL.host)
  }

  public func health() async throws -> SearchEngineHealth {
    let (data, response) = try await send(path: "_cluster/health", method: "GET", timeout: TimeInterval(requestTimeoutSeconds))
    try requireSuccess(response, body: data)
    guard let object = try? jsonObject(data), let status = object["status"] as? String else {
      throw SearchEngineError.invalidResponse("health status missing")
    }
    return SearchEngineHealth(isAvailable: status == "green" || status == "yellow", detail: status)
  }

  public func ensureIndex() async throws {
    let (_, head) = try await send(path: indexName, method: "HEAD", timeout: TimeInterval(requestTimeoutSeconds))
    if head.statusCode == 200 { return }
    guard head.statusCode == 404 else {
      try requireSuccess(head, body: Data())
      return
    }

    let body = try ElasticsearchRequestBodies.data(ElasticsearchRequestBodies.index)
    let (putBody, put) = try await send(path: indexName, method: "PUT", body: body, timeout: TimeInterval(requestTimeoutSeconds))
    if (200..<300).contains(put.statusCode) { return }
    if put.statusCode == 400, errorType(putBody) == "resource_already_exists_exception" { return }
    try requireSuccess(put, body: putBody)
  }

  public func apply(_ operations: [SearchIndexOperation]) async throws -> [SearchIndexOperationResult] {
    guard !operations.isEmpty else { return [] }
    let body = try ElasticsearchRequestBodies.bulk(operations, indexName: indexName)
    let (data, response) = try await send(
      path: "_bulk", method: "POST", body: body, contentType: "application/x-ndjson",
      timeout: TimeInterval(max(30, requestTimeoutSeconds))
    )
    try requireSuccess(response, body: data)
    guard let root = try? jsonObject(data), let items = root["items"] as? [[String: Any]], items.count == operations.count else {
      throw SearchEngineError.invalidResponse("bulk response items missing or out of order")
    }
    return try zip(operations, items).map { operation, item in
      guard let action = operationAction(operation), let result = item[action] as? [String: Any],
            let status = result["status"] as? Int else {
        throw SearchEngineError.invalidResponse("bulk item malformed")
      }
      let noteId = operation.noteId
      if (200..<300).contains(status) || (action == "delete" && status == 404) {
        return SearchIndexOperationResult(noteId: noteId, outcome: .succeeded)
      }
      let type = sanitized(result["error"].flatMap { ($0 as? [String: Any])?["type"] as? String } ?? "unknown_error")
      let reason = sanitized(result["error"].flatMap { ($0 as? [String: Any])?["reason"] as? String } ?? "operation failed")
      return SearchIndexOperationResult(noteId: noteId, outcome: .failed("\(type): \(reason.prefix(200))"))
    }
  }

  public func search(_ query: SearchEngineQuery) async throws -> [SearchEngineHit] {
    try await searchPage(query).hits
  }

  public func searchPage(_ query: SearchEngineQuery) async throws -> SearchEngineSearchPage {
    guard query.filter.libraryIds != [] else { return SearchEngineSearchPage(hits: [], facets: nil) }
    let body = try ElasticsearchRequestBodies.data(ElasticsearchRequestBodies.search(query))
    let (data, response) = try await send(
      path: "\(indexName)/_search", method: "POST", body: body, timeout: TimeInterval(requestTimeoutSeconds)
    )
    try requireSuccess(response, body: data)
    let facets = query.facets == nil ? nil : try facets(from: data)
    return SearchEngineSearchPage(hits: try hits(from: data, includeHighlight: true), facets: facets)
  }

  public func relatedNotes(_ query: SearchEngineRelatedQuery) async throws -> [SearchEngineHit] {
    guard query.filter.libraryIds != [] else { return [] }
    let body = try ElasticsearchRequestBodies.data(ElasticsearchRequestBodies.related(query))
    guard let root = try? jsonObject(body),
          let queryObject = root["query"] as? [String: Any],
          let bool = queryObject["bool"] as? [String: Any],
          let should = bool["should"] as? [[String: Any]], !should.isEmpty else { return [] }
    let (data, response) = try await send(
      path: "\(indexName)/_search", method: "POST", body: body, timeout: TimeInterval(requestTimeoutSeconds)
    )
    try requireSuccess(response, body: data)
    return try hits(from: data, includeHighlight: false)
  }

  private func send(
    path: String,
    method: String,
    body: Data? = nil,
    contentType: String = "application/json",
    timeout: TimeInterval
  ) async throws -> (Data, HTTPURLResponse) {
    var request = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: timeout)
    request.httpMethod = method
    request.httpBody = body
    if body != nil { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
    if let authorizationHeader = authorization.headerValue {
      request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
    }
    do {
      return try await transport.send(request)
    } catch let error as SearchEngineError {
      throw error
    } catch let error as URLError {
      throw SearchEngineError.unavailable("URLError \(error.code.rawValue)")
    } catch {
      throw SearchEngineError.unavailable("transport failure")
    }
  }

  private func requireSuccess(_ response: HTTPURLResponse, body: Data) throws {
    guard (200..<300).contains(response.statusCode) else {
      let type = sanitized(errorType(body) ?? "unknown_error")
      if response.statusCode == 401 || response.statusCode == 403 {
        throw SearchEngineError.rejected(status: response.statusCode, reason: type)
      }
      if (400..<500).contains(response.statusCode) {
        let reason = errorReason(body).map { ": \(sanitized(String($0.prefix(200))))" } ?? ""
        throw SearchEngineError.rejected(status: response.statusCode, reason: "\(type)\(reason)")
      }
      if response.statusCode >= 500 {
        throw SearchEngineError.unavailable("HTTP \(response.statusCode)")
      }
      throw SearchEngineError.invalidResponse("HTTP \(response.statusCode)")
    }
  }

  private func jsonObject(_ data: Data) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw SearchEngineError.invalidResponse("JSON object expected")
    }
    return object
  }

  private func errorType(_ data: Data) -> String? {
    guard let root = try? jsonObject(data) else { return nil }
    if let error = root["error"] as? [String: Any] { return error["type"] as? String }
    return root["error"] as? String
  }

  private func errorReason(_ data: Data) -> String? {
    guard let root = try? jsonObject(data), let error = root["error"] as? [String: Any] else { return nil }
    return error["reason"] as? String
  }

  private func sanitized(_ value: String) -> String {
    let secrets: [String]
    switch authorization {
    case .none:
      secrets = []
    case let .apiKey(key):
      secrets = [key]
    case let .basic(username, password):
      secrets = [username, password]
    }
    return secrets.reduce(value) { result, secret in
      secret.isEmpty ? result : result.replacingOccurrences(of: secret, with: "[redacted]")
    }
  }

  private func operationAction(_ operation: SearchIndexOperation) -> String? {
    switch operation {
    case .upsert: "index"
    case .delete: "delete"
    }
  }

  private func hits(from data: Data, includeHighlight: Bool) throws -> [SearchEngineHit] {
    guard let root = try? jsonObject(data),
          let hitsObject = root["hits"] as? [String: Any],
          let rawHits = hitsObject["hits"] as? [[String: Any]] else {
      throw SearchEngineError.invalidResponse("search hits missing")
    }
    return try rawHits.map { hit in
      let source = hit["_source"] as? [String: Any]
      guard let noteIdValue = (source?["note_id"] as? String) ?? (hit["_id"] as? String),
            let score = hit["_score"] as? NSNumber else {
        throw SearchEngineError.invalidResponse("search hit malformed")
      }
      let highlight: String?
      if includeHighlight, let fields = hit["highlight"] as? [String: Any] {
        highlight = (fields["body"] as? [String])?.first ?? (fields["title"] as? [String])?.first
      } else {
        highlight = nil
      }
      let matchedQueries = hit["matched_queries"] as? [String] ?? []
      let reasons = matchedQueries.compactMap(SearchEngineHitReasonKind.init(rawValue:)).map {
        SearchEngineHitReason(kind: $0)
      }
      return SearchEngineHit(noteId: NoteID(noteIdValue), score: score.doubleValue, highlight: highlight, reasons: reasons)
    }
  }

  private func facets(from data: Data) throws -> SearchEngineFacets {
    guard let root = try? jsonObject(data),
          let aggregations = root["aggregations"] as? [String: Any] else {
      throw SearchEngineError.invalidResponse("search facets missing")
    }
    func buckets(_ name: String) throws -> [SearchEngineFacetBucket] {
      guard let aggregation = aggregations[name] as? [String: Any],
            let rawBuckets = aggregation["buckets"] as? [[String: Any]] else {
        throw SearchEngineError.invalidResponse("search facet buckets missing")
      }
      return try rawBuckets.map { bucket in
        guard let key = bucket["key"] as? String, let count = bucket["doc_count"] as? NSNumber else {
          throw SearchEngineError.invalidResponse("search facet bucket malformed")
        }
        return SearchEngineFacetBucket(value: key, count: count.intValue)
      }
    }
    return SearchEngineFacets(tagClasses: try buckets("tag_classes"), tags: try buckets("tags"))
  }
}
