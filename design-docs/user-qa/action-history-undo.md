# Action History and Undo/Redo — decisions and open questions

Spec: `design-docs/specs/action-history-undo.md`.

The user asked for: undo/redo and user-action history in kaiba, using
the xxip implementation as a reference, with logs that stay small by
storing only deltas. The following defaults were chosen without an
explicit user answer; flag any that should change.

## Decided by default (confirm or override)

1. **No schema version bump** (U1). The log table is added through the
   idempotent DDL list like `app_settings` was, so existing v15 stores
   keep opening. Alternative was bumping to v16 under the
   no-backcompat policy, which would have rejected every existing
   store.
2. **History is linear per actor, not per library** (U11). The CLI,
   unauthenticated note-API callers, and the default user share one
   history. Per-(actor, library) scoping like xxip's per-workspace undo
   can be added later by widening the target queries.
3. **Notebook deletion and bulk ingest are not undoable** (U10): their
   cascade snapshots would embed every note body, which is exactly the
   bloat this design removes. They still appear in history.
4. **Retention default: 1000 entries** via app setting
   `history` -> `{"maxEntries": 1000}`. Change with the ordinary
   `setAppSetting` mutation; clamped to at least 10.
5. **A new action clears redo** (U7) — standard editor semantics,
   unlike xxip where stale redo targets stay reachable.
6. **Web UI is out of scope for v1** — the web app cannot edit note
   bodies yet, so undo buttons there would mostly undo memo/tag
   actions. The GraphQL surface (`undoState`, `undoAction`,
   `redoAction`, `actionHistory`) is ready for it.
7. **AI edits are undoable** and recorded with provenance `ai`; since
   attribution funnels to the same acting user, a human `kaiba undo`
   reverts the latest change regardless of whether a human or the agent
   made it.

## Open questions

- Should `history.maxEntries` also pair with an age-based cap
  (e.g. `maxAgeDays`)? Not implemented in v1.
- Should per-entity history (`actionHistory` filtered by note id) get a
  dedicated GraphQL argument in v1? The index exists; the argument is
  trivial to add when the UI needs it.
