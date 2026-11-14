import Foundation
import AppCore
import AppGraphQL

public struct KaibaHTTPRequest: Equatable, Sendable {
  public var method: String
  public var path: String
  public var percentEncodedPath: String
  public var query: String?
  public var headers: [String: String]
  public var body: Data

  public init(
    method: String,
    path: String,
    percentEncodedPath: String? = nil,
    query: String? = nil,
    headers: [String: String] = [:],
    body: Data = Data()
  ) {
    self.method = method.uppercased()
    self.path = path
    self.percentEncodedPath = percentEncodedPath ?? path
    self.query = query
    self.headers = headers.reduce(into: [:]) { result, element in
      result[element.key.lowercased()] = element.value
    }
    self.body = body
  }
}

public struct KaibaHTTPResponse: Equatable, Sendable {
  public var status: Int
  public var headers: [String: String]
  public var body: Data

  public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
    self.status = status
    self.headers = headers
    self.body = body
  }

  public static func json(status: Int = 200, _ value: JSONValue) -> Self {
    let body = (try? JSONEncoder.sorted.encode(value)) ?? Data("{}".utf8)
    return Self(status: status, headers: ["Content-Type": "application/json; charset=utf-8"], body: body)
  }

  public static func text(status: Int, _ value: String) -> Self {
    Self(
      status: status,
      headers: ["Content-Type": "text/plain; charset=utf-8"],
      body: Data(value.utf8)
    )
  }

  public func serialized(forMethod method: String = "GET") -> Data {
    var responseHeaders = headers
    responseHeaders["Content-Length"] = String(body.count)
    responseHeaders["Connection"] = "close"
    responseHeaders["X-Content-Type-Options"] = "nosniff"
    responseHeaders["X-Frame-Options"] = "DENY"
    responseHeaders["Referrer-Policy"] = "no-referrer"
    let reason = Self.reasonPhrase(for: status)
    var lines = ["HTTP/1.1 \(status) \(reason)"]
    lines.append(contentsOf: responseHeaders.keys.sorted().map { "\($0): \(responseHeaders[$0] ?? "")" })
    lines.append("")
    lines.append("")
    var data = Data(lines.joined(separator: "\r\n").utf8)
    if method.uppercased() != "HEAD" {
      data.append(body)
    }
    return data
  }

  private static func reasonPhrase(for status: Int) -> String {
    switch status {
    case 200: "OK"
    case 201: "Created"
    case 204: "No Content"
    case 400: "Bad Request"
    case 403: "Forbidden"
    case 404: "Not Found"
    case 405: "Method Not Allowed"
    case 409: "Conflict"
    case 413: "Content Too Large"
    case 415: "Unsupported Media Type"
    case 429: "Too Many Requests"
    case 431: "Request Header Fields Too Large"
    case 500: "Internal Server Error"
    case 503: "Service Unavailable"
    default: "Response"
    }
  }
}

public protocol KaibaHTTPRouteHandling: Sendable {
  func response(for request: KaibaHTTPRequest) async -> KaibaHTTPResponse
}

public struct AnyKaibaHTTPRouteHandler: KaibaHTTPRouteHandling {
  private let operation: @Sendable (KaibaHTTPRequest) async -> KaibaHTTPResponse

  public init(_ operation: @escaping @Sendable (KaibaHTTPRequest) async -> KaibaHTTPResponse) {
    self.operation = operation
  }

  public func response(for request: KaibaHTTPRequest) async -> KaibaHTTPResponse {
    await operation(request)
  }
}

public struct DeterministicServerHTTPAdapter: KaibaHTTPRouteHandling {
  public var routeHandler: any ServerRouteHandling
  public var context: ServerRequestContext

  public init(
    routeHandler: any ServerRouteHandling = DeterministicServerRouteHandler(),
    context: ServerRequestContext = ServerRequestContext()
  ) {
    self.routeHandler = routeHandler
    self.context = context
  }

  public func response(for request: KaibaHTTPRequest) async -> KaibaHTTPResponse {
    let descriptor = await routeHandler.route(
      ServerRequestEnvelope(
        method: request.method,
        path: request.path,
        headers: request.headers,
        body: request.body.isEmpty ? nil : request.body,
        query: request.query
      ),
      context: context
    )
    let body = (try? JSONEncoder.sorted.encode(JSONValue.object(descriptor.body))) ?? Data("{}".utf8)
    var headers = descriptor.headers
    headers["Content-Type"] = descriptor.contentType + "; charset=utf-8"
    return KaibaHTTPResponse(
      status: descriptor.status,
      headers: headers,
      body: body
    )
  }
}

private extension JSONEncoder {
  static var sorted: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }
}
