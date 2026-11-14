import Foundation

public enum KaibaHTTPRequestParseResult: Equatable, Sendable {
  case incomplete
  case complete(KaibaHTTPRequest)
}

private struct KaibaHTTPNormalizedTarget {
  var path: String
  var percentEncodedPath: String
  var query: String?
}

public enum KaibaHTTPRequestParserError: LocalizedError, Equatable, Sendable {
  case headersTooLarge
  case bodyTooLarge
  case malformedRequest
  case invalidTarget
  case invalidContentLength
  case unsupportedTransferEncoding

  public var errorDescription: String? {
    switch self {
    case .headersTooLarge: "HTTP headers exceed the 32 KiB limit."
    case .bodyTooLarge: "HTTP body exceeds the 2 MiB limit."
    case .malformedRequest: "Malformed HTTP request."
    case .invalidTarget: "Invalid HTTP request target."
    case .invalidContentLength: "Invalid Content-Length header."
    case .unsupportedTransferEncoding: "Transfer-Encoding is not supported."
    }
  }

  public var status: Int {
    switch self {
    case .headersTooLarge: 431
    case .bodyTooLarge: 413
    default: 400
    }
  }
}

public struct KaibaHTTPRequestParser: Sendable {
  public static let maximumHeaderBytes = 32 * 1_024
  public static let maximumBodyBytes = 2 * 1_024 * 1_024

  public init() {}

  public func parse(_ data: Data) throws -> KaibaHTTPRequestParseResult {
    let boundary = Data("\r\n\r\n".utf8)
    guard let headerRange = data.range(of: boundary) else {
      if data.count > Self.maximumHeaderBytes {
        throw KaibaHTTPRequestParserError.headersTooLarge
      }
      return .incomplete
    }
    guard headerRange.lowerBound <= Self.maximumHeaderBytes else {
      throw KaibaHTTPRequestParserError.headersTooLarge
    }
    guard let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else {
      throw KaibaHTTPRequestParserError.malformedRequest
    }
    let lines = headerText.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else {
      throw KaibaHTTPRequestParserError.malformedRequest
    }
    let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
    guard requestParts.count == 3,
          requestParts[2] == "HTTP/1.1",
          !requestParts[0].isEmpty else {
      throw KaibaHTTPRequestParserError.malformedRequest
    }
    let target = String(requestParts[1])
    let normalized = try normalizedTarget(target)
    var headers: [String: String] = [:]
    for line in lines.dropFirst() where !line.isEmpty {
      guard let separator = line.firstIndex(of: ":") else {
        throw KaibaHTTPRequestParserError.malformedRequest
      }
      let name = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
      let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
      guard !name.isEmpty, headers[name] == nil else {
        throw KaibaHTTPRequestParserError.malformedRequest
      }
      headers[name] = value
    }
    if let transferEncoding = headers["transfer-encoding"], !transferEncoding.isEmpty {
      throw KaibaHTTPRequestParserError.unsupportedTransferEncoding
    }
    let contentLength: Int
    if let rawLength = headers["content-length"] {
      guard let parsed = Int(rawLength), parsed >= 0 else {
        throw KaibaHTTPRequestParserError.invalidContentLength
      }
      contentLength = parsed
    } else {
      contentLength = 0
    }
    guard contentLength <= Self.maximumBodyBytes else {
      throw KaibaHTTPRequestParserError.bodyTooLarge
    }
    let bodyStart = headerRange.upperBound
    let availableBodyBytes = data.count - bodyStart
    guard availableBodyBytes >= contentLength else {
      return .incomplete
    }
    guard availableBodyBytes == contentLength else {
      throw KaibaHTTPRequestParserError.malformedRequest
    }
    return .complete(KaibaHTTPRequest(
      method: String(requestParts[0]),
      path: normalized.path,
      percentEncodedPath: normalized.percentEncodedPath,
      query: normalized.query,
      headers: headers,
      body: data.subdata(in: bodyStart..<(bodyStart + contentLength))
    ))
  }

  private func normalizedTarget(_ target: String) throws -> KaibaHTTPNormalizedTarget {
    guard target.hasPrefix("/"),
          !target.contains("\\"),
          !target.unicodeScalars.contains(where: { $0.value == 0 }) else {
      throw KaibaHTTPRequestParserError.invalidTarget
    }
    let pieces = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
    let rawPath = String(pieces[0])
    guard validPercentEncoding(in: rawPath), let decodedPath = rawPath.removingPercentEncoding else {
      throw KaibaHTTPRequestParserError.invalidTarget
    }
    let segments = decodedPath.split(separator: "/", omittingEmptySubsequences: false)
    guard !segments.contains(where: { $0 == "." || $0 == ".." }),
          !decodedPath.contains("\\") else {
      throw KaibaHTTPRequestParserError.invalidTarget
    }
    return KaibaHTTPNormalizedTarget(
      path: decodedPath,
      percentEncodedPath: rawPath,
      query: pieces.count == 2 ? String(pieces[1]) : nil
    )
  }

  private func validPercentEncoding(in value: String) -> Bool {
    let characters = Array(value)
    var index = 0
    while index < characters.count {
      if characters[index] == "%" {
        guard index + 2 < characters.count,
              characters[index + 1].isHexDigit,
              characters[index + 2].isHexDigit else {
          return false
        }
        index += 3
      } else {
        index += 1
      }
    }
    return true
  }
}
