import Foundation

import KaibaClient
import XCTest
@testable import AppCore
@testable import AppGraphQL

/// The tag entity page's GraphQL surface
/// (`design-docs/specs/note-capture-and-entity-pages.md`, E6): `tagDetail`
/// carrying `canonicalNote` and `coOccurringTags`, and the `promoteTagNote` /
/// `unpromoteTagNote` mutations. Every test drives the document executor rather
/// than the service facade directly, so the SDL, the operation allow-lists, the
/// argument validation and the selection projection are all exercised together.
final class TagEntityGraphQLTests: XCTestCase {
  // MARK: - tagDetail: canonicalNote (E1/E2)

  func testTagDetailProjectsTheCanonicalNoteOncePromoted() async throws {
    let service = try makeNoteGraphQLService()
    let tag = try service.service.defineTag(name: "kaiba", classId: .topic)
    let note = try service.service.createNote(
      notebookTitle: "Entities",
      title: "Kaiba",
      bodyMarkdown: "# Kaiba\nAn AI learning notebook."
    )
    _ = try service.service.promoteTagCanonicalNote(tagId: tag.tagId, noteId: note.noteId)
    let executor = NoteGraphQLDocumentExecutor(service: service)

    let response = await executor.execute(GraphQLDocumentRequest(
      query: """
      query TagDetail($tagId: String!) {
        tagDetail(tagId: $tagId) {
          result { accepted status }
          value {
            tag { tagId name }
            canonicalNote { noteId title bodyMarkdown }
          }
        }
      }
      """,
      variables: ["tagId": .string(tag.tagId.rawValue)],
      operationName: "TagDetail"
    ))

    let payload = try graphQLPayload(response.body, field: "tagDetail")
    XCTAssertEqual(try resultObject(payload)["accepted"], .bool(true))
    let value = try objectValue(payload["value"], field: "tagDetail.value")
    let canonical = try objectValue(value["canonicalNote"], field: "canonicalNote")
    XCTAssertEqual(canonical["noteId"], .string(note.noteId.rawValue))
    XCTAssertEqual(canonical["title"], .string("Kaiba"))
    XCTAssertEqual(canonical["bodyMarkdown"], .string("# Kaiba\nAn AI learning notebook."))
  }

  func testTagDetailReportsAnUnboundTagAsNullCanonicalNote() async throws {
    let service = try makeNoteGraphQLService()
    let tag = try service.service.defineTag(name: "kaiba", classId: .topic)
    let executor = NoteGraphQLDocumentExecutor(service: service)

    let response = await executor.execute(GraphQLDocumentRequest(
      query: """
      query TagDetail($tagId: String!) {
        tagDetail(tagId: $tagId) {
          result { accepted }
          value { canonicalNote { noteId } coOccurringTags { noteCount } }
        }
      }
      """,
      variables: ["tagId": .string(tag.tagId.rawValue)],
      operationName: "TagDetail"
    ))

    let payload = try graphQLPayload(response.body, field: "tagDetail")
    let value = try objectValue(payload["value"], field: "tagDetail.value")
    XCTAssertEqual(value["canonicalNote"], .null)
    // A tag with no shared notes projects an empty list, never null: the SDL
    // declares coOccurringTags as a non-null list.
    XCTAssertEqual(value["coOccurringTags"], .array([]))
  }

  // MARK: - tagDetail: coOccurringTags and its limit (E4, deviation D1)

  func testCoOccurringTagsRankBySharedNotesThroughTheDocumentSurface() async throws {
    let service = try makeNoteGraphQLService()
    try seedCoOccurrence(in: service.service)
    let subject = try XCTUnwrap(service.service.listTags().first { $0.name == "kaiba" })
    let executor = NoteGraphQLDocumentExecutor(service: service)

    let response = await executor.execute(GraphQLDocumentRequest(
      query: """
      query TagDetail($tagId: String!) {
        tagDetail(tagId: $tagId) {
          result { accepted }
          value { coOccurringTags { tag { name } noteCount } }
        }
      }
      """,
      variables: ["tagId": .string(subject.tagId.rawValue)],
      operationName: "TagDetail"
    ))

    let payload = try graphQLPayload(response.body, field: "tagDetail")
    XCTAssertEqual(try resultObject(payload)["accepted"], .bool(true))
    let rows = try coOccurrenceRows(payload)
    // "swift" shares all three notes, "sqlite" two. "Projects" is folder-class
    // and "unrelated" shares nothing, so neither appears.
    XCTAssertEqual(rows.map(\.name), ["swift", "sqlite"])
    XCTAssertEqual(rows.map(\.count), [3, 2])
  }

  func testCoOccurringTagLimitTrimsTheListAtTheRootField() async throws {
    let service = try makeNoteGraphQLService()
    try seedCoOccurrence(in: service.service)
    let subject = try XCTUnwrap(service.service.listTags().first { $0.name == "kaiba" })
    let executor = NoteGraphQLDocumentExecutor(service: service)

    let response = await executor.execute(GraphQLDocumentRequest(
      query: """
      query TagDetail($tagId: String!, $limit: Int) {
        tagDetail(tagId: $tagId, coOccurringTagLimit: $limit) {
          result { accepted }
          value { coOccurringTags { tag { name } noteCount } }
        }
      }
      """,
      variables: ["tagId": .string(subject.tagId.rawValue), "limit": .integer(1)],
      operationName: "TagDetail"
    ))

    let rows = try coOccurrenceRows(try graphQLPayload(response.body, field: "tagDetail"))
    XCTAssertEqual(rows.map(\.name), ["swift"])
    XCTAssertEqual(rows.map(\.count), [3])
  }

  func testCoOccurringTagLimitOfZeroReturnsAnEmptyListRatherThanTheDefault() async throws {
    let service = try makeNoteGraphQLService()
    try seedCoOccurrence(in: service.service)
    let subject = try XCTUnwrap(service.service.listTags().first { $0.name == "kaiba" })
    let executor = NoteGraphQLDocumentExecutor(service: service)

    // Zero is a meaningful request ("header without chips"), not an absent
    // argument, so it must not fall back to the default limit.
    let response = await executor.execute(GraphQLDocumentRequest(
      query: """
      query TagDetail($tagId: String!) {
        tagDetail(tagId: $tagId, coOccurringTagLimit: 0) {
          result { accepted }
          value { coOccurringTags { tag { name } } }
        }
      }
      """,
      variables: ["tagId": .string(subject.tagId.rawValue)],
      operationName: "TagDetail"
    ))

    let payload = try graphQLPayload(response.body, field: "tagDetail")
    XCTAssertEqual(try resultObject(payload)["accepted"], .bool(true))
    let value = try objectValue(payload["value"], field: "tagDetail.value")
    XCTAssertEqual(value["coOccurringTags"], .array([]))
  }

  func testCoOccurringTagLimitAboveTheTransportBoundIsRefused() async throws {
    let service = try makeNoteGraphQLService()
    let tag = try service.service.defineTag(name: "kaiba", classId: .topic)
    let executor = NoteGraphQLDocumentExecutor(service: service)

    // noteGraphQLMaximumLimit is 200 and AppCore's own coOccurringTags bound is
    // also 0...200, so the transport refuses before the service is reached.
    let response = await executor.execute(GraphQLDocumentRequest(
      query: """
      query TagDetail($tagId: String!) {
        tagDetail(tagId: $tagId, coOccurringTagLimit: 201) {
          result { accepted } value { noteCount }
        }
      }
      """,
      variables: ["tagId": .string(tag.tagId.rawValue)],
      operationName: "TagDetail"
    ))

    XCTAssertTrue(response.handled)
    try assertErrorMessage(response, contains: "invalidVariable")
  }

  func testCoOccurringTagsRejectsANestedArgument() async throws {
    let service = try makeNoteGraphQLService()
    let tag = try service.service.defineTag(name: "kaiba", classId: .topic)
    let executor = NoteGraphQLDocumentExecutor(service: service)

    // Documents deviation D1: the engine resolves a payload eagerly and then
    // projects it, so the limit cannot ride the nested field. If this ever
    // starts succeeding, the SDL comment and the root argument should move.
    let response = await executor.execute(GraphQLDocumentRequest(
      query: """
      query TagDetail($tagId: String!) {
        tagDetail(tagId: $tagId) {
          result { accepted }
          value { coOccurringTags(limit: 1) { noteCount } }
        }
      }
      """,
      variables: ["tagId": .string(tag.tagId.rawValue)],
      operationName: "TagDetail"
    ))

    try assertErrorMessage(response, contains: "does not accept arguments")
  }

  func testANonDefaultCoOccurringTagLimitLeavesTheRestOfTheHeaderAlone() async throws {
    let service = try makeNoteGraphQLService()
    try seedCoOccurrence(in: service.service)
    let subject = try XCTUnwrap(service.service.listTags().first { $0.name == "kaiba" })
    let note = try XCTUnwrap(try service.service.listNotes().first)
    _ = try service.service.promoteTagCanonicalNote(tagId: subject.tagId, noteId: note.noteId)
    let executor = NoteGraphQLDocumentExecutor(service: service)

    // The limit is now threaded into the single service read rather than being
    // applied by taking the default payload and replacing its chip list
    // (F-000-5). Every field outside coOccurringTags must therefore be
    // byte-identical between a default read and a trimmed one; if the two ever
    // diverge, the trimmed read is no longer the same aggregate.
    func header(limitArgument: String) async throws -> JSONObject {
      let response = await executor.execute(GraphQLDocumentRequest(
        query: """
        query TagDetail($tagId: String!) {
          tagDetail(tagId: $tagId\(limitArgument)) {
            result { accepted }
            value {
              tag { tagId name }
              noteCount
              notebookCount
              memoNotebookId
              canonicalNote { noteId title }
              coOccurringTags { tag { name } noteCount }
            }
          }
        }
        """,
        variables: ["tagId": .string(subject.tagId.rawValue)],
        operationName: "TagDetail"
      ))
      let payload = try graphQLPayload(response.body, field: "tagDetail")
      XCTAssertEqual(try resultObject(payload)["accepted"], .bool(true))
      return try objectValue(payload["value"], field: "tagDetail.value")
    }

    var byDefault = try await header(limitArgument: "")
    var trimmed = try await header(limitArgument: ", coOccurringTagLimit: 1")

    XCTAssertEqual(
      try objectValue(trimmed["canonicalNote"], field: "canonicalNote")["noteId"],
      .string(note.noteId.rawValue)
    )
    XCTAssertEqual(trimmed["coOccurringTags"], .array(
      [try XCTUnwrap(arrayValue(byDefault["coOccurringTags"], field: "coOccurringTags").first)]
    ))
    // Compare everything else as a whole, so a field added to TagDetail later
    // is covered by this check without anyone remembering to extend it.
    byDefault["coOccurringTags"] = nil
    trimmed["coOccurringTags"] = nil
    XCTAssertEqual(trimmed, byDefault)
  }

  // MARK: - promoteTagNote / unpromoteTagNote (E2)

  func testPromoteThenUnpromoteRoundTripsThroughTheMutationSurface() async throws {
    let service = try makeNoteGraphQLService()
    let tag = try service.service.defineTag(name: "kaiba", classId: .topic)
    let note = try service.service.createNote(
      notebookTitle: "Entities",
      title: "Kaiba",
      bodyMarkdown: "# Kaiba"
    )
    let executor = NoteGraphQLDocumentExecutor(service: service)

    let promoted = await executor.execute(GraphQLDocumentRequest(
      query: """
      mutation Promote($input: PromoteTagNoteInput!) {
        promoteTagNote(input: $input) {
          result { accepted status }
          note { noteId title }
        }
      }
      """,
      variables: ["input": .object([
        "tagId": .string(tag.tagId.rawValue),
        "noteId": .string(note.noteId.rawValue)
      ])],
      operationName: "Promote"
    ))
    let promotePayload = try graphQLPayload(promoted.body, field: "promoteTagNote")
    XCTAssertEqual(try resultObject(promotePayload)["accepted"], .bool(true))
    XCTAssertEqual(try resultObject(promotePayload)["status"], .string("ok"))
    XCTAssertEqual(try objectValue(promotePayload["note"], field: "note")["noteId"], .string(note.noteId.rawValue))
    XCTAssertEqual(try service.service.canonicalNote(tagId: tag.tagId)?.noteId, note.noteId)

    let unpromoted = await executor.execute(GraphQLDocumentRequest(
      query: """
      mutation Unpromote($input: UnpromoteTagNoteInput!) {
        unpromoteTagNote(input: $input) {
          result { accepted status }
          note { noteId }
        }
      }
      """,
      variables: ["input": .object(["tagId": .string(tag.tagId.rawValue)])],
      operationName: "Unpromote"
    ))
    let unpromotePayload = try graphQLPayload(unpromoted.body, field: "unpromoteTagNote")
    XCTAssertEqual(try resultObject(unpromotePayload)["accepted"], .bool(true))
    XCTAssertEqual(try objectValue(unpromotePayload["note"], field: "note")["noteId"], .string(note.noteId.rawValue))
    XCTAssertNil(try service.service.canonicalNote(tagId: tag.tagId))
    // The note itself survives being unpromoted.
    XCTAssertEqual(try service.service.getNote(note.noteId).noteId, note.noteId)
  }

  func testPromoteReplacesAPreviousBindingLastPromoteWins() async throws {
    let service = try makeNoteGraphQLService()
    let tag = try service.service.defineTag(name: "kaiba", classId: .topic)
    let first = try service.service.createNote(notebookTitle: "Entities", bodyMarkdown: "# First")
    let second = try service.service.createNote(notebookTitle: "Entities", bodyMarkdown: "# Second")
    let executor = NoteGraphQLDocumentExecutor(service: service)

    for note in [first, second] {
      let response = await executor.execute(promoteRequest(tagId: tag.tagId, noteId: note.noteId))
      let payload = try graphQLPayload(response.body, field: "promoteTagNote")
      XCTAssertEqual(try resultObject(payload)["accepted"], .bool(true))
    }

    XCTAssertEqual(try service.service.canonicalNote(tagId: tag.tagId)?.noteId, second.noteId)
  }

  func testUnpromoteOnAnUnboundTagIsAnAcceptedNoOpWithNoNote() async throws {
    let service = try makeNoteGraphQLService()
    let tag = try service.service.defineTag(name: "kaiba", classId: .topic)
    let executor = NoteGraphQLDocumentExecutor(service: service)

    let response = await executor.execute(GraphQLDocumentRequest(
      query: """
      mutation Unpromote($input: UnpromoteTagNoteInput!) {
        unpromoteTagNote(input: $input) { result { accepted status } note { noteId } }
      }
      """,
      variables: ["input": .object(["tagId": .string(tag.tagId.rawValue)])],
      operationName: "Unpromote"
    ))

    let payload = try graphQLPayload(response.body, field: "unpromoteTagNote")
    XCTAssertEqual(try resultObject(payload)["accepted"], .bool(true))
    XCTAssertEqual(payload["note"], .null)
  }

  func testPromoteRefusesOrganizationalTagsAndMissingRows() async throws {
    let service = try makeNoteGraphQLService()
    let folder = try service.service.defineTag(name: "Projects", classId: .folder)
    let topic = try service.service.defineTag(name: "kaiba", classId: .topic)
    let note = try service.service.createNote(notebookTitle: "Entities", bodyMarkdown: "# Kaiba")
    let executor = NoteGraphQLDocumentExecutor(service: service)

    // The resolver re-derives no rule of its own: these refusals are the
    // service's (E2), surfaced verbatim.
    let folderResponse = await executor.execute(promoteRequest(tagId: folder.tagId, noteId: note.noteId))
    let folderPayload = try graphQLPayload(folderResponse.body, field: "promoteTagNote")
    XCTAssertEqual(try resultObject(folderPayload)["accepted"], .bool(false))
    XCTAssertEqual(folderPayload["note"], .null)

    let missingNote = await executor.execute(promoteRequest(tagId: topic.tagId, noteId: NoteID("note-missing")))
    let missingNotePayload = try graphQLPayload(missingNote.body, field: "promoteTagNote")
    XCTAssertEqual(try resultObject(missingNotePayload)["accepted"], .bool(false))
    XCTAssertEqual(try resultObject(missingNotePayload)["status"], .string("not_found"))

    let missingTag = await executor.execute(promoteRequest(tagId: TagID("tag-missing"), noteId: note.noteId))
    let missingTagPayload = try graphQLPayload(missingTag.body, field: "promoteTagNote")
    XCTAssertEqual(try resultObject(missingTagPayload)["accepted"], .bool(false))
    XCTAssertEqual(try resultObject(missingTagPayload)["status"], .string("not_found"))

    XCTAssertNil(try service.service.canonicalNote(tagId: topic.tagId))
  }

  // MARK: - Carried-forward finding R1: the reach asymmetry, at this boundary

  func testAnOutOfReachBindingReadsAsUnboundYetPromoteStillOverwritesIt() async throws {
    let service = try makeNoteGraphQLService()
    let hidden = try service.service.createLibrary(name: "hidden", authRequired: true)
    let hiddenNote = try service.service.scoped(toLibrary: hidden.libraryId).createNote(
      notebookTitle: "Hidden",
      bodyMarkdown: "# Classified"
    )
    let tag = try service.service.defineTag(name: "kaiba", classId: .topic)
    _ = try service.service.promoteTagCanonicalNote(tagId: tag.tagId, noteId: hiddenNote.noteId)

    // The executor resolves the principal from the request, not from a
    // pre-scoped service, so the anonymous view has to be requested here the
    // way the note API transport requests it.
    let anonymous = NoteGraphQLDocumentExecutor(service: service)
    let detail = await anonymous.execute(asAnonymous(GraphQLDocumentRequest(
      query: """
      query TagDetail($tagId: String!) {
        tagDetail(tagId: $tagId) { result { accepted } value { canonicalNote { noteId } } }
      }
      """,
      variables: ["tagId": .string(tag.tagId.rawValue)],
      operationName: "TagDetail"
    )))
    let detailValue = try objectValue(
      try graphQLPayload(detail.body, field: "tagDetail")["value"],
      field: "tagDetail.value"
    )
    XCTAssertEqual(detailValue["canonicalNote"], .null)

    // Unpromote is reach-aware too: an accepted no-op that leaves the binding.
    let unpromote = await anonymous.execute(asAnonymous(GraphQLDocumentRequest(
      query: """
      mutation Unpromote($input: UnpromoteTagNoteInput!) {
        unpromoteTagNote(input: $input) { result { accepted } note { noteId } }
      }
      """,
      variables: ["input": .object(["tagId": .string(tag.tagId.rawValue)])],
      operationName: "Unpromote"
    )))
    let unpromotePayload = try graphQLPayload(unpromote.body, field: "unpromoteTagNote")
    XCTAssertEqual(try resultObject(unpromotePayload)["accepted"], .bool(true))
    XCTAssertEqual(unpromotePayload["note"], .null)
    XCTAssertEqual(try service.service.canonicalNote(tagId: tag.tagId)?.noteId, hiddenNote.noteId)

    // Promote is NOT reach-aware: the same principal, told the tag is unbound,
    // replaces the binding it cannot see. This asserts the documented E2
    // asymmetry rather than a rule invented in the resolver; it leaks nothing,
    // because the caller learns nothing about the note it displaced.
    let visibleNote = try service.service.createNote(notebookTitle: "Open", bodyMarkdown: "# Open")
    let promote = await anonymous.execute(
      asAnonymous(promoteRequest(tagId: tag.tagId, noteId: visibleNote.noteId))
    )
    let promotePayload = try graphQLPayload(promote.body, field: "promoteTagNote")
    XCTAssertEqual(try resultObject(promotePayload)["accepted"], .bool(true))
    XCTAssertEqual(try service.service.canonicalNote(tagId: tag.tagId)?.noteId, visibleNote.noteId)
  }

  func testTheProjectionAddsNoLongTermMemoryExclusionOfItsOwn() async throws {
    // Carried-forward finding R3 as a prohibition: canonicalNote resolves
    // through requireNote, which applies no long-term-memory exclusion, exactly
    // like every other by-id read in NoteService. TASK-005 must not patch that
    // at the GraphQL layer alone, so a long-term-memory note promoted as a
    // canonical description stays visible to an unscoped operator here.
    let service = try makeNoteGraphQLService()
    let memory = try service.service.appendLongTermMemoryNotes(
      [LongTermMemoryEntryInput(bodyMarkdown: "# Remembered")],
      idempotencyKey: "tag-entity-graphql"
    )
    let memoryNote = try XCTUnwrap(memory.notes.first)
    let tag = try service.service.defineTag(name: "kaiba", classId: .topic)
    _ = try service.service.promoteTagCanonicalNote(tagId: tag.tagId, noteId: memoryNote.noteId)
    let executor = NoteGraphQLDocumentExecutor(service: service)

    let response = await executor.execute(GraphQLDocumentRequest(
      query: """
      query TagDetail($tagId: String!) {
        tagDetail(tagId: $tagId) { result { accepted } value { canonicalNote { noteId } } }
      }
      """,
      variables: ["tagId": .string(tag.tagId.rawValue)],
      operationName: "TagDetail"
    ))
    let value = try objectValue(
      try graphQLPayload(response.body, field: "tagDetail")["value"],
      field: "tagDetail.value"
    )
    XCTAssertEqual(
      try objectValue(value["canonicalNote"], field: "canonicalNote")["noteId"],
      .string(memoryNote.noteId.rawValue)
    )
  }

  // MARK: - Schema contract and operation allow-lists (E6)

  func testSchemaContractDeclaresTheEntityPageSurfaceAndStillParses() throws {
    let contract = GraphQLContractProjector.schemaContract
    XCTAssertTrue(contract.contains("tagDetail(tagId: String!, coOccurringTagLimit: Int): TagDetailQueryPayload!"))
    XCTAssertTrue(contract.contains("promoteTagNote(input: PromoteTagNoteInput!): NoteMutationPayload!"))
    XCTAssertTrue(contract.contains("unpromoteTagNote(input: UnpromoteTagNoteInput!): NoteMutationPayload!"))
    XCTAssertTrue(contract.contains("type TagCoOccurrence { tag: NoteTag!, noteCount: Int! }"))
    XCTAssertTrue(contract.contains("canonicalNote: Note, coOccurringTags: [TagCoOccurrence!]!"))
    XCTAssertTrue(contract.contains("input PromoteTagNoteInput { tagId: String!, noteId: String! }"))
    XCTAssertTrue(contract.contains("input UnpromoteTagNoteInput { tagId: String! }"))

    // The published schema is served to clients and drives argument validation,
    // so it has to remain parseable after the additions.
    XCTAssertNoThrow(try KaibaGraphQLSchema.parseSDL(contract))
  }

  func testTheNewMutationsAreRoutableAndRejectedAsQueries() async throws {
    XCTAssertTrue(supportedNoteGraphQLFields.contains("promoteTagNote"))
    XCTAssertTrue(supportedNoteGraphQLFields.contains("unpromoteTagNote"))
    XCTAssertTrue(noteGraphQLMutationFields.contains("promoteTagNote"))
    XCTAssertTrue(noteGraphQLMutationFields.contains("unpromoteTagNote"))
    XCTAssertFalse(noteGraphQLQueryFields.contains("promoteTagNote"))
    XCTAssertFalse(noteGraphQLQueryFields.contains("unpromoteTagNote"))

    let service = try makeNoteGraphQLService()
    let tag = try service.service.defineTag(name: "kaiba", classId: .topic)
    let executor = NoteGraphQLDocumentExecutor(service: service)

    // A mutation issued as a query must be refused, not silently executed.
    let response = await executor.execute(GraphQLDocumentRequest(
      query: """
      query Promote($input: PromoteTagNoteInput!) {
        promoteTagNote(input: $input) { result { accepted } }
      }
      """,
      variables: ["input": .object([
        "tagId": .string(tag.tagId.rawValue),
        "noteId": .string("note-any")
      ])],
      operationName: "Promote"
    ))
    XCTAssertTrue(response.handled)
    XCTAssertNotNil(response.body["errors"])
  }

  func testUnknownEntityPageSelectionsAreRejected() async throws {
    let service = try makeNoteGraphQLService()
    let tag = try service.service.defineTag(name: "kaiba", classId: .topic)
    let executor = NoteGraphQLDocumentExecutor(service: service)

    let response = await executor.execute(GraphQLDocumentRequest(
      query: """
      query TagDetail($tagId: String!) {
        tagDetail(tagId: $tagId) { value { coOccurringTags { tag { name } weight } } }
      }
      """,
      variables: ["tagId": .string(tag.tagId.rawValue)],
      operationName: "TagDetail"
    ))
    try assertErrorMessage(response, contains: "unsupported field")
  }

  // MARK: - Helpers

  /// The note API's unauthenticated view: it still acts as the default user,
  /// and only the transport knows no credential arrived
  /// (`design-docs/specs/library.md`).
  private func asAnonymous(_ request: GraphQLDocumentRequest) -> GraphQLDocumentRequest {
    var anonymous = request
    anonymous.actingUserId = NoteStoreSchema.defaultUserId
    anonymous.isUnauthenticatedRequest = true
    return anonymous
  }

  private func promoteRequest(tagId: TagID, noteId: NoteID) -> GraphQLDocumentRequest {
    GraphQLDocumentRequest(
      query: """
      mutation Promote($input: PromoteTagNoteInput!) {
        promoteTagNote(input: $input) { result { accepted status } note { noteId } }
      }
      """,
      variables: ["input": .object([
        "tagId": .string(tagId.rawValue),
        "noteId": .string(noteId.rawValue)
      ])],
      operationName: "Promote"
    )
  }

  /// Three notes carry "kaiba": "swift" shares all three, "sqlite" two.
  /// "Projects" is folder-class and "unrelated" shares nothing, so neither may
  /// appear in the aggregate (E4's organizational exclusion).
  private func seedCoOccurrence(in service: NoteService) throws {
    _ = try service.defineTag(name: "kaiba", classId: .topic)
    _ = try service.defineTag(name: "Projects", classId: .folder)
    let notebook = try service.createNotebook(title: "Entities", folderPath: ["Projects"])
    for index in 0..<3 {
      var tags = [NoteTagInput(name: "kaiba"), NoteTagInput(name: "swift")]
      if index < 2 { tags.append(NoteTagInput(name: "sqlite")) }
      _ = try service.createNote(
        notebookId: notebook.notebookId,
        bodyMarkdown: "# Note \(index)",
        tags: tags
      )
    }
    _ = try service.createNote(
      notebookId: notebook.notebookId,
      bodyMarkdown: "# Elsewhere",
      tags: [NoteTagInput(name: "unrelated")]
    )
  }

  private func coOccurrenceRows(_ payload: JSONObject) throws -> [(name: String, count: Int)] {
    let value = try objectValue(payload["value"], field: "tagDetail.value")
    guard case let .array(rows)? = value["coOccurringTags"] else {
      throw TagEntityGraphQLTestFailure("expected coOccurringTags array, got \(String(describing: value["coOccurringTags"]))")
    }
    return try rows.map { row in
      let object = try objectValue(row, field: "coOccurringTags[]")
      guard case let .string(name)? = try objectValue(object["tag"], field: "tag")["name"] else {
        throw TagEntityGraphQLTestFailure("expected a tag name in \(object)")
      }
      guard case let .integer(count)? = object["noteCount"] else {
        throw TagEntityGraphQLTestFailure("expected an integer noteCount in \(object)")
      }
      return (name, Int(count))
    }
  }

  private func assertErrorMessage(
    _ response: GraphQLDocumentExecutionResponse,
    contains substring: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    XCTAssertTrue(response.handled, "expected handled response", file: file, line: line)
    guard case let .array(errors)? = response.body["errors"], let first = errors.first,
          case let .object(errorObject) = first, case let .string(message)? = errorObject["message"] else {
      XCTFail("expected an error message, got \(String(describing: response.body))", file: file, line: line)
      return
    }
    XCTAssertTrue(
      message.contains(substring),
      "expected '\(substring)' in '\(message)'",
      file: file,
      line: line
    )
  }

  private func makeNoteGraphQLService(function: String = #function) throws -> GraphQLNoteGraphQLService {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/AppGraphQLTests", isDirectory: true)
      .appendingPathComponent(function.replacingOccurrences(of: "()", with: ""), isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return try GraphQLNoteGraphQLService(
      service: NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
    )
  }

  private func graphQLPayload(_ body: JSONObject, field: String) throws -> JSONObject {
    let data = try objectValue(body["data"], field: "data")
    return try objectValue(data[field], field: field)
  }

  private func resultObject(_ payload: JSONObject) throws -> JSONObject {
    try objectValue(payload["result"], field: "result")
  }

  private func objectValue(_ value: JSONValue?, field: String) throws -> JSONObject {
    guard case let .object(object) = value else {
      throw TagEntityGraphQLTestFailure("expected object at \(field), got \(String(describing: value))")
    }
    return object
  }

  private func arrayValue(_ value: JSONValue?, field: String) throws -> [JSONValue] {
    guard case let .array(rows) = value else {
      throw TagEntityGraphQLTestFailure("expected array at \(field), got \(String(describing: value))")
    }
    return rows
  }
}

/// A malformed payload must FAIL the suite, not skip it. The surrounding
/// AppGraphQLTests files reach for `XCTSkip` here, which would turn a broken
/// projection into a silently green run.
private struct TagEntityGraphQLTestFailure: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}
