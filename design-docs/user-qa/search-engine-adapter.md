# Search Engine Adapter: decisions and open questions

Design: `design-docs/specs/search-engine-adapter.md`.

The Elasticsearch adapter was removed in 137c6f7 (2026-10-05); Meilisearch
is the only and default adapter. Decisions below that are specific to
Elasticsearch are marked "(Historical)" and no longer describe current
behavior. The reason for the removal is recorded in the design's Status
section.

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
- (Historical) Text is analyzed with Elasticsearch's built-in `cjk`
  analyzer, so the stock image works with no plugins. Meilisearch uses its
  built-in segmentation with the `jpn` locale (fusion F3).
- Reindex and backfill are available from the CLI only, through
  `kaiba search-engine sync|reindex`, and require a store administrator.
  The server also backfills automatically on first activation and whenever
  the index identity changes. There is no GraphQL admin mutation.
- KaibaClient operations are hand-written, following the existing
  `KaibaOperations.swift` style, not generated.
- (Historical) The local compose Elasticsearch runs with
  `xpack.security.enabled=false` and is bound to `127.0.0.1` only. This is
  documented as local-only. The Meilisearch compose service follows the
  same rule without a master key (fusion F5).
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
  queries (Historical: the Meilisearch adapter composes related notes and
  their reasons from sub-queries, fusion F3). Shared-tag reasons are
  confirmed against the store.
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
  Elasticsearch adapter do not change. (The Elasticsearch adapter was
  later removed in 137c6f7.)
- **Meilisearch auth modes** are `none` and `apiKey`. `basic` is
  rejected with `searchEngine.authMode`.
- **Japanese locale.** The Meilisearch index forces locale `jpn` for Han
  text, so kanji-only notes are not segmented as Chinese.
- **Deep pages.** A fused window above 1000 results runs on FTS only.
  This bounds the fused candidate count.

## Backend-only engine boundary (2026-10-05)

Decisions taken without a user answer for
`design-docs/specs/search-engine-adapter.md` B0-B8. The premise comes from
the user: only the kaiba backend talks to the search engine, and clients
never need its coordinates or credentials.

- **Premise and audit.** The audit of 137c6f7 (B1) found one real leak:
  the adapter descriptor's `defaultURL`, which carried the server's
  `KAIBA_MEILISEARCH_URL` value or the built-in fallback through GraphQL,
  KaibaClient and the web settings prefill. The config-case settings read
  also returned the resolved URL, and a save required a URL, which pushed
  engine coordinates onto the client. All engine query fields, logs, CLI
  output and test-connection details were already compliant.
- **Remove the descriptor field `defaultURL`.** The
  `SearchEngineAdapterDescriptor.defaultURL` field and
  `SearchEngineFactory.adapters(environment:)` are removed from AppCore,
  and the field is removed from GraphQL, KaibaClient and the web client.
  It was never in a release (latest tag `v0.1.16`), so no deprecation
  period is needed. The backend resolver
  `SearchEngineFactory.defaultURL(for:environment:)` keeps its name; it is
  backend-only, so the verification grep for `defaultURL` covers
  `web/src`, `Sources/AppGraphQL` and `Sources/KaibaClient`, plus targeted
  AppCore checks on the descriptor file and `adapters(environment`.
- **Omitted URL means server default.** For update, test connection, the
  stored record and the config section, an omitted, null, empty or
  whitespace-only URL is the server default. The backend resolves it with
  `SearchEngineFactory.defaultURL(for:environment:)`:
  `KAIBA_MEILISEARCH_URL`, then `SearchEngineFactory.fallbackMeilisearchURL`,
  each time it builds an engine. Treating empty like omitted everywhere
  avoids a third state that would only produce `searchEngine.url` errors.
- **Persist the marker, not the value.** A server-default save stores the
  settings without a `url` key. An environment change then takes effect at
  the next start, and the existing identity check backfills the new
  index. Persisting the resolved value was rejected: the setting would
  silently ignore later environment changes, and an administrator could
  only see or correct it by learning the value on the client.
- **Secret stays bound to the resolved target.** The stored secret's
  `target` is the URL resolved at save, compared with the URL resolved at
  each use. If the environment moves to another engine, an API key is not
  sent there: the engine stays detached (FTS only, logged as
  `searchEngine.secret`) until an administrator enters the key again.
  Binding the secret to a "server default" marker instead was rejected,
  because it would send a stored key to whatever host the environment
  names, which breaks the D5 rule from DR-D5-SECRET-RETARGET.
- **Settings read returns `url: null` for the default.** `url` is the
  explicit URL (stored or config) or `null`. A non-`none` kind with
  `url: null` means server default, which the web form shows as `Server
  default`. No `usesServerDefault` field is added: the pair is already
  unambiguous, and the schema stays smaller. Returning the effective URL
  to administrators was rejected: the client does not need it, cannot
  change the environment, and the value can reveal internal hosts to every
  remote administrator session.
- **Test connection reports no URL.** The result stays
  `{available, status, detail}`, with the existing sanitizing. It never
  reports the resolved URL.
- **Loopback rule.** The plain-`http`-only-on-loopback rule applies to the
  backend's network position: loopback is the host running `kaiba serve`
  (for the Tauri local service, the user's Mac), not the client device.
- **Tauri CSP and capabilities stay as they are.** `csp: null` and the
  `http://*:*`/`https://*:*` capability exist so the shell can reach a
  kaiba server at any user-configured origin. They list no engine origin.
  An allowlist cannot exclude an engine origin without also blocking
  arbitrary kaiba servers, so the premise is enforced by never giving the
  client engine coordinates and by a `web/src` guard test. Narrowing them
  is out of scope.
- **Web guard.** A bun test fails if any file under `web/src` contains the
  engine port string, `defaultURL` or `KAIBA_MEILISEARCH_URL`; test
  fixtures use placeholders such as `https://search.example`.
- **Plan records.** `impl-plans/active/search-engine-fusion-dispatch.json`
  stays unchanged as a completed workflow record. Its port mentions refer
  to the server-host compose binding.

## Open questions

- Should kaiba offer a `kaiba search-engine detach` command? It would clear
  the activation marker and the outbox once an operator has permanently
  stopped using an engine. Today the outbox stays bounded at one row per
  note.
- (Obsolete since 137c6f7: Elasticsearch-only.) Should an optional
  `analyzer: "kuromoji"` setting be supported for clusters that have the
  `analysis-kuromoji` plugin, to improve Japanese morphology over bigrams?
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
- Should the Tauri shell narrow `csp` and the `http:default` capability,
  for example to the origin of the kaiba server the user configured? The
  B0 premise does not need it (B1 A11), so it is not part of B0-B8.
- Should an administrator be able to see which URL the server default
  resolves to, for example in `kaiba search-engine status` (already
  printed as part of `indexIdentity` on the server host) or in a future
  admin-only field? B4 returns `null` to clients for now.
