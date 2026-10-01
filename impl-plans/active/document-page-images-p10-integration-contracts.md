# P10: Integration, Contract and Regression Tests; Serial Reconciliation

**planId**: P10-integration-contracts
**Wave**: 3
**dependsOn**: P3-import-ocr-pipeline, P4-retrieval-consumers, P5-undo-snapshots, P6-page-chat-context, P7-gateway-image-transport, P8-toolloop-image-transport, P9-web-reader
**Status**: Not started
**Design Reference**: `design-docs/specs/design-document-page-images.md` Verification table, DP10, Scope (non-PDF regression); `design-docs/specs/ai-agent-integration.md` AI12
**Index**: `impl-plans/active/document-page-images.md`

## Intent and context

The wave-2 plans each verify their own slice. This plan proves the end-to-end
acceptance signals that span slices:

- importing a PDF page and chatting on it sends the page image plus retrieved
  OCR through each provider path (Anthropic Messages, OpenAI chat completions and
  agent-gateway), with a text fallback;
- the GraphQL contract semantics (DP10) hold;
- non-PDF imports are unchanged;
- the full `mise run check` passes.

This plan is also the only serial reconciliation point for cross-plan breaks.

## Non-goals

- Do not add new behaviour or redesign anything.
- Fix only integration breaks between already-implemented plans, and record each
  fix in this Progress Log with its file, cause and hash.
- Do not change the GraphQL SDL, KaibaClient types or web types. DP10 requires
  them unchanged.
- Do not commit, push or archive plans. Workflow finalization owns those steps.

## writePaths

- `Tests/AppCoreTests/DocumentPageAgentChatProviderTests.swift` (new)
- `Tests/AppCoreTests/DocumentImportFormatRegressionTests.swift` (new)
- `Tests/AppGraphQLTests/DocumentPageContractGraphQLTests.swift` (new)
- `Tests/AppCoreTests/DocumentAutoTaggingTests.swift`
- `impl-plans/active/document-page-images.md` (status and Progress Log only)
- `impl-plans/active/document-page-images-p10-integration-contracts.md` (Progress Log only)

## sharedPaths (serial integration repairs only)

- `Sources/AppCore`
- `Sources/AppGraphQL`
- `Sources/AppServer`
- `Tests/AppCoreTests`
- `Tests/AppGraphQLTests`
- `web/src`

sharedPathNotes:

- `Sources/AppCore`: edit only to repair a compile or test break caused by two
  plans' interaction. Do it after re-reading the owning plan, and record the
  pre/post hash in the P10 log.
- `Sources/AppGraphQL`: same rule. The SDL in `GraphQLContractProjector.swift`
  and `GraphQLNoteSchemaContract.swift` must not change.
- `Sources/AppServer`: same rule. The only expected integration point is
  `KaibaServerRuntime` provider wiring.
- `Tests/AppCoreTests`: repair existing tests only when a cross-plan behaviour
  change makes an assertion stale. Keep the original test intent.
- `Tests/AppGraphQLTests`: same rule as `Tests/AppCoreTests`.
- `web/src`: repair only if `mise run web:check` fails because of P9
  integration. Never touch the server-credential rule tests' expectations.

## File-level changes

1. **`DocumentPageAgentChatProviderTests.swift`**:
   - Fixture: a real `importDocumentPages` of a 3-page source, using a fake
     `DocumentImageExtracting` that returns synthetic PNG page captures and a
     fake recognizer that returns "Page k text about lighthouse beacons" for
     k = 1..3. Imitate the fakes in `Tests/AppCoreTests/DocumentPageImportTests.swift`.
   - Add a normal note in the same library with body "Lighthouse maintenance log".
   - Start a chat on page 2 with the message "lighthouse".
   - Run `generateAgentChatReply` with each runtime below:
     1. `UserAgentToolLoopRunner(client: CapturingClient, ..., supportsImageInput: true)`.
        Encode the captured `ToolLoopModelRequest` with
        `AnthropicMessagesToolLoopClient.requestBody` -> the JSON has an image
        block whose base64 equals page 2's origin bytes, and the system text
        contains "Lighthouse maintenance log" and "Page 2 text".
     2. The same runtime, encoded with `OpenAIChatCompletionsToolLoopClient.requestBody`
        -> an `image_url` data URL with the page-2 origin base64, and the same
        RAG text.
     3. `AgentGatewayCLIInvoker` with a fake gateway script (reuse the P7 test
        helper pattern) for vendors `anthropic`, `codex` and `claude-code`, local
        mode -> the captured image bytes (or, for `claude-code`, the stream-json
        base64) equal the origin, and the stdin text contains
        "Lighthouse maintenance log".
     4. Fallbacks: gateway vendor `cursor`, and the runner with
        `supportsImageInput: false` -> no image, and the request contains
        `AgentInvocationRequest.imageFallbackNotice` plus "Lighthouse maintenance
        log".
   - Each case also asserts that the turn completed as answered.
2. **`DocumentImportFormatRegressionTests.swift`**:
   - For each of `epub`, `docx`, `html`, `md` and `txt`, call
     `importDocument(...)` (the heading-split path) with a stub converter that
     returns `"# Chapter One\n\nAlpha body\n\n# Chapter Two\n\nBeta body"`. Imitate
     the stub converter in `Tests/AppCoreTests/DocumentImportTests.swift`.
   - Assert:
     - two notes with Markdown bodies containing "Alpha body" and "Beta body";
     - `search_text IS NULL` for both;
     - no `documentPage` metadata;
     - `updateNoteBody` succeeds on them;
     - `searchNotes("Alpha")` finds the first note with snippet "Alpha body".
   - Also check that a normal `createNote` -> `updateNoteBody` -> search
     round-trip is unchanged.
3. **`DocumentPageContractGraphQLTests.swift`**. Imitate the executor fixtures in
   `Tests/AppGraphQLTests/DocumentPageOCRGraphQLTests.swift`.
   - Query `note(noteId:) { bodyMarkdown metaJSON }` for an imported page ->
     `bodyMarkdown == ""`, and `metaJSON` does not contain the OCR text.
   - `searchNotes(query: "beacons")` -> the page note is returned, and `snippet`
     contains "beacons".
   - `updateNote` on the page note -> a GraphQL error whose message contains
     "document page text is managed by OCR".
     - Imported notebooks are created read-only (`notebookReadOnly: true` in
       `importDocumentPages`). First make the notebook writable through the
       existing notebook read-only mutation or service call. Otherwise the error
       is the existing read-only error.
   - `recognizeDocumentPage` on a pending page -> the payload note has
     `bodyMarkdown == ""` and `documentPage.ocrState == "complete"`.
   - The existing `NoteGraphQLSchemaInventoryTests` must pass unchanged. That
     proves the SDL is unchanged.
4. **`DocumentAutoTaggingTests.swift`**:
   - Update the assertion at about line 77, which compares the body with
     "Recognized graph algorithms". It now expects body `""` and that text in
     `search_text`.
   - Keep the line-51 assertion that the tagging request contains "Recognized
     graph algorithms". It must pass because of P4.
5. **Index update**: in `impl-plans/active/document-page-images.md`, set the
   status to "Implemented, verification passed" only after every command below
   exits 0, and append a Progress Log entry that lists the evidence log paths.

## Pitfalls

- Do not weaken assertions to make tests pass. If an end-to-end assertion fails,
  find the owning plan's code, fix it serially, and log the fix.
- The fake gateway must not need network access or real credentials. Do not read
  `ANTHROPIC_API_KEY` or any real key. Use synthetic image bytes only.
- Use no downloaded PDFs and no real recognized text.

## Verification commands and required evidence

Use the prefix `PKG_CONFIG_PATH="$PWD/.build/anydoc-native/host/pkgconfig" mise exec --`
and save logs to `tmp/document-page-images/P10/`.

- `swift test --filter DocumentPageAgentChatProvider`. Must exit 0.
- `swift test --filter DocumentImportFormatRegression`. Must exit 0.
- `swift test --filter DocumentPageContractGraphQL`. Must exit 0.
- `swift test --filter DocumentAutoTagging`. Must exit 0.
- `swift test --filter DocumentPage`. Must exit 0.
- `swift test --filter AgentChat`. Must exit 0.
- `swift test --filter NoteSearch`. Must exit 0.
- `swift test --filter NoteStoreSchema`. Must exit 0.
- `swift test --filter NoteGraphQLSchemaInventory`. Must exit 0.
- `swift test --filter KaibaClient`. Must exit 0. The SDK contract is unchanged.
- `mise run lint`. Must exit 0.
- `mise run web:check`. Must exit 0, including the server-credential rule tests.
- `mise run tauri:check`. Must exit 0 on macOS.
- `PKG_CONFIG_PATH="$PWD/.build/anydoc-native/host/pkgconfig" mise run check 2>&1 | tee tmp/document-page-images/P10/full-check.log; echo "exit=${PIPESTATUS[0]}"`.
  Must exit 0. Record the XCTest, Swift Testing, Bun and DOM counts from the log.
- `grep -rn "Page display mode" web/src`. Must print nothing.
- `find Sources -name '*.swift' -exec wc -l {} + | sort -n | tail -5`. No file
  may reach 1000 lines.
- `git status --short`. Must show no `.riela/` change and only files listed in
  the plans' `writePaths`, plus any reconciliation repairs, each of which is
  logged.
- `git diff --check`. Must exit 0.

## Done criteria

- [ ] Every command above exits 0, and its log path is recorded in this Progress Log.
- [ ] The index status is updated, with evidence paths.
- [ ] Any reconciliation repairs are listed with the file, the reason and pre/post hashes.

## Progress Log

- 2026-10-01: Plan created.
