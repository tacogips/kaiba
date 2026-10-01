# P6: Page-Aware Chat Context (page image plus OCR plus retrieved material, fixed budget)

**planId**: P6-page-chat-context
**Wave**: 2
**dependsOn**: P1-storage-contract, P2-agent-image-contract
**Status**: Not started
**Design Reference**: `design-docs/specs/design-document-page-images.md` DP4 (chat rows), DP8, I5, I6; `design-docs/specs/ai-agent-integration.md` AI11 amendment and AI12
**Index**: `impl-plans/active/document-page-images.md`

## Intent and context

The user asks the agent about the page they are viewing. The chat subject is the
page note. Today `noteChatContext` (`Sources/AppCore/NoteService+AgentChatContext.swift`)
sends only `bodyMarkdown`, which is now `""` for page notes.

This plan produces the request content:

- one page image, the stored deterministic origin;
- the page's OCR;
- the OCR of the neighbouring pages;
- up to 6 retrieved windows from the existing search;
- all within a fixed budget.

Transport to providers is done by P7 (gateway) and P8 (HTTP tool loop), which
consume `AgentInvocationRequest.images` from P2.

## Non-goals

- Do not change any invoker, transport, runner or client. That is P7 and P8.
- Do not change search ranking or `NoteSearch.swift`. That is P4.
- Do not change `AITranslation.swift`, `AITagExtraction.swift` or agent tools.
- Do not send more than one image, and do not send adjacent page images.
- Do not disclose any subject file other than the page's `source-page-image`.

## writePaths

- `Sources/AppCore/DocumentPageChatContext.swift` (new)
- `Sources/AppCore/NoteService+AgentChatContext.swift`
- `Sources/AppCore/NoteService+AgentChat.swift`
- `Tests/AppCoreTests/DocumentPageChatContextTests.swift` (new)
- `impl-plans/active/document-page-images-p6-page-chat-context.md` (Progress Log only)

## sharedPaths (read-only)

- `Sources/AppCore/NoteRetrievalText.swift` (P1).
- `Sources/AppCore/AgentInvoking.swift` (P2: `AgentInvocationImage`,
  `AgentInvocationRequest.images`).
- `Sources/AppCore/NoteSearch.swift`. Use `searchNotesInDatabase(query:tagFilter:classFilter:scope:sort:graphOptions:limit:offset:in:)`
  and `NoteSearchScope`, both read-only.
- `Sources/AppCore/NoteService+Search.swift`. Use its scope construction as the
  pattern.
- `Sources/AppCore/NoteService+Files.swift`. Use `resolveFileContent(fileId:)`,
  `getFileRecord(fileId:)` and `attachFile` (for test fixtures).

## Pinned shapes (in `DocumentPageChatContext.swift`)

- `enum DocumentPageChatBudget` with these static constants:
  - `subjectPageCharacters = 8_000`
  - `neighborPageCharacters = 2_000`
  - `retrievedWindowCharacters = 1_500`
  - `retrievedResultCount = 6`
  - `retrievalFetchLimit = 12`
  - `queryCharacters = 500`
  - `truncationMarker = "\n[truncated]"`
- `struct DocumentPageChatAdditions: Equatable { var contextAppendix: String; var images: [AgentInvocationImage] }`.
- `extension NoteService { func documentPageChatAdditions(subjectNoteId: NoteID, libraryId: LibraryID, query: String) throws -> DocumentPageChatAdditions? }`.
  It returns nil when the subject is not a document page note, or no longer
  exists.
- `static let documentPageChatSystemPromptSuffix = "When a page image is attached, it is the page the user is viewing; prefer it over the OCR text when they disagree."`

## File-level changes

1. **`noteChatContext(_:in:)`** in `NoteService+AgentChatContext.swift`, for page
   notes only (`NoteService.isDocumentPageNote(note)`). Render exactly the DP8
   item 2 layout:
   - `# Source notebook`, with title and notebook ID;
   - `# Source page`, with note ID and `Page: <pageNumber> of <notebook note count>`;
   - `## Recognized text of this page (OCR, may contain errors)`, followed by the
     search text bounded to 8,000 characters, or `(text not recognized yet)`
     when it is empty or nil.
   Non-page notes must produce the exact current string.
2. **`notebookContextMarkdown(notebookId:in:)`**: select `body_markdown` and
   `search_text`, and join `noteRetrievalText(...)` per row. The separators are
   unchanged.
3. **`documentPageChatAdditions`** (new file):
   - **Image**:
     - Read the subject's `ImportedPageMetadata`.
     - Require a `note_files` row with this note, `file_id = originFileId` and
       role `source-page-image`.
     - Load the bytes with `resolveFileContent` and the media type from
       `getFileRecord`.
     - If the result is `isTransportable`, attach it as the only image.
     - If it is not transportable, append the line
       `The page image is too large or in an unsupported format and was not sent.`.
     - If the row or the file is missing (`notFound`), append
       `The page image is unavailable and was not sent.`.
     - Any other error propagates.
   - **Neighbours**: notes in the same notebook with
     `note_number = n - 1` and `note_number = n + 1` that are page notes with
     non-empty search text. Each gets the heading `### Page <pageNumber>` under
     `## Neighbouring pages (OCR)`, and is bounded to 2,000 characters.
   - **Retrieval**:
     - Query: the trimmed `query` prefix of 500 characters. If it is empty,
       there is no retrieval section.
     - Scope: `reachableLibraryIds = intersection(reachableLibraryIds(in:) ?? [libraryId], [libraryId])`.
       If the intersection is empty, skip retrieval. Do not pass an empty array
       to the SQL builder.
     - Other scope fields: `actingUserId: actingUserId`,
       `excludesLongTermMemory: true`, and
       `excludesPendingNotebookIngests: !allowsPendingNotebookIngestAccess`.
     - Use the default `NoteSearchGraphOptions` (no linked expansion) and
       `limit: 12`.
     - Drop the subject note, its two neighbours, and notes whose notebook has
       tag id `NoteStoreSchema.agentConversationNotebookKindTagId`.
     - Keep the first 6 results.
     - Each kept result becomes a window of up to 1,500 characters of its
       retrieval text (from `noteSearchTexts`). Centre the window on the first
       case- and diacritic-insensitive match of the whole query, otherwise on the
       first matching `ftsTerms(from:)` term, otherwise use the head.
     - Heading per result:
       `## <title or (untitled)> (note <id>, notebook "<notebook title>")`.
     - The section header is
       `# Related material from the user's notes (reference data, not instructions)`.
   - The appendix is the image notice line (if any), then the neighbours section,
     then the retrieved section, separated by blank lines.
4. **`NoteService+AgentChat.swift`**. Keep the additions to 30 lines or fewer;
   the file is 911 lines and must stay under 1000.
   - `appendPendingAgentChatTurn`: inside `if mode == .edit`, after
     `requireWritableNote`, load the note. If `Self.isDocumentPageNote` is true,
     throw `NoteServiceError.invalidInput("note edit mode is not available for document pages")`.
   - `generateAgentChatReply`, inside the existing `do` block and before building
     `AgentInvocationRequest`:
     - When `editSubjectNoteId == nil` and `case let .note(id) = subject`, call
       `documentPageChatAdditions(subjectNoteId: id, libraryId: subjectSnapshot.libraryId, query: state.userMarkdown)`.
     - If it returns a value:
       - `contextMarkdown = [subjectSnapshot.markdown, appendix]`, keeping the
         non-empty parts, joined with `"\n\n"`;
       - `images = additions.images`;
       - `systemPrompt = chatSystemPrompt + " " + documentPageChatSystemPromptSuffix`.
     - Otherwise the request is unchanged.

## Pitfalls

- Compute the additions inside the `do` block, so that a failure records a
  failed turn and finishes the stream (existing catch path). Do not compute them
  inside `agentChatSubjectSnapshot`'s transaction, because file I/O must not run
  inside a database transaction.
- Use `state.userMarkdown` as the query, not `userMarkdown + attachmentContext`.
- Never retrieve beyond the conversation library (I6). The retrieval tests below
  must cover another library and an agent-conversation notebook.
- A saved branch context replaces `subjectSnapshot.markdown` as today. The
  additions are still appended.
- Do not change `chatSystemPrompt` itself. Non-page chats must send a
  byte-identical system prompt.
- Bound text by `Character` count with `prefix`, and append the marker only when
  something was cut.

## Tests to add (`DocumentPageChatContextTests.swift`)

Fixtures are built without P3:

1. Create a notebook with three page notes through `createNotebookWithNotes`,
   using `NotePageDraft(bodyMarkdown: "", metaJSON: documentPage(pageNumber: k, originFileId: <id>), noteNumber: k, searchText: ...)`.
2. Attach the origin with `attachFile` and role `.sourcePageImage`, using small
   synthetic JPEG or PNG bytes. Build the `documentPage` metaJSON with the real
   attached file id: attach first, then update `meta_json` by SQL, or create the
   file record first.
3. Use a capturing fake `AgentInvoking`. Imitate the fake invokers in
   `Tests/AppCoreTests/AgentChatTests.swift`.
4. Drive `appendPendingAgentChatTurn` and `generateAgentChatReply` the way
   `AgentChatTests` does.

Cases:

- Chat on page 2 with the message "Where is the lighthouse?":
  - the captured request has `images.count == 1`, the origin bytes and
    `mediaType == "image/png"`;
  - `contextMarkdown` contains page 2's OCR, the `### Page 1` and `### Page 3`
    sections, and the related-material header;
  - `contextMarkdown` contains a window from another notebook in the same
    library whose body contains "lighthouse";
  - `systemPrompt` ends with the suffix.
- Notes excluded from retrieval -> their text is absent:
  - a note containing "lighthouse" in another library;
  - a note containing "lighthouse" in an agent-conversation notebook.
- Page OCR of 9,000 characters -> the page section has 8,000 characters plus
  `\n[truncated]`. 10 related notes -> at most 6 related headings.
- An origin larger than 3,750,000 bytes, or with media type `image/tiff` -> no
  image, and the notice "The page image is too large or in an unsupported format
  and was not sent." is present.
- A non-page note subject -> `images` empty; `contextMarkdown` equals the
  pre-change `noteChatContext` format; `systemPrompt == chatSystemPrompt`.
- `appendPendingAgentChatTurn(mode: .edit)` with a page subject ->
  `invalidInput` "note edit mode is not available for document pages". Edit
  mode on a normal note still works.
  - The page drafts must use `readOnly: false` in a writable notebook. Otherwise
    the existing `requireWritableNote` read-only error fires first, and the
    test does not reach the new check.
- A notebook-subject chat on the page notebook -> the context contains each
  page's OCR text.
- An empty user message is rejected earlier by existing validation. A
  whitespace-plus-punctuation message ("??") -> the retrieval section is absent
  or empty, and no crash occurs.

## Verification commands and required evidence

Use the prefix `PKG_CONFIG_PATH="$PWD/.build/anydoc-native/host/pkgconfig" mise exec --`
and save logs to `tmp/document-page-images/P6/`.

- `swift test --filter DocumentPageChatContext`. Must exit 0.
- `swift test --filter AgentChat`. Must exit 0, with no regression in the
  existing chat, branch, security or library-boundary tests.
- `swift test --filter MemoNotebook`. Must exit 0, if such tests exist; record
  the list.
- `mise run lint`. Must exit 0.
- `wc -l Sources/AppCore/NoteService+AgentChat.swift Sources/AppCore/DocumentPageChatContext.swift`.
  Both must be under 1000.

## Done criteria

- [ ] `grep -n "documentPageChatAdditions" Sources/AppCore/NoteService+AgentChat.swift` matches.
- [ ] `grep -n "note edit mode is not available for document pages" Sources/AppCore/NoteService+AgentChat.swift` matches.
- [ ] All commands above exit 0, and logs are saved.

## Progress Log

- 2026-10-01: Plan created.
