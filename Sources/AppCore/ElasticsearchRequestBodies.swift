import Foundation

enum ElasticsearchRequestBodies {
  static func data(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }

  static var index: [String: Any] {
    return [
      "settings": ["analysis": ["analyzer": ["cjk": ["type": "cjk"]]]],
      "mappings": [
        "dynamic": "strict",
        "properties": [
          "note_id": ["type": "keyword"],
          "notebook_id": ["type": "keyword"],
          "library_id": ["type": "keyword"],
          "owner_user_id": ["type": "keyword"],
          "tag_ids": ["type": "keyword"],
          "path_tag_ids": ["type": "keyword"],
          "path_tag_names": ["type": "keyword"],
          "tag_classes": ["type": "keyword"],
          "class_tag_keys": ["type": "keyword"],
          "tag_provenance_keys": ["type": "keyword"],
          "outgoing_link_note_ids": ["type": "keyword"],
          "incoming_link_note_ids": ["type": "keyword"],
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
      "path_tag_ids": document.pathTags.map { $0.tagId.rawValue },
      "path_tag_names": document.pathTags.map(\.name),
      "tag_classes": Array(Set(document.pathTags.compactMap(\.tagClass))).sorted(),
      "class_tag_keys": document.pathTags.compactMap { tag in
        tag.tagClass.map { "\($0):\(tag.tagId.rawValue)" }
      }.sorted(),
      "tag_provenance_keys": document.tagApplications.map {
        "\($0.provenance):\($0.tagId.rawValue)"
      }.sorted(),
      "outgoing_link_note_ids": document.outgoingLinkNoteIds.map(\.rawValue),
      "incoming_link_note_ids": document.incomingLinkNoteIds.map(\.rawValue),
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
    var result: [String: Any] = [
      "from": query.from,
      "size": query.size,
      "_source": ["note_id"],
      "query": ["bool": searchBoolQuery(query)],
      "highlight": [
        "fields": ["body": [String: Any](), "title": [String: Any]()],
        "fragment_size": 160,
        "number_of_fragments": 1,
        "pre_tags": [""],
        "post_tags": [""]
      ]
    ]
    if let facets = query.facets {
      result["aggs"] = [
        "tag_classes": ["terms": ["field": "tag_classes", "size": facets.tagClassLimit]],
        "tags": ["terms": ["field": "tag_ids", "size": facets.tagLimit]]
      ]
    }
    return result
  }

  private static func searchBoolQuery(_ query: SearchEngineQuery) -> [String: Any] {
    var should: [[String: Any]] = [["multi_match": [
          "query": query.text,
          "fields": ["title^3", "body", "tags^2", "context"],
          "operator": "or",
          "_name": SearchEngineHitReasonKind.textMatch.rawValue
        ]]]
    if !query.expansionTagIds.isEmpty {
      let ids = query.expansionTagIds.map(\.rawValue)
      should.append(["constant_score": [
        "filter": ["terms": ["tag_ids": ids]], "boost": 4.0,
        "_name": SearchEngineHitReasonKind.tagMatch.rawValue
      ]])
      should.append(["constant_score": [
        "filter": ["terms": ["path_tag_ids": ids]], "boost": 2.0,
        "_name": SearchEngineHitReasonKind.tagHierarchyMatch.rawValue
      ]])
    }
    return boolQuery(should: should, filter: filter(query.filter), mustNot: mustNot(query.filter))
  }

  static func related(_ query: SearchEngineRelatedQuery) -> [String: Any] {
    let signals = query.signals
    var should: [[String: Any]] = []
    if !query.likeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      should.append(["more_like_this": [
        "fields": ["title", "body", "tags", "context"],
        "like": query.likeText,
        "min_term_freq": 1,
        "min_doc_freq": 1,
        "max_query_terms": 25,
        // The cjk analyzer turns a note into many bigrams, so the 30% default
        // drops notes that share only a phrase with the source.
        "minimum_should_match": "10%",
        "_name": SearchEngineHitReasonKind.textSimilarity.rawValue
      ]])
    }
    if let signals {
      if !signals.sharedTagIds.isEmpty {
        should.append(["constant_score": [
          "filter": ["terms": ["tag_ids": signals.sharedTagIds.map(\.rawValue)]],
          "boost": 3.0, "_name": SearchEngineHitReasonKind.sharedTag.rawValue
        ]])
      }
      var relatedTagClauses: [[String: Any]] = []
      if !signals.nearTagIds.isEmpty {
        relatedTagClauses.append(["terms": ["path_tag_ids": signals.nearTagIds.map(\.rawValue)]])
      }
      if !signals.ancestorTagIds.isEmpty {
        relatedTagClauses.append(["terms": ["tag_ids": signals.ancestorTagIds.map(\.rawValue)]])
      }
      if !relatedTagClauses.isEmpty {
        should.append(["constant_score": [
          "filter": ["bool": ["should": relatedTagClauses, "minimum_should_match": 1]],
          "boost": 1.5, "_name": SearchEngineHitReasonKind.relatedTag.rawValue
        ]])
      }
      if !signals.entityTags.isEmpty {
        let keys = signals.entityTags.map { "\($0.tagClass):\($0.tagId.rawValue)" }
        should.append(["constant_score": [
          "filter": ["terms": ["class_tag_keys": keys]],
          "boost": 2.0, "_name": SearchEngineHitReasonKind.sharedEntity.rawValue
        ]])
      }
      should.append(["constant_score": [
        "filter": ["bool": ["should": [
          ["term": ["outgoing_link_note_ids": signals.sourceNoteId.rawValue]],
          ["term": ["incoming_link_note_ids": signals.sourceNoteId.rawValue]]
        ], "minimum_should_match": 1]],
        "boost": 5.0, "_name": SearchEngineHitReasonKind.linked.rawValue
      ]])
    }
    return [
      "size": query.size,
      "_source": ["note_id"],
      "query": ["bool": boolQuery(should: should, filter: filter(query.filter), mustNot: mustNot(query.filter))]
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

  private static func boolQuery(should: [[String: Any]], filter: [[String: Any]], mustNot: [[String: Any]]) -> [String: Any] {
    ["should": should, "minimum_should_match": 1, "filter": filter, "must_not": mustNot]
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
    if !value.hierarchyTagIds.isEmpty {
      clauses.append(["terms": ["path_tag_ids": value.hierarchyTagIds.map(\.rawValue)]])
    }
    for classFilter in value.tagClassFilters {
      if let tagId = classFilter.tagId {
        clauses.append(["term": ["class_tag_keys": "\(classFilter.tagClass):\(tagId.rawValue)"]])
      } else {
        clauses.append(["term": ["tag_classes": classFilter.tagClass]])
      }
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
