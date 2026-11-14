import AppCore
import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

public struct GraphQLDocumentImportInput: Codable, Sendable {
  public var filename: String
  public var contentBase64: String
  public var title: String?
  public var maximumOCRPages: String?
}

public extension GraphQLNoteGraphQLService {
  /// Inline upload stays below the existing 2 MiB HTTP envelope after base64
  /// expansion. Larger documents can use the local import command.
  func importDocument(_ input: GraphQLDocumentImportInput) async -> GraphQLNoteMutationResult {
    guard let lease = service.agentExecutionAdmission.acquire(principalId: service.agentExecutionPrincipalId()) else {
      return .init(result: .init(accepted: false, status: "overloaded", diagnostics: ["Import is busy; try again shortly."]))
    }
    defer { service.agentExecutionAdmission.release(lease) }
    return await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(returning: noteMutation {
          let limit = try input.maximumOCRPages.map(DocumentOCRPageLimit.parse) ?? documentMaximumOCRPages
          let filename = (input.filename as NSString).lastPathComponent
          let format = (filename as NSString).pathExtension.lowercased()
          guard filename == input.filename, filename.utf8.count <= 255,
            ["pdf", "png", "jpg", "jpeg", "gif", "webp"].contains(format) else {
            throw GraphQLNoteServiceError.invalidRequest("Choose a PDF or supported image filename")
          }
          guard input.contentBase64.utf8.count <= 1_398_104,
            let data = Data(base64Encoded: input.contentBase64), !data.isEmpty,
            data.count <= 1_048_576 else {
            throw GraphQLNoteServiceError.invalidRequest("Upload must contain valid base64 and be at most 1 MiB")
          }
          #if canImport(PDFKit)
          if format == "pdf" {
            guard let document = PDFDocument(data: data), (1...500).contains(document.pageCount) else {
              throw GraphQLNoteServiceError.invalidRequest("PDF upload must contain 1...500 readable pages")
            }
          }
          #endif
          let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
          try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
          defer { try? FileManager.default.removeItem(at: directory) }
          let source = directory.appendingPathComponent(filename)
          try data.write(to: source)
          let imported = try service.importDocumentPages(
            at: source.path, title: input.title?.isEmpty == false ? input.title : nil,
            processor: DocumentPageProcessor(
              recognizer: documentPageRecognizer, analyzer: documentPageAnalyzer
            ), maximumOCRPages: limit.maximum
          )
          return .init(
            result: .init(accepted: true, status: "ok"),
            notebook: GraphQLNotebookDTO(notebook: imported.notebook)
          )
        })
      }
    }
  }
}
