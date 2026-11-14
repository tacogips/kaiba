import Foundation
import Testing
@testable import KaibaClient

private actor ControlPlaneDiagnosticTransport: KaibaHTTPTransporting {
  let body: Data

  init(body: Data) {
    self.body = body
  }

  func send(_ request: KaibaHTTPRequest, maximumResponseBytes: Int) async throws -> KaibaHTTPResponse {
    KaibaHTTPResponse(statusCode: 200, body: body)
  }
}

@Suite("Kaiba control-plane diagnostic redaction")
struct KaibaControlPlaneDiagnosticTests {
  private static let activeToken = "active-control-plane-sentinel"
  private static let hostileDiagnostics = [
    "active token: \(activeToken)",
    "Authorization = [Bearer bracketed-authorization-secret]",
    "Authorization = \"Bearer quoted-authorization-secret\"",
    "Authorization = (Bearer parenthesized-authorization-secret)",
    "Authorization = [Bearer unclosed-bracketed-secret; safe-marker",
    "Authorization = \"Bearer unclosed-quoted-secret",
    "Authorization = (Bearer unclosed-parenthesized-secret",
    "Authorization = \"Bearer escaped-quote-secret\\\" remaining-quote-secret\"; escaped-safe-marker",
    "Authorization = [Bearer escaped-bracket-secret\\] remaining-bracket-secret]; escaped-safe-marker",
    "Authorization = (Bearer escaped-parenthesis-secret\\) remaining-parenthesis-secret); escaped-safe-marker",
    "{\"Authorization\": \"Bearer quoted-key-secret\\\" remaining-quoted-key-secret\"}; quoted-key-safe-marker",
    "{\\\"Authorization\\\": [Bearer serialized-key-secret\\] remaining-serialized-key-secret]}; serialized-key-safe-marker",
    "authorization_header = \"Bearer underscored-alias-secret\\\" remaining-underscored-alias-secret\"; underscored-alias-safe-marker",
    "Authorization-Header: [Bearer hyphenated-alias-secret\\] remaining-hyphenated-alias-secret]; hyphenated-alias-safe-marker",
    "HTTPAuthorizationHeader=(Bearer http-alias-secret\\) remaining-http-alias-secret); http-alias-safe-marker",
    "proxy_authorization = \"Bearer proxy-snake-secret\\\" remaining-proxy-snake-secret\"; proxy-snake-safe-marker",
    "proxyAuthorizationHeader: [Bearer proxy-camel-secret\\] remaining-proxy-camel-secret]; proxy-camel-safe-marker",
    "überAuthorizationHeader = \"Bearer unicode-latin-secret\\\" remaining-unicode-latin-secret\"; unicode-latin-safe-marker",
    "認証AuthorizationHeader: [Bearer unicode-cjk-secret\\] remaining-unicode-cjk-secret]; unicode-cjk-safe-marker",
    "https://sentinel-user:sentinel-password@example.com/private",
    "line\rbreak\ttab\u{001B}escape\u{0000}null"
  ]

  @Test func sanitizesEveryTypedControlPlanePayloadShape() async throws {
    let result: [String: Any] = [
      "accepted": false,
      "status": "invalid_request",
      "diagnostics": Self.hostileDiagnostics
    ]

    let directClient = try Self.client(root: result)
    let direct = try await directClient.deleteNote(KaibaNoteID(rawValue: "note-1"))

    let operationClient = try Self.client(root: ["result": result])
    let operation = try await operationClient.attachNoteFile(
      KaibaNoteID(rawValue: "note-1"),
      bytes: Data(),
      mediaType: "text/plain",
      role: .custom(Self.activeToken)
    )

    let valueClient = try Self.client(root: ["result": result, "value": NSNull()])
    let value = try await valueClient.getNote(KaibaNoteID(rawValue: "note-1"))

    let appendClient = try Self.client(root: [
      "result": result,
      "notes": [],
      "idempotentReplay": false
    ])
    let append = try await appendClient.appendLongTermMemory(
      entries: [KaibaLongTermMemoryEntry(bodyMarkdown: "memory")],
      idempotencyKey: "idempotency-key"
    )

    for diagnostics in [
      direct.diagnostics,
      operation.result.diagnostics,
      value.result.diagnostics,
      append.result.diagnostics
    ] {
      Self.expectSanitized(diagnostics)
    }
  }

  private static func client(root: [String: Any]) throws -> KaibaClient {
    let body = try JSONSerialization.data(withJSONObject: ["data": ["root": root]])
    return try KaibaClient(
      endpoint: URL(string: "http://localhost")!,
      authentication: .bearer(try KaibaBearerToken(activeToken)),
      transport: ControlPlaneDiagnosticTransport(body: body)
    )
  }

  private static func expectSanitized(_ diagnostics: [String]) {
    let rendered = diagnostics.joined(separator: " ")
    #expect(!rendered.contains(activeToken))
    #expect(!rendered.localizedCaseInsensitiveContains("authorization"))
    #expect(!rendered.contains("bracketed-authorization-secret"))
    #expect(!rendered.contains("quoted-authorization-secret"))
    #expect(!rendered.contains("parenthesized-authorization-secret"))
    #expect(!rendered.contains("unclosed-bracketed-secret"))
    #expect(!rendered.contains("unclosed-quoted-secret"))
    #expect(!rendered.contains("unclosed-parenthesized-secret"))
    #expect(rendered.contains("safe-marker"))
    #expect(!rendered.contains("escaped-quote-secret"))
    #expect(!rendered.contains("remaining-quote-secret"))
    #expect(!rendered.contains("escaped-bracket-secret"))
    #expect(!rendered.contains("remaining-bracket-secret"))
    #expect(!rendered.contains("escaped-parenthesis-secret"))
    #expect(!rendered.contains("remaining-parenthesis-secret"))
    #expect(rendered.contains("escaped-safe-marker"))
    #expect(!rendered.contains("quoted-key-secret"))
    #expect(!rendered.contains("remaining-quoted-key-secret"))
    #expect(rendered.contains("quoted-key-safe-marker"))
    #expect(!rendered.contains("serialized-key-secret"))
    #expect(!rendered.contains("remaining-serialized-key-secret"))
    #expect(rendered.contains("serialized-key-safe-marker"))
    #expect(!rendered.contains("underscored-alias-secret"))
    #expect(!rendered.contains("remaining-underscored-alias-secret"))
    #expect(rendered.contains("underscored-alias-safe-marker"))
    #expect(!rendered.contains("hyphenated-alias-secret"))
    #expect(!rendered.contains("remaining-hyphenated-alias-secret"))
    #expect(rendered.contains("hyphenated-alias-safe-marker"))
    #expect(!rendered.contains("http-alias-secret"))
    #expect(!rendered.contains("remaining-http-alias-secret"))
    #expect(rendered.contains("http-alias-safe-marker"))
    #expect(!rendered.contains("proxy-snake-secret"))
    #expect(!rendered.contains("remaining-proxy-snake-secret"))
    #expect(rendered.contains("proxy-snake-safe-marker"))
    #expect(!rendered.contains("proxy-camel-secret"))
    #expect(!rendered.contains("remaining-proxy-camel-secret"))
    #expect(rendered.contains("proxy-camel-safe-marker"))
    #expect(!rendered.contains("unicode-latin-secret"))
    #expect(!rendered.contains("remaining-unicode-latin-secret"))
    #expect(rendered.contains("unicode-latin-safe-marker"))
    #expect(!rendered.contains("unicode-cjk-secret"))
    #expect(!rendered.contains("remaining-unicode-cjk-secret"))
    #expect(rendered.contains("unicode-cjk-safe-marker"))
    #expect(!rendered.contains("sentinel-user"))
    #expect(!rendered.contains("sentinel-password"))
    #expect(rendered.contains("https://<redacted>@example.com/private"))
    #expect(rendered.unicodeScalars.allSatisfy {
      !CharacterSet.controlCharacters.contains($0)
    })
  }
}
