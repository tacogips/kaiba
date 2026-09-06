import Foundation
import AppCore
import XCTest
@testable import AppGraphQL

final class NoteGraphQLClientBoundaryTests: XCTestCase {
  func testIngestLinksAndNotebookFilesThroughGraphQLService() async throws {
    let service = try makeService()
    let ingest = await service.ingestNotebookPages(GraphQLIngestNotebookPagesInput(
      idempotencyKey: "client-boundary-ingest",
      title: "SDK ingest",
      pages: [
        GraphQLIngestNotebookPageInput(
          bodyMarkdown: "# One",
          readOnly: false,
          tags: [GraphQLNoteTagInput(name: "page-topic")],
          metaJSON: #"{"page":1}"#,
          noteNumber: 7,
          pageImage: GraphQLIngestAttachmentInput(
            contentBase64: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
              .base64EncodedString(),
            mediaType: "image/png",
            originalFilename: "page.png"
          )
        ),
        GraphQLIngestNotebookPageInput(
          bodyMarkdown: "# Two",
          pageImage: GraphQLIngestAttachmentInput(
            contentBase64: Data("second page image".utf8).base64EncodedString(),
            mediaType: "image/png",
            originalFilename: "page-2.png"
          )
        )
      ],
      sourceDocument: GraphQLIngestAttachmentInput(
        contentBase64: Data("%PDF-1.4\n".utf8).base64EncodedString(),
        mediaType: "application/pdf",
        originalFilename: "source.pdf"
      )
    ))
    XCTAssertTrue(ingest.result.accepted, ingest.result.diagnostics.joined(separator: "; "))
    let notebook = try XCTUnwrap(ingest.notebook)
    let notes = ingest.notes
    XCTAssertEqual(notes.count, 2)
    XCTAssertFalse(notes[0].readOnly)
    XCTAssertTrue(notes[1].readOnly)
    XCTAssertEqual(notes[0].tags.map(\.tag.name), ["page-topic"])
    XCTAssertEqual(notes[0].metaJSON, #"{"page":1}"#)
    XCTAssertEqual(ingest.noteFiles.map(\.position), [7, 2])
    XCTAssertEqual(ingest.notebookFiles.count, 1)

    let attachment = await service.attachNotebookFile(
      notebookId: notebook.notebookId,
      contentBase64: Data("content".utf8).base64EncodedString(),
      mediaType: "text/plain"
    )
    XCTAssertTrue(attachment.result.accepted)
    let notebookFiles = await service.notebookFiles(notebookId: notebook.notebookId)
    XCTAssertEqual(notebookFiles.value?.count, 2)
    let noteFiles = await service.noteFiles(noteId: notes[0].noteId)
    XCTAssertEqual(noteFiles.value?.map(\.position), [7])

    _ = await service.linkNotes(from: notes[0].noteId, to: notes[1].noteId)
    let links = await service.noteLinks(noteId: notes[0].noteId)
    XCTAssertEqual(links.value?.count, 1)
  }

  func testAuthenticatedAdminCanUseLongTermMemoryAndUnauthenticatedCannot() async throws {
    let service = try makeService()
    let scopedAdmin = GraphQLNoteGraphQLService(
      service: service.service.scoped(to: NoteStoreSchema.defaultUserId)
    )
    let allowed = await scopedAdmin.longTermMemoryNotebook()
    XCTAssertTrue(allowed.result.accepted)
    XCTAssertNotNil(allowed.value)

    let anonymous = GraphQLNoteGraphQLService(
      service: service.service.scoped(to: NoteStoreSchema.defaultUserId).unauthenticated()
    )
    let denied = await anonymous.longTermMemoryNotebook()
    XCTAssertFalse(denied.result.accepted)
    XCTAssertNil(denied.value)
  }

  func testRecallAssociationDepthValidationAndBoundsReachTheGraphQLBoundary() async throws {
    let graphQL = try makeService()
    let notebook = try graphQL.service.createNotebook(title: "GraphQL depth source")
    let firstHop = try graphQL.service.createNote(
      notebookId: notebook.notebookId,
      bodyMarkdown: "Quartz"
    )
    let secondHop = try graphQL.service.createNote(
      notebookId: notebook.notebookId,
      bodyMarkdown: "Nebula"
    )
    _ = try graphQL.service.linkNotes(from: firstHop.noteId, to: secondHop.noteId)
    let memory = try XCTUnwrap(try graphQL.service.appendLongTermMemoryNotes(
      [LongTermMemoryEntryInput(
        bodyMarkdown: "Graphqldepthboundarytoken",
        sourceNoteIds: [firstHop.noteId]
      )],
      idempotencyKey: "graphql-association-depth"
    ).notes.first)

    let negative = await graphQL.recallLongTermMemory(GraphQLRecallLongTermMemoryInput(
      query: "Graphqldepthboundarytoken",
      includeAssociations: true,
      associationDepth: -1
    ))
    XCTAssertFalse(negative.result.accepted)
    XCTAssertEqual(negative.result.status, "invalid_request")

    let zero = await graphQL.recallLongTermMemory(GraphQLRecallLongTermMemoryInput(
      query: "Graphqldepthboundarytoken",
      includeAssociations: true,
      associationDepth: 0
    ))
    XCTAssertEqual(zero.value.map(\.note.noteId), [memory.noteId])

    let one = await graphQL.recallLongTermMemory(GraphQLRecallLongTermMemoryInput(
      query: "Graphqldepthboundarytoken",
      includeAssociations: true,
      associationDepth: 1
    ))
    XCTAssertTrue(one.value.contains { $0.note.noteId == firstHop.noteId && $0.hopCount == 1 })
    XCTAssertFalse(one.value.contains { $0.note.noteId == secondHop.noteId })

    let maximum = await graphQL.recallLongTermMemory(GraphQLRecallLongTermMemoryInput(
      query: "Graphqldepthboundarytoken",
      includeAssociations: true,
      associationDepth: NoteGraphPolicy.maximumDepth
    ))
    let overMaximum = await graphQL.recallLongTermMemory(GraphQLRecallLongTermMemoryInput(
      query: "Graphqldepthboundarytoken",
      includeAssociations: true,
      associationDepth: NoteGraphPolicy.maximumDepth + 100
    ))
    XCTAssertTrue(maximum.value.contains { $0.note.noteId == secondHop.noteId && $0.hopCount == 2 })
    XCTAssertEqual(overMaximum.value, maximum.value)
  }

  func testIngestRejectsInvalidInputsAndBudgetsBeforeWrites() async throws {
    var service = try makeService()
    let claimCounter = NotebookIngestClaimCounter()
    service.ingestClaimObserver = { _ in claimCounter.record() }
    let originalCount = try service.service.listNotebooks().count
    let originalNoteIDs = Set(try service.service.listNotes(limit: 10_000).map(\.noteId))
    let validPage = GraphQLIngestNotebookPageInput(bodyMarkdown: "# Page")
    let invalidInputs = [
      GraphQLIngestNotebookPagesInput(idempotencyKey: UUID().uuidString, title: "empty", pages: []),
      GraphQLIngestNotebookPagesInput(
        idempotencyKey: UUID().uuidString,
        title: "too-many",
        pages: Array(repeating: validPage, count: 501)
      ),
      GraphQLIngestNotebookPagesInput(
        idempotencyKey: UUID().uuidString,
        title: "empty-page",
        pages: [GraphQLIngestNotebookPageInput(bodyMarkdown: "")]
      ),
      GraphQLIngestNotebookPagesInput(
        idempotencyKey: UUID().uuidString,
        title: "large-page",
        pages: [GraphQLIngestNotebookPageInput(
          bodyMarkdown: String(repeating: "x", count: MarkdownHeadingSplitter.maximumSectionBytes + 1)
        )]
      ),
      GraphQLIngestNotebookPagesInput(
        idempotencyKey: UUID().uuidString,
        title: "duplicate",
        pages: [
          GraphQLIngestNotebookPageInput(bodyMarkdown: "one", noteNumber: 1),
          GraphQLIngestNotebookPageInput(bodyMarkdown: "two", noteNumber: 1)
        ]
      ),
      GraphQLIngestNotebookPagesInput(
        idempotencyKey: UUID().uuidString,
        title: "negative",
        pages: [GraphQLIngestNotebookPageInput(bodyMarkdown: "one", noteNumber: -1)]
      ),
      GraphQLIngestNotebookPagesInput(
        idempotencyKey: UUID().uuidString,
        title: "mixed-number-collision",
        pages: [
          GraphQLIngestNotebookPageInput(bodyMarkdown: "positional"),
          GraphQLIngestNotebookPageInput(bodyMarkdown: "explicit", noteNumber: 1)
        ]
      ),
      GraphQLIngestNotebookPagesInput(
        idempotencyKey: UUID().uuidString,
        title: "invalid-metadata",
        metaJSON: "not-json",
        pages: [validPage]
      ),
      GraphQLIngestNotebookPagesInput(
        idempotencyKey: UUID().uuidString,
        title: "invalid-page-metadata",
        pages: [GraphQLIngestNotebookPageInput(bodyMarkdown: "# Page", metaJSON: "not-json")]
      ),
      GraphQLIngestNotebookPagesInput(
        idempotencyKey: UUID().uuidString,
        title: "invalid-page-metadata-shape",
        pages: [GraphQLIngestNotebookPageInput(bodyMarkdown: "# Page", metaJSON: "[]")]
      ),
      GraphQLIngestNotebookPagesInput(
        idempotencyKey: UUID().uuidString,
        title: "reserved-page-metadata",
        pages: [GraphQLIngestNotebookPageInput(
          bodyMarkdown: "# Page",
          metaJSON: #"{"kaibaChat":{}}"#
        )]
      ),
      GraphQLIngestNotebookPagesInput(
        idempotencyKey: UUID().uuidString,
        title: "base64",
        pages: [validPage],
        sourceDocument: GraphQLIngestAttachmentInput(
          contentBase64: "%%%", mediaType: "application/pdf", originalFilename: "source.pdf"
        )
      ),
      GraphQLIngestNotebookPagesInput(
        idempotencyKey: UUID().uuidString,
        title: "media",
        pages: [validPage],
        sourceDocument: GraphQLIngestAttachmentInput(
          contentBase64: "YQ==", mediaType: "not a media type", originalFilename: "source.pdf"
        )
      ),
      GraphQLIngestNotebookPagesInput(
        idempotencyKey: UUID().uuidString,
        title: "filename",
        pages: [validPage],
        sourceDocument: GraphQLIngestAttachmentInput(
          contentBase64: "YQ==", mediaType: "application/pdf", originalFilename: "../source.pdf"
        )
      ),
      GraphQLIngestNotebookPagesInput(
        idempotencyKey: UUID().uuidString,
        title: "source-role",
        pages: [validPage],
        sourceDocument: GraphQLIngestAttachmentInput(
          contentBase64: "YQ==",
          mediaType: "application/pdf",
          originalFilename: "source.pdf",
          role: "unsupported-role"
        )
      ),
      GraphQLIngestNotebookPagesInput(
        idempotencyKey: UUID().uuidString,
        title: "page-role",
        pages: [GraphQLIngestNotebookPageInput(
          bodyMarkdown: "# Page",
          pageImage: GraphQLIngestAttachmentInput(
            contentBase64: "YQ==",
            mediaType: "image/png",
            originalFilename: "page.png",
            role: "unsupported-role"
          )
        )]
      )
    ]
    for input in invalidInputs {
      let result = await service.ingestNotebookPages(input)
      XCTAssertFalse(result.result.accepted, input.title)
      XCTAssertEqual(result.result.status, "invalid_request", input.title)
      XCTAssertNil(result.notebook, input.title)
      XCTAssertTrue(result.notes.isEmpty, input.title)
      XCTAssertEqual(try service.service.listNotebooks().count, originalCount, input.title)
      XCTAssertEqual(
        Set(try service.service.listNotes(limit: 10_000).map(\.noteId)),
        originalNoteIDs,
        input.title
      )
      XCTAssertEqual(claimCounter.count, 0, input.title)
    }

    let encodedOverBudgetInput = GraphQLIngestNotebookPagesInput(
      idempotencyKey: UUID().uuidString,
      title: "encoded-over-budget",
      pages: [validPage],
      sourceDocument: GraphQLIngestAttachmentInput(
        contentBase64: Data(
          repeating: 0x61,
          count: GraphQLRequestLimits.maximumSerializedBodyBytes * 3 / 4
        ).base64EncodedString(),
        mediaType: "application/pdf",
        originalFilename: "source.pdf"
      )
    )
    XCTAssertGreaterThan(
      try JSONEncoder().encode(encodedOverBudgetInput).count,
      GraphQLRequestLimits.maximumSerializedBodyBytes
    )
    let encodedOverBudget = await service.ingestNotebookPages(encodedOverBudgetInput)
    XCTAssertFalse(encodedOverBudget.result.accepted)
    XCTAssertEqual(encodedOverBudget.result.status, "invalid_request")
    XCTAssertNil(encodedOverBudget.notebook)
    XCTAssertEqual(try service.service.listNotebooks().count, originalCount)
    XCTAssertEqual(Set(try service.service.listNotes(limit: 10_000).map(\.noteId)), originalNoteIDs)

    let oversized = Data(repeating: 0x61, count: 8 * 1_024 * 1_024 + 1)
    let overBudget = await service.ingestNotebookPages(GraphQLIngestNotebookPagesInput(
      idempotencyKey: UUID().uuidString,
      title: "over-budget",
      pages: [validPage],
      sourceDocument: GraphQLIngestAttachmentInput(
        contentBase64: oversized.base64EncodedString(),
        mediaType: "application/pdf",
        originalFilename: "source.pdf"
      )
    ))
    XCTAssertFalse(overBudget.result.accepted)
    XCTAssertEqual(try service.service.listNotebooks().count, originalCount)
    XCTAssertEqual(Set(try service.service.listNotes(limit: 10_000).map(\.noteId)), originalNoteIDs)
    XCTAssertEqual(claimCounter.count, 0)
  }

  func testIngestRollbackAttributionOrderingAndPartialFailureEvidence() async throws {
    let service = try makeService()
    let user = try service.service.createUser(email: "ingest@example.com", displayName: "Ingest User")
    var scoped = GraphQLNoteGraphQLService(service: service.service.scoped(to: user.userId))
    scoped.ingestNoteAttachmentMutation = { _, _, _, _, _, _, _ in
      throw NoteGraphQLClientBoundaryFault.attachmentWrite
    }
    let invalidMetadata = await scoped.ingestNotebookPages(GraphQLIngestNotebookPagesInput(
      idempotencyKey: "invalid-metadata",
      title: "rollback",
      metaJSON: "not-json",
      pages: [GraphQLIngestNotebookPageInput(bodyMarkdown: "# One", noteNumber: 1)]
    ))
    XCTAssertFalse(invalidMetadata.result.accepted)
    XCTAssertNil(invalidMetadata.notebook)

    let partial = await scoped.ingestNotebookPages(GraphQLIngestNotebookPagesInput(
      idempotencyKey: "partial-ingest",
      title: "partial",
      pages: [
        GraphQLIngestNotebookPageInput(
          bodyMarkdown: "# Two",
          noteNumber: 2,
          pageImage: GraphQLIngestAttachmentInput(
            contentBase64: Data("page".utf8).base64EncodedString(),
            mediaType: "image/png",
            originalFilename: "page.png"
          )
        ),
        GraphQLIngestNotebookPageInput(bodyMarkdown: "# One", noteNumber: 1)
      ]
    ))
    XCTAssertFalse(partial.result.accepted)
    XCTAssertEqual(partial.result.status, "partial-failure")
    XCTAssertNotNil(partial.notebook)
    XCTAssertEqual(partial.notes.map(\.noteNumber), [2, 1])
    XCTAssertTrue(partial.notes.allSatisfy(\.readOnly))
    XCTAssertTrue(partial.noteFiles.isEmpty)
    XCTAssertTrue(partial.notebookFiles.isEmpty)
    XCTAssertEqual(partial.notebook?.ownerUserId, user.userId)
    XCTAssertTrue(partial.notes.allSatisfy { $0.createdBy == user.userId })
    XCTAssertTrue(partial.notes.allSatisfy { $0.updatedBy == user.userId })
  }

  private func makeService(function: String = #function) throws -> GraphQLNoteGraphQLService {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/client-boundary-\(function)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return GraphQLNoteGraphQLService(
      service: try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
    )
  }
}

private enum NoteGraphQLClientBoundaryFault: Error {
  case attachmentWrite
}

private final class NotebookIngestClaimCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0

  var count: Int {
    lock.withLock { value }
  }

  func record() {
    lock.withLock { value += 1 }
  }
}
