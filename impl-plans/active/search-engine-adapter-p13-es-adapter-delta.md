# P13 Elasticsearch adapter delta: -v2 mapping, ontology query, facets, hybrid related, settings factory

**Status**: Ready
**planId**: P13-es-adapter-delta
**Wave**: 2
**dependsOn**: P12-delta-contract, P3-elasticsearch-adapter
**Design Reference**: `design-docs/specs/search-engine-adapter.md` D1 "Elasticsearch mapping (index -v2)" and "Index identity bump"; D2 "Elasticsearch query (search)" and "Facet access rule"; D3 "Elasticsearch query (related)" and "Reasons"; D5 "Normalized connection settings and factory"
**Index**: `impl-plans/active/search-engine-adapter.md`

## Intent and context

The Elasticsearch adapter must index the D1 fields and answer the D2 and D3 queries through the P12 protocol additions. The factory must build adapters from normalized connection settings (D5), which are used both by the config file and by store settings, and it must publish the adapter registry.

All Elasticsearch JSON stays private to `Sources/AppCore/Elasticsearch*.swift` (invariant 5). Callers keep seeing only `any SearchEngine`.

Repository facts:

- `ElasticsearchSearchEngine.swift` (215 lines):
  - `init(baseURL:indexPrefix:authorization:transport:)`;
  - `indexName = "<prefix>-notes-v1"`;
  - query timeouts of 10 seconds and bulk of 30;
  - `hits(from:includeHighlight:)` parses responses;
  - `sanitized(_:)` redacts credentials.
- `ElasticsearchRequestBodies.swift` (147 lines) has `index`, `document`, `search`, `related`, `bulk`, `filter` and `mustNot`. It uses `JSONSerialization` with `.sortedKeys`, so request bodies are byte-stable for exact-body tests.
- `ElasticsearchHTTPTransport.swift` (18 lines) has the `URLSessionElasticsearchTransport` protocol implementation.
- `SearchEngineFactory.swift` (59 lines) has `make(configuration:environment:)` with the SE2 validation.
- The tests are `Tests/AppCoreTests/ElasticsearchSearchEngineTests.swift` (mock transport, exact bodies), `SearchEngineFactoryTests.swift` and `ElasticsearchLiveTests.swift` (env-gated; it hardcodes `"\(prefix)-notes-v1"` for cleanup).

## Non-goals

- No change to `SearchEngine.swift`; P12 owns it. If a type is missing, stop and log it.
- No service, GraphQL or web change.
- No index alias and no deletion of the old `-v1` index.
- No new SwiftPM dependency.
- No new live-test scenarios. P21 extends the live test; this plan only keeps it green on `-v2`.

## writePaths

- `Sources/AppCore/ElasticsearchSearchEngine.swift`
- `Sources/AppCore/ElasticsearchRequestBodies.swift`
- `Sources/AppCore/ElasticsearchHTTPTransport.swift`
- `Sources/AppCore/SearchEngineFactory.swift`
- `Tests/AppCoreTests/ElasticsearchSearchEngineTests.swift`
- `Tests/AppCoreTests/SearchEngineFactoryTests.swift`
- `Tests/AppCoreTests/ElasticsearchLiveTests.swift`
- `impl-plans/active/search-engine-adapter-p13-es-adapter-delta.md`

## sharedPaths (read-only)

- `Sources/AppCore/SearchEngine.swift`: read-only. The P12 contract.
- `Sources/AppCore/SearchEngineSettingsTypes.swift`: read-only. `SearchEngineConnectionSettings`, `SearchEngineAuthMode` and `SearchEngineAdapterDescriptor`.
- `Sources/AppCore/KaibaConfiguration.swift`: read-only. `KaibaSearchEngineConfiguration` and `KaibaConfigurationError`.

## File-level changes

### `ElasticsearchSearchEngine.swift`

**Init.** `init(baseURL: URL, indexPrefix: String, authorization: ElasticsearchAuthorization, requestTimeoutSeconds: Int = 10, verifyTLS: Bool = true, transport: (any ElasticsearchHTTPTransport)? = nil)`.

- When `transport` is nil, use `URLSessionElasticsearchTransport(insecureTrustHost: verifyTLS ? nil : baseURL.host)`.
- Existing test call sites that pass `transport:` must keep compiling. Keep the label, and update the test helper if needed.

**Index name and identity.**

- `indexName = "\(indexPrefix)-notes-v2"`.
- `indexIdentity = "elasticsearch:\(SearchEngineFactory.normalizedTarget(baseURL.absoluteString) ?? baseURL.absoluteString)/\(indexName)"`.

**Timeouts.** Query, health, HEAD/PUT index and search requests use `requestTimeoutSeconds`. Bulk uses `max(30, requestTimeoutSeconds)`.

**`searchPage(_:)`.**

1. `libraryIds == []` returns an empty page with no request.
2. Post `ElasticsearchRequestBodies.search(query)`.
3. Parse the hits with highlight, and the reasons from each hit's `matched_queries` (below).
4. When `query.facets != nil`, parse `aggregations.tag_classes.buckets` and `aggregations.tags.buckets`. Each bucket gives `key` (string) and `doc_count` (int) and becomes a `SearchEngineFacetBucket`.

`search(_:)` returns `try await searchPage(query).hits`.

**`relatedNotes(_:)`.** Return `[]` with no request when either:

- `libraryIds == []`; or
- the request body has no `should` clause, meaning a blank `likeText` and either no signals or all signal lists empty with no `sourceNoteId` clause.

`sourceNoteId` always yields the `linked` clause, so a non-nil `signals` always gives at least one clause.

Otherwise, post the related body and parse the hits and reasons, without highlight.

**Reasons.** `matched_queries` is a JSON array of strings in Elasticsearch 8 responses.

- Map each element through `SearchEngineHitReasonKind(rawValue:)`, ignoring unknown names, and keep the reasons in clause order.
- Do not request `include_named_queries_score`, because that turns the field into an object.

### `ElasticsearchRequestBodies.swift`

**Mapping (`index`).** Keep every existing field. Add keyword fields:

- `path_tag_ids`
- `path_tag_names`
- `tag_classes`
- `class_tag_keys`
- `tag_provenance_keys`
- `outgoing_link_note_ids`
- `incoming_link_note_ids`

**`document`.** Add these values:

- `path_tag_ids`: `pathTags.map(tagId)`.
- `path_tag_names`: `pathTags.map(name)`.
- `tag_classes`: the distinct non-nil `tagClass` values, sorted.
- `class_tag_keys`: `"<class>:<tagId>"` for each path tag that has a class, sorted.
- `tag_provenance_keys`: `"<provenance>:<tagId>"` per application, sorted.
- the two link arrays, as given.

**`search`.** Clauses use the exact boost values and `_name` strings from design D2.

- `query.bool.should`:
  - `{"multi_match": {..., "_name": "text-match"}}`, with the base fields and `operator: or`;
  - plus, only when `expansionTagIds` is non-empty:
    - `{"constant_score": {"filter": {"terms": {"tag_ids": ids}}, "boost": 4.0, "_name": "tag-match"}}`;
    - `{"constant_score": {"filter": {"terms": {"path_tag_ids": ids}}, "boost": 2.0, "_name": "tag-hierarchy-match"}}`.
- `minimum_should_match: 1`.
- `filter` keeps the base clauses and adds:
  - `{"terms": {"path_tag_ids": hierarchyTagIds}}` when non-empty;
  - one clause per class filter: `{"term": {"tag_classes": c}}`, or `{"term": {"class_tag_keys": "c:<tagId>"}}` when a tag is given.
- `must_not`, `highlight`, `from`, `size` and `_source` are unchanged.
- When `facets` is set, add `"aggs": {"tag_classes": {"terms": {"field": "tag_classes", "size": tagClassLimit}}, "tags": {"terms": {"field": "tag_ids", "size": tagLimit}}}`.

**`related`.** The `should` clauses, each added only when its list is non-empty:

- `more_like_this` with `_name: "text-similarity"`, when `likeText` is not blank. Its base parameters are unchanged.
- `shared-tag`: `terms tag_ids: sharedTagIds`, boost 3.0.
- `related-tag`: a `constant_score` whose filter is `{"bool": {"should": [terms path_tag_ids: nearTagIds, terms tag_ids: ancestorTagIds], "minimum_should_match": 1}}`, boost 1.5. Omit an empty inner terms clause.
- `shared-entity`: `terms class_tag_keys: entityTags.map("<class>:<tagId>")`, boost 2.0.
- `linked`, always present when signals exist: a `constant_score` whose filter is `{"bool": {"should": [{"term": {"outgoing_link_note_ids": source}}, {"term": {"incoming_link_note_ids": source}}], "minimum_should_match": 1}}`, boost 5.0.

Then `minimum_should_match: 1`, and the base `filter` and `must_not`, which still exclude the source through `excludedNoteIds`.

### `ElasticsearchHTTPTransport.swift`

`URLSessionElasticsearchTransport(insecureTrustHost: String? = nil)`.

- When the host is non-nil, the transport owns a `URLSession` whose delegate answers `NSURLAuthenticationMethodServerTrust` challenges as follows:
  - when `challenge.protectionSpace.host` equals that host, with `.useCredential` and `URLCredential(trust:)`;
  - for every other challenge, with `.performDefaultHandling`.
- Wrap it in `#if canImport(Security)`.
- Expose `static var supportsInsecureTLS: Bool`. It is true only where the Security framework exists.
- When the host is nil, use `URLSession.shared`, as today.

### `SearchEngineFactory.swift`

**Registry.** `public static let adapters: [SearchEngineAdapterDescriptor] = [SearchEngineAdapterDescriptor(kind: "elasticsearch", displayName: "Elasticsearch", authModes: [.none, .basic, .apiKey])]`.

**`normalizedTarget`.** `public static func normalizedTarget(_ url: String) -> String?`.

- It returns nil when the string does not parse to a URL with a scheme and a host.
- Otherwise it returns the lowercase scheme, `://`, the lowercase host (IPv6 in brackets), `:port` when a port is present, and the path with trailing `/` removed.
- Examples: `HTTP://LocalHost:9200/` gives `http://localhost:9200`, and `https://es.example/sub/` gives `https://es.example/sub`.

P17 uses this for the secret binding.

**`make(settings:secret:)`.** `public static func make(settings: SearchEngineConnectionSettings, secret: String?) throws -> any SearchEngine`, plus an `internal` overload that takes `transport: (any ElasticsearchHTTPTransport)?` for tests.

Validation throws `KaibaConfigurationError.invalid(<field>)`, with these exact field strings:

- `searchEngine.kind`: not in `adapters`.
- `searchEngine.url`:
  - any SE2 URL rule;
  - more than 2048 characters;
  - any control character.
- `searchEngine.indexPrefix`: the SE2 regex.
- `searchEngine.username`: basic auth with a nil or empty username, more than 256 characters, or a control character.
- `searchEngine.secret`: `authMode != .none` with a nil or empty secret, more than 4096 characters, or a control character.
- `searchEngine.requestTimeoutSeconds`: outside `1...120`.
- `searchEngine.verifyTLS`: `false` with an `http` URL, or when `!supportsInsecureTLS`.

The authorization is `.none`, `.basic(username, secret)` or `.apiKey(secret)`.

**`make(configuration:environment:)`.**

- It keeps its signature and every existing error value, including `invalid("searchEngine.credentials")` and `missingEnvironmentVariable(name)`, checked in the existing order.
- After resolving the environment credentials, it maps the section onto `SearchEngineConnectionSettings` (`verifyTLS` true, timeout 10, and `username` from the environment for basic) and delegates to `make(settings:secret:)`.

### Tests

**`ElasticsearchLiveTests.swift`.** Change only the cleanup index name to `-notes-v2`. Live scenario changes belong to P21.

## Pitfalls

- **Exact-body tests are the contract.** Update the existing `ElasticsearchSearchEngineTests` expectations from `must` to `should` with `minimum_should_match: 1`, keeping their intent. A search with no new fields must send exactly one `should` clause, the named multi_match.
- **Empty lists.** Never send an empty `terms` array. Omit the clause instead.
- **Facet keys.** A `doc_count` can decode as `NSNumber`. Convert with `intValue`.
- **Reasons from `matched_queries`.** Do not derive reasons from scores.
- **Redaction.** Every error string still passes through `sanitized`. The new delegate must not log anything.
- **Identity change.** The index version bump and identity change are intentional. Update the factory test that expected `elasticsearch:kaiba-notes-v1` to the new normalized form, for example `elasticsearch:http://127.0.0.1:9200/kaiba-notes-v2`.
- **Line budget.** Keep every file under 1000 lines. If `ElasticsearchRequestBodies.swift` grows past about 350 lines, split the related body into `ElasticsearchRelatedRequestBody.swift` in the same directory, and log it as an amendment to writePaths.

## Tests to add or update

`ElasticsearchSearchEngineTests` (mock transport):

- Mapping PUT body -> contains the seven new keyword fields and `dynamic: strict`, and the path is `/<prefix>-notes-v2`.
- Upsert of a document with path tags (one direct `person` tag and one ancestor `folder` tag), applications and links -> the NDJSON document has the sorted `tag_classes`, `class_tag_keys` and `tag_provenance_keys`, and both link arrays.
- `searchPage` with `expansionTagIds [t1]`, `hierarchyTagIds [h1]`, class filters `[(person, nil), (event, e1)]` and `facets` -> the exact body has three `should` clauses with their boosts and names, the filter clauses, and the aggs.
- `searchPage` with no new fields -> the body has a single `text-match` should clause and no `aggs`.
- A response hit with `"matched_queries": ["text-match", "tag-match", "bogus"]` -> reasons `[textMatch, tagMatch]`.
- A response with aggregations -> facets buckets parsed in order.
- `relatedNotes` with all signals -> the five named clauses with their boosts.
- `relatedNotes` with blank `likeText` and nil signals -> `[]`, and the transport records zero requests.
- `libraryIds []` -> no request, for both search and related.
- An engine built with `requestTimeoutSeconds: 7` -> the search request has `timeoutInterval == 7`, and the bulk request has 30.

`SearchEngineFactoryTests`:

- `make(settings:)` for each invalid field -> the exact `KaibaConfigurationError.invalid(field)`.
- Valid basic and apiKey settings -> an engine. With the internal transport overload, the Authorization header matches.
- `verifyTLS: false` with `http` -> `searchEngine.verifyTLS`.
- `normalizedTarget` examples, as above.
- The config path keeps every existing error case.
- `adapters` -> exactly one descriptor, `elasticsearch`.

## Verification

```bash
mise run build
bash -c 'mkdir -p tmp/search-engine-adapter/P13 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter ElasticsearchSearchEngine 2>&1 | tee tmp/search-engine-adapter/P13/adapter.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P13 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter SearchEngineFactory 2>&1 | tee tmp/search-engine-adapter/P13/factory.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P13 && KAIBA_ELASTICSEARCH_URL=http://127.0.0.1:9200 mise run search:test-live 2>&1 | tee tmp/search-engine-adapter/P13/live.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P13 && mise run lint 2>&1 | tee tmp/search-engine-adapter/P13/lint.log; echo exit=${PIPESTATUS[0]}'
bash -c '! grep -rln "ElasticsearchSearchEngine\|ElasticsearchHTTPTransport\|ElasticsearchAuthorization\|URLSessionElasticsearchTransport" Sources --include=*.swift | grep -v "Sources/AppCore/Elasticsearch" | grep -v "Sources/AppCore/SearchEngineFactory.swift"'
wc -l Sources/AppCore/Elasticsearch*.swift Sources/AppCore/SearchEngineFactory.swift
```

Expected evidence:

- The adapter and factory runs show `exit=0` with an XCTest `Executed N tests, 0 failures`, N > 0.
- The live run, against the running compose cluster (`mise run search:up` beforehand if needed), shows `exit=0` and `Executed 1 test, 0 failures`. Record only the XCTest count. The swift-testing 0-test line is not a count record. If Docker is unavailable, record `blocked: docker unavailable` with the error, never passed.
- The grep guard exits 0, and every file is under 1000 lines.

## Done criteria

- [ ] The `-v2` mapping and document fields, the identity with the normalized target, and the timeouts are implemented.
- [ ] The D2 search body, facets and reasons, and the D3 related body and reasons, match the exact-body tests.
- [ ] `make(settings:secret:)`, `adapters`, `normalizedTarget` and the verifyTLS transport exist. The config path keeps its errors.
- [ ] All verification shows `exit=0` with positive XCTest counts, or the live run is recorded as blocked with the error.

## Progress Log

- 2026-10-04: Plan created (session-264).
