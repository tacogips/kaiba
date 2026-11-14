# P1 Descriptor contract: remove the client-visible `defaultURL`

**Status**: Completed. Accepted in session-272 (test-integrity comm-004170, adversarial review comm-004171, combined-tree integration review comm-004176). The P5 combined-tree gates passed (`impl-plans/completed/search-engine-backend-boundary.md`, "Final integration evidence"). Archived to `impl-plans/completed/` at Step 8 on 2026-10-05.
**planId**: P1-descriptor-contract
**Wave**: 1
**dependsOn**: none
**Design Reference**: `design-docs/specs/search-engine-adapter.md` B5 (GraphQL and KaibaClient), B1 rows A1-A3, B7 (KaibaClient, AppGraphQL schema), B verification guards
**Index**: `impl-plans/completed/search-engine-backend-boundary.md`

## Intent and context

Commit 137c6f7 added `defaultURL` to the adapter descriptor. It carries
the server's `KAIBA_MEILISEARCH_URL` value (or the built-in fallback) to
every client that reads the search-engine settings. The premise (B0) is
that only the backend knows engine coordinates. This plan removes the
descriptor field from AppCore, the GraphQL schema/executor/DTO and
KaibaClient, removes `SearchEngineFactory.adapters(environment:)`, and
documents the meaning of a `null` / omitted URL. It is the first-wave
contract: P2 builds the backend behavior on top of it.

The descriptor returns to the D5 shape:
`type SearchEngineAdapterDescriptor { kind: String!, displayName: String!, authModes: [String!]! }`.

Important naming fact: `SearchEngineFactory.defaultURL(for:environment:)`
(`Sources/AppCore/SearchEngineFactory.swift:17`) is the backend resolver
and must stay, with the same name and behavior. It is called by
`KaibaSearchEngineConfiguration.resolvedURL(environment:)`
(`Sources/AppCore/KaibaConfiguration.swift:128`). Only the descriptor
*field* `defaultURL` and `adapters(environment:)` go away.

The field was never released (added after tag `v0.1.16`), so no
deprecation shim is needed.

## Non-goals

- No change to URL resolution, persistence, the settings read's `url`,
  validation, the environment source or the CLI. That is P2.
- Do not rename or remove `SearchEngineFactory.defaultURL(for:environment:)`,
  `meilisearchURLEnvironmentVariable` or `fallbackMeilisearchURL`.
- No change to `input SearchEngineSettingsInput` in the schema (its `url`
  is already nullable).
- No web changes (P3), no README (P4), no `Sources/AppServer` changes.
- Do not add a `usesServerDefault` field anywhere.

## writePaths

- `Sources/AppCore/SearchEngineSettingsTypes.swift`
- `Sources/AppCore/SearchEngineFactory.swift`
- `Sources/AppCore/NoteService+SearchEngineSettings.swift`
- `Sources/AppGraphQL/GraphQLNoteSchemaContract.swift`
- `Sources/AppGraphQL/NoteGraphQLDocumentExecutorSupport.swift`
- `Sources/AppGraphQL/NoteGraphQLService+SearchEngineSettings.swift`
- `Sources/KaibaClient/KaibaModels+SearchEngine.swift`
- `Sources/KaibaClient/KaibaOperations+SearchEngine.swift`
- `Tests/AppCoreTests/SearchEngineFactoryTests.swift`
- `Tests/AppGraphQLTests/SearchEngineBackendBoundaryGraphQLTests.swift`
- `Tests/KaibaClientTests/KaibaSearchEngineOperationTests.swift`
- `impl-plans/completed/search-engine-backend-boundary-p1-descriptor-contract.md`
- `tmp/search-engine-backend-boundary/P1`

## sharedPaths (read-only)

- `Sources/AppCore/KaibaConfiguration.swift`
- `Tests/AppGraphQLTests/SearchEngineSettingsGraphQLTests.swift`

## sharedPathNotes

- `Sources/AppCore/NoteService+SearchEngineSettings.swift`: intendedEdit: change only line 7 (`SearchEngineFactory.adapters(environment: environment)` -> the static `SearchEngineFactory.adapters`). Leave line 6 (`environment`) and everything else for P2.
- `Sources/AppCore/KaibaConfiguration.swift`: intendedEdit: read-only; it keeps calling `SearchEngineFactory.defaultURL(for:environment:)`.
- `Tests/AppGraphQLTests/SearchEngineSettingsGraphQLTests.swift`: intendedEdit: read-only here (P2 owns it); imitate its helpers in the new test file.
- `tmp/search-engine-backend-boundary/P1`: intendedEdit: evidence logs, hashes.txt and intent.md only.

## artifactRoots

- `tmp/search-engine-backend-boundary/P1`

## File-level changes

1. `Sources/AppCore/SearchEngineSettingsTypes.swift`
   - `SearchEngineAdapterDescriptor`: delete the `defaultURL` property and
     its doc comment. The init becomes
     `public init(kind: String, displayName: String, authModes: [SearchEngineAuthMode])`.
   - Add a one-line doc comment on `SearchEngineSettingsInput.url`:
     omitted, `nil`, empty or whitespace-only means the server default,
     resolved on the backend (B2).
   - Add a one-line doc comment on `SearchEngineSettingsView.url`: the
     explicit stored or configured URL, `nil` for the server default (B4).
     Do not change any type shape besides the descriptor.
2. `Sources/AppCore/SearchEngineFactory.swift`: delete
   `adapters(environment:)` and its doc comment (lines 23-30). Keep the
   static `adapters`, `defaultURL(for:environment:)`, the env var and
   fallback constants unchanged. Optionally add "backend only; never sent
   to clients" to the `defaultURL(for:environment:)` doc comment.
3. `Sources/AppCore/NoteService+SearchEngineSettings.swift:7`: use
   `SearchEngineFactory.adapters` (static). Nothing else.
4. `Sources/AppGraphQL/GraphQLNoteSchemaContract.swift:58`: the line
   becomes exactly
   `type SearchEngineAdapterDescriptor { kind: String!, displayName: String!, authModes: [String!]! }`.
5. `Sources/AppGraphQL/NoteGraphQLDocumentExecutorSupport.swift` (~line
   426-431): remove the `"defaultURL": nil` entry from the
   `"SearchEngineAdapterDescriptor"` selection map.
6. `Sources/AppGraphQL/NoteGraphQLService+SearchEngineSettings.swift`:
   remove `defaultURL` from `GraphQLSearchEngineAdapterDTO` and its
   assignment in `init(adapter:)`.
7. `Sources/KaibaClient/KaibaModels+SearchEngine.swift`: remove
   `defaultURL` (and its comment) from
   `KaibaSearchEngineAdapterDescriptor`. Add doc comments:
   `KaibaSearchEngineSettings.url` is `nil` for the server default when
   `kind` is not `none`; `KaibaSearchEngineSettingsInput.url` omitted,
   `nil`, empty or whitespace-only means the server default.
8. `Sources/KaibaClient/KaibaOperations+SearchEngine.swift` (lines ~77 and
   ~97): both selections become `adapters { kind displayName authModes }`.

Patterns to imitate: the D5 descriptor shape before 137c6f7 (`git show
137c6f7^:Sources/AppCore/SearchEngineSettingsTypes.swift`), and the test
helpers in `Tests/AppGraphQLTests/SearchEngineSettingsGraphQLTests.swift`
(`makeService`, `run`, `serializedResponse`).

## Pitfalls

- `grep -rn 'defaultURL' Sources/AppCore` will still match
  `SearchEngineFactory.swift` (`defaultURL(for:environment:)`) and
  `KaibaConfiguration.swift:128`. That is correct. Do not "clean" them.
- After step 3, `environment` on line 6 is still used on line 15; leave it.
- Do not change `SearchEngineFactory.adapters` contents (Meilisearch,
  `[.none, .apiKey]`).
- Removing the descriptor field changes no JSON the server emits except
  dropping `defaultURL`; do not touch other DTO fields.

## Tests

- `Tests/AppCoreTests/SearchEngineFactoryTests.swift`
  `testDefaultsSelectMeilisearchAndResolveURLFromEnvironment`: delete the
  two `SearchEngineFactory.adapters(environment:)...map(\.defaultURL)`
  assertions (lines 76-77). Keep line 78
  (`XCTAssertNil(SearchEngineFactory.defaultURL(for: "other", ...))`) and
  every other assertion unchanged.
- New `Tests/AppGraphQLTests/SearchEngineBackendBoundaryGraphQLTests.swift`
  (XCTest, imitate `SearchEngineSettingsGraphQLTests` helpers; private
  copies of the helpers are fine):
  - `GraphQLContractProjector.schemaContract` -> contains the exact line
    `type SearchEngineAdapterDescriptor { kind: String!, displayName: String!, authModes: [String!]! }`
    and does not contain the substring `defaultURL`.
  - Admin query `query { searchEngineSettings { value { adapters { kind displayName authModes } } } }`
    -> adapters is `[{kind: "meilisearch", displayName: "Meilisearch", authModes: ["none","apiKey"]}]`.
  - Query `query { searchEngineSettings { value { adapters { defaultURL } } } }`
    -> rejected the way unknown fields are rejected today (imitate
    `Tests/AppGraphQLTests/NoteGraphQLTests.swift` around lines 545-559):
    `data.searchEngineSettings` is `null`, and `errors[0].message`
    contains `invalidSelection` and `defaultURL`.
  - Service whose slot environment is
    `["KAIBA_MEILISEARCH_URL": "https://engine-only.internal"]`
    (`service.service.searchEngineSlot.setEnvironment(...)`) -> the
    serialized `searchEngineSettings` response with
    `adapters { kind displayName authModes }` does not contain
    `engine-only.internal`.
- `Tests/KaibaClientTests/KaibaSearchEngineOperationTests.swift`: in the
  existing settings and update cases, capture the sent document (imitate
  the `body["query"]` pattern at line ~38) and expect it contains
  `adapters { kind displayName authModes }` and does not contain
  `defaultURL`.

## Verification

```bash
mkdir -p tmp/search-engine-backend-boundary/P1
bash -c 'mise run build 2>&1 | tee tmp/search-engine-backend-boundary/P1/build.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter "SearchEngineFactoryTests|SearchEngineBackendBoundaryGraphQLTests|SearchEngineSettingsGraphQLTests|SearchEngineSettingsTests|KaibaSearchEngineOperationTests|KaibaTypedOperationContractTests|NoteGraphQLSchemaInventoryTests|GraphQLIntrospectionTests" 2>&1 | tee tmp/search-engine-backend-boundary/P1/swift-test.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'mise run lint 2>&1 | tee tmp/search-engine-backend-boundary/P1/lint.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'grep -rn "defaultURL" Sources/AppGraphQL Sources/KaibaClient | tee tmp/search-engine-backend-boundary/P1/guard-client.log; test ! -s tmp/search-engine-backend-boundary/P1/guard-client.log'
bash -c 'grep -n "defaultURL" Sources/AppCore/SearchEngineSettingsTypes.swift | tee tmp/search-engine-backend-boundary/P1/guard-descriptor.log; test ! -s tmp/search-engine-backend-boundary/P1/guard-descriptor.log'
bash -c 'grep -rn "adapters(environment" Sources Tests | tee tmp/search-engine-backend-boundary/P1/guard-adapters.log; test ! -s tmp/search-engine-backend-boundary/P1/guard-adapters.log'
wc -l Sources/AppCore/SearchEngineSettingsTypes.swift Sources/AppCore/SearchEngineFactory.swift Sources/AppGraphQL/GraphQLNoteSchemaContract.swift Sources/AppGraphQL/NoteGraphQLDocumentExecutorSupport.swift Sources/AppGraphQL/NoteGraphQLService+SearchEngineSettings.swift Sources/KaibaClient/KaibaModels+SearchEngine.swift Sources/KaibaClient/KaibaOperations+SearchEngine.swift Tests/AppGraphQLTests/SearchEngineBackendBoundaryGraphQLTests.swift | tee tmp/search-engine-backend-boundary/P1/wc.log
```

Expected evidence:

- build exit 0.
- swift test exit 0; the XCTest line `Executed N tests, with 0 failures`
  with N > 0, and the swift-testing line `Test run with M tests passed`
  with M > 0 (KaibaClient suites are swift-testing). Record both counts.
- lint exit 0 (0 serious violations); pre-existing warnings in untouched
  files are noted, not fixed.
- The three guard commands exit 0 with empty logs.
- Every touched Swift file is under 1000 lines.

## Done criteria

- [x] `grep -rn 'defaultURL' Sources/AppGraphQL Sources/KaibaClient` is empty.
- [x] `grep -n 'defaultURL' Sources/AppCore/SearchEngineSettingsTypes.swift` is empty.
- [x] `grep -rn 'adapters(environment' Sources Tests` is empty.
- [x] `SearchEngineFactory.defaultURL(for:environment:)` still exists and `Sources/AppCore/KaibaConfiguration.swift` is unchanged.
- [x] Schema line matches the D5 shape exactly; new GraphQL test and updated KaibaClient test pass with positive counts.
- [x] Progress Log updated with commands, exit codes, counts and log paths.

## Progress Log

- 2026-10-05: Plan created.
- 2026-10-05: Removed the client-visible descriptor URL and the environment-resolved adapter-list API from AppCore, GraphQL and KaibaClient. Added explicit server-default semantics to the relevant Swift URL fields. Added GraphQL assertions for the exact descriptor shape, rejected `defaultURL` selection and environment URL non-disclosure; updated SDK request assertions for both settings operations.
- 2026-10-05: `mise run build` exit 0; full log `tmp/search-engine-backend-boundary/P1/build-final.log`.
- 2026-10-05: `PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter "SearchEngineFactoryTests|SearchEngineBackendBoundaryGraphQLTests|SearchEngineSettingsGraphQLTests|SearchEngineSettingsTests|KaibaSearchEngineOperationTests|KaibaTypedOperationContractTests|NoteGraphQLSchemaInventoryTests|GraphQLIntrospectionTests"` exit 0; XCTest 29 passed, 0 failed; Swift Testing 7 passed; full log `tmp/search-engine-backend-boundary/P1/swift-test-rerun-1.log`. The initial run failed one new test due to a missing `data` path component; corrected the test helper call and reran successfully. Initial log retained at `tmp/search-engine-backend-boundary/P1/swift-test.log`.
- 2026-10-05: selected-file `swiftlint lint --strict --quiet --no-cache` using NUL manifest `tmp/search-engine-backend-boundary/P1/changed-swift-files.nul` exit 0; log `tmp/search-engine-backend-boundary/P1/swiftlint-changed-rerun.log`.
- 2026-10-05: `mise run lint` exit 0 across 387 files; reports 3 non-serious warnings in untouched `Sources/AppCore/NoteService.swift`, `Sources/AppCore/ResendGatewayCLIMailSender.swift`, and `Tests/AppCoreTests/AITranslationTests.swift`; log `tmp/search-engine-backend-boundary/P1/lint.log`.
- 2026-10-05: descriptor/client/adapter grep guards and retained-resolver/configuration-unchanged guard all exit 0; outputs at `tmp/search-engine-backend-boundary/P1/guard-client.log`, `guard-descriptor.log`, and `guard-adapters.log`. Touched Swift files are all under 1000 lines; counts recorded in `tmp/search-engine-backend-boundary/P1/wc.log`.
