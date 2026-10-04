# P3 Elasticsearch adapter, factory and configuration validation

**Status**: Step 6 implementation complete; downstream review pending
**planId**: P3-elasticsearch-adapter
**Wave**: 2
**dependsOn**: P1-core-contract
**Design Reference**: `design-docs/specs/search-engine-adapter.md` SE2 (validation), SE8, SE9 (live test)
**Index**: `impl-plans/active/search-engine-adapter.md`

## Intent and context

This plan implements the only adapter, `ElasticsearchSearchEngine`. It
conforms to the P1 `SearchEngine` protocol over the Elasticsearch 8.x REST
API using URLSession. It also implements `SearchEngineFactory`, which
validates the `searchEngine` section and builds the adapter.

- All Elasticsearch JSON, URLs and headers stay private to
  `Sources/AppCore/Elasticsearch*.swift`.
- No new SwiftPM dependency.
- Linux builds need `#if canImport(FoundationNetworking)` /
  `import FoundationNetworking`. See the top of
  `Sources/AppCore/TursoHTTPDatabase.swift`.
- Pattern to imitate for the transport:
  `Sources/AppGraphQL/GraphQLHTTPDocumentClient.swift:URLSessionGraphQLHTTPTransport`,
  which uses `URLSession.shared.data(for:)` behind a protocol and is
  injectable in tests.

## Non-goals

- No other engines, no index aliases, and no deletion of old indices.
- No kuromoji support.
- No retries inside the adapter. Retries belong to the outbox (P2/P4).
- No changes to the protocol, value types or configuration struct. Those
  belong to P1 and are read-only here.

## writePaths

- `Sources/AppCore/SearchEngineFactory.swift`
- `Sources/AppCore/ElasticsearchSearchEngine.swift`
- `Sources/AppCore/ElasticsearchHTTPTransport.swift`
- `Sources/AppCore/ElasticsearchRequestBodies.swift`
- `Tests/AppCoreTests/ElasticsearchSearchEngineTests.swift`
- `Tests/AppCoreTests/SearchEngineFactoryTests.swift`
- `Tests/AppCoreTests/ElasticsearchLiveTests.swift`
- `impl-plans/active/search-engine-adapter-p3-elasticsearch-adapter.md`

New files: `Sources/AppCore/SearchEngineFactory.swift`, `Sources/AppCore/ElasticsearchSearchEngine.swift`, `Sources/AppCore/ElasticsearchHTTPTransport.swift`, `Sources/AppCore/ElasticsearchRequestBodies.swift`, `Tests/AppCoreTests/ElasticsearchSearchEngineTests.swift`, `Tests/AppCoreTests/SearchEngineFactoryTests.swift`, `Tests/AppCoreTests/ElasticsearchLiveTests.swift`.

## sharedPaths (read-only)

- `Sources/AppCore/SearchEngine.swift`
- `Sources/AppCore/KaibaConfiguration.swift`

## sharedPathNotes

- `Sources/AppCore/SearchEngine.swift`: read-only: P1 contract.
- `Sources/AppCore/KaibaConfiguration.swift`: read-only: P1
  `KaibaSearchEngineConfiguration` and `KaibaConfigurationError`.

## File-level changes

### `ElasticsearchHTTPTransport.swift`

- `protocol ElasticsearchHTTPTransport: Sendable { func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) }`
  is internal.
- `struct URLSessionElasticsearchTransport: ElasticsearchHTTPTransport` uses
  `URLSession.shared.data(for:)`. A response that is not an
  `HTTPURLResponse` maps to `SearchEngineError.invalidResponse`.
- Request timeouts are set on each `URLRequest`: 10 seconds for health,
  ensureIndex, search and related, and 30 seconds for `_bulk`.

### `ElasticsearchSearchEngine.swift`

- `public struct ElasticsearchSearchEngine: SearchEngine` has an internal
  init:
  `init(baseURL: URL, indexPrefix: String, authorization: ElasticsearchAuthorization, transport: any ElasticsearchHTTPTransport = URLSessionElasticsearchTransport())`.
- `enum ElasticsearchAuthorization: Sendable, Equatable` has the cases
  `none`, `apiKey(String)` and `basic(username: String, password: String)`.
  It is internal.
- `indexName = "\(indexPrefix)-notes-v1"`, and
  `indexIdentity = "elasticsearch:\(indexName)"`.
- Headers:
  - `ApiKey <value>` and `Basic <base64(user:pass)>` go in
    `Authorization`; `none` sends no header.
  - `Content-Type` is `application/json`, except `_bulk`, which uses
    `application/x-ndjson`.
- `health()`: `GET /_cluster/health`. A status of `green` or `yellow` gives
  `isAvailable: true`. `red` gives `isAvailable: false`, with the status as
  the detail. A transport error throws `.unavailable`.
- `ensureIndex()`:
  - `HEAD /<index>`: 200 means done.
  - 404 leads to `PUT /<index>` with the settings and mappings body.
  - On the PUT, a 400 whose body `error.type` is
    `resource_already_exists_exception` counts as success.
  - Any other non-2xx response throws through the error mapping below.
- `apply(_:)`:
  - An empty array returns `[]` without any request.
  - Otherwise `POST /_bulk` with an NDJSON body:
    - `{"index":{"_index":"<idx>","_id":"<noteId>"}}` followed by the
      document source line, or `{"delete":{"_index":"<idx>","_id":"<noteId>"}}`;
    - every line ends with `\n`, including the last.
  - Parse `items[]` in order, producing one result per operation.
    - Item status 2xx is success.
    - A delete with status 404 is success.
    - Otherwise `.failed("<error.type>: <error.reason>")`.
  - An HTTP-level non-2xx status throws, per the error mapping.
- `search(_:)`:
  - Send `POST /<index>/_search` with:
    - `from` and `size`;
    - `_source: ["note_id"]`;
    - a `bool` query whose `must` is
      `multi_match{query, fields:["title^3","body","tags^2","context"], operator:"or"}`;
    - the filter clauses (below) and the `must_not` clauses;
    - `highlight{fields:{body:{}, title:{}}, fragment_size:160, number_of_fragments:1, pre_tags:[""], post_tags:[""]}`.
  - The returned `highlight` is the first fragment, body before title.
- `relatedNotes(_:)`:
  - `POST /<index>/_search` with
    `more_like_this{fields:["title","body","tags","context"], like: likeText, min_term_freq:1, min_doc_freq:1, max_query_terms:25}`
    inside the same `bool` with filter and `must_not`, plus `size` and
    `_source:["note_id"]`.
  - No highlight is requested.
  - Hits come back with `highlight: nil`.
- Hit parsing: `noteId` from `_source.note_id` (falling back to `_id`) and
  `score` from `_score`. A missing `hits.hits` throws `.invalidResponse`.
- Error mapping, for any non-2xx response not handled above:
  - 401 or 403: `.rejected(status, "<error.type>")`.
  - Other 4xx: `.rejected(status, "<error.type>: <error.reason>")`, with the
    reason truncated to 200 characters.
  - 5xx: `.unavailable("HTTP <status>")`.
  - A `URLError` or other transport error: `.unavailable("<URLError code>")`.
  - Never include request headers, the URL userinfo, or the request body in
    any message.

### `ElasticsearchRequestBodies.swift`

Internal pure functions that build JSON as `[String: Any]`, serialized with
`JSONSerialization` and `.sortedKeys`, so tests can compare
deterministically:

- **Index settings.** `analysis` uses the built-in `cjk` analyzer. Shard and
  replica settings are left out.
- **Mappings.**
  - `dynamic: "strict"`.
  - `keyword`: `note_id`, `notebook_id`, `library_id`, `owner_user_id`,
    `tag_ids`.
  - `boolean`: `long_term_memory`.
  - `date`: `created_at`, `updated_at`.
  - `text` with `analyzer: "cjk"`: `title`, `body`, `tags`, `context`.
- **Document source.** Map `SearchIndexDocument` field by field to the
  snake_case names above. `tags` is the tag names joined with spaces.
- **Filter clauses.**
  - `libraryIds` non-nil: `terms library_id`.
  - `ownerUserId`: `term owner_user_id`.
  - `notebookId`: `term notebook_id`.
  - Non-empty `tagIds`: `terms tag_ids`.
  - `must_not`: `term long_term_memory: true` when `excludesLongTermMemory`,
    and `ids` with `excludedNoteIds` when that list is non-empty.
- **Empty library list.** `libraryIds == []` must never reach the adapter,
  because P5 short-circuits it. If it does arrive, the adapter must return
  `[]` without a request. Never send `terms: []` and never drop the clause.

### `SearchEngineFactory.swift`

`public enum SearchEngineFactory` with
`static func make(configuration:environment:)` returns
`(any SearchEngine)?`.

- It returns nil when the configuration is nil or `isEnabled == false`.
- `kind` must equal `"elasticsearch"`. Otherwise it throws
  `KaibaConfigurationError.invalid("searchEngine.kind")`.
- `url` rules. Any failure throws `invalid("searchEngine.url")`.
  - It must parse with `URL(string:)`.
  - The scheme must be `http` or `https`.
  - The host must be non-empty.
  - `user` and `password` (userinfo) must be nil.
  - `http` is allowed only when the host is `localhost`, `127.0.0.1` or
    `::1`. Compare case-insensitively, and accept `[::1]` brackets as
    Foundation reports them.
- `resolvedIndexPrefix` must match `^[a-z0-9][a-z0-9_-]{0,63}$`. Otherwise
  it throws `invalid("searchEngine.indexPrefix")`.
- Credentials:
  - `apiKeyEnvironmentVariable` combined with either the username or the
    password variable is `invalid("searchEngine.credentials")`.
  - Exactly one of the username and password variables is also
    `invalid("searchEngine.credentials")`.
  - A named variable that is missing or empty in `environment` throws
    `missingEnvironmentVariable(name)`.
- It builds `ElasticsearchSearchEngine` with the matching authorization.

### Test-only seam

The tests need the adapter with a mock transport. They use
`@testable import AppCore` and the internal init. `ElasticsearchLiveTests`
builds the adapter through the factory, so the real URLSession path runs.

## Pitfalls

- NDJSON must end with a newline, or Elasticsearch rejects the bulk request.
- Never log or embed the API key or password. Error tests assert this.
- Do not import or reference any Elasticsearch type outside the
  `Elasticsearch*.swift` files and the factory.
- `JSONSerialization` with `.sortedKeys` is required for deterministic test
  comparisons. Compare parsed JSON objects, not raw strings, where key order
  could vary.
- `HEAD` responses have no body; do not try to decode one.
- Swift 6: the struct and transport must be `Sendable`. Do not capture
  non-Sendable state.

## Tests

`ElasticsearchSearchEngineTests` (XCTest, with a recording mock transport
that returns scripted `(status, body)` pairs):

- `indexIdentity` for prefix "kaiba" is `"elasticsearch:kaiba-notes-v1"`.
- `ensureIndex`:
  - HEAD 200 sends exactly 1 request and no PUT.
  - HEAD 404 then PUT 200 sends a PUT to `/kaiba-notes-v1` whose body has
    `mappings.dynamic == "strict"`, `properties.title.analyzer == "cjk"`
    and `tag_ids.type == "keyword"`.
  - HEAD 404 then PUT 400 with `resource_already_exists_exception`
    succeeds.
  - HEAD 404 then PUT 400 with another type throws `.rejected(400, ...)`.
- `apply`:
  - An upsert and a delete produce 2 NDJSON pairs. The body ends with `\n`,
    and the content type is `application/x-ndjson`.
  - Items `[201, 404-on-delete]` give `[.succeeded, .succeeded]`.
  - An item status 400 with `mapper_parsing_exception` gives
    `.failed("mapper_parsing_exception: ...")`.
  - HTTP 503 throws `.unavailable`.
  - An empty array sends 0 requests.
- `search`:
  - With filter libraryIds `[a,b]`, owner `u`, notebook `n`, tags `[t]`,
    excludesLongTermMemory true and excludedNoteIds `[x]`, the body has
    `terms library_id [a,b]`, `term owner_user_id u`,
    `term notebook_id n`, `terms tag_ids [t]`,
    `must_not long_term_memory` and `ids [x]`.
  - The multi_match fields equal `["title^3","body","tags^2","context"]`.
  - The highlight pre and post tags are `[""]`.
  - A response with a highlight gives `hit.highlight` equal to the first
    body fragment.
  - `libraryIds: nil` gives no `library_id` clause.
  - `libraryIds: []` gives `[]` and 0 requests.
- `relatedNotes`: the body contains `more_like_this.like` equal to the
  likeText, `min_doc_freq` 1, the `ids` must_not entry, and no `highlight`.
- Authorization:
  - apiKey sends `Authorization: ApiKey k`.
  - basic sends `Basic base64("u:p")`.
  - none sends no Authorization header.
  - For each of 401 and 403, the thrown error's description does not
    contain the key or password.
- `health`: `yellow` is available, `red` is unavailable, and a transport
  `URLError` throws `.unavailable`.

`SearchEngineFactoryTests` (XCTest):

- nil configuration and `enabled: false` both give nil.
- `kind: "opensearch"` throws `invalid("searchEngine.kind")`.
- These URLs throw `invalid("searchEngine.url")`:
  - `http://es.example.com:9200`
  - `https://user:pw@es.example.com`
  - `ftp://127.0.0.1`
  - `not a url`
- These URLs are accepted: `http://127.0.0.1:9200`, `http://localhost:9200`
  and `https://es.example.com`.
- `indexPrefix: "Kaiba"` throws.
- API key plus username throws `invalid("searchEngine.credentials")`.
- A username without a password throws.
- An API key variable named but absent from the environment throws
  `missingEnvironmentVariable(name)`.
- A valid configuration returns an engine whose `indexIdentity` is
  `"elasticsearch:kaiba-notes-v1"`.

`ElasticsearchLiveTests` (XCTest):

- Every test calls
  `try XCTSkipUnless(ProcessInfo.processInfo.environment["KAIBA_ELASTICSEARCH_URL"] != nil)`.
- The engine is built through the factory with
  `indexPrefix = "kaiba-test-<lowercased uuid prefix 8>"`.
- Steps, in order:
  1. Run ensureIndex twice; the second call proves it is idempotent.
  2. Apply upserts for 3 documents. One has an English body about the
     weather. One has the Japanese body
     `"\u{6771}\u{4EAC}\u{306E}\u{5929}\u{6C17}"`. Write it as Swift Unicode
     escapes so the source stays ASCII, following the existing `\u{...}`
     usage in Tests.
  3. Refresh with `POST /<index>/_refresh` through a raw URLSession request
     in the test.
  4. Search "weather". It returns the English document.
  5. Search `"\u{6771}\u{4EAC}"`. It returns the Japanese document.
  6. Call relatedNotes. Its results exclude the source note.
  7. Delete one document, refresh, and search again. The deleted document
     is no longer found.
- Teardown always sends `DELETE /<index>` (best effort).

## Verification

```bash
mise run build
bash -c 'mkdir -p tmp/search-engine-adapter/P3 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter ElasticsearchSearchEngine 2>&1 | tee tmp/search-engine-adapter/P3/adapter.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P3 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter SearchEngineFactory 2>&1 | tee tmp/search-engine-adapter/P3/factory.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P3 && env -u KAIBA_ELASTICSEARCH_URL PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter ElasticsearchLive 2>&1 | tee tmp/search-engine-adapter/P3/live-skipped.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P3 && mise run lint 2>&1 | tee tmp/search-engine-adapter/P3/lint.log; echo exit=${PIPESTATUS[0]}'
bash -c '! grep -rln "ElasticsearchSearchEngine\|ElasticsearchHTTPTransport\|ElasticsearchAuthorization" Sources --include=*.swift | grep -v "Sources/AppCore/Elasticsearch" | grep -v "Sources/AppCore/SearchEngineFactory.swift"'
wc -l Sources/AppCore/Elasticsearch*.swift Sources/AppCore/SearchEngineFactory.swift
```

Expected evidence:

- `exit=0` for every run.
- The `live-skipped.log` shows the live tests as skipped, not failed.
- The grep guard prints nothing and exits 0.
- Every file is under 1000 lines.

The live run against Docker is P11's job. If `KAIBA_ELASTICSEARCH_URL` is
already available locally, you may also run it and record the result.

## Done criteria

- [x] The adapter conforms to `SearchEngine`, with the request shapes,
      parsing and error mapping specified above.
- [x] The factory enforces every SE2 validation rule, with the exact error
      values.
- [x] Mock-transport tests and factory tests pass. The live test skips
      cleanly when unset.
- [x] No Elasticsearch symbol appears outside the adapter and factory files.

## Progress Log

- 2026-10-04: Plan created.
- 2026-10-04: Implemented the URLSession transport, Elasticsearch request bodies and adapter, SearchEngineFactory validation, mock-transport/factory/live integration tests. New source/test paths had no pre-edit file hash; final SHA-256 values: SearchEngineFactory.swift `0a9e28af60651bd5598b8dfcc089cf17ce60bca5ae9bb7aae9a17d7eceb53996`; ElasticsearchSearchEngine.swift `fcbcab394ac9fcb4eabf6da6ee4da6729f35edcd565f5da3132fbea7bb13db48` (pre-redaction hash `92d9451ef4395f1bea795aca16c8a858e89acc0384c990af1c93a3e744f348a9`); ElasticsearchHTTPTransport.swift `82939873ca5b52a8cf98cf1e58f9eaaf4ae76df88a94bfe4ceb319c7166d6248`; ElasticsearchRequestBodies.swift `d7843fe3de1955c721d0b9e961d743eb95fcd2a7d7b9c29824be279b79be1e09`; ElasticsearchSearchEngineTests.swift `f40b8daac597a9aaef3cefe45fd1a055ffee3860f607d38d65924ea15fce8cbc`; SearchEngineFactoryTests.swift `3f8f967a82d5347b06fd9112bcaa0adb96ce92783d6ab59a8fe915feb1588a13`; ElasticsearchLiveTests.swift `2ac866db75cb31447e9a0e307fa856d0f8acfd634385610cde19f99fd23daeea`. Shared contract inputs remained read-only.
- 2026-10-04: `mise run build` passed (exit 0; `tmp/search-engine-adapter/P3/build-final.log`). The first build log recorded transient compile errors in shared search-service/synchronizer files while downstream work was in progress; a later build on the stable shared source passed.
- 2026-10-04: Focused final-source tests passed: `swift test --filter ElasticsearchSearchEngine` (8 tests, 0 failures; `tmp/search-engine-adapter/P3/attempt-3-adapter.log`); `swift test --filter SearchEngineFactory` (4 tests, 0 failures; `tmp/search-engine-adapter/P3/attempt-3-factory.log`); with `KAIBA_ELASTICSEARCH_URL` unset, `swift test --filter ElasticsearchLive` skipped 1 test and had 0 failures (`tmp/search-engine-adapter/P3/attempt-3-live-skipped.log`). An earlier adapter-test attempt exposed direct NSLock calls in the async mock; moved locking into a synchronous helper and reran successfully.
- 2026-10-04: Exact changed-file SwiftLint passed using the nonempty NUL-delimited manifest `tmp/search-engine-adapter/P3/changed-swift-files.nul` (exit 0; `tmp/search-engine-adapter/P3/swiftlint-changed-final.log`). Repository `mise run lint` passed with 3 non-serious repository findings (exit 0; `tmp/search-engine-adapter/P3/lint-final.log`). Symbol-boundary grep, line counts (all adapter/factory source files under 1000 lines), and `git diff --check` passed.
- 2026-10-04: After changing the live test to use the explicit `try XCTSkipUnless` API, reran it with `KAIBA_ELASTICSEARCH_URL` unset: 1 test skipped, 0 failures (exit 0; `tmp/search-engine-adapter/P3/final-live-skipped.log`). Re-ran selected-file SwiftLint and repository `mise run lint` on the final test source; both exited 0 (`swiftlint-changed-final2.log`, `lint-final2.log`). Final source-boundary grep, line counts, and whitespace check exited 0 (`source-shape-final.log`).
- Step 6 complete. Independent test-integrity/adversarial review and workflow finalization are downstream.
- 2026-10-04 Step 6 rerun: all seven P3 source/test SHA-256 hashes still match the final hashes above. `mise run build`, exact-file strict SwiftLint, and repository `mise run lint` passed (`tmp/search-engine-adapter/P3/step6-rerun/`). `swift test --skip-build` ran the existing source-matched XCTest binary: adapter 8/8 passed, factory 4/4 passed, and the unset-URL live test skipped (1 skipped, 0 failures). Fresh compile-enabled adapter, factory, and live test commands could not compile because the shared pending P6 `NoteGraphQLDocumentExecutor.swift` calls `searchEngineCapability`, `engineSearchNotes`, and `relatedNotes` methods not yet present on `GraphQLNoteGraphQLService`; complete logs are `adapter.log`, `factory.log`, and `live-skipped.log` in that directory. Those methods are P6-owned and were not edited here. No live Elasticsearch cluster test was run.
- 2026-10-04 Step 6 continuation: on the updated combined source, `mise run build` passed and fresh compile-enabled `swift test --filter ElasticsearchSearchEngine` passed 8/8 while `swift test --filter SearchEngineFactory` passed 4/4 (`tmp/search-engine-adapter/P3/step6-current/`). With `KAIBA_ELASTICSEARCH_URL` unset, the live suite skipped its one test and reported 0 failures. The exact seven-file strict SwiftLint check passed; repository `mise run lint` exited 0 with 3 non-serious repository findings. Symbol-boundary grep, source line counts (all below 1000), and `git diff --check` passed. P6 methods now compile in the shared tree. Live cluster execution remains P11-owned and was not run.
- 2026-10-04 final Step 6 source-matched rerun: adapter suite passed 8/8, factory suite passed 4/4, and the unset-URL live suite skipped 1 test with 0 failures; all three commands exited 0. Logs: `tmp/search-engine-adapter/P3/step6-final-2/adapter.log`, `factory.log`, and `live-skipped.log`. Source-boundary grep, line counts, and whitespace check exited 0 (`source-shape.log`). All seven adapter/factory source and test hashes still match the recorded final hashes. The live cluster run remains P11-owned.
