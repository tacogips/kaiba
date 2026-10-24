# Selected page regions, chat search, and connection tabs

The original-page viewer has a bottom-right region-selection control. The user arms it, drags a rectangle over the visible PDF or image, and receives an image attachment in the current page's footer discussion. Page coordinates account for scrolling, zoom and canvas device pixels. Selection cancels on Escape, navigation or rerender; tiny selections do not attach. The crop is bounded to 1600 pixels on its longest side and the existing 1 MiB chat attachment limit. It remains in the session draft until the user sends a question. Existing draft text is preserved, and a busy or retrying submission cannot be changed underneath a send.

Chat accepts validated PNG/JPEG image attachments alongside text files. Sent images are saved with the conversation turn and supplied through the existing provider image input; PDF imports still retain only the original PDF rather than generating stored page images. Chat questions and answers are database notes. Their initial write and subsequent reply update both refresh local full-text search and enqueue durable search-engine synchronization. Analysis offers a notebook-scoped rebuild covering its pages and recursively anchored AI conversations, including branches. The result distinguishes a local rebuild from a queued external-engine refresh.

The footer uses less space above the composer and around Suggestions. Its text input starts at 76 pixels, while longer drafts continue to grow up to the existing cap.

The right pane separates saved Links, Similar text, Same topic (shared tags), and Related topics (tag hierarchy/ontology). Suggestions identify their tag evidence; a related result can identify a destination tag and the ancestor it matched through. Current-page tags remain editable in the header. Semantic document-level tags appear separately with a Document marker, and an untagged page says No page tags. System bookkeeping tags are not presented as user topic tags. A page without tags may still appear in Similar through text similarity.

Home is the Markdown notebook editor. The Create and import menu opens document import as a modal popup, and also exposes Markdown notebook and note creation. Inside the popup, file selection comes first; Import options contain the optional Name in Kaiba override, explain the filename default, and retain extraction policy and OCR-budget overrides.

## Validation

The native browser verified a PDF-region drag opening page-scoped AI chat with a 47 KB PNG attachment. The temporary attachment was removed without sending a message. The compact footer, explicit untagged-page label, separate connection tabs, and simplified Home import screen were inspected visually. Analysis rebuilt the public test notebook's 25 pages; the local Meilisearch instance then reported available, activated, pending 0, failing 0.

Completed commands:

```sh
mise exec -- swift test -j 4 --filter 'ChatImageAndReindex|NotebookReindexGraphQLTests|AgentChatTests|AgentChatBranchTests|AgentChatGraphQLTests|SchemaInventory|SearchEngineOntology|SearchIndexSynchronizer'
mise run lint
mise run web:check
mise run tauri:check
git diff --check
```

Results: 83 focused Swift tests passed; 187 Bun tests and 150 web integration tests passed, together with TypeScript, ESLint and the production build. SwiftLint reports only two pre-existing large-tuple warnings. Tests cover provider image bytes and follow-up context, chat question/reply persistence and search indexing, scoped rebuild authorization and nested conversations, actual related-tag evidence, selection geometry/cancellation, draft staging, and separated recommendation categories. No live AI provider request was sent.

The existing test store uses schema 24. Preview runs from `tmp/ui-preview-compat` (compatible revision plus these UI/server feature changes), because the concurrent schema-25 work deliberately rejects existing older stores. The existing PDFs and note identities are preserved. The compatible server build used `mise exec -- swift build -j 4 --product kaiba`; its web build used `mise exec -- bun run build`. Source changes remain in the primary workspace; the preview checkout is an isolated runtime accommodation.


## Menu import and Markdown creation follow-up

Document import was removed from Home and moved to a modal opened from Create and import → Import PDF or image. The popup preserves the current route until import succeeds, respects the configured extraction default, restores focus when closed, and supports Escape and keyboard focus containment. Home retains the Markdown editor; creating a new notebook derives its name from the first heading. Adding a note preserves Markdown verbatim.

Browser verification created a temporary Markdown notebook and a second note, verified headings, emphasis, lists, quotes and code blocks, then reloaded the selected note. API reads confirmed exact Markdown bodies and writable notebook/notes. Both local SQLite search and live Meilisearch found the unique test content. The temporary notebook and its notes were then deleted. Evidence is in `tmp/pdf-validation-20261024/markdown-creation-check.json`.

`mise run web:check` passed with 187 Bun tests and 153 integration tests, TypeScript, ESLint and the production build. `mise run tauri:check` and `git diff --check` passed. Popup lifecycle, import defaults, Markdown note submission, and the absence of import controls on Home have regression coverage.
