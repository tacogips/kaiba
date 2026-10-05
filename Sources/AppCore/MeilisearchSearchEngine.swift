import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private struct MeilisearchRelatedSubquery {
  var text: String
  var weight: Double
  var reason: SearchEngineHitReasonKind
}

private struct MeilisearchRankedHits {
  var hits: [SearchEngineHit]
  var weight: Double
  var reason: SearchEngineHitReasonKind
}

public struct MeilisearchSearchEngine: SearchEngine {
  private let baseURL: URL
  private let indexUid: String
  private let apiKey: String?
  private let transport: any SearchEngineHTTPTransport
  private let requestTimeoutSeconds: Int
  private let taskWaitTimeout: TimeInterval
  private let initialTaskPollInterval: TimeInterval

  public var indexIdentity: String {
    "meilisearch:\(SearchEngineFactory.normalizedTarget(baseURL.absoluteString) ?? baseURL.absoluteString)/\(indexUid)"
  }

  init(
    baseURL: URL,
    indexPrefix: String,
    apiKey: String? = nil,
    requestTimeoutSeconds: Int = 10,
    verifyTLS: Bool = true,
    transport: (any SearchEngineHTTPTransport)? = nil,
    taskWaitTimeout: TimeInterval? = nil,
    initialTaskPollInterval: TimeInterval = 0.05
  ) {
    self.baseURL = baseURL
    indexUid = "\(indexPrefix)-notes-v1"
    self.apiKey = apiKey
    self.requestTimeoutSeconds = requestTimeoutSeconds
    self.taskWaitTimeout = taskWaitTimeout ?? TimeInterval(max(30, requestTimeoutSeconds))
    self.initialTaskPollInterval = initialTaskPollInterval
    self.transport = transport ?? URLSessionSearchEngineTransport(insecureTrustHost: verifyTLS ? nil : baseURL.host)
  }

  public func health() async throws -> SearchEngineHealth {
    let (data, response) = try await send(path: "health", method: "GET", timeout: TimeInterval(requestTimeoutSeconds))
    try requireSuccess(response, body: data)
    let status = try MeilisearchResponses.object(data)["status"] as? String ?? "unknown"
    return SearchEngineHealth(isAvailable: status == "available", detail: status)
  }

  public func ensureIndex() async throws {
    let (data, response) = try await send(path: "indexes/\(indexUid)", method: "GET", timeout: TimeInterval(requestTimeoutSeconds))
    if response.statusCode == 404 {
      let (created, createResponse) = try await send(path: "indexes", method: "POST",
        body: try MeilisearchRequestBodies.data(["uid": indexUid, "primaryKey": "id"]),
        timeout: TimeInterval(max(30, requestTimeoutSeconds)))
      if (200..<300).contains(createResponse.statusCode) {
        let task = try await waitForTask(MeilisearchResponses.taskUid(created))
        if task.status != "succeeded", task.code != "index_already_exists" {
          throw SearchEngineError.unavailable(sanitized("\(task.code ?? task.status): \(task.message ?? "task failed")"))
        }
      } else {
        let detail = MeilisearchResponses.errorDescription(created)
        if !detail.hasPrefix("index_already_exists:") { try requireSuccess(createResponse, body: created) }
      }
    } else {
      try requireSuccess(response, body: data)
    }
    let (settingsData, settingsResponse) = try await send(path: "indexes/\(indexUid)/settings", method: "PATCH",
      body: try MeilisearchRequestBodies.data(MeilisearchRequestBodies.settings), timeout: TimeInterval(max(30, requestTimeoutSeconds)))
    try requireSuccess(settingsResponse, body: settingsData)
    let settingsTask = try await waitForTask(MeilisearchResponses.taskUid(settingsData))
    if settingsTask.status != "succeeded" {
      throw SearchEngineError.unavailable(sanitized("\(settingsTask.code ?? settingsTask.status): \(settingsTask.message ?? "task failed")"))
    }
  }

  public func apply(_ operations: [SearchIndexOperation]) async throws -> [SearchIndexOperationResult] {
    guard !operations.isEmpty else { return [] }
    let upserts = operations.compactMap { operation -> SearchIndexDocument? in
      if case let .upsert(document) = operation { return document }
      return nil
    }
    let deletes = operations.compactMap { operation -> NoteID? in
      if case let .delete(id) = operation { return id }
      return nil
    }
    var outcomes: [NoteID: SearchIndexOperationOutcome] = [:]
    if !upserts.isEmpty {
      let response = try await submitUpserts(upserts)
      if let (code, _) = response, code.hasPrefix("invalid_document"), upserts.count > 1 {
        for document in upserts {
          let individual = try await submitUpserts([document])
          outcomes[document.noteId] = individual.map { .failed(String(sanitized("\($0.0): \($0.1)").prefix(500))) } ?? .succeeded
        }
      } else {
        let outcome: SearchIndexOperationOutcome = response.map { .failed(String(sanitized("\($0.0): \($0.1)").prefix(500))) } ?? .succeeded
        for document in upserts { outcomes[document.noteId] = outcome }
      }
    }
    if !deletes.isEmpty {
      let body = try MeilisearchRequestBodies.data(deletes.map(MeilisearchRequestBodies.documentId))
      let (data, http) = try await send(path: "indexes/\(indexUid)/documents/delete-batch", method: "POST", body: body,
        timeout: TimeInterval(max(30, requestTimeoutSeconds)))
      try requireSuccess(http, body: data)
      let taskId = try MeilisearchResponses.taskUid(data)
      let task = try await waitForTask(taskId)
      let outcome: SearchIndexOperationOutcome = task.status == "succeeded" ? .succeeded :
        .failed(String(sanitized("\(task.code ?? task.status): \(task.message ?? "task failed")").prefix(500)))
      for id in deletes { outcomes[id] = outcome }
    }
    return operations.map { SearchIndexOperationResult(noteId: $0.noteId, outcome: outcomes[$0.noteId] ?? .succeeded) }
  }

  public func search(_ query: SearchEngineQuery) async throws -> [SearchEngineHit] { try await searchPage(query).hits }

  public func searchPage(_ query: SearchEngineQuery) async throws -> SearchEngineSearchPage {
    guard query.filter.libraryIds != [] else { return SearchEngineSearchPage(hits: [], facets: nil) }
    if query.expansionTagIds.isEmpty {
      var searchBody = MeilisearchRequestBodies.search(query)
      searchBody["offset"] = query.from
      searchBody["limit"] = query.size
      let body = try MeilisearchRequestBodies.data(searchBody)
      let (data, response) = try await send(path: "indexes/\(indexUid)/search", method: "POST", body: body,
        timeout: TimeInterval(requestTimeoutSeconds))
      try requireSuccess(response, body: data)
      let facets = try query.facets.map { try MeilisearchResponses.facets(data, request: $0) }
      return SearchEngineSearchPage(hits: try MeilisearchResponses.hits(data, includeHighlight: true), facets: facets)
    }
    let expansion = query.expansionTagIds.map { quoteFilterValue($0.rawValue) }.joined(separator: ", ")
    let base = MeilisearchRequestBodies.search(query)
    let textQuery = base
    let tagQuery = MeilisearchRequestBodies.search(query, text: "", extra: ["tag_ids IN [\(expansion)]"], filterOnly: true)
    let hierarchyQuery = MeilisearchRequestBodies.search(query, text: "", extra: ["path_tag_ids IN [\(expansion)]"], filterOnly: true)
    let (data, response) = try await send(path: "multi-search", method: "POST",
      body: try MeilisearchRequestBodies.data(MeilisearchRequestBodies.multiSearch([textQuery, tagQuery, hierarchyQuery], index: indexUid)),
      timeout: TimeInterval(requestTimeoutSeconds))
    try requireSuccess(response, body: data)
    return try expandedSearch(data, query: query)
  }

  private func expandedSearch(_ data: Data, query: SearchEngineQuery) throws -> SearchEngineSearchPage {
    guard let root = try? MeilisearchResponses.object(data), let results = root["results"] as? [[String: Any]], results.count == 3 else {
      throw SearchEngineError.invalidResponse("multi-search response malformed")
    }
    let parsed = try results.map { try MeilisearchResponses.hits(MeilisearchRequestBodies.data($0), includeHighlight: true) }
    let labels: [SearchEngineHitReasonKind] = [.textMatch, .tagMatch, .tagHierarchyMatch]
    let weights = [1.0, 1.0, 0.5]
    let lists = zip(parsed, labels).enumerated().map { index, pair in
      NoteRetrievalCandidateList(label: .searchEngine, weight: weights[index], tier: .direct,
      entries: pair.0.map { hit in NoteRetrievalCandidateEntry(noteId: hit.noteId,
          provenance: NoteRetrievalProvenance(reasons: [pair.1])) })
    }
    let fused = NoteRetrievalReranker.fuse(lists, limit: min(query.from + query.size, NoteRetrievalFusionPolicy.maximumFusedWindow))
    let textHighlights = Dictionary(parsed[0].map { ($0.noteId, $0.highlight) }, uniquingKeysWith: { first, _ in first })
    let hits = fused.dropFirst(query.from).prefix(query.size).map {
      SearchEngineHit(noteId: $0.noteId, score: $0.score, highlight: textHighlights[$0.noteId] ?? nil,
        reasons: $0.provenance.reasons.map { SearchEngineHitReason(kind: $0) })
    }
    let facets = try query.facets.map { try MeilisearchResponses.facets(MeilisearchRequestBodies.data(results[0]), request: $0) }
    return SearchEngineSearchPage(hits: Array(hits), facets: facets)
  }

  public func relatedNotes(_ query: SearchEngineRelatedQuery) async throws -> [SearchEngineHit] {
    guard query.filter.libraryIds != [] else { return [] }
    let signals = query.signals
    var specifications: [MeilisearchRelatedSubquery] = []
    let salient = MeilisearchRequestBodies.salientTerms(query.likeText).joined(separator: " ")
    if !salient.isEmpty { specifications.append(MeilisearchRelatedSubquery(text: salient, weight: 1.0, reason: .textSimilarity)) }
    if let signals {
      if !signals.sharedTagIds.isEmpty {
        let filter = "tag_ids IN [\(signals.sharedTagIds.map { quoteFilterValue($0.rawValue) }.joined(separator: ", "))]"
        specifications.append(MeilisearchRelatedSubquery(text: filter, weight: 3.0, reason: .sharedTag))
      }
      var relatedClauses: [String] = []
      if !signals.nearTagIds.isEmpty {
        relatedClauses.append("path_tag_ids IN [\(signals.nearTagIds.map { quoteFilterValue($0.rawValue) }.joined(separator: ", "))]")
      }
      if !signals.ancestorTagIds.isEmpty {
        relatedClauses.append("tag_ids IN [\(signals.ancestorTagIds.map { quoteFilterValue($0.rawValue) }.joined(separator: ", "))]")
      }
      if !relatedClauses.isEmpty {
        specifications.append(MeilisearchRelatedSubquery(text: "(\(relatedClauses.joined(separator: " OR ")))", weight: 1.5, reason: .relatedTag))
      }
      if !signals.entityTags.isEmpty {
        let values = signals.entityTags.map { quoteFilterValue("\($0.tagClass):\($0.tagId.rawValue)") }.joined(separator: ", ")
        specifications.append(MeilisearchRelatedSubquery(text: "class_tag_keys IN [\(values)]", weight: 2.0, reason: .sharedEntity))
      }
      let source = quoteFilterValue(signals.sourceNoteId.rawValue)
      let linked = "outgoing_link_note_ids = \(source) OR incoming_link_note_ids = \(source)"
      specifications.append(MeilisearchRelatedSubquery(text: linked, weight: 5.0, reason: .linked))
    }
    guard !specifications.isEmpty else { return [] }
    var relatedFilter = query.filter
    if let sourceNoteId = signals?.sourceNoteId, !relatedFilter.excludedNoteIds.contains(sourceNoteId) {
      relatedFilter.excludedNoteIds.append(sourceNoteId)
    }
    let base = SearchEngineQuery(text: query.likeText, filter: relatedFilter, from: 0, size: query.size)
    let bodies = specifications.map { specification in
      let filterOnly = specification.reason != .textSimilarity
      return MeilisearchRequestBodies.search(base, text: filterOnly ? "" : specification.text,
        extra: filterOnly ? [specification.text] : [], filterOnly: filterOnly)
    }
    let (data, response) = try await send(path: "multi-search", method: "POST",
      body: try MeilisearchRequestBodies.data(MeilisearchRequestBodies.multiSearch(bodies, index: indexUid)),
      timeout: TimeInterval(requestTimeoutSeconds))
    try requireSuccess(response, body: data)
    guard let root = try? MeilisearchResponses.object(data), let rawResults = root["results"] as? [[String: Any]],
          rawResults.count == specifications.count else { throw SearchEngineError.invalidResponse("multi-search response malformed") }
    let lists = try zip(rawResults, specifications).map { result, specification in
      MeilisearchRankedHits(hits: try MeilisearchResponses.hits(MeilisearchRequestBodies.data(result), includeHighlight: false),
        weight: specification.weight, reason: specification.reason)
    }
    let candidates = lists.map { list in NoteRetrievalCandidateList(label: .searchEngine, weight: list.weight, tier: .direct,
      entries: list.hits.map { NoteRetrievalCandidateEntry(noteId: $0.noteId,
        provenance: NoteRetrievalProvenance(reasons: [SearchEngineHitReason(kind: list.reason).kind])) }) }
    return NoteRetrievalReranker.fuse(candidates, limit: query.size).map { candidate in
      SearchEngineHit(noteId: candidate.noteId, score: candidate.score, highlight: nil,
        reasons: candidate.provenance.reasons.map { SearchEngineHitReason(kind: $0) })
    }
  }

  private func submitUpserts(_ documents: [SearchIndexDocument]) async throws -> (String, String)? {
    let body = try MeilisearchRequestBodies.data(documents.map(MeilisearchRequestBodies.document))
    let (data, response) = try await send(path: "indexes/\(indexUid)/documents?primaryKey=id", method: "POST", body: body,
      timeout: TimeInterval(max(30, requestTimeoutSeconds)))
    try requireSuccess(response, body: data)
    let task = try await waitForTask(MeilisearchResponses.taskUid(data))
    return task.status == "succeeded" ? nil : (task.code ?? task.status, task.message ?? "task failed")
  }

  @discardableResult
  private func waitForTask(_ uid: Int) async throws -> MeilisearchTask {
    let deadline = Date().addingTimeInterval(taskWaitTimeout)
    var interval = initialTaskPollInterval
    while Date() < deadline {
      let (data, response) = try await send(path: "tasks/\(uid)", method: "GET", timeout: TimeInterval(max(30, requestTimeoutSeconds)))
      try requireSuccess(response, body: data)
      let task = try MeilisearchResponses.task(data)
      switch task.status {
      case "succeeded": return task
      case "failed", "canceled": return task
      default: break
      }
      try await Task.sleep(for: .seconds(interval))
      interval = min(interval * 2, 1.0)
    }
    throw SearchEngineError.unavailable("task pending")
  }

  private func send(path: String, method: String, body: Data? = nil, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
    let pathParts = path.split(separator: "?", maxSplits: 1).map(String.init)
    var url = baseURL.appendingPathComponent(pathParts[0])
    if pathParts.count == 2, let query = URLComponents(string: "?\(pathParts[1])") {
      var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
      components?.queryItems = query.queryItems
      url = components?.url ?? url
    }
    var request = URLRequest(url: url, timeoutInterval: timeout)
    request.httpMethod = method
    request.httpBody = body
    if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
    do {
      return try await transport.send(request)
    } catch let error as SearchEngineError {
      throw error
    } catch let error as URLError {
      throw SearchEngineError.unavailable("URLError \(error.code.rawValue)")
    } catch {
      throw SearchEngineError.unavailable("transport failure")
    }
  }

  private func requireSuccess(_ response: HTTPURLResponse, body: Data) throws {
    guard (200..<300).contains(response.statusCode) else {
      let reason = sanitized(MeilisearchResponses.errorDescription(body))
      if response.statusCode == 401 || response.statusCode == 403 || (400..<500).contains(response.statusCode) {
        throw SearchEngineError.rejected(status: response.statusCode, reason: reason)
      }
      if response.statusCode >= 500 { throw SearchEngineError.unavailable("HTTP \(response.statusCode)") }
      throw SearchEngineError.invalidResponse("HTTP \(response.statusCode)")
    }
  }

  private func sanitized(_ value: String) -> String {
    guard let apiKey, !apiKey.isEmpty else { return String(value.prefix(200)) }
    return String(value.replacingOccurrences(of: apiKey, with: "[redacted]").prefix(200))
  }

  private func quoteFilterValue(_ value: String) -> String {
    "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
  }
}
