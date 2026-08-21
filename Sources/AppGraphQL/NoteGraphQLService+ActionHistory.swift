import Foundation

import AppCore

// GraphQL surface of the action history and undo/redo
// (`design-docs/specs/action-history-undo.md`): `actionHistory` and
// `undoState` queries, `undoAction` and `redoAction` mutations.

public struct GraphQLActionLogEntryDTO: Codable, Equatable, Sendable {
  public var seq: Int64
  public var occurredAt: String
  public var actorUserId: String
  public var provenance: String
  public var entityType: String
  public var entityId: String
  public var notebookId: String?
  public var action: String
  /// The display title recorded with the entry, so history can name entities
  /// that no longer exist. Deltas stay server-side.
  public var title: String?
  public var undoable: Bool
  public var undoOfSeq: Int64?
  public var undoneBySeq: Int64?

  init(entry: NoteActionLogEntry) {
    self.seq = entry.seq
    self.occurredAt = entry.occurredAt
    self.actorUserId = entry.actorUserId.rawValue
    self.provenance = entry.provenance.rawValue
    self.entityType = entry.entityType.rawValue
    self.entityId = entry.entityId
    self.notebookId = entry.notebookId?.rawValue
    self.action = entry.action
    self.title = entry.display["title"]?.asString
    self.undoable = entry.undoable
    self.undoOfSeq = entry.undoOfSeq
    self.undoneBySeq = entry.undoneBySeq
  }
}

public struct GraphQLActionHistoryResult: Codable, Equatable, Sendable {
  public var result: GraphQLControlPlaneResult
  public var entries: [GraphQLActionLogEntryDTO]

  public init(result: GraphQLControlPlaneResult, entries: [GraphQLActionLogEntryDTO] = []) {
    self.result = result
    self.entries = entries
  }
}

public struct GraphQLUndoStateResult: Codable, Equatable, Sendable {
  public var result: GraphQLControlPlaneResult
  public var undo: GraphQLActionLogEntryDTO?
  public var redo: GraphQLActionLogEntryDTO?

  public init(
    result: GraphQLControlPlaneResult,
    undo: GraphQLActionLogEntryDTO? = nil,
    redo: GraphQLActionLogEntryDTO? = nil
  ) {
    self.result = result
    self.undo = undo
    self.redo = redo
  }
}

public struct GraphQLUndoRedoResult: Codable, Equatable, Sendable {
  public var result: GraphQLControlPlaneResult
  /// "ok", or "nothing-to-undo" / "nothing-to-redo" when the log offered no
  /// target — an empty answer, not an error.
  public var status: String
  /// The appended `undone`/`redone` entry.
  public var applied: GraphQLActionLogEntryDTO?
  /// The entry that was undone or redone.
  public var target: GraphQLActionLogEntryDTO?

  public init(
    result: GraphQLControlPlaneResult,
    status: String,
    applied: GraphQLActionLogEntryDTO? = nil,
    target: GraphQLActionLogEntryDTO? = nil
  ) {
    self.result = result
    self.status = status
    self.applied = applied
    self.target = target
  }
}

extension GraphQLNoteGraphQLService {
  public func actionHistory(limit: Int = 50, beforeSeq: Int64? = nil) async -> GraphQLActionHistoryResult {
    do {
      let entries = try service.actionHistory(limit: limit, beforeSeq: beforeSeq)
      return GraphQLActionHistoryResult(
        result: GraphQLControlPlaneResult(accepted: true, status: "ok"),
        entries: entries.map(GraphQLActionLogEntryDTO.init)
      )
    } catch {
      return GraphQLActionHistoryResult(result: graphQLNoteResult(for: error))
    }
  }

  public func undoState() async -> GraphQLUndoStateResult {
    do {
      let state = try service.undoState()
      return GraphQLUndoStateResult(
        result: GraphQLControlPlaneResult(accepted: true, status: "ok"),
        undo: state.undoTarget.map(GraphQLActionLogEntryDTO.init),
        redo: state.redoTarget.map(GraphQLActionLogEntryDTO.init)
      )
    } catch {
      return GraphQLUndoStateResult(result: graphQLNoteResult(for: error))
    }
  }

  public func undoAction() async -> GraphQLUndoRedoResult {
    do {
      guard let outcome = try service.undoLastAction() else {
        return GraphQLUndoRedoResult(result: GraphQLControlPlaneResult(accepted: true, status: "ok"), status: "nothing-to-undo")
      }
      return GraphQLUndoRedoResult(
        result: GraphQLControlPlaneResult(accepted: true, status: "ok"),
        status: "ok",
        applied: GraphQLActionLogEntryDTO(entry: outcome.entry),
        target: GraphQLActionLogEntryDTO(entry: outcome.target)
      )
    } catch {
      return GraphQLUndoRedoResult(result: graphQLNoteResult(for: error), status: "failed")
    }
  }

  public func redoAction() async -> GraphQLUndoRedoResult {
    do {
      guard let outcome = try service.redoLastAction() else {
        return GraphQLUndoRedoResult(result: GraphQLControlPlaneResult(accepted: true, status: "ok"), status: "nothing-to-redo")
      }
      return GraphQLUndoRedoResult(
        result: GraphQLControlPlaneResult(accepted: true, status: "ok"),
        status: "ok",
        applied: GraphQLActionLogEntryDTO(entry: outcome.entry),
        target: GraphQLActionLogEntryDTO(entry: outcome.target)
      )
    } catch {
      return GraphQLUndoRedoResult(result: graphQLNoteResult(for: error), status: "failed")
    }
  }
}
