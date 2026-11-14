# Web Chatbook UI

## Status

Accepted

## Summary

The web viewer's main screen becomes a chatbook-style three-pane reader
(reference: the user's chatbook screenshot, 2026-08-10):

- **Left pane** (foldable), tabs: **Files** (folder/notebook/note tree)
  and **Contents** (table of contents of the open document).
- **Center**: markdown reader for the selected note, with notebook page
  navigation.
- **Right pane** (foldable), tabs: **Memos** (note comments), **Info**
  (structured tags, timestamps, kind, files), **Links** (linked
  documents grouped by link kind), **Chat** (agent conversation).

This fully replaces the current notebook list/board main screen
(user decision 2026-08-12: full redesign, not an additional view).

## Design Decisions

- **W1 — Replace `NotesView`, do not patch it.** The 1376-line
  `views/NotesView.tsx` god component is left untouched while the new
  shell is built next to it; `App.tsx` switches once a parity checklist
  passes, then `NotesView` and its `:has()`-based grid CSS are deleted
  along with riela-era dead code (the single-shot assistant in
  `NoteDetailPane` and the workspace REST client `notes/workspace.ts`).
- **W2 — Hash routing.** `#/`, `#/notebook/<id>`, `#/note/<id>`
  (optionally `?conv=<id>` for the open conversation). First routing in
  the app; hash-based needs no dependency and no server rewrite
  changes. Deep links restore selection, pane, and tab state.
- **W3 — First shared store.** `state/appStore.tsx` (Solid context +
  `createStore`) owns selection, pane fold state, active tabs, and
  cached lists, and holds the single events-feed subscription
  (`notes/events.ts` long-poll) dispatching targeted refetches. Ends
  props-drilling from a god component.
- **W4 — Fold/layout via data attributes, not `:has()`.** The shell
  grid is `grid-template-columns` driven by `[data-left]`/`[data-right]`
  attributes plus CSS custom properties for pane widths; collapsed
  panes leave a slim rail with a reopen button. The `calc(100vh - Npx)`
  magic heights are replaced by grid rows. Splitter resizing is
  optional follow-up work. Pane/tab state persists in localStorage.
- **W5 — Real headings with ids.** `components/Markdown.tsx` renders
  `h1`-`h6` with slugified, de-duplicated ids (today it flattens to
  h3/h4 without ids). The Contents tab builds its tree from the
  exported `parseMarkdownBlocks`, scroll-syncs the active heading via
  `IntersectionObserver`, and scrolls on click. For imported notebooks
  (one note per H1 section) the Contents tab lists the notebook's notes
  as top-level entries with the open note's headings nested beneath.
- **W6 — One `Tabs` primitive.** A single accessible tab-strip
  component (`role="tablist"`/`tab`/`tabpanel`) replaces the three
  ad-hoc strips in the old code and serves both side panes.
- **W7 — Chat tab states are built before the runtime exists.**
  `agent-unavailable` (banner, composer still persists turns with an
  "unanswered" badge), `pending` (until the events feed delivers the
  completion), `answered`, `failed` (message + retry-as-resend). Backed
  by `noteConversations` / `sendAgentChatMessage` GraphQL fields and
  notes-by-notebook turn fetches.
- **W8 — Keep the long-poll feed.** Live updates stay on
  `GET /note/events`; the store maps `{kind, notebookId}` events to
  refetches of the open conversation's turns or the open note's memos,
  links, and info.

## Component Layout

```
web/src/
  router.ts                hash routing helpers + tests
  state/appStore.tsx       context + createStore, events subscription
  views/ChatbookView.tsx   3-pane shell, fold state, keyboard shortcuts
  panes/LeftPane.tsx       Tabs: Files | Contents
  panes/ReaderPane.tsx     markdown reader + notebook page navigation
  panes/RightPane.tsx      Tabs: Memos | Info | Links | Chat
  components/Tabs.tsx      shared tab strip
  components/FileTreeTab.tsx    (reuses notes/tree.ts)
  components/TocTab.tsx
  components/MemoListTab.tsx    (existing comment APIs)
  components/NoteInfoTab.tsx    (noteTagDetails query)
  components/LinkedDocsTab.tsx  (link queries, grouped by kind)
  components/AgentChatTab.tsx
```

## Parity Checklist (gates NotesView deletion)

- Folder/notebook/note tree browsing and selection
- Note reading
- Memo (comment) list and add
- Tag display (now structured with class + provenance)
- Search popup
- Kanban board entry point (or an explicit relocation decision)
- QR client registration flow
- Events-driven live refresh

## Verification

- `cd web && bun run typecheck && bun run test && bun run lint &&
  bun run build` per task.
- DOM-free logic tests per repo convention: `router.test.ts`,
  `toc.test.ts` (heading tree, slug dedupe), `chatState.test.ts`
  (turn-status reducer including unavailable/pending/failed),
  `paneState.test.ts` (fold/tab persistence).
- Smoke: `kaiba serve --web-root web/dist`, deep-link `#/note/<id>`,
  fold both panes, TOC scroll-sync, memo add reflected via the events
  feed, chat tab in agent-unavailable state.
