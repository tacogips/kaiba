import Foundation
import KaibaClient

public protocol KaibaSchemaFetching: Sendable {
  func fetchSchema() async throws -> KaibaGraphQLSchema
}

extension KaibaClient: KaibaSchemaFetching {}

public enum GraphQLSchemaOutputMode: String, Equatable, Sendable {
  case text
  case json
}

public struct GraphQLSchemaCommandResult: Equatable, Sendable {
  public var standardOutput: String
  public var standardError: String
  public var exitCode: Int32

  public init(standardOutput: String = "", standardError: String = "", exitCode: Int32) {
    self.standardOutput = standardOutput
    self.standardError = standardError
    self.exitCode = exitCode
  }
}

public enum GraphQLSchemaCommandError: Error, Equatable, CustomStringConvertible {
  case invalidUsage(String)
  case missingCredential(String)

  public var description: String {
    switch self {
    case let .invalidUsage(message): "invalid_usage: \(message)"
    case let .missingCredential(name): "missing_credential: environment variable \(name) is empty or unset"
    }
  }
}

private struct GraphQLSchemaJSONSuccess: Encodable {
  let status = "ok"
  let endpoint: String
  let filter: String?
  let queryFields: [KaibaSchemaField]
  let mutationFields: [KaibaSchemaField]
  let types: [KaibaSchemaType]

  private enum CodingKeys: String, CodingKey {
    case status
    case endpoint
    case filter
    case queryFields
    case mutationFields
    case types
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(status, forKey: .status)
    try container.encode(endpoint, forKey: .endpoint)
    if let filter {
      try container.encode(filter, forKey: .filter)
    } else {
      try container.encodeNil(forKey: .filter)
    }
    try container.encode(queryFields, forKey: .queryFields)
    try container.encode(mutationFields, forKey: .mutationFields)
    try container.encode(types, forKey: .types)
  }
}

public enum GraphQLSchemaCommand {
  public static func isSchemaSubcommand(arguments: [String]) -> Bool {
    arguments.first == "schema"
  }

  public struct Options: Equatable, Sendable {
    public var endpoint: URL
    public var apiKeyEnvironmentVariable: String?
    public var allowUnauthenticated: Bool
    public var allowRemoteUnauthenticated: Bool
    public var allowInsecureHTTP: Bool
    public var filter: String?
    public var output: GraphQLSchemaOutputMode

    public init(
      endpoint: URL,
      apiKeyEnvironmentVariable: String? = nil,
      allowUnauthenticated: Bool = false,
      allowRemoteUnauthenticated: Bool = false,
      allowInsecureHTTP: Bool = false,
      filter: String? = nil,
      output: GraphQLSchemaOutputMode = .text
    ) {
      self.endpoint = endpoint
      self.apiKeyEnvironmentVariable = apiKeyEnvironmentVariable
      self.allowUnauthenticated = allowUnauthenticated
      self.allowRemoteUnauthenticated = allowRemoteUnauthenticated
      self.allowInsecureHTTP = allowInsecureHTTP
      self.filter = filter
      self.output = output
    }
  }

  public static func parse(arguments: [String]) throws -> Options {
    var values: [String: String] = [:]
    var flags = Set<String>()
    var index = 0
    let valueOptions = Set([
      "--endpoint", "--api-key-env", "--filter", "--output", "--config", "--note-root"
    ])
    let flagOptions = Set([
      "--allow-unauthenticated", "--allow-remote-unauthenticated", "--allow-insecure-http"
    ])
    while index < arguments.count {
      let argument = arguments[index]
      if valueOptions.contains(argument) {
        guard values[argument] == nil else {
          throw GraphQLSchemaCommandError.invalidUsage("duplicate option \(argument)")
        }
        index += 1
        guard index < arguments.count, !arguments[index].hasPrefix("--") else {
          throw GraphQLSchemaCommandError.invalidUsage("missing value for \(argument)")
        }
        values[argument] = arguments[index]
      } else if flagOptions.contains(argument) {
        guard flags.insert(argument).inserted else {
          throw GraphQLSchemaCommandError.invalidUsage("duplicate option \(argument)")
        }
      } else {
        throw GraphQLSchemaCommandError.invalidUsage("unknown argument")
      }
      index += 1
    }
    guard let endpointRaw = values["--endpoint"] else {
      throw GraphQLSchemaCommandError.invalidUsage("--endpoint <url> is required")
    }
    guard let endpoint = URL(string: endpointRaw) else {
      throw KaibaClientError.invalidEndpoint("an absolute HTTP(S) URL with a host is required")
    }
    let apiKeyEnvironmentVariable = values["--api-key-env"]
    let allowUnauthenticated = flags.contains("--allow-unauthenticated")
    guard (apiKeyEnvironmentVariable != nil) != allowUnauthenticated else {
      throw GraphQLSchemaCommandError.invalidUsage(
        "exactly one of --api-key-env or --allow-unauthenticated is required"
      )
    }
    if flags.contains("--allow-remote-unauthenticated"), !allowUnauthenticated {
      throw GraphQLSchemaCommandError.invalidUsage(
        "--allow-remote-unauthenticated requires --allow-unauthenticated"
      )
    }
    if let name = apiKeyEnvironmentVariable {
      guard name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else {
        throw GraphQLSchemaCommandError.invalidUsage("--api-key-env requires a valid environment name")
      }
    }
    let output = GraphQLSchemaOutputMode(rawValue: values["--output"] ?? "text")
    guard let output else {
      throw GraphQLSchemaCommandError.invalidUsage("--output must be text or json")
    }
    return Options(
      endpoint: endpoint,
      apiKeyEnvironmentVariable: apiKeyEnvironmentVariable,
      allowUnauthenticated: allowUnauthenticated,
      allowRemoteUnauthenticated: flags.contains("--allow-remote-unauthenticated"),
      allowInsecureHTTP: flags.contains("--allow-insecure-http"),
      filter: values["--filter"],
      output: output
    )
  }

  public static func run(
    arguments: [String],
    environment: [String: String] = ProcessInfo.processInfo.environment,
    makeClient: @Sendable (URL, KaibaAuthentication, KaibaClientConfiguration) throws -> any KaibaSchemaFetching = {
      try KaibaClient(endpoint: $0, authentication: $1, configuration: $2)
    }
  ) async -> GraphQLSchemaCommandResult {
    do {
      return await run(
        try parse(arguments: arguments),
        environment: environment,
        makeClient: makeClient
      )
    } catch {
      return failure(
        error,
        output: requestedOutputMode(in: arguments),
        endpoint: requestedEndpointDescription(in: arguments, environment: environment)
      )
    }
  }

  public static func run(
    _ options: Options,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    makeClient: @Sendable (URL, KaibaAuthentication, KaibaClientConfiguration) throws -> any KaibaSchemaFetching = {
      try KaibaClient(endpoint: $0, authentication: $1, configuration: $2)
    }
  ) async -> GraphQLSchemaCommandResult {
    var failureEndpoint = redactedEndpoint(options.endpoint)
    if let name = options.apiKeyEnvironmentVariable,
       let value = environment[name], !value.isEmpty {
      if let token = try? KaibaBearerToken(value) {
        failureEndpoint = KaibaAuthentication.bearer(token)
          .redactedEndpointDiagnostic(failureEndpoint)
      } else {
        failureEndpoint = "<redacted-endpoint>"
      }
    }
    do {
      if let filter = options.filter {
        do { _ = try NSRegularExpression(pattern: filter) } catch {
          throw KaibaClientError.invalidRegex
        }
      }
      let authentication: KaibaAuthentication
      if let name = options.apiKeyEnvironmentVariable {
        guard let value = environment[name], !value.isEmpty else {
          throw GraphQLSchemaCommandError.missingCredential(name)
        }
        do {
          authentication = .bearer(try KaibaBearerToken(value))
        } catch {
          failureEndpoint = "<redacted-endpoint>"
          throw error
        }
      } else {
        authentication = .unauthenticated
      }
      failureEndpoint = authentication.redactedEndpointDiagnostic(failureEndpoint)
      let configuration = try KaibaClientConfiguration(
        transportSecurity: options.allowInsecureHTTP ? .allowInsecureRemoteHTTP : .secureByDefault,
        allowRemoteUnauthenticated: options.allowRemoteUnauthenticated
      )
      let normalizedEndpoint = try KaibaEndpoint(
        options.endpoint,
        transportSecurity: configuration.transportSecurity
      )
      let diagnosticEndpoint = normalizedEndpoint.diagnosticDescription(authentication: authentication)
      failureEndpoint = diagnosticEndpoint
      let schema = try await makeClient(options.endpoint, authentication, configuration).fetchSchema()
      let selection = try schema.selecting(matching: options.filter)
      let publishedFilter = selection.filter.map { filter in
        authentication.redactedDiagnostic(filter) == filter ? filter : "<redacted>"
      }
      let output: String
      if options.output == .json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let payload = GraphQLSchemaJSONSuccess(
          endpoint: diagnosticEndpoint,
          filter: publishedFilter,
          queryFields: selection.queryFields,
          mutationFields: selection.mutationFields,
          types: selection.types
        )
        guard let rendered = String(data: try encoder.encode(payload), encoding: .utf8) else {
          throw KaibaClientError.invalidResponse(status: nil, byteCount: 0)
        }
        output = rendered
      } else {
        output = KaibaSchemaRenderer.text(selection)
      }
      return GraphQLSchemaCommandResult(standardOutput: output, exitCode: 0)
    } catch {
      return failure(error, output: options.output, endpoint: failureEndpoint)
    }
  }

  private static func failure(
    _ error: Error,
    output: GraphQLSchemaOutputMode,
    endpoint: String
  ) -> GraphQLSchemaCommandResult {
    let code: String
    let message: String
    let nextAction: String
    let exitCode: Int32
    switch error {
    case let error as GraphQLSchemaCommandError:
      code = error.description.components(separatedBy: ":").first ?? "invalid_usage"
      message = messageWithoutCode(error.description, code: code)
      nextAction = code == "missing_credential"
        ? nextActionFor(code: code)
        : "Correct the command arguments and retry."
      exitCode = 2
    case let error as KaibaClientError:
      code = error.code
      message = runtimeMessageFor(code: code)
        ?? messageWithoutCode(error.description, code: code)
      nextAction = nextActionFor(code: code)
      exitCode = ["invalid_endpoint", "invalid_configuration", "invalid_request", "invalid_regex"]
        .contains(code) ? 2 : 1
    default:
      code = "connection_failed"
      message = "Kaiba could not reach the configured endpoint."
      nextAction = nextActionFor(code: code)
      exitCode = 1
    }
    let diagnostic: String
    if output == .json {
      let object: [String: String] = [
        "code": code,
        "endpoint": endpoint,
        "message": message,
        "nextAction": nextAction,
        "status": "error"
      ]
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      diagnostic = (try? encoder.encode(object)).flatMap {
        String(data: $0, encoding: .utf8)
      } ?? "{\"status\":\"error\"}"
    } else {
      diagnostic = "\(code): \(sentence(message)) \(nextAction)"
    }
    return GraphQLSchemaCommandResult(standardError: diagnostic, exitCode: exitCode)
  }

  private static func messageWithoutCode(_ description: String, code: String) -> String {
    let prefix = "\(code): "
    return description.hasPrefix(prefix) ? String(description.dropFirst(prefix.count)) : description
  }

  private static func runtimeMessageFor(code: String) -> String? {
    switch code {
    case "auth_failed": "Kaiba rejected the configured credential."
    case "connection_failed": "Kaiba could not reach the configured endpoint."
    case "http_failed": "Kaiba returned an unsuccessful HTTP response."
    case "invalid_response": "Kaiba returned an invalid GraphQL response."
    case "schema_unavailable": "Schema introspection is unavailable or invalid."
    default: nil
    }
  }

  private static func sentence(_ value: String) -> String {
    value.hasSuffix(".") ? value : "\(value)."
  }

  private static func nextActionFor(code: String) -> String {
    switch code {
    case "auth_failed", "missing_credential": "Check the API key environment variable and endpoint, then retry."
    case "connection_failed": "Check the endpoint and network path, then retry."
    case "http_failed": "Check the Kaiba server status and endpoint, then retry."
    case "invalid_response": "Verify the endpoint targets a compatible Kaiba GraphQL server."
    case "schema_unavailable": "Enable authenticated introspection or update the server."
    default: "Correct the configuration and retry."
    }
  }

  private static func redactedEndpoint(_ endpoint: URL) -> String {
    guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
      return "<invalid-endpoint>"
    }
    components.user = nil
    components.password = nil
    components.query = nil
    components.fragment = nil
    guard let sanitized = components.string else {
      return "<invalid-endpoint>"
    }
    return KaibaAuthentication.unauthenticated.redactedEndpointDiagnostic(sanitized)
  }

  private static func requestedOutputMode(in arguments: [String]) -> GraphQLSchemaOutputMode {
    for index in arguments.indices where arguments[index] == "--output" {
      let valueIndex = arguments.index(after: index)
      if valueIndex < arguments.endIndex, arguments[valueIndex] == GraphQLSchemaOutputMode.json.rawValue {
        return .json
      }
    }
    return .text
  }

  private static func requestedEndpointDescription(
    in arguments: [String],
    environment: [String: String]
  ) -> String {
    guard let index = arguments.firstIndex(of: "--endpoint") else {
      return "<invalid-endpoint>"
    }
    let valueIndex = arguments.index(after: index)
    guard valueIndex < arguments.endIndex,
          !arguments[valueIndex].hasPrefix("--"),
          let endpoint = URL(string: arguments[valueIndex]) else {
      return "<invalid-endpoint>"
    }
    var endpointDescription = redactedEndpoint(endpoint)
    for apiKeyIndex in arguments.indices where arguments[apiKeyIndex] == "--api-key-env" {
      let nameIndex = arguments.index(after: apiKeyIndex)
      guard nameIndex < arguments.endIndex,
            arguments[nameIndex].range(
              of: #"^[A-Za-z_][A-Za-z0-9_]*$"#,
              options: .regularExpression
            ) != nil else {
        return "<redacted-endpoint>"
      }
      guard let value = environment[arguments[nameIndex]], !value.isEmpty else {
        continue
      }
      guard let token = try? KaibaBearerToken(value) else {
        return "<redacted-endpoint>"
      }
      endpointDescription = KaibaAuthentication.bearer(token)
        .redactedEndpointDiagnostic(endpointDescription)
    }
    return endpointDescription
  }
}
