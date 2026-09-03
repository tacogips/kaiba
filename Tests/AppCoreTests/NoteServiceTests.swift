import Foundation
import AppCore
import XCTest

final class NoteServiceTests: NoteTestCase {
  func testCreateNotebookFolderPathUsesParentScopedIdentityAndRejectsUnsafePathsAtomically() throws {
    let service = try makeService()
    let initialNotebookCount = try service.listNotebooks().count

    let notebook = try service.createNotebook(
      title: "Assistant run",
      folderPath: ["workflow", "2026-08-03"]
    )
    let tags = try service.listTags()
    let workflow = try XCTUnwrap(tags.first { $0.name == "workflow" })
    let date = try XCTUnwrap(tags.first { $0.name == "2026-08-03" })
    XCTAssertEqual(workflow.classId, TagClassID("folder"))
    XCTAssertEqual(date.classId, TagClassID("folder"))
    XCTAssertEqual(date.parentTagId, workflow.tagId)
    XCTAssertEqual(try service.getNotebook(notebook.notebookId).tags.map(\.tag.name), ["2026-08-03"])

    for unsafePath in [["."], [".."], ["workflow/child"], ["workflow\\child"]] {
      XCTAssertThrowsError(try service.createNotebook(title: "Unsafe", folderPath: unsafePath))
    }
    XCTAssertEqual(
      try service.listNotebooks().count,
      initialNotebookCount + 1,
      "invalid paths must roll back the new notebook"
    )

    let firstHistory = try service.createNotebook(
      title: "Build history",
      folderPath: ["build", "history-2026-08-03"]
    )
    let repeatedHistory = try service.createNotebook(
      title: "Build history repeated",
      folderPath: ["build", "history-2026-08-03"]
    )
    let otherHistory = try service.createNotebook(
      title: "Deploy history",
      folderPath: ["deploy", "history-2026-08-03"]
    )
    let firstLeaf = try XCTUnwrap(firstHistory.tags.first?.tag)
    XCTAssertEqual(repeatedHistory.tags.first?.tag.tagId, firstLeaf.tagId)
    XCTAssertNotEqual(otherHistory.tags.first?.tag.tagId, firstLeaf.tagId)

    _ = try service.defineTag(name: "shared", classId: TagClassID("topic"))
    let sameNamedFolder = try service.defineTag(name: "shared", classId: TagClassID("folder"), createOnly: true)
    XCTAssertEqual(sameNamedFolder.classId, TagClassID("folder"))
    XCTAssertThrowsError(try service.applyNotebookTags(
      notebookId: notebook.notebookId,
      tags: ["shared"],
      provenance: .human
    )) { error in
      guard case let .invalidInput(message)? = error as? NoteServiceError else {
        return XCTFail("expected ambiguous name lookup, got \(error)")
      }
      XCTAssertTrue(message.contains("ambiguous"))
    }
    XCTAssertThrowsError(
      try service.defineTag(name: "shared", classId: TagClassID("folder"), createOnly: true)
    )

    let idTagged = try service.applyNotebookTagIds(
      notebookId: notebook.notebookId,
      tagIds: [otherHistory.tags[0].tag.tagId],
      provenance: .human
    )
    XCTAssertTrue(idTagged.tags.contains { $0.tag.tagId == otherHistory.tags[0].tag.tagId })
    XCTAssertEqual(
      Set(try service.listNotebooks(tagFilterIdGroups: [[otherHistory.tags[0].tag.tagId]])
        .map(\.notebookId)),
      Set([notebook.notebookId, otherHistory.notebookId])
    )
    let idRemoved = try service.removeNotebookTagById(
      notebookId: notebook.notebookId,
      tagId: otherHistory.tags[0].tag.tagId,
      removedBy: .human
    )
    XCTAssertFalse(idRemoved.tags.contains { $0.tag.tagId == otherHistory.tags[0].tag.tagId })
  }

  func testConcurrentFolderPathCreationReusesOnlyTheExactSibling() throws {
    let service = try makeService()
    let results = ConcurrentFolderPathResults()

    DispatchQueue.concurrentPerform(iterations: 16) { index in
      do {
        let notebook = try service.createNotebook(
          title: "Concurrent \(index)",
          folderPath: ["concurrent-workflow", "history-2026-08-03"]
        )
        if let tagId = notebook.tags.first?.tag.tagId {
          results.record(tagId: tagId)
        }
      } catch {
        results.record(error: error)
      }
    }

    XCTAssertTrue(results.errors.isEmpty, results.errors.joined(separator: "\n"))
    XCTAssertEqual(Set(results.tagIds).count, 1)
    XCTAssertEqual(results.tagIds.count, 16)
    let tags = try service.listTags()
    let parent = try XCTUnwrap(tags.first { $0.name == "concurrent-workflow" })
    XCTAssertEqual(
      tags.filter {
        $0.name == "history-2026-08-03" && $0.parentTagId == parent.tagId
      }.count,
      1
    )
  }

  func testNotebookKindCreationIgnoresSameNamedFolderAcrossCreationPaths() throws {
    let service = try makeService()
    let kindName = "notebook-kind:shared-display"
    let folderNotebook = try service.createNotebook(
      title: "Folder only",
      folderPath: [kindName]
    )
    let folder = try XCTUnwrap(folderNotebook.tags.first?.tag)
    XCTAssertEqual(folder.classId, TagClassID("folder"))

    let created = try service.createNotebook(title: "Created", kindTagName: kindName)
    let note = try service.createNote(
      notebookKindTagName: kindName,
      bodyMarkdown: "# Created with note"
    )
    let ingested = try service.createNotebookWithNotes(
      title: "Ingested",
      kindTagName: kindName,
      pages: [NotePageDraft(bodyMarkdown: "# Page")]
    )

    let kind = try XCTUnwrap(try service.listTags().first {
      $0.name == kindName && $0.classId == TagClassID("document-kind")
    })
    XCTAssertNotEqual(kind.tagId, folder.tagId)
    for notebook in [created, try service.getNotebook(note.notebookId), ingested.notebook] {
      XCTAssertTrue(notebook.tags.contains { $0.tag.tagId == kind.tagId })
      XCTAssertFalse(notebook.tags.contains { $0.tag.tagId == folder.tagId })
    }
  }

  func testCreateNoteDerivesTitleAndListShowsFirstNotePreview() throws {
    let service = try makeService()

    let note = try service.createNote(
      bodyMarkdown: """
      # Design Notes

      First paragraph of the note body.
      """,
      tags: [NoteTagInput(name: "ノート", classId: TagClassID("document-kind"))]
    )

    XCTAssertEqual(note.title, "Design Notes")
    XCTAssertEqual(note.noteNumber, 1)
    XCTAssertEqual(note.tags.map(\.tag.name), ["ノート"])

    let notebooks = try service.listNotebooks().filter { $0.notebookId == note.notebookId }
    XCTAssertEqual(notebooks.count, 1)
    XCTAssertEqual(notebooks.first?.title, "Design Notes")
    XCTAssertEqual(notebooks.first?.firstNotePreview?.contains("First paragraph"), true)
  }

  func testCreateNoteCanUseExplicitTitleWithoutRewritingBody() throws {
    let service = try makeService()

    let note = try service.createNote(title: "Explicit Title", bodyMarkdown: "Body without a heading")

    XCTAssertEqual(note.title, "Explicit Title")
    XCTAssertEqual(note.bodyMarkdown, "Body without a heading")
    XCTAssertEqual(
      try service.listNotebooks().first { $0.notebookId == note.notebookId }?.title,
      "Explicit Title"
    )
  }

  func testUpdateNoteBodyReDerivesDerivedTitleButPreservesExplicitTitle() throws {
    let service = try makeService()

    // A derived title (no explicit title on create) re-derives from the new body.
    let derived = try service.createNote(bodyMarkdown: "# Original Heading\nBody")
    XCTAssertEqual(derived.title, "Original Heading")
    let derivedUpdated = try service.updateNoteBody(
      noteId: derived.noteId,
      bodyMarkdown: "Changed body without a heading"
    )
    XCTAssertEqual(derivedUpdated.title, "Changed body without a heading")
    XCTAssertEqual(derivedUpdated.bodyMarkdown, "Changed body without a heading")

    // An explicit title survives body edits and is never clobbered.
    let explicit = try service.createNote(title: "Explicit Title", bodyMarkdown: "Body without a heading")
    let explicitUpdated = try service.updateNoteBody(
      noteId: explicit.noteId,
      bodyMarkdown: "# A New Heading In The Body\nMore body"
    )
    XCTAssertEqual(explicitUpdated.title, "Explicit Title")
    XCTAssertEqual(explicitUpdated.bodyMarkdown, "# A New Heading In The Body\nMore body")
  }

  func testGenericListNotesNotebookFilterMatchesNotebookScopedOrder() throws {
    let service = try makeService()
    let ingest = try service.createNotebookWithNotes(
      title: "Ordered",
      pages: (1...4).map { NotePageDraft(bodyMarkdown: "# Page \($0)\nbody \($0)", noteNumber: 5 - $0) }
    )
    // Explicit descending note numbers: page bodies "Page 1".."Page 4" carry
    // note_number 4,3,2,1. The generic overload with a notebook filter must sort
    // by note_number ascending regardless of insertion/creation order.
    let generic = try service.listNotes(limit: 100, offset: 0, notebookId: ingest.notebook.notebookId)
    XCTAssertEqual(generic.map(\.noteNumber), [1, 2, 3, 4])
    XCTAssertEqual(generic.map(\.title), ["Page 4", "Page 3", "Page 2", "Page 1"])
  }

  func testIngestRejectsImplicitExplicitPageNumberCollision() throws {
    let service = try makeService()
    // Page 1 is positional (effective number 1); page 2 explicitly claims 1.
    XCTAssertThrowsError(
      try service.createNotebookWithNotes(
        title: "Colliding",
        pages: [
          NotePageDraft(bodyMarkdown: "# First\nbody"),
          NotePageDraft(bodyMarkdown: "# Second\nbody", noteNumber: 1)
        ]
      )
    ) { error in
      guard case let NoteServiceError.invalidInput(message) = error else {
        return XCTFail("expected invalidInput, got \(error)")
      }
      XCTAssertTrue(message.contains("1"), "message should name colliding page number: \(message)")
      XCTAssertTrue(message.contains("2"), "message should name colliding page position: \(message)")
    }
  }

  func testSymbolOnlyQueryMatchesViaLikeFallback() throws {
    let service = try makeService()
    _ = try service.createNote(bodyMarkdown: "# Arrow Note\nThe flow is A → B and then C")
    _ = try service.createNote(bodyMarkdown: "# Unrelated\nNothing special here")

    let results = try service.searchNotes(query: "→")
    XCTAssertEqual(results.map(\.note.title), ["Arrow Note"])
  }

  func testTitleDerivationSupportsHeadingLevelsFirstLineMarkersAndCap() throws {
    let service = try makeService()
    let h3 = try service.createNote(bodyMarkdown: "### Deep Heading\nBody")
    let list = try service.createNote(bodyMarkdown: "- List marker title\nBody")
    let longLine = String(repeating: "a", count: NoteTitleDerivation.fallbackTitleLimit + 10)
    let capped = try service.createNote(bodyMarkdown: "\(longLine)\nBody")
    let empty = try service.createNote(notebookTitle: "Fallback Notebook", bodyMarkdown: " \n ")

    XCTAssertEqual(h3.title, "Deep Heading")
    XCTAssertEqual(list.title, "List marker title")
    XCTAssertEqual(capped.title, String(longLine.prefix(NoteTitleDerivation.fallbackTitleLimit)))
    XCTAssertNil(empty.title)
    XCTAssertEqual(try service.getNotebook(empty.notebookId).title, "Fallback Notebook")
  }

  func testTitleDerivationSkipsFencesIndentedCodeAndPreservesInlineMarkup() throws {
    XCTAssertEqual(
      NoteTitleDerivation.title(from: "intro\n```bash\n# install deps\n```\n# Real Title"),
      "Real Title"
    )
    XCTAssertEqual(NoteTitleDerivation.title(from: "    # indented code\nActual title"), "Actual title")
    XCTAssertEqual(NoteTitleDerivation.title(from: "# Title ##\nBody"), "Title")
    XCTAssertEqual(NoteTitleDerivation.title(from: "**Bold** first line\nBody"), "**Bold** first line")
    XCTAssertEqual(NoteTitleDerivation.title(from: "[Link](https://example.test)\nBody"), "[Link](https://example.test)")
    XCTAssertEqual(NoteTitleDerivation.title(from: "```swift\nlet title = 1\n```\n日本語のタイトル"), "日本語のタイトル")
    XCTAssertEqual(NoteTitleDerivation.title(from: "### 見出し ##\r\nBody"), "見出し")
  }

  func testNoteTimestampsUseFractionalISO8601() throws {
    let service = try makeService()

    let note = try service.createNote(bodyMarkdown: "# Timestamped\nBody")
    let updated = try service.updateNoteBody(noteId: note.noteId, bodyMarkdown: "# Timestamped\nChanged")

    XCTAssertFractionalISO8601(note.createdAt)
    XCTAssertFractionalISO8601(note.updatedAt)
    XCTAssertFractionalISO8601(updated.updatedAt)
  }

  func testReadOnlyBlocksBodyEditAndDeleteButAllowsCommentsAndTags() throws {
    let service = try makeService()
    let note = try service.createNote(bodyMarkdown: "# Locked\nBody", readOnly: true)

    XCTAssertThrowsError(try service.updateNoteBody(noteId: note.noteId, bodyMarkdown: "# Changed"))
    XCTAssertThrowsError(try service.deleteNote(noteId: note.noteId))

    let comment = try service.addComment(noteId: note.noteId, bodyMarkdown: "Still commentable")
    XCTAssertEqual(comment.bodyMarkdown, "Still commentable")

    let tagged = try service.applyTags(
      noteId: note.noteId,
      tags: [NoteTagInput(name: "reviewed", classId: TagClassID("topic"))],
      provenance: .human
    )
    XCTAssertEqual(tagged.tags.map(\.tag.name), ["reviewed"])
  }

  func testAITagsCannotOverwriteOrRemoveHumanTags() throws {
    let service = try makeService()
    let note = try service.createNote(
      bodyMarkdown: "# Tagged\nBody",
      tags: [NoteTagInput(name: "strategy", classId: TagClassID("topic"))],
      provenance: .human,
      assignedBy: "user"
    )

    let afterAIApply = try service.applyTags(
      noteId: note.noteId,
      tags: [NoteTagInput(name: "strategy", classId: TagClassID("event"))],
      provenance: .ai,
      assignedBy: "workflow-session"
    )
    let assignment = try XCTUnwrap(afterAIApply.tags.first)
    XCTAssertEqual(assignment.provenance, .human)
    XCTAssertEqual(assignment.assignedBy, "user")
    XCTAssertEqual(assignment.tag.classId, TagClassID("topic"))

    XCTAssertThrowsError(try service.removeTag(noteId: note.noteId, tagName: "strategy", removedBy: .ai))
    XCTAssertNoThrow(try service.removeTag(noteId: note.noteId, tagName: "strategy", removedBy: .human))
    XCTAssertTrue(try service.getNote(note.noteId).tags.isEmpty)
  }

  func testSearchReflectsCreateUpdateTagsAndDelete() throws {
    let service = try makeService()
    let note = try service.createNote(
      bodyMarkdown: "# Searchable\nAlpha beta knowledge",
      tags: [NoteTagInput(name: "research", classId: TagClassID("topic"))]
    )

    var results = try service.searchNotes(query: "Alpha", tagFilter: ["research"])
    XCTAssertEqual(results.map(\.note.noteId), [note.noteId])

    _ = try service.updateNoteBody(noteId: note.noteId, bodyMarkdown: "# Searchable\nGamma delta knowledge")
    XCTAssertTrue(try service.searchNotes(query: "Alpha").isEmpty)
    results = try service.searchNotes(query: "Gamma", classFilter: ["topic"])
    XCTAssertEqual(results.map(\.note.noteId), [note.noteId])

    try service.deleteNote(noteId: note.noteId)
    XCTAssertTrue(try service.searchNotes(query: "Gamma").isEmpty)
  }

  func testSearchSupportsOffsetPagination() throws {
    let service = try makeService()
    _ = try service.createNote(bodyMarkdown: "# First\n\nPaged search body")
    _ = try service.createNote(bodyMarkdown: "# Second\n\nPaged search body")
    _ = try service.createNote(bodyMarkdown: "# Third\n\nPaged search body")
    let allResults = try service.searchNotes(query: "Paged", limit: 3).map(\.note.noteId)

    XCTAssertEqual(
      try service.searchNotes(query: "Paged", limit: 2).map(\.note.noteId),
      Array(allResults.prefix(2))
    )
    XCTAssertEqual(
      try service.searchNotes(query: "Paged", limit: 2, offset: 2).map(\.note.noteId),
      Array(allResults.dropFirst(2))
    )
  }

  func testSearchSupportsSortDateAndLinkedExpansion() throws {
    let service = try makeService()
    let direct = try service.createNote(bodyMarkdown: "# Alpha\n\nShared planning term")
    let neighbor = try service.createNote(bodyMarkdown: "# Neighbor\n\nNo matching text")
    let unrelated = try service.createNote(bodyMarkdown: "# Unrelated\n\nShared planning term")
    _ = try service.linkNotes(from: direct.noteId, to: neighbor.noteId)

    let withoutLinked = try service.searchNotes(query: "planning", includeLinked: false, limit: 10)
    XCTAssertTrue(withoutLinked.map(\.note.noteId).contains(direct.noteId))
    XCTAssertFalse(withoutLinked.map(\.note.noteId).contains(neighbor.noteId))

    let withLinked = try service.searchNotes(query: "planning", includeLinked: true, limit: 10)
    XCTAssertTrue(withLinked.map(\.note.noteId).contains(neighbor.noteId))
    XCTAssertEqual(withLinked.first { $0.note.noteId == neighbor.noteId }?.isLinkedNeighbor, true)
    XCTAssertTrue(try service.searchNotes(query: "", createdAfter: "2000-01-01", createdBefore: "2999-12-31").contains {
      $0.note.noteId == direct.noteId
    })
    XCTAssertEqual(
      try service.searchNotes(query: "planning", sort: .title, limit: 10).map(\.note.noteId).prefix(2),
      [direct.noteId, unrelated.noteId]
    )
    XCTAssertTrue(try service.searchNotes(query: "", createdAfter: "2999-01-01T00:00:00.000Z").isEmpty)
  }

  func testLinkedSearchExcludesDirectHitsBeforeNeighborLimitAndAppliesFilters() throws {
    let service = try makeService()
    let direct = try service.createNote(
      bodyMarkdown: "# Direct\n\nplanning",
      tags: [NoteTagInput(name: "keep", classId: TagClassID("topic"))]
    )
    let directLinkedToDirect = try service.createNote(bodyMarkdown: "# Also Direct\n\nplanning")
    let filteredNeighbor = try service.createNote(
      bodyMarkdown: "# Filtered Neighbor\n\ncontext",
      tags: [NoteTagInput(name: "keep", classId: TagClassID("topic"))]
    )
    let excludedNeighbor = try service.createNote(bodyMarkdown: "# Excluded Neighbor\n\ncontext")
    _ = try service.linkNotes(from: direct.noteId, to: directLinkedToDirect.noteId)
    _ = try service.linkNotes(from: direct.noteId, to: filteredNeighbor.noteId)
    _ = try service.linkNotes(from: direct.noteId, to: excludedNeighbor.noteId)

    let results = try service.searchNotes(
      query: "planning",
      tagFilter: ["keep"],
      includeLinked: true,
      limit: 2
    )

    XCTAssertEqual(results.map(\.note.noteId), [direct.noteId, filteredNeighbor.noteId])
    XCTAssertEqual(results.last?.isLinkedNeighbor, true)
  }

  func testProposeLinksExcludesExistingLinksAndSelf() throws {
    let service = try makeService()
    let subject = try service.createNote(bodyMarkdown: "# Subject\n\nProject roadmap planning")
    let candidate = try service.createNote(bodyMarkdown: "# Candidate\n\nRoadmap planning notes")
    let existing = try service.createNote(bodyMarkdown: "# Existing\n\nProject roadmap planning")
    _ = try service.linkNotes(from: subject.noteId, to: existing.noteId)

    let proposals = try service.proposeLinks(noteId: subject.noteId)

    XCTAssertEqual(proposals.map(\.targetNote.noteId), [candidate.noteId])
    XCTAssertEqual(proposals.first?.linkKind, "related")
    XCTAssertEqual(proposals.first?.source, "deterministic")
  }

  func testSearchDoesNotBackfillPartialFTSPageWithTextLikeScan() throws {
    let service = try makeService()
    let indexed = try service.createNote(bodyMarkdown: "# Indexed\n\nPartialOnly search body")
    let unindexed = try service.createNote(bodyMarkdown: "# Unindexed\n\nPartialOnly search body")
    try service.driver.withDatabase { database in
      try database.execute("DELETE FROM note_fts_map WHERE note_id = ?", bindings: [.id(unindexed.noteId)])
    }

    let results = try service.searchNotes(query: "PartialOnly", limit: 10).map(\.note.noteId)

    XCTAssertEqual(results, [indexed.noteId])
  }

  func testSearchFindsJapaneseSubstrings() throws {
    let service = try makeService()
    let note = try service.createNote(
      bodyMarkdown: "# 日本語ノート\nこれは日本語検索の検証です",
      tags: [NoteTagInput(name: "知識管理", classId: TagClassID("topic"))]
    )

    XCTAssertEqual(try service.searchNotes(query: "日本語検索").map(\.note.noteId), [note.noteId])
    XCTAssertEqual(try service.searchNotes(query: "検索").map(\.note.noteId), [note.noteId])
    XCTAssertEqual(try service.searchNotes(query: "知識").map(\.note.noteId), [note.noteId])
  }

  func testFTSRefreshUsesStableTagPayloadOrderForUpdateAndDelete() throws {
    let service = try makeService()
    let note = try service.createNote(
      bodyMarkdown: "# Indexed\nObsolete body",
      tags: [
        NoteTagInput(name: "zeta", classId: TagClassID("topic")),
        NoteTagInput(name: "alpha", classId: TagClassID("topic"))
      ]
    )

    _ = try service.updateNoteBody(noteId: note.noteId, bodyMarkdown: "# Indexed\nBeta body")
    try assertFTSIntegrity(service)
    XCTAssertTrue(try service.searchNotes(query: "Obsolete").isEmpty)
    XCTAssertEqual(try service.searchNotes(query: "Beta", tagFilter: ["alpha"]).map(\.note.noteId), [note.noteId])

    try service.deleteNote(noteId: note.noteId)
    try assertFTSIntegrity(service)
    XCTAssertTrue(try service.searchNotes(query: "Beta").isEmpty)
  }

  func testSystemAndNonDeletableTagAssignmentsCannotBeDemotedByLaterApply() throws {
    let service = try makeService()
    let note = try service.createNote(
      bodyMarkdown: "# Tagged\nBody",
      tags: [NoteTagInput(name: "system-topic", classId: TagClassID("topic"))],
      provenance: .system,
      assignedBy: "kaiba-note"
    )

    try service.driver.withDatabase { database in
      try database.execute(
        """
        UPDATE note_tags
        SET deletable = 0
        WHERE note_id = ?
          AND tag_id = (SELECT tag_id FROM tags WHERE name = 'system-topic')
        """,
        bindings: [.id(note.noteId)]
      )
    }

    _ = try service.applyTags(noteId: note.noteId, tags: [NoteTagInput(name: "system-topic")], provenance: .human)
    let assignment = try XCTUnwrap(try service.getNote(note.noteId).tags.first { $0.tag.name == "system-topic" })
    XCTAssertEqual(assignment.provenance, .system)
    XCTAssertEqual(assignment.assignedBy, "kaiba-note")
    XCTAssertFalse(assignment.deletable)
  }

  func testApplyTagRejectsUnknownClassId() throws {
    let service = try makeService()

    XCTAssertThrowsError(try service.createNote(
      bodyMarkdown: "# Dangling\nBody",
      tags: [NoteTagInput(name: "dangling", classId: TagClassID("missing-class"))]
    )) { error in
      XCTAssertEqual(error as? NoteServiceError, .notFound("tag class not found: missing-class"))
    }
  }

  func testDefineTagClassAndTagForConfigAgent() throws {
    let service = try makeService()

    let tagClass = try service.defineTagClass(
      classId: TagClassID("business-idea"),
      label: "Business Idea",
      description: "Opportunity notes"
    )
    let tag = try service.defineTag(name: "business-idea", classId: tagClass.classId)

    XCTAssertEqual(tagClass.classId, TagClassID("business-idea"))
    XCTAssertEqual(tag.classId, TagClassID("business-idea"))
    XCTAssertTrue(try service.listTagClasses().contains(tagClass))
    XCTAssertTrue(try service.listTags().contains(tag))
  }

  func testNotebookKindTagsAreNonDeletableSystemTags() throws {
    let service = try makeService()
    let notebook = try service.createNotebook(
      title: "Imported PDF",
      kindTagName: "notebook-kind:imported-material"
    )

    XCTAssertEqual(notebook.tags.first?.tag.name, "notebook-kind:imported-material")
    XCTAssertEqual(notebook.tags.first?.provenance, .system)
    XCTAssertEqual(notebook.tags.first?.deletable, false)
  }

  func testAttachNotebookFileFromURLStoresSourceDocument() throws {
    let service = try makeService()
    let notebook = try service.createNotebook(title: "Imported PDF")
    let source = URL(fileURLWithPath: service.noteRootPath(), isDirectory: true)
      .appendingPathComponent("source.pdf")
    let sourceData = Data("%PDF-1.4 source".utf8)
    try sourceData.write(to: source)

    let attachment = try service.attachNotebookFile(
      notebookId: notebook.notebookId,
      fileURL: source,
      role: .sourceDocument,
      mediaType: "application/pdf",
      originalFilename: "source.pdf"
    )

    XCTAssertEqual(attachment.role, .sourceDocument)
    XCTAssertEqual(attachment.file.mediaType, "application/pdf")
    XCTAssertEqual(attachment.file.originalFilename, "source.pdf")
    XCTAssertEqual(try service.listFiles(notebookId: notebook.notebookId), [attachment])
    XCTAssertEqual(try service.resolveFileContent(fileId: attachment.file.fileId), sourceData)
  }

  func testNotebookKindTagIdsDoNotCollideForPrefixedAndUnprefixedNames() throws {
    let service = try makeService()

    let plain = try service.createNotebook(title: "Plain Kind", kindTagName: "foo")
    let prefixed = try service.createNotebook(title: "Prefixed Kind", kindTagName: "notebook-kind:foo")

    let plainTag = try XCTUnwrap(plain.tags.first?.tag)
    let prefixedTag = try XCTUnwrap(prefixed.tags.first?.tag)
    XCTAssertEqual(plainTag.name, "foo")
    XCTAssertEqual(prefixedTag.name, "notebook-kind:foo")
    XCTAssertNotEqual(plainTag.tagId, prefixedTag.tagId)
    XCTAssertEqual(try service.listTags().filter { ["foo", "notebook-kind:foo"].contains($0.name) }.count, 2)
  }

  func testListNotebooksFiltersByNotebookTags() throws {
    let service = try makeService()
    let imported = try service.createNotebook(
      title: "Imported PDF",
      kindTagName: "notebook-kind:imported-material"
    )
    let memo = try service.createNotebook(
      title: "Daily Memo",
      kindTagName: "notebook-kind:user-memo"
    )

    let importedKindTagIds = try XCTUnwrap(try service.tagIds(named: ["notebook-kind:imported-material"]))
    let memoKindTagIds = try XCTUnwrap(try service.tagIds(named: ["notebook-kind:user-memo"]))
    XCTAssertEqual(try service.listNotebooks(tagFilterIdGroups: [importedKindTagIds]).map(\.notebookId), [
      imported.notebookId
    ])
    XCTAssertEqual(try service.listNotebooks(tagFilterIdGroups: [memoKindTagIds]).map(\.notebookId), [
      memo.notebookId
    ])
    XCTAssertNil(try service.tagIds(named: ["notebook-kind:missing"]))
    XCTAssertTrue(try service.listNotebooks(tagFilterIdGroups: [[TagID("notebook-kind:missing")]]).isEmpty)
  }

  func testNotebookTagsCanBeAppliedAndRemovedAfterCreation() throws {
    let service = try makeService()
    let notebook = try service.createNotebook(title: "Working Set")

    let tagged = try service.applyNotebookTags(
      notebookId: notebook.notebookId,
      tags: ["active-project"],
      provenance: .human,
      assignedBy: "tester"
    )
    XCTAssertEqual(tagged.tags.map(\.tag.name), ["active-project"])
    let activeProjectTagIds = try XCTUnwrap(tagged.tags.first.map { [$0.tag.tagId] })
    XCTAssertEqual(
      try service.listNotebooks(tagFilterIdGroups: [activeProjectTagIds]).map(\.notebookId),
      [notebook.notebookId]
    )

    XCTAssertThrowsError(try service.removeNotebookTag(
      notebookId: notebook.notebookId,
      tagName: "active-project",
      removedBy: .ai
    )) { error in
      XCTAssertEqual(error as? NoteServiceError, .protectedTag("active-project"))
    }

    let untagged = try service.removeNotebookTag(
      notebookId: notebook.notebookId,
      tagName: "active-project",
      removedBy: .human
    )
    XCTAssertTrue(untagged.tags.isEmpty)
    XCTAssertTrue(try service.listNotebooks(tagFilterIdGroups: [activeProjectTagIds]).isEmpty)
  }

  func testSystemNotebookKindTagsRemainProtectedAfterCreation() throws {
    let service = try makeService()
    let notebook = try service.createNotebook(
      title: "Imported PDF",
      kindTagName: "notebook-kind:imported-material"
    )

    XCTAssertThrowsError(try service.removeNotebookTag(
      notebookId: notebook.notebookId,
      tagName: "notebook-kind:imported-material",
      removedBy: .human
    )) { error in
      XCTAssertEqual(error as? NoteServiceError, .protectedTag("notebook-kind:imported-material"))
    }
  }

  func testCreateNotebookWithNotesStoresPagesAtomically() throws {
    let service = try makeService()

    let result = try service.createNotebookWithNotes(
      title: "Imported Packet",
      kindTagName: "notebook-kind:imported-material",
      metaJSON: #"{"sourceDocumentRef":"file:///packet.pdf"}"#,
      pages: [
        NotePageDraft(
          bodyMarkdown: "# Page One\n\nAlpha OCR",
          tags: [NoteTagInput(name: "ocr", classId: TagClassID("topic"))],
          noteNumber: 10
        ),
        NotePageDraft(
          bodyMarkdown: "# Page Two\n\nBeta OCR",
          tags: [NoteTagInput(name: "ocr", classId: TagClassID("topic"))],
          noteNumber: 20
        )
      ],
      assignedBy: "ingest-workflow"
    )

    XCTAssertEqual(result.notebook.title, "Imported Packet")
    XCTAssertEqual(result.notebook.tags.first?.tag.name, "notebook-kind:imported-material")
    XCTAssertEqual(result.notes.map(\.noteNumber), [10, 20])
    XCTAssertEqual(result.notes.map(\.readOnly), [true, true])
    XCTAssertEqual(result.notes.flatMap(\.tags).map(\.assignedBy), ["ingest-workflow", "ingest-workflow"])
    XCTAssertEqual(try service.searchNotes(query: "Alpha OCR").map(\.note.noteId), [result.notes[0].noteId])
    XCTAssertEqual(try service.searchNotes(query: "Beta OCR").map(\.note.noteId), [result.notes[1].noteId])
  }

  func testCreateNotebookWithNotesRejectsDuplicateExplicitPageNumbers() throws {
    let service = try makeService()

    XCTAssertThrowsError(try service.createNotebookWithNotes(
      title: "Broken Packet",
      pages: [
        NotePageDraft(bodyMarkdown: "# Page One\n\nAlpha", noteNumber: 3),
        NotePageDraft(bodyMarkdown: "# Page Two\n\nBeta", noteNumber: 3)
      ]
    )) { error in
      guard case let NoteServiceError.invalidInput(message) = error else {
        return XCTFail("expected invalidInput, got \(error)")
      }
      XCTAssertTrue(message.contains("3"), "message should name the colliding note number: \(message)")
      XCTAssertTrue(message.contains("1") && message.contains("2"), "message should name colliding pages: \(message)")
    }

    XCTAssertEqual(
      try service.listNotebooks().filter { $0.title == "Broken Packet" }.count,
      0
    )
  }

  func testCreateNotebookWithNotesRollsBackWhenAnyPageFails() throws {
    let service = try makeService()

    XCTAssertThrowsError(try service.createNotebookWithNotes(
      title: "Broken Packet",
      kindTagName: "notebook-kind:imported-material",
      pages: [
        NotePageDraft(bodyMarkdown: "# Page One\n\nShould not remain"),
        NotePageDraft(bodyMarkdown: "# Page Two\n\nInvalid metadata", metaJSON: "{")
      ]
    ))

    XCTAssertEqual(
      try service.listNotebooks().filter { $0.title == "Broken Packet" }.count,
      0
    )
    XCTAssertTrue(try service.searchNotes(query: "Should not remain").isEmpty)
  }

  func testLinksAndCommentsAreAllowedForReadOnlyNotes() throws {
    let service = try makeService()
    let source = try service.createNote(bodyMarkdown: "# Source\nFacts", readOnly: true)
    let target = try service.createNote(bodyMarkdown: "# Target\nContext")

    let link = try service.linkNotes(from: source.noteId, to: target.noteId, provenance: .human)
    let comment = try service.addComment(noteId: source.noteId, bodyMarkdown: "Metadata is still allowed")

    XCTAssertEqual(link.fromNoteId, source.noteId)
    XCTAssertEqual(link.toNoteId, target.noteId)
    XCTAssertEqual(try service.listLinks(noteId: source.noteId), [link])
    XCTAssertEqual(try service.listComments(noteId: source.noteId).map(\.commentId), [comment.commentId])
  }

  func testAILinkCannotOverwriteHumanLinkProvenance() throws {
    let service = try makeService()
    let source = try service.createNote(bodyMarkdown: "# Source\nFacts")
    let target = try service.createNote(bodyMarkdown: "# Target\nContext")

    let human = try service.linkNotes(from: source.noteId, to: target.noteId, provenance: .human)
    let afterAI = try service.linkNotes(from: source.noteId, to: target.noteId, provenance: .ai)

    XCTAssertEqual(afterAI.provenance, .human)
    XCTAssertEqual(afterAI.createdAt, human.createdAt)
    XCTAssertEqual(try service.listLinks(noteId: source.noteId), [human])
  }

  func testHumanLinkCanPromoteAILinkProvenance() throws {
    let service = try makeService()
    let source = try service.createNote(bodyMarkdown: "# Source\nFacts")
    let target = try service.createNote(bodyMarkdown: "# Target\nContext")

    _ = try service.linkNotes(from: source.noteId, to: target.noteId, provenance: .ai)
    let afterHuman = try service.linkNotes(from: source.noteId, to: target.noteId, provenance: .human)

    XCTAssertEqual(afterHuman.provenance, .human)
    XCTAssertEqual(try service.listLinks(noteId: source.noteId).map(\.provenance), [.human])
  }

  func testSaveConversationCreatesConversationNotebookAndCitationLinks() throws {
    let service = try makeService()
    let cited = try service.createNote(bodyMarkdown: "# Cited\nImportant source")

    let saved = try service.saveConversation(
      title: "Agent Chat",
      transcript: [
        NoteConversationTurn(
          userMarkdown: "What matters here?",
          assistantMarkdown: "The cited note matters.",
          sourceNoteIds: [cited.noteId]
        ),
        NoteConversationTurn(userMarkdown: "Anything else?", assistantMarkdown: "No.")
      ],
      assignedBy: "agent-session-1"
    )

    XCTAssertEqual(saved.notebook.title, "Agent Chat")
    XCTAssertEqual(saved.notebook.tags.first?.tag.name, "notebook-kind:agent-conversation")
    XCTAssertEqual(saved.notebook.tags.first?.deletable, false)
    XCTAssertEqual(saved.notes.map(\.noteNumber), [1, 2])
    XCTAssertEqual(saved.notes.first?.title, "Conversation Turn 1")
    XCTAssertEqual(saved.notes.first?.bodyMarkdown.contains("## Agent"), true)

    let links = try service.listLinks(noteId: saved.notes[0].noteId)
    XCTAssertEqual(links.count, 1)
    XCTAssertEqual(links.first?.toNoteId, cited.noteId)
    XCTAssertEqual(links.first?.linkKind, "source-citation")
    XCTAssertEqual(links.first?.provenance, .system)
  }

  func testConversationKindUsesSeededSystemTagWhenFolderSharesItsName() throws {
    let service = try makeService()
    let kindName = "notebook-kind:agent-conversation"
    let seededKind = try XCTUnwrap(try service.listTags().first {
      $0.name == kindName && $0.classId == TagClassID("document-kind") && $0.isSystem
    })
    let sameNamedFolder = try service.defineTag(
      name: kindName,
      classId: TagClassID("folder")
    )

    let saved = try service.saveConversation(
      title: "Identity-safe conversation",
      transcript: [NoteConversationTurn(userMarkdown: "Hello", assistantMarkdown: "Hi")]
    )
    let assignment = try XCTUnwrap(saved.notebook.tags.first)
    XCTAssertEqual(assignment.tag.tagId, seededKind.tagId)
    XCTAssertEqual(assignment.tag.classId, TagClassID("document-kind"))
    XCTAssertNotEqual(assignment.tag.tagId, sameNamedFolder.tagId)
  }

  func testSearchNotesWithMaxOffsetDoesNotOverflow() throws {
    let service = try makeService()
    _ = try service.createNote(bodyMarkdown: "# Overflow\n\nSearchable overflow body")

    // A hostile `offset` at Int.max must not trap the process when combined with
    // `limit` to compute the fetch window; the query simply returns no page.
    let results = try service.searchNotes(query: "overflow", limit: 5, offset: Int.max)
    XCTAssertTrue(results.isEmpty)
  }
}

private final class ConcurrentFolderPathResults: @unchecked Sendable {
  private let lock = NSLock()
  private var storedTagIds: [TagID] = []
  private var storedErrors: [String] = []

  var tagIds: [TagID] {
    lock.lock()
    defer { lock.unlock() }
    return storedTagIds
  }

  var errors: [String] {
    lock.lock()
    defer { lock.unlock() }
    return storedErrors
  }

  func record(tagId: TagID) {
    lock.lock()
    storedTagIds.append(tagId)
    lock.unlock()
  }

  func record(error: Error) {
    lock.lock()
    storedErrors.append(String(describing: error))
    lock.unlock()
  }
}

func makeService(function: String = #function) throws -> NoteService {
  let service = try NoteService(driver: try makeNoteDriver(function: function))
  try enableSeededAutoActions(driver: service.driver)
  return service
}

// Kaiba seeds the default AI-tagging actions disabled (no dispatcher ships with
// the CLI). The vendored tests were written against the enabled note-created/
// note-updated seeds, so the shared helpers opt those two back in; the
// notebook-created seed (added for AI notebook tagging) stays disabled here so
// vendored expectations keep their original dispatch counts.
func enableSeededAutoActions(driver: NoteDatabaseDriving) throws {
  try driver.withDatabase { database in
    try database.execute(
      """
      UPDATE auto_actions SET enabled = 1
      WHERE action_id IN (
        'default-ai-tagging-note-created',
        'default-ai-tagging-note-updated'
      )
      """
    )
  }
}

private func assertFTSIntegrity(_ service: NoteService, file: StaticString = #filePath, line: UInt = #line) throws {
  do {
    try service.driver.withDatabase { database in
      try database.execute("INSERT INTO note_fts(note_fts) VALUES('integrity-check')")
    }
  } catch {
    XCTFail("FTS integrity check failed: \(error)", file: file, line: line)
    throw error
  }
}

private func XCTAssertFractionalISO8601(
  _ value: String,
  file: StaticString = #filePath,
  line: UInt = #line
) {
  XCTAssertNotNil(value.range(of: #"\.\d+Z$"#, options: .regularExpression), file: file, line: line)
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  XCTAssertNotNil(formatter.date(from: value), file: file, line: line)
}
