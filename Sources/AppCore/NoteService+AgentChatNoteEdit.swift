import Foundation

/// Edit-mode agent chat (`design-docs/specs/ai-agent-integration.md`). The
/// agent has no tool channel back into kaiba, so an edit-mode reply carries
/// the complete replacement note body between sentinel lines and the server
/// applies it through `updateNoteBody` — the same guarded write path as
/// `kaiba edit`, portable across every provider adapter.

public extension NoteService {
  static let noteEditBodyOpening = "<kaiba-note-body>"
  static let noteEditBodyClosing = "</kaiba-note-body>"

  static var noteEditSystemPrompt: String {
    """
    You are an editing assistant for a note-taking system. The document \
    provided as context is the current body of the user's note, and the \
    user's message asks you to change it. Reply with the complete revised \
    note body in markdown, wrapped between a line containing only \
    \(noteEditBodyOpening) and a line containing only \(noteEditBodyClosing). \
    Preserve everything the user did not ask to change. Text after the \
    closing line is shown to the user as a short summary of the change. \
    When the request is unclear, or no change is needed, reply in plain \
    markdown without those markers and the note is left untouched.
    """
  }

  /// Splits an edit-mode reply into the replacement body (between the
  /// sentinels) and the commentary around it. A reply without a usable body
  /// returns nil so the caller can fall back to a plain chat answer — the
  /// agent declining or asking a clarifying question must never blank a note.
  static func noteEditReply(
    from markdown: String
  ) -> (bodyMarkdown: String?, commentary: String) {
    guard let opening = markdown.range(of: noteEditBodyOpening),
      let closing = markdown.range(of: noteEditBodyClosing, range: opening.upperBound..<markdown.endIndex)
    else {
      return (nil, markdown)
    }
    let body = String(markdown[opening.upperBound..<closing.lowerBound])
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let commentary = (String(markdown[..<opening.lowerBound]) + "\n"
      + String(markdown[closing.upperBound...]))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else {
      return (nil, markdown)
    }
    return (body, commentary)
  }

  /// Applies an edit-mode reply to the subject note and returns the assistant
  /// markdown to persist on the turn, plus whether the note was rewritten.
  /// Throws when the note refuses the write (for example, it was locked after
  /// the turn was accepted).
  internal func applyNoteEditReply(
    _ markdown: String,
    subjectNoteId: NoteID,
    originatingActionId: AutoActionID?
  ) throws -> (assistantMarkdown: String, updatedNote: Bool) {
    let parsed = Self.noteEditReply(from: markdown)
    guard let bodyMarkdown = parsed.bodyMarkdown else {
      return (markdown, false)
    }
    _ = try updateNoteBody(
      noteId: subjectNoteId,
      bodyMarkdown: bodyMarkdown,
      provenance: .ai,
      originatingActionId: originatingActionId
    )
    return (parsed.commentary.isEmpty ? "Updated the note." : parsed.commentary, true)
  }
}
