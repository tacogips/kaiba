import Foundation

enum ElasticsearchRequestBodies {
  static func data(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }

  static var index: [String: Any] {
    [
      "settings": ["analysis": ["analyzer": ["cjk": ["type": "cjk"]]]],
      "mappings": [
        "dynamic": "strict",
        "properties": [
          "note_id": ["type": "keyword"],
          "notebook_id": ["type": "keyword"],
          "library_id": ["type": "keyword"],
          "owner_user_id": ["type": "keyword"],
          "tag_ids": ["type": "keyword"],
          "long_term_memory": ["type": "boolean"],
          "created_at": ["type": "date"],
          "updated_at": ["type": "date"],
          "title": ["type": "text", "analyzer": "cjk"],
          "body": ["type": "text", "analyzer": "cjk"],
          "tags": ["type": "text", "analyzer": "cjk"],
          "context": ["type": "text", "analyzer": "cjk"]
        ]
      ]
    ]
  }

  static func document(_ document: SearchIndexDocument) -> [String: Any] {
    var result: [String: Any] = [
      "note_id": document.noteId.rawValue,
      "notebook_id": document.notebookId.rawValue,
      "library_id": document.libraryId.rawValue,
      "tag_ids": document.tagIds.map(\.rawValue),
      "title": document.title,
      "body": document.body,
      "tags": document.tagNames.joined(separator: " "),
      "context": document.context,
      "long_term_memory": document.isLongTermMemory,
      "created_at": document.createdAt,
      "updated_at": document.updatedAt
    ]
    if let ownerUserId = document.ownerUserId {
      result["owner_user_id"] = ownerUserId.rawValue
    } else {
      result["owner_user_id"] = NSNull()
    }
    return result
  }

  static func search(_ query: SearchEngineQuery) -> [String: Any] {
    [
      "from": query.from,
      "size": query.size,
      "_source": ["note_id"],
      "query": ["bool": boolQuery(
        must: [["multi_match": [
          "query": query.text,
          "fields": ["title^3", "body", "tags^2", "context"],
          "operator": "or"
        ]]],
        filter: filter(query.filter),
        mustNot: mustNot(query.filter)
      )],
      "highlight": [
        "fields": ["body": [String: Any](), "title": [String: Any]()],
        "fragment_size": 160,
        "number_of_fragments": 1,
        "pre_tags": [""],
        "post_tags": [""]
      ]
    ]
  }

  static func related(_ query: SearchEngineRelatedQuery) -> [String: Any] {
    [
      "size": query.size,
      "_source": ["note_id"],
      "query": ["bool": boolQuery(
        must: [["more_like_this": [
          "fields": ["title", "body", "tags", "context"],
          "like": query.likeText,
          "min_term_freq": 1,
          "min_doc_freq": 1,
          "max_query_terms": 25
        ]]],
        filter: filter(query.filter),
        mustNot: mustNot(query.filter)
      )]
    ]
  }

  static func bulk(_ operations: [SearchIndexOperation], indexName: String) throws -> Data {
    var lines: [String] = []
    for operation in operations {
      switch operation {
      case let .upsert(indexedDocument):
        lines.append(try line(["index": ["_index": indexName, "_id": indexedDocument.noteId.rawValue]]))
        lines.append(try line(document(indexedDocument)))
      case let .delete(noteId):
        lines.append(try line(["delete": ["_index": indexName, "_id": noteId.rawValue]]))
      }
    }
    return Data((lines.joined(separator: "\n") + "\n").utf8)
  }

  private static func line(_ value: Any) throws -> String {
    guard let string = String(data: try data(value), encoding: .utf8) else {
      throw SearchEngineError.invalidResponse("could not encode request")
    }
    return string
  }

  private static func boolQuery(must: [[String: Any]], filter: [[String: Any]], mustNot: [[String: Any]]) -> [String: Any] {
    ["must": must, "filter": filter, "must_not": mustNot]
  }

  private static func filter(_ value: SearchEngineFilter) -> [[String: Any]] {
    var clauses: [[String: Any]] = []
    if let libraryIds = value.libraryIds {
      clauses.append(["terms": ["library_id": libraryIds.map(\.rawValue)]])
    }
    if let owner = value.ownerUserId {
      clauses.append(["term": ["owner_user_id": owner.rawValue]])
    }
    if let notebook = value.notebookId {
      clauses.append(["term": ["notebook_id": notebook.rawValue]])
    }
    if !value.tagIds.isEmpty {
      clauses.append(["terms": ["tag_ids": value.tagIds.map(\.rawValue)]])
    }
    return clauses
  }

  private static func mustNot(_ value: SearchEngineFilter) -> [[String: Any]] {
    var clauses: [[String: Any]] = []
    if value.excludesLongTermMemory {
      clauses.append(["term": ["long_term_memory": true]])
    }
    if !value.excludedNoteIds.isEmpty {
      clauses.append(["ids": ["values": value.excludedNoteIds.map(\.rawValue)]])
    }
    return clauses
  }
}
