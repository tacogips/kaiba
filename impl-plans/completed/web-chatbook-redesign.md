# Web Chatbook Redesign

**Status**: In Progress
**Design Reference**: `design-docs/specs/web-chatbook-ui.md`

## Purpose

Replace the web viewer's main screen with the chatbook three-pane
foldable reader (Files/Contents left tabs; markdown reader center;
Memos/Info/Links/Chat right tabs), with hash routing and a shared
store, then delete the legacy `NotesView` after parity.

## Deliverables

- [x] `router.ts`, `state/appStore.tsx`, `views/ChatbookView.tsx`
- [x] `panes/LeftPane.tsx`, `panes/ReaderPane.tsx`, `panes/RightPane.tsx`
- [x] `components/Tabs.tsx`, `FileTreeTab`, `TocTab`, `MemoListTab`, `NoteInfoTab`, `LinkedDocsTab`, `AgentChatTab`
- [x] Markdown heading ids; data-attribute fold grid CSS
- [x] NotesView + dead riela code removed after parity checklist
- [x] bun tests (router, toc, chat state, pane state)

## Tasks

### TASK-001: Spec (web-chatbook-ui.md)

**Parallelizable**: Yes

**Completion Criteria**:

- [x] Spec accepted (W1-W8, parity checklist)

### TASK-002: Router and store

**Parallelizable**: Yes

**Completion Criteria**:

- [x] Hash routes `#/`, `#/notebook/<id>`, `#/note/<id>` (+`?conv=`); store owns selection/panes/tabs; single events subscription
- [x] `router.test.ts`, `paneState.test.ts`

### TASK-003: Shell and fold CSS

**Parallelizable**: No (after TASK-002)

**Completion Criteria**:

- [x] 3-pane grid via `[data-left]`/`[data-right]` + CSS vars; slim reopen rails; no `:has()` layout, no viewport-calc magic heights

### TASK-004: Markdown heading ids

**Parallelizable**: Yes

**Completion Criteria**:

- [x] `h1`-`h6` with slugified deduped ids; existing rendering tests updated

### TASK-005: Left pane (Files | Contents)

**Parallelizable**: Yes (after TASK-002/003)

**Completion Criteria**:

- [x] FileTreeTab reusing `notes/tree.ts`; TocTab tree + IntersectionObserver scroll-sync; imported notebooks nest note list + open-note headings
- [x] `toc.test.ts`

### TASK-006: Reader pane

**Parallelizable**: Yes (after TASK-002/003)

**Completion Criteria**:

- [x] Markdown reader for selected note; notebook page navigation

### TASK-007: Right pane Memos / Info / Links

**Parallelizable**: Yes (after TASK-002/003)

**Completion Criteria**:

- [x] MemoListTab (`noteComments` list + `addNoteComment` write), NoteInfoTab (note tags + timestamps + tag extraction), LinkedDocsTab (grouped by link kind)

### TASK-008: Chat tab

**Parallelizable**: Yes (after TASK-002/003; needs chat GraphQL fields)

**Completion Criteria**:

- [x] Conversation list, transcript, composer; states agent-unavailable/pending/answered/failed; events-feed refetch
- [x] `chatState.test.ts`

### TASK-009: Parity switch and deletion

**Parallelizable**: No (last)

**Completion Criteria**:

- [x] Parity checklist in spec passes; `App.tsx` switched; `NotesView.tsx`, `:has()` grid CSS, `NoteDetailPane`, `notes/workspace.ts` removed

### TASK-010: Verification

**Parallelizable**: No

**Completion Criteria**:

- [x] `bun run typecheck && bun run lint && bun test src && bun run build` clean; smoke per spec

## Progress Log

- 2026-08-12: Plan created; spec accepted.
- 2026-08-12: Chatbook shell implemented and switched on. New modules:
  `router.ts`, `state/appStore.tsx`, `state/paneState.ts`,
  `views/ChatbookView.tsx`, `views/BoardView.tsx`, `panes/{Left,Reader,Right}Pane.tsx`,
  `components/{Tabs,FileTreeTab,TocTab,MemoListTab,NoteInfoTab,LinkedDocsTab,AgentChatTab}.tsx`,
  `notes/{markdown,toc,chatState,kanban,noteText}.ts`, `chatbook.css`.
  Deleted: `views/NotesView.tsx`, `components/NoteDetailPane.tsx`,
  `components/NoteComposePanel.tsx`, `components/NoteDetailLogic.{ts,test.ts}`
  (surviving pure helpers moved to `notes/noteText.ts`), `notes/workspace.ts`,
  and the `:has()`/`calc(100vh - Npx)` workspace CSS in `styles.css`.
- 2026-08-12: Kanban relocated rather than deferred — the board lives at
  `#/board` (`views/BoardView.tsx`) with a header entry point, reusing
  `NotebookProgressController` and the column mapping now in `notes/kanban.ts`.
- 2026-08-12: Browser smoke test against `kaiba serve --web-root web/dist`
  (headless Chrome over CDP) covering deep links, tree browse, reader paging,
  TOC scroll-sync, pane fold/persistence, search, memo add, chat send, board,
  QR `?code=` registration, and a chat turn pushed by another client arriving
  live through the events feed. Console clean.

- 2026-08-12: Both server-side follow-ups landed, so the web side was closed
  out. `MemoListTab` now reads the stored list with the new
  `noteComments(noteId:)` query and re-reads it after `addNoteComment`; the
  session-only caveat is gone. With `createNote`/`updateNoteBody` publishing
  `note-created`/`note-updated` for existing notebooks, the store's event
  handler re-reads any notebook whose notes are on screen (the open one or
  another expanded in the tree), not just the open one. Verified in the browser:
  memos written by another client appear, a remote body edit lands in the
  reader, and a note created by another client extends the reader's paging
  (1 / 3 to 1 / 4) with no user action.

### Findings and follow-ups

- **Fixed while testing**: `searchNotes` declared `$sort: String` but the schema
  argument is `NoteListSort`, so every search failed with `invalidVariable`.
  The bug predates this work and stayed hidden because the search popup was
  RielaApp-only; the chatbook shell makes search reachable, so it is fixed in
  `notes/client.ts`. Same class of bug fixed in the new
  `noteGraphNeighbors` query (`[String!]` to `[String!]!`).
- **Memos list — resolved** by the server's `noteComments(noteId:)` query;
  `MemoListTab` reads the stored list and re-reads after each write.
- **Live refresh — resolved** for note writes: `createNote` and
  `updateNoteBody` now publish `note-created`/`note-updated` with the notebook
  id for existing notebooks, and the store turns those into targeted refetches.
  One gap remains: `addComment` publishes no event, so a memo written by
  another client appears only when something else touches the note (the events
  it does emit) or on the next tab switch or Refresh. Publishing a change event
  from `addComment` would close it.
- **Unused-but-kept modules**: `NotebookScopeController` /
  `NotebookReadOnlyController` in `notes/controller.ts` and
  `notes/createdFilter.ts` are no longer referenced — tag-scoped notebook
  filtering, notebook locking and created-date filters have no UI in the new
  shell. They are kept with their tests for when those controls return; the
  older riela dashboard CSS in `styles.css` (`.page`, `.instance-*`, `.run-*`,
  `.registry-*`) was already unreferenced before this change and was left
  alone.
