# P18 GraphQL and KaibaClient delta: ontology search args, facets, reasons, engine settings

**Status**: Completed. Accepted in session-264 (test-integrity, adversarial and integration review, comm-003910). The combined-tree wave-8 reconcile passed (`tmp/search-engine-adapter/reconcile/session-264-wave8/reconcile-summary.md`). Archived to `impl-plans/completed/` at Step 8 on 2026-10-05.
**planId**: P18-graphql-client-delta
**Wave**: 4
**dependsOn**: P15-ontology-query-service, P17-settings-core
**Design Reference**: `design-docs/specs/search-engine-adapter.md` D2 "GraphQL and KaibaClient"; D3 "Reasons"; D5 "GraphQL"; SE5 (registration lists, statuses)
**Index**: `impl-plans/completed/search-engine-adapter.md`

## Intent and context

This plan exposes the following over the existing note GraphQL surface and the hand-written KaibaClient:

- the D2 arguments and facets;
- the D3 reasons;
- the D5 settings query and the two mutations.

The SDL lines below are pinned and used verbatim by P20 (web). Admin gating and secret handling live in AppCore (P17). This layer maps errors to statuses and must never echo an input secret.

Repository facts:

- **SDL sources.**
  - `Sources/AppGraphQL/GraphQLContractProjector.swift`: `type Query` lines 45-47, with mutations near line 74.
  - `Sources/AppGraphQL/GraphQLNoteSchemaContract.swift`: the type definitions, including `input SetAppSettingInput` at line 170.
- **Registries.** In `Sources/AppGraphQL/NoteGraphQLDocumentExecutorSupport.swift`:
  - `supportedNoteGraphQLFields` (93);
  - `noteGraphQLQueryFields` (174);
  - `noteGraphQLMutationFields` (208), derived from the two above;
  - `noteGraphQLRootSelectionTypes` (322);
  - `noteGraphQLSelectionFields` (378).
- **Dispatch.** `Sources/AppGraphQL/NoteGraphQLDocumentExecutor.swift`:
  - the engine fields are at lines 342-357;
  - the input mutation pattern is `setAppSetting` (474), using `requiredInput("input", variables:)`.
- **Inputs.** `Sources/AppGraphQL/NoteGraphQLDocumentInputs.swift`, for example `GraphQLSetAppSettingInput` (97).
- **Variable validators.** `Sources/AppGraphQL/NoteGraphQLDocumentVariables.swift`.
- **Service.** `Sources/AppGraphQL/NoteGraphQLService+SearchEngine.swift` holds the DTOs and the `searchEngineDisabledResult` and `searchEngineUnavailableResult` helpers.
- **KaibaClient.**
  - `Sources/KaibaClient/KaibaOperations+SearchEngine.swift` (62 lines);
  - `Sources/KaibaClient/KaibaModels.swift` (325 lines);
  - payloads conform to `KaibaControlPlaneDiagnosticsSanitizable`.
- **Tests.**
  - `Tests/AppGraphQLTests/SearchEngineGraphQLTests.swift` and `NoteGraphQLSchemaInventoryTests.swift`;
  - `Tests/KaibaClientTests/KaibaSearchEngineOperationTests.swift`, plus the contract tests `KaibaTypedOperationContractTests.swift` and `KaibaSchemaTests.swift`;
  - `Tests/AppServerTests/GraphQLSchemaAuthorizationTests.swift`.

## Non-goals

- No change to `searchNotes` or any other existing field.
- No secret anywhere in a response type.
- No new admin or viewer field.
- No change to `NoteGraphQLService.swift`, which must stay at 956 lines.

## writePaths

- `Sources/AppGraphQL/GraphQLContractProjector.swift`
- `Sources/AppGraphQL/GraphQLNoteSchemaContract.swift`
- `Sources/AppGraphQL/NoteGraphQLDocumentExecutorSupport.swift`
- `Sources/AppGraphQL/NoteGraphQLDocumentExecutor.swift`
- `Sources/AppGraphQL/NoteGraphQLDocumentVariables.swift`
- `Sources/AppGraphQL/NoteGraphQLDocumentInputs.swift`
- `Sources/AppGraphQL/NoteGraphQLService+SearchEngine.swift`
- `Sources/AppGraphQL/NoteGraphQLService+SearchEngineSettings.swift` (new)
- `Sources/KaibaClient/KaibaOperations+SearchEngine.swift`
- `Sources/KaibaClient/KaibaModels+SearchEngine.swift` (new)
- `Sources/KaibaClient/KaibaModels.swift`
- `Tests/AppGraphQLTests/SearchEngineGraphQLTests.swift`
- `Tests/AppGraphQLTests/SearchEngineSettingsGraphQLTests.swift` (new)
- `Tests/AppGraphQLTests/NoteGraphQLSchemaInventoryTests.swift`
- `Tests/KaibaClientTests/KaibaSearchEngineOperationTests.swift`
- `Tests/KaibaClientTests/KaibaTypedOperationContractTests.swift`
- `Tests/KaibaClientTests/KaibaSchemaTests.swift`
- `Tests/AppServerTests/GraphQLSchemaAuthorizationTests.swift`
- `impl-plans/completed/search-engine-adapter-p18-graphql-client-delta.md`

## sharedPaths (read-only)

- `Sources/AppCore/SearchEngine.swift`: read-only. The P12 types.
- `Sources/AppCore/SearchEngineSettingsTypes.swift`: read-only. The P12 settings types.
- `Sources/AppCore/NoteService+SearchEngine.swift`: read-only. P15 `engineSearchNotesPage` and `relatedNotes`.
- `Sources/AppCore/NoteService+SearchEngineSettings.swift`: read-only. P17 `searchEngineSettings`, `updateSearchEngineSettings` and `testSearchEngineConnection`.
- `Sources/AppGraphQL/NoteGraphQLService.swift`: read-only. `graphQLNoteResult(for:)`. The file must stay at 956 lines.
- `Sources/AppGraphQL/NoteGraphQLContracts.swift`: read-only. `GraphQLNoteDTO` and `GraphQLControlPlaneResult`.

## File-level changes

### SDL (pinned; each field on one physical line)

`type Query`: replace the existing `engineSearchNotes` line and add one field:

```graphql
engineSearchNotes(query: String!, notebookId: String, tagFilter: [String!], tagClassFilter: [String!], expandOntology: Boolean, facets: Boolean, limit: Int, offset: Int): EngineNoteSearchQueryPayload!
searchEngineSettings: SearchEngineSettingsPayload!
```

`type Mutation`:

```graphql
updateSearchEngineSettings(input: SearchEngineSettingsInput!): SearchEngineSettingsPayload!
testSearchEngineConnection(input: SearchEngineSettingsInput!): SearchEngineConnectionTestPayload!
```

Types: replace `EngineNoteHit` and `EngineNoteSearchQueryPayload`, and add the rest.

```graphql
type EngineNoteHit { note: Note!, snippet: String!, score: Float!, reasons: [EngineHitReason!]! }
type EngineHitReason { kind: String!, tags: [String!]! }
type EngineSearchFacets { tagClasses: [EngineFacetBucket!]!, tags: [EngineTagFacetBucket!]! }
type EngineFacetBucket { value: String!, count: Int! }
type EngineTagFacetBucket { tagId: String!, name: String!, tagClass: String, count: Int! }
type EngineNoteSearchQueryPayload { result: ControlPlaneResult!, value: [EngineNoteHit!], facets: EngineSearchFacets }
type SearchEngineAdapterDescriptor { kind: String!, displayName: String!, authModes: [String!]! }
type SearchEngineSettings { managedBy: String!, kind: String!, url: String, indexPrefix: String, authMode: String!, username: String, hasSecret: Boolean!, verifyTLS: Boolean!, requestTimeoutSeconds: Int!, adapters: [SearchEngineAdapterDescriptor!]!, active: Boolean! }
type SearchEngineSettingsPayload { result: ControlPlaneResult!, value: SearchEngineSettings }
input SearchEngineSettingsInput { kind: String!, url: String, indexPrefix: String, authMode: String, username: String, secret: String, clearSecret: Boolean, verifyTLS: Boolean, requestTimeoutSeconds: Int }
type SearchEngineConnectionTestResult { available: Boolean!, status: String!, detail: String! }
type SearchEngineConnectionTestPayload { result: ControlPlaneResult!, value: SearchEngineConnectionTestResult }
```

### Registries (`NoteGraphQLDocumentExecutorSupport.swift`)

- Add the three new root fields to `supportedNoteGraphQLFields`, and `searchEngineSettings` to `noteGraphQLQueryFields`. The two mutations become mutation fields by derivation.
- Add root selection types: `searchEngineSettings` -> `SearchEngineSettingsPayload`, `updateSearchEngineSettings` -> `SearchEngineSettingsPayload`, and `testSearchEngineConnection` -> `SearchEngineConnectionTestPayload`.
- In `noteGraphQLSelectionFields`, add every new type's fields and nested types. Extend `EngineNoteHit` with `reasons` and `EngineNoteSearchQueryPayload` with `facets`.

### Dispatch (`NoteGraphQLDocumentExecutor.swift`)

- **`engineSearchNotes`.** Additionally parse:
  - `tagClassFilter` with `optionalStringArray`, defaulting to `[]`;
  - `expandOntology` with the existing optional-bool helper, or one added in `NoteGraphQLDocumentVariables.swift`, defaulting to true;
  - `facets`, defaulting to false.

  Then call the service's new page method. Keep the existing limit and offset validators.
- **`searchEngineSettings`.** No arguments.
- **The two mutations.** `let input: GraphQLSearchEngineSettingsInput = try requiredInput("input", variables: variables)`.

### Inputs (`NoteGraphQLDocumentInputs.swift`)

`public struct GraphQLSearchEngineSettingsInput: Codable, Equatable, Sendable` mirrors the SDL input.

- `clearSecret` decodes as `Bool?`, defaulting to false.
- `description` must redact `secret`. Imitate the P12 `SearchEngineSettingsInput` redaction, or convert immediately and never interpolate the value.

### `NoteGraphQLService+SearchEngine.swift`

**DTOs.**

- `GraphQLEngineNoteHitDTO` gains `reasons: [GraphQLEngineHitReasonDTO]`, where `kind` is the raw value and `tags` comes from `tagNames`.
- Add `GraphQLEngineSearchFacetsDTO` and `GraphQLEngineNoteSearchPage`, the latter with `result`, `value` and `facets`.
- `relatedNotes` returns the same page shape with `facets: nil`.

**`engineSearchNotes`.** The new signature takes `tagClassFilter`, `expandOntology` and `facets`. It calls `service.engineSearchNotesPage`. Keep the status mapping (`feature-disabled`, `search-engine-unavailable`, otherwise `graphQLNoteResult`).

### `NoteGraphQLService+SearchEngineSettings.swift` (new)

These three methods call the P17 service methods. Error mapping:

- `SearchEngineSettingsError.managedByConfig` gives `accepted: false`, status `settings-managed-by-config`, diagnostics `["search engine settings are managed by the configuration file"]`.
- `.invalid(field)` gives `accepted: false`, status `invalid-settings`, diagnostics `[field]`.
- Other errors go through `graphQLNoteResult(for:)`, which covers the admin-gate not-found shape.
- A failed connection test is a value: `accepted: true`, with `value.status` set.

**DTOs.** `GraphQLSearchEngineSettingsDTO` carries `managedBy` and `authMode` as raw strings, and `GraphQLSearchEngineConnectionTestDTO`. Neither type has a secret field.

### KaibaClient

- **`KaibaOperations+SearchEngine.swift`.**
  - `engineSearchNotes(...)` keeps its parameters, adds defaulted `tagClassFilter: [String] = []`, `expandOntology: Bool = true` and `facets: Bool = false`, and selects `reasons { kind tags }` and `facets { ... }`.
  - The return type becomes `KaibaEngineSearchPagePayload`, with `result`, `value` and `facets`. Existing callers keep compiling: either keep the old method returning `KaibaValuePayload<[KaibaEngineNoteHit]>` and add `engineSearchNotesPage(...)`, or change it everywhere in the tests. Choose keep-old plus add-new, and log the choice.
  - Add `searchEngineSettings()`, `updateSearchEngineSettings(_ input: KaibaSearchEngineSettingsInput)` and `testSearchEngineConnection(_ input: KaibaSearchEngineSettingsInput)`.
- **`KaibaModels+SearchEngine.swift` (new).** Models:
  - `KaibaEngineHitReason`
  - `KaibaEngineSearchFacets`
  - `KaibaEngineSearchPagePayload`
  - `KaibaSearchEngineSettings`
  - `KaibaSearchEngineSettingsPayload`
  - `KaibaSearchEngineSettingsInput`, which encodes `secret` only when non-nil
  - `KaibaSearchEngineConnectionTestPayload`

  Payloads get diagnostics-sanitizable conformances, like the capability payload.
- **`KaibaModels.swift`.** Only `KaibaEngineNoteHit` gains `reasons: [KaibaEngineHitReason]`.

## Pitfalls

- **Pinned SDL.** The lines must match verbatim, because P20's web queries use these names. One field per physical line.
- **Never echo the input.** Mutation responses are built from the P17 view, never from the input.
- **Authorization tests.** `GraphQLSchemaAuthorizationTests` may assert the exact mutation list or the scopes. Update it to include the two new mutations with the same scope class as `setAppSetting`. Do not weaken other assertions.
- **The executor stays under 1000 lines.** It is 679 now. If the support file passes 900, move the new selection-field entries to a new `NoteGraphQLDocumentExecutorSupport+SearchEngine.swift` (a writePaths amendment) and log it.
- **Backwards compatibility.** Old clients that do not select `reasons` or `facets` keep working.

## Tests

**`SearchEngineGraphQLTests` (extend):**

- `engineSearchNotes` with `tagClassFilter`, `expandOntology: false` and `facets: true` -> the JSON has `reasons[0].kind` and the facets buckets. The recorded engine query has `expansionTagIds == []` and non-nil facets.
  - The `AppGraphQLTests` target cannot see `Tests/AppCoreTests/FakeSearchEngine.swift`. Extend this file's private `GraphQLSearchEngineFixture` instead: implement `searchPage` with scripted hits (with reasons) and scripted facets, and record the last query, using a small lock-protected box.
  - Tests that need a real note use an existing store fixture from this file.
- `relatedNotes` -> `facets` is null and the reasons are present.

**`SearchEngineSettingsGraphQLTests` (new):**

- An admin reads the settings -> accepted, with `adapters[0].kind == "elasticsearch"`.
- A non-admin, scoped to a non-admin user -> not accepted, with the not-found mapping.
- Managed by config -> the update gives `settings-managed-by-config`.
- An invalid url -> `invalid-settings` with diagnostics `["searchEngine.url"]`.
- A test connection with a retargeted url and an omitted secret -> accepted, `value.status == "invalid-settings"`, and `value.detail == "searchEngine.secret"`.
- An update with `secret: "TOPSECRET-123"`, then a read -> the encoded JSON of both responses does not contain `TOPSECRET-123`.

**Other suites:**

- `NoteGraphQLSchemaInventoryTests`: update the inventory to include the new fields and types.
- `KaibaSearchEngineOperationTests`: the operation documents for the new methods validate against the schema contract, and decoding of the page, settings and test payloads works.

## Verification

```bash
mise run build
bash -c 'mkdir -p tmp/search-engine-adapter/P18 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter SearchEngineGraphQL 2>&1 | tee tmp/search-engine-adapter/P18/graphql.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P18 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter SearchEngineSettingsGraphQL 2>&1 | tee tmp/search-engine-adapter/P18/settings-graphql.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P18 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter AppGraphQLTests 2>&1 | tee tmp/search-engine-adapter/P18/graphql-suite.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P18 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter KaibaClientTests 2>&1 | tee tmp/search-engine-adapter/P18/client-suite.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P18 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter GraphQLSchemaAuthorization 2>&1 | tee tmp/search-engine-adapter/P18/authorization.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P18 && mise run lint 2>&1 | tee tmp/search-engine-adapter/P18/lint.log; echo exit=${PIPESTATUS[0]}'
grep -n "searchEngineSettings\|updateSearchEngineSettings\|testSearchEngineConnection\|tagClassFilter" Sources/AppGraphQL/GraphQLContractProjector.swift
wc -l Sources/AppGraphQL/NoteGraphQLService.swift Sources/AppGraphQL/NoteGraphQLDocumentExecutor.swift Sources/AppGraphQL/NoteGraphQLDocumentExecutorSupport.swift Sources/KaibaClient/KaibaModels.swift
```

Expected evidence:

- Every `swift test` run shows `exit=0` with a positive count. The AppGraphQL and AppServer suites are XCTest, so record `Executed N tests, 0 failures`. `Tests/KaibaClientTests` is entirely swift-testing, so for `client-suite.log` record the swift-testing `Test run with N tests passed` count, never the XCTest 0 line. Extend `KaibaSearchEngineOperationTests` in its existing swift-testing `@Test` style.
- `NoteGraphQLService.swift` is still 956 lines, and every file is under 1000.

## Done criteria

- [x] The pinned SDL lines and types are present and registered in every list and in the dispatch.
- [x] Status mapping and no-secret-echo are proven by tests.
- [x] The KaibaClient operations and models exist; the old `engineSearchNotes` callers compile through the preserved array-returning method.
- [x] Required test records have exit 0 and positive counts; build, lint and structural checks completed.

## Progress Log

- 2026-10-04: Plan created (session-264).
- 2026-10-05: Implemented P18 on the shared branch. `engineSearchNotes` now dispatches tag-class filters, ontology-expansion control and facets through the P15 page API; hit reasons and optional facets are projected in the registered GraphQL schema. Added settings read/update/test fields, secret-free GraphQL DTOs and field-only settings error mappings over P17. `GraphQLSearchEngineSettingsInput` redacts its description and defaults omitted `clearSecret` to false.
- 2026-10-05: Kept the legacy KaibaClient `engineSearchNotes` and `relatedNotes` array payloads for existing callers; added `engineSearchNotesPage` plus typed settings read/update/test operations and models. Legacy hit decoding defaults absent reasons to an empty list.
- 2026-10-05: Added GraphQL page/reason/facet recording tests, a related hit reason plus null-facets assertion, settings admin/config/invalid/retarget/no-secret tests, root-field inventory entries, and KaibaClient operation/decode coverage. No production P18 edits outside declared writePaths.
- 2026-10-05: Final-source evidence: `tmp/search-engine-adapter/P18/build-source-final.log` (`mise run build`, exit 0); `graphql-focus-source-final.log` (SearchEngineGraphQL 6/6), `settings-graphql-source-final.log` (SearchEngineSettingsGraphQL 3/3), `graphql-suite-final.log` (AppGraphQLTests 171/171 XCTest; exit 0), `client-suite-final.log` (KaibaClientTests 60/60 Swift Testing; exit 0), and `authorization-source-final.log` (GraphQLSchemaAuthorization 2/2; exit 0).
- 2026-10-05: Exact changed-file strict SwiftLint passed using `changed-swift-files.nul` (`swiftlint-changed-final.log`, exit 0). Repository `mise run lint` exited 0 (`lint-source-final.log`); its three warnings are in unchanged `Sources/AppCore/NoteService.swift`, `Sources/AppCore/ResendGatewayCLIMailSender.swift`, and `Tests/AppCoreTests/AITranslationTests.swift`, with no P18 diagnostics. GraphQL service remains 956 lines; executor 690; selection support 803; every touched Swift file is below 1000 lines. The contract grep and `git diff --check` passed.
- 2026-10-05: Resolved intermediate attempts are retained separately: early GraphQL test compile/query assertion failures and a Swift Testing macro compile error were corrected and replaced by passing final-source suite evidence; the initial strict lint wrapper used zsh's read-only `$status` and was rerun with a writable task variable; first strict lint findings were corrected without rule suppressions. See `tmp/search-engine-adapter/P18/implementation-intents/001-graphql-client-delta.md` and the corresponding `graphql.log`, `graphql-rerun-1.log`, `graphql-rerun-2.log`, `graphql-final.log`, and `swiftlint-changed-rerun-1.log`.
- 2026-10-05: Step 6 implementation is complete. Independent test-integrity/adversarial review and P11/P21 combined-tree integration against the real schema remain downstream workflow work.
