import Foundation

public extension NoteService {
  func searchNotes(
    query: String,
    tagFilter: [String] = [],
    classFilter: [String] = [],
    notebookId: String? = nil,
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
        notebookId: notebookId,
        sort: sort,
        createdAfter: createdAfter,
        createdBefore: createdBefore,
        graphOptions: NoteSearchGraphOptions(includeLinked: includeLinked, depth: depth),
        limit: limit,
        offset: offset,
        in: database
      )
    }
  }
}
