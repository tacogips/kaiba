import Foundation

/// Agentic search: the configured agent answers a search question over the
/// note store. The agent receives two things it can work with:
///
/// 1. The `kaiba` CLI usage for search (`kaibaSearchCommandUsage`), so an
///    agent runtime that can execute shell commands (claude-code, codex,
///    cursor vendors) runs its own `kaiba search` / `kaiba show` calls to
///    grep notes and memos iteratively.
/// 2. A precomputed grep pass over notes and memos for the raw query, so a
///    text-only vendor (openrouter, openai, ...) still grounds its answer in
///    real store content.
///
/// The reply is markdown; the prompt demands one `noteId`/`notebookId` per
/// finding so the web UI and CLI can link results.
public struct AIAgenticSearchService: Sendable {
  public var service: NoteService
  public var invoker: any AgentInvoking
  public var provider: String?
  public var model: String?

  public init(
    service: NoteService,
    invoker: any AgentInvoking,
    provider: String? = nil,
    model: String? = nil
  ) {
    self.service = service
    self.invoker = invoker
    self.provider = provider
    self.model = model
  }

  public struct Result: Equatable, Sendable {
    public var answerMarkdown: String

    public init(answerMarkdown: String) {
      self.answerMarkdown = answerMarkdown
    }
  }

  /// The kaiba command usage handed to the agent so it can search the store
  /// itself when its runtime can execute commands.
  public static let kaibaSearchCommandUsage = """
    You can search the kaiba note store with the `kaiba` CLI:

      kaiba search "<query>" [--notebook <notebook-id>] [--memos] \
    [--tag <name>] [--limit N] [--output json]
          Full-text (grep) search over note titles, bodies and tag names.
          --notebook scopes the search to one notebook.
          --memos also greps memo (comment) text, including notebook-level
          memos; memo matches show which note or notebook they belong to.
      kaiba show <note-id> [--output json]
          Read one note's full markdown.
      kaiba list [--notebook <notebook-id>] [--limit N]
          List notes (optionally of one notebook).
      kaiba notebook list [--limit N]
          List notebooks.
      kaiba notebook show <notebook-id>
          Read one notebook's metadata.

    Run several searches with different terms (synonyms, related words,
    partial words) when the first pass finds nothing.
    """

  static func searchSystemPrompt(notebookId: NotebookID?) -> String {
    let scope = notebookId.map { "Scope every search to notebook \($0)." }
      ?? "Search across all notebooks."
    return """
      You are the search assistant of a kaiba note store. Answer the user's \
      search question by finding the most relevant notes and memos. \(scope)

      \(kaibaSearchCommandUsage)

      If your runtime cannot execute commands, use the pre-computed search \
      results provided in the context document instead.

      Reply in markdown. For every finding include the note id (or notebook \
      id) on its own line in the form `- noteId: <id> — <title>` followed by \
      a one-or-two sentence explanation of why it matches. Only use ids that \
      literally appear in the pre-computed results or in kaiba CLI output you \
      ran yourself — never invent or abbreviate ids. When neither source \
      yields a match, say plainly that nothing matched.
      """
  }

  public func search(
    query: String,
    notebookId: NotebookID? = nil,
    limit: Int = 20
  ) async throws -> Result {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw NoteServiceError.invalidInput("search query must not be empty")
    }
    // The grep pass runs the full query plus its content-bearing terms: a
    // question like "which note mentions pepper?" matches nothing verbatim,
    // but "pepper" does.
    var noteMatches: [NoteSearchResult] = []
    var seenNoteIds = Set<NoteID>()
    var memoMatches: [NoteComment] = []
    var seenCommentIds = Set<CommentID>()
    for term in Self.grepTerms(from: trimmed) {
      for match in try service.searchNotes(query: term, notebookId: notebookId, limit: limit)
      where seenNoteIds.insert(match.note.noteId).inserted {
        noteMatches.append(match)
      }
      for memo in try service.searchComments(query: term, notebookId: notebookId, limit: 50)
      where seenCommentIds.insert(memo.commentId).inserted {
        memoMatches.append(memo)
      }
      if noteMatches.count >= limit {
        break
      }
    }
    noteMatches = Array(noteMatches.prefix(limit))
    let request = AgentInvocationRequest(
      purpose: .search,
      systemPrompt: Self.searchSystemPrompt(notebookId: notebookId),
      turns: [AgentInvocationTurn(role: .user, markdown: trimmed)],
      contextMarkdown: Self.grepContextMarkdown(
        query: trimmed,
        noteMatches: noteMatches,
        memoMatches: memoMatches
      ),
      provider: provider,
      model: model
    )
    let reply = try await invoker.invoke(request)
    return Result(answerMarkdown: reply.markdown)
  }

  /// The full query followed by its content-bearing words (question words and
  /// other glue dropped), capped so the grounding pass stays cheap.
  static func grepTerms(from query: String, maximumTerms: Int = 6) -> [String] {
    var terms = [query]
    let words = query
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { $0.count >= 2 }
    for word in words where terms.count < maximumTerms {
      let lowered = word.lowercased()
      guard !Self.grepStopwords.contains(lowered), !terms.contains(where: { $0.lowercased() == lowered }) else {
        continue
      }
      terms.append(word)
    }
    return terms
  }

  static let grepStopwords: Set<String> = [
    "the", "a", "an", "of", "in", "on", "at", "to", "for", "and", "or", "not",
    "is", "are", "was", "were", "be", "been", "do", "does", "did", "can",
    "which", "what", "who", "whom", "when", "where", "how", "why", "that",
    "this", "these", "those", "it", "its", "my", "our", "your", "their",
    "note", "notes", "notebook", "notebooks", "memo", "memos",
    "mention", "mentions", "mentioned", "about", "with", "have", "has"
  ]

  /// The precomputed grep pass, rendered as the agent's context document.
  static func grepContextMarkdown(
    query: String,
    noteMatches: [NoteSearchResult],
    memoMatches: [NoteComment]
  ) -> String {
    var sections = ["# Pre-computed grep results for: \(query)"]
    if noteMatches.isEmpty && memoMatches.isEmpty {
      sections.append("No direct matches. Try other terms with the kaiba CLI if you can run commands.")
    }
    if !noteMatches.isEmpty {
      let lines = noteMatches.map { match in
        "- noteId: \(match.note.noteId) (notebook \(match.note.notebookId)) — "
          + "\(match.note.title ?? "(untitled)")\n  \(match.snippet)"
      }
      sections.append("## Note matches\n\(lines.joined(separator: "\n"))")
    }
    if !memoMatches.isEmpty {
      let lines = memoMatches.map { memo in
        let anchor = memo.noteId.map { "noteId: \($0)" }
          ?? memo.notebookId.map { "notebookId: \($0)" }
          ?? "unanchored"
        let body = memo.bodyMarkdown.replacingOccurrences(of: "\n", with: " ")
        return "- memo \(memo.commentId) (\(anchor)) — \(String(body.prefix(300)))"
      }
      sections.append("## Memo matches\n\(lines.joined(separator: "\n"))")
    }
    return sections.joined(separator: "\n\n")
  }
}
