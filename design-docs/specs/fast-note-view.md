# Fast Note view

Fast Note is separate from the notebook tree and reference reader. Its entry
point is the timeline icon in the workspace toolbar (`#/fast`). The folder icon
returns to the reference workspace and opens the notebook library.

The feed contains individual text notes, including Quick Memos and Markdown
notebook notes. Physical document pages, AI conversations, long-term memory,
and tag-memo notebooks retain their dedicated views. Creation time descending
is the fixed default order; editing an older note does not move it to the top.
Equal timestamps use descending note IDs for deterministic pagination.

The center displays a list by default or a responsive card grid. Search matches
all entered terms against note titles, Markdown bodies, and notebook titles.
Search and access restrictions apply before the 50-note pagination boundary.
Search text and layout are carried in the hash route and retained when returning
from a selected note.

Neither the left pane nor its collapsed rail is mounted in Fast Note. The feed
occupies the center without a right pane. Selecting a note displays only that
note in the center and opens its right pane. The note header has a Back to notes
icon. Existing note tags, editing, AI context, and right-pane tools use the same
selected-note app state as the reference reader. Cross-note reference links
open the reference reader, including PDF pages; jump-back restores the Fast Note
selection, query, and layout.

Quick capture uses the existing `/note/capture` endpoint and its per-account,
per-library Quick Memos notebook. It creates one note with intact Markdown.
The check icon or Command/Control Enter saves it and opens its detail view.
The feed follows live note events as well as captures made in the current view.

The `fastNotes` GraphQL query performs the feed selection in AppCore, reusing
library, owner, and pending-ingestion access predicates. It introduces no schema
migration. The isolated schema-24 UI preview adapts only the physical-page
predicate to its legacy page metadata; primary code uses `document_pages`.

## Verification evidence

Evidence is recorded under `tmp/pdf-validation-20261024/fast-note-*`.
Automated checks cover creation order after edits, search before pagination,
physical-page and internal-notebook exclusions, account isolation, route context,
list/cards, selected-note layout, return navigation, quick capture, and retries.
Native browser and database verification complete the implementation audit.

### Completed audit, 2026-10-24

| Requirement | Authoritative evidence |
| --- | --- |
| Separate Fast Note and reference workspaces | Native timeline/folder mode switching; `ChatbookView` mounts distinct reader branches. |
| Creation descending, unaffected by editing | `FastNotesTests.testFeedSortsByCreationAndSearchesBeforePagination`; native feed/API order. |
| Center list and cards | Native layout toggle and `FastNotesView.integration.tsx`; layout persisted in `#/fast`. |
| No left pane | Native library absence and integration assertions against `.pane-left`; Fast Note grid mounts no left pane or splitter. |
| One selected note in the center, right pane shown | Native capture/detail/reload and integration assertions; notebook-wide notes are not fetched for Fast Note selection. |
| Header return icon | Native Back to notes restores the filtered cards, including after reload. |
| Search in the feed | Native body-text search and exact returned note ID; backend test searches before offset/limit. |
| Fast capture | Native Markdown capture matched the exact SQLite body in one Quick Memos note. |
| Scope and exclusions | Focused owner-scope/internal-note/document-page tests; runtime feed excluded 2,320 physical pages. |

Validation passed: `mise run web:check` (194 Bun tests, 162 Vitest tests,
TypeScript, ESLint, production build), `mise run tauri:check`, and
`swift test -j 4 --filter 'FastNotes|NoteGraphQLSchemaInventory'` through mise
(four tests). `mise run lint` passed with the two existing large-tuple warnings.
The native runtime used the isolated compatibility preview described above.
`tmp/pdf-validation-20261024/fast-note-runtime-check.json` records the runtime
and database checks, including removal of the temporary capture and its
test-only Quick Memos notebook. Existing user notebooks were preserved.
