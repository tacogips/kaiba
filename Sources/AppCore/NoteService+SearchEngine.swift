import Foundation

private struct PreparedEngineSearch {
  let scope: NoteSearchScope
  let hierarchyTagIds: [TagID]
  let classFilters: [SearchEngineTagClassFilter]
  let expansionTagIds: [TagID]
}

private struct PreparedRelatedSearch {
  let scope: NoteSearchScope
  let likeText: String
  let signals: SearchEngineRelatedSignals
}

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
    try await engineSearchNotesPage(
      query: query,
      notebookId: notebookId,
      tagFilter: tagFilter,
      expandOntology: true,
      includeFacets: false,
      limit: limit,
      offset: offset
    ).hits
  }

  /// Searches the engine with deterministic ontology filters, expansion and optional facets.
  func engineSearchNotesPage(
    query: String,
    notebookId: NotebookID? = nil,
    tagFilter: [String] = [],
    tagClassFilter: [String] = [],
    expandOntology: Bool = true,
    includeFacets: Bool = false,
    limit: Int = 20,
    offset: Int = 0
  ) async throws -> NoteEngineSearchPage {
    guard let engine = searchEngine else { throw SearchEngineError.notConfigured }
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedQuery.isEmpty else {
      throw NoteServiceError.invalidInput("query must not be empty")
    }
    guard limit > 0 else { return NoteEngineSearchPage(hits: [], facets: nil) }
    let requestedOffset = max(0, offset)

    let prepared = try driver.withDatabase { database -> PreparedEngineSearch? in
      let scope = try makeNoteSearchScope(notebookId: notebookId, in: database)
      guard scope.reachableLibraryIds != [] else { return nil }
      let hierarchyTagIds: [TagID]
      if tagFilter.isEmpty {
        hierarchyTagIds = []
      } else {
        guard let resolved = try resolveTagIds(named: tagFilter, in: database), !resolved.isEmpty else {
          return nil
        }
        hierarchyTagIds = resolved
      }
      guard let classFilters = try resolveTagClassFilters(tagClassFilter, in: database) else { return nil }
      let expansionTagIds = expandOntology
        ? try ontologyExpansionTagIds(query: trimmedQuery, in: database)
        : []
      return PreparedEngineSearch(
        scope: scope,
        hierarchyTagIds: hierarchyTagIds,
        classFilters: classFilters,
        expansionTagIds: expansionTagIds
      )
    }
    guard let prepared else {
      return NoteEngineSearchPage(hits: [], facets: nil)
    }

    let (sum, sumOverflow) = requestedOffset.addingReportingOverflow(limit)
    let (fetchSize, fetchOverflow) = (sumOverflow ? Int.max : sum).addingReportingOverflow(20)
    let enginePage = try await engine.searchPage(SearchEngineQuery(
      text: trimmedQuery,
      filter: searchEngineFilter(
        for: prepared.scope,
        tagIds: [],
        excludedNoteIds: [],
        hierarchyTagIds: prepared.hierarchyTagIds,
        tagClassFilters: prepared.classFilters
      ),
      from: 0,
      size: sumOverflow || fetchOverflow ? Int.max : fetchSize,
      expansionTagIds: prepared.expansionTagIds,
      facets: includeFacets ? SearchEngineFacetRequest() : nil
    ))

    return try driver.withDatabase { database in
      let hits = enginePage.hits
      let allowedIds = try scopedNoteIds(hits.map(\.noteId), scope: prepared.scope, in: database)
      var orderedHits: [SearchEngineHit] = []
      var seen = Set<NoteID>()
      for hit in hits where allowedIds.contains(hit.noteId) && seen.insert(hit.noteId).inserted {
        orderedHits.append(hit)
      }
      let page = Array(orderedHits.dropFirst(requestedOffset).prefix(limit))
      let notesById = try requireNotes(page.map(\.noteId), in: database)
      let searchTexts = try noteSearchTexts(Array(notesById.keys), in: database)
      let noteHits = page.compactMap { hit -> NoteEngineSearchHit? in
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
        return NoteEngineSearchHit(note: note, snippet: resultSnippet, score: hit.score, reasons: hit.reasons)
      }
      let facets = try enginePage.facets.map { try hydrateEngineFacets($0, in: database) }
      return NoteEngineSearchPage(hits: noteHits, facets: facets)
    }
  }

  /// Finds related notes for a readable source note, with store re-checks (design SE4).
  func relatedNotes(noteId: NoteID, limit: Int = 8) async throws -> [NoteEngineSearchHit] {
    guard let engine = searchEngine else { throw SearchEngineError.notConfigured }

    let prepared = try driver.withDatabase { database -> PreparedRelatedSearch? in
      let source = try requireNote(noteId, in: database)
      guard limit > 0 else { return nil }
      let scope = try makeNoteSearchScope(notebookId: nil, in: database)
      guard scope.reachableLibraryIds != [] else { return nil }
      let sourceText = noteRetrievalText(
        bodyMarkdown: source.bodyMarkdown,
        searchText: try noteSearchText(source.noteId, in: database)
      )
      let signals = try relatedSignals(forSourceNoteId: noteId, in: database)
      return PreparedRelatedSearch(
        scope: scope,
        likeText: (source.title ?? "") + "\n" + sourceText,
        signals: signals
      )
    }
    guard let prepared else { return [] }
    let likeText = String(prepared.likeText.prefix(4000))
    let (fetchSize, overflowed) = limit.addingReportingOverflow(20)
    let hits = try await engine.relatedNotes(SearchEngineRelatedQuery(
      likeText: likeText,
      filter: searchEngineFilter(for: prepared.scope, tagIds: [], excludedNoteIds: [noteId]),
      size: overflowed ? Int.max : fetchSize,
      signals: prepared.signals
    ))

    return try driver.withDatabase { database in
      let allowedIds = try scopedNoteIds(hits.map(\.noteId), scope: prepared.scope, in: database)
      var orderedHits: [SearchEngineHit] = []
      var seen = Set<NoteID>()
      for hit in hits where hit.noteId != noteId && allowedIds.contains(hit.noteId)
        && seen.insert(hit.noteId).inserted {
        orderedHits.append(hit)
      }
      let page = Array(orderedHits.prefix(limit))
      let enriched = try enrichRelatedReasons(
        page,
        sourceSharedTagIds: prepared.signals.sharedTagIds,
        in: database
      )
      let notesById = try requireNotes(enriched.map(\.noteId), in: database)
      let searchTexts = try noteSearchTexts(Array(notesById.keys), in: database)
      return enriched.compactMap { hit in
        guard let note = notesById[hit.noteId] else { return nil }
        let text = noteRetrievalText(bodyMarkdown: note.bodyMarkdown, searchText: searchTexts[note.noteId])
        let highlight = hit.highlight?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resultSnippet: String
        if let highlight, !highlight.isEmpty {
          resultSnippet = highlight
        } else {
          resultSnippet = snippet(from: text, query: "")
        }
        return NoteEngineSearchHit(note: note, snippet: resultSnippet, score: hit.score, reasons: hit.reasons)
      }
    }
  }
}
