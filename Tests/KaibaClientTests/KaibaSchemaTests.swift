import Foundation
import Testing
@testable import KaibaClient

private actor SchemaTransport: KaibaHTTPTransporting {
  let result: Result<KaibaHTTPResponse, KaibaClientError>
  private(set) var requestCount = 0

  init(result: Result<KaibaHTTPResponse, KaibaClientError>) {
    self.result = result
  }

  func send(_ request: KaibaHTTPRequest, maximumResponseBytes: Int) async throws -> KaibaHTTPResponse {
    requestCount += 1
    return try result.get()
  }
}

@Suite("Kaiba schema selection")
struct KaibaSchemaTests {
  @Test func synthesizesBuiltinsAndComputesForwardClosure() throws {
    let schema = try KaibaGraphQLSchema.parseSDL("""
    type Query { note(id: ID!): Note unrelated: Other }
    type Note implements Node { id: ID! state: State input: Nested }
    interface Node { id: ID! }
    type Other implements Node { id: ID! }
    input Nested { values: [String!]! }
    enum State { READY WAITING }
    """)
    let selected = try schema.selecting(matching: "Query.note$")
    #expect(selected.queryFields.map(\.name) == ["note"])
    #expect(Set(selected.types.map(\.name)) == ["ID", "Nested", "Node", "Note", "Other", "State", "String"])
    #expect(!selected.queryFields.contains { $0.name == "unrelated" })
  }

  @Test func canonicalizesShuffledMembersAndRoundTripsJSON() throws {
    let schema = try KaibaGraphQLSchema(
      queryFields: [
        KaibaSchemaField(
          name: "zeta",
          arguments: [
            KaibaSchemaInputValue(name: "z", type: .named(kind: .scalar, name: "String")),
            KaibaSchemaInputValue(name: "a", type: .named(kind: .scalar, name: "String"))
          ],
          type: .nonNull(.named(kind: .object, name: "Thing"))
        ),
        KaibaSchemaField(name: "alpha", type: .named(kind: .object, name: "Thing"))
      ],
      types: [KaibaSchemaType(
        kind: .object,
        name: "Thing",
        fields: [
          KaibaSchemaField(name: "z", type: .named(kind: .scalar, name: "String")),
          KaibaSchemaField(name: "a", type: .named(kind: .scalar, name: "String"))
        ]
      )]
    )
    #expect(schema.queryFields.map(\.name) == ["alpha", "zeta"])
    #expect(schema.queryFields[1].arguments.map(\.name) == ["a", "z"])
    #expect(schema.types.first { $0.name == "Thing" }?.fields.map(\.name) == ["a", "z"])
    let selection = try schema.selecting(matching: nil)
    let encoded = try JSONEncoder().encode(selection)
    let decoded = try JSONDecoder().decode(KaibaSchemaSelection.self, from: encoded)
    #expect(decoded == selection)
    let rendered = try KaibaSchemaRenderer.json(selection)
    #expect(rendered.contains(#""kind" : "NON_NULL""#))
    #expect(!rendered.contains(#""description" : null"#))
  }

  @Test func decodedSchemasValidateAndCanonicalizeBeforeUse() throws {
    let shuffled = #"""
    {
      "queryFields": [
        {"name":"zeta","type":{"kind":"SCALAR","name":"String"}},
        {"name":"alpha","type":{"kind":"OBJECT","name":"Thing"}}
      ],
      "mutationFields": [],
      "types": [
        {"kind":"SCALAR","name":"String"},
        {"kind":"OBJECT","name":"Thing","fields":[
          {"name":"zeta","type":{"kind":"SCALAR","name":"String"}},
          {"name":"alpha","type":{"kind":"SCALAR","name":"String"}}
        ]}
      ]
    }
    """#
    let decoded = try JSONDecoder().decode(KaibaGraphQLSchema.self, from: Data(shuffled.utf8))
    #expect(decoded.queryFields.map(\.name) == ["alpha", "zeta"])
    #expect(decoded.types.map(\.name) == ["Thing", "String"])
    #expect(decoded.types[0].fields.map(\.name) == ["alpha", "zeta"])

    let invalidSchemas = [
      #"{"queryFields":[],"types":[{"kind":"SCALAR","name":"String"},{"kind":"SCALAR","name":"String"}]}"#,
      #"{"queryFields":[{"name":"value","type":{"kind":"NON_NULL","ofType":{"kind":"NON_NULL","ofType":{"kind":"SCALAR","name":"String"}}}}],"types":[{"kind":"SCALAR","name":"String"}]}"#,
      #"{"queryFields":[],"types":[{"kind":"UNKNOWN","name":"String"}]}"#,
      #"{"queryFields":[{"name":"bad-name","type":{"kind":"SCALAR","name":"String"}}],"types":[{"kind":"SCALAR","name":"String"}]}"#,
      #"{"queryFields":[{"name":"value","type":{"kind":"OBJECT","name":"String"}}],"types":[{"kind":"SCALAR","name":"String"}]}"#,
      #"{"queryFields":[],"types":[{"kind":"SCALAR","name":"String","fields":[{"name":"value","type":{"kind":"SCALAR","name":"String"}}]}]}"#,
      #"{"queryFields":[{"name":"value","type":{"kind":"LIST","name":"String","ofType":{"kind":"SCALAR","name":"String"}}}],"types":[{"kind":"SCALAR","name":"String"}]}"#,
      #"{"queryFields":[{"name":"value","type":{"kind":"NON_NULL","name":"String","ofType":{"kind":"SCALAR","name":"String"}}}],"types":[{"kind":"SCALAR","name":"String"}]}"#,
      #"{"queryFields":[{"name":"value","type":{"kind":"SCALAR","name":"String","ofType":{"kind":"SCALAR","name":"String"}}}],"types":[{"kind":"SCALAR","name":"String"}]}"#,
      #"{"queryFields":[],"types":[{"kind":"INTERFACE","name":"Node"},{"kind":"OBJECT","name":"Thing","interfaces":["Node","Node"]}]}"#,
      #"{"queryFields":[],"types":[{"kind":"OBJECT","name":"Thing"},{"kind":"UNION","name":"Choice","possibleTypes":["Thing","Thing"]}]}"#
    ]
    for source in invalidSchemas {
      #expect(throws: (any Error).self) {
        try JSONDecoder().decode(KaibaGraphQLSchema.self, from: Data(source.utf8))
      }
    }
  }

  @Test func canonicalTypeOrderMatchesTheSchemaDiscoveryContract() throws {
    let schema = try KaibaGraphQLSchema.parseSDL("""
    interface Node { id: ID! }
    type Thing implements Node { id: ID! }
    input Filter { value: String }
    enum State { READY }
    scalar Timestamp
    union Choice = Thing
    type Query { thing: Thing }
    """)
    var distinctKinds: [KaibaSchemaTypeKind] = []
    for kind in schema.types.map(\.kind) where distinctKinds.last != kind {
      distinctKinds.append(kind)
    }
    #expect(distinctKinds == [.object, .inputObject, .enumeration, .scalar, .interface, .union])
  }

  @Test func textRendererIncludesDeterministicImplementsClauses() throws {
    let schema = try KaibaGraphQLSchema.parseSDL("""
    interface Entity { id: ID! }
    interface Node implements Entity { id: ID! }
    type Thing implements Node & Entity { id: ID! }
    type Query { thing: Thing }
    """)
    let rendered = KaibaSchemaRenderer.text(try schema.selecting(matching: nil))
    #expect(rendered.contains("type Thing implements Entity & Node {\n  id: ID!\n}"))
    #expect(rendered.contains("interface Node implements Entity {\n  id: ID!\n}"))
  }

  @Test func rejectsDanglingAndDuplicateDefinitions() {
    #expect(throws: KaibaClientError.self) {
      try KaibaGraphQLSchema.parseSDL("type Query { missing: Missing }")
    }
    #expect(throws: KaibaClientError.self) {
      try KaibaGraphQLSchema.parseSDL("type Query { value: String } type Thing { id: ID } type Thing { id: ID }")
    }
  }

  @Test func emptySelectionUsesStableText() throws {
    let schema = try KaibaGraphQLSchema.parseSDL("type Query { value: String }")
    let selection = try schema.selecting(matching: "does-not-match")
    #expect(KaibaSchemaRenderer.text(selection) == "# No schema elements matched.")
  }

  @Test func parsesAllSupportedKindsDescriptionsDeprecationsAndReferenceKinds() throws {
    let schema = try KaibaGraphQLSchema.parseSDL(#"""
    # comments and multiline definitions are accepted
    """A node contract"""
    interface Node {
      "Stable identity"
      id: ID!
    }
    "A concrete result"
    type Note implements Node {
      id: ID!
      "Legacy value"
      oldValue: String @deprecated(reason: "use value")
      value(input: Filter): State
    }
    type Other implements Node { id: ID! }
    "Search input"
    input Filter {
      "Search terms"
      terms: [String!]!
    }
    enum State {
      READY
      OLD @deprecated(reason: "retired")
    }
    union SearchResult = Note | Other
    scalar Timestamp
    type Query {
      node(id: ID!): Node
      search(filter: Filter): [SearchResult!]!
      now: Timestamp
    }
    """#)

    let note = try #require(schema.types.first { $0.name == "Note" })
    #expect(note.description == "A concrete result")
    #expect(note.interfaces == ["Node"])
    #expect(note.fields.first { $0.name == "oldValue" }?.isDeprecated == true)
    #expect(note.fields.first { $0.name == "oldValue" }?.deprecationReason == "use value")
    #expect(note.fields.first { $0.name == "value" }?.arguments.first?.type ==
      .named(kind: .inputObject, name: "Filter"))
    #expect(note.fields.first { $0.name == "value" }?.type ==
      .named(kind: .enumeration, name: "State"))
    #expect(schema.queryFields.first { $0.name == "node" }?.type ==
      .named(kind: .interface, name: "Node"))
    #expect(schema.types.first { $0.name == "Node" }?.possibleTypes == ["Note", "Other"])
    #expect(schema.types.first { $0.name == "SearchResult" }?.possibleTypes == ["Note", "Other"])
    #expect(schema.types.first { $0.name == "State" }?.enumValues.first { $0.name == "OLD" }?
      .deprecationReason == "retired")
    let rendered = KaibaSchemaRenderer.text(try schema.selecting(matching: nil))
    #expect(rendered.contains(#"oldValue: String @deprecated(reason: "use value")"#))
    #expect(rendered.contains(#"OLD @deprecated(reason: "retired")"#))
  }

  @Test func textRendererUsesJSONCompatibleEscapingForAllControls() throws {
    let reason = "quote \" slash \\ line\nreturn\rtab\tback\u{8}form\u{c}escape\u{1b}null\0"
    let schema = try KaibaGraphQLSchema(
      queryFields: [KaibaSchemaField(
        name: "old",
        type: .named(kind: .scalar, name: "String"),
        isDeprecated: true,
        deprecationReason: reason
      )],
      types: [KaibaSchemaType(kind: .scalar, name: "String")]
    )
    let rendered = KaibaSchemaRenderer.text(try schema.selecting(matching: nil))
    #expect(rendered.contains(#"quote \" slash \\ line\nreturn\rtab\tback\bform\fescape\u001Bnull\u0000"#))
    #expect(!rendered.unicodeScalars.contains { scalar in
      scalar.value != 0x0A && CharacterSet.controlCharacters.contains(scalar)
    })
  }

  @Test func validatesWrapperDepthKindsAndMalformedSDL() throws {
    let eightWrappers = "[[[[[[[[String]]]]]]]]"
    let valid = try KaibaGraphQLSchema.parseSDL("type Query { value: \(eightWrappers) }")
    #expect(valid.queryFields.first?.type.rendered == eightWrappers)

    for invalid in [
      "type Query { value: [[[[[[[[[String]]]]]]]]] }",
      "type Query { value: String } type Thing implements String { id: ID }",
      "type Query { value: Choice } union Choice = String",
      "type Query { value: String } type Query { other: String }",
      "type Query { value String }",
      "extend type Query { value: String }",
      "type Query { value: Missing }"
    ] {
      #expect(throws: KaibaClientError.self) {
        try KaibaGraphQLSchema.parseSDL(invalid)
      }
    }
  }

  @Test func selectionCoversEverySeedCategoryCyclesAndQualifiedNames() throws {
    let schema = try KaibaGraphQLSchema.parseSDL("""
    type Query { lookup(input: Input): Node }
    type Mutation { update(input: Input!): Concrete }
    interface Node { next: Node }
    type Concrete implements Node { next: Node choice: Choice state: State }
    type Alternative implements Node { next: Node }
    union Choice = Concrete | Alternative
    input Input { nested: Nested }
    input Nested { input: Input values: [String!]! }
    enum State { READY }
    """)

    #expect(try schema.selecting(matching: "^Query\\.lookup$").queryFields.map(\.name) == ["lookup"])
    #expect(try schema.selecting(matching: "^Mutation\\.update$").mutationFields.map(\.name) == ["update"])
    #expect(try schema.selecting(matching: "^Type\\.Input$").types.contains { $0.name == "Nested" })
    #expect(try schema.selecting(matching: "^State$").types.map(\.name).contains("State"))

    let closure = try schema.selecting(matching: "lookup")
    #expect(Set(closure.types.map(\.name)) == [
      "Alternative", "Choice", "Concrete", "Input", "Nested", "Node", "State", "String"
    ])
    #expect(try schema.selecting(matching: nil).queryFields == schema.queryFields)
  }

  @Test func shuffledEquivalentSchemasRenderByteIdentically() throws {
    let alpha = try KaibaGraphQLSchema(
      queryFields: [
        KaibaSchemaField(name: "z", type: .named(kind: .scalar, name: "String")),
        KaibaSchemaField(name: "a", type: .named(kind: .object, name: "Thing"))
      ],
      types: [
        KaibaSchemaType(kind: .scalar, name: "String"),
        KaibaSchemaType(kind: .object, name: "Thing", fields: [
          KaibaSchemaField(name: "z", type: .named(kind: .scalar, name: "String")),
          KaibaSchemaField(name: "a", type: .named(kind: .scalar, name: "String"))
        ])
      ]
    )
    let beta = try KaibaGraphQLSchema(
      queryFields: alpha.queryFields.reversed(),
      types: alpha.types.reversed().map { type in
        var shuffled = type
        shuffled.fields.reverse()
        return shuffled
      }
    )
    let alphaSelection = try alpha.selecting(matching: nil)
    let betaSelection = try beta.selecting(matching: nil)
    #expect(KaibaSchemaRenderer.text(alphaSelection) == KaibaSchemaRenderer.text(betaSelection))
    #expect(try KaibaSchemaRenderer.json(alphaSelection) == KaibaSchemaRenderer.json(betaSelection))
    #expect(alpha.introspectionData() == beta.introspectionData())
  }

  @Test func fetchSchemaPreservesBoundaryErrorsAndMapsSchemaFailures() async throws {
    let failures: [(Result<KaibaHTTPResponse, KaibaClientError>, String)] = [
      (.failure(.connectionFailed(-1001)), "connection_failed"),
      (.success(KaibaHTTPResponse(statusCode: 401, body: Data())), "auth_failed"),
      (.success(KaibaHTTPResponse(statusCode: 503, body: Data())), "http_failed"),
      (.success(KaibaHTTPResponse(statusCode: 200, body: Data("not-json".utf8))), "invalid_response"),
      (.success(KaibaHTTPResponse(
        statusCode: 200,
        body: Data(#"{"errors":[{"message":"disabled"}]}"#.utf8)
      )), "schema_unavailable"),
      (.success(KaibaHTTPResponse(
        statusCode: 200,
        body: Data(#"{"data":{"__schema":{"types":[]}}}"#.utf8)
      )), "schema_unavailable")
    ]
    for (result, code) in failures {
      let client = try KaibaClient(
        endpoint: URL(string: "http://localhost")!,
        authentication: .unauthenticated,
        transport: SchemaTransport(result: result)
      )
      do {
        _ = try await client.fetchSchema()
        Issue.record("expected \(code)")
      } catch let error as KaibaClientError {
        #expect(error.code == code)
      }
    }
  }

  @Test func fetchSchemaUsesCanonicalOperationAndDecodesShuffledIntrospection() async throws {
    let source = try KaibaGraphQLSchema.parseSDL("""
    type Query { z: String a: Thing }
    type Thing { z: String a: String }
    """)
    let envelope = KaibaJSONValue.object(["data": source.introspectionData()])
    let body = try JSONEncoder().encode(envelope)
    let transport = SchemaTransport(result: .success(KaibaHTTPResponse(statusCode: 200, body: body)))
    let client = try KaibaClient(
      endpoint: URL(string: "http://localhost/custom")!,
      authentication: .unauthenticated,
      transport: transport
    )
    let decoded = try await client.fetchSchema()
    #expect(decoded == source)
    #expect(await transport.requestCount == 1)
  }

  @Test func fetchSchemaSanitizesCredentialBearingSchemaMetadata() async throws {
    let tokenValue = "sentinelSchemaToken"
    let authorizationValues = [
      "bracketed-authorization-value",
      "quoted-authorization-value",
      "parenthesized-authorization-value",
      "unicode-latin-authorization-value",
      "unicode-cjk-authorization-value"
    ]
    let fieldDescription =
      "read with \"proxy_authorization\": [Bearer \(authorizationValues[0])\\] "
      + "remaining-\(authorizationValues[0])]; \"überAuthorizationHeader\" = "
      + "(Bearer \(authorizationValues[3])\\) remaining-\(authorizationValues[3]))"
    let deprecationReason =
      "\\\"proxyAuthorizationHeader\\\" = \"Bearer \(authorizationValues[1])\\\" "
      + "remaining-\(authorizationValues[1])\"; 認証AuthorizationHeader = "
      + "[Bearer \(authorizationValues[4])\\] remaining-\(authorizationValues[4])]"
    let source = try KaibaGraphQLSchema(
      queryFields: [KaibaSchemaField(
        name: "legacy",
        description: fieldDescription,
        type: .named(kind: .scalar, name: "String"),
        isDeprecated: true,
        deprecationReason: deprecationReason
      )],
      types: [KaibaSchemaType(
        kind: .scalar,
        name: "String",
        description: "owned by 'redirect_http_authorization_header': (Bearer \(authorizationValues[2])\\) remaining-\(authorizationValues[2]))"
      )]
    )
    let transport = SchemaTransport(result: .success(KaibaHTTPResponse(
      statusCode: 200,
      body: try schemaEnvelope(for: source)
    )))
    let client = try KaibaClient(
      endpoint: URL(string: "http://localhost")!,
      authentication: .bearer(try KaibaBearerToken(tokenValue)),
      transport: transport
    )

    let schema = try await client.fetchSchema()
    let field = try #require(schema.queryFields.first)
    #expect(field.description == "read with <redacted>; <redacted>")
    #expect(field.deprecationReason == "<redacted>; <redacted>")
    #expect(schema.types.first?.description == "owned by <redacted>")

    let selection = try schema.selecting(matching: nil)
    let outputs = [
      String(data: try JSONEncoder().encode(schema), encoding: .utf8) ?? "",
      KaibaSchemaRenderer.text(selection),
      try KaibaSchemaRenderer.json(selection)
    ]
    for output in outputs {
      #expect(!output.contains(tokenValue))
      for authorizationValue in authorizationValues {
        #expect(!output.contains(authorizationValue))
      }
      #expect(!output.localizedCaseInsensitiveContains("authorization"))
    }
  }

  @Test func fetchSchemaRejectsTaintedIdentifiersAndSanitizesSchemaErrors() async throws {
    let tokenValue = "sentinelSchemaToken"
    let source = try KaibaGraphQLSchema(
      queryFields: [KaibaSchemaField(
        name: tokenValue,
        type: .named(kind: .scalar, name: "String")
      )],
      types: [KaibaSchemaType(kind: .scalar, name: "String")]
    )
    let responses: [SchemaTransport] = [
      SchemaTransport(result: .success(KaibaHTTPResponse(
        statusCode: 200,
        body: try schemaEnvelope(for: source)
      ))),
      SchemaTransport(result: .failure(.schemaUnavailable(
        "Authorization: Bearer hidden \(tokenValue)"
      )))
    ]

    for transport in responses {
      let client = try KaibaClient(
        endpoint: URL(string: "http://localhost")!,
        authentication: .bearer(try KaibaBearerToken(tokenValue)),
        transport: transport
      )
      do {
        _ = try await client.fetchSchema()
        Issue.record("expected credential-safe schema rejection")
      } catch let error as KaibaClientError {
        var dumped = ""
        dump(error, to: &dumped)
        for output in [error.description, String(reflecting: error), dumped] {
          #expect(!output.contains(tokenValue))
          #expect(!output.contains("hidden"))
          #expect(!output.localizedCaseInsensitiveContains("Authorization: Bearer"))
        }
        #expect(error.code == "schema_unavailable")
      }
    }
  }

  @Test func rejectsMalformedIntrospectionShapesAndReferenceKindConflicts() throws {
    let source = try KaibaGraphQLSchema.parseSDL("type Query { value: String }")
    let base = source.introspectionData()
    let malformed = [
      updatingType(base, named: "Query") { $0["fields"] = .string("not-an-array") },
      updatingType(base, named: "Query") { $0["fields"] = .null },
      updatingType(base, named: "Query") { $0["description"] = .integer(7) },
      updatingType(base, named: "String") { $0["fields"] = .array([]) },
      updatingType(base, named: "Query") { type in
        guard case var .array(fields)? = type["fields"],
              case var .object(field) = fields[0] else { return }
        field["args"] = .string("not-an-array")
        fields[0] = .object(field)
        type["fields"] = .array(fields)
      },
      updatingType(base, named: "Query") { type in
        guard case var .array(fields)? = type["fields"],
              case var .object(field) = fields[0],
              case var .object(reference)? = field["type"] else { return }
        reference["kind"] = .string("OBJECT")
        field["type"] = .object(reference)
        fields[0] = .object(field)
        type["fields"] = .array(fields)
      }
    ]
    for value in malformed {
      #expect(value != base)
      #expect(throws: KaibaClientError.self) {
        try KaibaGraphQLSchema(introspectionData: value)
      }
    }
  }

  @Test func rejectsInvalidGraphQLNamesFromIntrospectionBeforePublication() throws {
    let source = try KaibaGraphQLSchema.parseSDL("""
    interface Node { id: ID! }
    type Thing implements Node { id: ID! state: State }
    input Filter { term: String }
    enum State { READY }
    union Result = Thing
    type Query { find(filter: Filter): Result }
    """)
    let base = source.introspectionData()
    let invalidNames = [
      ("Thing", "Bad\nType"),
      ("find", "bad\u{1B}field"),
      ("filter", "bad-argument"),
      ("term", "9input"),
      ("READY", "BAD.VALUE"),
      ("Node", "Node/Interface"),
      ("Result", "$Result")
    ]
    for (valid, invalid) in invalidNames {
      let malformed = replacingString(in: base, matching: valid, with: invalid)
      do {
        _ = try KaibaGraphQLSchema(introspectionData: malformed)
        Issue.record("expected invalid GraphQL name rejection")
      } catch let error as KaibaClientError {
        #expect(error.code == "schema_unavailable")
        #expect(!error.description.contains(invalid))
      }
    }
  }

  @Test func rejectsInvalidGraphQLNamesFromPublicSchemaValues() {
    #expect(throws: KaibaClientError.self) {
      try KaibaGraphQLSchema(
        queryFields: [KaibaSchemaField(
          name: "valid",
          arguments: [KaibaSchemaInputValue(
            name: "valid",
            type: .named(kind: .scalar, name: "Bad-Type")
          )],
          type: .named(kind: .scalar, name: "String")
        )],
        types: [
          KaibaSchemaType(kind: .scalar, name: "String"),
          KaibaSchemaType(kind: .scalar, name: "Bad-Type")
        ]
      )
    }
  }
}

private func updatingType(
  _ value: KaibaJSONValue,
  named name: String,
  update: (inout [String: KaibaJSONValue]) -> Void
) -> KaibaJSONValue {
  guard case var .object(root) = value,
        case var .object(schema)? = root["__schema"],
        case var .array(types)? = schema["types"] else {
    return value
  }
  for index in types.indices {
    guard case var .object(type) = types[index], type["name"] == .string(name) else { continue }
    update(&type)
    types[index] = .object(type)
    break
  }
  schema["types"] = .array(types)
  root["__schema"] = .object(schema)
  return .object(root)
}

private func replacingString(
  in value: KaibaJSONValue,
  matching source: String,
  with replacement: String
) -> KaibaJSONValue {
  switch value {
  case let .array(values):
    return .array(values.map { replacingString(in: $0, matching: source, with: replacement) })
  case let .object(object):
    return .object(object.mapValues {
      replacingString(in: $0, matching: source, with: replacement)
    })
  case let .string(value) where value == source:
    return .string(replacement)
  default:
    return value
  }
}

private func schemaEnvelope(for schema: KaibaGraphQLSchema) throws -> Data {
  try JSONEncoder().encode(KaibaJSONValue.object([
    "data": .object(["__schema": schema.introspectionData().objectValue?["__schema"] ?? .null])
  ]))
}
