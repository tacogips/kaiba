import Foundation

struct MeilisearchTask {
  var status: String
  var code: String?
  var message: String?
}

enum MeilisearchResponses {
  static func object(_ data: Data, error: String = "JSON object expected") throws -> [String: Any] {
    guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw SearchEngineError.invalidResponse(error)
    }
    return value
  }

  static func hits(_ data: Data, includeHighlight: Bool) throws -> [SearchEngineHit] {
    let root = try object(data, error: "search response malformed")
    guard let raw = root["hits"] as? [[String: Any]] else { throw SearchEngineError.invalidResponse("search hits missing") }
    return try raw.map { item in
      guard let note = item["note_id"] as? String, let score = item["_rankingScore"] as? NSNumber else {
        throw SearchEngineError.invalidResponse("search hit malformed")
      }
      var highlight: String?
      if includeHighlight, let formatted = item["_formatted"] as? [String: Any],
         let matches = item["_matchesPosition"] as? [String: Any] {
        let candidate = matches["body"] != nil ? formatted["body"] as? String :
          (matches["title"] != nil ? formatted["title"] as? String : nil)
        if let candidate {
          let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
          if !trimmed.isEmpty { highlight = String(trimmed.prefix(200)) }
        }
      }
      return SearchEngineHit(noteId: NoteID(note), score: score.doubleValue, highlight: highlight,
        reasons: [SearchEngineHitReason(kind: .textMatch)])
    }
  }

  static func facets(_ data: Data, request: SearchEngineFacetRequest) throws -> SearchEngineFacets {
    let root = try object(data, error: "facet response malformed")
    guard let distribution = root["facetDistribution"] as? [String: [String: Int]] else {
      throw SearchEngineError.invalidResponse("search facets missing")
    }
    func buckets(_ field: String, _ limit: Int) -> [SearchEngineFacetBucket] {
      (distribution[field] ?? [:]).map { SearchEngineFacetBucket(value: $0.key, count: $0.value) }
        .sorted { $0.count != $1.count ? $0.count > $1.count : $0.value < $1.value }.prefix(max(0, limit)).map { $0 }
    }
    return SearchEngineFacets(tagClasses: buckets("tag_classes", request.tagClassLimit), tags: buckets("tag_ids", request.tagLimit))
  }

  static func taskUid(_ data: Data) throws -> Int {
    guard let value = try? object(data)["taskUid"] as? Int else { throw SearchEngineError.invalidResponse("task uid missing") }
    return value
  }

  static func task(_ data: Data) throws -> MeilisearchTask {
    let root = try object(data, error: "task response malformed")
    guard let status = root["status"] as? String else { throw SearchEngineError.invalidResponse("task status missing") }
    let error = root["error"] as? [String: Any]
    return MeilisearchTask(status: status, code: error?["code"] as? String, message: error?["message"] as? String)
  }

  static func errorDescription(_ data: Data) -> String {
    guard let root = try? object(data), let message = root["message"] as? String else { return "unknown_error" }
    let code = root["code"] as? String ?? "unknown_error"
    return String("\(code): \(message)".prefix(200))
  }
}
