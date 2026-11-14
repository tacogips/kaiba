import Foundation

private struct KaibaRootPayload<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
  var root: Value

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let object = try container.decode([String: Value].self)
    guard object.count == 1, let value = object.values.first else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "expected one root field")
    }
    root = value
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(["root": root])
  }
}

private protocol KaibaControlPlaneDiagnosticsSanitizable {
  func sanitizingDiagnostics(_ sanitizer: (String) -> String) -> Self
}

extension KaibaControlPlaneResult: KaibaControlPlaneDiagnosticsSanitizable {
  fileprivate func sanitizingDiagnostics(_ sanitizer: (String) -> String) -> Self {
    var copy = self
    copy.diagnostics = diagnostics.map(sanitizer)
    return copy
  }
}

extension KaibaOperationPayload: KaibaControlPlaneDiagnosticsSanitizable {
  fileprivate func sanitizingDiagnostics(_ sanitizer: (String) -> String) -> Self {
    var copy = self
    copy.result = result.sanitizingDiagnostics(sanitizer)
    return copy
  }
}

extension KaibaLongTermMemoryAppendPayload: KaibaControlPlaneDiagnosticsSanitizable {
  fileprivate func sanitizingDiagnostics(_ sanitizer: (String) -> String) -> Self {
    var copy = self
    copy.result = result.sanitizingDiagnostics(sanitizer)
    return copy
  }
}

extension KaibaValuePayload: KaibaControlPlaneDiagnosticsSanitizable {
  fileprivate func sanitizingDiagnostics(_ sanitizer: (String) -> String) -> Self {
    var copy = self
    copy.result = result.sanitizingDiagnostics(sanitizer)
    return copy
  }
}

extension KaibaClient {
  public func getNote(_ noteId: KaibaNoteID) async throws -> KaibaValuePayload<KaibaNote> {
    return try await operation(
      "query KaibaGetNote($noteId: String!) { root: note(noteId: $noteId) { result { accepted status diagnostics } value { \(Self.noteFields) } } }",
      variables: ["noteId": .string(noteId.rawValue)],
      as: KaibaValuePayload<KaibaNote>.self
    )
  }

  public func listNotes(
    notebookId: KaibaNotebookID? = nil,
    tagFilter: [String] = [],
    limit: Int = 50,
    offset: Int = 0
  ) async throws -> KaibaValuePayload<[KaibaNote]> {
    var variables: [String: KaibaJSONValue] = ["limit": .integer(limit), "offset": .integer(offset)]
    if let notebookId { variables["notebookId"] = .string(notebookId.rawValue) }
    if !tagFilter.isEmpty { variables["tagFilter"] = .array(tagFilter.map(KaibaJSONValue.string)) }
    return try await operation(
      """
      query KaibaListNotes($notebookId: String, $tagFilter: [String!], $limit: Int, $offset: Int) {
        root: notes(notebookId: $notebookId, tagFilter: $tagFilter, limit: $limit, offset: $offset) {
          result { accepted status diagnostics } value { \(Self.noteFields) }
        }
      }
      """,
      variables: variables,
      as: KaibaValuePayload<[KaibaNote]>.self
    )
  }

  public func createNote(
    notebookId: KaibaNotebookID? = nil,
    notebookTitle: String? = nil,
    title: String? = nil,
    bodyMarkdown: String,
    readOnly: Bool? = nil,
    tags: [KaibaTagInput] = [],
    provenance: String? = nil,
    assignedBy: String? = nil,
    metaJSON: String? = nil,
    originatingActionId: KaibaAutoActionID? = nil
  ) async throws -> KaibaOperationPayload {
    var input: [String: KaibaJSONValue] = ["bodyMarkdown": .string(bodyMarkdown)]
    if let notebookId { input["notebookId"] = .string(notebookId.rawValue) }
    if let notebookTitle { input["notebookTitle"] = .string(notebookTitle) }
    if let title { input["title"] = .string(title) }
    if let readOnly { input["readOnly"] = .bool(readOnly) }
    if !tags.isEmpty { input["tags"] = .array(tags.map(Self.tagInput)) }
    if let provenance { input["provenance"] = .string(provenance) }
    if let assignedBy { input["assignedBy"] = .string(assignedBy) }
    if let metaJSON { input["metaJSON"] = .string(metaJSON) }
    if let originatingActionId { input["originatingActionId"] = .string(originatingActionId.rawValue) }
    return try await operation(
      """
      mutation KaibaCreateNote($input: CreateNoteInput!) {
        root: createNote(input: $input) {
          result { accepted status diagnostics } note { \(Self.noteFields) }
          notebook { \(Self.notebookFields) } notes { \(Self.noteFields) }
        }
      }
      """,
      variables: ["input": .object(input)],
      as: KaibaOperationPayload.self
    )
  }

  public func updateNote(
    _ noteId: KaibaNoteID,
    bodyMarkdown: String,
    originatingActionId: KaibaAutoActionID? = nil
  ) async throws -> KaibaOperationPayload {
    var input: [String: KaibaJSONValue] = [
      "noteId": .string(noteId.rawValue), "bodyMarkdown": .string(bodyMarkdown)
    ]
    if let originatingActionId { input["originatingActionId"] = .string(originatingActionId.rawValue) }
    return try await operation(
      "mutation KaibaUpdateNote($input: UpdateNoteInput!) { root: updateNote(input: $input) { result { accepted status diagnostics } note { \(Self.noteFields) } } }",
      variables: ["input": .object(input)],
      as: KaibaOperationPayload.self
    )
  }

  public func searchNotes(
    query: String,
    notebookId: KaibaNotebookID? = nil,
    tagFilter: [String] = [],
    classFilter: [String] = [],
    includeLinked: Bool = false,
    depth: Int = 1,
    limit: Int = 20,
    offset: Int = 0
  ) async throws -> KaibaValuePayload<[KaibaNoteSearchResult]> {
    var variables: [String: KaibaJSONValue] = [
      "query": .string(query), "includeLinked": .bool(includeLinked), "depth": .integer(depth),
      "limit": .integer(limit), "offset": .integer(offset)
    ]
    if let notebookId { variables["notebookId"] = .string(notebookId.rawValue) }
    if !tagFilter.isEmpty { variables["tagFilter"] = .array(tagFilter.map(KaibaJSONValue.string)) }
    if !classFilter.isEmpty { variables["classFilter"] = .array(classFilter.map(KaibaJSONValue.string)) }
    return try await operation(
      """
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
          value { note { \(Self.noteFields) } snippet rank matchedTags { \(Self.tagDefinitionFields) }
            isLinkedNeighbor termCoverage }
        }
      }
      """,
      variables: variables,
      as: KaibaValuePayload<[KaibaNoteSearchResult]>.self
    )
  }

  public func setNoteReadOnly(_ noteId: KaibaNoteID, readOnly: Bool) async throws -> KaibaOperationPayload {
    try await operation(
      "mutation KaibaSetNoteReadOnly($noteId: String!, $readOnly: Boolean!) { root: setNoteReadOnly(noteId: $noteId, readOnly: $readOnly) { result { accepted status diagnostics } note { \(Self.noteFields) } } }",
      variables: ["noteId": .string(noteId.rawValue), "readOnly": .bool(readOnly)],
      as: KaibaOperationPayload.self
    )
  }

  public func noteGraphNeighbors(
    noteIds: [KaibaNoteID],
    depth: Int = 2,
    limit: Int = 20
  ) async throws -> KaibaValuePayload<[KaibaNoteGraphNeighbor]> {
    try await operation(
      """
      query KaibaNoteGraph($noteIds: [String!]!, $depth: Int, $limit: Int) {
        root: noteGraphNeighbors(noteIds: $noteIds, depth: $depth, limit: $limit) {
          result { accepted status diagnostics }
          value { seedNoteId note { \(Self.noteFields) } edgeKind weight hopCount pathNoteIds }
        }
      }
      """,
      variables: [
        "noteIds": .array(noteIds.map { .string($0.rawValue) }),
        "depth": .integer(depth), "limit": .integer(limit)
      ],
      as: KaibaValuePayload<[KaibaNoteGraphNeighbor]>.self
    )
  }

  public func deleteNote(_ noteId: KaibaNoteID) async throws -> KaibaControlPlaneResult {
    try await operation(
      "mutation KaibaDeleteNote($noteId: String!) { root: deleteNote(noteId: $noteId) { accepted status diagnostics } }",
      variables: ["noteId": .string(noteId.rawValue)],
      as: KaibaControlPlaneResult.self
    )
  }

  public func getNotebook(_ notebookId: KaibaNotebookID) async throws -> KaibaValuePayload<KaibaNotebook> {
    try await operation(
      "query KaibaGetNotebook($notebookId: String!) { root: notebook(notebookId: $notebookId) { result { accepted status diagnostics } value { \(Self.notebookFields) } } }",
      variables: ["notebookId": .string(notebookId.rawValue)],
      as: KaibaValuePayload<KaibaNotebook>.self
    )
  }

  public func listNotebooks(limit: Int = 50, offset: Int = 0) async throws -> KaibaValuePayload<[KaibaNotebook]> {
    try await operation(
      "query KaibaListNotebooks($limit: Int, $offset: Int) { root: notebooks(limit: $limit, offset: $offset) { result { accepted status diagnostics } value { \(Self.notebookFields) } } }",
      variables: ["limit": .integer(limit), "offset": .integer(offset)],
      as: KaibaValuePayload<[KaibaNotebook]>.self
    )
  }

  public func createNotebook(
    title: String,
    kindTagName: String? = nil,
    folderPath: [String] = [],
    metaJSON: String? = nil,
    originatingActionId: KaibaAutoActionID? = nil
  ) async throws -> KaibaOperationPayload {
    var input: [String: KaibaJSONValue] = ["title": .string(title)]
    if let kindTagName { input["kindTagName"] = .string(kindTagName) }
    if !folderPath.isEmpty { input["folderPath"] = .array(folderPath.map(KaibaJSONValue.string)) }
    if let metaJSON { input["metaJSON"] = .string(metaJSON) }
    if let originatingActionId { input["originatingActionId"] = .string(originatingActionId.rawValue) }
    return try await operation(
      "mutation KaibaCreateNotebook($input: CreateNotebookInput!) { root: createNotebook(input: $input) { result { accepted status diagnostics } notebook { \(Self.notebookFields) } } }",
      variables: ["input": .object(input)],
      as: KaibaOperationPayload.self
    )
  }

  public func deleteNotebook(_ notebookId: KaibaNotebookID) async throws -> KaibaControlPlaneResult {
    try await operation(
      "mutation KaibaDeleteNotebook($notebookId: String!) { root: deleteNotebook(notebookId: $notebookId) { accepted status diagnostics } }",
      variables: ["notebookId": .string(notebookId.rawValue)],
      as: KaibaControlPlaneResult.self
    )
  }

  public func setNotebookReadOnly(
    _ notebookId: KaibaNotebookID,
    readOnly: Bool
  ) async throws -> KaibaOperationPayload {
    try await operation(
      """
      mutation KaibaSetNotebookReadOnly($notebookId: String!, $readOnly: Boolean!) {
        root: setNotebookReadOnly(notebookId: $notebookId, readOnly: $readOnly) {
          result { accepted status diagnostics } notebook { \(Self.notebookFields) }
        }
      }
      """,
      variables: ["notebookId": .string(notebookId.rawValue), "readOnly": .bool(readOnly)],
      as: KaibaOperationPayload.self
    )
  }

  public func listTags() async throws -> KaibaValuePayload<[KaibaTag]> {
    try await operation(
      "query KaibaTags { root: tags { result { accepted status diagnostics } value { tagId name classId parentTagId isSystem createdAt } } }",
      as: KaibaValuePayload<[KaibaTag]>.self
    )
  }

  public func listTagClasses() async throws -> KaibaValuePayload<[KaibaTagClass]> {
    try await operation(
      "query KaibaTagClasses { root: tagClasses { result { accepted status diagnostics } value { classId label description isSystem createdAt } } }",
      as: KaibaValuePayload<[KaibaTagClass]>.self
    )
  }

  public func defineTag(name: String, classId: String? = nil) async throws -> KaibaOperationPayload {
    var input: [String: KaibaJSONValue] = ["name": .string(name)]
    if let classId { input["classId"] = .string(classId) }
    return try await operation(
      "mutation KaibaDefineTag($input: DefineNoteTagInput!) { root: defineNoteTag(input: $input) { result { accepted status diagnostics } tag { \(Self.tagDefinitionFields) } } }",
      variables: ["input": .object(input)],
      as: KaibaOperationPayload.self
    )
  }

  public func defineTagClass(
    classId: String,
    label: String,
    description: String? = nil
  ) async throws -> KaibaOperationPayload {
    var input: [String: KaibaJSONValue] = [
      "classId": .string(classId), "label": .string(label)
    ]
    if let description { input["description"] = .string(description) }
    return try await operation(
      """
      mutation KaibaDefineTagClass($input: DefineNoteTagClassInput!) {
        root: defineNoteTagClass(input: $input) {
          result { accepted status diagnostics }
          tagClass { classId label description isSystem createdAt }
        }
      }
      """,
      variables: ["input": .object(input)],
      as: KaibaOperationPayload.self
    )
  }

  public func applyNoteTags(
    noteId: KaibaNoteID,
    tags: [KaibaTagInput],
    provenance: String? = nil,
    assignedBy: String? = nil
  ) async throws -> KaibaOperationPayload {
    var input: [String: KaibaJSONValue] = [
      "noteId": .string(noteId.rawValue), "tags": .array(tags.map(Self.tagInput))
    ]
    if let provenance { input["provenance"] = .string(provenance) }
    if let assignedBy { input["assignedBy"] = .string(assignedBy) }
    return try await operation(
      "mutation KaibaApplyNoteTags($input: ApplyNoteTagsInput!) { root: applyNoteTags(input: $input) { result { accepted status diagnostics } note { \(Self.noteFields) } } }",
      variables: ["input": .object(input)],
      as: KaibaOperationPayload.self
    )
  }

  public func applyNoteTags(
    noteId: KaibaNoteID,
    tagNames: [String]
  ) async throws -> KaibaOperationPayload {
    try await applyNoteTags(noteId: noteId, tags: tagNames.map { KaibaTagInput(name: $0) })
  }

  public func removeNoteTag(
    noteId: KaibaNoteID,
    tagName: String,
    provenance: String? = nil
  ) async throws -> KaibaOperationPayload {
    var variables: [String: KaibaJSONValue] = [
      "noteId": .string(noteId.rawValue), "tagName": .string(tagName)
    ]
    if let provenance { variables["provenance"] = .string(provenance) }
    return try await operation(
      """
      mutation KaibaRemoveNoteTag($noteId: String!, $tagName: String!, $provenance: String) {
        root: removeNoteTag(noteId: $noteId, tagName: $tagName, provenance: $provenance) {
          result { accepted status diagnostics } note { \(Self.noteFields) }
        }
      }
      """,
      variables: variables,
      as: KaibaOperationPayload.self
    )
  }

  public func applyNotebookTags(
    notebookId: KaibaNotebookID,
    tagNames: [String],
    provenance: String? = nil,
    assignedBy: String? = nil
  ) async throws -> KaibaOperationPayload {
    var input: [String: KaibaJSONValue] = [
      "notebookId": .string(notebookId.rawValue),
      "tags": .array(tagNames.map(KaibaJSONValue.string))
    ]
    if let provenance { input["provenance"] = .string(provenance) }
    if let assignedBy { input["assignedBy"] = .string(assignedBy) }
    return try await operation(
      "mutation KaibaApplyNotebookTags($input: ApplyNotebookTagsInput!) { root: applyNotebookTags(input: $input) { result { accepted status diagnostics } notebook { \(Self.notebookFields) } } }",
      variables: ["input": .object(input)],
      as: KaibaOperationPayload.self
    )
  }

  public func applyNotebookTagIDs(
    notebookId: KaibaNotebookID,
    tagIds: [KaibaTagID],
    provenance: String? = nil,
    assignedBy: String? = nil
  ) async throws -> KaibaOperationPayload {
    var input: [String: KaibaJSONValue] = [
      "notebookId": .string(notebookId.rawValue),
      "tagIds": .array(tagIds.map { .string($0.rawValue) })
    ]
    if let provenance { input["provenance"] = .string(provenance) }
    if let assignedBy { input["assignedBy"] = .string(assignedBy) }
    return try await operation(
      "mutation KaibaApplyNotebookTagIDs($input: ApplyNotebookTagIdsInput!) { root: applyNotebookTagIds(input: $input) { result { accepted status diagnostics } notebook { \(Self.notebookFields) } } }",
      variables: ["input": .object(input)],
      as: KaibaOperationPayload.self
    )
  }

  public func removeNotebookTag(
    notebookId: KaibaNotebookID,
    tagName: String,
    provenance: String? = nil
  ) async throws -> KaibaOperationPayload {
    try await removeNotebookTag(
      notebookId: notebookId,
      tagArgument: ("tagName", tagName),
      operation: "removeNotebookTag",
      provenance: provenance
    )
  }

  public func removeNotebookTag(
    notebookId: KaibaNotebookID,
    tagId: KaibaTagID,
    provenance: String? = nil
  ) async throws -> KaibaOperationPayload {
    try await removeNotebookTag(
      notebookId: notebookId,
      tagArgument: ("tagId", tagId.rawValue),
      operation: "removeNotebookTagById",
      provenance: provenance
    )
  }

  public func listNoteAttachments(_ noteId: KaibaNoteID) async throws -> KaibaValuePayload<[KaibaFileAttachment]> {
    try await operation(
      "query KaibaNoteFiles($noteId: String!) { root: noteFiles(noteId: $noteId) { result { accepted status diagnostics } value { noteId role position file { \(Self.fileFields) } } } }",
      variables: ["noteId": .string(noteId.rawValue)],
      as: KaibaValuePayload<[KaibaFileAttachment]>.self
    )
  }

  public func listNotebookAttachments(
    _ notebookId: KaibaNotebookID
  ) async throws -> KaibaValuePayload<[KaibaFileAttachment]> {
    try await operation(
      "query KaibaNotebookFiles($notebookId: String!) { root: notebookFiles(notebookId: $notebookId) { result { accepted status diagnostics } value { notebookId role file { \(Self.fileFields) } } } }",
      variables: ["notebookId": .string(notebookId.rawValue)],
      as: KaibaValuePayload<[KaibaFileAttachment]>.self
    )
  }

  public func attachNoteFile(
    _ noteId: KaibaNoteID,
    bytes: Data,
    mediaType: String,
    originalFilename: String? = nil,
    role: KaibaAttachmentRole = .related,
    position: Int = 0
  ) async throws -> KaibaOperationPayload {
    var input: [String: KaibaJSONValue] = [
      "noteId": .string(noteId.rawValue),
      "contentBase64": .string(bytes.base64EncodedString()),
      "mediaType": .string(mediaType), "role": .string(role.rawValue),
      "position": .integer(position)
    ]
    if let originalFilename { input["originalFilename"] = .string(originalFilename) }
    return try await operation(
      "mutation KaibaAttachNoteFile($input: AttachNoteFileInput!) { root: attachNoteFile(input: $input) { result { accepted status diagnostics } file { \(Self.fileFields) } } }",
      variables: ["input": .object(input)],
      as: KaibaOperationPayload.self
    )
  }

  public func attachNotebookFile(
    _ notebookId: KaibaNotebookID,
    bytes: Data,
    mediaType: String,
    originalFilename: String? = nil,
    role: KaibaAttachmentRole = .related
  ) async throws -> KaibaOperationPayload {
    var input: [String: KaibaJSONValue] = [
      "notebookId": .string(notebookId.rawValue),
      "contentBase64": .string(bytes.base64EncodedString()),
      "mediaType": .string(mediaType),
      "role": .string(role.rawValue)
    ]
    if let originalFilename { input["originalFilename"] = .string(originalFilename) }
    return try await operation(
      "mutation KaibaAttachNotebookFile($input: AttachNotebookFileInput!) { root: attachNotebookFile(input: $input) { result { accepted status diagnostics } file { \(Self.fileFields) } } }",
      variables: ["input": .object(input)],
      as: KaibaOperationPayload.self
    )
  }

  public func ingestNotebookPages(
    idempotencyKey: String,
    title: String,
    pages: [KaibaIngestPage],
    kindTagName: String? = nil,
    sourceDocument: KaibaInlineAttachment? = nil,
    metaJSON: String? = nil,
    originatingActionId: KaibaAutoActionID? = nil
  ) async throws -> KaibaOperationPayload {
    var input: [String: KaibaJSONValue] = [
      "idempotencyKey": .string(idempotencyKey),
      "title": .string(title),
      "pages": .array(pages.map { page in
        var value: [String: KaibaJSONValue] = [
          "bodyMarkdown": .string(page.bodyMarkdown),
          "readOnly": .bool(page.readOnly),
          "tags": .array(page.tags.map { tag in
            var value: [String: KaibaJSONValue] = ["name": .string(tag.name)]
            if let classId = tag.classId { value["classId"] = .string(classId) }
            return .object(value)
          })
        ]
        if let metaJSON = page.metaJSON { value["metaJSON"] = .string(metaJSON) }
        if let noteNumber = page.noteNumber { value["noteNumber"] = .integer(noteNumber) }
        if let pageImage = page.pageImage {
          value["pageImage"] = Self.inlineAttachment(pageImage)
        }
        return .object(value)
      })
    ]
    if let kindTagName { input["kindTagName"] = .string(kindTagName) }
    if let sourceDocument { input["sourceDocument"] = Self.inlineAttachment(sourceDocument) }
    if let metaJSON { input["metaJSON"] = .string(metaJSON) }
    if let originatingActionId { input["originatingActionId"] = .string(originatingActionId.rawValue) }
    return try await operation(
      """
      mutation KaibaIngestNotebookPages($input: IngestNotebookPagesInput!) {
        root: ingestNotebookPages(input: $input) {
          result { accepted status diagnostics } notebook { \(Self.notebookFields) }
          notes { \(Self.noteFields) }
          noteFiles { noteId role position file { \(Self.fileFields) } }
          notebookFiles { notebookId role file { \(Self.fileFields) } }
        }
      }
      """,
      variables: ["input": .object(input)],
      as: KaibaOperationPayload.self
    )
  }

  public func listNoteComments(_ noteId: KaibaNoteID) async throws -> KaibaValuePayload<[KaibaComment]> {
    try await operation(
      "query KaibaNoteComments($noteId: String!) { root: noteComments(noteId: $noteId) { result { accepted status diagnostics } value { commentId noteId notebookId bodyMarkdown author createdAt } } }",
      variables: ["noteId": .string(noteId.rawValue)],
      as: KaibaValuePayload<[KaibaComment]>.self
    )
  }

  public func addNoteComment(
    _ noteId: KaibaNoteID,
    bodyMarkdown: String,
    author: String? = nil
  ) async throws -> KaibaOperationPayload {
    var input: [String: KaibaJSONValue] = [
      "noteId": .string(noteId.rawValue), "bodyMarkdown": .string(bodyMarkdown)
    ]
    if let author { input["author"] = .string(author) }
    return try await operation(
      "mutation KaibaAddNoteComment($input: AddNoteCommentInput!) { root: addNoteComment(input: $input) { result { accepted status diagnostics } comment { commentId noteId notebookId bodyMarkdown author createdAt } } }",
      variables: ["input": .object(input)],
      as: KaibaOperationPayload.self
    )
  }

  public func addNotebookComment(
    _ notebookId: KaibaNotebookID,
    bodyMarkdown: String,
    author: String? = nil
  ) async throws -> KaibaOperationPayload {
    var input: [String: KaibaJSONValue] = [
      "notebookId": .string(notebookId.rawValue), "bodyMarkdown": .string(bodyMarkdown)
    ]
    if let author { input["author"] = .string(author) }
    return try await operation(
      """
      mutation KaibaAddNotebookComment($input: AddNotebookCommentInput!) {
        root: addNotebookComment(input: $input) {
          result { accepted status diagnostics }
          comment { commentId noteId notebookId bodyMarkdown author createdAt }
        }
      }
      """,
      variables: ["input": .object(input)],
      as: KaibaOperationPayload.self
    )
  }

  public func listNotebookComments(
    _ notebookId: KaibaNotebookID
  ) async throws -> KaibaValuePayload<[KaibaComment]> {
    try await operation(
      """
      query KaibaNotebookComments($notebookId: String!) {
        root: notebookComments(notebookId: $notebookId) {
          result { accepted status diagnostics }
          value { commentId noteId notebookId bodyMarkdown author createdAt }
        }
      }
      """,
      variables: ["notebookId": .string(notebookId.rawValue)],
      as: KaibaValuePayload<[KaibaComment]>.self
    )
  }

  public func listNoteConversations(
    _ noteId: KaibaNoteID,
    limit: Int = 50
  ) async throws -> KaibaValuePayload<[KaibaConversation]> {
    try await operation(
      """
      query KaibaNoteConversations($noteId: String!, $limit: Int) {
        root: noteConversations(noteId: $noteId, limit: $limit) {
          result { accepted status diagnostics }
          value { notebookId title updatedAt turnCount subjectNoteId subjectNotebookId }
        }
      }
      """,
      variables: ["noteId": .string(noteId.rawValue), "limit": .integer(limit)],
      as: KaibaValuePayload<[KaibaConversation]>.self
    )
  }

  public func listNotebookConversations(
    _ notebookId: KaibaNotebookID,
    limit: Int = 50
  ) async throws -> KaibaValuePayload<[KaibaConversation]> {
    try await operation(
      """
      query KaibaNotebookConversations($notebookId: String!, $limit: Int) {
        root: notebookConversations(notebookId: $notebookId, limit: $limit) {
          result { accepted status diagnostics }
          value { notebookId title updatedAt turnCount subjectNoteId subjectNotebookId }
        }
      }
      """,
      variables: ["notebookId": .string(notebookId.rawValue), "limit": .integer(limit)],
      as: KaibaValuePayload<[KaibaConversation]>.self
    )
  }

  public func ingestDocument(
    idempotencyKey: String,
    title: String,
    pages: [KaibaIngestPage],
    sourceDocument: KaibaInlineAttachment? = nil,
    metaJSON: String? = nil,
    originatingActionId: KaibaAutoActionID? = nil
  ) async throws -> KaibaOperationPayload {
    try await ingestNotebookPages(
      idempotencyKey: idempotencyKey,
      title: title,
      pages: pages,
      sourceDocument: sourceDocument,
      metaJSON: metaJSON,
      originatingActionId: originatingActionId
    )
  }

  public func saveConversation(
    title: String,
    transcript: [KaibaConversationTurn],
    assignedBy: String? = nil,
    originatingActionId: KaibaAutoActionID? = nil
  ) async throws -> KaibaOperationPayload {
    var input: [String: KaibaJSONValue] = [
      "title": .string(title),
      "transcript": .array(transcript.map { turn in
        .object([
          "userMarkdown": .string(turn.userMarkdown),
          "assistantMarkdown": .string(turn.assistantMarkdown),
          "sourceNoteIds": .array(turn.sourceNoteIds.map { .string($0.rawValue) })
        ])
      })
    ]
    if let assignedBy { input["assignedBy"] = .string(assignedBy) }
    if let originatingActionId { input["originatingActionId"] = .string(originatingActionId.rawValue) }
    return try await operation(
      """
      mutation KaibaSaveConversation($input: SaveNoteConversationInput!) {
        root: saveNoteConversation(input: $input) {
          result { accepted status diagnostics } notebook { \(Self.notebookFields) }
          notes { \(Self.noteFields) }
        }
      }
      """,
      variables: ["input": .object(input)],
      as: KaibaOperationPayload.self
    )
  }

  public func noteLinks(_ noteId: KaibaNoteID) async throws -> KaibaValuePayload<[KaibaNoteLink]> {
    try await operation(
      "query KaibaNoteLinks($noteId: String!) { root: noteLinks(noteId: $noteId) { result { accepted status diagnostics } value { fromNoteId toNoteId linkKind provenance createdAt } } }",
      variables: ["noteId": .string(noteId.rawValue)],
      as: KaibaValuePayload<[KaibaNoteLink]>.self
    )
  }

  public func longTermMemoryNotebook() async throws -> KaibaValuePayload<KaibaNotebook> {
    try await operation(
      "query KaibaLongTermMemoryNotebook { root: longTermMemoryNotebook { result { accepted status diagnostics } value { \(Self.notebookFields) } } }",
      as: KaibaValuePayload<KaibaNotebook>.self
    )
  }

  public func appendLongTermMemory(
    entries: [KaibaLongTermMemoryEntry],
    idempotencyKey: String
  ) async throws -> KaibaLongTermMemoryAppendPayload {
    let entryValues = entries.map { entry -> KaibaJSONValue in
      var object: [String: KaibaJSONValue] = [
        "bodyMarkdown": .string(entry.bodyMarkdown),
        "topicTags": .array(entry.topicTags.map(KaibaJSONValue.string)),
        "sourceNoteIds": .array(entry.sourceNoteIds.map { .string($0.rawValue) }),
        "relatedNoteIds": .array(entry.relatedNoteIds.map { .string($0.rawValue) })
      ]
      if let periodStart = entry.periodStart { object["periodStart"] = .string(periodStart) }
      if let periodEnd = entry.periodEnd { object["periodEnd"] = .string(periodEnd) }
      if let metaJSON = entry.metaJSON { object["metaJSON"] = .string(metaJSON) }
      return .object(object)
    }
    return try await operation(
      "mutation KaibaAppendLongTermMemory($input: AppendLongTermMemoryInput!) { root: appendLongTermMemory(input: $input) { result { accepted status diagnostics } notes { \(Self.noteFields) } idempotentReplay } }",
      variables: ["input": .object([
        "idempotencyKey": .string(idempotencyKey), "entries": .array(entryValues)
      ])],
      as: KaibaLongTermMemoryAppendPayload.self
    )
  }

  public func recallLongTermMemory(
    query: String,
    limit: Int = 20,
    includeAssociations: Bool = false,
    associationDepth: Int = 2,
    recencyWeight: Double = 0.5
  ) async throws -> KaibaValuePayload<[KaibaLongTermMemoryRecallHit]> {
    try await operation(
      """
      mutation KaibaRecallLongTermMemory($input: RecallLongTermMemoryInput!) {
        root: recallLongTermMemory(input: $input) {
          result { accepted status diagnostics }
          value { note { \(Self.noteFields) } snippet rank isAssociation edgeKind weight hopCount pathNoteIds }
        }
      }
      """,
      variables: ["input": .object([
        "query": .string(query),
        "limit": .integer(limit),
        "includeAssociations": .bool(includeAssociations),
        "associationDepth": .integer(associationDepth),
        "recencyWeight": .double(recencyWeight)
      ])],
      as: KaibaValuePayload<[KaibaLongTermMemoryRecallHit]>.self
    )
  }

  public func linkLongTermMemoryAssociations(
    noteId: KaibaNoteID,
    limit: Int = 8
  ) async throws -> KaibaValuePayload<[KaibaNoteLink]> {
    try await operation(
      """
      mutation KaibaLinkLongTermMemory($noteId: String!, $limit: Int) {
        root: linkLongTermMemoryAssociations(noteId: $noteId, limit: $limit) {
          result { accepted status diagnostics }
          value { fromNoteId toNoteId linkKind provenance createdAt }
        }
      }
      """,
      variables: ["noteId": .string(noteId.rawValue), "limit": .integer(limit)],
      as: KaibaValuePayload<[KaibaNoteLink]>.self
    )
  }

  private func operation<Value: Codable & Equatable & Sendable & KaibaControlPlaneDiagnosticsSanitizable>(
    _ document: String,
    variables: [String: KaibaJSONValue] = [:],
    as type: Value.Type
  ) async throws -> Value {
    let response = try await execute(
      KaibaGraphQLRequest(document: document, variables: variables),
      as: KaibaRootPayload<Value>.self
    )
    return response.data.root.sanitizingDiagnostics(authentication.redactedDiagnostic)
  }

  private func removeNotebookTag(
    notebookId: KaibaNotebookID,
    tagArgument: (name: String, value: String),
    operation: String,
    provenance: String?
  ) async throws -> KaibaOperationPayload {
    var variables: [String: KaibaJSONValue] = [
      "notebookId": .string(notebookId.rawValue),
      tagArgument.name: .string(tagArgument.value)
    ]
    if let provenance { variables["provenance"] = .string(provenance) }
    let argumentVariable = "$\(tagArgument.name)"
    let document = """
    mutation KaibaRemoveNotebookTag(
      $notebookId: String!, $\(tagArgument.name): String!, $provenance: String
    ) {
      root: \(operation)(
        notebookId: $notebookId, \(tagArgument.name): \(argumentVariable), provenance: $provenance
      ) { result { accepted status diagnostics } notebook { \(Self.notebookFields) } }
    }
    """
    return try await self.operation(document, variables: variables, as: KaibaOperationPayload.self)
  }

  private static func tagInput(_ tag: KaibaTagInput) -> KaibaJSONValue {
    var value: [String: KaibaJSONValue] = ["name": .string(tag.name)]
    if let classId = tag.classId { value["classId"] = .string(classId) }
    return .object(value)
  }

  private static func inlineAttachment(_ attachment: KaibaInlineAttachment) -> KaibaJSONValue {
    var value: [String: KaibaJSONValue] = [
      "contentBase64": .string(attachment.bytes.base64EncodedString()),
      "mediaType": .string(attachment.mediaType)
    ]
    if let filename = attachment.originalFilename { value["originalFilename"] = .string(filename) }
    if let role = attachment.role { value["role"] = .string(role.rawValue) }
    return .object(value)
  }

  private static let tagFields = "tag { tagId name classId parentTagId isSystem createdAt } provenance assignedBy deletable createdAt"
  private static let tagDefinitionFields = "tagId name classId parentTagId isSystem createdAt"
  private static let noteFields = "noteId notebookId noteNumber title bodyMarkdown readOnly createdAt updatedAt metaJSON tags { \(tagFields) } createdBy updatedBy"
  private static let notebookFields = "notebookId title readOnly createdAt updatedAt metaJSON tags { \(tagFields) } firstNotePreview noteCount libraryId ownerUserId createdBy updatedBy"
  private static let fileFields = "fileId storageKind localPath s3Profile s3Bucket s3Key mediaType byteSize sha256 originalFilename createdAt migratedAt"
}
