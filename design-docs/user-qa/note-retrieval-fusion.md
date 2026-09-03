# Note Retrieval Fusion: decisions and open questions

Design: `design-docs/specs/note-retrieval-fusion.md`.

## Decisions taken without a user answer (2026-09-03)

- Techniques were restricted to those that need no embedding model, vector
  store, or index-time LLM call, because kaiba ships as one SQLite-backed
  binary. Recorded as an assumption; reversible if an embedding runtime is
  added later.
- The FTS schema change bumps `NoteStoreSchema.currentVersion` to 19 and
  follows the existing "recreate the store" policy rather than adding a
  migration.
- Recency in long-term memory recall defaults to a minor weight (0.5) instead
  of off, because it only reorders notes the query already matched.

## Open questions

- Should long-term memories carry explicit validity (`validFrom`,
  `invalidAt`) so superseded facts are filtered at recall time (Zep / Engram
  pattern)? Not implemented; `periodEnd` is used as the recency key.
- Should the agent tool expose FTS boolean syntax (`AND`, `OR`, `NOT`, `NEAR`)
  as LogicalRAG does? Deferred until the multi-query guidance is observed in
  real sessions.
