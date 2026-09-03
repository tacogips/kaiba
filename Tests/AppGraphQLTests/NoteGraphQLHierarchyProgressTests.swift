import Foundation

import AppCore
@testable import AppGraphQL
import XCTest

final class NoteGraphQLHierarchyProgressTests: XCTestCase {
  func testDefineTagCreateOnlyUsesScopedIdentityDomainsAtomically() async throws {
    let service = try makeHierarchyGraphQLService()
    let first = await service.defineTag(
      GraphQLDefineNoteTagInput(name: "Web Folder", classId: TagClassID("folder"), createOnly: true)
    )
    XCTAssertTrue(first.result.accepted)
    let tagId = try XCTUnwrap(first.tag?.tagId)
    let executor = NoteGraphQLDocumentExecutor(service: service)
    let response = await executor.execute(GraphQLDocumentRequest(
      query: """
      mutation DefineFolder($input: DefineNoteTagInput!) {
        defineNoteTag(input: $input) {
          result { accepted status diagnostics }
          tag { tagId classId parentTagId }
        }
      }
      """,
      variables: [
        "input": .object([
          "name": .string("Web Folder"),
          "classId": .string("topic"),
          "createOnly": .bool(true)
        ])
      ],
      operationName: "DefineFolder"
    ))
    let payload = try payloadObject(response.body, field: "defineNoteTag")
    let result = try objectValue(payload["result"], field: "result")
    XCTAssertEqual(result["accepted"], .bool(true))
    XCTAssertEqual(result["status"], .string("ok"))
    let duplicateTopic = await service.defineTag(
      GraphQLDefineNoteTagInput(name: "Web Folder", classId: TagClassID("topic"), createOnly: true)
    )
    XCTAssertFalse(duplicateTopic.result.accepted)
    XCTAssertEqual(duplicateTopic.result.status, "invalid_request")
    let persisted = await service.tags()
    let tag = try XCTUnwrap(persisted.value?.first { $0.tagId == tagId })
    XCTAssertEqual(tag.classId, TagClassID("folder"))
    XCTAssertNil(tag.parentTagId)
    XCTAssertEqual(
      persisted.value?.filter { $0.name == "Web Folder" }.compactMap(\.classId).sorted(),
      [.folder, .topic]
    )

    let decoded = try JSONDecoder().decode(
      GraphQLDefineNoteTagInput.self,
      from: Data(#"{"name":"Compatible"}"#.utf8)
    )
    XCTAssertFalse(decoded.createOnly)
    XCTAssertTrue(GraphQLContractProjector.schemaContract.contains("createOnly: Boolean"))
  }

  func testGraphQLProjectsHierarchyFolderAndExpandedNotebookFilters() async throws {
    let service = try makeHierarchyGraphQLService()
    let parentResult = await service.defineTag(
      GraphQLDefineNoteTagInput(name: "portfolio", classId: TagClassID("topic"))
    )
    let parentId = try XCTUnwrap(parentResult.tag?.tagId)
    let childResult = await service.defineTag(
      GraphQLDefineNoteTagInput(
        name: "project",
        classId: TagClassID("topic"),
        parentTagId: parentId
      )
    )
    XCTAssertEqual(childResult.tag?.parentTagId, parentId)

    let notebookResult = await service.createNotebook(
      GraphQLCreateNotebookInput(title: "Project Notebook")
    )
    let notebookId = try XCTUnwrap(notebookResult.notebook?.notebookId)
    let tagged = await service.applyNotebookTags(
      GraphQLApplyNotebookTagsInput(
        notebookId: notebookId,
        tags: ["project"],
        provenance: "human",
        assignedBy: "graphql-hierarchy-test"
      )
    )
    XCTAssertTrue(tagged.result.accepted)

    let parentFiltered = await service.notebooks(tagFilterIdGroups: [[parentId]])
    XCTAssertEqual(parentFiltered.value?.map(\.notebookId), [notebookId])

    let folderResult = await service.defineTag(
      GraphQLDefineNoteTagInput(name: "Work", classId: TagClassID("folder"))
    )
    XCTAssertEqual(folderResult.tag?.classId, .folder)
    let folderTagged = await service.applyNotebookTags(
      GraphQLApplyNotebookTagsInput(
        notebookId: notebookId,
        tags: ["Work"],
        provenance: "human",
        assignedBy: "graphql-hierarchy-test"
      )
    )
    XCTAssertTrue(
      folderTagged.notebook?.tags.contains {
        $0.tag.name == "Work" && $0.tag.classId == TagClassID("folder")
      } == true
    )
  }

  func testDocumentExecutorValidatesTagIdGroupsWithoutFailingOpen() async throws {
    let service = try makeHierarchyGraphQLService()
    let folder = await service.defineTag(
      GraphQLDefineNoteTagInput(name: "ID Root", classId: TagClassID("folder"))
    )
    let folderId = try XCTUnwrap(folder.tag?.tagId)
    let created = await service.createNotebook(GraphQLCreateNotebookInput(title: "ID matched"))
    let notebookId = try XCTUnwrap(created.notebook?.notebookId)
    _ = await service.applyNotebookTagIds(GraphQLApplyNotebookTagIdsInput(
      notebookId: notebookId,
      tagIds: [folderId]
    ))
    let executor = NoteGraphQLDocumentExecutor(service: service)
    let query = """
    query GroupedById($tagFilterIdGroups: [[String!]!]) {
      notebooks(tagFilterIdGroups: $tagFilterIdGroups) {
        result { accepted status diagnostics }
        value { notebookId }
      }
    }
    """

    for malformedVariables: JSONObject in [
      ["tagFilterIdGroups": .string(folderId.rawValue)],
      ["tagFilterIdGroups": .array([.string(folderId.rawValue)])],
      ["tagFilterIdGroups": .array([.array([.string(folderId.rawValue), .integer(1)])])]
    ] {
      let response = await executor.execute(GraphQLDocumentRequest(
        query: query,
        variables: malformedVariables,
        operationName: "GroupedById"
      ))
      XCTAssertNotNil(response.body["errors"])
      XCTAssertEqual(
        try objectValue(response.body["data"], field: "data")["notebooks"],
        .null
      )
    }

    for optionalVariables: JSONObject in [
      [:],
      ["tagFilterIdGroups": .null],
      ["tagFilterIdGroups": .array([.array([])])]
    ] {
      let response = await executor.execute(GraphQLDocumentRequest(
        query: query,
        variables: optionalVariables,
        operationName: "GroupedById"
      ))
      let payload = try payloadObject(response.body, field: "notebooks")
      guard case let .array(values)? = payload["value"] else {
        return XCTFail("expected empty ID groups to preserve the unfiltered request")
      }
      XCTAssertTrue(values.contains { value in
        guard case let .object(notebook) = value else { return false }
        return notebook["notebookId"] == .string(notebookId.rawValue)
      })
    }

    let unknown = await executor.execute(GraphQLDocumentRequest(
      query: query,
      variables: ["tagFilterIdGroups": .array([.array([.string("unknown-id")])])],
      operationName: "GroupedById"
    ))
    XCTAssertEqual(try payloadObject(unknown.body, field: "notebooks")["value"], .array([]))

    for oversizedGroups: [[JSONValue]] in [
      Array(
        repeating: [.string(folderId.rawValue)],
        count: 65
      ),
      [Array(
        repeating: .string(folderId.rawValue),
        count: 257
      )]
    ] {
      let response = await executor.execute(GraphQLDocumentRequest(
        query: query,
        variables: [
          "tagFilterIdGroups": .array(oversizedGroups.map(JSONValue.array))
        ],
        operationName: "GroupedById"
      ))
      let payload = try payloadObject(response.body, field: "notebooks")
      let result = try objectValue(payload["result"], field: "notebooks.result")
      XCTAssertEqual(result["accepted"], JSONValue.bool(false))
      XCTAssertEqual(result["status"], JSONValue.string("invalid_request"))
      XCTAssertEqual(payload["value"], JSONValue.null)
    }
  }

  func testDocumentExecutorUsesTagIdsForAmbiguousFolderMutationsAndFilters() async throws {
    let service = try makeHierarchyGraphQLService()
    let firstParent = await service.defineTag(
      GraphQLDefineNoteTagInput(name: "Workflow A", classId: TagClassID("folder"))
    )
    let secondParent = await service.defineTag(
      GraphQLDefineNoteTagInput(name: "Workflow B", classId: TagClassID("folder"))
    )
    let firstHistory = await service.defineTag(GraphQLDefineNoteTagInput(
      name: "history",
      classId: TagClassID("folder"),
      parentTagId: try XCTUnwrap(firstParent.tag?.tagId)
    ))
    let secondHistory = await service.defineTag(GraphQLDefineNoteTagInput(
      name: "history",
      classId: TagClassID("folder"),
      parentTagId: try XCTUnwrap(secondParent.tag?.tagId)
    ))
    let firstHistoryId = try XCTUnwrap(firstHistory.tag?.tagId)
    let secondHistoryId = try XCTUnwrap(secondHistory.tag?.tagId)
    XCTAssertNotEqual(firstHistoryId, secondHistoryId)
    let created = await service.createNotebook(GraphQLCreateNotebookInput(title: "ID scoped"))
    let notebookId = try XCTUnwrap(created.notebook?.notebookId)
    let executor = NoteGraphQLDocumentExecutor(service: service)

    let applied = await executor.execute(GraphQLDocumentRequest(
      query: """
      mutation ApplyById($input: ApplyNotebookTagIdsInput!) {
        applyNotebookTagIds(input: $input) {
          result { accepted status diagnostics }
          notebook { notebookId tags { tag { tagId name parentTagId } } }
        }
      }
      """,
      variables: [
        "input": .object([
          "notebookId": .string(notebookId.rawValue),
          "tagIds": .array([.string(secondHistoryId.rawValue)]),
          "provenance": .string("human")
        ])
      ],
      operationName: "ApplyById"
    ))
    let appliedPayload = try payloadObject(applied.body, field: "applyNotebookTagIds")
    let appliedResult = try objectValue(appliedPayload["result"], field: "result")
    XCTAssertEqual(appliedResult["accepted"], .bool(true))

    let filtered = await executor.execute(GraphQLDocumentRequest(
      query: """
      query FilterById($tagFilterIdGroups: [[String!]!]) {
        notebooks(tagFilterIdGroups: $tagFilterIdGroups) {
          result { accepted status }
          value { notebookId }
        }
      }
      """,
      variables: [
        "tagFilterIdGroups": .array([
          .array([.string(secondHistoryId.rawValue), .string(secondHistoryId.rawValue)]),
          .array([.string(secondHistoryId.rawValue)])
        ])
      ],
      operationName: "FilterById"
    ))
    let filteredPayload = try payloadObject(filtered.body, field: "notebooks")
    guard case let .array(values)? = filteredPayload["value"],
          case let .object(notebook)? = values.first else {
      return XCTFail("expected ID-filtered notebook")
    }
    XCTAssertEqual(notebook["notebookId"], .string(notebookId.rawValue))

    let removed = await executor.execute(GraphQLDocumentRequest(
      query: """
      mutation RemoveById($notebookId: String!, $tagId: String!) {
        removeNotebookTagById(notebookId: $notebookId, tagId: $tagId) {
          result { accepted status }
          notebook { tags { tag { tagId } } }
        }
      }
      """,
      variables: [
        "notebookId": .string(notebookId.rawValue),
        "tagId": .string(secondHistoryId.rawValue)
      ],
      operationName: "RemoveById"
    ))
    let removedPayload = try payloadObject(removed.body, field: "removeNotebookTagById")
    let removedNotebook = try objectValue(removedPayload["notebook"], field: "notebook")
    guard case let .array(tags)? = removedNotebook["tags"] else {
      return XCTFail("expected projected notebook tags")
    }
    XCTAssertTrue(tags.isEmpty)
    XCTAssertTrue(GraphQLContractProjector.schemaContract.contains("tagFilterIdGroups"))
    XCTAssertTrue(GraphQLContractProjector.schemaContract.contains("ApplyNotebookTagIdsInput"))
  }

  private func makeHierarchyGraphQLService(
    function: String = #function
  ) throws -> GraphQLNoteGraphQLService {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/NoteGraphQLHierarchyProgressTests", isDirectory: true)
      .appendingPathComponent(function.replacingOccurrences(of: "()", with: ""), isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let noteService = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
    return GraphQLNoteGraphQLService(service: noteService)
  }

  private func payloadObject(
    _ body: JSONObject,
    field: String
  ) throws -> JSONObject {
    let data = try objectValue(body["data"], field: "data")
    return try objectValue(data[field], field: field)
  }

  private func objectValue(
    _ value: JSONValue?,
    field: String
  ) throws -> JSONObject {
    guard case let .object(object)? = value else {
      throw NSError(
        domain: "NoteGraphQLHierarchyProgressTests",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "expected object at \(field)"]
      )
    }
    return object
  }
}
