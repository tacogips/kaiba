import Foundation

/// Dedicated Document AI settings. Only credential variable names belong in config.
public struct GoogleDocumentAIConfiguration: Codable, Equatable, Sendable {
  public var processorName: String
  public var commandPath: String?
  public var serviceAccountEnvironmentVariable: String?
  public var accessTokenEnvironmentVariable: String?
  public var languageHints: [String]?
  public var timeoutSeconds: Int?

  public init(
    processorName: String, commandPath: String? = nil,
    serviceAccountEnvironmentVariable: String? = nil,
    accessTokenEnvironmentVariable: String? = nil,
    languageHints: [String]? = nil, timeoutSeconds: Int? = nil
  ) {
    self.processorName = processorName
    self.commandPath = commandPath
    self.serviceAccountEnvironmentVariable = serviceAccountEnvironmentVariable
    self.accessTokenEnvironmentVariable = accessTokenEnvironmentVariable
    self.languageHints = languageHints
    self.timeoutSeconds = timeoutSeconds
  }
}

/// Tool-free Document AI CLI adapter shared by imports and deferred page OCR.
/// Unlike a coding-agent gateway, this process only calls a fixed Google API.
/// It receives one credential, a private HOME, and document bytes on stdin.
public struct GoogleDocumentAIPageRecognizer: DocumentPageRecognizing {
  public static let binaryName = "google-document-ocr-gateway"
  public let configuration: GoogleDocumentAIConfiguration
  public let environment: [String: String]

  public init(
    configuration: GoogleDocumentAIConfiguration,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.configuration = configuration
    self.environment = environment
  }

  public func recognize(imageURL: URL) throws -> String {
    let parts = configuration.processorName.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 6 || parts.count == 8, parts[0] == "projects",
          parts[2] == "locations", parts[4] == "processors",
          parts.count != 8 || parts[6] == "processorVersions",
          parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy(Self.isResourceCharacter) }) else {
      throw DocumentConversionError.failed("import.googleDocumentAI.processorName must be a full processor or processor-version resource name")
    }
    let timeout = configuration.timeoutSeconds ?? 120
    guard (1...600).contains(timeout) else {
      throw DocumentConversionError.failed("import.googleDocumentAI.timeoutSeconds must be between 1 and 600")
    }
    let credential = try credentialSelection()
    let binary = try resolveBinary()
    let body = try requestBody(imageURL: imageURL)
    let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("kaiba-document-ai-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: workspace) }
    // Do not forward shell hooks, other provider keys, or the operator's HOME.
    let childEnvironment = [
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
      "HOME": workspace.path, "TMPDIR": workspace.path,
      credential.name: credential.value
    ]
    let method = parts.count == 8
      ? "projects.locations.processors.processorVersions.process"
      : "projects.locations.processors.process"
    let arguments = [
      "writer", method, "--location", String(parts[3]),
      "--param", "name=\(configuration.processorName)", "--body", "-",
      credential.flag, credential.name
    ]
    let completion = SynchronousGatewayResult()
    Task.detached {
      do {
        completion.finish(.success(try await AgentGatewayCLIInvoker.run(
          binary: binary, arguments: arguments, stdin: body,
          environment: childEnvironment, timeoutNanoseconds: UInt64(timeout) * 1_000_000_000,
          workingDirectory: workspace
        )))
      } catch { completion.finish(.failure(error)) }
    }
    let execution: AgentGatewayCLIInvoker.Execution
    do { execution = try completion.wait() } catch {
      // Subprocess diagnostics can contain credentials or private page content.
      throw DocumentConversionError.failed("Google Document AI gateway execution failed or timed out")
    }
    guard execution.exitCode == 0 else {
      throw DocumentConversionError.failed(Self.failureMessage(execution.stderr, exitCode: execution.exitCode))
    }
    return try Self.parseResponse(execution.stdout)
  }

  static func parseResponse(_ data: Data) throws -> String {
    guard let response = try? JSONDecoder().decode(GoogleOCRResponse.self, from: data), response.ok,
          (response.data.document.error?.code ?? 0) == 0,
          let pages = response.data.document.pages, !pages.isEmpty,
          pages.allSatisfy({ ($0.error?.code ?? 0) == 0 }) else {
      throw DocumentConversionError.failed("Google Document AI returned an invalid or incomplete OCR response")
    }
    // Google's canonical text preserves its reading order; do not reorder by x/y
    // or ask an LLM to rewrite it. Protobuf omits text on a successfully blank page.
    return response.data.document.text ?? ""
  }

  private func requestBody(imageURL: URL) throws -> Data {
    let mimeTypes = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp"]
    guard let mimeType = mimeTypes[imageURL.pathExtension.lowercased()] else {
      throw DocumentConversionError.failed("Google Document AI page OCR requires a supported image")
    }
    let size = try imageURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size > 0, size <= 20 * 1_024 * 1_024 else {
      throw DocumentConversionError.failed("Google Document AI page image must be nonempty and at most 20 MiB")
    }
    var body: [String: Any] = [
      // Full Document AI replies include image/layout data that can exceed the
      // shared subprocess output limit even for a single page.
      "fieldMask": "text,error,pages.pageNumber",
      "rawDocument": ["content": try Data(contentsOf: imageURL).base64EncodedString(), "mimeType": mimeType]
    ]
    if let hints = configuration.languageHints, !hints.isEmpty {
      body["processOptions"] = ["ocrConfig": ["hints": ["languageHints": hints]]]
    }
    return try JSONSerialization.data(withJSONObject: body)
  }

  private func credentialSelection() throws -> GoogleOCRCredential {
    guard configuration.serviceAccountEnvironmentVariable == nil || configuration.accessTokenEnvironmentVariable == nil else {
      throw DocumentConversionError.failed("configure either serviceAccountEnvironmentVariable or accessTokenEnvironmentVariable, not both")
    }
    let token = configuration.accessTokenEnvironmentVariable
    let name = token ?? configuration.serviceAccountEnvironmentVariable ?? "GOOGLE_APPLICATION_CREDENTIALS_JSON"
    guard name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil,
          !AgentGatewayCLIInvoker.servedReservedEnvironmentKeys.contains(name),
          !name.hasPrefix("DYLD_"), !name.hasPrefix("LD_"),
          !["ENV", "BASH_ENV", "SHELLOPTS", "BASHOPTS", "CDPATH"].contains(name),
          let value = environment[name], !value.isEmpty else {
      throw DocumentConversionError.failed("Google Document AI requires a valid, non-reserved credential environment variable with a value")
    }
    return GoogleOCRCredential(name: name, value: value, flag: token == nil ? "--service-account-env" : "--access-token-env")
  }

  private func resolveBinary() throws -> String {
    if let path = configuration.commandPath {
      let expanded = (path as NSString).expandingTildeInPath
      guard expanded.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: expanded) else {
        throw DocumentConversionError.failed("import.googleDocumentAI.commandPath must name an executable absolute path")
      }
      return expanded
    }
    for directory in (environment["PATH"] ?? "").split(separator: ":") where directory.hasPrefix("/") {
      let path = URL(fileURLWithPath: String(directory)).appendingPathComponent(Self.binaryName).path
      if FileManager.default.isExecutableFile(atPath: path) { return path }
    }
    throw DocumentConversionError.failed("google-document-ocr-gateway not found; install it or set import.googleDocumentAI.commandPath")
  }

  private static func isResourceCharacter(_ byte: UInt8) -> Bool {
    (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 45 || byte == 95
  }

  private static func failureMessage(_ data: Data, exitCode: Int32) -> String {
    let error = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? [String: Any]
    let provider = error?["provider"] as? [String: Any]
    let details = provider?["details"] as? [[String: Any]] ?? []
    if details.contains(where: { $0["reason"] as? String == "SERVICE_DISABLED" }) {
      return "Google Document AI API is disabled for the configured Google Cloud project"
    }
    if let status = error?["httpStatus"] as? Int, (400...599).contains(status) {
      return "Google Document AI request failed (HTTP \(status)); check API enablement, processor, region, and IAM permissions"
    }
    return "Google Document AI gateway failed (exit \(exitCode))"
  }
}

private struct GoogleOCRCredential {
  var name: String
  var value: String
  var flag: String
}

private struct GoogleOCRResponse: Decodable {
  var ok: Bool
  var data: GoogleOCRPayload
}

private struct GoogleOCRPayload: Decodable {
  var document: GoogleOCRDocument
}

private struct GoogleOCRDocument: Decodable {
  var error: GoogleOCRStatus?
  var text: String?
  var pages: [GoogleOCRPage]?
}

private struct GoogleOCRPage: Decodable {
  var error: GoogleOCRStatus?
}

private struct GoogleOCRStatus: Decodable {
  var code: Int?
}
