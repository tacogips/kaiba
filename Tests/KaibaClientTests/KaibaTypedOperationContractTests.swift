import Foundation
import Testing
@testable import KaibaClient

private actor TypedContractTransport: KaibaHTTPTransporting {
  let root: KaibaJSONValue
  private(set) var requests: [KaibaHTTPRequest] = []

  init(root: KaibaJSONValue) {
    self.root = root
  }

  func send(_ request: KaibaHTTPRequest, maximumResponseBytes: Int) async throws -> KaibaHTTPResponse {
    requests.append(request)
    let envelope = KaibaJSONValue.object(["data": .object(["root": root])])
    return KaibaHTTPResponse(statusCode: 200, body: try JSONEncoder().encode(envelope))
  }
}

private struct TypedFailureTransport: KaibaHTTPTransporting {
  enum Mode: Sendable {
    case graphQLError
    case decodeFailure
  }

  let mode: Mode

  func send(_ request: KaibaHTTPRequest, maximumResponseBytes: Int) async throws -> KaibaHTTPResponse {
    switch mode {
    case .graphQLError:
      return KaibaHTTPResponse(
        statusCode: 200,
        body: Data(#"{"errors":[{"message":"typed fixture failure"}]}"#.utf8)
      )
    case .decodeFailure:
      return KaibaHTTPResponse(statusCode: 200, body: Data(#"{"data":{"root":7}}"#.utf8))
    }
  }
}

private struct TypedContractOutcome: Equatable, Sendable {
  let result: KaibaControlPlaneResult
  let evidence: String?
}

private enum TypedResponseFixture: Sendable {
  case direct
  case value(KaibaJSONValue, evidence: String)
  case operation(field: String, value: KaibaJSONValue, evidence: String)
  case append

  func root(name: String, accepted: Bool) -> KaibaJSONValue {
    let result = ContractFixture.control(name: name, accepted: accepted)
    switch self {
    case .direct:
      return result
    case let .value(value, _):
      return .object(accepted ? ["result": result, "value": value] : ["result": result])
    case let .operation(field, value, _):
      return .object(accepted ? ["result": result, field: value] : ["result": result])
    case .append:
      return .object([
        "result": result,
        "notes": accepted ? .array([ContractFixture.note]) : .array([]),
        "idempotentReplay": .bool(accepted)
      ])
    }
  }

  func expectedEvidence(accepted: Bool) -> String? {
    switch self {
    case .direct:
      return nil
    case let .value(_, evidence), let .operation(_, _, evidence):
      return accepted ? evidence : nil
    case .append:
      return accepted ? "note-fixture|true" : "nil|false"
    }
  }
}

private struct TypedOperationContract: Sendable {
  let name: String
  let document: String
  let variables: [String: KaibaJSONValue]
  let response: TypedResponseFixture
  let invoke: @Sendable (KaibaClient) async throws -> TypedContractOutcome
}

private struct TypedContractInputs: Sendable {
  let noteId = KaibaNoteID(rawValue: "note-1")
  let relatedNoteId = KaibaNoteID(rawValue: "note-2")
  let notebookId = KaibaNotebookID(rawValue: "notebook-1")
  let tagId = KaibaTagID(rawValue: "tag-1")
  let originatingActionId = KaibaAutoActionID(rawValue: "action-1")
  let attachment = KaibaInlineAttachment(
    bytes: Data("bytes".utf8), mediaType: "text/plain", originalFilename: "source.txt"
  )
  let sourceDocument = KaibaInlineAttachment(
    bytes: Data("source".utf8), mediaType: "application/pdf",
    originalFilename: "source.pdf", role: .sourceDocument
  )
  let pageImage = KaibaInlineAttachment(
    bytes: Data("image".utf8), mediaType: "image/png",
    originalFilename: "page.png", role: .sourcePageImage
  )
  let richTag = KaibaTagInput(name: "topic", classId: "class-1")
  let note = TypedResponseFixture.value(ContractFixture.note, evidence: "note-fixture")
  let notes = TypedResponseFixture.value(.array([ContractFixture.note]), evidence: "note-fixture")
  let notebook = TypedResponseFixture.value(ContractFixture.notebook, evidence: "Notebook fixture")
  let notebooks = TypedResponseFixture.value(.array([ContractFixture.notebook]), evidence: "Notebook fixture")
  let operationNote = TypedResponseFixture.operation(
    field: "note", value: ContractFixture.note, evidence: "note-fixture"
  )
  let operationNotebook = TypedResponseFixture.operation(
    field: "notebook", value: ContractFixture.notebook, evidence: "Notebook fixture"
  )
}

@Suite("Kaiba typed operation contracts")
struct KaibaTypedOperationContractTests {
  @Test func everyPublicConvenienceHasAnExactRequestAndDecodedResultFixture() async throws {
    for contract in contracts() {
      for accepted in [true, false] {
        let transport = TypedContractTransport(root: contract.response.root(name: contract.name, accepted: accepted))
        let client = try KaibaClient(
          endpoint: URL(string: "http://localhost")!,
          authentication: .unauthenticated,
          transport: transport
        )
        let outcome = try await contract.invoke(client)
        let sent = try #require(await transport.requests.first, "missing request for \(contract.name)")
        #expect(await transport.requests.count == 1, "unexpected request count for \(contract.name)")
        let wire = try JSONDecoder().decode(KaibaGraphQLWireRequest.self, from: sent.body)
        #expect(wire.query == contract.document, "document changed for \(contract.name)")
        #expect((wire.variables ?? [:]) == contract.variables, "variables changed for \(contract.name)")
        #expect((wire.variables == nil) == contract.variables.isEmpty, "variable envelope changed for \(contract.name)")
        #expect(wire.operationName == nil)
        #expect(outcome.result == ContractFixture.decodedControl(name: contract.name, accepted: accepted))
        #expect(outcome.evidence == contract.response.expectedEvidence(accepted: accepted))
      }
    }
  }

  @Test func everyPublicConveniencePropagatesGraphQLAndDecodeFailures() async throws {
    for (mode, expectedCode) in [
      (TypedFailureTransport.Mode.graphQLError, "graphql_failed"),
      (.decodeFailure, "decoding_failed")
    ] {
      let client = try KaibaClient(
        endpoint: URL(string: "http://localhost")!,
        authentication: .unauthenticated,
        transport: TypedFailureTransport(mode: mode)
      )
      for contract in contracts() {
        do {
          _ = try await contract.invoke(client)
          Issue.record("expected \(expectedCode) for \(contract.name)")
        } catch let error as KaibaClientError {
          #expect(error.code == expectedCode, "wrong failure for \(contract.name)")
        } catch {
          Issue.record("unexpected error for \(contract.name): \(error)")
        }
      }
    }
  }

  @Test func noteFilterContractsMatchRielaKaibaAddonInputs() throws {
    let contractsByName = Dictionary(uniqueKeysWithValues: contracts().map { ($0.name, $0.variables) })
    #expect(contractsByName["listNotes"]?["tagFilter"] == .array([
      .string("research"), .string("swift")
    ]))
    let search = try #require(contractsByName["searchNotes"])
    #expect(search["tagFilter"] == .array([.string("research")]))
    #expect(search["classFilter"] == .array([.string("document")]))
    #expect(search["includeLinked"] == .bool(true))
    #expect(search["depth"] == .integer(3))
  }

  @Test func fileFixtureMatchesRielaFileRecordAttributes() throws {
    let data = try JSONEncoder().encode(ContractFixture.file)
    let file = try JSONDecoder().decode(KaibaFile.self, from: data)
    #expect(file.fileId == KaibaFileID(rawValue: "file-fixture"))
    #expect(file.storageKind == "s3")
    #expect(file.localPath == nil)
    #expect(file.s3Profile == "archive")
    #expect(file.s3Bucket == "notes")
    #expect(file.s3Key == "fixtures/file-fixture")
    #expect(file.s3URL == "s3://notes/fixtures/file-fixture")
    #expect(file.migratedAt == "2026-09-04T02:00:00Z")
  }

  private func contracts() -> [TypedOperationContract] {
    let input = TypedContractInputs()
    return noteContracts(input)
      + notebookAndTagContracts(input)
      + attachmentAndCommentContracts(input)
      + conversationAndMemoryContracts(input)
  }

  private func noteContracts(_ input: TypedContractInputs) -> [TypedOperationContract] {
    let noteId = input.noteId
    let relatedNoteId = input.relatedNoteId
    let notebookId = input.notebookId
    let originatingActionId = input.originatingActionId
    let richTag = input.richTag
    let note = input.note
    let notes = input.notes
    let operationNote = input.operationNote
    return [
      contract("getNote", TypedDocuments.getNote, ["noteId": .string(noteId.rawValue)], note) { client in
        let payload = try await client.getNote(noteId)
        return TypedContractOutcome(result: payload.result, evidence: payload.value?.noteId.rawValue)
      },
      contract("listNotes", TypedDocuments.listNotes, [
        "notebookId": .string(notebookId.rawValue),
        "tagFilter": .array([.string("research"), .string("swift")]),
        "limit": .integer(7), "offset": .integer(3)
      ], notes) { client in
        let payload = try await client.listNotes(
          notebookId: notebookId,
          tagFilter: ["research", "swift"],
          limit: 7,
          offset: 3
        )
        return TypedContractOutcome(result: payload.result, evidence: payload.value?.first?.noteId.rawValue)
      },
      contract("createNote", TypedDocuments.createNote, ["input": .object([
        "notebookId": .string(notebookId.rawValue), "notebookTitle": .string("Notebook input"),
        "title": .string("Note input"), "bodyMarkdown": .string("body"), "readOnly": .bool(true),
        "tags": .array([.object(["name": .string("topic"), "classId": .string("class-1")])]),
        "provenance": .string("fixture"), "assignedBy": .string("tester"),
        "metaJSON": .string(#"{"fixture":true}"#),
        "originatingActionId": .string(originatingActionId.rawValue)
      ])], operationNote) { client in
        let payload = try await client.createNote(
          notebookId: notebookId, notebookTitle: "Notebook input", title: "Note input",
          bodyMarkdown: "body", readOnly: true, tags: [richTag], provenance: "fixture",
          assignedBy: "tester", metaJSON: #"{"fixture":true}"#,
          originatingActionId: originatingActionId
        )
        return TypedContractOutcome(result: payload.result, evidence: payload.note?.noteId.rawValue)
      },
      contract("updateNote", TypedDocuments.updateNote, ["input": .object([
        "noteId": .string(noteId.rawValue), "bodyMarkdown": .string("updated"),
        "originatingActionId": .string(originatingActionId.rawValue)
      ])], operationNote) { client in
        let payload = try await client.updateNote(
          noteId,
          bodyMarkdown: "updated",
          originatingActionId: originatingActionId
        )
        return TypedContractOutcome(result: payload.result, evidence: payload.note?.noteId.rawValue)
      },
      contract("searchNotes", TypedDocuments.searchNotes, [
        "query": .string("needle"), "notebookId": .string(notebookId.rawValue),
        "tagFilter": .array([.string("research")]),
        "classFilter": .array([.string("document")]),
        "includeLinked": .bool(true), "depth": .integer(3),
        "limit": .integer(9), "offset": .integer(4)
      ], .value(.array([ContractFixture.searchResult]), evidence: "matched snippet")) { client in
        let payload = try await client.searchNotes(
          query: "needle",
          notebookId: notebookId,
          tagFilter: ["research"],
          classFilter: ["document"],
          includeLinked: true,
          depth: 3,
          limit: 9,
          offset: 4
        )
        return TypedContractOutcome(result: payload.result, evidence: payload.value?.first?.snippet)
      },
      contract("setNoteReadOnly", TypedDocuments.setNoteReadOnly, [
        "noteId": .string(noteId.rawValue), "readOnly": .bool(true)
      ], operationNote) { client in
        let payload = try await client.setNoteReadOnly(noteId, readOnly: true)
        return TypedContractOutcome(result: payload.result, evidence: payload.note?.noteId.rawValue)
      },
      contract("noteGraphNeighbors", TypedDocuments.noteGraph, [
        "noteIds": .array([.string(noteId.rawValue), .string(relatedNoteId.rawValue)]),
        "depth": .integer(3), "limit": .integer(11)
      ], .value(.array([ContractFixture.graphNeighbor]), evidence: "semantic")) { client in
        let payload = try await client.noteGraphNeighbors(
          noteIds: [noteId, relatedNoteId], depth: 3, limit: 11
        )
        return TypedContractOutcome(result: payload.result, evidence: payload.value?.first?.edgeKind)
      },
      contract("deleteNote", TypedDocuments.deleteNote, ["noteId": .string(noteId.rawValue)], .direct) { client in
        TypedContractOutcome(result: try await client.deleteNote(noteId), evidence: nil)
      }
    ]
  }

  private func notebookAndTagContracts(_ input: TypedContractInputs) -> [TypedOperationContract] {
    let noteId = input.noteId
    let notebookId = input.notebookId
    let tagId = input.tagId
    let originatingActionId = input.originatingActionId
    let richTag = input.richTag
    let notebook = input.notebook
    let notebooks = input.notebooks
    let operationNote = input.operationNote
    let operationNotebook = input.operationNotebook
    return [
      contract("getNotebook", TypedDocuments.getNotebook, ["notebookId": .string(notebookId.rawValue)], notebook) { client in
        let payload = try await client.getNotebook(notebookId)
        return TypedContractOutcome(result: payload.result, evidence: payload.value?.title)
      },
      contract("listNotebooks", TypedDocuments.listNotebooks, [
        "limit": .integer(13), "offset": .integer(5)
      ], notebooks) { client in
        let payload = try await client.listNotebooks(limit: 13, offset: 5)
        return TypedContractOutcome(result: payload.result, evidence: payload.value?.first?.title)
      },
      contract("createNotebook", TypedDocuments.createNotebook, ["input": .object([
        "title": .string("Book"), "kindTagName": .string("reference"),
        "folderPath": .array([.string("Root"), .string("Child")]),
        "metaJSON": .string(#"{"book":true}"#),
        "originatingActionId": .string(originatingActionId.rawValue)
      ])], operationNotebook) { client in
        let payload = try await client.createNotebook(
          title: "Book", kindTagName: "reference", folderPath: ["Root", "Child"],
          metaJSON: #"{"book":true}"#,
          originatingActionId: originatingActionId
        )
        return TypedContractOutcome(result: payload.result, evidence: payload.notebook?.title)
      },
      contract("deleteNotebook", TypedDocuments.deleteNotebook, [
        "notebookId": .string(notebookId.rawValue)
      ], .direct) { client in
        TypedContractOutcome(result: try await client.deleteNotebook(notebookId), evidence: nil)
      },
      contract("setNotebookReadOnly", TypedDocuments.setNotebookReadOnly, [
        "notebookId": .string(notebookId.rawValue), "readOnly": .bool(true)
      ], operationNotebook) { client in
        let payload = try await client.setNotebookReadOnly(notebookId, readOnly: true)
        return TypedContractOutcome(result: payload.result, evidence: payload.notebook?.title)
      },
      contract("listTags", TypedDocuments.listTags, [:], .value(
        .array([ContractFixture.tag]), evidence: "topic"
      )) { client in
        let payload = try await client.listTags()
        return TypedContractOutcome(result: payload.result, evidence: payload.value?.first?.name)
      },
      contract("listTagClasses", TypedDocuments.listTagClasses, [:], .value(
        .array([ContractFixture.tagClass]), evidence: "Class fixture"
      )) { client in
        let payload = try await client.listTagClasses()
        return TypedContractOutcome(result: payload.result, evidence: payload.value?.first?.label)
      },
      contract("defineTag", TypedDocuments.defineTag, ["input": .object([
        "name": .string("topic"), "classId": .string("class-1")
      ])], .operation(field: "tag", value: ContractFixture.tag, evidence: "topic")) { client in
        let payload = try await client.defineTag(name: "topic", classId: "class-1")
        return TypedContractOutcome(result: payload.result, evidence: payload.tag?.name)
      },
      contract("defineTagClass", TypedDocuments.defineTagClass, ["input": .object([
        "classId": .string("class-1"), "label": .string("Class"),
        "description": .string("Description")
      ])], .operation(field: "tagClass", value: ContractFixture.tagClass, evidence: "Class fixture")) { client in
        let payload = try await client.defineTagClass(
          classId: "class-1", label: "Class", description: "Description"
        )
        return TypedContractOutcome(result: payload.result, evidence: payload.tagClass?.label)
      },
      contract("applyNoteTags", TypedDocuments.applyNoteTags, ["input": .object([
        "noteId": .string(noteId.rawValue),
        "tags": .array([.object(["name": .string("topic"), "classId": .string("class-1")])]),
        "provenance": .string("fixture"), "assignedBy": .string("tester")
      ])], operationNote) { client in
        let payload = try await client.applyNoteTags(
          noteId: noteId, tags: [richTag], provenance: "fixture", assignedBy: "tester"
        )
        return TypedContractOutcome(result: payload.result, evidence: payload.note?.noteId.rawValue)
      },
      contract("applyNoteTagNames", TypedDocuments.applyNoteTags, ["input": .object([
        "noteId": .string(noteId.rawValue), "tags": .array([.object(["name": .string("topic")])])
      ])], operationNote) { client in
        let payload = try await client.applyNoteTags(noteId: noteId, tagNames: ["topic"])
        return TypedContractOutcome(result: payload.result, evidence: payload.note?.noteId.rawValue)
      },
      contract("removeNoteTag", TypedDocuments.removeNoteTag, [
        "noteId": .string(noteId.rawValue), "tagName": .string("topic"),
        "provenance": .string("fixture")
      ], operationNote) { client in
        let payload = try await client.removeNoteTag(
          noteId: noteId, tagName: "topic", provenance: "fixture"
        )
        return TypedContractOutcome(result: payload.result, evidence: payload.note?.noteId.rawValue)
      },
      contract("applyNotebookTags", TypedDocuments.applyNotebookTags, ["input": .object([
        "notebookId": .string(notebookId.rawValue), "tags": .array([.string("topic")]),
        "provenance": .string("fixture"), "assignedBy": .string("tester")
      ])], operationNotebook) { client in
        let payload = try await client.applyNotebookTags(
          notebookId: notebookId, tagNames: ["topic"], provenance: "fixture", assignedBy: "tester"
        )
        return TypedContractOutcome(result: payload.result, evidence: payload.notebook?.title)
      },
      contract("applyNotebookTagIDs", TypedDocuments.applyNotebookTagIDs, ["input": .object([
        "notebookId": .string(notebookId.rawValue), "tagIds": .array([.string(tagId.rawValue)]),
        "provenance": .string("fixture"), "assignedBy": .string("tester")
      ])], operationNotebook) { client in
        let payload = try await client.applyNotebookTagIDs(
          notebookId: notebookId, tagIds: [tagId], provenance: "fixture", assignedBy: "tester"
        )
        return TypedContractOutcome(result: payload.result, evidence: payload.notebook?.title)
      },
      contract("removeNotebookTagByName", TypedDocuments.removeNotebookTagByName, [
        "notebookId": .string(notebookId.rawValue), "tagName": .string("topic"),
        "provenance": .string("fixture")
      ], operationNotebook) { client in
        let payload = try await client.removeNotebookTag(
          notebookId: notebookId, tagName: "topic", provenance: "fixture"
        )
        return TypedContractOutcome(result: payload.result, evidence: payload.notebook?.title)
      },
      contract("removeNotebookTagByID", TypedDocuments.removeNotebookTagByID, [
        "notebookId": .string(notebookId.rawValue), "tagId": .string(tagId.rawValue),
        "provenance": .string("fixture")
      ], operationNotebook) { client in
        let payload = try await client.removeNotebookTag(
          notebookId: notebookId, tagId: tagId, provenance: "fixture"
        )
        return TypedContractOutcome(result: payload.result, evidence: payload.notebook?.title)
      }
    ]
  }

  private func attachmentAndCommentContracts(_ input: TypedContractInputs) -> [TypedOperationContract] {
    let noteId = input.noteId
    let notebookId = input.notebookId
    let attachment = input.attachment
    let sourceDocument = input.sourceDocument
    let pageImage = input.pageImage
    let originatingActionId = input.originatingActionId
    return [
      contract("listNoteAttachments", TypedDocuments.noteFiles, [
        "noteId": .string(noteId.rawValue)
      ], .value(.array([ContractFixture.noteAttachment]), evidence: "file-fixture")) { client in
        let payload = try await client.listNoteAttachments(noteId)
        return TypedContractOutcome(result: payload.result, evidence: payload.value?.first?.file.fileId.rawValue)
      },
      contract("listNotebookAttachments", TypedDocuments.notebookFiles, [
        "notebookId": .string(notebookId.rawValue)
      ], .value(.array([ContractFixture.notebookAttachment]), evidence: "file-fixture")) { client in
        let payload = try await client.listNotebookAttachments(notebookId)
        return TypedContractOutcome(result: payload.result, evidence: payload.value?.first?.file.fileId.rawValue)
      },
      contract("attachNoteFile", TypedDocuments.attachNoteFile, ["input": .object([
        "noteId": .string(noteId.rawValue), "contentBase64": .string("Ynl0ZXM="),
        "mediaType": .string("text/plain"), "originalFilename": .string("source.txt"),
        "role": .string("embedded"), "position": .integer(2)
      ])], .operation(field: "file", value: ContractFixture.file, evidence: "file-fixture")) { client in
        let payload = try await client.attachNoteFile(
          noteId, bytes: attachment.bytes, mediaType: attachment.mediaType,
          originalFilename: attachment.originalFilename, role: .embedded, position: 2
        )
        return TypedContractOutcome(result: payload.result, evidence: payload.file?.fileId.rawValue)
      },
      contract("attachNotebookFile", TypedDocuments.attachNotebookFile, ["input": .object([
        "notebookId": .string(notebookId.rawValue), "contentBase64": .string("Ynl0ZXM="),
        "mediaType": .string("text/plain"), "originalFilename": .string("source.txt"),
        "role": .string("source-document")
      ])], .operation(field: "file", value: ContractFixture.file, evidence: "file-fixture")) { client in
        let payload = try await client.attachNotebookFile(
          notebookId, bytes: attachment.bytes, mediaType: attachment.mediaType,
          originalFilename: attachment.originalFilename, role: .sourceDocument
        )
        return TypedContractOutcome(result: payload.result, evidence: payload.file?.fileId.rawValue)
      },
      ingestContract(
        name: "ingestNotebookPages", title: "Ingest", kindTagName: "document",
        pages: [KaibaIngestPage(bodyMarkdown: "Page", readOnly: false,
                                tags: [KaibaTagInput(name: "page-tag", classId: "class-1")],
                                metaJSON: #"{"page":2}"#, noteNumber: 2, pageImage: pageImage)],
        sourceDocument: sourceDocument, metaJSON: #"{"ingest":true}"#,
        originatingActionId: originatingActionId
      ),
      ingestDocumentContract(
        title: "Document", pages: [KaibaIngestPage(bodyMarkdown: "Document page", noteNumber: 4)],
        sourceDocument: sourceDocument, metaJSON: #"{"document":true}"#,
        originatingActionId: originatingActionId
      ),
      contract("listNoteComments", TypedDocuments.noteComments, [
        "noteId": .string(noteId.rawValue)
      ], .value(.array([ContractFixture.comment]), evidence: "fixture comment")) { client in
        let payload = try await client.listNoteComments(noteId)
        return TypedContractOutcome(result: payload.result, evidence: payload.value?.first?.bodyMarkdown)
      },
      contract("addNoteComment", TypedDocuments.addNoteComment, ["input": .object([
        "noteId": .string(noteId.rawValue), "bodyMarkdown": .string("comment"),
        "author": .string("author")
      ])], .operation(field: "comment", value: ContractFixture.comment, evidence: "fixture comment")) { client in
        let payload = try await client.addNoteComment(noteId, bodyMarkdown: "comment", author: "author")
        return TypedContractOutcome(result: payload.result, evidence: payload.comment?.bodyMarkdown)
      },
      contract("addNotebookComment", TypedDocuments.addNotebookComment, ["input": .object([
        "notebookId": .string(notebookId.rawValue), "bodyMarkdown": .string("comment"),
        "author": .string("author")
      ])], .operation(field: "comment", value: ContractFixture.comment, evidence: "fixture comment")) { client in
        let payload = try await client.addNotebookComment(
          notebookId, bodyMarkdown: "comment", author: "author"
        )
        return TypedContractOutcome(result: payload.result, evidence: payload.comment?.bodyMarkdown)
      },
      contract("listNotebookComments", TypedDocuments.notebookComments, [
        "notebookId": .string(notebookId.rawValue)
      ], .value(.array([ContractFixture.comment]), evidence: "fixture comment")) { client in
        let payload = try await client.listNotebookComments(notebookId)
        return TypedContractOutcome(result: payload.result, evidence: payload.value?.first?.bodyMarkdown)
      }
    ]
  }

  private func conversationAndMemoryContracts(_ input: TypedContractInputs) -> [TypedOperationContract] {
    let noteId = input.noteId
    let relatedNoteId = input.relatedNoteId
    let notebookId = input.notebookId
    let notebook = input.notebook
    let operationNotebook = input.operationNotebook
    let originatingActionId = input.originatingActionId
    return [
      contract("listNoteConversations", TypedDocuments.noteConversations, [
        "noteId": .string(noteId.rawValue), "limit": .integer(12)
      ], .value(.array([ContractFixture.conversation]), evidence: "Conversation fixture")) { client in
        let payload = try await client.listNoteConversations(noteId, limit: 12)
        return TypedContractOutcome(result: payload.result, evidence: payload.value?.first?.title)
      },
      contract("listNotebookConversations", TypedDocuments.notebookConversations, [
        "notebookId": .string(notebookId.rawValue), "limit": .integer(14)
      ], .value(.array([ContractFixture.conversation]), evidence: "Conversation fixture")) { client in
        let payload = try await client.listNotebookConversations(notebookId, limit: 14)
        return TypedContractOutcome(result: payload.result, evidence: payload.value?.first?.title)
      },
      contract("saveConversation", TypedDocuments.saveConversation, ["input": .object([
        "title": .string("Conversation"), "assignedBy": .string("tester"),
        "originatingActionId": .string(originatingActionId.rawValue),
        "transcript": .array([.object([
          "userMarkdown": .string("question"), "assistantMarkdown": .string("answer"),
          "sourceNoteIds": .array([.string(noteId.rawValue), .string(relatedNoteId.rawValue)])
        ])])
      ])], operationNotebook) { client in
        let payload = try await client.saveConversation(
          title: "Conversation",
          transcript: [KaibaConversationTurn(
            userMarkdown: "question", assistantMarkdown: "answer",
            sourceNoteIds: [noteId, relatedNoteId]
          )],
          assignedBy: "tester",
          originatingActionId: originatingActionId
        )
        return TypedContractOutcome(result: payload.result, evidence: payload.notebook?.title)
      },
      contract("noteLinks", TypedDocuments.noteLinks, ["noteId": .string(noteId.rawValue)], .value(
        .array([ContractFixture.link]), evidence: "semantic"
      )) { client in
        let payload = try await client.noteLinks(noteId)
        return TypedContractOutcome(result: payload.result, evidence: payload.value?.first?.linkKind)
      },
      contract("longTermMemoryNotebook", TypedDocuments.longTermMemoryNotebook, [:], notebook) { client in
        let payload = try await client.longTermMemoryNotebook()
        return TypedContractOutcome(result: payload.result, evidence: payload.value?.title)
      },
      contract("appendLongTermMemory", TypedDocuments.appendLongTermMemory, ["input": .object([
        "idempotencyKey": .string("memory-key"),
        "entries": .array([.object([
          "bodyMarkdown": .string("memory"), "topicTags": .array([.string("topic")]),
          "sourceNoteIds": .array([.string(noteId.rawValue)]),
          "relatedNoteIds": .array([.string(relatedNoteId.rawValue)]),
          "periodStart": .string("2026-09-01T00:00:00Z"),
          "periodEnd": .string("2026-09-02T00:00:00Z"),
          "metaJSON": .string(#"{"memory":true}"#)
        ])])
      ])], .append) { client in
        let payload = try await client.appendLongTermMemory(
          entries: [KaibaLongTermMemoryEntry(
            bodyMarkdown: "memory", topicTags: ["topic"], sourceNoteIds: [noteId],
            relatedNoteIds: [relatedNoteId], periodStart: "2026-09-01T00:00:00Z",
            periodEnd: "2026-09-02T00:00:00Z", metaJSON: #"{"memory":true}"#
          )],
          idempotencyKey: "memory-key"
        )
        let noteID = payload.notes.first?.noteId.rawValue ?? "nil"
        return TypedContractOutcome(result: payload.result, evidence: "\(noteID)|\(payload.idempotentReplay)")
      },
      contract("recallLongTermMemory", TypedDocuments.recallLongTermMemory, ["input": .object([
        "query": .string("memory"), "limit": .integer(6), "includeAssociations": .bool(true),
        "associationDepth": .integer(3), "recencyWeight": .double(0.75)
      ])], .value(.array([ContractFixture.recallHit]), evidence: "memory snippet")) { client in
        let payload = try await client.recallLongTermMemory(
          query: "memory", limit: 6, includeAssociations: true,
          associationDepth: 3, recencyWeight: 0.75
        )
        return TypedContractOutcome(result: payload.result, evidence: payload.value?.first?.snippet)
      },
      contract("linkLongTermMemoryAssociations", TypedDocuments.linkLongTermMemory, [
        "noteId": .string(noteId.rawValue), "limit": .integer(5)
      ], .value(.array([ContractFixture.link]), evidence: "semantic")) { client in
        let payload = try await client.linkLongTermMemoryAssociations(noteId: noteId, limit: 5)
        return TypedContractOutcome(result: payload.result, evidence: payload.value?.first?.linkKind)
      }
    ]
  }

  private func contract(
    _ name: String,
    _ document: String,
    _ variables: [String: KaibaJSONValue],
    _ response: TypedResponseFixture,
    invoke: @escaping @Sendable (KaibaClient) async throws -> TypedContractOutcome
  ) -> TypedOperationContract {
    TypedOperationContract(
      name: name, document: document, variables: variables, response: response, invoke: invoke
    )
  }

  private func ingestContract(
    name: String,
    title: String,
    kindTagName: String?,
    pages: [KaibaIngestPage],
    sourceDocument: KaibaInlineAttachment?,
    metaJSON: String?,
    originatingActionId: KaibaAutoActionID?
  ) -> TypedOperationContract {
    contract(name, TypedDocuments.ingestNotebookPages, ["input": ContractFixture.ingestInput(
      idempotencyKey: "typed-ingest-contract",
      title: title, kindTagName: kindTagName, pages: pages,
      sourceDocument: sourceDocument, metaJSON: metaJSON,
      originatingActionId: originatingActionId
    )], .operation(field: "notebook", value: ContractFixture.notebook, evidence: "Notebook fixture")) { client in
      let payload = try await client.ingestNotebookPages(
        idempotencyKey: "typed-ingest-contract",
        title: title, pages: pages, kindTagName: kindTagName,
        sourceDocument: sourceDocument, metaJSON: metaJSON,
        originatingActionId: originatingActionId
      )
      return TypedContractOutcome(result: payload.result, evidence: payload.notebook?.title)
    }
  }

  private func ingestDocumentContract(
    title: String,
    pages: [KaibaIngestPage],
    sourceDocument: KaibaInlineAttachment?,
    metaJSON: String?,
    originatingActionId: KaibaAutoActionID?
  ) -> TypedOperationContract {
    contract("ingestDocument", TypedDocuments.ingestNotebookPages, ["input": ContractFixture.ingestInput(
      idempotencyKey: "typed-document-ingest-contract",
      title: title, kindTagName: nil, pages: pages,
      sourceDocument: sourceDocument, metaJSON: metaJSON,
      originatingActionId: originatingActionId
    )], .operation(field: "notebook", value: ContractFixture.notebook, evidence: "Notebook fixture")) { client in
      let payload = try await client.ingestDocument(
        idempotencyKey: "typed-document-ingest-contract",
        title: title, pages: pages, sourceDocument: sourceDocument, metaJSON: metaJSON,
        originatingActionId: originatingActionId
      )
      return TypedContractOutcome(result: payload.result, evidence: payload.notebook?.title)
    }
  }
}

private enum ContractFixture {
  static func control(name: String, accepted: Bool) -> KaibaJSONValue {
    .object([
      "accepted": .bool(accepted),
      "status": .string(accepted ? "ok" : "forbidden"),
      "diagnostics": .array([.string("\(accepted ? "success" : "rejected")-\(name)")])
    ])
  }

  static func decodedControl(name: String, accepted: Bool) -> KaibaControlPlaneResult {
    KaibaControlPlaneResult(
      accepted: accepted,
      status: accepted ? .ok : .forbidden,
      diagnostics: ["\(accepted ? "success" : "rejected")-\(name)"]
    )
  }

  static let tag: KaibaJSONValue = .object([
    "tagId": .string("tag-fixture"), "name": .string("topic"),
    "classId": .string("class-fixture"), "parentTagId": .null,
    "isSystem": .bool(false), "createdAt": .string("2026-09-04T00:00:00Z")
  ])

  static let tagClass: KaibaJSONValue = .object([
    "classId": .string("class-fixture"), "label": .string("Class fixture"),
    "description": .string("Fixture class"), "isSystem": .bool(false),
    "createdAt": .string("2026-09-04T00:00:00Z")
  ])

  static let note: KaibaJSONValue = .object([
    "noteId": .string("note-fixture"), "notebookId": .string("notebook-fixture"),
    "noteNumber": .integer(7), "title": .string("Note fixture"),
    "bodyMarkdown": .string("Fixture body"), "readOnly": .bool(false),
    "createdAt": .string("2026-09-04T00:00:00Z"),
    "updatedAt": .string("2026-09-04T01:00:00Z"), "metaJSON": .string(#"{"fixture":true}"#),
    "tags": .array([]), "createdBy": .string("user-fixture"), "updatedBy": .string("user-fixture")
  ])

  static let notebook: KaibaJSONValue = .object([
    "notebookId": .string("notebook-fixture"), "title": .string("Notebook fixture"),
    "readOnly": .bool(false), "createdAt": .string("2026-09-04T00:00:00Z"),
    "updatedAt": .string("2026-09-04T01:00:00Z"), "metaJSON": .string(#"{"fixture":true}"#),
    "tags": .array([]), "firstNotePreview": .string("Preview"), "noteCount": .integer(1),
    "libraryId": .string("library-fixture"), "ownerUserId": .string("user-fixture"),
    "createdBy": .string("user-fixture"), "updatedBy": .string("user-fixture")
  ])

  static let file: KaibaJSONValue = .object([
    "fileId": .string("file-fixture"), "storageKind": .string("s3"),
    "localPath": .null, "s3Profile": .string("archive"),
    "s3Bucket": .string("notes"), "s3Key": .string("fixtures/file-fixture"),
    "mediaType": .string("text/plain"), "byteSize": .integer(5),
    "sha256": .string("fixture-sha"), "originalFilename": .string("fixture.txt"),
    "createdAt": .string("2026-09-04T00:00:00Z"),
    "migratedAt": .string("2026-09-04T02:00:00Z")
  ])

  static let noteAttachment: KaibaJSONValue = .object([
    "noteId": .string("note-fixture"), "role": .string("embedded"),
    "position": .integer(2), "file": file
  ])

  static let notebookAttachment: KaibaJSONValue = .object([
    "notebookId": .string("notebook-fixture"), "role": .string("source-document"), "file": file
  ])

  static let comment: KaibaJSONValue = .object([
    "commentId": .string("comment-fixture"), "noteId": .string("note-fixture"),
    "notebookId": .string("notebook-fixture"), "bodyMarkdown": .string("fixture comment"),
    "author": .string("fixture author"), "createdAt": .string("2026-09-04T00:00:00Z")
  ])

  static let conversation: KaibaJSONValue = .object([
    "notebookId": .string("notebook-fixture"), "title": .string("Conversation fixture"),
    "updatedAt": .string("2026-09-04T01:00:00Z"), "turnCount": .integer(2),
    "subjectNoteId": .string("note-fixture"), "subjectNotebookId": .string("notebook-fixture")
  ])

  static let link: KaibaJSONValue = .object([
    "fromNoteId": .string("note-fixture"), "toNoteId": .string("note-related"),
    "linkKind": .string("semantic"), "provenance": .string("fixture"),
    "createdAt": .string("2026-09-04T00:00:00Z")
  ])

  static let searchResult: KaibaJSONValue = .object([
    "note": note, "snippet": .string("matched snippet"), "rank": .double(0.9),
    "matchedTags": .array([tag]), "isLinkedNeighbor": .bool(true), "termCoverage": .double(0.8)
  ])

  static let graphNeighbor: KaibaJSONValue = .object([
    "seedNoteId": .string("note-seed"), "note": note, "edgeKind": .string("semantic"),
    "weight": .double(0.7), "hopCount": .integer(2),
    "pathNoteIds": .array([.string("note-seed"), .string("note-fixture")])
  ])

  static let recallHit: KaibaJSONValue = .object([
    "note": note, "snippet": .string("memory snippet"), "rank": .double(0.95),
    "isAssociation": .bool(true), "edgeKind": .string("semantic"), "weight": .double(0.6),
    "hopCount": .integer(1), "pathNoteIds": .array([.string("note-fixture")])
  ])

  static func ingestInput(
    idempotencyKey: String,
    title: String,
    kindTagName: String?,
    pages: [KaibaIngestPage],
    sourceDocument: KaibaInlineAttachment?,
    metaJSON: String?,
    originatingActionId: KaibaAutoActionID?
  ) -> KaibaJSONValue {
    var object: [String: KaibaJSONValue] = [
      "idempotencyKey": .string(idempotencyKey),
      "title": .string(title),
      "pages": .array(pages.map { page in
        var pageObject: [String: KaibaJSONValue] = [
          "bodyMarkdown": .string(page.bodyMarkdown), "readOnly": .bool(page.readOnly),
          "tags": .array(page.tags.map { .object([
            "name": .string($0.name), "classId": $0.classId.map(KaibaJSONValue.string) ?? .null
          ]) })
        ]
        if let metaJSON = page.metaJSON { pageObject["metaJSON"] = .string(metaJSON) }
        if let noteNumber = page.noteNumber { pageObject["noteNumber"] = .integer(noteNumber) }
        if let pageImage = page.pageImage { pageObject["pageImage"] = attachment(pageImage) }
        return .object(pageObject)
      })
    ]
    if let kindTagName { object["kindTagName"] = .string(kindTagName) }
    if let sourceDocument { object["sourceDocument"] = attachment(sourceDocument) }
    if let metaJSON { object["metaJSON"] = .string(metaJSON) }
    if let originatingActionId { object["originatingActionId"] = .string(originatingActionId.rawValue) }
    return .object(object)
  }

  private static func attachment(_ value: KaibaInlineAttachment) -> KaibaJSONValue {
    var object: [String: KaibaJSONValue] = [
      "contentBase64": .string(value.bytes.base64EncodedString()),
      "mediaType": .string(value.mediaType)
    ]
    if let filename = value.originalFilename { object["originalFilename"] = .string(filename) }
    if let role = value.role { object["role"] = .string(role.rawValue) }
    return .object(object)
  }
}

private enum TypedDocuments {
  private static let tagFields = "tag { tagId name classId parentTagId isSystem createdAt } provenance assignedBy deletable createdAt"
  private static let tagDefinitionFields = "tagId name classId parentTagId isSystem createdAt"
  private static let noteFields = "noteId notebookId noteNumber title bodyMarkdown readOnly createdAt updatedAt metaJSON tags { \(tagFields) } createdBy updatedBy"
  private static let notebookFields = "notebookId title readOnly createdAt updatedAt metaJSON tags { \(tagFields) } firstNotePreview noteCount libraryId ownerUserId createdBy updatedBy"
  private static let fileFields = "fileId storageKind localPath s3Profile s3Bucket s3Key mediaType byteSize sha256 originalFilename createdAt migratedAt"

  static let getNote = "query KaibaGetNote($noteId: String!) { root: note(noteId: $noteId) { result { accepted status diagnostics } value { \(noteFields) } } }"
  static let listNotes = """
  query KaibaListNotes($notebookId: String, $tagFilter: [String!], $limit: Int, $offset: Int) {
    root: notes(notebookId: $notebookId, tagFilter: $tagFilter, limit: $limit, offset: $offset) {
      result { accepted status diagnostics } value { \(noteFields) }
    }
  }
  """
  static let createNote = """
  mutation KaibaCreateNote($input: CreateNoteInput!) {
    root: createNote(input: $input) {
      result { accepted status diagnostics } note { \(noteFields) }
      notebook { \(notebookFields) } notes { \(noteFields) }
    }
  }
  """
  static let updateNote = "mutation KaibaUpdateNote($input: UpdateNoteInput!) { root: updateNote(input: $input) { result { accepted status diagnostics } note { \(noteFields) } } }"
  static let searchNotes = """
  query KaibaSearchNotes(
    $query: String!, $notebookId: String, $tagFilter: [String!], $classFilter: [String!],
    $includeLinked: Boolean, $depth: Int, $limit: Int, $offset: Int
  ) {
    root: searchNotes(
      query: $query, notebookId: $notebookId, tagFilter: $tagFilter,
      classFilter: $classFilter, includeLinked: $includeLinked, depth: $depth,
      limit: $limit, offset: $offset
    ) {
      result { accepted status diagnostics }
      value { note { \(noteFields) } snippet rank matchedTags { \(tagDefinitionFields) }
        isLinkedNeighbor termCoverage }
    }
  }
  """
  static let setNoteReadOnly =
    "mutation KaibaSetNoteReadOnly($noteId: String!, $readOnly: Boolean!) { "
    + "root: setNoteReadOnly(noteId: $noteId, readOnly: $readOnly) { "
    + "result { accepted status diagnostics } note { \(noteFields) } } }"
  static let noteGraph = """
  query KaibaNoteGraph($noteIds: [String!]!, $depth: Int, $limit: Int) {
    root: noteGraphNeighbors(noteIds: $noteIds, depth: $depth, limit: $limit) {
      result { accepted status diagnostics }
      value { seedNoteId note { \(noteFields) } edgeKind weight hopCount pathNoteIds }
    }
  }
  """
  static let deleteNote = "mutation KaibaDeleteNote($noteId: String!) { root: deleteNote(noteId: $noteId) { accepted status diagnostics } }"
  static let getNotebook = "query KaibaGetNotebook($notebookId: String!) { root: notebook(notebookId: $notebookId) { result { accepted status diagnostics } value { \(notebookFields) } } }"
  static let listNotebooks = "query KaibaListNotebooks($limit: Int, $offset: Int) { root: notebooks(limit: $limit, offset: $offset) { result { accepted status diagnostics } value { \(notebookFields) } } }"
  static let createNotebook = "mutation KaibaCreateNotebook($input: CreateNotebookInput!) { root: createNotebook(input: $input) { result { accepted status diagnostics } notebook { \(notebookFields) } } }"
  static let deleteNotebook = "mutation KaibaDeleteNotebook($notebookId: String!) { root: deleteNotebook(notebookId: $notebookId) { accepted status diagnostics } }"
  static let setNotebookReadOnly = """
  mutation KaibaSetNotebookReadOnly($notebookId: String!, $readOnly: Boolean!) {
    root: setNotebookReadOnly(notebookId: $notebookId, readOnly: $readOnly) {
      result { accepted status diagnostics } notebook { \(notebookFields) }
    }
  }
  """
  static let listTags = "query KaibaTags { root: tags { result { accepted status diagnostics } value { tagId name classId parentTagId isSystem createdAt } } }"
  static let listTagClasses = "query KaibaTagClasses { root: tagClasses { result { accepted status diagnostics } value { classId label description isSystem createdAt } } }"
  static let defineTag = "mutation KaibaDefineTag($input: DefineNoteTagInput!) { root: defineNoteTag(input: $input) { result { accepted status diagnostics } tag { \(tagDefinitionFields) } } }"
  static let defineTagClass = """
  mutation KaibaDefineTagClass($input: DefineNoteTagClassInput!) {
    root: defineNoteTagClass(input: $input) {
      result { accepted status diagnostics }
      tagClass { classId label description isSystem createdAt }
    }
  }
  """
  static let applyNoteTags = "mutation KaibaApplyNoteTags($input: ApplyNoteTagsInput!) { root: applyNoteTags(input: $input) { result { accepted status diagnostics } note { \(noteFields) } } }"
  static let removeNoteTag = """
  mutation KaibaRemoveNoteTag($noteId: String!, $tagName: String!, $provenance: String) {
    root: removeNoteTag(noteId: $noteId, tagName: $tagName, provenance: $provenance) {
      result { accepted status diagnostics } note { \(noteFields) }
    }
  }
  """
  static let applyNotebookTags = "mutation KaibaApplyNotebookTags($input: ApplyNotebookTagsInput!) { root: applyNotebookTags(input: $input) { result { accepted status diagnostics } notebook { \(notebookFields) } } }"
  static let applyNotebookTagIDs =
    "mutation KaibaApplyNotebookTagIDs($input: ApplyNotebookTagIdsInput!) { "
    + "root: applyNotebookTagIds(input: $input) { result { accepted status diagnostics } "
    + "notebook { \(notebookFields) } } }"
  static let removeNotebookTagByName = removeNotebookTag(argument: "tagName", operation: "removeNotebookTag")
  static let removeNotebookTagByID = removeNotebookTag(argument: "tagId", operation: "removeNotebookTagById")
  static let noteFiles = "query KaibaNoteFiles($noteId: String!) { root: noteFiles(noteId: $noteId) { result { accepted status diagnostics } value { noteId role position file { \(fileFields) } } } }"
  static let notebookFiles = "query KaibaNotebookFiles($notebookId: String!) { root: notebookFiles(notebookId: $notebookId) { result { accepted status diagnostics } value { notebookId role file { \(fileFields) } } } }"
  static let attachNoteFile = "mutation KaibaAttachNoteFile($input: AttachNoteFileInput!) { root: attachNoteFile(input: $input) { result { accepted status diagnostics } file { \(fileFields) } } }"
  static let attachNotebookFile = "mutation KaibaAttachNotebookFile($input: AttachNotebookFileInput!) { root: attachNotebookFile(input: $input) { result { accepted status diagnostics } file { \(fileFields) } } }"
  static let ingestNotebookPages = """
  mutation KaibaIngestNotebookPages($input: IngestNotebookPagesInput!) {
    root: ingestNotebookPages(input: $input) {
      result { accepted status diagnostics } notebook { \(notebookFields) }
      notes { \(noteFields) }
      noteFiles { noteId role position file { \(fileFields) } }
      notebookFiles { notebookId role file { \(fileFields) } }
    }
  }
  """
  static let noteComments =
    "query KaibaNoteComments($noteId: String!) { root: noteComments(noteId: $noteId) { "
    + "result { accepted status diagnostics } "
    + "value { commentId noteId notebookId bodyMarkdown author createdAt } } }"
  static let addNoteComment =
    "mutation KaibaAddNoteComment($input: AddNoteCommentInput!) { root: addNoteComment(input: $input) { "
    + "result { accepted status diagnostics } "
    + "comment { commentId noteId notebookId bodyMarkdown author createdAt } } }"
  static let addNotebookComment = """
  mutation KaibaAddNotebookComment($input: AddNotebookCommentInput!) {
    root: addNotebookComment(input: $input) {
      result { accepted status diagnostics }
      comment { commentId noteId notebookId bodyMarkdown author createdAt }
    }
  }
  """
  static let notebookComments = """
  query KaibaNotebookComments($notebookId: String!) {
    root: notebookComments(notebookId: $notebookId) {
      result { accepted status diagnostics }
      value { commentId noteId notebookId bodyMarkdown author createdAt }
    }
  }
  """
  static let noteConversations = """
  query KaibaNoteConversations($noteId: String!, $limit: Int) {
    root: noteConversations(noteId: $noteId, limit: $limit) {
      result { accepted status diagnostics }
      value { notebookId title updatedAt turnCount subjectNoteId subjectNotebookId }
    }
  }
  """
  static let notebookConversations = """
  query KaibaNotebookConversations($notebookId: String!, $limit: Int) {
    root: notebookConversations(notebookId: $notebookId, limit: $limit) {
      result { accepted status diagnostics }
      value { notebookId title updatedAt turnCount subjectNoteId subjectNotebookId }
    }
  }
  """
  static let saveConversation = """
  mutation KaibaSaveConversation($input: SaveNoteConversationInput!) {
    root: saveNoteConversation(input: $input) {
      result { accepted status diagnostics } notebook { \(notebookFields) }
      notes { \(noteFields) }
    }
  }
  """
  static let noteLinks = "query KaibaNoteLinks($noteId: String!) { root: noteLinks(noteId: $noteId) { result { accepted status diagnostics } value { fromNoteId toNoteId linkKind provenance createdAt } } }"
  static let longTermMemoryNotebook = "query KaibaLongTermMemoryNotebook { root: longTermMemoryNotebook { result { accepted status diagnostics } value { \(notebookFields) } } }"
  static let appendLongTermMemory =
    "mutation KaibaAppendLongTermMemory($input: AppendLongTermMemoryInput!) { "
    + "root: appendLongTermMemory(input: $input) { result { accepted status diagnostics } "
    + "notes { \(noteFields) } idempotentReplay } }"
  static let recallLongTermMemory = """
  mutation KaibaRecallLongTermMemory($input: RecallLongTermMemoryInput!) {
    root: recallLongTermMemory(input: $input) {
      result { accepted status diagnostics }
      value { note { \(noteFields) } snippet rank isAssociation edgeKind weight hopCount pathNoteIds }
    }
  }
  """
  static let linkLongTermMemory = """
  mutation KaibaLinkLongTermMemory($noteId: String!, $limit: Int) {
    root: linkLongTermMemoryAssociations(noteId: $noteId, limit: $limit) {
      result { accepted status diagnostics }
      value { fromNoteId toNoteId linkKind provenance createdAt }
    }
  }
  """

  private static func removeNotebookTag(argument: String, operation: String) -> String {
    """
    mutation KaibaRemoveNotebookTag(
      $notebookId: String!, $\(argument): String!, $provenance: String
    ) {
      root: \(operation)(
        notebookId: $notebookId, \(argument): $\(argument), provenance: $provenance
      ) { result { accepted status diagnostics } notebook { \(notebookFields) } }
    }
    """
  }
}
