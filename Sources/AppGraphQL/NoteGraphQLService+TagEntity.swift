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
  /// sensible header", which is `NoteService.defaultCoOccurringTagLimit`. Every
  /// limit -- default or not -- is handed to the service read itself, so the
  /// aggregate costs exactly one query at whatever size was asked for. This
  /// layer never takes a default payload, throws its chips away and re-runs the
  /// aggregate, and it still reaches into none of the service's own rules:
  /// choosing the limit is the whole of its job here.
  func tagDetail(
    tagId: TagID,
    coOccurringTagLimit: Int?
  ) async -> GraphQLNoteQueryResult<GraphQLTagDetailDTO> {
    noteResult {
      GraphQLTagDetailDTO(detail: try service.tagDetail(
        tagId: tagId,
        coOccurringTagLimit: coOccurringTagLimit ?? NoteService.defaultCoOccurringTagLimit
      ))
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
