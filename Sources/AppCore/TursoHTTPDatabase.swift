import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct TursoDatabaseConfiguration: Equatable, Sendable {
  public var url: URL
  public var authToken: String
  public var allowInsecureLoopbackHTTP: Bool

  public init(
    url: URL,
    authToken: String,
    allowInsecureLoopbackHTTP: Bool = false
  ) {
    self.url = url
    self.authToken = authToken
    self.allowInsecureLoopbackHTTP = allowInsecureLoopbackHTTP
  }
}

public enum TursoDatabaseError: Error, Equatable, Sendable {
  case invalidURL
  case insecureURL
  case invalidResponse
  case httpFailure(Int)
  case serverFailure(String)
}

struct TursoHTTPExecutionResult: Sendable {
  var rows: [SQLiteRow]
  var affectedRowCount: Int
}

/// Synchronous SQL-over-HTTP v2 connection used behind `NoteDatabaseDriving`.
/// The driver serializes access, so the mutable baton always belongs to exactly
/// one logical database connection and can safely span Kaiba transactions.
final class TursoHTTPDatabase: @unchecked Sendable {
  private let endpoint: URL
  private let authToken: String
  private let session: URLSession
  private var baton: String?
  private var routedEndpoint: URL?

  init(
    configuration: TursoDatabaseConfiguration,
    session: URLSession = .shared
  ) throws {
    endpoint = try Self.pipelineEndpoint(configuration: configuration)
    authToken = configuration.authToken
    self.session = session
  }

  deinit {
    try? close()
  }

  func execute(_ sql: String, bindings: [SQLiteValue]) throws -> TursoHTTPExecutionResult {
    let statement: [String: Any] = [
      "sql": sql,
      "args": bindings.map(Self.encodedValue)
    ]
    let response = try send(requests: [["type": "execute", "stmt": statement]])
    guard let first = response.results.first else {
      throw TursoDatabaseError.invalidResponse
    }
    switch first {
    case .error(let message):
      throw TursoDatabaseError.serverFailure(message)
    case .ok(let result):
      return result
    }
  }

  private func close() throws {
    guard baton != nil else {
      return
    }
    _ = try send(requests: [["type": "close"]])
    baton = nil
    routedEndpoint = nil
  }

  private func send(requests: [[String: Any]]) throws -> PipelineResponse {
    var body: [String: Any] = ["requests": requests]
    if let baton {
      body["baton"] = baton
    }
    var request = URLRequest(url: routedEndpoint ?? endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if !authToken.isEmpty {
      request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let result = try Self.perform(request, session: session)
    guard (200..<300).contains(result.statusCode) else {
      throw TursoDatabaseError.httpFailure(result.statusCode)
    }
    let decoded = try Self.decodeResponse(result.data)
    baton = decoded.baton
    if let baseURL = decoded.baseURL,
       let url = URL(string: baseURL),
       let routed = URL(string: "v2/pipeline", relativeTo: url)?.absoluteURL {
      routedEndpoint = routed
    }
    return decoded
  }

  private static func pipelineEndpoint(configuration: TursoDatabaseConfiguration) throws -> URL {
    guard var components = URLComponents(url: configuration.url, resolvingAgainstBaseURL: false),
          let host = components.host else {
      throw TursoDatabaseError.invalidURL
    }
    switch components.scheme?.lowercased() {
    case "libsql", "turso":
      components.scheme = "https"
    case "https":
      break
    case "http":
      let isLoopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
      guard configuration.allowInsecureLoopbackHTTP, isLoopback else {
        throw TursoDatabaseError.insecureURL
      }
    default:
      throw TursoDatabaseError.invalidURL
    }
    components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    components.path = components.path.isEmpty ? "/v2/pipeline" : "/\(components.path)/v2/pipeline"
    components.query = nil
    components.fragment = nil
    guard let endpoint = components.url else {
      throw TursoDatabaseError.invalidURL
    }
    return endpoint
  }

  private static func encodedValue(_ value: SQLiteValue) -> [String: Any] {
    switch value {
    case .text(let value): return ["type": "text", "value": value]
    case .int(let value): return ["type": "integer", "value": String(value)]
    case .double(let value): return ["type": "float", "value": value]
    case .null: return ["type": "null"]
    }
  }

  private static func perform(_ request: URLRequest, session: URLSession) throws -> HTTPResult {
    let box = HTTPResultBox()
    let semaphore = DispatchSemaphore(value: 0)
    session.dataTask(with: request) { data, response, error in
      box.store(data: data, response: response, error: error)
      semaphore.signal()
    }.resume()
    semaphore.wait()
    let result = box.result()
    if let error = result.error {
      throw error
    }
    guard let response = result.response as? HTTPURLResponse else {
      throw TursoDatabaseError.invalidResponse
    }
    return HTTPResult(statusCode: response.statusCode, data: result.data ?? Data())
  }

  private static func decodeResponse(_ data: Data) throws -> PipelineResponse {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let rawResults = object["results"] as? [[String: Any]] else {
      throw TursoDatabaseError.invalidResponse
    }
    let results = try rawResults.map(decodePipelineResult)
    return PipelineResponse(
      baton: object["baton"] as? String,
      baseURL: object["base_url"] as? String,
      results: results
    )
  }

  private static func decodePipelineResult(_ object: [String: Any]) throws -> PipelineResult {
    if object["type"] as? String == "error" {
      let error = object["error"] as? [String: Any]
      return .error(error?["message"] as? String ?? "remote database request failed")
    }
    guard object["type"] as? String == "ok",
          let response = object["response"] as? [String: Any] else {
      throw TursoDatabaseError.invalidResponse
    }
    if response["type"] as? String == "close" {
      return .ok(TursoHTTPExecutionResult(rows: [], affectedRowCount: 0))
    }
    guard let result = response["result"] as? [String: Any],
          let columns = result["cols"] as? [[String: Any]],
          let rawRows = result["rows"] as? [[[String: Any]]] else {
      throw TursoDatabaseError.invalidResponse
    }
    let names = try columns.map { column -> String in
      guard let name = column["name"] as? String else {
        throw TursoDatabaseError.invalidResponse
      }
      return name
    }
    let rows = try rawRows.map { rawRow -> SQLiteRow in
      guard rawRow.count == names.count else {
        throw TursoDatabaseError.invalidResponse
      }
      var values: [String: String?] = [:]
      for (name, rawValue) in zip(names, rawRow) {
        values[name] = try decodedTextValue(rawValue)
      }
      return SQLiteRow(values: values)
    }
    return .ok(TursoHTTPExecutionResult(
      rows: rows,
      affectedRowCount: result["affected_row_count"] as? Int ?? 0
    ))
  }

  private static func decodedTextValue(_ value: [String: Any]) throws -> String? {
    switch value["type"] as? String {
    case "null": return nil
    case "text", "integer": return value["value"] as? String
    case "float":
      guard let number = value["value"] as? NSNumber else {
        throw TursoDatabaseError.invalidResponse
      }
      return number.stringValue
    case "blob": return value["base64"] as? String
    default: throw TursoDatabaseError.invalidResponse
    }
  }
}

private struct PipelineResponse {
  var baton: String?
  var baseURL: String?
  var results: [PipelineResult]
}

private enum PipelineResult {
  case ok(TursoHTTPExecutionResult)
  case error(String)
}

private struct HTTPResult {
  var statusCode: Int
  var data: Data
}

private struct HTTPResultSnapshot {
  var data: Data?
  var response: URLResponse?
  var error: Error?
}

private final class HTTPResultBox: @unchecked Sendable {
  private let lock = NSLock()
  private var data: Data?
  private var response: URLResponse?
  private var error: Error?

  func store(data: Data?, response: URLResponse?, error: Error?) {
    lock.lock()
    self.data = data
    self.response = response
    self.error = error
    lock.unlock()
  }

  func result() -> HTTPResultSnapshot {
    lock.lock()
    defer { lock.unlock() }
    return HTTPResultSnapshot(data: data, response: response, error: error)
  }
}
