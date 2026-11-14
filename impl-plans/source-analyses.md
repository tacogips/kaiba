# Reusable source analyses implementation plan

1. Completed: define the analysis workflow and its integration with existing kaiba capabilities.
2. Completed: implement built-in analysis templates and defensive custom-template persistence.
3. Completed: add a document-notebook panel with paginated source selection and batch submission
   through existing note-scoped agent conversations; preserve provider/model choice.
4. Completed: expose per-source submission status and durable result navigation; stop additional
   submissions on unmount and retain partial successes.
5. Completed: add behavior tests, run web and Tauri gates, review the final diff, and document
   usage and verification evidence.

## Completion evidence (2026-09-14)

| Requirement | Evidence |
| --- | --- |
| Feature scope and integration rationale | `design-docs/source-analyses.md`, with workflow requirements and integration decisions |
| Built-ins and saved custom templates | `analysisTemplates.ts`, settings integration; three unit tests cover persistence, validation and prompt construction |
| Usable notebook entry point | `ReaderPane.tsx` mounts `SourceAnalyses` keyed by document notebook identity |
| Complete source pagination | Integration tests load 201 sources over two pages and reject repeated pages with a reload path |
| Correct batch dispatch | Integration tests verify selected note identity, provider/model capture, fresh conversations and no edit mode |
| Partial failures and navigation | Integration tests preserve a successful row after a network error and stop subsequent submissions after unmount |
| Durable results | Existing `sendAgentChatMessage` persists note-scoped conversations; integration verifies result navigation; 27 GraphQL tests pass for the reused backend contract |
| Documentation | README describes entry point, templates, saved results, failure handling and context limits |
| Client verification | `mise run web:check`: 171 unit tests and 63 integration tests passed; typecheck, ESLint and production build passed |
| Native verification | `mise run tauri:check`: formatting, check and Clippy passed |
| Backend verification | `mise exec -- swift test --filter AgentChatGraphQLTests`: 27 passed |
| Diff hygiene | `git diff --check` passed |

The first integration run exposed detached-DOM fixtures that prevented Solid's
delegated click handlers from firing. Fixtures now mount in the document and
clean up after each test; the full final gate passes. Existing test fixtures emit
localhost connection warnings, but all tests pass. Initial verification did not
include live provider generation or visual inspection; the follow-up below closes
those gaps. Model-generated citation accuracy is not guaranteed. No Swift source
files were changed by this feature work.

## Live browser verification (2026-09-14)

Added `scripts/test-source-analyses-browser.py`, an opt-in Playwright scenario
that refuses a non-empty store and sends three real provider requests. Ran it
against the built SPA and Swift server on `127.0.0.1:8792`, with an isolated
SQLite store and the existing Codex subscription (`gpt-5.6-luna`). No user
notebooks or production configuration were changed.

Verified through the real UI and GraphQL responses:

- Selecting two source notes creates two distinct conversations, each with its
  own source note and no edit-mode request.
- Both summaries reach `answered`, retain the expected source code, and exclude
  the other note's code. The answers cite the correct source note numbers.
- Opening a result and reloading the page displays the saved answer.
- Saving a custom template writes the real server setting. Reloading the page
  retains the template; applying it produces a third real answer.
- All original source Markdown remains byte-for-byte unchanged.
- No uncaught browser page errors occur.
- Desktop (1440 × 1000) and narrow (390 × 844) screenshots were inspected.
  The narrow analysis panel scrolls internally to preserve reader space.

Visual inspection found that a sticky composer could cover the bottom of a long
answer in the full-page conversation. `ReaderPane.tsx` now marks that container
as `reader-conversation`; scoped layout rules in `chatbook.css` reserve composer
space and scroll the transcript independently. The browser scenario now checks
that the transcript ends above the composer, the composer remains in the viewport,
and the 390px page has no horizontal overflow. The complete live scenario was
rerun successfully after this fix, and both final screenshots were inspected.

Evidence is retained locally at
`/tmp/kaiba-analysis-live.oIUm6q/evidence6/` (`evidence.json` and six screenshots).
The final test store is `/tmp/kaiba-analysis-live.oIUm6q/store6/`.

The final live scenario passed. Earlier setup attempts needed the matching
Playwright browser installation; the harness also needed response parsing outside
its event callback and the actual `appSetting.valueJSON` field. These were harness
issues, not failures of the product. The final run covers all three requests in
one uninterrupted scenario.

Re-ran `mise run web:check` (171 unit tests, 63 integration tests, typecheck,
ESLint, production build) and `mise run tauri:check` after the layout fix; both
passed. Temporary servers were stopped; test stores and artifacts were retained.
