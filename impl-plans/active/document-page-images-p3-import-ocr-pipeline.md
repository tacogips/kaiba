# P3: Import and Manual-OCR Pipeline (search text only, figures dropped, determinism tests)

**planId**: P3-import-ocr-pipeline
**Wave**: 2
**dependsOn**: P1-storage-contract
**Status**: Not started
**Design Reference**: `design-docs/specs/design-document-page-images.md` DP3 items 1-2, DP7, I1, I3, I4
**Index**: `impl-plans/active/document-page-images.md`

## Intent and context

PDF and standalone images become one note per page through
`DocumentPageProcessor.prepare` (`Sources/AppCore/DocumentPageProcessing.swift`)
and `NoteService.importDocumentPages` (`Sources/AppCore/NoteService+PageImport.swift`).
Today the OCR markdown and `![Figure n](/files/<id>)` links are written into
`bodyMarkdown`. Manual OCR (`Sources/AppCore/NoteService+DocumentPageOCR.swift`)
prepends recognized text to the body through `updateNoteBodyInDatabase(... completingPendingDocumentOCR: true)`.

After this plan:

- page bodies are `""`;
- OCR goes to `notes.search_text`, using P1's `NotePageDraft.searchText` and the
  column;
- figure extraction is removed everywhere;
- manual OCR writes only `search_text`, the title, `documentPage` metadata and
  FTS.

Rasterization stays deterministic, and this plan adds tests that prove it.

## Non-goals

- Do not change `PDFDocumentImageExtractor.swift`, `EPUBDocumentImageExtractor.swift`,
  `DocumentImageExtracting.swift`, `ImageOCRDocumentConverter.swift`,
  `VisionDocumentPageRecognizer.swift` or `GoogleDocumentAIPageRecognizer.swift`.
- Do not change the heading-split import path: `NoteService+DocumentImport.swift`,
  `MarkdownHeadingSplitter.swift`, `DocumentConverting.swift` and
  `DocumentPageNoteMapper.swift`.
- Do not change search, tagging, undo or chat code. Those belong to P4, P5 and P6.
- Do not add a GraphQL field.
- Do not edit `Tests/AppCoreTests/DocumentAutoTaggingTests.swift`. P10 owns it,
  because its tagging-text assertion also needs P4.

## writePaths

- `Sources/AppCore/DocumentPageProcessing.swift`
- `Sources/AppCore/NoteService+PageImport.swift`
- `Sources/AppCore/NoteService+DocumentPageOCR.swift`
- `Sources/AppCore/DocumentPageFigureExtraction.swift` (delete)
- `Sources/AppCore/DocumentFigureTextBounds.swift` (delete; only figure extraction uses it, so verify with grep before deleting)
- `Sources/AppCore/DocumentImportProviderFactory.swift`
- `Sources/AppCore/KaibaConfiguration.swift`
- `Sources/AppCore/CommandImport.swift`
- `Sources/AppGraphQL/NoteGraphQLService.swift`
- `Sources/AppGraphQL/NoteGraphQLService+DocumentImport.swift`
- `Sources/AppGraphQL/NoteGraphQLService+DocumentPages.swift`
- `Sources/AppServer/KaibaServerRuntime.swift`
- `Tests/AppCoreTests/DocumentPageProcessingTests.swift`
- `Tests/AppCoreTests/DocumentPageImportTests.swift`
- `Tests/AppCoreTests/DocumentVisualProviderTests.swift`
- `Tests/AppCoreTests/DocumentFigureTextBoundsTests.swift` (delete)
- `Tests/AppCoreTests/GoogleDocumentAIPageRecognizerTests.swift`
- `Tests/AppCoreTests/PDFPageRasterDeterminismTests.swift` (new)
- `Tests/AppGraphQLTests/DocumentPageOCRGraphQLTests.swift`
- `Tests/AppGraphQLTests/DocumentUploadGraphQLTests.swift`
- `Tests/AppGraphQLTests/GoogleDocumentAIOCRGraphQLTests.swift`
- `impl-plans/active/document-page-images-p3-import-ocr-pipeline.md` (Progress Log only)

## sharedPaths

- `Sources/AppCore/NoteService.swift`. P1 edited it in wave 1, and no other
  wave-2 plan edits it. P3 may edit it only to remove the
  `completingPendingDocumentOCR` parameter and its
  `requirePendingDocumentOCRNote` branch from `updateNoteBodyInDatabase`, and to
  change the guard condition to unconditional
  `if Self.isDocumentPageNote(existing)`. Read the file fresh and record its hash.
- `Sources/AppCore/NoteRetrievalText.swift` (P1, read-only).
- `Sources/AppCore/PDFDocumentImageExtractor.swift` (read-only, used by the
  determinism test).

sharedPathNotes:

- `Sources/AppCore/NoteService.swift`: remove the `completingPendingDocumentOCR`
  parameter and branch, and make the document-page body guard unconditional.
  Make no other change.

## File-level changes

1. **`DocumentPageProcessing.swift`**:
   - Remove the `figureExtractor` stored property and init parameter, and remove
     `PreparedDocumentPage.figures`.
   - Ignore `.embedded` extraction results. Keep only `.pageCapture` origins.
   - Keep `markdown: String?` (nil means pending), and update its doc comment to
     say "recognized OCR text; stored as hidden search text".
   - Keep the analyzer and recognizer calls and the page-limit semantics exactly.
   - Add one doc comment stating that origin images come only from the extractor
     or the source bytes, and that providers receive a temporary copy and never
     produce page images.
2. **`NoteService+PageImport.swift`**:
   - Stage and attach only the origin file per page, with role `.sourcePageImage`
     and position = page number. Keep the source-document attachment.
   - Draft fields:
     - `NotePageDraft(bodyMarkdown: "", readOnly: false, metaJSON: ..., noteNumber: page.pageNumber, searchText: page.markdown ?? "")`;
     - `ocrState` is `"pending"` when `page.markdown == nil`;
     - `pendingBodySHA256: nil`.
   - The notebook-title derivation stays as it is (analysis title, then the
     first page markdown title, then the filename).
   - Keep `ImportedPageMetadata.pendingBodySHA256` as an optional field so that
     old metadata still decodes.
3. **`NoteService+DocumentPageOCR.swift` `recognizeDocumentPage`**:
   - New signature without `figureExtractor`:
     `recognizeDocumentPage(noteId:recognizer:analyzer:)`.
   - `requirePendingDocumentOCRNote` keeps the ownership, read-only, pending-state
     and origin-present checks, and drops the `pendingBodySHA256` digest
     comparison.
   - Final transaction, in order:
     1. Re-read the note through `requirePendingDocumentOCRNote` and require
        `current == snapshot`. Otherwise throw `conflict`.
     2. Read `previous = ftsPayload`.
     3. Read `existing = noteSearchText`.
     4. Compute `newSearch`: if `existing` is non-empty, it is
        `recognized + "\n\n" + existing`; otherwise it is `recognized`.
     5. Compute the title: when `noteTitleSource == .derived`, use
        `noteTitle(from: recognized) ?? current.title`; otherwise keep the title.
     6. `UPDATE notes SET search_text = ?, title = ?, updated_at = ?, updated_by = (owner), meta_json = jsonb(?)`.
        The meta JSON is the existing object with `documentPage` replaced:
        `ocrState` complete, `pendingBodySHA256` nil, new analysis.
     7. Touch the notebook's `updated_at` (imitate `updateNoteBodyInDatabase`).
     8. Call `refreshFTS(noteId:previous:)`.
     9. Enqueue auto-actions using `makeAutoActionEvent(trigger: .noteUpdated, ..., noteBodyMarkdown: noteRetrievalText(bodyMarkdown: current.bodyMarkdown, searchText: newSearch), ...)`.
   - After commit, `dispatchQueuedAutoActions` and publish `noteUpdated`, as today.
   - Never write `body_markdown`. Never call `recordAction`.
4. **Remove figure wiring**:
   - `DocumentImportProviderFactory.swift`: remove `makeFigureExtractor`.
   - `KaibaConfiguration.swift`: remove `KaibaImportConfiguration.figures` and its
     init parameter. Unknown JSON keys are ignored by the decoder. Verify that
     `KaibaImportConfiguration` uses synthesized decoding or a keyed container
     that ignores unknown keys.
   - `CommandImport.swift`: remove the `figureExtractor:` arguments in import and
     `page-ocr`.
   - `NoteGraphQLService.swift`: remove the `documentPageFigureExtractor` stored
     property and init parameter.
   - `NoteGraphQLService+DocumentImport.swift` and
     `NoteGraphQLService+DocumentPages.swift`: remove the arguments.
   - `KaibaServerRuntime.swift`: remove the `documentPageFigureExtractor:` line.
   - Delete `DocumentPageFigureExtraction.swift` and `DocumentFigureTextBounds.swift`
     after `grep -rn "DocumentFigureRegion\|DocumentFigureLocating\|DocumentPageFigureExtracting\|CroppingDocumentPageFigureExtractor\|StructuredDocumentFigureLocator\|DocumentFigureTextBounds" Sources Tests`
     shows only the files you are removing or updating.

## Pitfalls

- `pendingBodySHA256` must not be written for new imports. It must still decode
  when present.
- The OCR path previously used `updateNoteBodyInDatabase`. Do not route it back
  through any body-writing function, because the P1 body guard will reject it.
- Pending pages must store `search_text = ''` (not NULL), so that invariant I1
  holds and P1's migration selector skips them.
- `refreshFTS` must be preceded by `ftsPayload`, read before the UPDATE.
- Concurrency: recognition runs outside the transaction. The `current == snapshot`
  comparison plus `ocrState == pending` is the only guard. Keep the
  existing staged-file cleanup pattern only for files that are still staged.
  After figure removal, no new files are staged, so delete the staging code.
- Do not remove `ImportedPageMetadata` fields or rename `documentPage` JSON keys.
  The web client parses them.
- After removing init parameters, grep `Tests/` for `figureExtractor:` and
  `documentPageFigureExtractor:` and fix every call site in your write paths. If
  a call site is outside your write paths, stop and record it as a reconciliation
  item in your Progress Log.

## Tests to add or update

`DocumentPageImportTests.swift`:

- Rename and update `testPersistsExactPageOriginsPendingStateFiguresAndTitle` to
  cover origins, pending state, search text and title:
  - a 3-page fake PDF with OCR limit 2 -> 3 notes;
  - each note's body is `""`;
  - `noteSearchText` of pages 1-2 equals the recognized text, and page 3 is `""`;
  - each page has exactly one `note_files` row with role `source-page-image`;
  - no `embedded` rows;
  - origin bytes equal the extractor bytes;
  - titles are derived from the recognized text;
  - `metaJSON` has no `pendingBodySHA256`.
- Replace the three figure tests (`testDeferredOCRCompletesReadOnlyImportAndPreservesFigure`,
  `testDeferredOCRStoresNewFiguresWithText` and
  `testDeferredFigureLinkFailureRollsBackOCRAndRemovesStagedBlob`) with these
  cases:
  - deferred OCR on pending page 3 -> `search_text` equals the recognized text;
    body still `""`; `ocrState` complete; FTS `searchNotes` finds a recognized
    word; no action-history `noteBodyUpdated` entry.
  - deferred OCR on a page whose `search_text` is `"legacy text ![Figure 1](/files/f1)"`
    (set by direct SQL plus `refreshFTS`, simulating migrated pending text) ->
    `search_text == recognized + "\n\n" + "legacy text ![Figure 1](/files/f1)"`.
- Replace `testDeferredOCRRejectsEditedPage` with: `updateNoteBody` on a pending
  page -> `invalidInput`, and OCR afterwards still succeeds. The body is
  unwritable, so the digest guard is unnecessary.
  - First make the imported notebook writable through the existing notebook
    read-only API. Imports create read-only notebooks, and otherwise the
    read-only error fires before the page guard.
- Keep `testConcurrentEditDuringOCRIsNotOverwritten`, adapted: the concurrent
  change is a metadata or `ocrState` change, or a second OCR completion
  -> `conflict`, and `search_text` keeps the first value.
- Keep `testRealDownloadedPDFPersistsEveryPageWithOnlyTwoOCRCalls`, adapted to
  `search_text`. It stays skipped when its fixture is absent. Do not add real
  PDFs.
- Keep `testFileLinkFailureRollsBackNotebookNotesAndStagedFiles`.
- Add a standalone image import case, so the image path is tested and not only
  the PDF fake path. Imitate the existing tests in this file that write a
  synthetic `.png` source file (search for `.png`, for example
  `testDeferredOCRStoresNewFiguresWithText`). Use generated bytes only and no
  real files.
  - `importDocumentPages` with a synthetic `.png` source file (no PDF; the
    processor uses the source bytes unchanged as the origin) and a fake
    recognizer returning a known synthetic text -> exactly one note;
  - the body is `""`;
  - `noteSearchText` equals the recognized text;
  - exactly one `note_files` row with role `source-page-image`, and its bytes
    equal the source PNG bytes exactly;
  - no `embedded` rows;
  - `documentPage.ocrState == "complete"`;
  - `searchNotes` finds the note by a recognized word.
  - Variant with `maximumOCRPages: 0` -> body `""`, `search_text` is `''` (not
    NULL), and `ocrState` is `pending`.

`DocumentPageProcessingTests.swift`:

- Remove `testVisualFigureProviderRunsOnlyWithinOCRLimit`.
- Add: an extractor result containing `.embedded` images -> `prepare` output
  contains no figures. There is no `figures` property any more, so assert that
  the result has only origins.
- Add determinism of origins:
  - a recording fake analyzer and recognizer with `maximumOCRPages: 0` -> zero
    provider calls, and each `origin.data` equals the extractor output byte for
    byte;
  - with `maximumOCRPages: nil` -> providers are called once per page, and the
    origin bytes are still identical.

`PDFPageRasterDeterminismTests.swift` (new):

- Guard it with `#if canImport(PDFKit)`; otherwise `XCTSkip`.
- Generate a 2-page PDF in memory with CoreGraphics (imitate any PDF
  generation helper in `DocumentPageProcessingTests` or
  `PDFDocumentImageExtractor` tests; if none exists, use
  `CGContext(consumer:mediaBox:)`).
- Write it to a temporary directory and run `DocumentImageExtractor().extractImages`
  twice. Assert:
  - the `.pageCapture` bytes are equal between runs;
  - each capture's longest pixel side is 1600 (read it with `CGImageSourceCreateWithData`);
  - the pages are numbered 1 and 2.

`DocumentVisualProviderTests.swift`:

- Remove `testCropUsesTopLeftCoordinatesAndPreservesActualPixels`.
- Remove the figure-locator parts of `testInvalidAnalysisAndRegionsFailInsteadOfGuessing`
  and keep the analysis parts.
- In `testIndependentGatewayConfigurationsRoundTrip`, drop `figures`, and add:
  configuration JSON containing an `import.figures` object still decodes, and the
  other `import` fields are preserved.

Delete `DocumentFigureTextBoundsTests.swift`.

`GoogleDocumentAIPageRecognizerTests.swift`, `DocumentPageOCRGraphQLTests.swift`,
`DocumentUploadGraphQLTests.swift`, `GoogleDocumentAIOCRGraphQLTests.swift`:

- Change assertions that expect recognized text in `bodyMarkdown` so that they
  expect `bodyMarkdown == ""` and the recognized text in `search_text`. Read
  `search_text` through `driver.withDatabase { try noteSearchText(id, in: $0) }`,
  using the test fixture's service or driver access. Keep each test's other
  intent, such as error mapping and column order.

## Verification commands and required evidence

Use the prefix `PKG_CONFIG_PATH="$PWD/.build/anydoc-native/host/pkgconfig" mise exec --`
and tee each log to `tmp/document-page-images/P3/`.

- `swift test --filter DocumentPage`. Must exit 0. Log `document-page.log`.
- `swift test --filter PDFPageRasterDeterminism`. Must exit 0 on macOS. Log
  `determinism.log`.
- `swift test --filter DocumentVisualProvider`. Must exit 0.
- `swift test --filter GoogleDocumentAI`. Must exit 0.
- `swift test --filter DocumentUploadGraphQL`. Must exit 0.
- `swift test --filter DocumentImport`. Must exit 0. This is the regression check
  for the heading-split path and image converter tests.
- `mise run build`. Must exit 0. AppServer and the CLI must compile without
  figure wiring.
- `mise run lint`. Must exit 0.
- `grep -rn "figureExtractor\|makeFigureExtractor\|DocumentPageFigureExtracting" Sources Tests`.
  Must print nothing.
- `wc -l` on every edited Swift file. Each must be under 1000.

`DocumentAutoTaggingTests` may fail until P4 lands. Record the result, but do
not fix it here. P10 owns that file.

## Done criteria

- [ ] `Sources/AppCore/DocumentPageFigureExtraction.swift` and
  `Sources/AppCore/DocumentFigureTextBounds.swift` no longer exist.
- [ ] `grep -n "pendingBodySHA256: page.markdown" Sources/AppCore/NoteService+PageImport.swift` prints nothing.
- [ ] `grep -n "body_markdown\|bodyMarkdown:" Sources/AppCore/NoteService+DocumentPageOCR.swift`
  matches only reads used to compute retrieval text. No body write remains.
- [ ] All commands above exit 0, and logs are saved.
- [ ] `document-page.log` lists the standalone image import test, including its
  `maximumOCRPages: 0` variant, as passed.

## Progress Log

- 2026-10-01: Plan created.
