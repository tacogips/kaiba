# P3 Meilisearch adapter, factory and settings integration

**Status**: Not Started
**planId**: P3-meilisearch-adapter
**Wave**: 2
**dependsOn**: P1-fusion-contract (neutral transport and `NoteRetrievalReranker.fuse`)
**Design Reference**: `design-docs/specs/design-search-engine-fusion.md` F3 (all subsections) and F4
**Index**: `impl-plans/active/search-engine-fusion.md`

## Intent and context

Add a Meilisearch implementation of the existing `SearchEngine` protocol.
Close its gaps inside the adapter: ontology expansion and related notes run
as multi-search sub-queries fused with `NoteRetrievalReranker.fuse`, writes
are task-based, and the hit window is limited. Register the adapter in the
factory so that config, store settings, test connection and hot-swap work
with no other change. The Elasticsearch adapter must stay byte-identical.

Repository facts and patterns to imitate:

- Protocol and value types: `Sources/AppCore/SearchEngine.swift`
  (`SearchEngine`, `SearchEngineQuery`, `SearchEngineFilter`,
  `SearchEngineRelatedQuery`, `SearchEngineRelatedSignals`,
  `SearchEngineHit`, `SearchEngineHitReason`, `SearchEngineFacets`,
  `SearchEngineError`, `SearchIndexOperation`, `SearchIndexDocument`).
- The adapter structure to mirror is
  `Sources/AppCore/ElasticsearchSearchEngine.swift`:
  - `indexIdentity`;
  - `init(baseURL:indexPrefix:authorization:requestTimeoutSeconds:verifyTLS:transport:)`;
  - the private helpers `send`, `requireSuccess`, `jsonObject` and
    `sanitized` (error-text truncation);
  - `hits(from:includeHighlight:)` and `facets(from:)`.
- Document field derivation: `Sources/AppCore/ElasticsearchRequestBodies.swift`
  shows how the D1 fields (`path_tag_ids`, `tag_classes`, `class_tag_keys`,
  `tag_provenance_keys`, link lists) are derived from `SearchIndexDocument`.
  Use the same field names and derivation, but do not edit that file.
- Factory: `Sources/AppCore/SearchEngineFactory.swift`:
  - `adapters` (line 4);
  - `make(configuration:environment:)`, which checks
    `configuration.kind == "elasticsearch"` at line 23;
  - `make(settings:secret:transport:)`, the validation chain and the
    construction of `ElasticsearchSearchEngine`.
- After P1, the transport protocol is `SearchEngineHTTPTransport`,
  aliased as `ElasticsearchHTTPTransport`, with
  `URLSessionSearchEngineTransport`.
- Settings validation (`NoteService+SearchEngineSettings.swift:validatedSettings`)
  maps a factory `KaibaConfigurationError.invalid(field)` to
  `SearchEngineSettingsError.invalid(field:)`. No change is needed there.
- Mock transport pattern: the private `RecordingElasticsearchTransport` in
  `Tests/AppCoreTests/ElasticsearchSearchEngineTests.swift:348`.
- SHA-256: import pattern of `Sources/AppCore/KaibaJWT.swift`
  (CryptoKit, or `Crypto` on Linux).

## Non-goals

- No protocol change and no capability flags.
- No edit to `ElasticsearchSearchEngine.swift`,
  `ElasticsearchRequestBodies.swift`, `SearchEngine.swift`,
  `NoteService+SearchEngine*.swift` or the runtime controller.
- No compose, mise or live test (that is P9). No README (P7). No web (P8).

## writePaths

- `Sources/AppCore/MeilisearchSearchEngine.swift`
- `Sources/AppCore/MeilisearchRequestBodies.swift`
- `Sources/AppCore/MeilisearchResponses.swift`
- `Sources/AppCore/SearchEngineFactory.swift`
- `Tests/AppCoreTests/MeilisearchSearchEngineTests.swift`
- `Tests/AppCoreTests/MeilisearchFactoryTests.swift`
- `Tests/AppCoreTests/SearchEngineFactoryTests.swift`
- `impl-plans/active/search-engine-fusion-p3-meilisearch-adapter.md`
- `tmp/search-engine-fusion/P3`

## sharedPaths (read-only)

- `Sources/AppCore/SearchEngine.swift`
- `Sources/AppCore/SearchEngineHTTPTransport.swift`
- `Sources/AppCore/NoteRetrievalReranker.swift`
- `Sources/AppCore/ElasticsearchSearchEngine.swift`
- `Sources/AppCore/ElasticsearchRequestBodies.swift`
- `Sources/AppCore/SearchEngineSettingsTypes.swift`
- `Sources/AppCore/NoteService+SearchEngineSettings.swift`
- `Sources/AppCore/NoteSearch.swift`

## sharedPathNotes

- `Tests/AppCoreTests/SearchEngineFactoryTests.swift`: intendedEdit:
  change only the expected `SearchEngineFactory.adapters` array in
  `testSettingsValidationAndNormalizedTargets` (line ~69) to list
  Elasticsearch, then Meilisearch. The accepted design appends a
  descriptor. Change no other assertion.
- `Sources/AppCore/MeilisearchSearchEngine.swift`: intendedEdit: new adapter file.
- `Sources/AppCore/MeilisearchRequestBodies.swift`: intendedEdit: new file for request bodies, filters and salient terms.
- `Sources/AppCore/MeilisearchResponses.swift`: intendedEdit: new file for response and error parsing.
- `Tests/AppCoreTests/MeilisearchSearchEngineTests.swift`: intendedEdit: new mock-transport tests.
- `Tests/AppCoreTests/MeilisearchFactoryTests.swift`: intendedEdit: new factory and settings tests.
- `Sources/AppCore/SearchEngineHTTPTransport.swift`: intendedEdit: read-only; the transport written by P1.
- `Sources/AppCore/NoteRetrievalReranker.swift`: intendedEdit: read-only; use `fuse`, written by P1.
- `Sources/AppCore/NoteSearch.swift`: intendedEdit: read-only; reuse `ftsTerms(from:)`.
- `tmp/search-engine-fusion/P3`: intendedEdit: generated evidence logs only.

## artifactRoots

- `tmp/search-engine-fusion/P3`

## File-level changes

### `SearchEngineFactory.swift`

- `adapters` becomes `[elasticsearch descriptor (unchanged), SearchEngineAdapterDescriptor(kind: "meilisearch", displayName: "Meilisearch", authModes: [.none, .apiKey])]`.
- `make(configuration:environment:)`:
  - replace the `kind == "elasticsearch"` check with membership in
    `adapters`;
  - for `meilisearch`, a username or password environment variable throws
    `invalid("searchEngine.credentials")`;
  - Elasticsearch behavior is unchanged, including that `"opensearch"`
    still throws `invalid("searchEngine.kind")`.
- `make(settings:secret:transport:)`:
  - after the kind check, require
    `descriptor.authModes.contains(settings.authMode)`, otherwise throw
    `invalid("searchEngine.authMode")`;
  - keep every existing validation in its current order;
  - then switch on the kind: `elasticsearch` builds the existing adapter
    exactly as today; `meilisearch` builds
    `MeilisearchSearchEngine(baseURL:indexPrefix:apiKey: secret when .apiKey, requestTimeoutSeconds:verifyTLS:transport:)`.

### `MeilisearchSearchEngine.swift` (under 450 lines)

- `public struct MeilisearchSearchEngine: SearchEngine`:
  - index uid `"\(indexPrefix)-notes-v1"`;
  - `indexIdentity` = `"meilisearch:\(normalizedTarget ?? absolute)/\(uid)"`;
  - the header `Authorization: Bearer <key>` only when a key is set;
  - `Content-Type: application/json`;
  - query, health and ensureIndex timeouts use `requestTimeoutSeconds`;
    writes and task waits use `max(30, requestTimeoutSeconds)`.
- `health()`: `GET /health`. `status == "available"` gives
  `isAvailable: true`; `detail` is the status word.
- `ensureIndex()`:
  - `GET /indexes/<uid>`. A 200 skips creation. A 404 sends
    `POST /indexes {uid, primaryKey: "id"}` and waits; a task error code
    `index_already_exists` counts as success.
  - Then always `PATCH /indexes/<uid>/settings` and wait.
- Task wait: poll `GET /tasks/<taskUid>`, starting at 50 ms and doubling up
  to 1 s, until `succeeded`, `failed` or `canceled`. When the deadline
  passes, throw `.unavailable("task pending")`.
- Test seam (internal, never public): the initializer takes two extra
  parameters, used only by tests:
  - `taskWaitTimeout: TimeInterval? = nil`. When nil, the deadline is
    `max(30, requestTimeoutSeconds)` seconds.
  - `initialTaskPollInterval: TimeInterval = 0.05`.

  `SearchEngineFactory` never passes either parameter, so the production
  bound and backoff from design F3 are unchanged. Do not expose them
  through settings, config or the factory.
- `apply(_:)`:
  - one upsert task, `POST /indexes/<uid>/documents?primaryKey=id`;
  - one delete task, `POST /indexes/<uid>/documents/delete-batch`;
  - return outcomes in input order. On a failed upsert task whose error
    code starts with `invalid_document` and which held more than one
    document, resubmit each upsert once as its own task and give each its
    own outcome. Any other failed task gives every operation of that task
    `.failed("<code>: <message>")`, truncated to 500 characters.
  - HTTP 401/403 throws `.rejected(status:reason:)`. 5xx and transport
    errors throw `.unavailable`.
  - An empty operation list returns `[]` with no request.
- `search(_:)`: `searchPage(_:).hits`.
- `searchPage(_:)`:
  - With no expansion ids: a single `POST /indexes/<uid>/search`.
  - With expansion ids: `POST /multi-search` with the text, tag and
    hierarchy queries, each fetching `from + size`. Fuse them with
    `NoteRetrievalReranker.fuse` as direct lists with weights 1.0, 1.0 and
    0.5. Each hit's reasons are the lists containing it, mapped to
    `.textMatch`, `.tagMatch` and `.tagHierarchyMatch`. Slice
    `[from, from + size)`. The score is the fused score, and the highlight
    comes from the text hit.
  - Facets come only from the text query.
- `relatedNotes(_:)`: one multi-search with the lists text-similarity,
  shared-tag, related-tag, shared-entity and linked. Skip empty lists. Fuse
  with weights 1.0, 3.0, 1.5, 2.0 and 5.0. The reasons are
  `.textSimilarity`, `.sharedTag`, `.relatedTag`, `.sharedEntity` and
  `.linked`. Truncate to `size`. With `signals == nil`, only the text list
  runs.

### `MeilisearchRequestBodies.swift` (under 450 lines)

- The document JSON uses the D1 field names (see the design's F3
  "Document"). `owner_user_id` is null when absent.
- The document id is the note id when it matches `^[A-Za-z0-9_-]{1,511}$`,
  otherwise `"x-" + lowercase hex SHA-256(utf8)`. Upsert and delete use the
  same function.
- The settings body is exactly as in design F3 "Index settings".
- `filterExpression(_ filter: SearchEngineFilter, extra: [String]) -> [String]`
  builds the ANDed array elements in the order given in design F3. String
  values are double-quoted with `\` escaped first, then `"`.
  `libraryIds == nil` adds no library clause. An empty `excludedNoteIds`
  adds no `NOT` clause.
- The search body sets:
  - `q`, `filter`, `offset`, `limit`;
  - `showRankingScore: true`, `showMatchesPosition: true`,
    `matchingStrategy: "last"`,
    `locales: ["jpn"]`;
  - `attributesToRetrieve: ["note_id", "title", "body"]` and
    `attributesToCrop: ["body", "title"]` with `cropLength: 24`;
  - `highlightPreTag`, `highlightPostTag` and `cropMarker` all `""`;
  - `facets` only when requested.

  Filter-only sub-queries add `sort: ["updated_at:desc"]` and omit the crop
  fields.
- `salientTerms(_ text: String) -> [String]`: the `ftsTerms` runs,
  lowercased, keeping runs of at least 2 characters, ordered by frequency
  descending then first occurrence, at most 10. The query is the terms
  joined by spaces.

### `MeilisearchResponses.swift` (under 300 lines)

- Parse hits: `note_id` and `_rankingScore`. Requests set
  `showMatchesPosition: true`. The highlight is `_formatted.body` when
  `_matchesPosition` has a `body` key, otherwise `_formatted.title` when it
  has a `title` key, otherwise nil. Trim it and cap it at 200 characters.
  If the live run (P9) shows that `_formatted` includes cropped attributes
  without retrieving them, P9 records that and P10 may narrow
  `attributesToRetrieve` to `note_id`. Do not guess here.
- Parse `facetDistribution` into count-desc, value-asc buckets truncated
  to the requested limits.
- Parse task status and errors. Error bodies
  `{message, code, type}` become `"<code>: <message>"`, truncated to 200
  characters. Never include headers, the key or the URL.

## Invariants

- `ElasticsearchSearchEngineTests` and all existing factory and settings
  tests pass. The only edited existing assertion is the adapters list.
- The Elasticsearch `indexIdentity` and requests are unchanged.
- No secret appears in any error string. Test this with a transport that
  echoes the key.
- Meilisearch files reference no AI or agent types (boundary grep).

## Pitfalls

- Meilisearch writes are asynchronous. Never report `.succeeded` before
  the task has succeeded.
- The factory path keeps the 30-second minimum. `SearchEngineFactory`
  must not pass `taskWaitTimeout` or `initialTaskPollInterval`. Do not
  "fix" a slow test by lowering the production bound or by using
  `requestTimeoutSeconds` directly.
- `maxTotalHits` must be in the settings body, or offsets above 1000 return
  nothing.
- Do not use `basic` for Meilisearch. The factory must reject it with
  `searchEngine.authMode` before any network call.
- Filter injection: never interpolate unescaped ids or class names.
- `fuse` sorts ties by note id. Fused pages are therefore deterministic.
  Do not re-sort by `_rankingScore` afterwards.
- `relatedNotes` must also exclude the source note through
  `excludedNoteIds` in every sub-query.
- Per-file budgets: keep every new file under the stated line limits.
  Split by responsibility, not arbitrarily.

## Tests

`MeilisearchSearchEngineTests` (XCTest, recording mock transport that
returns scripted responses by method and path):

- `health` with `{"status":"available"}` -> `isAvailable == true`. With a
  500 response -> throws `.unavailable`.
- `ensureIndex` when the index is absent -> requests in order: GET index
  (404), POST indexes, GET task, PATCH settings, GET task. The settings
  body contains `maxTotalHits` 2000, the `jpn` locale, and the
  filterable and sortable attributes from the design.
- `ensureIndex` when the index is present -> no POST indexes; PATCH
  settings is still sent.
- Create-task error `index_already_exists` -> success.
- `apply` with two upserts and one delete -> one documents POST and one
  delete-batch POST, outcomes in input order. A delete of an absent id
  succeeds.
- A failed upsert task with code `invalid_document_id` for two docs -> two
  single-document resubmissions with individual outcomes.
- Construct the adapter directly (not through the factory) with
  `taskWaitTimeout: 0.2` and `initialTaskPollInterval: 0.01`, using a
  transport that always answers `{"status":"processing"}` for
  `GET /tasks/<uid>`. Call `apply` -> throws `.unavailable("task pending")`,
  and the test finishes in under 2 seconds (assert with a measured
  elapsed time).
- 401 -> `.rejected`.
- A search with library, owner, notebook, hierarchy, class and
  long-term-memory filters and excluded ids -> the exact `filter` array.
  Values containing `"` and `\` are escaped.
- Expansion ids present -> a `/multi-search` with 3 queries. Scripted
  results put tag-only note T first in the tag lists and text-only note X
  first in the text list -> T ranks above X. Reasons are
  `[tagMatch, tagHierarchyMatch]` for T and `[textMatch]` for X.
- Related with signals -> 5 queries. A linked note outranks a shared-tag
  note, which outranks a text-only note, with the expected reasons. The
  source is excluded in every query.
- Facets -> buckets sorted and truncated.
- The id `"note-1-abc"` maps to itself; `"note with space"` maps to
  `x-<64 hex>`. Delete uses the same mapping.
- The auth header is present for `apiKey` and absent for `none`.
- An error body containing the key -> the thrown description does not
  contain it.

`MeilisearchFactoryTests` (XCTest):

- `adapters` contains Meilisearch with `[.none, .apiKey]`.
- Settings kind `meilisearch` with `authMode .basic` -> throws
  `invalid("searchEngine.authMode")`.
- Through `NoteService.testSearchEngineConnection`, the same input gives
  status `invalid-settings` with detail `searchEngine.authMode`. Follow
  `SearchEngineSettingsTests` for admin setup.
- The config section `{kind: meilisearch, url: http://127.0.0.1:7700}` ->
  identity `meilisearch:http://127.0.0.1:7700/kaiba-notes-v1`.
- Meilisearch with `usernameEnvironmentVariable` -> throws
  `invalid("searchEngine.credentials")`.
- Meilisearch with `apiKeyEnvironmentVariable` set and present -> builds.
- An Elasticsearch config yields the same identity string as before
  (`elasticsearch:<target>/kaiba-notes-v2`).

## Verification

```bash
mkdir -p tmp/search-engine-fusion/P3
bash -c 'mise run build 2>&1 | tee tmp/search-engine-fusion/P3/build.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter "MeilisearchSearchEngineTests|MeilisearchFactoryTests" 2>&1 | tee tmp/search-engine-fusion/P3/meili.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter "ElasticsearchSearchEngineTests|SearchEngineFactoryTests|SearchEngineSettingsTests|KaibaSearchEngineConfiguration" 2>&1 | tee tmp/search-engine-fusion/P3/regression.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'mise run lint 2>&1 | tee tmp/search-engine-fusion/P3/lint.log; echo exit=${PIPESTATUS[0]}'
swiftlint lint --strict --quiet --no-cache Sources/AppCore/MeilisearchSearchEngine.swift Sources/AppCore/MeilisearchRequestBodies.swift Sources/AppCore/MeilisearchResponses.swift Sources/AppCore/SearchEngineFactory.swift Tests/AppCoreTests/MeilisearchSearchEngineTests.swift Tests/AppCoreTests/MeilisearchFactoryTests.swift
git diff --stat -- Sources/AppCore/ElasticsearchSearchEngine.swift Sources/AppCore/ElasticsearchRequestBodies.swift Sources/AppCore/SearchEngine.swift
git diff -- Tests/AppCoreTests/SearchEngineFactoryTests.swift
grep -nE "AIAgenticSearch|AgentInvok|AgentGateway|AgentReply|ClaudeSubscription" Sources/AppCore/Meilisearch*.swift
wc -l Sources/AppCore/Meilisearch*.swift Sources/AppCore/SearchEngineFactory.swift
```

Expected evidence:

- build `exit=0`.
- The Meilisearch run shows `exit=0` and `Executed N tests, 0 failures`
  with N >= 20.
- The regression run shows `exit=0` with N > 0.
- Strict swiftlint is clean.
- The Elasticsearch and protocol diff stat is empty.
- The factory-test diff touches only the adapters expectation.
- The boundary grep prints nothing.
- Every file is under its budget and under 1000 lines.

## Done criteria

- [ ] The adapter conforms to `SearchEngine` with the F3 behavior.
- [ ] The factory registers Meilisearch, enforces the auth-mode rule, and
      leaves Elasticsearch unchanged.
- [ ] Mock-transport and factory tests pass with positive counts, and the
      regressions pass.
- [ ] Evidence is recorded in the progress log.

## Progress Log

- 2026-10-05: Plan created.
