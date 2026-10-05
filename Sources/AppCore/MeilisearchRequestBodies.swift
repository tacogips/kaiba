import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

enum MeilisearchRequestBodies {
  static func data(_ object: Any) throws -> Data {
    guard JSONSerialization.isValidJSONObject(object) else {
      throw SearchEngineError.invalidResponse("could not encode request")
    }
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }

  static func documentId(_ noteId: NoteID) -> String {
    let raw = noteId.rawValue
    if raw.range(of: "^[A-Za-z0-9_-]{1,511}$", options: .regularExpression) != nil { return raw }
    let digest = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    return "x-\(digest)"
  }

  static func document(_ value: SearchIndexDocument) -> [String: Any] {
    [
      "id": documentId(value.noteId), "note_id": value.noteId.rawValue,
      "notebook_id": value.notebookId.rawValue, "library_id": value.libraryId.rawValue,
      "owner_user_id": value.ownerUserId?.rawValue as Any? ?? NSNull(),
      "title": value.title, "body": value.body, "tags": value.tagNames.joined(separator: " "),
      "context": value.context, "tag_ids": value.tagIds.map(\.rawValue),
      "path_tag_ids": value.pathTags.map { $0.tagId.rawValue },
      "path_tag_names": value.pathTags.map(\.name),
      "tag_classes": Array(Set(value.pathTags.compactMap(\.tagClass))).sorted(),
      "class_tag_keys": value.pathTags.compactMap { tag in tag.tagClass.map { "\($0):\(tag.tagId.rawValue)" } }.sorted(),
      "tag_provenance_keys": value.tagApplications.map { "\($0.provenance):\($0.tagId.rawValue)" }.sorted(),
      "outgoing_link_note_ids": value.outgoingLinkNoteIds.map(\.rawValue),
      "incoming_link_note_ids": value.incomingLinkNoteIds.map(\.rawValue),
      "long_term_memory": value.isLongTermMemory, "created_at": value.createdAt, "updated_at": value.updatedAt
    ]
  }

  static var settings: [String: Any] {
    [
      "searchableAttributes": ["title", "tags", "body", "context"],
      "filterableAttributes": ["note_id", "notebook_id", "library_id", "owner_user_id", "tag_ids", "path_tag_ids",
        "tag_classes", "class_tag_keys", "outgoing_link_note_ids", "incoming_link_note_ids", "long_term_memory"],
      "sortableAttributes": ["updated_at"],
      "localizedAttributes": [["attributePatterns": ["title", "tags", "body", "context"], "locales": ["jpn"]]],
      "pagination": ["maxTotalHits": 2000],
      "faceting": ["sortFacetValuesBy": ["*": "count"], "maxValuesPerFacet": 100]
    ]
  }

  static func filterExpression(_ filter: SearchEngineFilter, extra: [String] = []) -> [String] {
    var clauses = extra
    if let ids = filter.libraryIds { clauses.append("library_id IN [\(ids.map { quote($0.rawValue) }.joined(separator: ", "))]") }
    if let value = filter.ownerUserId { clauses.append("owner_user_id = \(quote(value.rawValue))") }
    if let value = filter.notebookId { clauses.append("notebook_id = \(quote(value.rawValue))") }
    if !filter.tagIds.isEmpty { clauses.append("tag_ids IN [\(filter.tagIds.map { quote($0.rawValue) }.joined(separator: ", "))]") }
    if !filter.hierarchyTagIds.isEmpty {
      clauses.append("path_tag_ids IN [\(filter.hierarchyTagIds.map { quote($0.rawValue) }.joined(separator: ", "))]")
    }
    for item in filter.tagClassFilters {
      if let tagId = item.tagId {
        clauses.append("class_tag_keys = \(quote("\(item.tagClass):\(tagId.rawValue)"))")
      } else {
        clauses.append("tag_classes = \(quote(item.tagClass))")
      }
    }
    if filter.excludesLongTermMemory { clauses.append("long_term_memory = false") }
    if !filter.excludedNoteIds.isEmpty {
      clauses.append("NOT note_id IN [\(filter.excludedNoteIds.map { quote($0.rawValue) }.joined(separator: ", "))]")
    }
    return clauses
  }

  static func search(_ query: SearchEngineQuery, text: String? = nil, extra: [String] = [], filterOnly: Bool = false) -> [String: Any] {
    var body: [String: Any] = [
      "q": filterOnly ? "" : (text ?? query.text), "filter": filterExpression(query.filter, extra: extra),
      "offset": 0, "limit": max(0, query.from + query.size), "showRankingScore": true,
      "showMatchesPosition": true, "matchingStrategy": "last", "locales": ["jpn"],
      "attributesToRetrieve": ["note_id", "title", "body"]
    ]
    if filterOnly {
      body["sort"] = ["updated_at:desc"]
    } else {
      body["attributesToCrop"] = ["body", "title"]
      body["cropLength"] = 24
      body["highlightPreTag"] = ""
      body["highlightPostTag"] = ""
      body["cropMarker"] = ""
      if query.facets != nil { body["facets"] = ["tag_classes", "tag_ids"] }
    }
    return body
  }

  static func multiSearch(_ queries: [[String: Any]], index: String) -> [String: Any] {
    ["queries": queries.map { ["indexUid": index, "q": $0["q"] ?? "", "filter": $0["filter"] ?? [],
      "limit": $0["limit"] ?? 0, "offset": 0, "showRankingScore": true,
      "showMatchesPosition": $0["showMatchesPosition"] ?? false,
      "matchingStrategy": "last", "locales": ["jpn"]].merging($0) { _, new in new } }]
  }

  static func salientTerms(_ text: String) -> [String] {
    let terms = ftsTerms(from: text).map { $0.lowercased() }.filter { $0.count >= 2 }
    var count: [String: Int] = [:]
    var first: [String: Int] = [:]
    for (index, term) in terms.enumerated() { count[term, default: 0] += 1; first[term] = min(first[term] ?? index, index) }
    return count.keys.sorted { count[$0, default: 0] != count[$1, default: 0] ? count[$0, default: 0] > count[$1, default: 0] : first[$0, default: 0] < first[$1, default: 0] }.prefix(10).map { $0 }
  }

  private static func quote(_ value: String) -> String {
    "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
  }
}
