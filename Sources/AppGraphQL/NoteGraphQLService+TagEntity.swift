import Foundation

import AppCore

/// The tag entity page's GraphQL facade
/// (`design-docs/specs/note-capture-and-entity-pages.md`, E6). Every rule the
/// surface enforces lives in `NoteService+TagDetail.swift`; this layer only
/// chooses the co-occurrence limit and shapes DTOs, so the GraphQL answer and
/// the CLI answer can never diverge.
public extension GraphQLNoteGraphQLService {
  /// Tag detail carrying the entity header (E1/E2/E4).
  ///
  /// `coOccurringTagLimit` is nil for "whatever the service considers a
  /// sensible header", which is `NoteService.defaultCoOccurringTagLimit` and
  /// costs exactly one aggregate. An explicit limit that differs re-runs the
  /// aggregate at the caller's size; the first result is discarded rather than
  /// reaching into the service's transaction, which keeps this layer free of
  /// its own reach rules. An explicit limit equal to the default is served by
  /// the first aggregate alone.
  func tagDetail(
    tagId: TagID,
    coOccurringTagLimit: Int?
  ) async -> GraphQLNoteQueryResult<GraphQLTagDetailDTO> {
    noteResult {
      var detail = try service.tagDetail(tagId: tagId)
      if let coOccurringTagLimit, coOccurringTagLimit != NoteService.defaultCoOccurringTagLimit {
        detail.coOccurringTags = try service.coOccurringTags(
          tagId: tagId,
          limit: coOccurringTagLimit
        )
      }
      return GraphQLTagDetailDTO(detail: detail)
    }
  }

  /// Designates a note as the tag's canonical description (E2).
  ///
  /// Reach asymmetry, stated here because this is where a client meets the
  /// operation: the read side (`tagDetail.canonicalNote`) and `unpromoteTagNote`
  /// are both reach-aware and treat a binding to an unreachable note as absent,
  /// while promotion is unconditional and can therefore replace a binding the
  /// caller was told did not exist. That is E2's last-promote-wins rule applied
  /// to a store-global tag table; it discloses nothing about the overwritten
  /// note. This resolver deliberately re-derives no rule of its own -- it
  /// returns exactly what `promoteTagCanonicalNote` decides.
  ///
  /// Promotion is not recorded as an undoable action (E2 asks for a change
  /// event, not an undo entry), so no action-history interaction happens here.
  func promoteTagNote(
    _ input: GraphQLPromoteTagNoteInput
  ) async -> GraphQLNoteMutationResult {
    noteMutation {
      let note = try service.promoteTagCanonicalNote(
        tagId: input.tagId,
        noteId: input.noteId
      )
      return .init(
        result: GraphQLControlPlaneResult(accepted: true, status: "ok"),
        note: GraphQLNoteDTO(note: note)
      )
    }
  }

  /// Clears the tag's canonical binding (E2). Unpromoting a tag that is not
  /// bound -- or whose binding points outside this principal's reach -- is a
  /// no-op success, so `note` is nil and no change event is published. Like
  /// promotion, this is not undoable.
  func unpromoteTagNote(
    _ input: GraphQLUnpromoteTagNoteInput
  ) async -> GraphQLNoteMutationResult {
    noteMutation {
      let note = try service.unpromoteTagCanonicalNote(tagId: input.tagId)
      return .init(
        result: GraphQLControlPlaneResult(accepted: true, status: "ok"),
        note: note.map(GraphQLNoteDTO.init)
      )
    }
  }
}
