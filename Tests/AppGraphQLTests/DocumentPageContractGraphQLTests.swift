import Foundation
import AppCore
import XCTest
@testable import AppGraphQL

final class DocumentPageContractGraphQLTests: XCTestCase {
  func testPageBodySearchUpdateAndRecognitionContracts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("synthetic.pdf")
    try Data("synthetic image".utf8).write(to: source)
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
    let recognizer = ContractRecognizer()
    let imported = try service.importDocumentPages(
      at: source.path,
      processor: DocumentPageProcessor(recognizer: recognizer, extractor: ContractExtractor()),
      maximumOCRPages: 1
    )
    let note = try XCTUnwrap(imported.notes.first { $0.noteNumber == 1 })
    let pendingNote = try XCTUnwrap(imported.notes.first { $0.noteNumber == 2 })
    let executor = NoteGraphQLDocumentExecutor(service: GraphQLNoteGraphQLService(
      service: service, documentPageRecognizer: recognizer
    ))

    let projection = await executor.execute(GraphQLDocumentRequest(
      query: "query($noteId: String!){note(noteId:$noteId){value{bodyMarkdown metaJSON}}}",
      variables: ["noteId": .string(note.noteId.rawValue)]
    ))
    let noteValue = try XCTUnwrap(projection.body["data"]?.asObject?["note"]?.asObject?["value"]?.asObject)
    XCTAssertEqual(noteValue["bodyMarkdown"], .string(""))
    XCTAssertFalse(try XCTUnwrap(noteValue["metaJSON"]?.asString).contains("Lighthouse maintenance log"))

    let search = await executor.execute(GraphQLDocumentRequest(
      query: "{searchNotes(query:\"beacons\"){value{note{noteId} snippet}}}"
    ))
    let values = try XCTUnwrap(search.body["data"]?.asObject?["searchNotes"]?.asObject?["value"]?.asArray)
    let match = try XCTUnwrap(values.first { $0.asObject?["note"]?.asObject?["noteId"]?.asString == note.noteId.rawValue })
    XCTAssertTrue(try XCTUnwrap(match.asObject?["snippet"]?.asString).contains("beacons"))

    _ = try service.setNotebookReadOnly(notebookId: note.notebookId, readOnly: false)
    let update = await executor.execute(GraphQLDocumentRequest(
      query: "mutation($input:UpdateNoteInput!){updateNote(input:$input){result{accepted status diagnostics}}}",
      variables: ["input": .object(["noteId": .string(note.noteId.rawValue), "bodyMarkdown": .string("Edit")])]
    ))
    let diagnostics = update.body["data"]?.asObject?["updateNote"]?.asObject?["result"]?.asObject?["diagnostics"]?.asArray
    XCTAssertTrue((diagnostics ?? []).contains { $0.asString?.contains("document page text is managed by OCR") == true })

    let recognized = await executor.execute(GraphQLDocumentRequest(
      query: "mutation($noteId:String!){recognizeDocumentPage(noteId:$noteId){note{bodyMarkdown metaJSON}}}",
      variables: ["noteId": .string(pendingNote.noteId.rawValue)]
    ))
    let payload = try XCTUnwrap(recognized.body["data"]?.asObject?["recognizeDocumentPage"]?.asObject?["note"]?.asObject)
    XCTAssertEqual(payload["bodyMarkdown"], .string(""))
    let metadata = try JSONValue(parsing: XCTUnwrap(payload["metaJSON"]?.asString))
    XCTAssertEqual(metadata.asObject?["documentPage"]?.asObject?["ocrState"], .string("complete"))
  }
}

private struct ContractRecognizer: DocumentPageRecognizing {
  func recognize(imageURL: URL) throws -> String { "Lighthouse maintenance log: beacons inspected" }
}

private struct ContractExtractor: DocumentImageExtracting {
  func extractImages(fileURL: URL, sourceFormat: String) throws -> DocumentImageExtractionResult {
    DocumentImageExtractionResult(images: (1...2).map { page in
      DocumentExtractedImage(
        pageNumber: page, kind: .pageCapture, data: Data("synthetic page \(page)".utf8),
        mediaType: "image/png", suggestedFilename: "page-\(page).png"
      )
    }, pageTexts: ["", ""])
  }
}
