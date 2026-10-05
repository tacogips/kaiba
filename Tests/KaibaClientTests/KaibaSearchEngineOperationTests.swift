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

  @Test func pageSettingsAndTestConnectionOperationsDecodePinnedContract() async throws {
    let pageResponse = Data(#"""
    {"data":{"root":{"result":{"accepted":true,"status":"ok","diagnostics":[]},
    "value":[{"note":{"noteId":"note-1","notebookId":"book-1","noteNumber":1,
    "title":"Title","bodyMarkdown":"Body","readOnly":false,"createdAt":"now",
    "updatedAt":"now","metaJSON":null,"tags":[],"createdBy":null,"updatedBy":null},
    "snippet":"hit","score":2.5,"reasons":[{"kind":"shared-tag","tags":["topic:swift"]}]}],
    "facets":{"tagClasses":[{"value":"topic","count":2}],
    "tags":[{"tagId":"tag-1","name":"swift","tagClass":"topic","count":2}]}}}}
    """#.utf8)
    let pageTransport = SearchEngineOperationTransport(responseBody: pageResponse)
    let page = try await makeClient(pageTransport).engineSearchNotesPage(
      query: "needle", tagClassFilter: ["topic:swift"], expandOntology: false, facets: true
    )
    #expect(page.value?.first?.reasons.first?.kind == "shared-tag")
    #expect(page.facets?.tags.first?.tagId == "tag-1")
    let pageRequest = try #require(await pageTransport.request)
    let pageWire = try #require(try JSONSerialization.jsonObject(with: pageRequest.body) as? [String: Any])
    let pageDocument = try #require(pageWire["query"] as? String)
    #expect(pageDocument.contains("tagClassFilter: $tagClassFilter"))
    #expect(pageDocument.contains("reasons { kind tags }"))
    #expect(pageDocument.contains("facets { tagClasses"))
    let pageVariables = try #require(pageWire["variables"] as? [String: Any])
    #expect(pageVariables["expandOntology"] as? Bool == false)
    #expect(pageVariables["facets"] as? Bool == true)

    let settingsResponse = Data(#"""
    {"data":{"root":{"result":{"accepted":true,"status":"ok","diagnostics":[]},
    "value":{"managedBy":"default","kind":"none","url":null,"indexPrefix":null,
    "authMode":"none","username":null,"hasSecret":false,"verifyTLS":true,
    "requestTimeoutSeconds":10,"adapters":[{"kind":"meilisearch",
    "displayName":"Meilisearch","authModes":["none","basic","apiKey"]}],"active":false}}}}
    """#.utf8)
    let settingsTransport = SearchEngineOperationTransport(responseBody: settingsResponse)
    let settings = try await makeClient(settingsTransport).searchEngineSettings()
    #expect(settings.value?.adapters.first?.kind == "meilisearch")
    let settingsRequest = try #require(await settingsTransport.request)
    let settingsWire = try #require(try JSONSerialization.jsonObject(with: settingsRequest.body) as? [String: Any])
    let settingsDocument = try #require(settingsWire["query"] as? String)
    #expect(settingsDocument.contains("adapters { kind displayName authModes }"))
    #expect(!settingsDocument.contains("defaultURL"))

    let updateResponse = Data(#"""
    {"data":{"root":{"result":{"accepted":true,"status":"ok","diagnostics":[]},
    "value":{"managedBy":"store","kind":"meilisearch","url":"https://search.internal",
    "indexPrefix":"kaiba","authMode":"basic","username":"operator","hasSecret":true,
    "verifyTLS":true,"requestTimeoutSeconds":10,"adapters":[],"active":true}}}}
    """#.utf8)
    let updateTransport = SearchEngineOperationTransport(responseBody: updateResponse)
    let updated = try await makeClient(updateTransport).updateSearchEngineSettings(
      KaibaSearchEngineSettingsInput(
        kind: "meilisearch", url: "https://search.internal", authMode: "basic",
        username: "operator", secret: "request-only-secret"
      )
    )
    #expect(updated.value?.hasSecret == true)
    let updateRequest = try #require(await updateTransport.request)
    let updateWire = try #require(try JSONSerialization.jsonObject(with: updateRequest.body) as? [String: Any])
    #expect((updateWire["query"] as? String)?.contains("root: updateSearchEngineSettings") == true)
    let updateDocument = try #require(updateWire["query"] as? String)
    #expect(updateDocument.contains("adapters { kind displayName authModes }"))
    #expect(!updateDocument.contains("defaultURL"))
    let updateInput = try #require((updateWire["variables"] as? [String: Any])?["input"] as? [String: Any])
    #expect(updateInput["secret"] as? String == "request-only-secret")

    let testResponse = Data(#"""
    {"data":{"root":{"result":{"accepted":true,"status":"ok","diagnostics":[]},
    "value":{"available":false,"status":"invalid-settings","detail":"searchEngine.secret"}}}}
    """#.utf8)
    let testTransport = SearchEngineOperationTransport(responseBody: testResponse)
    let connection = try await makeClient(testTransport).testSearchEngineConnection(
      KaibaSearchEngineSettingsInput(kind: "meilisearch", url: "https://other.internal", authMode: "basic")
    )
    #expect(connection.value?.status == "invalid-settings")
    let testRequest = try #require(await testTransport.request)
    let testWire = try #require(try JSONSerialization.jsonObject(with: testRequest.body) as? [String: Any])
    let input = try #require((testWire["variables"] as? [String: Any])?["input"] as? [String: Any])
    #expect(input["secret"] == nil)
  }

  private func makeClient(_ transport: any KaibaHTTPTransporting) throws -> KaibaClient {
    try KaibaClient(
      endpoint: URL(string: "http://127.0.0.1:8080/graphql")!,
      authentication: .unauthenticated,
      transport: transport
    )
  }
}
