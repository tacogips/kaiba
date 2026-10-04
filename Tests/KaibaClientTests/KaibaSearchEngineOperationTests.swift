import Foundation
import Testing
@testable import KaibaClient

private actor SearchEngineOperationTransport: KaibaHTTPTransporting {
  private let responseBody: Data
  private(set) var request: KaibaHTTPRequest?

  init(responseBody: Data) { self.responseBody = responseBody }

  func send(_ request: KaibaHTTPRequest, maximumResponseBytes: Int) async throws -> KaibaHTTPResponse {
    self.request = request
    return KaibaHTTPResponse(statusCode: 200, body: responseBody)
  }
}

@Suite("Kaiba search engine operations")
struct KaibaSearchEngineOperationTests {
  @Test func engineSearchSendsArgumentsAndDecodesTypedHit() async throws {
    let transport = SearchEngineOperationTransport(responseBody: Data(#"""
    {"data":{"root":{"result":{"accepted":true,"status":"ok","diagnostics":[]},
      "value":[{"note":{"noteId":"note-1","notebookId":"book-1","noteNumber":1,
        "title":"Title","bodyMarkdown":"Body","readOnly":false,"createdAt":"now",
        "updatedAt":"now","metaJSON":null,"tags":[],"createdBy":null,"updatedBy":null},
        "snippet":"hit","score":2.5}]}}
    }
    """#.utf8))
    let client = try makeClient(transport)
    let result = try await client.engineSearchNotes(
      query: "needle", notebookId: KaibaNotebookID(rawValue: "book-1"), tagFilter: [], limit: 12, offset: 4
    )
    #expect(result.result.accepted)
    #expect(result.value?.first?.note.noteId.rawValue == "note-1")
    #expect(result.value?.first?.snippet == "hit")
    #expect(result.value?.first?.score == 2.5)
    let request = try #require(await transport.request)
    let body = try #require(try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
    let document = try #require(body["query"] as? String)
    #expect(document.contains("root: engineSearchNotes"))
    #expect(document.contains("query: $query"))
    #expect(document.contains("tagFilter: $tagFilter"))
    let variables = try #require(body["variables"] as? [String: Any])
    #expect(variables["query"] as? String == "needle")
    #expect(variables["notebookId"] as? String == "book-1")
    #expect(variables["tagFilter"] == nil)
    #expect(variables["limit"] as? Int == 12)
    #expect(variables["offset"] as? Int == 4)
  }

  @Test func relatedNotesAndCapabilityDecodeDisabledResult() async throws {
    let relatedTransport = SearchEngineOperationTransport(responseBody: Data(#"{"data":{"root":{"result":{"accepted":true,"status":"ok","diagnostics":[]},"value":[]}}}"#.utf8))
    let client = try makeClient(relatedTransport)
    let result = try await client.relatedNotes(noteId: KaibaNoteID(rawValue: "source"), limit: 7)
    #expect(result.result.accepted)
    let relatedRequest = try #require(await relatedTransport.request)
    let relatedBody = try #require(try JSONSerialization.jsonObject(with: relatedRequest.body) as? [String: Any])
    let relatedDocument = try #require(relatedBody["query"] as? String)
    #expect(relatedDocument.contains("root: relatedNotes"))
    #expect(relatedDocument.contains("noteId: $noteId"))
    let relatedVariables = try #require(relatedBody["variables"] as? [String: Any])
    #expect(relatedVariables["noteId"] as? String == "source")
    #expect(relatedVariables["limit"] as? Int == 7)

    let disabledTransport = SearchEngineOperationTransport(responseBody: Data(#"""
    {"data":{"root":{"result":{"accepted":false,"status":"feature-disabled",
      "diagnostics":["search engine is not configured"]},"enabled":false}}}
    """#.utf8))
    let capability = try await makeClient(disabledTransport).searchEngineCapability()
    #expect(!capability.result.accepted)
    #expect(capability.result.status == .custom("feature-disabled"))
    #expect(!capability.enabled)
    let capabilityRequest = try #require(await disabledTransport.request)
    let capabilityBody = try #require(try JSONSerialization.jsonObject(with: capabilityRequest.body) as? [String: Any])
    #expect((capabilityBody["query"] as? String)?.contains("root: searchEngineCapability") == true)
  }

  private func makeClient(_ transport: any KaibaHTTPTransporting) throws -> KaibaClient {
    try KaibaClient(
      endpoint: URL(string: "http://127.0.0.1:8080/graphql")!,
      authentication: .unauthenticated,
      transport: transport
    )
  }
}
