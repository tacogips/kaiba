import Foundation

public extension NoteService {
  /// Whether explicit engine-backed search is available (design SE4).
  var isSearchEngineEnabled: Bool { searchEngine != nil }

  /// Searches the configured engine, then re-checks each hit against the store (design SE4).
  func engineSearchNotes(
    query: String,
    notebookId: NotebookID? = nil,
    tagFilter: [String] = [],
    limit: Int = 20,
    offset: Int = 0
  ) async throws -> [NoteEngineSearchHit] {
    guard let engine = searchEngine else { throw SearchEngineError.notConfigured }
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedQuery.isEmpty else {
      throw NoteServiceError.invalidInput("query must not be empty")
    }
    guard limit > 0 else { return [] }
    let requestedOffset = max(0, offset)

    let prepared = try driver.withDatabase { database -> (NoteSearchScope, [TagID])? in
      let scope = try makeNoteSearchScope(notebookId: notebookId, in: database)
      guard scope.reachableLibraryIds != [] else { return nil }
      let tagIds = try expandedTagFilterIds(names: tagFilter, in: database)
      guard tagFilter.isEmpty || !tagIds.isEmpty else { return nil }
      return (scope, tagIds)
    }
    guard let (scope, tagIds) = prepared else { return [] }

    let (sum, sumOverflow) = requestedOffset.addingReportingOverflow(limit)
    let (fetchSize, fetchOverflow) = (sumOverflow ? Int.max : sum).addingReportingOverflow(20)
    let hits = try await engine.search(SearchEngineQuery(
      text: trimmedQuery,
      filter: searchEngineFilter(for: scope, tagIds: tagIds, excludedNoteIds: []),
      from: 0,
      size: sumOverflow || fetchOverflow ? Int.max : fetchSize
    ))

    return try driver.withDatabase { database in
      let allowedIds = try scopedNoteIds(hits.map(\.noteId), scope: scope, in: database)
      var orderedHits: [SearchEngineHit] = []
      var seen = Set<NoteID>()
      for hit in hits where allowedIds.contains(hit.noteId) && seen.insert(hit.noteId).inserted {
        orderedHits.append(hit)
      }
      let page = Array(orderedHits.dropFirst(requestedOffset).prefix(limit))
      let notesById = try requireNotes(page.map(\.noteId), in: database)
      let searchTexts = try noteSearchTexts(Array(notesById.keys), in: database)
      return page.compactMap { hit in
        guard let note = notesById[hit.noteId] else { return nil }
        let retrievalText = noteRetrievalText(
          bodyMarkdown: note.bodyMarkdown,
          searchText: searchTexts[note.noteId]
        )
        let highlight = hit.highlight?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resultSnippet: String
        if let highlight, !highlight.isEmpty {
          resultSnippet = highlight
        } else {
          resultSnippet = snippet(from: retrievalText, query: trimmedQuery)
        }
        return NoteEngineSearchHit(
          note: note,
          snippet: resultSnippet,
          score: hit.score
        )
      }
    }
  }

  /// Finds related notes for a readable source note, with store re-checks (design SE4).
  func relatedNotes(noteId: NoteID, limit: Int = 8) async throws -> [NoteEngineSearchHit] {
    guard let engine = searchEngine else { throw SearchEngineError.notConfigured }

    let prepared = try driver.withDatabase { database -> (NoteSearchScope, String)? in
      let source = try requireNote(noteId, in: database)
      guard limit > 0 else { return nil }
      let scope = try makeNoteSearchScope(notebookId: nil, in: database)
      guard scope.reachableLibraryIds != [] else { return nil }
      let sourceText = noteRetrievalText(
        bodyMarkdown: source.bodyMarkdown,
        searchText: try noteSearchText(source.noteId, in: database)
      )
      return (scope, (source.title ?? "") + "\n" + sourceText)
    }
    guard let (scope, sourceText) = prepared else { return [] }
    let likeText = String(sourceText.prefix(4000))
    let (fetchSize, overflowed) = limit.addingReportingOverflow(20)
    let hits = try await engine.relatedNotes(SearchEngineRelatedQuery(
      likeText: likeText,
      filter: searchEngineFilter(for: scope, tagIds: [], excludedNoteIds: [noteId]),
      size: overflowed ? Int.max : fetchSize
    ))

    return try driver.withDatabase { database in
      let allowedIds = try scopedNoteIds(hits.map(\.noteId), scope: scope, in: database)
      var orderedHits: [SearchEngineHit] = []
      var seen = Set<NoteID>()
      for hit in hits where hit.noteId != noteId && allowedIds.contains(hit.noteId)
        && seen.insert(hit.noteId).inserted {
        orderedHits.append(hit)
      }
      let page = Array(orderedHits.prefix(limit))
      let notesById = try requireNotes(page.map(\.noteId), in: database)
      let searchTexts = try noteSearchTexts(Array(notesById.keys), in: database)
      return page.compactMap { hit in
        guard let note = notesById[hit.noteId] else { return nil }
        let text = noteRetrievalText(bodyMarkdown: note.bodyMarkdown, searchText: searchTexts[note.noteId])
        let highlight = hit.highlight?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resultSnippet: String
        if let highlight, !highlight.isEmpty {
          resultSnippet = highlight
        } else {
          resultSnippet = snippet(from: text, query: "")
        }
        return NoteEngineSearchHit(
          note: note,
          snippet: resultSnippet,
          score: hit.score
        )
      }
    }
  }
}
