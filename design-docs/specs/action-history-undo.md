# Action History and Undo/Redo

## Status

Accepted (2026-08-21). Initial implementation.

## Summary

- **Every user-visible mutation appends one row to an append-only action
  log** (`note_action_log`), written in the same transaction as the
  mutation itself, so the log can never disagree with the store.
- **Undo and redo are queries over that log**, not in-memory stacks: the
  latest undoable entry per actor is the undo target, and link columns
  (`undo_of_seq`, `undone_by_seq`) record what has been undone or redone.
- **The log stores deltas, never live data.** Body edits are stored as a
  splice patch (only the changed span), field changes as
  `{before, after}` pairs, and creations store nothing at all — a
  creation's content is captured only at the moment it is undone, because
  until then the live row *is* the data. Only deletions snapshot content
  at record time, because that is the moment the data leaves the store.
- **Growth is bounded**: a configurable entry cap (app setting
  `history.maxEntries`, default 1000) prunes the oldest entries on
  insert, and snapshots consumed by a redo are cleared.
- Exposed through GraphQL (`actionHistory`, `undoState`, `undoAction`,
  `redoAction`) and the CLI (`kaiba history`, `kaiba undo`,
  `kaiba redo`).

## Traceability

- Extends `design-docs/specs/kaiba-note.md` (note store) and
  `design-docs/specs/multi-user.md` (attribution).
- Reference design: the event log of `tacogips/xxip`
  (`design-docs/specs/design-event-log.md` there). Kaiba adopts its
  log-derived undo state and link columns, and deliberately diverges
  where noted in U2, U4, U7, U9.
- Implementation plan: `impl-plans/completed/action-history-undo.md`.
- User decisions: `design-docs/user-qa/action-history-undo.md`.

## Design Decisions

- **U1 — One additive append-only table, no schema version bump.**
  `note_action_log` is created by the idempotent base statement list in
  `NoteStoreSchema`, exactly like `app_settings` was ("App settings in
  sqlite", `design-docs/specs/kaiba-migration-history.md`): fresh and
  existing v15 stores both gain it at `prepare`, and a store touched by
  this build still opens under the previous build. `currentVersion`
  stays 15.

- **U2 — Recording is transactional and mandatory.** Each recorded
  mutation inserts its log row inside the same
  `database.transaction { }` that performs the write, adjacent to the
  existing `enqueueAutoActions` outbox call. A failed insert rolls the
  mutation back. This deliberately diverges from xxip's best-effort
  try/catch recording, whose silent event loss let a broken CHECK
  constraint go unnoticed for several commits.

- **U3 — The undo/redo "stacks" are derived by indexed query.** The undo
  target is the newest row per actor with `undoable = 1` and
  `undone_by_seq IS NULL`. `undone` entries are never recorded as undoable so
  they need no explicit exclusion, while a `redone` entry is recorded
  undoable, keeping undo pointed at the most recently applied change. Undoing
  appends an `undone` row and links the target's
  `undone_by_seq`; redoing appends a `redone` row and links the `undone`
  row. Nothing is ever popped, so state survives restarts and concurrent
  clients for free.

- **U4 — Deltas only; live data is never duplicated into the log.**
  - Body edits store a splice patch
    `{"p": prefixBytes, "s": suffixBytes, "del": removed, "ins": inserted}`
    computed by trimming the common prefix and suffix at character
    boundaries of both versions. Undo replaces the `ins` span with
    `del`; redo the reverse. A full rewrite degrades to `before+after`
    (never worse than xxip, which stored both full texts for *every*
    edit); a typical edit stores only the changed span.
  - Field changes (title, read-only, tag assignments) store only the
    changed fields as `{before, after}`.
  - **Creations store no content** (`delta_json` NULL). Undoing a
    creation captures the entity's snapshot *at undo time* into the
    `undone` entry — the "deferred snapshot": content enters the log
    only at the moment it stops being live.
  - **Deletions snapshot at record time** (note row, tag assignments,
    links, comments, file-attachment mappings), because that is the
    moment the data would otherwise be lost. This is the one
    unavoidable snapshot; U9 bounds its lifetime.

- **U5 — One bidirectional apply function per action kind.** Undo and
  redo share a single application routine taking a direction, writing
  the delta's `before` side for undo and `after` side for redo (xxip's
  strongest pattern; halves the code and keeps the two symmetric).

- **U6 — Conflict guards precede every application.** The entity's
  current state must equal the direction's expected side (splice-span
  bytes match, field `after` matches, existence/non-existence for
  create/delete), else the operation fails with
  `NoteServiceError.conflict` and no row is touched. Read-only and
  library-reach checks apply exactly as they do to ordinary mutations.

- **U7 — A new action clears redo.** Redo is available only when the
  newest unlinked `undone` entry is newer than the newest ordinary undo
  target (`R.seq > U.seq`). xxip leaves stale redo targets reachable;
  kaiba follows standard editor semantics instead.

- **U8 — One-hop resolution, single transaction.** `redone` entries
  point `undo_of_seq` directly at the *base* entry (never at another
  `redone`/`undone`), and `undone` entries point at their immediate
  target, so resolution is at most one hop regardless of how many
  undo/redo cycles occurred. Undo (apply inverse + append `undone` +
  link) and redo (apply forward + append `redone` + link) each run in
  ONE transaction — fixing xxip's three un-transacted writes.

- **U9 — Bounded growth.** On every insert the recorder prunes: entries
  beyond the newest `history.maxEntries` (app setting key `history`,
  `{"maxEntries": 1000}` default, clamped to ≥ 10) are deleted oldest
  first, except entries still referenced by an entry newer than the cutoff
  through `undo_of_seq`. The cap is **store-wide, not per actor**: the cutoff
  is a single `ORDER BY seq DESC LIMIT 1 OFFSET maxEntries` with no
  `actor_user_id` filter, so a very active actor can prune a quiet actor's
  older entries even though history and undo/redo are otherwise per-actor
  (U11). This is accepted for v1 — the default cap is generous and undo is a
  recency feature — and is the place to revisit if multi-actor stores grow
  busy (partition the cutoff on `actor_user_id`). A creation snapshot consumed
  by redo is cleared from its `undone` row (the re-inserted live row owns the
  data again). Pruned undo targets simply stop being offered; resolving a link
  to a pruned row reports a conflict rather than corrupting state.

- **U10 — Recorded scope (v1).** Undoable: note create / body update /
  tag apply / tag remove / read-only set / delete; notebook create
  (undo requires the notebook to be empty) and notebook read-only set;
  comment add. Recorded but **not undoable**: notebook delete and bulk
  ingest (`createNotebookWithNotes`, import, comment promotion) — their
  cascade snapshots would be unbounded, defeating U4. Not recorded
  (v1): links, notebook tags, notebook moves, long-term-memory appends,
  user/library administration.

- **U11 — Attribution and provenance.** The actor is
  `writeOwnerUserId()` (acting user, else the default user — the CLI
  and unauthenticated hosts therefore share one linear history), and
  history queries and undo/redo are scoped per actor. Each entry also
  records `NoteProvenance` (`human`/`ai`/`system`); `updateNoteBody`
  gains a `provenance` parameter so the agent edit path
  (`applyNoteEditReply`) records `ai`. AI edits are undoable by the
  same actor like any other edit.

- **U12 — Restoring a deleted note restores what is restorable.** Tags,
  comments, and file-attachment mappings are re-created from the
  snapshot; a link whose peer note no longer exists, or a file mapping
  whose blob row is gone, is dropped silently rather than failing the
  whole undo. Re-insertion conflicts (id or note-number taken) surface
  as `conflict`.

- **U13 — Clients learn about undo/redo through the existing change
  feed.** After the transaction commits, undo/redo publish the same
  `NoteChangeEvent` kinds the original mutations would
  (`noteUpdated`, `noteCreated`, `notebookDeleted`, ...), so live
  clients refresh without a new mechanism.

## Storage

```sql
CREATE TABLE IF NOT EXISTS note_action_log (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  occurred_at TEXT NOT NULL,
  actor_user_id TEXT NOT NULL REFERENCES users(user_id),
  provenance TEXT NOT NULL CHECK (provenance IN ('human','ai','system')),
  entity_type TEXT NOT NULL CHECK (entity_type IN ('note','notebook','comment')),
  entity_id TEXT NOT NULL,
  notebook_id TEXT,
  action TEXT NOT NULL,
  display_json BLOB NOT NULL CHECK (json_valid(display_json, 8)),
  delta_json BLOB CHECK (delta_json IS NULL OR json_valid(delta_json, 8)),
  undoable INTEGER NOT NULL CHECK (undoable IN (0,1)),
  undo_of_seq INTEGER,
  undone_by_seq INTEGER
)
```

- `AUTOINCREMENT` keeps `seq` monotonic across pruning, so a pruned seq
  is never reused by a new entry.
- `action` carries no CHECK on purpose: additive action kinds must not
  make rows written by a newer build unreadable to an older one (U1).
- `display_json` is a tiny rendering snapshot (`{"title": ...}` plus
  ids) so history can name entities that no longer exist.
- Indexes: `(actor_user_id, seq DESC)` for target queries,
  `(entity_type, entity_id, seq DESC)` for per-entity history.

Action kinds (v1): `note-created`, `note-body-updated`,
`note-tags-applied`, `note-tag-removed`, `note-read-only-set`,
`note-deleted`, `notebook-created`, `notebook-read-only-set`,
`notebook-deleted`, `notebook-ingested`, `comment-added`, `undone`,
`redone`.

## Data Flow

1. A mutation (e.g. `updateNoteBody`) opens its transaction, loads prior
   state (already required for FTS/permission checks), performs its
   writes, computes the delta from the already-loaded prior state, calls
   `recordAction(_, in: db)`, and commits. The recorder inserts the row
   and prunes per U9.
2. `undoAction`: one transaction — find target (U3), resolve base (U8),
   guard (U6), apply inverse (U5; capturing the deferred snapshot for
   creations per U4), append `undone`, link `undone_by_seq`. Publish
   change events after commit (U13).
3. `redoAction`: one transaction — availability check (U7), resolve
   base, guard, apply forward (re-inserting from the `undone` entry's
   snapshot for creations, then clearing it), append `redone`
   (`undoable = 1`), link. Publish after commit.
4. `undoState` returns the current undo and redo targets' descriptions
   for UI affordances; `actionHistory(limit, beforeSeq)` pages the log
   descending for the history view.

## Non-Goals

- Branching or per-entity selective undo; history is linear per actor.
- Undo of notebook deletion and bulk ingest (U10) — revisit with a
  cold-storage tier if needed.
- Cross-actor undo, collaborative merge, or CRDT semantics.
- Text-diff granularity beyond one splice per edit (a multi-span diff
  saves little for kaiba-sized notes and complicates the guard).
- Web UI affordances; the web app cannot edit note bodies yet. The
  GraphQL surface is sufficient for it to adopt later.
- Migration of pre-existing mutations; history starts when this build
  first opens the store.

## Verification

- `AppCoreTests/NoteActionHistoryTests`: recording per mutation kind,
  splice-patch round-trips (ASCII, multi-byte, emoji, full rewrite,
  no-op), undo/redo cycles for every undoable kind, deferred-snapshot
  capture and clearing, redo invalidation by a new action (U7), conflict
  guards (moved/edited/readonly/missing), pruning respecting referenced
  entries, per-actor isolation, and that a recording failure rolls the
  mutation back (U2).
- `AppGraphQLTests`: `actionHistory` / `undoState` / `undoAction` /
  `redoAction` contract round-trips.
- Existing schema tests keep passing without version changes (U1).
