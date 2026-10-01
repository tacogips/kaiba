# Document Page Images: Image-Only Reader, Hidden OCR Text, Page-Aware Agent Chat

## Status

Accepted (2026-10-01). Supersedes these parts of
[document-import.md](document-import.md): the Text/Original page reader, OCR
text stored in `notes.body_markdown` of page notes, figure Markdown links, the
`import.figures` provider, and the pending-body digest edit guard. Amends
[ai-agent-integration.md](ai-agent-integration.md) AI1 and AI11 (see AI12
there) and adds one rule to [note-retrieval-fusion.md](note-retrieval-fusion.md).
User-facing decisions taken without an explicit answer are listed in
[../user-qa/document-page-images.md](../user-qa/document-page-images.md).

## Problem

PDF and standalone image imports already create one note per physical page
with a deterministic PDFKit/CoreGraphics page raster
(`PDFDocumentImageExtractor`, `source-page-image` file). The OCR output and
figure links are written into `bodyMarkdown`, and the web reader
(`DocumentNotebookReader`) offers a Text/Original toggle. Users find the toggle
confusing and do not want to read OCR Markdown. Agent chat on a page sends only
`bodyMarkdown`, so the model never sees the page.

## Scope

In scope: notes created by the page processor, which are PDF pages and standalone
PNG/JPEG/GIF/WebP images. In this document these are called document page notes.

Out of scope and unchanged: EPUB, DOCX, PPTX, XLSX, OpenDocument, RTF, CSV,
HTML, Markdown, text, and every other format that goes through
`AnydocKitDocumentConverter` + `MarkdownHeadingSplitter`. These keep producing
readable heading-split Markdown notes (DI2/DI7 of document-import.md). All
user-authored notes, memo and chat notes also stay unchanged.

### Definitions

- **Document page note**: a note whose `meta_json` has a `documentPage` object
  that decodes as `ImportedPageMetadata`. The existing `NoteService.importedPageMetadata(_:)`
  decides this. No other marker is introduced.
- **Search text**: the new `notes.search_text` column. It holds the OCR output of a
  document page note. It is `''` while OCR is pending and `NULL` for every other note.
- **Retrieval text**: one deterministic function of `(body_markdown, search_text)`.
  When `search_text` is NULL or empty, it is `body_markdown`.
  When `body_markdown` is empty, it is `search_text`.
  Otherwise it is `body_markdown + "\n\n" + search_text`.
  Every index, snippet and AI-context consumer listed in DP4 reads this one
  function. It is never computed in two different ways.

## Design Decisions

### DP1. The reader shows only the page image

For notebooks that contain document page notes, `DocumentNotebookReader` always
renders the stored origin image (`NoteFileImage` for `documentPage.originFileId`).

- Remove the `mode` signal, the `Page display mode` button group and the
  Text/Original buttons.
- Remove the Markdown body and the inline `NoteEditor` from the page view. The
  reader does not render `bodyMarkdown`, even when it is not empty (see DP3 for
  legacy content).
- Keep: physical-page ordering, batch loading, previous/next buttons, arrow keys,
  swipe, page jump, and right-binding and vertical-writing navigation
  (`pageStepForArrow`, with binding inherited from neighbouring pages when a page
  reports `unknown`). The reader no longer reads `writingMode`, because no text
  is laid out. The value stays in the metadata.
- The manual OCR button stays for pending pages. Its label becomes
  "Make page searchable" and the pending notice becomes "Text on this page is
  not searchable yet." Errors and retry behaviour are unchanged.
- `ReaderPane` still picks `DocumentNotebookReader` when any loaded note has
  `documentPage` metadata. Its fallback for other notebooks (`NoteSection`
  Markdown rendering) is unchanged.

### DP2. OCR text is stored in a dedicated `notes.search_text` column

Decision: add a nullable `search_text TEXT` column to `notes`.

Rejected alternatives:

- Keeping OCR in `bodyMarkdown` and only hiding it in the web reader. OCR would
  still appear in every other `bodyMarkdown` consumer: GraphQL `Note`, the CLI,
  KaibaClient, agent tools, edit mode and undo patches.
- Storing OCR in `meta_json.documentPage`. `metaJSON` is returned by every note
  query, so the text would be sent to every client on every page load. FTS would
  also have to index JSON.

`search_text` is server-internal. It is not a field of the AppCore `Note` value or
the GraphQL `Note` type. It is read through a narrow internal accessor so that
`Note` equality, existing snapshots and every client contract stay unchanged.

FTS stays exactly as it is (`note_fts(title, body, tags, context)`). The `body`
column is indexed with the retrieval text instead of the raw `body_markdown`.
OCR text therefore keeps the same bm25 column weight (`1.0`) it had when it
lived in `body_markdown`, so ranking and retrieval-fusion scores for page notes
do not change. The FTS table definition does not need to be rebuilt.

### DP3. Write paths and the body guard

1. **Import** (`NoteService.importDocumentPages`):
   - Each page draft gets `bodyMarkdown = ""` and
     `searchText = recognized text ?? ""`. `NotePageDraft` gains an optional
     `searchText`, which is nil for every other caller.
   - The note title is derived as today, but from the recognized text, because the
     body is empty: `noteTitle(from: body) ?? noteTitle(from: searchText)`. This
     keeps the table-of-contents labels the same as before and the same as
     migrated notes.
   - Only the origin image is attached to each page note. Figures are no longer
     attached or linked (DP7).
   - `pendingBodySHA256` is no longer written.
   - `ocrState` is `pending` when OCR did not run and `complete` otherwise.
   - `insertNotebookWithNotes` writes `search_text` in the same `INSERT` and then
     calls `refreshFTS`, so the index row is created from the retrieval text in
     the same transaction.
2. **Manual or deferred OCR** (`recognizeDocumentPage`, CLI `page-ocr`, GraphQL
   `recognizeDocumentPage`):
   - Recognition and analysis still run outside the transaction on the stored
     origin.
   - The final transaction re-reads the note. It requires that the note is
     reachable and owned, has no note-level lock, has `ocrState == "pending"`, and
     has a `Note` value equal to the snapshot. If any check fails, it raises
     `conflict` and writes nothing.
   - The transaction then:
     1. reads the previous FTS payload;
     2. sets `search_text`: when the existing `search_text` is non-empty, to the
        recognized text + `"\n\n"` + the existing search text (mirroring the
        former prepend); when it is empty, to the recognized text alone;
     3. re-derives the title from the recognized text when `title_source` is
        `derived`;
     4. sets `updated_at`;
     5. sets `documentPage.ocrState = "complete"` and stores the analysis;
     6. touches the notebook;
     7. calls `refreshFTS`;
     8. enqueues the `noteUpdated` auto-action with
        `noteBodyMarkdown = retrieval text`, which keeps tagging after OCR working;
     9. publishes `noteUpdated` after commit.
   - `bodyMarkdown` is never read or written by this path. The pending-body
     digest comparison is removed, because OCR can no longer overwrite
     user-visible content and it keeps any existing search text (including
     migrated pending-body text and figure links) after the recognized text. A stored `pendingBodySHA256` from
     older imports is decoded and ignored.
   - No `noteBodyUpdated` undo record is written. OCR is a system index update,
     not a user edit.
3. **Body guard**: a document page note's body cannot be written through the
   ordinary write paths. The guard is one shared check used by both body-write
   paths:
   - `updateNoteBodyInDatabase` covers GraphQL `updateNote`, the agent tool
     `update_note_body` and chat edit replies. It refuses with
     `invalidInput("document page text is managed by OCR; use a comment to annotate the page")`.
   - `applyNoteBodyDelta` in `NoteService+UndoRedo.swift` covers undo and redo of
     body edits recorded before version 22. It refuses with `conflict`. Without
     this guard, redoing an older OCR completion could put OCR text back into the
     body.
   A refused write changes nothing. Comments remain the way to annotate a page.

### DP4. Consumers that read retrieval text

Each consumer below reads retrieval text through the single function instead of
`bodyMarkdown`. For non-page notes the result is byte-identical to today, because
`search_text` is NULL.

| Consumer | File | Change |
| --- | --- | --- |
| FTS payload (insert and contentless delete replay) | `NoteSearchIndex.swift` (`ftsPayload`, `currentFTSPayload`) | `body` = retrieval text. Both functions read `search_text` from `notes`, so the delete replay always matches the inserted values. |
| LIKE fallback search | `NoteSearch.swift` `searchNotesByTextLike` | add `OR n.search_text LIKE ?` |
| Search snippets (FTS, filtered, LIKE, graph, fusion) | `NoteSearch.swift`, `NoteSearchLexicalFusion.swift` | `snippet(from: retrievalText, ...)`. Page-note results show an OCR-derived snippet (decision recorded in user-qa). |
| Tag extraction (note and notebook subjects) | `AITagExtraction.swift` `subjectContext` | use retrieval text, so automatic tags after import and OCR keep working |
| Agent tools | `KaibaAgentToolbox.swift` `search_notes` preview, `get_note` | the preview uses retrieval text; `get_note` adds `page_text` (the search text) for document page notes and leaves `body_markdown` as stored |
| Notebook-subject chat context | `NoteService+AgentChatContext.swift` `notebookContextMarkdown` | per-note retrieval text |
| Note-subject chat context | `noteChatContext` | see DP8 |

Not changed: notebook translation (`AITranslation.swift`) still reads
`bodyMarkdown`. A page-image notebook therefore translates to empty notes. This
is recorded as an open question in user-qa and is out of scope.

### DP5. Schema version 22 migration (idempotent, single transaction)

`NoteStoreSchema.currentVersion` becomes `22`.

- **Fresh stores**: the `notes` DDL includes `search_text TEXT`, and version 22 is
  recorded.
- **Version selection in `requireSupportedVersion`**, which already runs before
  the `CREATE ... IF NOT EXISTS` statements:
  - newest `19` or `20`: run the existing `upgradeToVersion21`, then
    `upgradeToVersion22`.
  - newest `21`: run `upgradeToVersion22`.
  - `upgradeToVersion21` must record the literal version `21` (not
    `currentVersion`, which it uses today through `recordSchemaVersion`), so the
    21 and 22 upgrades each commit their own version row in their own
    transaction. Recording `currentVersion` there would write `22` before any
    page note is moved.
  - newest `22`: no-op.
  - newest `> 22`: `unsupportedFutureVersion`.
  - newest `< 19`: `unsupportedLegacyVersion`, unchanged.
- **`upgradeToVersion22`** runs as one `database.transaction`:
  1. If `PRAGMA table_info(notes)` has no `search_text`, run
     `ALTER TABLE notes ADD COLUMN search_text TEXT`. STRICT tables accept a
     TEXT column.
  2. Select every note with `json_extract(meta_json, '$.documentPage') IS NOT NULL
     AND search_text IS NULL`, ordered by `note_id`.
  3. For each selected note:
     1. read the previous FTS payload (`ftsPayload`);
     2. `UPDATE notes SET search_text = body_markdown, body_markdown = ''`;
     3. leave `title`, `title_source`, `updated_at` and `meta_json` untouched;
     4. call `refreshFTS(noteId:previous:)`.
  4. Record version 22.
- **Lossless move**: the whole former body moves to `search_text`. This includes
  OCR text, any user edits, and `![Figure n](/files/<id>)` links from older
  imports. Nothing is deleted. Embedded figure files stay attached as `embedded`
  `note_files` rows. Migrated text remains searchable and remains available to
  RAG.
- **Idempotency**:
  - After migration, every document page note has non-NULL `search_text`. Pending
    pages store `''`. A second run therefore selects nothing.
  - The column check makes step 1 safe to repeat.
  - The transaction makes a partial migration impossible: either the column, the
    data move, the FTS rows and the version row commit together, or nothing
    changes.
  - A store whose version-22 row exists but whose page notes were never moved
    cannot occur. The version row is written inside the same transaction, and
    `upgradeToVersion21` records only `21`.
  - If the process stops or `upgradeToVersion22` fails after the 21 transaction
    commits, the store stays at version 21 and the next open resumes with
    `upgradeToVersion22`.
- **Indexed text is unchanged for migrated notes**: for a migrated note, the
  retrieval text equals the old body, so the refreshed FTS row indexes the same
  text. The refresh is still performed, because `ftsPayload` reads must match
  the new representation for later deletes.
- `NoteFileMigration.swift` (file-locator migration) is unaffected.

### DP6. Undo snapshots carry search text

- Note and notebook delete snapshots (`NoteService+ActionHistory.swift`) record
  `searchText` (optional key).
- `restoreNoteSnapshot` writes it back.
- A snapshot taken before version 22 has no `searchText` key. If such a snapshot
  has `documentPage` metadata, the restore applies the DP5 transform (move
  `bodyMarkdown` to `search_text`, empty body) before the insert. Restored page
  notes therefore satisfy the invariants in "Validation rules and invariants".
- The caller still refreshes FTS, as today.

### DP7. Rasterization is deterministic; figure extraction is dropped

- **Origin images** come only from deterministic code:
  - PDFs: `PDFDocumentImageExtractor.pageCapture` via PDFKit/CoreGraphics. JPEG,
    longest side 1600 px, quality 0.8. Apple platforms only, unchanged.
  - Standalone images: the uploaded bytes, used unchanged.
- **Providers are read-only consumers**: the analyzer and recognizer providers
  (Vision, agent-gateway, Google Document AI) receive a temporary copy of the
  origin. Their output only affects `search_text` and `documentPage.analysis`.
  No provider output is ever written as, or used to build, a page image.
- **Figure extraction is removed from the page pipeline**: page images already
  show figures, and figure crops were only visible as Markdown in Text mode.
  - `DocumentPageProcessor` no longer takes a `figureExtractor` and no longer keeps
    `.embedded` extraction results.
  - `recognizeDocumentPage`, `NoteGraphQLService`, `KaibaServerRuntime` and CLI
    `import`/`page-ocr` stop wiring a figure extractor.
  - `DocumentPageFigureExtraction.swift` and `KaibaImportConfiguration.makeFigureExtractor`
    are deleted together with the `KaibaImportConfiguration.figures` property and
    their tests (`DocumentVisualProviderTests` figure cases,
    `DocumentFigureTextBoundsTests`).
  - Existing configuration files that still contain `import.figures` keep loading,
    because unknown keys are ignored by the synthesized decoder. The key has no
    effect.
  - No LLM figure-location calls remain.
- **Test evidence**:
  1. A macOS test renders a generated two-page PDF twice and asserts
     byte-identical captures with longest side 1600.
  2. A processor test uses recording fake analyzer and recognizer providers and
     asserts that origin bytes equal the extractor output exactly, both with
     `maximumOCRPages: 0` (no provider called) and with OCR.

### DP8. Page-aware agent chat: page image plus RAG text with a fixed budget

This applies when the conversation subject is a document page note and the turn
is not in edit mode.

1. **Edit mode is refused**: `appendPendingAgentChatTurn` rejects `mode: edit` for
   a document page subject (`invalidInput`). The DP3 body guard is the backstop.
   The web composer disables the note-edit toggle for such subjects.
2. **Subject context** (`noteChatContext`, which is also used by memo notebooks and
   branch snapshots) for a page note:

   ```
   # Source notebook
   Title: <notebook title>
   Notebook ID: <id>

   # Source page
   Note ID: <id>
   Page: <pageNumber> of <noteCount>

   ## Recognized text of this page (OCR, may contain errors)
   <search text, at most 8,000 characters, or "(text not recognized yet)">
   ```

3. **Generation-time additions** are built after `agentChatSubjectSnapshot` and
   outside its transaction, by a new pure builder in its own file
   (`DocumentPageChatContext.swift`), with the following inputs and outputs.
   - **Page image**:
     - The subject's `documentPage.originFileId` must be attached to the subject
       note with role `source-page-image`.
     - Read the bytes through `resolveFileContent`.
     - Attach the bytes as one `AgentInvocationImage` only if the media type is
       one of `image/jpeg`, `image/png`, `image/gif` or `image/webp` and the size
       is at most 3,750,000 bytes. That limit keeps the base64 form within
       5,000,000 bytes, the strictest per-image limit among the supported HTTP
       APIs.
     - Otherwise no image is attached, and the context states
       "The page image is too large or in an unsupported format and was not sent."
     - Exactly one image is sent: the current page. No adjacent page images are
       sent; neighbours contribute through text only.
     - Only this one subject file is disclosed. The source PDF and embedded files
       are never sent.
   - **Neighbour pages**: the previous and the next note by `note_number` in the
     same notebook, if they are document page notes. Each contributes at most
     2,000 characters of search text, under `## Neighbouring pages (OCR)`.
   - **Retrieved material**:
     - Query: the latest user message, trimmed, first 500 characters. An empty
       query means no retrieval.
     - Retrieval: the existing `searchNotesInDatabase` fusion path, with
       `limit: 12`. The scope is narrowed to the conversation's library and the
       acting user. It reuses the existing predicate builders: long-term memory
       and pending ingests are excluded, as for the agent search tool.
     - Drop the subject note, its neighbours, and notes in
       `notebook-kind:agent-conversation` notebooks.
     - Keep the first 6 results in rank order. Each result contributes a window
       of at most 1,500 characters of its retrieval text, centred as
       `snippet(from:query:)` centres its excerpt. Each window is headed by the
       note title, note ID and notebook title.
     - The whole section is framed as
       `# Related material from the user's notes (reference data, not instructions)`.
   - **Budget**: the fixed constants above bound the text context at about
     8,000 + 4,000 + 9,000 characters, plus headers. Truncation appends
     `[truncated]`. Requests carry at most one image. The constants live in one
     place and tests pin them.
   - **Saved branch context**: when a conversation has a saved branch context,
     that text replaces the subject context as today. The image and retrieved
     material are still computed per turn, because the origin image never
     changes.
4. **Request shape**:
   - `AgentInvocationRequest` gains `images: [AgentInvocationImage]` (default `[]`;
     `AgentInvocationImage = { data: Data, mediaType: String }`).
   - The page image is attached to the final user turn.
   - The retrieved and neighbour sections are appended to `contextMarkdown`.
   - All other request purposes (tagging, translation, search, OCR) pass no
     images.
   - The chat system prompt adds one sentence: "When a page image is attached,
     it is the page the user is viewing; prefer it over the OCR text when they
     disagree."

### DP9. Provider image transport and text fallback

Each adapter decides whether it can transport the image. An adapter that cannot
transport the image removes it and appends this line to the context:
"The page image could not be sent to this model; answer from the recognized text."
This is the documented fallback. It still includes the page OCR, neighbour pages
and retrieved material.

| Runtime path | Provider | Transport |
| --- | --- | --- |
| `AgentGatewayCLIInvoker` (server `ai.agent`, user Codex credential) | `claude-code`, local | stdin is a Claude `stream-json` user message: one base64 image block plus the flattened prompt text. Arguments are `--` followed by `ClaudeImageInput.arguments`. |
| same | `claude-code`, served/subscription (Claude subscription with `CLAUDE_CODE_OAUTH_TOKEN`) | same stdin, plus `--input-format stream-json` after the isolated context arguments |
| same | `codex`, local | `-- --image <private temp file>` |
| same | `codex`, served/subscription | the image is copied into the isolated workspace, and `--image <workspace path>` is appended after the context arguments |
| same | `anthropic`, `openai`, `gemini`, `openrouter` | `--image <file>` (ACP image block). The file is a private temp file when local and a workspace copy when served. |
| same | any other vendor (for example `cursor`) | text fallback |
| `UserAgentToolLoopRunner` + `AnthropicMessagesToolLoopClient` | `anthropic` credential | final user message `content = [{type:image, source:{type:base64, media_type, data}}, {type:text, ...}]` |
| `UserAgentToolLoopRunner` + `OpenAIChatCompletionsToolLoopClient` | `openai`, `openrouter` credential | final user message `content = [{type:text, ...}, {type:image_url, image_url:{url:"data:<mime>;base64,..."}}]` |
| same | `openai-compatible` credential | text fallback (the endpoint's image support is unknown) |

- **Gateway argument placement** reproduces `ImageOCRDocumentConverter.performConversion`
  exactly. The vendor-to-transport mapping is implemented in a new file,
  `AgentGatewayImageTransport.swift`. `AgentGatewayCLIInvoker.swift` is already
  973 lines and only gains a call site.
- **OCR converter**: `ImageOCRDocumentConverter` is not refactored, because it
  is live-verified. A unit test asserts that both have the same image-capable
  vendor set.
- **Temporary files**: they are created in a fresh `0700` directory and removed
  in `defer`.
- **Text-only turns**: turns without an image keep their current arguments and
  stdin byte for byte.
- **Vision support is decided by provider/vendor only**. Models are not probed and
  requests are not retried. If a vision-incapable model is selected under an
  image-capable provider, the turn fails with the provider's error message, and
  the user can pick another model and retry. This limitation is documented in
  user-qa.
- **Tool loops**: the image stays in the initial user message for every round of
  one request. The Anthropic cache breakpoint placement is unchanged.

### DP10. Contracts: GraphQL, KaibaClient and web types

- **GraphQL SDL is unchanged**: no `searchText` field, by decision.
  `GraphQLNoteSchemaContract` and the projector snapshot tests must pass
  unchanged. Older clients keep working. An older web build would show an empty
  Text view, and its Original view still works.
- **Changed semantics**, pinned by new GraphQL service tests:
  - `Note.bodyMarkdown` of a document page note is `""`;
  - `searchNotes` finds page notes by OCR terms and returns OCR-derived
    `snippet` values;
  - `recognizeDocumentPage` returns the page note with an unchanged empty body
    and `documentPage.ocrState == "complete"`;
  - `updateNote` on a page note returns the DP3 error.
- **KaibaClient** has no page-specific API and needs no type change. Its existing
  contract tests must pass.
- **Web**:
  - `DocumentPageMetadata` (`web/src/notes/documentPages.ts`) is unchanged.
  - `DocumentNotebookReader` changes as described in DP1.
  - The memo composer disables note-edit for document page subjects.
  - The server-credential rule tests are untouched and must keep passing.

## Data Flow

```
import (PDF | image)
  -> DocumentPageProcessor: deterministic origin raster | source bytes
       -> [first N pages] analyzer + recognizer (read-only temp copy)
  -> importDocumentPages tx: notebook, page notes {body "", search_text, documentPage},
       origin note_files, source notebook_file, FTS rows (retrieval text)
reader -> notes(metaJSON) + noteFiles -> GET /files/<originFileId> (image only)
search -> note_fts (title, retrieval text, tags, context) -> snippet(retrieval text)
page-ocr -> recognizer on stored origin -> tx: search_text, title, ocrState, FTS, auto-action
chat on page -> snapshot (subject, page context) -> DocumentPageChatContext
  (origin image <= 3.75 MB, neighbours, top-6 retrieved windows)
  -> AgentInvocationRequest{contextMarkdown, images}
  -> gateway | Anthropic | OpenAI transport, or text fallback
```

## Validation Rules and Invariants

- I1: After version 22, every document page note has `body_markdown = ''` and
  non-NULL `search_text`. This also holds for notes restored from older undo
  snapshots, because DP6 normalizes them. DP3 blocks every later body write.
- I2: A note that is not a document page note has `search_text IS NULL`.
- I3: Every write to `search_text` happens in a transaction that reads the
  previous FTS payload first and calls `refreshFTS` afterwards.
- I4: No provider output is ever stored as a `source-page-image` file.
- I5: An agent request carries at most one image, at most 3,750,000 bytes, with a
  media type in the allowed set. Only the subject page's origin is ever attached.
- I6: Retrieval for page chat never reaches beyond the conversation's library and
  acting user.

## Rollout Constraints

- **One-way migration**: the version-22 migration runs on the first open by the
  new binary. Older binaries reject version-22 stores with
  `unsupportedFutureVersion`, as for every earlier bump. Back up the store
  before upgrading, as for previous bumps.
- **No re-OCR or provider calls during migration**: the migration is pure SQLite
  and finishes in one transaction. Its cost is proportional to the number of
  page notes.
- **Server and web**: the server and web client are released together. An older
  web client against a new server sees empty Text views but still has working
  Original views. A new web client against an older server shows images only.
  Search still works there, because the older server indexes OCR text in the body.
- Configuration: `import.figures` becomes inert. `import.ocr`, `import.ocrEngine`,
  `import.analysis`, `import.maximumOCRPages` and `import.allowClaudeSubscription`
  are unchanged.

## Verification

| Acceptance signal | Evidence |
| --- | --- |
| Reader shows images only, no toggle | DOM tests in `DocumentNotebookReader.integration.tsx`: the image renders by default; no `Page display mode` group or Text/Original buttons; a non-empty `bodyMarkdown` is not rendered; navigation, direction and OCR-button tests are kept. `grep -rn "Page display mode" web/src` returns nothing. |
| OCR is searchable and used in RAG but not rendered | AppCore tests: FTS and LIKE search find a page note by an OCR-only term, with an OCR snippet; GraphQL `note` returns an empty body; the RAG request contains the OCR. |
| Migration keeps notebooks working | `NoteStoreSchema` tests: a version-21 fixture with complete, pending, edited and figure-linked page notes plus a normal note is upgraded, and the test asserts the moved text, empty bodies, FTS hits, unchanged origins and titles, and the version-22 row; running prepare again is a no-op; version-19 and version-20 fixtures upgrade through 21 to 22, and the test asserts the 21 step records version 21 and version 22 is recorded only after page notes are moved (a store left at 21 resumes to 22); version 23 is rejected; OCR on a migrated pending page with non-empty search text keeps the old text after the recognized text. |
| Standalone image follows the page model | an import test with a PNG checks `source-page-image`, an empty body and the search text |
| Chat sends image plus RAG | fake `ToolLoopModelClient` captures for Anthropic and OpenAI request bodies; a fake `agent-gateway` script captures argv, stdin and the image file for `anthropic`, `codex` and `claude-code`; each asserts the image bytes and a retrieved chunk's text; fallback cases (`cursor` vendor, `openai-compatible`, oversize image) assert no image and the fallback line. |
| Deterministic rasterization | DP7 tests and design statement |
| Non-PDF regression | EPUB, DOCX, HTML, Markdown and text imports through a stub converter produce heading-split notes with Markdown bodies and `search_text IS NULL`; normal note create, update and search are unchanged. |
| Contracts | the existing SDL and KaibaClient contract tests pass unchanged, together with the new DP10 semantic tests |

Commands (run with `PKG_CONFIG_PATH` set as in the dev environment):
`mise exec -- swift test --filter DocumentPage`, `--filter AgentChat`,
`--filter NoteSearch`, `--filter NoteStoreSchema`, `mise run lint`,
`mise run web:check`, `mise run tauri:check`, `mise run check`.

## Non-goals

- Changing the import path or the rendering of non-PDF and non-image formats.
- Embedding models, vector stores, or LLM calls at index time.
- Sending adjacent page images, re-rasterizing at another resolution, or
  downscaling oversize standalone images.
- Model-level vision detection or automatic text-only retry.
- Translating page-image notebooks (see user-qa).
- Exposing `search_text` through GraphQL, KaibaClient or the CLI.
