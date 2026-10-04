import Foundation

public extension NoteService {
  func searchNotes(
    query: String,
    tagFilter: [String] = [],
    classFilter: [String] = [],
    notebookId: NotebookID? = nil,
    sort: NoteListSort = .createdAtDesc,
    createdAfter: String? = nil,
    createdBefore: String? = nil,
    includeLinked: Bool = false,
    depth: Int = 1,
    limit: Int = 20,
    offset: Int = 0
  ) throws -> [NoteSearchResult] {
    try driver.withDatabase { database in
      try searchNotesInDatabase(
        query: query,
        tagFilter: tagFilter,
        classFilter: classFilter,
        // The library scope is applied inside the query rather than to its
        // results: filtering a page after the fact would hand back fewer hits
        // than the caller asked for (`design-docs/specs/library.md`).
        scope: try makeNoteSearchScope(
          notebookId: notebookId,
          createdAfter: createdAfter,
          createdBefore: createdBefore,
          in: database
        ),
        sort: sort,
        graphOptions: NoteSearchGraphOptions(includeLinked: includeLinked, depth: depth),
        limit: limit,
        offset: offset,
        in: database
      )
    }
  }

  internal func makeNoteSearchScope(
    notebookId: NotebookID?,
    createdAfter: String? = nil,
    createdBefore: String? = nil,
    in database: SQLiteDatabase
  ) throws -> NoteSearchScope {
    NoteSearchScope(
      notebookId: notebookId,
      reachableLibraryIds: try reachableLibraryIds(in: database),
      actingUserId: actingUserId,
      excludesLongTermMemory: actingUserId != nil || isUnauthenticatedPrincipal,
      excludesPendingNotebookIngests: !allowsPendingNotebookIngestAccess,
      createdAfter: createdAfter,
      createdBefore: createdBefore
    )
  }
}
