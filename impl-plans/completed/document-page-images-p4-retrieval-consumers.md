# P4: Retrieval-Text Consumers (LIKE search, snippets, tagging, agent tools, notebook preview)

**planId**: P4-retrieval-consumers
**Wave**: 2
**dependsOn**: P1-storage-contract
**Status**: Completed. Accepted in session-246 (test-integrity, adversarial and serial integration review). The combined-tree `mise run check` exited 0 (`tmp/document-page-images/reconcile-session-246/wave5/full-check.log`). Archived at Step 8 on 2026-10-02.
**Design Reference**: `design-docs/specs/design-document-page-images.md` DP4 (all rows except the FTS row, which is P1, and the chat rows, which are P6); `design-docs/specs/note-retrieval-fusion.md` "Retrieval text for document page notes"
**Index**: `impl-plans/active/document-page-images.md`

## Intent and context

After P1, a page note's OCR text lives in `notes.search_text`, and `body_markdown`
is `""`. FTS already indexes the retrieval text (P1). The other readers of note
text must use the same retrieval text so that search results, tagging and agent
tools keep working for page notes. For every other note `search_text` is NULL,
so the retrieval text is exactly `bodyMarkdown`. Non-page behaviour must remain
byte-identical.

## Non-goals

- Do not change `NoteSearchIndex.swift` (P1) or chat context files (P6).
- Do not change `AITranslation.swift`. Translation is out of scope by design.
- Do not change GraphQL types, ranking weights, or the fusion algorithm.
- Do not expose `search_text` as a new GraphQL field.
- Do not change bm25 weights.

## writePaths

- `Sources/AppCore/NoteSearch.swift`
- `Sources/AppCore/NoteSearchLexicalFusion.swift`
- `Sources/AppCore/AITagExtraction.swift`
- `Sources/AppCore/KaibaAgentToolbox.swift`
- `Sources/AppCore/NoteService+NotebookStats.swift`
- `Tests/AppCoreTests/DocumentPageRetrievalTextTests.swift` (new)
- `Tests/AppCoreTests/KaibaAgentToolboxTests.swift`
- `impl-plans/active/document-page-images-p4-retrieval-consumers.md` (Progress Log only)

## sharedPaths (read-only)

- `Sources/AppCore/NoteRetrievalText.swift` (P1 helpers: `noteRetrievalText`,
  `noteSearchTexts`, `NoteService.retrievalText(for:)`,
  `NoteService.retrievalTexts(for:)`).

## File-level changes

1. **`NoteSearch.swift`**:
   - In each result builder that calls `snippet(from: note.bodyMarkdown, ...)`
     (about lines 306, 454, 575 and 676), first batch-load
     `noteSearchTexts(ids, in: database)` once per query. Then use
     `snippet(from: noteRetrievalText(bodyMarkdown: note.bodyMarkdown, searchText: texts[note.noteId]), query: ...)`.
   - `searchNotesByTextLike`: add `OR n.search_text LIKE ? ESCAPE '\\'` inside the
     text predicate, and add one more `.text(likePattern)` binding in the correct
     position. The bindings are positional; recount them.
   - Leave `snippet(from:query:)` itself unchanged.
2. **`NoteSearchLexicalFusion.swift`** (about line 115): build the snippet from
   the retrieval text. `relaxedSnippetQuery(terms:body:)` must receive the same
   retrieval text. Batch-load once, before the `map`.
3. **`AITagExtraction.swift` `subjectContext`**:
   - Note subject: `Self.capped(service.retrievalText(for: note))`.
   - Notebook subject: load the retrieval texts once with
     `service.retrievalTexts(for: notes)`, then use
     `texts[note.noteId] ?? note.bodyMarkdown` with the same `prefix(4_000)`.
4. **`KaibaAgentToolbox.swift`**:
   - `getNotebook` preview: `String(retrievalText.prefix(240))`, using
     `service.retrievalTexts(for: notes)`.
   - `getNote`: after `noteJSON(note, includeBody: true)`, if
     `NoteService.isDocumentPageNote(note)`, add
     `payload["page_text"] = .string(AgentToolOutputLimits.bounded(searchText, maximumBytes: AgentToolOutputLimits.maximumNoteBodyBytes))`.
     Here `searchText` is the note's search text, or `""` when it is nil.
     `body_markdown` stays as stored.
   - `search_notes` uses `NoteSearchResult.snippet`, which is already fixed by
     change 1. Do not change it.
5. **`NoteService+NotebookStats.swift` `firstNotePreviews`**: also select
   `outer_notes.search_text`, and compute
   `notebookPreviewText(noteRetrievalText(bodyMarkdown: body, searchText: row["search_text"]))`.
   This was a residual-risk item in the design review: without it, PDF notebooks
   show empty list previews.

## Pitfalls

- Load search texts in a batch, once per query. Do not load them per result row.
  The search paths run on every keystroke in some clients.
- LIKE bindings are positional. Insert the new binding right after the
  `body_markdown` LIKE binding. Then run a non-page LIKE test to confirm that tag
  LIKE still matches.
- `requireNotes` returns `Note` values, and `Note` has no search text. Do not add
  a field to `Note`.
- Keep `get_note`'s existing keys unchanged. Only add `page_text`.

## Tests to add (`DocumentPageRetrievalTextTests.swift`)

Fixture: `createNotebookWithNotes` with drafts that use P1's `searchText`:

- a page note with metaJSON `documentPage`, body `""` and searchText
  "Zephyrine harbor manifest";
- a normal note with body "plain note body".

Cases:

- `searchNotes(query: "Zephyrine")` -> returns the page note, and the snippet
  contains "Zephyrine".
- A query that forces the LIKE fallback (a sub-trigram term, imitating an
  existing LIKE-path test in the NoteSearch tests, for example a 2-character
  term that occurs only in the OCR text) -> returns the page note.
- A relaxed multi-term query (one term matches the OCR, one matches nothing)
  -> the page note has `termCoverage` 0.5, and its snippet comes from the OCR.
- The normal note's snippet is byte-identical to `snippet(from: "plain note body", query: ...)`.
- `AITagExtractionService` with a capturing fake `AgentInvoking`. Imitate
  `Tests/AppCoreTests/DocumentAutoTaggingTests.swift`'s fake invoker.
  - Tagging the page note -> the request's text contains "Zephyrine harbor manifest".
  - Tagging the notebook -> the request contains it under the page's heading.
- Notebook list stats (`listNotebooks` or the stats API used by
  `NoteService+NotebookStats` callers) -> the first-note preview of a page-only
  notebook contains "Zephyrine".

`KaibaAgentToolboxTests.swift` (append):

- `get_note` on the page note -> `page_text` equals the OCR text, and
  `body_markdown` is `""`.
- `get_note` on a normal note -> has no `page_text` key.
- `get_notebook` preview of the page note -> starts with "Zephyrine".

## Verification commands and required evidence

Use the prefix `PKG_CONFIG_PATH="$PWD/.build/anydoc-native/host/pkgconfig" mise exec --`
and save logs to `tmp/document-page-images/P4/`.

- `swift test --filter DocumentPageRetrievalText`. Must exit 0.
- `swift test --filter NoteSearch`. Must exit 0, with no regressions in the
  existing search, fusion or graph tests.
- `swift test --filter KaibaAgentToolbox`. Must exit 0.
- `swift test --filter AITag`. Must exit 0.
- `swift test --filter NotebookStats`, or the test class covering notebook
  previews (find it with `grep -rln firstNotePreview Tests`). Must exit 0.
- `mise run lint`. Must exit 0.
- `wc -l Sources/AppCore/NoteSearch.swift`. Must be under 1000. The file is 854
  lines now; keep additions small.

## Done criteria

- [x] `grep -n "snippet(from: note.bodyMarkdown" Sources/AppCore/NoteSearch.swift Sources/AppCore/NoteSearchLexicalFusion.swift` prints nothing.
- [x] `grep -n "search_text LIKE" Sources/AppCore/NoteSearch.swift` matches.
- [x] `grep -n "page_text" Sources/AppCore/KaibaAgentToolbox.swift` matches.
- [x] All assigned commands exit 0, and logs are saved.

## Progress Log

- 2026-10-01: Plan created.
- 2026-10-02: Implemented P4 retrieval consumers. FTS, filter, LIKE, relaxed, and graph search snippets now batch-load search_text and use noteRetrievalText; LIKE binds search_text after body_markdown. AI tagging note/notebook context, get_notebook previews, page-only get_note `page_text`, and notebook list first-note previews use retrieval text. Added synthetic page/normal note coverage for search, LIKE, relaxed coverage, tagging, toolbox fields, and notebook preview.
- 2026-10-02 verification: `PKG_CONFIG_PATH="$PWD/.build/anydoc-native/host/pkgconfig" mise exec -- swift test --filter DocumentPageRetrievalText` passed 4 tests; `... swift test --filter NoteSearch` passed 1 test; `... swift test --filter KaibaAgentToolbox` passed 8; `... swift test --filter AITag` passed 12; `... swift test --filter NotebookStats` passed 6; supplemental `... swift test --filter NoteRetrievalFusion` passed 12 and `... swift test --filter NoteServiceTests` passed 40. Full logs are under `tmp/document-page-images/P4/`.
- 2026-10-02 lint/static checks: the NUL-manifest selected-file command `xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/document-page-images/P4/changed-swift-files.nul` passed. `mise run lint` exited 0 with 3 diagnostics in untouched baseline files (`NoteService.swift:720`, `ResendGatewayCLIMailSender.swift:75`, `AITranslationTests.swift:71`). `NoteSearch.swift` is 876 lines; diff check and all three required grep gates passed. First retrieval test attempt exposed two incorrect assertions (untitled heading assumption and out-of-scope single-notebook preview); corrected test assertions passed on rerun (`retrieval-text-final.log`).
- 2026-10-02: Implementation-phase work is complete. Formal test-integrity, adversarial, and serial integration review remain downstream workflow steps.
