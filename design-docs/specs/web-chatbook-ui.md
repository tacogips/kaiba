# Web Chatbook UI

## Status

Accepted

## Traceability

- Workflow issue: `direct-workflow:comm-002100`
- Composition reference: the user's desktop screenshot
  `Screenshot 2026-08-12 at 21.13.56.png` (kept outside the repository)
- Repository guidance: `AGENTS.md`

## Issue Scope: `direct-workflow:comm-002100`

This issue implements only the right-pane agent memo/chat composer and its
attachment contracts:

- **In scope:** W9-W12, the right-pane and Memo-pane behavior needed by those
  decisions, their client/server contract integration, responsive light/dark
  styling, and the focused tests and documentation required by the intake.
- **Out of scope:** W1-W8, W13, header search, left-pane or center-reader
  changes, broader routing or application-shell redesign, and unrelated
  parity work. Those pre-existing decisions remain context for compatibility;
  this issue does not authorize implementing or revising them.
- Existing conversations, memos, pane behavior, streaming, and file storage
  are integration boundaries to preserve, not invitations to broaden the
  feature.

## Summary

The web viewer's main screen becomes a chatbook-style three-pane reader
(reference: the user's chatbook screenshot, 2026-08-10):

- **Left pane** (foldable), tabs: **Files** (folder/notebook/note tree)
  and **Contents** (table of contents of the open document).
- **Center**: continuous-scroll reader — the open notebook's notes flow
  vertically with lazy rendering, a goto-page control, and
  click-to-select (clicking a note selects it for the right pane;
  clicking again deselects). No arrow paging.
- **Right pane** (foldable, ~0.8x the reader's width). Memos and chat
  are one **Memo** feature: a merged timeline of memos and agent turns
  with a rounded, bottom-anchored composer. The composer has attachment
  and memo-only controls on the left, model choice near the right, and
  submit at the far right. **Enter** submits, **Shift+Enter** inserts a
  newline, and memo-only is a mode rather than a separate submit
  action. Agent replies stream via the agent reply chunk feed. With a note
  selected the tabs are Memo | Info | Links for that note; with no note
  selected they show notebook-wide aggregates — all memos (attributed
  to their notes; notebook-level memos exist too), deduped tags across
  all notes, and all links.
- **Header**: a store-wide search form — scope (all notebooks / the
  open notebook) and method (agentic by default, or grep) — navigating
  to a `#/search` results screen.

This fully replaces the previous notebook-list main screen
(user decision 2026-08-12: full redesign, not an additional view).
(2026-08-12 revision: continuous scroll, unified memo, notebook-level
memo subjects, streaming replies, and header search replaced the
original per-note reader + separate Memos/Chat tabs described below.)

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
  `IntersectionObserver`, and scrolls on click.
  (2026-08-12 revision) The Contents tab is a three-level hierarchy:
  the open notebook is the root entry, every note nests beneath it,
  and each note's full heading tree nests beneath the note. Anchor ids
  are namespaced per note (`note-<noteId>--<slug>`) so every mounted
  note carries ids and TOC clicks can jump into any note's headings;
  a click on a heading of a not-yet-mounted note scrolls its section
  into view first and retries the heading anchor. The open note's
  headings expand by default; other notes expand via a disclosure
  control. The tab is available whenever a notebook is open, even
  with no note selected.
- **W6 — One `Tabs` primitive.** A single accessible tab-strip
  component (`role="tablist"`/`tab`/`tabpanel`) replaces the three
  ad-hoc strips in the old code and serves both side panes.
- **W7 — Memo timeline exposes the agent lifecycle without splitting chat
  into a separate tab.**
  `agent-unavailable` (banner, composer still persists turns with an
  "unanswered" badge), `pending` (with transient streamed chunks),
  `answered`, and `failed` (message + retry-as-resend) render in the same
  Memo timeline as comments. `noteConversations` and notes-by-notebook
  queries reconstruct durable turns; `sendAgentChatMessage` starts the
  pending lifecycle.
- **W8 — Streaming is transient; persistence is authoritative.** While a
  reply is pending, the pane long-polls
  `GET /note/agent-stream?turn=<turnNoteId>&cursor=N` and renders ordered
  chunks for that turn. Completion or failure is persisted on the turn note;
  the existing `GET /note/events` feed then triggers a durable refetch and
  replaces transient text. Stream loss or pane closure therefore cannot lose
  the final reply. The general events feed continues to refresh memos, links,
  info, and conversation catalogs.
- **W9 — Composer interaction follows the desktop reference.** The
  rounded composer is one keyboard submission surface, not a textarea
  followed by action buttons. Plain Enter submits a non-empty draft;
  Shift+Enter inserts a newline; composing text through an IME never
  submits. The plus control opens the file picker, the memo-only icon is
  a real toggle button (`aria-pressed`, accessible name, tooltip, visible
  selected treatment), and the circular submit control is the last item
  at the far right. All icon-only controls retain a visible focus ring and
  at least a 36px pointer target. The desktop screenshot
  `Screenshot 2026-08-12 at 21.13.56.png` (kept outside the repository) is a
  composition reference; Kaiba keeps its own colors, typography, pane
  semantics, existing light and dark theme tokens, and responsive
  breakpoints. Composer controls must remain legible, focused, and visibly
  selected in both themes and at each existing pane breakpoint.
- **W10 — New chat changes the active boundary, not stored history.** A
  New chat icon at the upper left of the right pane's Memo view sets an
  explicit local `new conversation` intent. The merged timeline immediately
  appends a visible, focus-announced `New conversation` boundary after all
  retained memos and prior turns; the empty region below it is the active
  thread. The next agent submission omits `conversationNotebookId`, so the
  server creates a new conversation; its returned id becomes active and the
  boundary remains as that conversation's separator. The action clears the
  draft and staged attachments and stops the current display stream, but it
  never deletes or hides comments, conversation notebooks, or turn notes.
  Clicking New chat again while the active region is still empty only resets
  that same local boundary rather than stacking separators. This explicit
  state must not silently fall back to `latestConversationId` before the first
  new message. A focused new-chat test verifies the visible boundary, empty
  active region, retained history, and omitted conversation id.
- **W11 — Model choice is store-persistent and provider-scoped.** The
  selector lists models advertised for the server's configured agent
  provider, with the configured model as the fallback when discovery is
  unavailable. Selection is stored in the existing SQLite-backed `web`
  app-settings document as `agentModel`; defensive parsing preserves
  older documents. Every agent send includes the selected model. Memo-only
  submissions do not invoke a model, but retain the selection for the next
  agent send. The provider is not selectable in this pane.
- **W12 — Composer attachments are bounded agent-turn context.** The
  first release accepts at most four UTF-8 text files with an aggregate
  decoded size of 1 MiB. Accepted media are exactly `text/plain`,
  `text/markdown`, `text/csv`, `text/tab-separated-values`,
  `application/json`, `application/xml`, `application/yaml`, and
  `application/x-yaml`; parameters such as `charset` are removed before
  matching. Empty or generic browser MIME values may be normalized from a
  recognized filename extension, but extension or browser MIME alone is not
  sufficient: decoded content must also be valid UTF-8. `text/html`, SVG,
  scripts, executables, archives, and other active or binary formats are
  explicitly rejected. Filenames are display metadata only; empty names,
  path separators, control characters, and names longer than 255 UTF-8 bytes
  are rejected rather than silently sanitized or truncated.
  Selected files appear as removable chips before submission. Files are
  persisted as attachments of the generated chat turn and included in
  that turn's agent context with a filename/media-type delimiter; file
  content is data and never instructions. Binary files, invalid UTF-8,
  empty files, duplicate files, too many files, and over-limit payloads
  are rejected before a turn is created. Memo comments have no attachment
  relation, so memo-only mode remains text-only: enabling it with staged
  files is blocked with an accessible explanation, and the attachment
  control is unavailable while selected. This is an intentional safe
  boundary, not silent attachment loss.

- **W15 — Center-pane diary list (2026-08-14).** The center pane has
  `List | Notebook` display tabs. List is the home/default surface and shows
  user-facing notebooks by descending `updatedAt`, with the first note's
  whitespace-normalized text capped at 80 Unicode characters, note count,
  update time, and non-kind tag assignments including provenance. Selecting a
  card opens that notebook through the canonical route and switches to the
  Notebook tab. Tag chips above the list filter the overview by notebook tag,
  so hierarchical AI classifications remain useful without requiring the
  writer to file an entry first. Internal agent-conversation, long-term-memory,
  and tag-memo backing notebooks are excluded; imported and translated writing
  remains visible. Automatic classification continues to use AI4's configured
  `ai.autoTag.auto` boundary and existing provenance protections.

- **W14 — Tag detail pane (2026-08-13).** Inline tag-term underlining in
  the reader, the cross-notebook tag-mode right pane (Memo | History |
  Links), the in-app return stack, and drag-select tag registration are
  specified separately in `tag-detail-pane.md` (decisions T1-T9). They
  extend the right pane and reader without changing W1-W13.

- **W13 — Note source images open as a page-flip carousel
  (2026-08-12).** A note whose attachments include image files (role
  `source-page-image` = captured pages of the imported document, role
  `embedded` = images extracted from those pages) shows an arrow on its
  left edge in the reader. Pressing it flips the note to an in-place
  carousel: captured pages first in page order, then embedded images.
  The left arrow advances deeper; the right-edge arrow, a rightward
  mouse/touch swipe, or ArrowRight steps back and closes once it steps
  past the first image (Escape and a "Back to text" button also close).
  Attachments are discovered lazily per mounted note via the `noteFiles`
  GraphQL query; bytes come from `GET /files/<fileId>` fetched with the
  bearer header into object URLs, because an `img src` cannot carry
  Authorization. An older server without `noteFiles` leaves notes
  without arrows. Ordering/stepping logic lives DOM-free in
  `notes/noteImages.ts` with tests.

## Composer Data Flow and Rollout

1. On pane load, fetch the `web` app setting and the current-provider
   model catalog. Normalize a stored selection against the catalog;
   otherwise use the configured model.
2. File selection performs client-side count, size, duplicate, and media
   checks for prompt feedback. The server repeats every check and is the
   authority.
3. Agent submission sends subject, explicit conversation intent, trimmed
   markdown, idempotency key, selected model, and bounded inline
   attachments. The server validates the entire request before creating a
   turn, snapshots the model on the turn, and persists the turn and file
   associations before reply dispatch can observe it.
   Prompt construction has a separate 1 MiB (1,048,576-byte) UTF-8 file-content
   budget. Filename/media-type delimiters and omission markers do not consume
   that content budget; they have a separate 4 KiB framing allowance. It
   includes every current-turn file first in composer order, then whole files
   from prior turns newest-to-oldest and by stored attachment position. A
   prior file that does not wholly fit is omitted with a deterministic marker;
   files are never partially truncated. Consequently every accepted
   current-turn file is present in its initial invocation, while retries and
   later turns reconstruct the same ordering from persisted positions.
4. Memo-only submission uses the existing note/notebook comment mutation.
   It does not send model or attachment fields.
5. Deploy server/core contract support before enabling the web controls.
   A web client receiving an unavailable catalog shows only the configured
   model; an older server must leave model and attachment controls disabled
   rather than sending unsupported fields.
6. The composer's note edit toggle sends `mode: "edit"` on the agent
   submission. It is enabled only for a note subject whose own read-only
   flag and whose notebook's flag are both clear (the client mirror of the
   server's `updateNoteBody` gate; imported documents lock the notebook),
   drops automatically when the subject changes or stops being writable,
   and is mutually exclusive with memo-only. The mode is per turn, so a
   conversation started in memo mode can switch to edit mid-thread and the
   prior turns ground the edit. Like model/attachments, the field is only
   sent when the composer-extension catalog is available — an older server
   would silently answer as a memo, which must never masquerade as an
   applied edit. Turns whose meta records `mode: "edit"` render a
   "Note edit" badge in the timeline.

The 1 MiB aggregate limit deliberately stays below
`KaibaHTTPRequestParser.maximumBodyBytes` after base64 and JSON overhead.
It does not raise the global HTTP limit or weaken the existing 8 MiB
service limit for other note-file APIs.

## Component Layout

```
web/src/
  router.ts                hash routing helpers + tests
  state/appStore.tsx       context + createStore, events subscription
  views/ChatbookView.tsx   3-pane shell, fold state, keyboard shortcuts
  panes/LeftPane.tsx       Tabs: Files | Contents
  panes/ReaderPane.tsx     List | Notebook center tabs + markdown navigation
  panes/RightPane.tsx      Tabs: Memo | Info | Links + New chat boundary
  components/Tabs.tsx      shared tab strip
  components/FileTreeTab.tsx    (reuses notes/tree.ts)
  components/NotebookListTab.tsx chronological notebook cards + tag filters
  components/TocTab.tsx
  components/MemoTab.tsx        merged comments/agent turns + composer
  components/NotebookAggregateTabs.tsx notebook-wide Memo/Info/Links
  components/NoteInfoTab.tsx    (noteTagDetails query)
  components/LinkedDocsTab.tsx  (link queries, grouped by kind)
  notes/memoTimeline.ts          deterministic merged-timeline projection
  notes/chatState.ts             agent lifecycle projection
  notes/notebookList.ts          diary ordering, visibility, preview projection
  notes/settings.ts              defensive web setting persistence
```

## Parity Checklist (gates NotesView deletion)

- Folder/notebook/note tree browsing and selection
- Note reading
- Memo (comment) list and add
- Tag display (now structured with class + provenance)
- Search popup
- QR client registration flow
- Events-driven live refresh

## Verification

- `cd web && bun run typecheck && bun run test && bun run lint &&
  bun run build` per task.
- DOM-free logic tests per repo convention: `router.test.ts`,
  `toc.test.ts` (heading tree, slug dedupe), `chatState.test.ts`
  (turn-status reducer including unavailable/pending/failed),
  `paneState.test.ts` (fold/tab persistence), plus focused composer tests
  for Enter/Shift+Enter/IME handling, memo-only accessibility and blocking,
  model fallback/persistence, new-chat conversation intent, and attachment
  validation/removal.
- Smoke: `kaiba serve --web-root web/dist`, deep-link `#/note/<id>`,
  fold both panes, TOC scroll-sync, memo add reflected via the events
  feed, unified Memo pane in agent-unavailable state, and composer contrast,
  focus, selected state, and responsive placement in light and dark themes.
