import Foundation

import AppCore
import XCTest
@testable import AppGraphQL

final class NoteGraphQLControlPlaneSecurityTests: XCTestCase {
  func testScopedNonAdminCannotReadOrMutateGlobalAutoActions() async throws {
    let base = try makeService()
    let alice = try base.service.createUser(email: "alice@example.com", displayName: "Alice")
    let bob = try base.service.createUser(email: "bob@example.com", displayName: "Bob")
    let aliceGraphQL = GraphQLNoteGraphQLService(service: base.service.scoped(to: alice.userId))
    let actionId = AutoActionID("alice-cross-user-action")

    let listed = await aliceGraphQL.autoActions()
    XCTAssertFalse(listed.result.accepted)
    XCTAssertEqual(listed.result.status, "not_found")

    let configured = await aliceGraphQL.configureAutoAction(
      actionId: actionId,
      trigger: "note-created",
      workflowId: WorkflowID("note-auto-tagging")
    )
    XCTAssertFalse(configured.result.accepted)
    XCTAssertEqual(configured.result.status, "not_found")

    let deleted = await aliceGraphQL.deleteAutoAction(
      actionId: AutoActionID("default-ai-tagging-note-created")
    )
    XCTAssertFalse(deleted.accepted)
    XCTAssertEqual(deleted.status, "not_found")
    XCTAssertTrue(
      try base.service.listAutoActions().contains {
        $0.actionId == AutoActionID("default-ai-tagging-note-created")
      }
    )

    _ = try base.service.scoped(to: bob.userId).createNote(bodyMarkdown: "# Bob\nPrivate")
    XCTAssertFalse(
      try base.service.listAutoActionDispatchAttempts().contains { $0.record.action.actionId == actionId }
    )
  }

  func testGraphQLForeignProtectedTagRemovalsReturnNotFound() async throws {
    let base = try makeService()
    let alice = try base.service.createUser(email: "tag-owner@example.com", displayName: "Owner")
    let bob = try base.service.createUser(email: "tag-outsider@example.com", displayName: "Outsider")
    let owner = base.service.scoped(to: alice.userId)
    let outsiderGraphQL = GraphQLNoteGraphQLService(service: base.service.scoped(to: bob.userId))
    let note = try owner.createNote(bodyMarkdown: "# Private\nTag source")
    let notebook = try owner.createNotebook(title: "Private tags")
    let noteTag = "private-human-note-tag"
    let notebookTag = try base.service.defineTag(name: "private-human-notebook-tag")
    try owner.applyTags(
      noteId: note.noteId,
      tags: [NoteTagInput(name: noteTag)],
      provenance: .human
    )
    try owner.applyNotebookTagIds(
      notebookId: notebook.notebookId,
      tagIds: [notebookTag.tagId],
      provenance: .human
    )

    let noteRemoval = await outsiderGraphQL.removeTag(
      noteId: note.noteId,
      tagName: noteTag,
      provenance: NoteProvenance.ai.rawValue
    )
    XCTAssertFalse(noteRemoval.result.accepted)
    XCTAssertEqual(noteRemoval.result.status, "not_found")

    let notebookNameRemoval = await outsiderGraphQL.removeNotebookTag(
      notebookId: notebook.notebookId,
      tagName: notebookTag.name,
      provenance: NoteProvenance.ai.rawValue
    )
    XCTAssertFalse(notebookNameRemoval.result.accepted)
    XCTAssertEqual(notebookNameRemoval.result.status, "not_found")

    let notebookIdRemoval = await outsiderGraphQL.removeNotebookTagById(
      notebookId: notebook.notebookId,
      tagId: notebookTag.tagId,
      provenance: NoteProvenance.ai.rawValue
    )
    XCTAssertFalse(notebookIdRemoval.result.accepted)
    XCTAssertEqual(notebookIdRemoval.result.status, "not_found")
  }

  private func makeService(function: String = #function) throws -> GraphQLNoteGraphQLService {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/AppGraphQLTests", isDirectory: true)
      .appendingPathComponent(function.replacingOccurrences(of: "()", with: ""), isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return try GraphQLNoteGraphQLService(
      service: NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
    )
  }
}
