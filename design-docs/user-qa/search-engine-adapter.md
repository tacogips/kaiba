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

## Delta decisions taken without a user answer (2026-10-04)

These cover design sections D0-D5.

- **Config precedence.** A `searchEngine` section in the config file,
  enabled or not, locks the settings. The web settings show it read-only,
  and the server rejects settings mutations with
  `settings-managed-by-config`. Without the section, the store settings
  apply. This lets operators who manage kaiba by file keep full control.
- **Secret storage.** Store settings live under the existing reserved
  `auth.` prefix, at `auth.search-engine.settings` and
  `auth.search-engine.secret`. The generic, ungated `appSetting` and
  `setAppSetting` surface therefore cannot reach either key. The secret is
  stored in the note store the way the JWT signing secret is. It is
  write-only: reads return only `hasSecret`, and no partial mask is shown.
  The secret is bound to its auth mode, and choosing `none` deletes it.
- **Secret binding to target.** The stored secret is saved as
  `{authMode, target, secret}`, where `target` is the normalized base URL.
  It is reused only when both the auth mode and the target are unchanged.
  Otherwise an update or a test connection must supply the secret again.
  If it does not, the call is rejected with `searchEngine.secret` and
  makes no network call. This keeps an administrator call, or a stolen
  admin token, from sending the stored credential to another host. The
  web form requires re-entering the secret when the URL or auth mode
  changes. (Review finding DR-D5-SECRET-RETARGET.)
- **Credential sources.** Environment-variable credentials stay available
  through the config file only. Store settings take a typed secret.
- **Administrator gate.** The settings use the same gate as the API-client
  administration, `requireStoreAdministrator(in:)`. Non-admins get the
  existing not-found-shaped error, and the web section stays hidden for
  them. No new viewer or admin GraphQL field is added.
- **Hot-swap.** A shared `SearchEngineSlot` on `NoteService` lets scoped
  copies see a swapped adapter. An AppServer actor stops the old sync loop
  and starts a new one. A changed index identity reuses the durable SE3
  backfill.
- **Index version and identity.** The index moves to `-v2`. The identity
  now includes the normalized base URL, so switching clusters triggers a
  backfill. The old `-v1` index is not deleted automatically.
- **Ontology expansion.** It is deterministic tag-name matching in the
  store, with at most 10 tags: substring matching for CJK and whole-word
  matching for Latin. The boosts are direct tag 4.0 and tag or descendant
  2.0, against BM25 text at 1.0.
- **Related-note boosts.** Linked 5.0, shared tag 3.0, shared person or
  event tag +2.0, near tag (sibling, parent, child or ancestor) 1.5, and
  `more_like_this` text 1.0. The reasons come from Elasticsearch named
  queries. Shared-tag reasons are confirmed against the store.
- **Facets.** Engine aggregations over the engine-filtered set, computed
  only on request. The counts can include notes the store re-check drops,
  such as pending ingests in a reachable library or entries one drain
  stale. They are shown as refinement hints.
- **Agent tool.** The agent `search_notes` tool uses the engine when it is
  attached and `include_linked` is false. It falls back to FTS on any
  engine error. `AIAgenticSearch` grounding stays on FTS.
- **TLS verification toggle.** `verifyTLS: false` is offered, as requested.
  It is allowed only with `https` and only where the Security framework is
  available, and the form shows a warning next to it.

## Fusion and lightweight engine (2026-10-05)

Decisions taken without a user answer for
`design-docs/specs/design-search-engine-fusion.md` (F1-F6).

- **Where fusion applies.** GraphQL `searchNotes` with
  `includeLinked: true`, the agent `search_notes` tool (both
  `include_linked` values) and `AIAgenticSearch` grounding. `searchNotes`
  without `includeLinked`, the link picker, `kaiba search`, memo search
  and long-term-memory recall stay on FTS, because the web client already
  offers engine search through `engineSearchNotes` and the link picker was
  kept on FTS earlier.
- **Fallback.** With no engine, or after any engine error in a call,
  each path runs today's code. There is no partial engine contribution and
  no per-call health probe. A thrown error is the unhealthy signal.
- **Weights.** Engine and full-text lists weigh 1.0 each per query. The
  grounding weights stay full query 2.0 and terms 1.0. RRF `k` stays 60.
  Coverage is reported, not used as a cross-source sort key.
- **Related-notes signals** are not fused into search paths, which have
  no source note. The Meilisearch adapter fuses its own related and
  expansion sub-queries with the same reranker.
- **Provenance.** Additive GraphQL field
  `NoteSearchResult.provenance { sources, reasons }`, a per-result
  `provenance` key in the agent tool output when the engine was used, and
  a sources suffix in the agentic context. The web client does not show
  it yet.
- **Agent output with no engine** stays byte-identical, with no
  `provenance` key.
- **Engine choice.** Meilisearch, for its built-in Japanese segmentation,
  small single-binary footprint and optional key. Typesense keeps the
  index in RAM and always needs a key. Manticore's stock CJK handling is
  n-gram only. The live Japanese assertion is the acceptance gate.
- **No capability flags.** Meilisearch gaps (no `more_like_this`, no
  clause boosts) are closed inside the adapter, so the protocol and the
  Elasticsearch adapter do not change.
- **Meilisearch auth modes** are `none` and `apiKey`. `basic` is
  rejected with `searchEngine.authMode`.
- **Japanese locale.** The Meilisearch index forces locale `jpn` for Han
  text, so kanji-only notes are not segmented as Chinese.
- **Deep pages.** A fused window above 1000 results runs on FTS only.
  This bounds the fused candidate count.

## Open questions

- Should kaiba offer a `kaiba search-engine detach` command? It would clear
  the activation marker and the outbox once an operator has permanently
  stopped using an engine. Today the outbox stays bounded at one row per
  note.
- Should an optional `analyzer: "kuromoji"` setting be supported for
  clusters that have the `analysis-kuromoji` plugin, to improve Japanese
  morphology over bigrams?
- Should engine search also cover the link-picker popup
  (`NoteSearchPopup`)? It stays on FTS. The agent `search_notes` tool is
  now covered by delta D4.
- (Resolved 2026-10-05 by F1.) Should `AIAgenticSearch` grounding also
  retrieve candidates from the engine? Yes, fused with its FTS term lists,
  with an exact FTS fallback.
- Should the Meilisearch locale be configurable (for example `cmn` for
  Chinese-language stores) instead of the fixed `jpn`?
- Should there be a cross-call circuit breaker, so that an engine that is
  timing out stops being queried for a while? Today each call pays at
  most one engine timeout before it falls back.
- Should `searchNotes` without `includeLinked`, or the link picker, also
  use fusion when an engine is attached?
- Should the web client show retrieval provenance (for example "engine",
  "tag match", "linked") next to search results?
- Should the fusion weights be adjustable per store? They are fixed
  constants for now.
- Should tag rename, merge or delete APIs be added? None exist today. Any
  future rename must call the subtree enqueue described in D1.
- Should the related-note and expansion boosts be adjustable per store?
  They are fixed adapter constants for now.
- Is non-loopback plain `http`, for example a LAN cluster without TLS,
  needed? If so, it would take an explicit opt-in flag like Turso's
  `allowInsecureLoopbackHTTP`.
