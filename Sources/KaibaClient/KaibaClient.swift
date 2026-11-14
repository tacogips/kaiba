import Foundation

public struct KaibaClient: Sendable {
  public let endpoint: KaibaEndpoint
  public let authentication: KaibaAuthentication
  public let configuration: KaibaClientConfiguration
  private let transport: any KaibaHTTPTransporting

  public init(
    endpoint source: URL,
    authentication: KaibaAuthentication,
    configuration: KaibaClientConfiguration? = nil,
    transport: any KaibaHTTPTransporting = URLSessionKaibaHTTPTransport()
  ) throws {
    let resolvedConfiguration = try configuration ?? KaibaClientConfiguration()
    try resolvedConfiguration.validate()
    let endpoint = try KaibaEndpoint(
      source,
      transportSecurity: resolvedConfiguration.transportSecurity
    )
    if case .unauthenticated = authentication,
       !endpoint.isLoopback,
       !resolvedConfiguration.allowRemoteUnauthenticated {
      throw KaibaClientError.invalidConfiguration(
        "remote unauthenticated access requires allowRemoteUnauthenticated"
      )
    }
    self.endpoint = endpoint
    self.authentication = authentication
    self.configuration = resolvedConfiguration
    self.transport = transport
  }

  public func execute(
    _ request: KaibaGraphQLRequest
  ) async throws -> KaibaGraphQLResponse<KaibaJSONValue> {
    let document = request.document.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !document.isEmpty else {
      throw KaibaClientError.invalidRequest("the GraphQL document must not be empty")
    }
    if let operationName = request.operationName, operationName.isEmpty {
      throw KaibaClientError.invalidRequest("operationName must be non-empty when present")
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let body: Data
    do {
      body = try encoder.encode(KaibaGraphQLWireRequest(
        query: request.document,
        variables: request.variables.isEmpty ? nil : request.variables,
        operationName: request.operationName
      ))
    } catch {
      throw KaibaClientError.invalidRequest("the GraphQL request could not be encoded")
    }
    guard body.count <= configuration.maximumRequestBytes else {
      throw KaibaClientError.invalidRequest("the encoded GraphQL request exceeds the byte limit")
    }
    var headers = [
      "accept": "application/json",
      "content-type": "application/json"
    ]
    if case let .bearer(token) = authentication {
      headers["authorization"] = "Bearer \(token.rawValue)"
    }
    let response: KaibaHTTPResponse
    do {
      response = try await transport.send(
        KaibaHTTPRequest(
          url: endpoint.transportURL,
          headers: headers,
          body: body,
          timeout: configuration.requestTimeout
        ),
        maximumResponseBytes: configuration.maximumResponseBytes
      )
    } catch let error as CancellationError {
      throw error
    } catch let error as KaibaClientError {
      throw error
    } catch let error as URLError {
      if error.code == .cancelled {
        throw CancellationError()
      }
      throw KaibaClientError.connectionFailed(error.code.rawValue)
    } catch {
      throw KaibaClientError.connectionFailed(nil)
    }
    if response.statusCode == 401 || response.statusCode == 403 {
      throw KaibaClientError.authFailed(response.statusCode)
    }
    guard (200...299).contains(response.statusCode) else {
      throw KaibaClientError.httpFailed(response.statusCode)
    }
    guard response.body.count <= configuration.maximumResponseBytes,
          let envelope = try? JSONDecoder().decode(KaibaGraphQLWireEnvelope.self, from: response.body) else {
      throw KaibaClientError.invalidResponse(
        status: response.statusCode,
        byteCount: response.body.count
      )
    }
    if let errors = envelope.errors, !errors.isEmpty {
      let safeErrors: [KaibaGraphQLError]
      do {
        safeErrors = try sanitized(errors)
      } catch {
        throw KaibaClientError.invalidResponse(
          status: response.statusCode,
          byteCount: response.body.count
        )
      }
      throw KaibaClientError.graphqlFailed(
        safeErrors,
        partialData: envelope.data
      )
    }
    guard let data = envelope.data else {
      throw KaibaClientError.invalidResponse(
        status: response.statusCode,
        byteCount: response.body.count
      )
    }
    return KaibaGraphQLResponse(data: data)
  }

  public func execute<Value: Decodable & Sendable>(
    _ request: KaibaGraphQLRequest,
    as type: Value.Type
  ) async throws -> KaibaGraphQLResponse<Value> {
    let raw = try await execute(request)
    do {
      let data = try JSONEncoder().encode(raw.data)
      return KaibaGraphQLResponse(data: try JSONDecoder().decode(type, from: data))
    } catch let error as DecodingError {
      throw KaibaClientError.decodingFailed(codingPath(from: error))
    }
  }

  private func sanitized(_ errors: [KaibaGraphQLError]) throws -> [KaibaGraphQLError] {
    try errors.prefix(20).map { error in
      let message = sanitizedText(error.message)
      let path = try error.path?.map { value -> KaibaJSONValue in
        switch value {
        case let .string(component):
          return .string(sanitizedText(component))
        case .integer:
          return value
        default:
          throw InvalidGraphQLPathError()
        }
      }
      let extensions = error.extensions?["code"]?.stringValue.map {
        ["code": KaibaJSONValue.string(sanitizedText($0))]
      }
      let locations = error.locations?.prefix(20).filter {
        $0.line > 0 && $0.column > 0
      }
      return KaibaGraphQLError(
        message: message,
        locations: locations.map(Array.init),
        path: path,
        extensions: extensions
      )
    }
  }

  private func sanitizedText(_ source: String) -> String {
    KaibaRedaction(authentication: authentication).text(source)
  }

  private func codingPath(from error: DecodingError) -> String {
    let path: [CodingKey]
    switch error {
    case let .dataCorrupted(context), let .keyNotFound(_, context),
         let .typeMismatch(_, context), let .valueNotFound(_, context):
      path = context.codingPath
    @unknown default:
      path = []
    }
    return path.map { key in
      if let index = key.intValue {
        return String(index)
      }
      return sanitizedText(key.stringValue)
    }.joined(separator: ".")
  }
}

private struct InvalidGraphQLPathError: Error {}
