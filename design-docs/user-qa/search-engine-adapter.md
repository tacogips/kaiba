# Search Engine Adapter: decisions and open questions

Design: `design-docs/specs/search-engine-adapter.md`.

## Decisions taken without a user answer (2026-10-04)

- Consistency uses a durable outbox in the note store (store version 23),
  not best-effort pushes. Every indexed-text write already passes through
  `refreshFTS` or `deleteNoteRows`, so the outbox covers all of them in the
  write transaction, and an engine outage only delays indexing. Reversible.
- Engine search is a separate GraphQL field, `engineSearchNotes`, rather
  than a mode of `searchNotes`. This keeps the default path untouched and
  keeps BM25 ranks separate from engine scores. Engine hits do not feed
  into the FTS fusion.
- Access control is enforced twice: by an engine filter on library, owner,
  notebook, tags and long-term memory, and by a store re-check that uses
  the `searchNotes` predicates. Library membership changes need no reindex,
  because reachable libraries are resolved at query time.
- Text is analyzed with Elasticsearch's built-in `cjk` analyzer, so the
  stock image works with no plugins.
- Reindex and backfill are available from the CLI only, through
  `kaiba search-engine sync|reindex`, and require a store administrator.
  The server also backfills automatically on first activation and whenever
  the index identity changes. There is no GraphQL admin mutation.
- KaibaClient operations are hand-written, following the existing
  `KaibaOperations.swift` style, not generated.
- The local compose Elasticsearch runs with `xpack.security.enabled=false`
  and is bound to `127.0.0.1` only. This is documented as local-only.
- A plain `http` engine URL is accepted only for loopback hosts, so
  credentials are never sent unencrypted across a network. There is no
  override flag.

## Open questions

- Should kaiba offer a `kaiba search-engine detach` command? It would clear
  the activation marker and the outbox once an operator has permanently
  stopped using an engine. Today the outbox stays bounded at one row per
  note.
- Should an optional `analyzer: "kuromoji"` setting be supported for
  clusters that have the `analysis-kuromoji` plugin, to improve Japanese
  morphology over bigrams?
- Should engine search also cover the link-picker popup
  (`NoteSearchPopup`) and the agent `search_notes` tool? Both stay on FTS
  for now.
- Is non-loopback plain `http`, for example a LAN cluster without TLS,
  needed? If so, it would take an explicit opt-in flag like Turso's
  `allowInsecureLoopbackHTTP`.
