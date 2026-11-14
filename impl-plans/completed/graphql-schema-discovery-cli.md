# Authenticated GraphQL Schema Discovery CLI

**Status**: Completed; verification complete with repository-baseline lint findings
**Feature ID**: `graphql-schema-discovery-cli`
**Issue**: `local-request:/Users/taco/gits/tacogips/kaiba:Add first-party Kaiba Swift client SDK and schema discovery CLI`
**Design Reference**: `design-docs/specs/graphql-schema-discovery-cli.md`
**Parent Design**: `design-docs/specs/kaiba-client-sdk.md`

## Purpose

Implement authenticated endpoint schema discovery as
`kaiba graphql schema`, with optional ICU regex selection, deterministic
forward transitive type closure, canonical text/JSON, redacted failures, and
regression protection for existing GraphQL execution.

This plan owns the schema-discovery slice. It extends the parent issue's public
`KaibaClient` and internal `KaibaCLIKit`; it does not duplicate endpoint,
authentication, HTTP, or error behavior and never imports store/service APIs
into the client.

## Deliverables

- [x] Authenticated standard `__schema`/`__type` support for the bounded fields
      used by canonical `KaibaSchemaIntrospectionV1`.
- [x] `KaibaClient.fetchSchema()` and public immutable schema models.
- [x] Deterministic schema validation, regex seeding, forward dependency
      closure, and ordering.
- [x] Testable `KaibaCLIKit` parsing/running/rendering for
      `kaiba graphql schema`.
- [x] Stable canonical SDL-like text, sorted JSON, stderr failures, codes, and
      exit statuses from the accepted design.
- [x] Existing `kaiba graphql` and public `AppCore`/`AppGraphQL` compatibility.
- [x] Deterministic server, SDK, selector, CLI, redaction, and regression tests
      using injected/in-memory transports only.
- [x] Command help and `README.md` examples without literal credentials.
- [x] Passing build, focused/full tests, feature-clean SwiftLint, file-size,
      secret-audit, and
      diff gates; no commit or push.

## Dependencies And Ownership

- Prerequisite parent SDK surface: public `KaibaClient` product,
  `KaibaEndpoint`, `KaibaAuthentication`, `KaibaBearerToken`,
  `KaibaTransportSecurity`, injectable `KaibaHTTPTransporting`, arbitrary
  GraphQL execution, finite timeout/no retry, redirect refusal, and typed
  `KaibaClientError`.
- `KaibaClient` owns public schema DTOs, introspection decoding/validation,
  filtering, closure, and canonical schema result values.
- `AppGraphQL` owns parsing the authoritative SDL and projecting bounded
  introspection. It may depend on `KaibaClient`; the client must not depend on
  `AppGraphQL`, `AppCore`, `AppServer`, SQLite, or AnydocKit.
- `AppServer` owns pre-dispatch authentication/status behavior.
- Internal non-product `KaibaCLIKit` owns schema-command options, environment
  lookup, runner, rendering, channel, and exit decisions. `AppCLI` only routes
  and writes its result.
- Any incompatible sibling SDK boundary blocks integration and must be resolved
  in the parent design; this feature must not add a parallel transport.

## File Plan

Expected additions:

- `Sources/AppGraphQL/GraphQLSchemaCatalog.swift`
- `Sources/AppGraphQL/GraphQLSchemaIntrospectionExecutor.swift`
- `Sources/KaibaClient/KaibaGraphQLSchema.swift`
- `Sources/KaibaClient/KaibaSchemaIntrospection.swift`
- `Sources/KaibaClient/KaibaSchemaFilter.swift`
- `Sources/KaibaClient/KaibaSchemaRenderer.swift`
- `Sources/KaibaCLIKit/GraphQLSchemaCommand.swift`
- `Tests/AppGraphQLTests/GraphQLSchemaIntrospectionTests.swift`
- `Tests/KaibaClientTests/KaibaSchemaDiscoveryTests.swift`
- `Tests/KaibaClientTests/KaibaSchemaFilterTests.swift`
- `Tests/KaibaClientTests/KaibaSchemaRendererTests.swift`
- `Tests/KaibaCLIKitTests/GraphQLSchemaCommandTests.swift`

Expected modifications:

- `Package.swift`
- `Sources/AppGraphQL/GraphQLContractProjector.swift`
- `Sources/AppGraphQL/NoteGraphQLDocumentExecutor.swift`
- `Sources/AppGraphQL/NoteGraphQLDocumentExecutorSupport.swift`
- `Sources/AppServer/ServerContracts.swift`
- `Sources/AppCLI/main.swift`
- `Sources/AppCore/Command.swift`
- `Tests/AppGraphQLTests/GraphQLHTTPDocumentClientTests.swift`
- `Tests/AppServerTests/KaibaServerRuntimeTests.swift` or one new focused route
  test file
- `Tests/AppCoreTests/CommandTests.swift`
- `README.md`

Omit an expected modification only when implementation proves it unnecessary,
and record that decision in the progress log. Do not add to the existing
1,060-line `Tests/AppGraphQLTests/NoteGraphQLTests.swift`; all new Swift files
must remain below 1,000 lines.

## Tasks

### TASK-001: Validate The Parent SDK Integration Boundary

**Parallelizable**: No; prerequisite

**Completion Criteria**:

- [x] Confirm the exact prerequisite types and target graph listed above.
- [x] Confirm authentication is a required closed choice and non-loopback HTTP
      and unauthenticated policies each require explicit configuration.
- [x] Confirm typed client errors distinguish connection, auth, other HTTP,
      invalid response, GraphQL, decode, and schema failures without retaining
      request headers/body, response body, raw token, or unsafe system error.
- [x] Add only schema-specific public surfaces and document any resolved
      cross-feature mismatch in the progress log.

### TASK-002: Parse One Authoritative Schema Catalog

**Parallelizable**: No; required by server introspection

**Completion Criteria**:

- [x] Parse `GraphQLContractProjector.schemaContract` into an immutable catalog
      of roots, objects, inputs, enums, scalars, interfaces, unions, fields,
      arguments, descriptions/deprecations, and recursive type references.
- [x] Support the SDL subset Kaiba emits, including comments, multiline
      definitions, lists, and non-null wrappers; reject malformed/unsupported
      declarations deterministically.
- [x] Synthesize used built-in `String`, `Int`, `Float`, `Boolean`, and `ID`
      scalars when undeclared.
- [x] Reject duplicates, dangling references, invalid wrappers, and wrapper
      nesting deeper than eight.
- [x] Keep `Query`/`Mutation` as roots and prove complete catalog/SDL inventory
      parity in tests so no second handwritten inventory exists.

### TASK-003: Serve Authenticated Bounded Introspection

**Parallelizable**: No; depends on TASK-002

**Completion Criteria**:

- [x] Define `KaibaSchemaIntrospectionV1` within the existing GraphQL document
      byte limit and select the exact design fields through eight wrapper levels.
- [x] Recognize supported `__schema`/`__type` operations before note dispatch;
      reject malformed, unsupported, or mixed introspection with GraphQL errors.
- [x] Make pre-dispatch auth treat introspection as requiring authentication;
      only explicit server unauthenticated mode bypasses a bearer.
- [x] Project standard root identities, types, members, interfaces/possible
      types, descriptions/deprecations, enum values, and type references.
- [x] Preserve every existing ordinary GraphQL request/status/body behavior.
- [x] Test accepted/rejected bearer, missing authenticator, explicit
      unauthenticated server mode, catalog parity, wrapper limit, `__type`,
      malformed selections, and ordinary-operation regressions through
      in-memory route/executor calls.
- [x] Bound selection nodes, schema-aware projection complexity, and serialized
      response bytes independently; alias-breadth amplification receives a
      bounded GraphQL error before unbounded projection or publication.

### TASK-004: Add SDK Schema Fetch And Validation

**Parallelizable**: Yes after TASK-001; integrates with TASK-003

**Files**:

- `Sources/KaibaClient/KaibaGraphQLSchema.swift`
- `Sources/KaibaClient/KaibaSchemaIntrospection.swift`
- `Sources/KaibaClient/KaibaGraphQLSchemaValidation.swift`
- `Tests/KaibaClientTests/KaibaClientPublicAPITests.swift`

**Completion Criteria**:

- [x] Add public immutable `Codable`, `Equatable`, and `Sendable` schema, root
      field, member, type-kind, and recursive type-reference models consistent
      with the parent SDK design.
- [x] `KaibaClient.fetchSchema()` sends the canonical document through the
      existing normalized endpoint, authentication, timeout, no-redirect, and
      injected transport.
- [x] Decode and validate required query/optional mutation roots, type kinds,
      kind-specific member shapes, wrong-typed optional members, wrapper
      shape/depth (including null-only wrapper names/named `ofType`), member and
      relationship uniqueness, and complete kind-consistent references before return.
- [x] Exclude introspection meta-types and represent roots separately.
- [x] Preserve parent errors: 401/403 `auth_failed`, transport
      `connection_failed`, other HTTP `http_failed`, malformed envelope
      `invalid_response`, GraphQL rejection/schema defects `schema_unavailable`.
- [x] Test bare/custom paths, loopback/remote HTTP policy, bearer header,
      unauthenticated header absence, redirects, timeouts, shuffled response,
      malformed response variants, and sentinel-secret redaction with a mock
      transport. Schema descriptions/deprecations and retained
      `schema_unavailable` reasons are credential-sanitized; tainted identifiers
      fail before publication.
- [x] Only `/graphql` is published as a diagnostic path; every custom endpoint
      path is opaque for bearer and unauthenticated parser, validation,
      readiness, runtime, and success output. The normalized raw URL is
      module-internal, absent from the public symbol graph, and retained only
      for transport.
- [x] Failure endpoint construction is authentication-independent before any
      throwing regex or credential validation; missing-credential and invalid-
      regex JSON regressions publish exactly one opaque path segment.
- [x] Transport timeout is an absolute wall-clock deadline; a trickling
      response cannot keep introspection alive through incremental progress.
- [x] The shared client rejects timeouts above its documented 24-hour ceiling,
      preserves cancellation, and keeps public HTTP request/response reflection
      opaque to bearer values and GraphQL bodies.

### TASK-005: Implement Regex Seeds And Forward Closure

**Parallelizable**: Yes after schema models exist

**Completion Criteria**:

- [x] Compile `NSRegularExpression` before transport and map failure to
      `invalid_regex` without raw engine diagnostics.
- [x] Match only the design candidates: simple name plus `Query.<field>`,
      `Mutation.<field>`, or `Type.<name>`.
- [x] Directly seed root fields and object/input/enum/scalar types; include
      interfaces/unions only when reachable.
- [x] Follow root/member arguments/results, input fields, implemented
      interfaces, union possible types, and nested list/non-null references.
- [x] Use a visited set for cycles, emit complete selected/reachable types, fail
      on dangling references, and never reverse-add roots.
- [x] Canonicalize every collection using the design's stable kind/name order.
- [x] Escape every text control character using JSON-compatible escapes before
      rendering deprecation reasons into SDL-like terminal output.
- [x] Test no filter, no match, invalid filter, every direct category,
      qualified candidates, wrappers, built-ins, shared dependencies, cycles,
      interface/union closure, missing references, and shuffled input order.

### TASK-006: Implement `KaibaCLIKit` Schema Command

**Parallelizable**: No; depends on TASK-004 and TASK-005

**Completion Criteria**:

- [x] Add/confirm non-product `KaibaCLIKit` and `KaibaCLIKitTests` targets, with
      the narrow target dependencies from the parent design.
- [x] Parse required endpoint, exactly one auth option, optional
      `--allow-insecure-http`, optional filter, and `text|json`; reject duplicate,
      unknown, positional, missing-value, and conflicting inputs. Distinguish a
      missing endpoint (`invalid_usage`) from a present malformed endpoint
      (`invalid_endpoint`), including empty, alphabetic, and integer-overflowing
      ports.
- [x] Validate environment names and read the injected environment immediately
      before client construction; missing/empty fails before transport.
- [x] Render canonical SDL-like text and sorted JSON success exactly as designed,
      including definition spacing/indentation, escaped deprecation reasons,
      sorted object/interface `implements` clauses, and the fixed no-match text.
- [x] Map every fixed code/message/next action/exit status and write failures to
      stderr with stdout empty, including structured JSON invalid-regex failure
      before client construction and the exact credential-specific next action
      for missing credentials in text and JSON.
- [x] Runtime `auth_failed`, `connection_failed`, `http_failed`,
      `invalid_response`, and `schema_unavailable` diagnostics have exact text
      and JSON goldens backed by local copy rather than underlying errors.
- [x] Exit 0 on success, 2 on usage/configuration failure, and 1 on every
      endpoint/runtime/schema failure.
- [x] Route `schema` only as the first token after `graphql`; do not scan
      arbitrary values or change `GraphQLCommand.parse` or `.run`; require
      `graphql` itself to be the command token after complete global-option
      pairs, and route before note-root/Kaiba configuration loading so ambient
      config cannot affect it.
- [x] Resolve command and help tokens with option-aware positional grammar so
      filter values such as `serve` and `-h` execute schema discovery instead
      of routing to another command or global help.
- [x] Test parser matrices, output goldens, no match, all errors/channels/exits,
      no transport on local failures, and mock-transport sentinel-secret absence
      from fetched values, renderers, stdout, stderr, descriptions, and
      reflected errors. Invalid empty, alphabetic, and integer-overflowing ports
      produce structured `invalid_endpoint` failures without creating a client.
- [x] Shared-client schema metadata redaction conservatively consumes complete
      Authorization assignments through the next comma, semicolon, newline, or
      diagnostic boundary, including escaped or missing quoted, bracketed, and
      parenthesized delimiters, and recognizes quoted, backslash-serialized,
      underscored, hyphenated, compact, and prefixed Authorization keys whose
      Unicode-aware normalized identifier ends in `authorization` or
      `authorizationheader` before text or JSON rendering.
- [x] Active bearer values embedded in accepted endpoint paths are redacted
      from every text/JSON success and failure diagnostic, including mixed-case
      percent escapes and optional escaping of unreserved token characters.
- [x] Schema selection applies the original regex, while a filter changed by
      authentication-aware diagnostic sanitization is published as one opaque
      marker; stdout, stderr, command results, reflection, and dumps retain
      neither the complete active credential nor a co-located substring.
- [x] Preserve valid JSON output selection across executable unknown,
      duplicate, missing, and conflicting argument failures; use the validated
      normalized endpoint for runtime diagnostics. Syntax-check missing and
      duplicate `--config`/`--note-root` options in this same renderer. For
      ambiguous authentication arguments, redact the diagnostic endpoint with
      every resolved valid `--api-key-env` value or suppress it; never echo an
      unknown or positional argument value into a parse-error diagnostic.
- [x] Reject every malformed GraphQL type, member, enum, interface, possible-
      type, and named-reference identifier before publication or rendering.

### TASK-007: Document And Prove Compatibility

**Parallelizable**: Yes after syntax/output stabilize

**Completion Criteria**:

- [x] Add command help and `README.md` examples for bearer env,
      trusted-loopback unauthenticated, non-loopback HTTP opt-in, filter
      candidates, closure, output modes, and error behavior.
- [x] Use placeholders/environment names only; no literal token is documented.
- [x] Retain/add tests for all existing local/remote `kaiba graphql` document,
      file, stdin, variables, operation, endpoint normalization, body, and exit
      behavior.
- [x] Add routing regressions proving a document/argument containing `schema`
      or `graphql` does not select the subcommand.
- [x] Search schema paths for `NoteService`, database drivers, note roots, and
      local fallback; any hit requires removal or explicit test-only rationale.

### TASK-008: Run Final Gates And Handoff

**Parallelizable**: No; final

**Completion Criteria**:

- [x] Focused introspection, SDK, selection, CLI, server auth, and GraphQL
      regression tests pass.
- [x] Full Swift build/test passes; strict SwiftLint has no feature-caused
      finding and retains three documented repository-baseline errors on the
      toolchain; feature-caused findings are fixed, not suppressed.
- [x] Diff and file-size checks pass; no new/modified non-generated Swift file
      exceeds 1,000 lines.
- [x] Secret/error audit finds no credential persistence or unsafe diagnostic
      interpolation.
- [x] Handoff records exact commands/results, changed paths, remaining risks,
      and confirms no commit/push.

## Verification Commands

Run from `/Users/taco/gits/tacogips/kaiba`:

```bash
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift package describe --type json
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter KaibaClientTests
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter KaibaCLIKitTests
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'GraphQLIntrospection|GraphQLSchemaCLI'
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'httpClient|endpointURLAppendsGraphQL|CommandTests'
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint --strict --no-cache
git diff --check
{ git diff --name-only -- '*.swift'; git ls-files --others --exclude-standard -- '*.swift' | rg -v '^\.riela/'; } \
  | sort -u \
  | while IFS= read -r file; do lines=$(wc -l < "$file"); \
      if [ "$lines" -gt 1000 ]; then printf '%s %s\n' "$lines" "$file"; fi; \
    done
rg -n 'case "[^"]+"|== "[^"]+"|!= "[^"]+"|status: String|type: String|kind: String|mode: String|decision: String|provider: String' Sources/KaibaClient Sources/KaibaCLIKit --glob '*.swift'
rg -n 'Authorization: Bearer|secret-token|sentinel-schema-secret' Sources Tests README.md \
  --glob '*.swift' --glob '*.md'
rg -n 'NoteService|SQLite|DatabaseDriver|noteRoot|local.*fallback' \
  Sources/KaibaClient Sources/KaibaCLIKit --glob '*.swift'
```

The two `rg` commands are audits, not unconditional zero-match assertions:
fixed fake tokens and test names may be legitimate. Inspect every hit for real
credentials, unsafe output/error interpolation, or production store coupling.
If dependency preparation requires the repository wrapper, run equivalent
`mise run build`, `mise run test`, and `mise run lint` commands and record why.
No web/Tauri gate is required unless implementation changes `web/` or
`web/src-tauri/`.

## Completion Definition

Every deliverable/task criterion is checked; exact gates pass or an
environment-owned gap is recorded; design and plan retain no high/mid finding;
documentation matches shipped behavior; endpoint-only/no-persistence evidence
is explicit. Completion does not authorize commit or push.

## Progress Log

- 2026-09-04: Plan created from the feature-local design; implementation not
  started.
- 2026-09-04: Self-review added ownership/dependency boundaries, direct CLI
  testability, output-channel/exit coverage, file-size enforcement, and exact
  verification gates. Decision: `accepted_after_corrections`.
- 2026-09-04: Independent review found a high integration mismatch with the
  accepted parent SDK design. Corrected command path, target/API names,
  transport-security flags, introspection breadth, regex candidates, schema
  kinds, output shape/channels, and error mapping. It also added explicit
  introspection-auth bypass regressions, built-in scalars, wrapper depth, and
  routing collision tests. Decision:
  `accepted_after_corrections_with_low_risks`; no high/mid finding remains.
- 2026-09-04: Implemented the accepted parent integration: authenticated
  bounded `__schema`/`__type`, immutable public schema models, built-in scalar
  synthesis, eight-level type-reference decoding, duplicate/dangling-reference
  validation, deterministic nested sorting, regex seeds and transitive closure,
  canonical text/JSON, and first-token-only CLI routing. Added normalized
  endpoint/status/filter output and explicit stdout/stderr/exit mapping.
- 2026-09-04: Verification: package describe proved the standalone dependency
  boundary; focused SDK/CLI/introspection/server-auth tests passed; full build
  passed; final full tests passed with 769 XCTest and 56 Swift Testing tests and zero
  failures. Strict SwiftLint retained only the three pre-existing findings at
  `Sources/AppCore/NoteService.swift:654`,
  `Sources/AppCore/ResendGatewayCLIMailSender.swift:75`, and
  `Tests/AppCoreTests/AITranslationTests.swift:71`. File-size, secret/store
  coupling, and diff audits passed. No commit or push occurred.
- 2026-09-04: Plan deviations: the authoritative SDL parser lives in
  `Sources/KaibaClient/KaibaGraphQLSchema.swift` and is reused by the server
  executor, so a duplicate `GraphQLSchemaCatalog.swift` was unnecessary;
  authentication coverage lives in the focused
  `Tests/AppServerTests/GraphQLSchemaAuthorizationTests.swift` file.
- 2026-09-04: The implementation self-review required revision before
  independent review. Replaced raw regex/blacklist introspection recognition
  with bounded syntax-aware selected-operation validation and projection;
  expanded catalog, wrapper, auth, filter, output, redaction, error, and routing
  matrices; made public schema values externally immutable; and completed all
  remaining plan criteria. The unrelated PageRank adjustment was restored to
  the pre-issue state.
- 2026-09-04: Final revision verification passed 779 XCTest tests and 77 Swift
  Testing tests with zero failures. All plan criteria are complete; strict
  SwiftLint retains only the three documented repository-baseline findings;
  diff, file-size, secret, store-coupling, routing, and redaction audits passed.
  No commit or push was performed.
- 2026-09-04: Resolved `SELF-IMPL-005` by extracting the schema root inventory
  assertions from the oversized general GraphQL test file into the focused
  `Tests/AppGraphQLTests/NoteGraphQLSchemaInventoryTests.swift`. The general
  file is now 980 lines, the new file is 92 lines, and the corrected all-modified
  Swift-file audit reports no file above 1,000 lines.
- 2026-09-04: Test-integrity revision resolved `TEST-INTEGRITY-001`: schema CLI
  endpoint tests now reject ports `0`/`65536` and percent-encoded NUL/newline
  paths as `invalid_endpoint`, exit `2`, emit no stdout, and create no client.
  The shared SDK endpoint performs this validation before transport.
- 2026-09-04: Test-integrity revision resolved `TEST-INTEGRITY-002` by replacing
  marker-only sibling SDK coverage with exact document/variables fixtures and
  nontrivial decoded success, control-plane rejection, GraphQL-error, and decode-
  failure assertions for every typed convenience.
- 2026-09-04: Test-integrity revision resolved `TEST-INTEGRITY-003`: schema and
  typed-operation live HTTP tests now use OS-assigned ephemeral ports and await
  server shutdown on every success and error path. Focused endpoint, CLI,
  typed-contract, and integration tests passed with zero failures.
- 2026-09-04: Post-revision verification passed 779 XCTest tests and 80 Swift
  Testing tests with zero failures. An immediately preceding full run reproduced
  the unrelated pre-existing PageRank exact-floating-point flake; the retry
  passed unchanged. Strict SwiftLint retains only the three documented baseline
  findings. File-size, plan-completion, diff, and status audits passed; no commit
  or push occurred.
- 2026-09-04: Step 7 reopened schema-response validation, terminal escaping,
  stable ordering, GraphQL error redaction/location, and JSON invalid-regex
  completion criteria. The revision rejects absent, null, wrong-typed, or
  kind-inapplicable introspection members and reference-kind conflicts; escapes
  every text control; uses object/input/enum/scalar/interface/union order;
  redacts retained extension codes; preserves sanitized locations; and renders
  invalid regex as structured JSON stderr with exit 2 before client creation.
  All reopened criteria are rechecked.
- 2026-09-04: Step 7 revision verification passed the focused suite with 2
  XCTest and 46 Swift Testing tests and the full suite with 779 XCTest and 84
  Swift Testing tests, all with zero failures. Build, file-size, completion,
  diff, and status audits passed. Strict SwiftLint retains only the three
  documented baseline findings. No TypeScript files changed; no commit or push
  occurred.
- 2026-09-04: The second Step 7 revision routes `graphql schema` before local
  note-root/configuration loading and proves an invalid ambient
  `KAIBA_CONFIG_PATH` cannot preempt structured argument errors. Canonical text
  now includes sorted object/interface `implements` clauses with exact goldens.
  The affected routing, rendering, redaction, status, and documentation criteria
  were reopened and rechecked after verification.
- 2026-09-04: Final revision verification passed the focused suite with 11
  XCTest and 50 Swift Testing tests and the full suite with 779 XCTest and 88
  Swift Testing tests, all with zero failures. Package description, build,
  all-modified Swift-file size, zero-unchecked-criteria, TypeScript-change,
  wire-spelling, diff, and status audits passed. Strict SwiftLint reports only
  the three documented baseline findings. No commit or push occurred.
- 2026-09-04: The third Step 7 revision resolved `STEP7-REVIEW-014` by routing
  executable usage errors through the requested JSON renderer for unknown,
  duplicate, missing, and conflicting arguments. It resolved
  `STEP7-REVIEW-015` by rejecting every invalid GraphQL Name received through
  introspection before publication or text rendering. It resolved
  `STEP7-REVIEW-016` by rendering validated normalized endpoints on runtime
  failures while retaining redacted safe values for parser/endpoint failures.
- 2026-09-04: Third-revision verification passed the focused suite with 11
  XCTest and 32 Swift Testing tests and the full suite with 779 XCTest and 94
  Swift Testing tests, all with zero failures. Package description, build,
  all-modified Swift-file size, zero-unchecked-criteria, TypeScript-change,
  diff, and status audits passed. Strict SwiftLint reports only the three
  documented baseline findings. No commit or push occurred.
- 2026-09-04: The fourth Step 7 revision (`comm-000028`) changed the sibling
  SDK and additive GraphQL input contract only: optional auto-action causality,
  strict long-term-memory timestamps, and request-encoding error mapping. Schema
  discovery continues to derive these additive inputs from the authoritative
  contract. Focused and full suites, package description, build, file-size,
  completion, TypeScript-change, diff, and status audits passed; strict
  SwiftLint retains only the three documented baseline findings. No commit or
  push occurred.
- 2026-09-04: The fifth Step 7 revision (`comm-000032`) hardened the shared SDK
  error boundary used by schema discovery: coding-key and GraphQL string paths
  are credential-sanitized, and malformed non-string/non-integer GraphQL paths
  fail as `invalid_response`. The SDK focused/full suites, build, file-size,
  completion, TypeScript-change, diff, and status audits passed; strict
  SwiftLint retains only the three documented baseline findings. No commit or
  push occurred.
- 2026-09-04: The sixth Step 7 revision (`comm-000036`) requires `graphql` to
  be the validated command token after complete global-option pairs, keeps
  arbitrary argument values out of schema routing, and syntax-checks missing
  or duplicate `--config`/`--note-root` through the selected JSON renderer.
  Executable regressions cover arbitrary values, both global options, and a
  global value literally named `graphql`.
- 2026-09-04: Sixth-revision verification passed the focused suite with 16
  XCTest and 63 Swift Testing tests and the full suite with 779 XCTest and 101
  Swift Testing tests, all with zero failures. Package description, build,
  all-modified Swift-file size, zero-unchecked-criteria, TypeScript-change,
  duplicate-key, diff, and status audits passed. Strict SwiftLint reports only
  the three unchanged repository-baseline findings. No commit or push occurred.
- 2026-09-04: The Step 6 self-review revision (`comm-000038`) reopened and
  rechecked TASK-004. `SELF-IMPL-006` is resolved at the shared SDK boundary:
  decoded type references enforce null-only irrelevant fields and duplicate
  interface/possible-type relationships fail before canonical normalization.
  JSONDecoder regressions cover LIST/NON_NULL names, named `ofType`, and both
  relationship arrays.
- 2026-09-04: Seventh-revision verification passed 17 focused schema tests, the
  complete focused matrix with 16 XCTest and 63 Swift Testing tests, and an
  unchanged full-suite retry with 779 XCTest and 101 Swift Testing tests. The
  initial full run reproduced the pre-existing PageRank exact-floating-point
  flake. Package description, build, all-modified Swift-file size,
  zero-unchecked-criteria, TypeScript-change, diff, and status audits passed.
  Strict SwiftLint reports only the three unchanged repository-baseline
  findings. No commit or push occurred.
- 2026-09-04: The eighth sibling SDK/server revision (`comm-000042`) adds a
  shared 2 MiB serialized-body ceiling to direct ingest and the HTTP parser.
  Schema discovery behavior and completion criteria are unchanged; the common
  build, test, lint, size, plan, TypeScript, diff, and status gates are rerun.
- 2026-09-04: Eighth-revision common verification passed the focused matrix
  with 16 XCTest and 63 Swift Testing tests and the full suite with 779 XCTest
  and 101 Swift Testing tests. Package description, build, all-modified
  Swift-file size, zero-unchecked-criteria, TypeScript-change, diff, and status
  audits passed. Strict SwiftLint reports only the three unchanged baseline
  findings. No commit or push occurred.
- 2026-09-04: The ninth SDK/CLI revision (`comm-000046`) reopened and rechecked
  TASK-004 and TASK-006. Shared credential sanitization now covers introspection
  descriptions, deprecation reasons, and `schema_unavailable` reasons; tainted
  identifiers fail before publication. Mock-transport regressions cover SDK,
  renderer, stdout/stderr, description, reflection, and dump boundaries, and
  missing credentials use exact credential-specific text/JSON next actions.
- 2026-09-04: Ninth-revision verification passed the focused schema/CLI suite
  with 40 Swift Testing tests, the complete focused matrix with 16 XCTest and
  67 Swift Testing tests, and the full suite with 779 XCTest and 105 Swift
  Testing tests. Package description, build, all-modified Swift-file size,
  zero-unchecked-criteria, TypeScript-change, diff, status, and exact executable
  missing-credential checks passed. Strict SwiftLint reports only the three
  unchanged repository-baseline findings. No commit or push occurred.
- 2026-09-04: The adversarial revision (`comm-000051`) reopened and rechecked
  TASK-004 and TASK-006. Shared authentication-aware endpoint rendering removes
  active bearer values from readiness and schema-command success/failure
  fields, complete client-error reflection is opaque to retained partial data,
  and the production transport enforces an absolute deadline against trickling
  responses.
- 2026-09-04: Adversarial-revision verification passed the focused client/CLI
  matrix with 70 Swift Testing tests and the unchanged full-suite retry with
  779 XCTest and 108 Swift Testing tests. The preceding count-only full-suite
  run reproduced the documented unrelated PageRank exact-floating-point flake;
  the immediate retry passed without changes. Package description, build,
  all-modified Swift-file size, zero-unchecked-criteria, TypeScript-change,
  diff, and status audits passed. Strict SwiftLint reports only the three
  unchanged repository-baseline findings. No commit or push occurred.
- 2026-09-04: The Step 6 self-review revision (`comm-000053`) reopened and
  rechecked TASK-004 and TASK-006. `SELF-IMPL-007` is resolved by applying
  endpoint-specific redaction to the decoded path before text/JSON rendering;
  mixed-case percent escapes and escaped unreserved token characters have
  focused readiness and schema-command coverage.
- 2026-09-04: Self-review-revision verification passed the focused client/CLI
  matrix with 70 Swift Testing tests and the full suite with 779 XCTest and 108
  Swift Testing tests. Package description, build, all-modified Swift-file
  size, zero-unchecked-criteria, TypeScript-change, diff, status, and both exact
  executable encoding regressions passed. Strict SwiftLint reports only the
  three unchanged repository-baseline findings. No commit or push occurred.
- 2026-09-04: The Step 7 revision (`comm-000057`) reopened and rechecked
  TASK-006. Parse-error endpoint diagnostics now use every syntactically valid
  supplied `--api-key-env` value or suppress the endpoint for malformed
  credential options. A duplicate-option regression and the exact reviewer
  command prove the second environment token is absent from structured stderr.
- 2026-09-04: Latest-revision verification passed the focused matrix with 16
  XCTest and 72 Swift Testing tests and the full suite with 779 XCTest and 110
  Swift Testing tests. Package description, build, reviewer reproduction,
  all-modified Swift-file size, zero-unchecked-criteria, TypeScript-change,
  whitespace, diff, and status audits passed. Strict SwiftLint reports only the
  three unchanged repository-baseline findings. No commit or push occurred.
- 2026-09-04: The Step 6 self-review revision (`comm-000059`) reopened and
  rechecked TASK-006. Schema-command parse diagnostics no longer echo unknown
  or positional argument values. Text and structured-JSON regressions cover an
  active credential supplied as a positional value and as an option-shaped
  unknown value.
- 2026-09-04: Latest self-review-revision verification passed the focused
  matrix with 16 XCTest and 73 Swift Testing tests and the unchanged full-suite
  retry with 779 XCTest and 111 Swift Testing tests. Package description,
  build, exact text/JSON reproductions, all-modified Swift-file size,
  zero-unchecked-criteria, TypeScript-change, diff, and status audits passed.
  Strict SwiftLint reports only the three unchanged repository-baseline
  findings. No commit or push occurred.
- 2026-09-04: The Step 7 revision (`comm-000063`) rechecked the TASK-008
  secret/error audit against the shared SDK boundary. Typed control-plane
  diagnostics now receive authentication-aware bearer, Authorization-pattern,
  URL-user-information, control-character, and length sanitization before
  publication; no schema-command source behavior changed.
- 2026-09-04: Latest-revision verification passed the focused client/server
  matrix with 2 XCTest and 50 Swift Testing tests, and the full suite passed on
  an unchanged retry. Package description, build, all-modified Swift-file
  size, zero-unchecked-criteria, TypeScript-change, diff, and status audits
  passed. Strict SwiftLint reports only the three unchanged repository-
  baseline findings. No commit or push occurred.
- 2026-09-04: The Step 7 revision (`comm-000067`) reopened and rechecked
  TASK-006 and TASK-008. Runtime `auth_failed`, `connection_failed`,
  `http_failed`, `invalid_response`, and `schema_unavailable` failures now use
  documented local messages and next actions with exact text/JSON goldens,
  independent of `KaibaClientError.description` and transport detail.
- 2026-09-04: Revision verification passed package description, build, the
  focused schema/ingest/comment matrix with 12 XCTest and 28 Swift Testing
  tests, and the full suite on an unchanged retry with 779 XCTest and 112 Swift
  Testing tests. Strict SwiftLint reports only the three unchanged repository
  baseline findings. File-size, plan, TypeScript, diff, and status audits
  passed. No commit or push occurred.
- 2026-09-04: The Step 7 revision (`comm-000071`) rechecked TASK-008 against
  the shared SDK/server boundary. Bearer-authenticated Riela display
  attribution is preserved outside the reserved verified `client:` namespace,
  and long-term-memory validation/not-found failures use stable typed statuses;
  schema-command behavior is unchanged.
- 2026-09-04: Latest-revision verification passed build, the requested focused
  matrix with 6 XCTest and 28 Swift Testing tests, and the final unchanged full
  suite with 780 XCTest and 112 Swift Testing tests. Strict SwiftLint reports
  only the three unchanged repository-baseline findings. File-size, plan,
  TypeScript-change, diff, and status audits passed. No commit or push occurred.
- 2026-09-04: The Step 7 revision (`comm-000075`) reopened and rechecked
  TASK-006 and TASK-008 with the shared SDK endpoint boundary. Explicit
  integer-overflowing ports now fail SDK validation before transport, and a
  present alphabetic-port endpoint now remains distinct from a missing option:
  structured CLI output reports `invalid_endpoint`, exit 2, and creates no
  client for either case.
- 2026-09-04: Latest-revision verification passed package description, build,
  41 focused Swift Testing tests, and the full suite with zero failures. Both
  exact reviewer CLI reproductions passed. Strict SwiftLint reports only the
  three unchanged repository-baseline findings. File-size, plan,
  TypeScript-change, diff, and status audits passed. No commit or push occurred.
- 2026-09-04: The self-review revision (`comm-000077`) reopened and rechecked
  TASK-006 and TASK-008. The shared IPv6-safe endpoint boundary now rejects
  explicit empty hostname and IPv6 ports as structured `invalid_endpoint`
  failures before client creation.
- 2026-09-04: Self-review revision verification passed package description,
  build, 41 focused Swift Testing tests, the full suite with 780 XCTest and 112
  Swift Testing tests, exact hostname/IPv6 CLI reproductions, file-size, plan,
  TypeScript-change, diff, and status audits. Strict SwiftLint reports only the
  three unchanged repository-baseline findings. No commit or push occurred.
- 2026-09-04: The adversarial-review revision (`comm-000082`) rechecked the
  shared SDK/server correctness boundary. Post-create ingest evidence and
  long-term-memory idempotency conflicts were corrected in AppCore/AppGraphQL;
  schema-discovery CLI behavior and output contracts did not change.
- 2026-09-04: Revision verification passed package description, build, the
  focused matrix with 23 XCTest and 4 Swift Testing tests, ten consecutive
  focused stress runs, and the final full suite with 783 XCTest and 112 Swift
  Testing tests. One earlier count-only full run reported one XCTest failure
  without retaining its identity; the unchanged retry passed. File-size,
  zero-unchecked-criteria, TypeScript-change, diff, and status audits passed.
  Strict SwiftLint reports only the three unchanged repository-baseline
  findings. No commit or push occurred.
- 2026-09-04: The adversarial-review revision (`comm-000087`) reopened and
  rechecked TASK-003, TASK-006, and TASK-008. Authenticated introspection now
  bounds selection nodes, schema-aware projection complexity, and serialized
  response bytes. Top-level command/help resolution now consumes schema option
  values, so filters equal to `serve` or `-h` cannot reroute the command.
- 2026-09-04: Revision verification passed package description, build, 24
  focused XCTest and 34 focused Swift Testing tests, both exact executable
  reproductions, and the complete suite with 786 XCTest and 114 Swift Testing
  tests. File-size, zero-unchecked-criteria, TypeScript-change, diff, and status
  audits passed; strict SwiftLint reports
  only the three unchanged repository-baseline findings. No commit or push
  occurred.
- 2026-09-04: The Step 7 revision (`comm-000091`) reopened and rechecked
  TASK-006 and TASK-008. Schema selection retains the original regex, while
  credential-bearing filters are represented by one opaque JSON marker so
  complete active tokens and co-located substrings cannot survive in stdout,
  stderr, command results, reflection, or dumps.
- 2026-09-04: Revision verification passed package description, build, all 26
  schema-command tests, and the complete suite with 786 XCTest and 115 Swift
  Testing tests. File-size, zero-unchecked-criteria, TypeScript-change, diff,
  and status audits passed. Strict SwiftLint reports only the three unchanged
  repository-baseline findings. No commit or push occurred.
- 2026-09-05: The adversarial-review revision (`comm-000096`) reopened and
  rechecked TASK-004, TASK-006, and TASK-008. Shared endpoint diagnostics now
  publish only `/graphql`; every custom path is one opaque marker across
  bearer, unauthenticated, parser, validation, runtime, and success paths.
  The shared AppCore/AppGraphQL ingest-dispatch and association-depth fixes do
  not change schema-discovery routing or output structure.
- 2026-09-05: Revision verification passed package description, build, the
  focused matrix with 27 XCTest and 46 Swift Testing tests, the final unchanged
  full-suite retry with 789 XCTest and 117 Swift Testing tests, and the exact
  custom-path reviewer reproduction. File-size, zero-unchecked-criteria,
  TypeScript-change, deleted-file, diff, and status audits passed. Strict
  SwiftLint reports only three unchanged repository-baseline findings. No
  commit or push was performed.
- 2026-09-05: The latest Step 6 rerun rechecked TASK-004, TASK-006, and
  TASK-008 against all supplied review feedback. The shared endpoint now keeps
  its normalized transport URL module-internal, and the public symbol graph
  proves schema-command callers can observe only redacted endpoint diagnostics.
  Existing focused regressions reconfirm invalid versus missing endpoint
  classification, empty-port rejection, option-aware command/help routing,
  deterministic implements rendering, GraphQL URL-user-info sanitization, and
  opaque custom paths.
- 2026-09-05: Latest rerun verification passed the focused matrix with 25
  XCTest and 80 Swift Testing tests, `mise run build`, and the final unchanged
  full suite with 789 XCTest and 118 Swift Testing tests. Two preceding full
  attempts each reported one XCTest failure before the unchanged final pass.
  Strict SwiftLint reports only the same three repository-baseline findings.
  Package dependency, public-symbol-graph, file-size, zero-unchecked-criteria,
  TypeScript-change, whitespace, diff, and status audits passed. No commit or
  push was performed.
- 2026-09-05: The Step 7 adversarial-review revision (`comm-000107`) reopened
  and rechecked TASK-006 and TASK-008. The schema command now creates its
  fallback endpoint diagnostic through authentication-independent custom-path
  redaction before regex validation and credential lookup. JSON regressions
  cover missing credentials and invalid regex with no client construction.
- 2026-09-05: Revision verification passed 81 focused Swift Testing tests, both
  exact reviewer CLI reproductions, and `mise run build`. The unmodified full
  suite passed 790 XCTest tests after excluding the identified baseline
  floating-point exact-equality failure in `NoteRetrievalFusionTests`, plus all
  119 Swift Testing tests. Strict SwiftLint reports only the same three
  repository-baseline findings. File-size, zero-unchecked-criteria,
  TypeScript-change, whitespace, diff, and status audits passed. No commit or
  push was performed.
- 2026-09-05: The Step 7 review revision (`comm-000111`) rechecked TASK-004 and
  TASK-008. The endpoint public-surface regression now generates and parses the
  KaibaClient public symbol graph instead of matching implementation source
  text; neither `url` nor `transportURL` is published.
- 2026-09-05: Revision verification passed the generated public-symbol-graph
  test, the requested 7-test ingest/live-server matrix, and `mise run build`.
  The full suite passed after excluding the reproduced unchanged exact-
  floating-point baseline failure in `NoteRetrievalFusionTests`; strict
  SwiftLint reports only the same three repository-baseline findings. Package-
  description, file-size, zero-unchecked-criteria, TypeScript-change,
  whitespace, diff, and status audits passed. No commit or push was performed.
- 2026-09-05: The Step 7 adversarial-review revision (`comm-000116`) rechecked
  TASK-004 and TASK-008 against the shared transport contract. Excessive finite
  timeouts fail before transport, cancellation remains structured cancellation,
  and transport-value diagnostics publish only bounded metadata.
- 2026-09-05: Shared-client revision verification passed 56 focused Swift
  Testing tests, the 71-XCTest/84-Swift-Testing reviewer matrix, and `mise run
  build`. The full suite passed 790 XCTest tests after excluding the reproduced
  unchanged `NoteRetrievalFusionTests` floating-point baseline failure, plus all
  122 Swift Testing tests. Strict SwiftLint reports only three existing
  repository-baseline findings; package-description, file-size, zero-unchecked-
  criteria, TypeScript-change, deletion, whitespace, and diff audits passed. No
  commit or push was performed; `.riela` remains untouched.
- 2026-09-05: The Step 6 self-review revision (`comm-000118`) rechecked TASK-004
  against the shared SDK contract. The readiness API now propagates native and
  URL cancellation through its throwing boundary rather than returning a
  retryable connection-failure status; schema discovery remains unchanged.
- 2026-09-05: Shared-client self-review revision verification passed 57 focused
  Swift Testing tests and `mise run build`. The full suite passed 790 XCTest
  tests after excluding the reproduced unchanged `NoteRetrievalFusionTests`
  floating-point baseline failure, plus all 123 Swift Testing tests. Strict
  SwiftLint reports only three existing repository-baseline findings; package-
  description, file-size, zero-unchecked-criteria, TypeScript-change, deletion,
  whitespace, and diff audits passed. No commit or push was performed; `.riela`
  remains untouched.
- 2026-09-05: The Step 7 review revision (`comm-000122`) rechecked TASK-006 and
  TASK-008 against the shared client contract. Schema metadata sanitization now
  replaces complete quoted, bracketed, and parenthesized Authorization values;
  GraphQL, control-plane, and schema regressions cover each wrapper form.
- 2026-09-05: Shared-client revision verification passed 57 focused Swift
  Testing tests, the 71-XCTest/85-Swift-Testing reviewer matrix, `mise run
  build`, and the full suite with 791 XCTest and 123 Swift Testing tests. Strict
  SwiftLint reports only three existing repository-baseline findings. An
  unchanged skip-build repeat reproduced the documented intermittent exact-
  equality failure in `NoteRetrievalFusionTests` while all 123 Swift Testing
  tests passed. Package-description, file-size, zero-unchecked-criteria,
  TypeScript-change, deletion, whitespace, and diff audits passed. No commit or
  push was performed; `.riela` remains untouched.
- 2026-09-05: The Step 6 self-review revision (`comm-000124`) rechecked TASK-006
  and TASK-008 against the shared client contract. Unterminated Authorization
  wrappers are conservatively consumed through their diagnostic boundary, with
  GraphQL, control-plane, and schema regressions for every wrapper form.
- 2026-09-05: Shared-client self-review verification passed 57 focused Swift
  Testing tests, the 71-XCTest/85-Swift-Testing reviewer matrix, and `mise run
  build`. The full suite passed 790 XCTest tests after excluding the reproduced
  unchanged `NoteRetrievalFusionTests` exact-equality baseline failure, plus all
  123 Swift Testing tests. Strict SwiftLint reports only three existing
  repository-baseline findings; package-description, file-size, zero-unchecked-
  criteria, TypeScript-change, deletion, whitespace, and diff audits passed. No
  commit or push was performed; `.riela` remains untouched.
- 2026-09-05: The Step 6 self-review revision (`comm-000126`) rechecked TASK-006
  and TASK-008 against the shared-client contract. Authorization assignments
  now redact through their diagnostic boundary independently of escaped quote,
  bracket, or parenthesis characters; GraphQL error, control-plane diagnostic,
  and schema metadata regressions cover each escaped delimiter form.
- 2026-09-05: Shared-client escaped-delimiter verification passed 57 focused
  Swift Testing tests, the 71-XCTest/85-Swift-Testing reviewer matrix, `mise
  run build`, package description, file-size, zero-unchecked-criteria,
  TypeScript-change, deletion, whitespace, and diff audits. An initial full-
  suite run hit an unrelated intermittent assertion at
  `Tests/AppServerTests/AgentReplyStreamHubTests.swift:754`; the unchanged
  `swift test --skip-build` retry passed all 791 XCTest and 123 Swift Testing
  tests. Strict SwiftLint reports only three existing repository-baseline
  findings. No commit or push was performed; `.riela` remains untouched.
- 2026-09-05: The Step 6 self-review revision (`comm-000128`) rechecked TASK-006
  and TASK-008 against the shared-client contract. Plain, quoted, and
  backslash-serialized Authorization keys now reach the same conservative
  assignment-boundary sanitizer, with GraphQL error, control-plane diagnostic,
  and schema metadata regressions combining quoted keys and escaped values.
- 2026-09-05: Shared-client quoted-key verification passed 57 focused Swift
  Testing tests, the 71-XCTest/85-Swift-Testing reviewer matrix, `mise run
  build`, and the full suite with 791 XCTest and 123 Swift Testing tests. Strict
  SwiftLint reports only three existing repository-baseline findings. Package-
  description, file-size, zero-unchecked-criteria, TypeScript-change, deletion,
  whitespace, and diff audits passed. No commit or push was performed; `.riela`
  remains untouched.
- 2026-09-05: The Step 6 self-review revision (`comm-000130`) rechecked TASK-006
  and TASK-008 against the shared-client contract. Underscored, hyphenated,
  compact, and HTTP-prefixed Authorization header aliases now reach the same
  conservative assignment-boundary sanitizer. GraphQL errors, control-plane
  diagnostics, and schema metadata combine those aliases with escaped values.
- 2026-09-05: Shared-client Authorization-alias verification passed 57 focused
  Swift Testing tests, the 71-XCTest/85-Swift-Testing reviewer matrix, and `mise
  run build`. Full-suite runs reproduced the unrelated exact-equality failure at
  `Tests/AppCoreTests/NoteRetrievalFusionTests.swift:148`; excluding that test
  passed 790 XCTest and all 123 Swift Testing tests. Strict SwiftLint reports
  only three existing repository-baseline findings. Package-description, file-
  size, zero-unchecked-criteria, TypeScript-change, workflow-change, deletion,
  whitespace, and diff audits passed. No commit or push was performed; `.riela`
  remains untouched.
- 2026-09-05: The Step 6 self-review revision (`comm-000132`) rechecked TASK-006
  and TASK-008 against the shared-client contract. Authorization-key matching
  now normalizes identifier suffixes instead of enumerating prefixes, covering
  snake-case and camel-case proxy aliases plus other prefixed forms across
  GraphQL errors, control-plane diagnostics, and schema metadata.
- 2026-09-05: Shared-client prefixed-alias verification passed 57 focused Swift
  Testing tests, the 71-XCTest/85-Swift-Testing reviewer matrix, and `mise run
  build`. Full-suite runs reproduced the unrelated exact-equality failure at
  `Tests/AppCoreTests/NoteRetrievalFusionTests.swift:148`; excluding that test
  passed 790 XCTest and all 123 Swift Testing tests. Strict SwiftLint reports
  only three existing repository-baseline findings. Package-description, file-
  size, zero-unchecked-criteria, TypeScript-change, workflow-change, deletion,
  whitespace, and diff audits passed. No commit or push was performed; `.riela`
  remains untouched.
- 2026-09-05: The Step 6 self-review revision (`comm-000134`) rechecked TASK-006
  and TASK-008 against the shared-client contract. Authorization-key matching
  now consumes Unicode letter, mark, number, and connector prefixes and uses a
  Unicode-aware suffix boundary. Latin and CJK-prefixed escaped-value
  regressions cover GraphQL errors, control-plane diagnostics, and schema
  metadata.
- 2026-09-05: Shared-client Unicode-prefixed-alias verification passed 57
  focused Swift Testing tests, the 71-XCTest/85-Swift-Testing reviewer matrix,
  `mise run build`, and the full suite with 791 XCTest and 123 Swift Testing
  tests. Strict SwiftLint reports only three existing repository-baseline
  findings. Package-description, file-size, zero-unchecked-criteria,
  TypeScript-change, workflow-change, deletion, whitespace, and diff audits
  passed. No commit or push was performed; `.riela` remains untouched.

- 2026-09-05: The Step 7 adversarial revision (`comm-000139`) rechecked the
  shared SDK/server boundary used by schema discovery. Ingest now has
  principal-scoped canonical idempotency and a hidden pending lifecycle with
  one terminal change-feed publication. No schema-discovery behavior changed;
  the shared client remains transport-only with no local-store fallback.
- 2026-09-05: Shared-boundary verification passed the focused ingest suite,
  reviewer matrix, build, package description, file-size, plan, TypeScript,
  workflow, deletion, whitespace, and diff audits. The full suite reproduced
  only the documented `NoteRetrievalFusionTests.swift:148` exact-equality
  baseline, and the excluded-test run passed. Strict SwiftLint reports only
  three repository-baseline findings. No commit or push was performed; `.riela`
  remains untouched.
- 2026-09-05: The Step 6 test-integrity revision (`comm-000142`) rechecked the
  shared SDK/server boundary. Pending-ingest direct reads and search plus
  cross-principal idempotency now have deterministic regressions; no schema-
  discovery behavior changed. Focused tests, the reviewer matrix, build, the
  excluded-baseline full suite, lint-baseline review, package description, and
  repository audits passed. No commit or push was performed; `.riela` remains
  untouched.
- 2026-09-05: The Step 7 implementation-review revision (`comm-000146`)
  rechecked the shared SDK/server boundary. Pending ingest rows are excluded
  inside every search and graph-expansion query before pagination, public
  notebook metadata cannot forge the server-owned ingest marker, and a
  persisted recovery record makes terminal reveal failures retryable without
  losing committed identities. No schema-discovery behavior changed.
- 2026-09-05: `comm-000146` verification passed 11 focused XCTest tests, the
  16-XCTest/51-Swift-Testing reviewer matrix, `mise run build`, and the full
  XCTest/123-Swift-Testing suite. Strict SwiftLint reports only three
  repository-baseline findings. Package-description, file-size, plan,
  TypeScript, workflow, deletion, whitespace, and diff audits passed. No
  commit or push was performed; `.riela` remains untouched.
- 2026-09-05: The Step 6 self-review revision (`comm-000148`) rechecked the
  shared SDK/server boundary. Long-term-memory graph operations now exclude
  pending ingests, and AppCore's ingest-marker capability and lifecycle APIs
  are package-internal with public-symbol-graph coverage. No schema-discovery
  behavior changed.
- 2026-09-05: `comm-000148` shared-boundary verification passed 29 focused
  XCTest tests, the 36-XCTest/51-Swift-Testing reviewer matrix, `mise run
  build`, and the full XCTest/123-Swift-Testing suite. Strict SwiftLint reports
  only three repository-baseline findings. Public-symbol-graph, package,
  file-size, plan, TypeScript, workflow, deletion, whitespace, and diff audits
  passed. No commit or push was performed; `.riela` remains untouched.
- 2026-09-05: The session-6 Step 6 rerun rechecked the shared SDK/server
  boundary against every supplied high/mid finding. Ingest validation now
  precedes the durable idempotency claim, and pending retries atomically
  reclaim a claim abandoned before notebook creation. Schema discovery output,
  filtering, authentication, and legacy GraphQL routing are unchanged.
- 2026-09-05: Session-6 shared-boundary verification passed the reviewer-
  focused matrix with 35 XCTest and 57 Swift Testing tests, `mise run build`,
  `mise run test` including all 123 Swift Testing tests, and `mise run lint`
  with zero serious violations and only three unchanged baseline warnings. No
  TypeScript files changed. No commit or push was performed; `.riela` remains
  untouched.
- 2026-09-05: The session-6 Step 7 adversarial revision (`comm-000157`)
  rechecked the shared SDK/server boundary. Durable created-state recovery,
  pending tag isolation, and terminal-only action-history publication close
  server-side ingest lifecycle gaps without changing schema discovery output,
  authentication, transitive filtering, or legacy GraphQL routing. Focused and
  repository-wide verification passed as recorded with the SDK implementation
  plan: 46 XCTest plus 85 Swift Testing focused tests, and 801 XCTest plus 123
  Swift Testing full-suite tests.
- 2026-09-05: The session-6 Step 6 self-review revision (`comm-000159`)
  closes the remaining public pending-tag catalog path in the shared server
  boundary. Schema discovery output, authentication, transitive filtering, and
  legacy GraphQL routing remain unchanged.
- 2026-09-05: `comm-000159` shared-boundary verification passed the two new
  targeted regressions, the 47-XCTest/85-Swift-Testing reviewer matrix, `mise
  run build`, the complete `mise run test` suite, and `mise run lint` with zero
  serious violations and three unchanged baseline warnings.
- 2026-09-05: The session-6 Step 7 revision (`comm-000163`) guarantees cleanup
  of shared server-side ingest execution ownership after every owning
  invocation. The schema-discovery contract, authentication, filtering, and
  legacy GraphQL routing remain unchanged.
- 2026-09-05: `comm-000163` shared-boundary verification passed the 48-XCTest/
  85-Swift-Testing reviewer matrix, `mise run build`, the complete `mise run
  test` suite, `mise run lint`, package-boundary and file-size checks, and the
  TypeScript, workflow, deleted-file, whitespace, and diff audits.
- 2026-09-05: The session-6 Step 6 self-review revision (`comm-000165`) makes
  shared ingest ownership cleanup exactly-once across successful abandonment
  while retaining failed-cleanup fallback. Schema discovery behavior remains
  unchanged.
- 2026-09-05: `comm-000165` shared-boundary verification passed the targeted
  stale-release regression, all 13 ingest concurrency/reconciliation XCTest
  tests, the 48-XCTest/85-Swift-Testing reviewer matrix, `mise run build`, the
  complete `mise run test` suite including 123 Swift Testing tests, `mise run
  lint`, package-boundary and file-size checks, and the TypeScript, workflow,
  deleted-file, whitespace, and diff audits.
- 2026-09-05: The session-6 Step 7 revision (`comm-000169`) closes shared
  ingest preflight gaps for page metadata and attachment roles before any
  idempotency claim. Schema discovery output and filtering remain unchanged.
- 2026-09-05: `comm-000169` shared-boundary verification passed the targeted,
  client-boundary, reconciliation, reviewer-matrix, build, full-suite rerun,
  lint, package-boundary, file-size, web, TypeScript, workflow, deleted-file,
  whitespace, and diff checks. The initial full-suite run's unrelated exact-
  floating-point flake passed both isolated and complete-suite reruns.
- 2026-09-05: The session-6 self-review revision (`comm-000171`) strengthens
  the shared ingest-boundary regression by comparing complete note-ID sets
  across every rejected preflight input. Schema discovery behavior remains
  unchanged.
- 2026-09-05: `comm-000171` shared-boundary verification passed the targeted
  regression, the 48-XCTest/85-Swift-Testing reviewer matrix, `mise run build`,
  the complete `mise run test` suite including 123 Swift Testing tests, and
  `mise run lint` with zero serious violations and three unchanged baseline
  warnings.
- 2026-09-05: The session-6 Step 7 revision (`comm-000175`) closes the shared
  server-boundary deferred-ingest lifecycle by making it package-internal and
  exactly-once for terminal event/action publication. Schema discovery output,
  filtering, authentication, and CLI compatibility remain unchanged.
- 2026-09-05: `comm-000175` shared-boundary verification passed the targeted
  lifecycle and public-symbol regressions, the reviewer matrix, build, the
  complete test-suite rerun, lint, package-boundary and file-size checks, and
  TypeScript, workflow, web, deleted-test, whitespace, and diff audits. The
  first full-suite run's known exact-floating-point flake passed in isolation
  and on the complete rerun.
- 2026-09-05: The session-6 adversarial revision (`comm-000180`) adds
  connection-owned cancellable route tasks and bounded ingest-claim waiting at
  the shared HTTP/server boundary. Schema discovery output, authentication,
  filtering, and CLI compatibility remain unchanged.
- 2026-09-05: `comm-000180` shared-boundary verification passed the
  39-XCTest/85-Swift-Testing reviewer matrix, build, one complete 807-XCTest/
  123-Swift-Testing suite rerun, lint, package-boundary and file-size checks,
  and TypeScript, workflow, web, deleted-test, whitespace, and diff audits.
  Additional complete attempts reproduced only the pre-existing exact-
  floating-point `NoteRetrievalFusionTests` flake, which passed in isolation.
- 2026-09-05: The session-6 self-review revision (`comm-000182`) adds an
  atomic cancel-before-handler-entry gate and truthful live-worker accounting
  to the shared HTTP server. Schema discovery output, authentication,
  filtering, and CLI compatibility remain unchanged.
- 2026-09-05: `comm-000182` shared-boundary verification passed the targeted
  and 40-XCTest/85-Swift-Testing reviewer matrices, build, lint, package-
  boundary and file-size checks, and TypeScript, workflow, web, deleted-test,
  whitespace, and diff audits. The complete suite was blocked only by the
  pre-existing `NoteRetrievalFusionTests` exact-floating-point assertion,
  which passed in isolation; all 123 Swift Testing tests passed.

## Remaining Risks

- The bounded introspection support satisfies the SDK but not every arbitrary
  third-party introspection document.
- Future SDL syntax may require deliberate catalog-parser expansion.
- Integration depends on the sibling SDK landing the accepted endpoint/auth/
  transport/error boundary; duplication is forbidden if it diverges.
