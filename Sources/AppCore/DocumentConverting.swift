#if canImport(AnydocKit)
import AnydocKit
#endif
import Foundation

/// Seam over document-to-markdown conversion so import service tests can use
/// deterministic stubs while production calls AnydocKit in-process.
public protocol DocumentConverting: Sendable {
  func convert(inputPath: String) throws -> DocumentConversionResult
}

public struct DocumentConversionResult: Equatable, Sendable {
  public var markdown: String
  public var sourceFormat: String
  public var toolName: String
  public var toolVersion: String?

  public init(
    markdown: String,
    sourceFormat: String,
    toolName: String = AnydocKitDocumentConverter.toolName,
    toolVersion: String? = nil
  ) {
    self.markdown = markdown
    self.sourceFormat = sourceFormat
    self.toolName = toolName
    self.toolVersion = toolVersion
  }
}

public enum DocumentConversionError: Error, Equatable, Sendable {
  /// The converter rejected the document (for example an encrypted or
  /// image-only PDF); carries the library's error kind and message.
  case unsupported(kind: String, message: String)
  case failed(String)
}

/// Direct Swift-library adapter over AnydocKit. No executable lookup or
/// runtime path configuration is involved. AnydocKit's Rust FFI ships only
/// for Apple platforms, so the Linux build keeps the type (call sites and
/// default arguments stay portable) but every conversion fails cleanly.
public struct AnydocKitDocumentConverter: DocumentConverting {
  public static let toolName = "AnydocKit"

  public init() {}

  #if canImport(AnydocKit)
  public func convert(inputPath: String) throws -> DocumentConversionResult {
    do {
      let conversion = try Anydoc.convert(contentsOf: URL(fileURLWithPath: inputPath))
      return DocumentConversionResult(
        markdown: conversion.markdown,
        sourceFormat: conversion.format.rawValue,
        toolName: Self.toolName,
        toolVersion: Anydoc.version
      )
    } catch let error as AnydocError {
      switch error.kind {
      case .unsupported, .encrypted:
        throw DocumentConversionError.unsupported(
          kind: error.kind.rawValue,
          message: error.message
        )
      default:
        throw DocumentConversionError.failed("\(error.kind.rawValue): \(error.message)")
      }
    } catch {
      throw DocumentConversionError.failed(String(describing: error))
    }
  }
  #else
  public func convert(inputPath: String) throws -> DocumentConversionResult {
    throw DocumentConversionError.failed(
      "AnydocKit document conversion is unavailable on this platform"
    )
  }
  #endif
}
