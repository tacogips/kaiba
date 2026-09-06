import Foundation
import Testing
@testable import KaibaCLIKit
import KaibaClient

private struct SchemaFetcher: KaibaSchemaFetching {
  let schema: KaibaGraphQLSchema
  func fetchSchema() async throws -> KaibaGraphQLSchema { schema }
}

private struct FailingSchemaFetcher: KaibaSchemaFetching {
  let error: KaibaClientError
  func fetchSchema() async throws -> KaibaGraphQLSchema { throw error }
}

private struct RuntimeFailureExpectation {
  let error: KaibaClientError
  let code: String
  let message: String
  let nextAction: String
}

private actor CommandSchemaTransport: KaibaHTTPTransporting {
  let body: Data

  init(body: Data) {
    self.body = body
  }

  func send(_ request: KaibaHTTPRequest, maximumResponseBytes: Int) async throws -> KaibaHTTPResponse {
    KaibaHTTPResponse(statusCode: 200, body: body)
  }
}

private final class SchemaClientFactoryCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  func increment() {
    lock.lock()
    count += 1
    lock.unlock()
  }

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
}

@Suite("GraphQLSchemaCommand")
struct GraphQLSchemaCommandTests {
  @Test func executableSchemaRoutingIgnoresAmbientKaibaConfiguration() throws {
    let result = try runKaiba(arguments: [
      "graphql", "schema", "--endpoint", "http://127.0.0.1:1",
      "--allow-unauthenticated", "--filter", "[", "--output", "json"
    ], environmentUpdates: [
      "KAIBA_CONFIG_PATH": FileManager.default.currentDirectoryPath
        + "/tmp/missing-schema-routing-config.yml"
    ])
    #expect(result.exitCode == 2)
    #expect(result.standardOutput.isEmpty)
    #expect(result.standardError.contains(#""code" : "invalid_regex""#))
    #expect(!result.standardError.contains("missing-schema-routing-config"))
  }

  @Test(arguments: [
    ["--unknown"],
    ["--endpoint", "http://other.test"],
    ["--filter"],
    ["--api-key-env", "KEY"]
  ])
  func executableUsageFailuresPreserveRequestedJSONOutput(extraArguments: [String]) throws {
    let result = try runKaiba(arguments: [
      "graphql", "schema", "--endpoint", "http://localhost",
      "--allow-unauthenticated", "--output", "json"
    ] + extraArguments)
    #expect(result.exitCode == 2)
    #expect(result.standardOutput.isEmpty)
    #expect(result.standardError.contains(#""status" : "error""#))
    #expect(result.standardError.contains(#""code" : "invalid_usage""#))
    #expect(result.standardError.contains(#""endpoint" : "http://localhost""#))
  }

  @Test func executableMissingEndpointPreservesRequestedJSONOutput() throws {
    let result = try runKaiba(arguments: [
      "graphql", "schema", "--allow-unauthenticated", "--output", "json"
    ])
    #expect(result.exitCode == 2)
    #expect(result.standardOutput.isEmpty)
    #expect(result.standardError.contains(#""status" : "error""#))
    #expect(result.standardError.contains(#""code" : "invalid_usage""#))
    #expect(result.standardError.contains(#""endpoint" : "<invalid-endpoint>""#))
  }

  @Test(arguments: [
    ["--config"],
    ["--note-root"],
    ["--config", "first.yml", "--config", "second.yml"],
    ["--note-root", "tmp/first", "--note-root", "tmp/second"]
  ])
  func executableGlobalOptionFailuresPreserveRequestedJSONOutput(
    globalArguments: [String]
  ) throws {
    let result = try runKaiba(arguments: [
      "graphql", "schema", "--endpoint", "http://localhost",
      "--allow-unauthenticated", "--output", "json"
    ] + globalArguments)
    #expect(result.exitCode == 2)
    #expect(result.standardOutput.isEmpty)
    #expect(result.standardError.contains(#""status" : "error""#))
    #expect(result.standardError.contains(#""code" : "invalid_usage""#))
  }

  @Test func executableDoesNotRouteArbitraryGraphqlValueToSchema() throws {
    let result = try runKaiba(arguments: [
      "search", "graphql", "schema", "--endpoint", "http://127.0.0.1:1",
      "--allow-unauthenticated"
    ])
    #expect(!result.standardError.contains("connection_failed"))
    #expect(!result.standardOutput.contains("connection_failed"))
  }

  @Test func executableFindsGraphqlCommandAfterGlobalValueNamedGraphql() throws {
    let result = try runKaiba(arguments: [
      "--note-root", "graphql", "graphql", "schema",
      "--endpoint", "http://127.0.0.1:1", "--allow-unauthenticated",
      "--filter", "[", "--output", "json"
    ])
    #expect(result.exitCode == 2)
    #expect(result.standardOutput.isEmpty)
    #expect(result.standardError.contains(#""code" : "invalid_regex""#))
  }

  @Test(arguments: ["serve", "-h"])
  func executableSchemaRoutingIgnoresFilterValuesThatLookLikeCommandsOrHelp(
    filter: String
  ) throws {
    let result = try runKaiba(arguments: [
      "graphql", "schema", "--endpoint", "http://127.0.0.1:1",
      "--allow-unauthenticated", "--filter", filter, "--output", "json"
    ])
    #expect(result.exitCode == 1)
    #expect(result.standardOutput.isEmpty)
    #expect(result.standardError.contains(#""code" : "connection_failed""#))
    #expect(!result.standardError.contains("unknown serve argument"))
    #expect(!result.standardError.contains("Usage:"))
  }

  @Test func invalidOutputValueDoesNotSelectJSONFailureRendering() async {
    let result = await GraphQLSchemaCommand.run(arguments: [
      "--endpoint", "http://localhost", "--allow-unauthenticated", "--output", "yaml"
    ])
    #expect(result.exitCode == 2)
    #expect(result.standardOutput.isEmpty)
    #expect(result.standardError.hasPrefix("invalid_usage:"))
  }

  @Test func parserFailureEndpointRedactsUnsafeURLComponents() async {
    let result = await GraphQLSchemaCommand.run(arguments: [
      "--endpoint", "https://user:password@example.com/root?token=secret#fragment",
      "--allow-unauthenticated", "--output", "json", "--unknown"
    ])
    #expect(result.exitCode == 2)
    #expect(result.standardError.contains(#""endpoint" : "https://example.com/<redacted>""#))
    #expect(!result.standardError.contains("user"))
    #expect(!result.standardError.contains("password"))
    #expect(!result.standardError.contains("secret"))
    #expect(!result.standardError.contains("fragment"))
  }

  @Test(arguments: [GraphQLSchemaOutputMode.text, .json])
  func customEndpointPathIsOpaqueAcrossSuccessAndFailurePaths(
    outputMode: GraphQLSchemaOutputMode
  ) async throws {
    let pathCredential = "path-api-secret"
    let bearerArguments = [
      "--endpoint", "https://example.com/\(pathCredential)",
      "--api-key-env", "KAIBA_API_KEY", "--output", outputMode.rawValue
    ]
    let environment = ["KAIBA_API_KEY": "different-header-secret"]
    let schema = try KaibaGraphQLSchema.parseSDL("type Query { value: String }")
    let results = [
      await GraphQLSchemaCommand.run(
        arguments: bearerArguments,
        environment: environment,
        makeClient: { _, _, _ in SchemaFetcher(schema: schema) }
      ),
      await GraphQLSchemaCommand.run(
        arguments: bearerArguments,
        environment: environment,
        makeClient: { _, _, _ in FailingSchemaFetcher(error: .connectionFailed(-1001)) }
      ),
      await GraphQLSchemaCommand.run(
        arguments: bearerArguments + ["--filter", "["],
        environment: environment,
        makeClient: { _, _, _ in SchemaFetcher(schema: schema) }
      ),
      await GraphQLSchemaCommand.run(
        arguments: bearerArguments + ["--unknown"],
        environment: environment,
        makeClient: { _, _, _ in SchemaFetcher(schema: schema) }
      ),
      await GraphQLSchemaCommand.run(
        arguments: [
          "--endpoint", "https://example.com/\(pathCredential)",
          "--allow-unauthenticated", "--allow-remote-unauthenticated",
          "--output", outputMode.rawValue
        ],
        makeClient: { _, _, _ in SchemaFetcher(schema: schema) }
      )
    ]

    #expect(results.map(\.exitCode) == [0, 1, 2, 2, 0])
    for result in results {
      #expect(!result.standardOutput.contains(pathCredential))
      #expect(!result.standardError.contains(pathCredential))
      if outputMode == .json {
        #expect((result.standardOutput + result.standardError).contains("https://example.com/<redacted>"))
      }
    }
  }

  @Test func duplicateCredentialOptionsRedactEveryResolvedEnvironmentValue() async {
    let result = await GraphQLSchemaCommand.run(
      arguments: [
        "--endpoint", "https://example.com/beta-sentinel",
        "--api-key-env", "KEY1", "--api-key-env", "KEY2", "--output", "json"
      ],
      environment: ["KEY1": "alpha-sentinel", "KEY2": "beta-sentinel"]
    )
    #expect(result.exitCode == 2)
    #expect(result.standardOutput.isEmpty)
    #expect(result.standardError.contains(#""code" : "invalid_usage""#))
    #expect(result.standardError.contains(#""endpoint" : "https://example.com/<redacted>""#))
    #expect(!result.standardError.contains("alpha-sentinel"))
    #expect(!result.standardError.contains("beta-sentinel"))
  }

  @Test(arguments: [GraphQLSchemaOutputMode.text, .json])
  func credentialBearingUnknownArgumentsAreNotEchoed(
    outputMode: GraphQLSchemaOutputMode
  ) async {
    for unknownArgument in ["beta-sentinel", "--beta-sentinel"] {
      let result = await GraphQLSchemaCommand.run(
        arguments: [
          "--endpoint", "https://example.com", "--api-key-env", "KEY",
          unknownArgument, "--output", outputMode.rawValue
        ],
        environment: ["KEY": "beta-sentinel"]
      )
      #expect(result.exitCode == 2)
      #expect(result.standardOutput.isEmpty)
      #expect(result.standardError.contains("invalid_usage"))
      #expect(result.standardError.contains("unknown argument"))
      #expect(!result.standardError.contains("beta-sentinel"))
    }
  }

  @Test func parsesAndRunsJSONOutput() async throws {
    let options = try GraphQLSchemaCommand.parse(arguments: [
      "--endpoint", "https://example.com", "--api-key-env", "KAIBA_API_KEY", "--output", "json"
    ])
    let schema = try KaibaGraphQLSchema.parseSDL("type Query { notes: String! }")
    let result = await GraphQLSchemaCommand.run(
      options,
      environment: ["KAIBA_API_KEY": "secret"],
      makeClient: { _, _, _ in SchemaFetcher(schema: schema) }
    )
    #expect(result.exitCode == 0)
    #expect(result.standardError.isEmpty)
    #expect(result.standardOutput.contains(#""filter" : null"#))
    #expect(result.standardOutput.contains(#""status" : "ok""#))
    #expect(result.standardOutput.contains(#""endpoint" : "https://example.com/graphql""#))
    #expect(!result.standardOutput.contains(#""description" : null"#))
  }

  @Test func credentialBearingFilterIsAppliedButNotPublishedOrReflected() async throws {
    let credential = "sentinelFilterCredential"
    let credentialSubstring = "FilterCredential"
    let options = try GraphQLSchemaCommand.parse(arguments: [
      "--endpoint", "https://example.com", "--api-key-env", "KAIBA_API_KEY",
      "--filter", "^Query\\.notes$|\(credential)|\(credentialSubstring)", "--output", "json"
    ])
    let schema = try KaibaGraphQLSchema.parseSDL("type Query { notes: String! zeta: String } ")
    let result = await GraphQLSchemaCommand.run(
      options,
      environment: ["KAIBA_API_KEY": credential],
      makeClient: { _, _, _ in SchemaFetcher(schema: schema) }
    )

    #expect(result.exitCode == 0)
    #expect(result.standardError.isEmpty)
    #expect(result.standardOutput.contains(#""filter" : "<redacted>""#))
    #expect(result.standardOutput.contains(#""name" : "notes""#))
    #expect(!result.standardOutput.contains(#""name" : "zeta""#))

    var dumped = ""
    dump(result, to: &dumped)
    let reflectedChildren = Mirror(reflecting: result).children.map {
      String(reflecting: $0.value)
    }
    let publishedRepresentations = [
      result.standardOutput,
      result.standardError,
      String(describing: result),
      String(reflecting: result),
      dumped
    ] + reflectedChildren
    for representation in publishedRepresentations {
      #expect(!representation.contains(credential))
      #expect(!representation.contains(credentialSubstring))
    }
  }

  @Test func invalidRegexUsesSelectedJSONRendererWithoutCreatingClient() async throws {
    let counter = SchemaClientFactoryCounter()
    let options = try GraphQLSchemaCommand.parse(arguments: [
      "--endpoint", "https://example.com", "--allow-unauthenticated",
      "--allow-remote-unauthenticated", "--filter", "[", "--output", "json"
    ])
    let result = await GraphQLSchemaCommand.run(options, makeClient: { _, _, _ in
      counter.increment()
      throw KaibaClientError.connectionFailed(nil)
    })
    #expect(result.exitCode == 2)
    #expect(result.standardOutput.isEmpty)
    #expect(result.standardError.contains(#""status" : "error""#))
    #expect(result.standardError.contains(#""code" : "invalid_regex""#))
    #expect(counter.value == 0)
  }

  @Test func earlyFailuresKeepCustomEndpointPathsOpaque() async {
    let endpoint = "https://example.com/private/tenant/path"
    let counter = SchemaClientFactoryCounter()
    let missingCredential = await GraphQLSchemaCommand.run(
      arguments: [
        "--endpoint", endpoint, "--api-key-env", "KAIBA_DEFINITELY_UNSET", "--output", "json"
      ],
      environment: [:],
      makeClient: { _, _, _ in
        counter.increment()
        throw KaibaClientError.connectionFailed(nil)
      }
    )
    let invalidRegex = await GraphQLSchemaCommand.run(
      arguments: [
        "--endpoint", endpoint, "--allow-unauthenticated", "--allow-remote-unauthenticated",
        "--filter", "[", "--output", "json"
      ],
      environment: [:],
      makeClient: { _, _, _ in
        counter.increment()
        throw KaibaClientError.connectionFailed(nil)
      }
    )

    for (result, code) in [(missingCredential, "missing_credential"), (invalidRegex, "invalid_regex")] {
      #expect(result.exitCode == 2)
      #expect(result.standardOutput.isEmpty)
      #expect(result.standardError.contains(#""endpoint" : "https://example.com/<redacted>""#))
      #expect(result.standardError.contains(#""code" : "\#(code)""#))
      #expect(!result.standardError.contains("private/tenant/path"))
    }
    #expect(counter.value == 0)
  }

  @Test func rejectsRemoteUnauthenticatedOverrideWithBearerMode() {
    #expect(throws: GraphQLSchemaCommandError.self) {
      try GraphQLSchemaCommand.parse(arguments: [
        "--endpoint", "https://example.com",
        "--api-key-env", "KAIBA_API_KEY",
        "--allow-remote-unauthenticated"
      ])
    }
  }

  @Test func missingCredentialUsesExactCredentialRecoveryInTextAndJSON() async throws {
    let baseArguments = [
      "--endpoint", "https://example.com", "--api-key-env", "KAIBA_API_KEY"
    ]
    let text = await GraphQLSchemaCommand.run(arguments: baseArguments, environment: [:])
    #expect(text == GraphQLSchemaCommandResult(
      standardError: "missing_credential: environment variable KAIBA_API_KEY is empty or unset. "
        + "Check the API key environment variable and endpoint, then retry.",
      exitCode: 2
    ))

    let json = await GraphQLSchemaCommand.run(
      arguments: baseArguments + ["--output", "json"],
      environment: [:]
    )
    #expect(json == GraphQLSchemaCommandResult(
      standardError: """
      {
        "code" : "missing_credential",
        "endpoint" : "https://example.com",
        "message" : "environment variable KAIBA_API_KEY is empty or unset",
        "nextAction" : "Check the API key environment variable and endpoint, then retry.",
        "status" : "error"
      }
      """,
      exitCode: 2
    ))
  }

  @Test(arguments: [GraphQLSchemaOutputMode.text, .json])
  func schemaCommandNeverPrintsCredentialBearingMetadata(
    outputMode: GraphQLSchemaOutputMode
  ) async throws {
    let tokenValue = "sentinelSchemaToken"
    let authorizationValue = "sentinel-authorization-value"
    let schema = try KaibaGraphQLSchema(
      queryFields: [KaibaSchemaField(
        name: "legacy",
        description: "bearer \(tokenValue)",
        type: .named(kind: .scalar, name: "String"),
        isDeprecated: true,
        deprecationReason: "Authorization: Bearer \(authorizationValue)"
      )],
      types: [KaibaSchemaType(kind: .scalar, name: "String")]
    )
    let envelope = KaibaJSONValue.object(["data": schema.introspectionData()])
    let transport = CommandSchemaTransport(body: try JSONEncoder().encode(envelope))
    let arguments = [
      "--endpoint", "https://example.com", "--api-key-env", "KAIBA_API_KEY",
      "--output", outputMode.rawValue
    ]
    let result = await GraphQLSchemaCommand.run(
      arguments: arguments,
      environment: ["KAIBA_API_KEY": tokenValue],
      makeClient: { endpoint, authentication, configuration in
        try KaibaClient(
          endpoint: endpoint,
          authentication: authentication,
          configuration: configuration,
          transport: transport
        )
      }
    )
    #expect(result.exitCode == 0)
    #expect(result.standardError.isEmpty)
    #expect(result.standardOutput.contains("<redacted>"))
    for output in [result.standardOutput, result.standardError] {
      #expect(!output.contains(tokenValue))
      #expect(!output.contains(authorizationValue))
      #expect(!output.localizedCaseInsensitiveContains("Authorization: Bearer"))
    }
  }

  @Test(arguments: [GraphQLSchemaOutputMode.text, .json])
  func schemaCommandRejectsCredentialBearingIdentifiersWithoutPrintingThem(
    outputMode: GraphQLSchemaOutputMode
  ) async throws {
    let tokenValue = "sentinelSchemaToken"
    let schema = try KaibaGraphQLSchema(
      queryFields: [KaibaSchemaField(
        name: tokenValue,
        type: .named(kind: .scalar, name: "String")
      )],
      types: [KaibaSchemaType(kind: .scalar, name: "String")]
    )
    let envelope = KaibaJSONValue.object(["data": schema.introspectionData()])
    let transport = CommandSchemaTransport(body: try JSONEncoder().encode(envelope))
    let result = await GraphQLSchemaCommand.run(
      arguments: [
        "--endpoint", "https://example.com", "--api-key-env", "KAIBA_API_KEY",
        "--output", outputMode.rawValue
      ],
      environment: ["KAIBA_API_KEY": tokenValue],
      makeClient: { endpoint, authentication, configuration in
        try KaibaClient(
          endpoint: endpoint,
          authentication: authentication,
          configuration: configuration,
          transport: transport
        )
      }
    )
    #expect(result.exitCode == 1)
    #expect(result.standardOutput.isEmpty)
    #expect(result.standardError.contains("schema_unavailable"))
    #expect(!result.standardError.contains(tokenValue))
  }

  @Test(arguments: [GraphQLSchemaOutputMode.text, .json])
  func schemaCommandRedactsTheActiveTokenFromEndpointDiagnostics(
    outputMode: GraphQLSchemaOutputMode
  ) async throws {
    let examples = [
      (token: "sentinel-endpoint?/token", encodedPath: "sentinel-endpoint%3F%2ftoken"),
      (token: "sentinel-unreserved-token", encodedPath: "%73entinel-unreserved-token")
    ]
    let schema = try KaibaGraphQLSchema.parseSDL("type Query { value: String }")
    for example in examples {
      let arguments = [
        "--endpoint", "https://example.com/\(example.encodedPath)",
        "--api-key-env", "KAIBA_API_KEY", "--output", outputMode.rawValue
      ]
      let success = await GraphQLSchemaCommand.run(
        arguments: arguments,
        environment: ["KAIBA_API_KEY": example.token],
        makeClient: { _, _, _ in SchemaFetcher(schema: schema) }
      )
      #expect(success.exitCode == 0)
      assertEndpointCredentialAbsent(example, from: success)
      if outputMode == .json {
        #expect(success.standardOutput.contains("https://example.com/<redacted>"))
      }

      let failure = await GraphQLSchemaCommand.run(
        arguments: arguments,
        environment: ["KAIBA_API_KEY": example.token],
        makeClient: { _, _, _ in FailingSchemaFetcher(error: .connectionFailed(-1001)) }
      )
      #expect(failure.exitCode == 1)
      assertEndpointCredentialAbsent(example, from: failure)
      if outputMode == .json {
        #expect(failure.standardError.contains("https://example.com/<redacted>"))
      }

      let localFailure = await GraphQLSchemaCommand.run(
        arguments: arguments + ["--filter", "["],
        environment: ["KAIBA_API_KEY": example.token],
        makeClient: { _, _, _ in SchemaFetcher(schema: schema) }
      )
      #expect(localFailure.exitCode == 2)
      assertEndpointCredentialAbsent(example, from: localFailure)
      if outputMode == .json {
        #expect(localFailure.standardError.contains("https://example.com/<redacted>"))
      }
    }
  }

  private func assertEndpointCredentialAbsent(
    _ example: (token: String, encodedPath: String),
    from result: GraphQLSchemaCommandResult
  ) {
    #expect(!result.standardOutput.contains(example.token))
    #expect(!result.standardError.contains(example.token))
    #expect(!result.standardOutput.contains(example.encodedPath))
    #expect(!result.standardError.contains(example.encodedPath))
  }

  @Test func rejectsCompleteInvalidArgumentMatrix() {
    let invalidArguments: [[String]] = [
      [],
      ["--endpoint", "https://example.com"],
      ["--endpoint", "https://example.com", "--allow-unauthenticated", "--api-key-env", "KEY"],
      ["--endpoint", "https://example.com", "--allow-unauthenticated", "--endpoint", "https://other.test"],
      ["--endpoint", "https://example.com", "--allow-unauthenticated", "--allow-unauthenticated"],
      ["--endpoint", "https://example.com", "--api-key-env"],
      ["--endpoint", "https://example.com", "--api-key-env", "9INVALID"],
      ["--endpoint", "https://example.com", "--api-key-env", "KEY", "--output", "yaml"],
      ["--endpoint", "https://example.com", "--api-key-env", "KEY", "--unknown"],
      ["--endpoint", "https://example.com", "--api-key-env", "KEY", "positional"]
    ]
    for arguments in invalidArguments {
      #expect(throws: (any Error).self) {
        try GraphQLSchemaCommand.parse(arguments: arguments)
      }
    }
  }

  @Test func localFailuresCreateNoClient() async throws {
    let counter = SchemaClientFactoryCounter()
    let options = try GraphQLSchemaCommand.parse(arguments: [
      "--endpoint", "https://example.com", "--api-key-env", "KAIBA_API_KEY"
    ])
    for environment in [[:], ["KAIBA_API_KEY": ""]] {
      let result = await GraphQLSchemaCommand.run(
        options,
        environment: environment,
        makeClient: { _, _, _ in
          counter.increment()
          throw KaibaClientError.connectionFailed(nil)
        }
      )
      #expect(result.exitCode == 2)
      #expect(result.standardOutput.isEmpty)
    }
    #expect(counter.value == 0)
  }

  @Test(arguments: [
    "http://localhost:",
    "http://[::1]:",
    "https://example.com:0",
    "https://example.com:65536",
    "https://example.com:999999999999999999999",
    "https://example.com:alphabetic",
    "https://example.com/%00",
    "https://example.com/a%0Ab"
  ])
  func invalidEndpointsExitTwoBeforeClientCreation(rawValue: String) async {
    let counter = SchemaClientFactoryCounter()
    let result = await GraphQLSchemaCommand.run(
      arguments: [
        "--endpoint", rawValue, "--allow-unauthenticated",
        "--allow-remote-unauthenticated", "--output", "json"
      ],
      makeClient: { _, _, _ in
        counter.increment()
        throw KaibaClientError.connectionFailed(nil)
      }
    )
    #expect(result.exitCode == 2)
    #expect(result.standardOutput.isEmpty)
    #expect(result.standardError.contains(#""status" : "error""#))
    #expect(result.standardError.contains(#""code" : "invalid_endpoint""#))
    #expect(counter.value == 0)
  }

  @Test func rendersStableTextFilteredJSONAndEmptyOutput() async throws {
    let schema = try KaibaGraphQLSchema.parseSDL("""
    type Query { zeta: Thing notes: String! }
    type Thing { z: String a: String }
    """)
    let textOptions = try GraphQLSchemaCommand.parse(arguments: [
      "--endpoint", "http://localhost", "--allow-unauthenticated"
    ])
    let text = await GraphQLSchemaCommand.run(
      textOptions,
      makeClient: { _, _, _ in SchemaFetcher(schema: schema) }
    )
    #expect(text == GraphQLSchemaCommandResult(
      standardOutput: """
      type Query {
        notes: String!
        zeta: Thing
      }

      type Thing {
        a: String
        z: String
      }

      scalar String
      """,
      exitCode: 0
    ))

    let jsonOptions = try GraphQLSchemaCommand.parse(arguments: [
      "--endpoint", "http://localhost", "--allow-unauthenticated",
      "--filter", "^Query\\.notes$", "--output", "json"
    ])
    let json = await GraphQLSchemaCommand.run(
      jsonOptions,
      makeClient: { _, _, _ in SchemaFetcher(schema: schema) }
    )
    #expect(json.exitCode == 0)
    #expect(json.standardError.isEmpty)
    #expect(json.standardOutput.contains(#""filter" : "^Query\\.notes$""#))
    #expect(json.standardOutput.contains(#""name" : "notes""#))
    #expect(!json.standardOutput.contains(#""name" : "zeta""#))

    var noMatchOptions = textOptions
    noMatchOptions.filter = "does-not-match"
    let noMatch = await GraphQLSchemaCommand.run(
      noMatchOptions,
      makeClient: { _, _, _ in SchemaFetcher(schema: schema) }
    )
    #expect(noMatch.standardOutput == "# No schema elements matched.")
    #expect(noMatch.exitCode == 0)
  }

  @Test func mapsRuntimeFailuresToStableChannelsCodesAndExits() async throws {
    let failures = [
      RuntimeFailureExpectation(
        error: .authFailed(401), code: "auth_failed",
        message: "Kaiba rejected the configured credential.",
        nextAction: "Check the API key environment variable and endpoint, then retry."
      ),
      RuntimeFailureExpectation(
        error: .authFailed(403), code: "auth_failed",
        message: "Kaiba rejected the configured credential.",
        nextAction: "Check the API key environment variable and endpoint, then retry."
      ),
      RuntimeFailureExpectation(
        error: .connectionFailed(-1001), code: "connection_failed",
        message: "Kaiba could not reach the configured endpoint.",
        nextAction: "Check the endpoint and network path, then retry."
      ),
      RuntimeFailureExpectation(
        error: .httpFailed(503), code: "http_failed",
        message: "Kaiba returned an unsuccessful HTTP response.",
        nextAction: "Check the Kaiba server status and endpoint, then retry."
      ),
      RuntimeFailureExpectation(
        error: .invalidResponse(status: 200, byteCount: 19), code: "invalid_response",
        message: "Kaiba returned an invalid GraphQL response.",
        nextAction: "Verify the endpoint targets a compatible Kaiba GraphQL server."
      ),
      RuntimeFailureExpectation(
        error: .schemaUnavailable("sentinel-schema-secret\nAuthorization: Bearer hidden"),
        code: "schema_unavailable", message: "Schema introspection is unavailable or invalid.",
        nextAction: "Enable authenticated introspection or update the server."
      )
    ]
    let base = try GraphQLSchemaCommand.parse(arguments: [
      "--endpoint", "https://example.com", "--api-key-env", "KAIBA_API_KEY", "--output", "json"
    ])
    for failure in failures {
      let json = await GraphQLSchemaCommand.run(
        base,
        environment: ["KAIBA_API_KEY": "sentinel-token"],
        makeClient: { _, _, _ in FailingSchemaFetcher(error: failure.error) }
      )
      #expect(json == GraphQLSchemaCommandResult(
        standardError: """
        {
          "code" : "\(failure.code)",
          "endpoint" : "https://example.com/graphql",
          "message" : "\(failure.message)",
          "nextAction" : "\(failure.nextAction)",
          "status" : "error"
        }
        """,
        exitCode: 1
      ))
      var textOptions = base
      textOptions.output = .text
      let text = await GraphQLSchemaCommand.run(
        textOptions,
        environment: ["KAIBA_API_KEY": "sentinel-token"],
        makeClient: { _, _, _ in FailingSchemaFetcher(error: failure.error) }
      )
      #expect(text == GraphQLSchemaCommandResult(
        standardError: "\(failure.code): \(failure.message) \(failure.nextAction)",
        exitCode: 1
      ))
    }
  }

  @Test func enforcesIndependentRemotePoliciesAndRedactsUnsafeEndpointParts() async throws {
    let remoteUnauthenticated = try GraphQLSchemaCommand.parse(arguments: [
      "--endpoint", "https://example.com", "--allow-unauthenticated"
    ])
    let denied = await GraphQLSchemaCommand.run(
      remoteUnauthenticated,
      makeClient: { endpoint, authentication, configuration in
        try KaibaClient(
          endpoint: endpoint,
          authentication: authentication,
          configuration: configuration
        )
      }
    )
    #expect(denied.exitCode == 2)

    let allowed = try GraphQLSchemaCommand.parse(arguments: [
      "--endpoint", "http://example.com", "--allow-unauthenticated",
      "--allow-remote-unauthenticated", "--allow-insecure-http"
    ])
    let schema = try KaibaGraphQLSchema.parseSDL("type Query { value: String }")
    #expect(await GraphQLSchemaCommand.run(
      allowed,
      makeClient: { _, _, _ in SchemaFetcher(schema: schema) }
    ).exitCode == 0)

    let unsafe = GraphQLSchemaCommand.Options(
      endpoint: URL(string: "https://sentinel-user:sentinel-pass@example.com/graphql?token=sentinel-query")!,
      apiKeyEnvironmentVariable: "KEY",
      output: .json
    )
    let redacted = await GraphQLSchemaCommand.run(unsafe, environment: ["KEY": "sentinel-token"])
    #expect(redacted.exitCode == 2)
    #expect(!redacted.standardError.contains("sentinel-user"))
    #expect(!redacted.standardError.contains("sentinel-pass"))
    #expect(!redacted.standardError.contains("sentinel-query"))
    #expect(!redacted.standardError.contains("sentinel-token"))
  }

  @Test func routesOnlySchemaAsTheFirstGraphQLArgument() {
    #expect(GraphQLSchemaCommand.isSchemaSubcommand(arguments: ["schema", "--endpoint", "http://localhost"]))
    #expect(!GraphQLSchemaCommand.isSchemaSubcommand(arguments: ["query { schema } "]))
    #expect(!GraphQLSchemaCommand.isSchemaSubcommand(arguments: ["--variables", #"{"value":"schema"}"#]))
    #expect(!GraphQLSchemaCommand.isSchemaSubcommand(arguments: ["--operation", "schema"]))
    #expect(!GraphQLSchemaCommand.isSchemaSubcommand(arguments: []))
  }
}

private func kaibaExecutableURL() -> URL? {
  let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
#if os(macOS) && arch(arm64)
  let targetDirectory = "arm64-apple-macosx"
#elseif os(macOS)
  let targetDirectory = "x86_64-apple-macosx"
#elseif arch(arm64)
  let targetDirectory = "aarch64-unknown-linux-gnu"
#else
  let targetDirectory = "x86_64-unknown-linux-gnu"
#endif
  let packageCandidate = repositoryRoot
    .appendingPathComponent(".build")
    .appendingPathComponent(targetDirectory)
    .appendingPathComponent("debug")
    .appendingPathComponent("kaiba")
  if FileManager.default.isExecutableFile(atPath: packageCandidate.path) {
    return packageCandidate
  }
  var directory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
  while directory.path != "/" {
    let candidate = directory.appendingPathComponent("kaiba")
    if FileManager.default.isExecutableFile(atPath: candidate.path) {
      return candidate
    }
    directory.deleteLastPathComponent()
  }
  return nil
}

private func runKaiba(
  arguments: [String],
  environmentUpdates: [String: String] = [:]
) throws -> KaibaProcessResult {
  let executable = try #require(kaibaExecutableURL())
  let process = Process()
  process.executableURL = executable
  process.arguments = arguments
  var environment = ProcessInfo.processInfo.environment
  environmentUpdates.forEach { environment[$0.key] = $0.value }
  process.environment = environment
  let standardOutput = Pipe()
  let standardError = Pipe()
  process.standardOutput = standardOutput
  process.standardError = standardError
  try process.run()
  process.waitUntilExit()
  return try KaibaProcessResult(
    standardOutput: #require(String(
      data: standardOutput.fileHandleForReading.readDataToEndOfFile(),
      encoding: .utf8
    )),
    standardError: #require(String(
      data: standardError.fileHandleForReading.readDataToEndOfFile(),
      encoding: .utf8
    )),
    exitCode: process.terminationStatus
  )
}

private struct KaibaProcessResult {
  let standardOutput: String
  let standardError: String
  let exitCode: Int32
}
