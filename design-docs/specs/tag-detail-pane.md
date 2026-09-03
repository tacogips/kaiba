# Tag Detail Pane

## Status

Accepted (2026-08-13)

## Summary

Tags become first-class navigation subjects in the chatbook web UI:

- **Inline tag terms.** When a note's body contains a string equal to the
  name of a tag attached to that note (or to its notebook), the reader
  underlines those occurrences. Clicking an underlined term — or any tag
  chip in the Info/Tags tabs — opens the right pane in **tag mode**.
- **Tag mode right pane.** The tag-scoped analogue of the per-note
  Memo/Info/Links panes, aggregated **across all notebooks**: a Memo tab
  (agent chat + memos about the tag itself), a History tab (every memo
  ever written on notes/notebooks carrying the tag), and a Links tab
  (every note carrying the tag, grouped by notebook). Use case: a person
  name appearing in an imported document is a `person` tag; the reader
  can ask the agent about that person, see past agent memos, and jump to
  every other note mentioning them.
- **Return stack.** Following an occurrence link from the tag pane (or
  any right-pane link) pushes the current location onto an in-app return
  stack; a visible **Back** control pops it, repeatedly, until the stack
  is empty.
- **Drag-select to tag.** Selecting text in the reader with the mouse
  offers a small popover to register the selection as a tag on the note
  containing it.

## Traceability

- Extends `web-chatbook-ui.md` (right pane, reader) and the domain
  model in `kaiba-note.md` (D6/D7 tags, K12 conversation notebooks).

## Design Decisions

- **T1 — Highlight only attached tags.** The matcher input is the union
  of the note's own tag assignments and the open notebook's tag
  assignments — not the global tag catalog. This keeps matching cheap,
  deterministic, and semantically honest: an underline asserts "this
  note is about this tag", which is only true when the tag is attached.
  Folder-class tags and system kind tags (`imported-material`,
  `agent-conversation`, `user-memo`, `tag-memo`) are excluded — they are
  organizational, not subjects.
- **T2 — Matching is a pure inline-segment pass.** Tag matching runs as
  a post-pass over the parsed inline segments in the existing markdown
  model (`parseInlineSegments`), splitting `text` segments only — never
  inside code, links, bold/italic markers, and never via raw-HTML string
  replacement. Longest tag name wins at a given position;
  ASCII-case-insensitive, otherwise literal substring match (no
  word-boundary requirement, since Japanese has no delimiters); tag
  names shorter than 2 characters are skipped to avoid noise. The logic
  lives DOM-free in `web/src/notes/tagMatch.ts` with unit tests.
- **T3 — Tag mode is route-addressed.** The selected tag rides the hash
  route as a `?tag=<tagId>` query parameter (same pattern as `?conv=`),
  so deep links restore the pane and the events feed can refresh it.
  While set, the right pane replaces its note/notebook tabs with the tag
  tabs **Memo | History | Links** under a header showing the tag name,
  class, and note/notebook counts, plus a close control that returns to
  the note/notebook tabs. Selecting a tag never changes the center
  reader; only following an occurrence link does.
- **T4 — Tag memos and chat bind to a per-tag memo notebook.** Memos and
  agent conversations attach to notes/notebooks, not tags (schema
  `note_comments`). Rather than a new comment subject kind, each tag
  lazily gets one dedicated **tag memo notebook**: kind system tag
  `tag-memo`, title `Tag: <name>`, subject binding recorded in notebook
  meta JSON (`kaibaTagMemo.subjectTagId`, mirroring the K12 `kaibaChat`
  pattern) rather than a tag assignment — so the memo notebook itself
  never appears among the tag's occurrences or history. The tag
  Memo tab is the existing notebook-subject memo/chat surface (K12,
  W7-W12) pointed at that notebook — agent chat, streaming, models, and
  attachments all work unchanged. One backend refinement: when a
  conversation's subject notebook is a `tag-memo` notebook, the subject
  context markdown is built from the notes carrying the tag across all
  notebooks (capped like the existing notebook context), not from the
  empty memo notebook itself — so the agent is grounded on the tag's
  occurrences (e.g. every note mentioning the person). The notebook is
  created on demand by `ensureTagMemoNotebook` (first submit, not first
  view). Lookup and creation form one serialized database operation:
  concurrent callers return the same notebook, and only the winning call
  emits notebook-creation side effects. In the Files tree it behaves exactly like
  conversation notebooks today (no special exclusion in v1); the
  meta-JSON binding keeps it out of the History aggregation so the Memo
  tab is never duplicated.
- **T5 — History is the cross-notebook memo aggregate.** A new
  `tagComments(tagId, limit, offset)` query returns all `note_comments`
  rows whose note carries the tag, plus notebook-level memos of
  notebooks carrying it (expanded to descendant tags via the existing
  hierarchy CTE), newest first, each attributed with its note/notebook
  title. Tag-memo notebooks never appear (T4's meta binding). Memos are
  append-only (no edit history exists), so this chronological aggregate
  *is* the memo history.
- **T6 — Links are tag occurrences.** The Links tab lists every note
  carrying the tag across all notebooks — reusing the existing
  cross-notebook feed `notes(notebookId: nil, tagFilter: [name])` —
  grouped by notebook with titles from the notebook catalog. The client
  follows offset pages at the API maximum of 200 until a short page proves
  exhaustion; a full page must advance the offset, and failure to make
  progress is surfaced rather than silently returning a partial list.
  Changing or closing the selected tag immediately clears the previous
  occurrence set and invalidates its request generation. Each page checks
  that generation before publishing, so late responses for an old tag can
  neither restore stale links nor remain clickable. Clicking a current
  occurrence navigates to that note (T7). Explicit `note_links` stay on the
  per-note Links tab; a shared tag *is* the link here (the note graph already
  models `shared-tag` edges).
- **T7 — In-app return stack.** Navigation initiated from the right pane
  (tag occurrences, linked docs) pushes the current route (including
  selection and `?tag=`) onto a store-owned LIFO stack (capped at 50).
  A **Back** control appears whenever the stack is non-empty and pops
  one entry per click, restoring reader position, selection, and pane
  state; it works repeatedly across chained jumps. Browser history keeps
  working independently (hash routing); the in-app stack exists so
  "return to where I was reading" survives intermediate in-pane
  interactions that would pollute browser history.
- **T8 — Drag-select registers a human tag.** On `mouseup` over a
  completed non-empty selection inside the reader, a small popover
  anchored near the selection offers "Register '<text>' as tag". The
  selection is trimmed of surrounding whitespace/newlines, rejected when
  empty, longer than 64 characters, or spanning multiple notes (the
  anchor node's `data-note-id` section is the subject). Confirming calls
  the existing `applyNoteTags` mutation (provenance `human`, assigner
  `kaiba-web`, no class); the tag is created on demand by the existing
  upsert semantics, the note refetches, and the new underlines appear
  immediately. Class assignment and hierarchy stay in existing surfaces.
- **T9 — New GraphQL surface is three operations.** `tagDetail(tagId)`
  (tag + class + parent + note/notebook counts + existing memo notebook
  id or null), `tagComments(tagId, limit, offset)` (T5), and mutation
  `ensureTagMemoNotebook(tagId)` (T4). Everything else reuses existing
  operations (`notes`, `tags`, `notebookComments`, `noteConversations`
  machinery, `applyNoteTags`). Pagination uses the existing offset contract;
  bounds follow the existing limit of 0…200 and a page shorter than the
  requested limit is the end-of-results signal.
- **T10 — Note tag changes publish change events.** `applyTags` and
  `removeTag` publish a `note-tags` change event (notebook-scoped, like
  the existing `notebook-tags`), and a removal that deletes nothing
  stays silent. Tag assignments drive the underlines, the tag pane's
  aggregates, and the tag catalog, so other clients need waking exactly
  as they do for notebook tags; the web feed already reloads the
  notebook's notes and refreshes the catalog on any non-note kind.
- **T11 — Tag context limits are UTF-8 byte limits.** The tag heading,
  separators, and occurrence markdown share the configured context budget.
  Content is truncated only at a valid UTF-8 scalar boundary, never by a
  character count treated as bytes. The final context therefore never exceeds
  `limitBytes`, including for Japanese, emoji, and other multibyte content; a
  non-positive or heading-smaller budget returns the largest valid UTF-8 prefix
  that fits.

## Data Flow

1. Reader mounts a note → matcher built from note tags ∪ notebook tags
   (T1/T2) → underlined terms render as focusable elements carrying
   `data-tag-id`.
2. Click on a term or chip → route gains `?tag=<id>` → right pane enters
   tag mode → prior-tag links clear → `tagDetail` + `tagComments` + all
   `notes(tagFilter)` pages load; generation checks discard responses after a
   newer selection. Memo tab loads the memo notebook's timeline when
   `memoNotebookId` is non-null, otherwise shows an empty timeline.
3. First memo/chat submit with no memo notebook → `ensureTagMemoNotebook`
   → submit proceeds against the returned notebook id.
4. Occurrence click → push return stack → navigate to the note's
   notebook/note route. Back pops and restores.
5. Drag-select → popover → `applyNoteTags` → note refetch → underlines
   update.

## Non-Goals

- No new comment subject kind in the schema; tag memos are notebook
  memos (T4).
- No global-catalog matching or fuzzy/morphological matching (T1/T2).
- No tag rename/merge/delete surface.
- No change to CLI surface; this is a web + GraphQL feature.

## Verification

- Swift: unit tests for `tagDetail`, `listTagComments` (descendant
  expansion, tag-memo exclusion, pagination), `ensureTagMemoNotebook`
  (concurrent callers produce one notebook and one creation side effect), and
  tag context truncation at/beyond the byte limit with multibyte content;
  GraphQL executor tests for the three operations; `swift build`, targeted
  `swift test`, `swiftlint`.
- Web: DOM-free tests for `tagMatch.ts` (longest-first, case folding,
  segment splitting, exclusions), return-stack reducer, router `?tag=`
  round-trip, Links pagination beyond 200 occurrences, and rapid tag switching
  with an old response arriving last; `bun run typecheck && bun run test && bun
  run lint && bun run build`.
- Smoke: serve, open an imported note with a person tag, click the
  underlined name, chat in the tag Memo tab, jump to another occurrence,
  press Back twice, drag-select a phrase and register it as a tag.
