import Foundation

/// Seam over the external document-to-markdown converter so import logic and
/// tests never depend on a real binary (design decision DI1).
public protocol DocumentConverting: Sendable {
  func convert(inputPath: String) throws -> DocumentConversionResult
}

public struct DocumentConversionResult: Equatable, Sendable {
  public var markdown: String
  public var sourceFormat: String
  public var toolVersion: String?

  public init(markdown: String, sourceFormat: String, toolVersion: String? = nil) {
    self.markdown = markdown
    self.sourceFormat = sourceFormat
    self.toolVersion = toolVersion
  }
}

public enum DocumentConversionError: Error, Equatable, Sendable {
  /// The converter binary could not be located; carries the path that was tried.
  case toolNotFound(String)
  /// The converter rejected the document (e.g. scanned PDF without OCR);
  /// carries the converter's error kind and message verbatim.
  case unsupported(kind: String, message: String)
  case failed(String)
}

/// Spawns the installed `anydoc-swift` CLI with `--json` and parses its
/// versioned envelope. The binary path comes from `import.anydocPath` in the
/// configuration, else a `PATH` lookup.
public struct AnydocCLIDocumentConverter: DocumentConverting {
  public static let defaultBinaryName = "anydoc-swift"
  static let maximumOutputBytes = 64 * 1024 * 1024

  public var binaryPath: String?
  public var environment: [String: String]

  public init(
    binaryPath: String? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.binaryPath = binaryPath
    self.environment = environment
  }

  public func convert(inputPath: String) throws -> DocumentConversionResult {
    let resolvedBinary = try resolveBinary()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: resolvedBinary)
    process.arguments = [inputPath, "--json"]
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    do {
      try process.run()
    } catch {
      throw DocumentConversionError.toolNotFound(resolvedBinary)
    }
    let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
    let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard outputData.count <= Self.maximumOutputBytes else {
      throw DocumentConversionError.failed(
        "converter output exceeded \(Self.maximumOutputBytes) bytes"
      )
    }
    switch process.terminationStatus {
    case 0, 1:
      return try Self.parseEnvelope(outputData)
    default:
      let message = String(data: errorData, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      throw DocumentConversionError.failed(
        "anydoc-swift exited with status \(process.terminationStatus)"
          + (message.isEmpty ? "" : ": \(message)")
      )
    }
  }

  func resolveBinary() throws -> String {
    if let binaryPath, !binaryPath.isEmpty {
      let expanded = (binaryPath as NSString).expandingTildeInPath
      guard FileManager.default.isExecutableFile(atPath: expanded) else {
        throw DocumentConversionError.toolNotFound(expanded)
      }
      return expanded
    }
    let searchPath = environment["PATH"] ?? ""
    for directory in searchPath.split(separator: ":") {
      let candidate = (String(directory) as NSString)
        .appendingPathComponent(Self.defaultBinaryName)
      if FileManager.default.isExecutableFile(atPath: candidate) {
        return candidate
      }
    }
    throw DocumentConversionError.toolNotFound(Self.defaultBinaryName)
  }

  /// Parses the `--json` envelope. Pure over `Data` so tests exercise it with
  /// fixtures instead of spawning a process.
  static func parseEnvelope(_ data: Data) throws -> DocumentConversionResult {
    let object: Any
    do {
      object = try JSONSerialization.jsonObject(with: data)
    } catch {
      throw DocumentConversionError.failed("anydoc-swift printed invalid JSON")
    }
    guard let envelope = object as? [String: Any],
      let status = envelope["status"] as? String
    else {
      throw DocumentConversionError.failed("anydoc-swift envelope is missing status")
    }
    switch status {
    case "ok":
      guard let markdown = envelope["markdown"] as? String,
        let format = envelope["format"] as? String
      else {
        throw DocumentConversionError.failed(
          "anydoc-swift ok envelope is missing markdown or format"
        )
      }
      let tool = envelope["tool"] as? [String: Any]
      return DocumentConversionResult(
        markdown: markdown,
        sourceFormat: format,
        toolVersion: tool?["version"] as? String
      )
    case "error":
      let error = envelope["error"] as? [String: Any]
      let kind = error?["kind"] as? String ?? "unknown"
      let message = error?["message"] as? String ?? "conversion failed"
      if kind == "unsupported" || kind == "encrypted" {
        throw DocumentConversionError.unsupported(kind: kind, message: message)
      }
      throw DocumentConversionError.failed("\(kind): \(message)")
    default:
      throw DocumentConversionError.failed("anydoc-swift envelope status is \(status)")
    }
  }
}
