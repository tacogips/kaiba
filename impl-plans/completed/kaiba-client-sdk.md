# Public Kaiba Swift Client SDK

**Status**: Completed; verification complete with three pre-existing SwiftLint findings
**Issue**: `local-request:/Users/taco/gits/tacogips/kaiba:Add first-party Kaiba Swift client SDK and schema discovery CLI`
**Design Reference**: `design-docs/specs/kaiba-client-sdk.md`
**Workflow Mode**: `issue-resolution`

## Purpose

Implement the accepted standalone `KaibaClient` boundary, additive GraphQL
server operations needed by Riela, deterministic readiness, authenticated
schema discovery/filtering, and the `kaiba graphql schema` command. Preserve
all existing `AppCore`, `AppGraphQL`, and `kaiba graphql` execution behavior.
Do not modify Riela, commit, or push in this work package.

## Dependencies And Order

```text
TASK-001 package targets
  -> TASK-002 endpoint/auth/transport/errors
  -> TASK-003 arbitrary execution/readiness
  -> TASK-004 schema model/filter/render
       -> TASK-005 authenticated server introspection
       -> TASK-009 CLI schema command
  -> TASK-006 typed existing operations
       -> TASK-007 additive note/ingest operations
       -> TASK-008 additive long-term-memory operations
TASK-002...009 -> TASK-010 docs -> TASK-011 verification
```

Tasks marked parallelizable may proceed only after their stated prerequisites.
No task may introduce a dependency from `KaibaClient` to Kaiba implementation
targets or a local-store fallback.

## Deliverables

- [x] `Package.swift`: public `KaibaClient` product/target; internal
      `KaibaCLIKit`; `KaibaClientTests` and `KaibaCLIKitTests`; updated target
      dependencies with no `AppCore` dependency from the SDK.
- [x] `Sources/KaibaClient/`: endpoint/authentication policy, redirect-safe
      HTTP transport, arbitrary GraphQL execution, typed errors/redaction,
      readiness, schema discovery/filter/rendering, DTOs, and operation
      conveniences.
- [x] `Sources/KaibaCLIKit/GraphQLSchemaCommand.swift`: schema subcommand
      parsing, execution, stable text/JSON output, exit/error mapping.
- [x] `Sources/AppCLI/main.swift` and `Sources/AppCore/Command.swift`: route and
      document the schema subcommand without changing legacy document mode.
- [x] `Sources/AppGraphQL/GraphQLHTTPDocumentClient.swift` and
      `Sources/AppCLI/GraphQLCommand.swift`: retained compatibility boundary;
      existing focused tests remain green.
- [x] `Sources/AppGraphQL/`: authenticated introspection plus additive links,
      notebook attachment/ingest, and long-term-memory schema/execution.
- [x] `Tests/KaibaClientTests/`, `Tests/KaibaCLIKitTests/`, focused
      `Tests/AppGraphQLTests/`, and `Tests/AppServerTests/` coverage.
- [x] `README.md`, `design-docs/specs/command.md`, and, if operation details
      need a cross-reference, `design-docs/specs/kaiba-note.md` updates.
- [x] Focused and full Swift build/test verification plus strict SwiftLint
      execution with its three unchanged repository-baseline findings and exact
      commands recorded in the progress log.

## Tasks

### TASK-001: Establish the standalone package boundaries

**Parallelizable**: No

**Files**:

- `Package.swift`
- `Sources/KaibaClient/KaibaClient.swift`
- `Sources/KaibaCLIKit/GraphQLSchemaCommand.swift`
- `Tests/KaibaClientTests/KaibaClientBoundaryTests.swift`
- `Tests/KaibaCLIKitTests/GraphQLSchemaCommandTests.swift`

**Work**:

- Add the public `KaibaClient` library product and target with no target
  dependency beyond system Foundation modules.
- Add non-product `KaibaCLIKit` depending on `KaibaClient`; make `AppCLI`
  depend on it without moving or rewriting the legacy
  `Sources/AppCLI/GraphQLCommand.swift` path.
- Add test targets whose dependency lists prove the client and CLI support
  seams can be tested without `AppCore` or a database.
- Establish public access control, `Sendable` conformance, and a small facade;
  split later types by responsibility before any file approaches 1,000 lines.

**Completion Criteria**:

- [x] `swift package describe --type json` shows `KaibaClient` has no
      `AppCore`, `AppGraphQL`, `AppServer`, SQLite, or Anydoc dependency.
- [x] A boundary test imports only `KaibaClient` and constructs a client with
      an injected transport.
- [x] The existing `AppCLI/GraphQLCommand.swift` remains at its path and
      existing command tests/build behavior are unchanged.

### TASK-002: Implement endpoint, authentication, transport, and redaction policy

**Parallelizable**: No; depends on TASK-001

**Files**:

- `Sources/KaibaClient/KaibaEndpoint.swift`
- `Sources/KaibaClient/KaibaAuthentication.swift`
- `Sources/KaibaClient/KaibaHTTPTransport.swift`
- `Sources/KaibaClient/KaibaClientError.swift`
- `Sources/KaibaClient/KaibaRedaction.swift`
- `Tests/KaibaClientTests/KaibaClientPublicAPITests.swift`
- `Tests/KaibaClientTests/KaibaEndpointTests.swift`
- `Tests/KaibaClientTests/KaibaHTTPTransportTests.swift`
- `Tests/KaibaClientTests/KaibaRedactionTests.swift`

**Work**:

- Implement exact endpoint normalization and loopback classification from the
  design, including IPv4 `127/8`, IPv6 `::1`, `localhost.`, custom paths,
  default ports, and rejection of user info/query/fragment/control/dot paths.
- Require `.bearer` or `.unauthenticated`; validate a non-codable redacting
  bearer wrapper; enforce TLS/remote unauthenticated explicit overrides.
- Implement request/response transport values and a URLSession transport with
  finite absolute deadline, platform TLS, cancellation propagation, and
  redirects disabled. Never copy an Authorization header to a redirect.
- Enforce the configured 2 MiB encoded-request and 8 MiB streaming-response
  defaults without buffering past the response limit; cover bounded overrides.
- Implement stable error codes/categories and bounded redaction without raw
  bodies, documents, variables, headers, localized transport descriptions, or
  tokens.

**Completion Criteria**:

- [x] Table tests cover bare/custom localhost and remote endpoints, IPv4/IPv6,
      invalid schemes/ports/user info/query/fragment/dot segments, and both
      insecure transport opt-ins. Explicit empty, alphabetic, and integer-
      overflowing authority ports fail as `invalid_endpoint` before
      transport/client creation.
- [x] Tests prove bearer values are absent from description/debug reflection,
      `Mirror`, `dump`, encoded output, endpoint diagnostics, GraphQL messages,
      and redirect handling; retained extension codes and URL user-information
      receive the same credential redaction and sanitized GraphQL locations
      remain available. GraphQL path strings and typed-decoding coding keys use
      the same sanitizer, while non-string/non-integer GraphQL path components
      fail as `invalid_response`. Retained `schema_unavailable` reasons receive
      the same active-token and Authorization-pattern sanitization.
- [x] Authorization-pattern sanitization conservatively consumes complete
      assignments through the next comma, semicolon, newline, or diagnostic
      boundary, including escaped or missing quoted, bracketed, and
      parenthesized delimiters, across GraphQL errors, control-plane
      diagnostics, and schema metadata. Quoted, backslash-serialized, and
      underscored, hyphenated, compact, and prefixed Authorization aliases
      receive the same redaction when their Unicode-aware normalized identifier
      ends in `authorization` or `authorizationheader`.
- [x] Active-token redaction covers readiness and CLI success/failure endpoint
      diagnostics, including accepted custom paths containing mixed-case
      percent escapes or escaped unreserved token characters; full
      `KaibaClientError` reflection and dumps never expose retained partial data.
- [x] Every non-`/graphql` endpoint path is opaque in bearer and unauthenticated
      diagnostics, including parser, validation, readiness, runtime, success,
      reflection, and dump paths; the normalized raw URL is module-internal,
      absent from the public symbol graph, and retained only for transport.
- [x] Schema-command fallback diagnostics redact custom paths before regex
      compilation and credential lookup, including missing-credential and
      invalid-regex failures that cannot construct authentication.
- [x] 3xx, 401/403, timeout, DNS/connectivity, other HTTP, malformed response,
      GraphQL, and decoding failures remain distinct.
- [x] Exact-limit and one-byte-over request/response fixtures prove preflight
      rejection and streaming cancellation.
- [x] A continuously trickling response cannot extend the configured absolute
      wall-clock deadline.
- [x] `KaibaClient.init` revalidates every finite-positive timeout and byte-limit
      invariant so a configuration mutated after construction cannot bypass the
      public construction contract.
- [x] Configuration and direct transport entry points reject timeouts above the
      documented 24-hour representability ceiling before `Duration` conversion.
- [x] Public HTTP request/response description, debug reflection, `Mirror`, and
      `dump` expose only opaque endpoint metadata, header names, status, byte
      counts, and timeout; bearer values and bodies never appear.

### TASK-003: Add arbitrary GraphQL execution and readiness

**Parallelizable**: No; depends on TASK-002

**Files**:

- `Sources/KaibaClient/KaibaJSONValue.swift`
- `Sources/KaibaClient/KaibaGraphQL.swift`
- `Sources/KaibaClient/KaibaReadiness.swift`
- `Tests/KaibaClientTests/KaibaGraphQLExecutionTests.swift`
- `Tests/KaibaClientTests/KaibaReadinessTests.swift`

**Work**:

- Implement Codable JSON values, GraphQL request/envelope/error models, and
  untyped plus generic typed `execute` overloads.
- Protect transport-owned headers and validate document, variables, and
  operation name before sending.
- Retain optional partial data in a GraphQL error while keeping it out of
  descriptions and opaque diagnostic reflection.
- Implement the one-request `notes(limit: 0)` readiness probe and structural
  result validation; do not retry or classify by message text.

**Completion Criteria**:

- [x] Recorded-request tests assert canonical POST body and headers for bearer
      and explicit unauthenticated modes.
- [x] Arbitrary documents, variables, named operations, partial data, empty
      errors, invalid envelopes, and typed decoding paths have deterministic
      fixtures.
- [x] Readiness fixtures cover ready bearer/unauthenticated, 401/403, timeout,
      connection failure, `accepted == false`, and incompatible alias/shape.
- [x] Readiness endpoint evidence applies decoded-path active-token redaction,
      including mixed-case and escaped-unreserved forms, without changing the
      operational endpoint URL.
- [x] Arbitrary and typed execution propagate `CancellationError`, including a
      cancellation-originated `URLError.cancelled`, instead of returning
      retryable `connection_failed`.
- [x] The throwing readiness probe propagates native `CancellationError` and
      cancellation-originated `URLError.cancelled` instead of publishing a
      retryable `connectionFailed` readiness status.

### TASK-004: Implement schema model, validation, closure, and rendering

**Parallelizable**: Yes after TASK-003

**Files**:

- `Sources/KaibaClient/KaibaGraphQLSchema.swift`
- `Sources/KaibaClient/KaibaGraphQLSchemaValidation.swift`
- `Sources/KaibaClient/KaibaSchemaIntrospection.swift`
- `Sources/KaibaClient/KaibaSchemaFilter.swift`
- `Sources/KaibaClient/KaibaSchemaRenderer.swift`
- `Tests/KaibaClientTests/KaibaSchemaDiscoveryTests.swift`
- `Tests/KaibaClientTests/KaibaSchemaFilterTests.swift`
- `Tests/KaibaClientTests/KaibaSchemaRendererTests.swift`

**Work**:

- Define typed schema kind/reference/member models and the canonical standard
  introspection document.
- Decode and validate query/mutation roots, nested `LIST`/`NON_NULL` references,
  duplicate definitions, and every referenced named type.
- Compile the optional ICU regex before client execution. Match simple and
  qualified seed names, compute visited-set transitive closure, keep unmatched
  root fields excluded, include reachable interfaces/unions only as related
  types, and exclude introspection meta-types.
- Canonically sort every collection and render the stable JSON structure and
  SDL excerpt, including the fixed empty-match text.

**Completion Criteria**:

- [x] Invalid regex invokes the injected transport zero times.
- [x] Tests cover query, mutation, object, input, enum, scalar, interface,
      union, list/non-null, cycles, built-in scalars, empty match, no filter,
      dangling references, conflicting duplicates/reference kinds, wrong-typed
      optional members, kind-specific member shapes, and complete control-character
      escaping.
- [x] Public `Decodable` schema initialization runs the same validation and
      canonical ordering boundary; known type-reference fields obey wrapper
      shape rules, duplicate interface/possible-type relationships fail, and
      malformed or duplicate decoded input returns an error without reaching a
      trapping dictionary initializer.
- [x] Introspection descriptions and deprecation reasons are credential-
      sanitized before publication; identifiers and references that would be
      altered by redaction fail as `schema_unavailable` without echoing the
      rejected value.
- [x] Equivalent shuffled introspection responses produce byte-identical text
      and sorted-key JSON.
- [x] Schema-discovery GraphQL failures map to `schema_unavailable`; auth and
      connection errors retain their specific codes.

### TASK-005: Serve authenticated standard introspection

**Parallelizable**: Yes after TASK-004; coordinate with TASK-007/TASK-008 SDL edits

**Files**:

- `Sources/AppGraphQL/GraphQLContractProjector.swift`
- `Sources/AppGraphQL/NoteGraphQLDocumentExecutor.swift`
- `Sources/AppGraphQL/NoteGraphQLDocumentExecutorSupport.swift`
- new focused introspection support files under `Sources/AppGraphQL/`
- `Sources/AppServer/ServerContracts.swift`
- `Tests/AppGraphQLTests/GraphQLIntrospectionTests.swift`
- `Tests/AppServerTests/GraphQLIntrospectionAuthenticationTests.swift`

**Work**:

- Parse the authoritative SDL through the shared schema model and materialize
  the standard `__schema`/`__type` fields selected by the SDK's bounded
  canonical introspection query.
- Route introspection before ordinary note root dispatch while preserving
  parsing limits and explicit GraphQL errors for unsupported selections.
- Make the server authentication predicate treat introspection as protected
  whenever ordinary GraphQL is protected. Do not add a GET/local SDL endpoint.
- Add a contract test that all advertised ordinary root fields map to executor
  support and all references resolve after TASK-007/TASK-008 changes.

**Completion Criteria**:

- [x] Canonical `__schema` and `__type` requests return a structurally valid,
      complete representation of `GraphQLContractProjector.schemaContract`.
- [x] Missing/invalid bearer receives the existing 401 behavior and no schema;
      authenticated and explicitly unauthenticated server modes behave per
      server policy.
- [x] Unsupported introspection selections return bounded GraphQL errors and
      never a fabricated partial schema.
- [x] Selection-node and schema-aware projection-complexity budgets reject
      alias breadth before projection, and an independent serialized-response
      byte limit rejects oversized output; amplification regressions cover all
      three enforcement boundaries.

### TASK-006: Implement typed conveniences over existing GraphQL fields

**Parallelizable**: Yes after TASK-003

**Files**:

- `Sources/KaibaClient/KaibaIdentifiers.swift`
- `Sources/KaibaClient/KaibaModels.swift`
- `Sources/KaibaClient/KaibaNoteOperations.swift`
- `Sources/KaibaClient/KaibaNotebookOperations.swift`
- `Sources/KaibaClient/KaibaTagOperations.swift`
- `Sources/KaibaClient/KaibaAttachmentOperations.swift`
- `Sources/KaibaClient/KaibaCommentOperations.swift`
- `Sources/KaibaClient/KaibaConversationOperations.swift`
- family-matched fixtures/tests under `Tests/KaibaClientTests/`
- `Tests/AppServerTests/KaibaClientServerIntegrationTests.swift`

**Work**:

- Add distinct ID wrappers, input/output DTOs, control-plane results, and
  lossless open enums for extensible wire values.
- Implement fixed operation documents for the accepted note, notebook, tag,
  attachment, comment, and conversation methods already represented in the
  server schema.
- Make selection sets cover current Riela payload fields and keep document
  construction internal; use arbitrary execution for unsupported future data.
- Preserve response ordering and server validation rather than clamping inputs
  silently in the client.

**Completion Criteria**:

- [x] Every method has an outgoing document/variables fixture and success,
      control-plane rejection, GraphQL error, and decode-failure coverage.
- [x] Every typed control-plane payload shape sanitizes active bearer values,
      Authorization-like fragments, URL user information, and control
      characters from `result.diagnostics` before public return.
- [x] Note list/search methods expose the complete filters used by Riela,
      including tag/class filters, linked-neighbor inclusion, and depth, with
      exact request and decoded-result parity tests.
- [x] `createNote`, `updateNote`, `createNotebook`, and `saveConversation`
      accept optional typed auto-action causality, include it exactly in their
      request fixtures, and preserve live-server dispatch suppression.
- [x] File DTOs and fixed selections preserve Riela's storage attributes
      (`localPath`, S3 profile/bucket/key and derived URL, and `migratedAt`) in
      exact fixtures and a live-server payload-parity test.
- [x] Bearer-authenticated note creation, tag assignment, comments, and
      conversations preserve explicit Riela `author`/`assignedBy` labels while
      reserving `client:` for verified server attribution; exact wire and live
      server tests cover the boundary.
- [x] Typed operation statuses decode and encode the server's underscore wire
      spellings, including real `not_found` and `invalid_request` responses and
      exact malformed long-term-memory append/recall statuses.
- [x] Identifier types cannot be mixed without an explicit raw-value boundary.
- [x] Unknown extensible status/role values round-trip through `.custom`.
- [x] No operation imports or calls `NoteService`, configuration loaders,
      database drivers, file paths, or process environment.
- [x] A real loopback `KaibaServerRuntime` test exercises representative read
      and write methods through `KaibaClient`, proving the fixed documents and
      DTOs agree with the live executor rather than only canned JSON.
- [x] Arbitrary and typed request JSON encoding failures, including NaN and
      infinities, map to `invalid_request` before any transport call.

### TASK-007: Add note links, notebook attachments, and ingest GraphQL operations

**Parallelizable**: Yes after TASK-006; coordinate authoritative SDL with TASK-005

**Files**:

- `Sources/AppGraphQL/GraphQLNoteSchemaContract.swift`
- `Sources/AppGraphQL/GraphQLContractProjector.swift`
- `Sources/AppGraphQL/NoteGraphQLContracts.swift`
- `Sources/AppGraphQL/NoteGraphQLDocumentInputs.swift`
- `Sources/AppGraphQL/NoteGraphQLDocumentExecutor.swift`
- `Sources/AppGraphQL/NoteGraphQLDocumentExecutorSupport.swift`
- `Sources/AppGraphQL/NoteGraphQLService.swift`
- `Sources/AppCore/NoteService+NotebookIngestIdempotency.swift`
- `Sources/AppServer/KaibaLocalHTTPServer.swift`
- `Sources/KaibaClient/KaibaIngestOperations.swift`
- `Tests/AppServerTests/KaibaClientHTTPTransportTests.swift`
- `Tests/AppServerTests/KaibaLocalHTTPServerCapacityTests.swift`
- `Tests/AppServerTests/NotebookIngestConcurrencyTests.swift`
- `Tests/AppGraphQLTests/NoteGraphQLClientBoundaryTests.swift`
- `Tests/KaibaClientTests/KaibaIngestOperationsTests.swift`

**Work**:

- Add `noteLinks`, `notebookFiles`, `attachNotebookFile`, and
  `ingestNotebookPages` schema types and executor dispatch.
- Reuse `NoteService` authorization, transactional notebook/page creation,
  attachment storage, audit attribution, and change publication; do not copy
  SQL into GraphQL.
- Validate page count/numbers, per-page markdown size, filenames/media types,
  base64, aggregate decoded attachments, and serialized body budget before
  mutation work. Use the shared 2 MiB serialized-body limit at the direct
  GraphQL service and HTTP parser boundaries. Accept bytes, never server-local
  paths.
- Return explicit committed notebook/note/attachment identities when a
  post-create attachment fails; do not hide partial state or attempt client
  rollback.
- Implement typed `ingestNotebookPages` and `ingestDocument` wrappers for
  caller-converted pages/source metadata and preflight encoded request size.

**Completion Criteria**:

- [x] Tests cover authorization scoping, audit attribution, ordering, bounds,
      invalid base64/media/filename/page numbers, direct aggregate serialized
      input above 2 MiB returning `invalid_request` with zero notebook/note
      writes, transaction rollback on page creation failure, and explicit
      reconciliation evidence for attachment failure.
- [x] Note links and both attachment scopes reproduce the fields required by
      current Riela add-on payloads.
- [x] Document convenience tests prove conversion/OCR is caller-owned and no
      path or local-store fallback exists.
- [x] Ingest conveniences preserve optional typed auto-action causality through
      exact request fixtures and the live GraphQL/service boundary.
- [x] Ingest pages preserve Riela's per-page read-only state, note tags, and
      metadata through exact request, direct service, and live-server fixtures.
- [x] Page-image attachments preserve Riela ordering by using the explicit
      page note number or the one-based request index when it is absent.
- [x] Fault-injection tests cover first, middle, and final read-only restoration
      failures with and without attachment failure; every post-create response
      retains committed notebook, note, and attachment identities and readback
      state.
- [x] Notebook/note auto-action outbox rows remain ineligible until attachments,
      requested read-only restoration, and readback reach a terminal committed
      state; a blocking dispatcher test observes only finalized resources.
- [x] Attachment, read-only-restoration, and authoritative-readback partial
      failures return before deferred auto-action finalization; fault-injection
      tests observe zero eligible outbox rows and zero dispatcher invocations.
- [x] Ingest requires a caller-provided principal-scoped idempotency key,
      persists a canonical request digest and terminal result, replays lost or
      concurrent identical requests, rejects changed input under one key, and
      permits two principals to independently reuse the same key.
- [x] Pending ingest notebooks and notes are unavailable to direct reads,
      listings, search, and change feeds; terminal completion publishes one
      finalized event after reconciliation and visibility transition. Blocked-
      phase regressions exercise `getNotebook`, `getNote`, `listNotebooks`,
      `listNotes`, `searchNotes`, and `NoteChangeFeed` before terminal state.
- [x] Every lexical, fallback, filter-only, linked-graph search, long-term-memory
      association recall, and long-term-memory link-materialization query
      excludes pending notebooks before graph ranking, limit, and offset;
      regressions prove hidden hits consume no pagination slots and cannot be
      returned or linked through the memory graph.
- [x] `_kaibaNotebookIngest` is rejected from public notebook metadata through
      both AppCore and the live GraphQL `createNotebook` boundary. Only the
      package-internal pending-ingest capability may persist the marker, and a
      public-symbol-graph regression keeps that capability and its lifecycle
      APIs out of the AppCore public surface.
- [x] A terminal-completion transaction failure persists the committed
      notebook/note identities, exact terminal result, and dispatch policy;
      the same idempotency key retries only the reveal transition and then
      replays the recovered result without duplicate resources.
- [x] Page/count/number, serialized-size, attachment, notebook/page metadata,
      and source-document/page-image role validation completes before the
      durable idempotency claim. Invalid page metadata shapes and unsupported
      roles produce zero claim observations and notebooks, with the complete
      preflight note-ID set remaining unchanged. A request
      already waiting on a claim abandoned before notebook creation atomically
      reclaims it, executes once, and replays without a false timeout.
- [x] Hidden notebook/note identities are persisted atomically with creation;
      a new service process resumes the created state, reuses any matching
      committed attachments, reconciles read-only state, and reveals without
      duplicate resources. Live retries remain waiters behind one process-local
      execution owner.
- [x] Tags first created by a pending ingest are excluded from the public tag
      catalog until reveal without hiding pre-existing tags. Pending notebooks
      are also excluded from tag detail counts, tag comment projections, tag
      memo source resolution, tag memo lookup, and tag agent context, preventing
      incomplete page bodies from reaching an agent.
- [x] Pending-scope mutations emit no action history. The single
      `notebookIngested` record is committed in the same terminal transaction
      that removes the pending marker, with legacy premature records hidden
      until reveal and not duplicated.
- [x] The owning ingest invocation releases process-local execution ownership
      on every exit path. If both terminal reveal and recovery-record
      persistence fail, a same-process retry reacquires the durable `created`
      state, finalizes once, and replays without waiting for timeout or restart.
      Successful pre-create abandonment disarms deferred cleanup after its own
      release, so the exiting invocation cannot release a replacement owner;
      failed abandonment retains the deferred-release fallback.
- [x] The generic deferred-ingest auto-action policy and finalizer are
      package-internal. Creation persists an exact-note lifecycle marker;
      finalization atomically consumes it, records terminal history, enqueues
      notebook/note actions, and publishes one terminal notebook-created event.
      Public-symbol, observer, and duplicate-finalization regressions prove
      ordinary or repeated finalization cannot duplicate actions or events.
- [x] Pending duplicate requests use cancellable execution-release
      notification with bounded exponential fallback instead of 10 ms SQLite
      polling. Client timeout, disconnect, and server stop cancel the
      connection-owned route task. An atomic pre-handler gate rejects tasks
      cancelled before execution; regressions bound claim transactions, verify
      handler suppression and route-task cleanup, and preserve exact replay.

### TASK-008: Add authenticated long-term-memory GraphQL operations

**Parallelizable**: Yes after TASK-006; coordinate authoritative SDL with TASK-005

**Files**:

- `Sources/AppCore/NoteService+LongTermMemory.swift`
- `Sources/AppGraphQL/GraphQLNoteSchemaContract.swift`
- `Sources/AppGraphQL/GraphQLContractProjector.swift`
- `Sources/AppGraphQL/NoteGraphQLContracts.swift`
- `Sources/AppGraphQL/NoteGraphQLDocumentInputs.swift`
- `Sources/AppGraphQL/NoteGraphQLDocumentExecutor.swift`
- `Sources/AppGraphQL/NoteGraphQLDocumentExecutorSupport.swift`
- `Sources/KaibaClient/KaibaLongTermMemoryOperations.swift`
- `Tests/AppCoreTests/NoteLongTermMemoryTests.swift`
- `Tests/AppGraphQLTests/NoteGraphQLLongTermMemoryTests.swift`
- `Tests/AppServerTests/KaibaClientOperationAuthenticationTests.swift`
- `Tests/KaibaClientTests/KaibaLongTermMemoryOperationsTests.swift`

**Work**:

- Introduce a service authorization helper that preserves local unscoped
  operator access and permits authenticated enabled admins, while ordinary
  unauthenticated/non-admin callers fail closed.
- Add `longTermMemoryNotebook`, `appendLongTermMemory`,
  `recallLongTermMemory`, and `linkLongTermMemoryAssociations` schema DTOs and
  fields; preserve atomic append, idempotency key, tag/metadata, bounds,
  recency, and graph evidence semantics.
- Scope HTTP audit ownership to the authenticated user, preserve explicit
  caller-visible Riela attribution, reserve `client:` for verified client
  attribution, and apply the boundary consistently across mutations.
- Implement typed append/consolidate/recall wrappers and output fixtures
  matching the information consumed by Riela's memory nodes.

**Completion Criteria**:

- [x] Local operator and authenticated admin succeed; non-admin, revoked,
      disabled, missing, and ordinary unauthenticated identities receive no
      canonical-memory disclosure.
- [x] Idempotent replay returns the original ordered note identities and does
      not duplicate notes or associations.
- [x] Idempotency keys are user-principal scoped, every batch persists a
      canonical normalized-request digest, changed same-count requests return
      `invalid_request`, and concurrent identical/conflicting reuse is tested.
- [x] Default-operator retries recognize pre-principal key-only note IDs,
      validate every persisted canonical request field, and transactionally
      adopt matching legacy batches without duplication; mismatches conflict.
- [x] Recall tests cover direct/associated hits, depth/limit/recency validation,
      and complete path evidence; service, GraphQL, and live HTTP boundaries
      reject negative depth, honor zero and one, and cap above the maximum.
- [x] Typed client fixtures preserve source metadata and association results
      without importing `AppCore` IDs or services.
- [x] Period timestamps accept ISO-8601 with and without fractional seconds,
      reject malformed values rather than dropping them, and preserve accepted
      metadata through the live service boundary.
- [x] Non-finite typed recall weights fail as `invalid_request` before
      transport.
- [x] Real HTTP tests issue credentials for admin and non-admin users and prove
      the bearer-authenticated server allows or denies the same SDK operation
      without disclosing the canonical notebook on denial.
- [x] Long-term-memory append/recall validation failures return
      `invalid_request` with exact live HTTP assertions, while the shared error
      mapping retains `not_found` for missing resources.

### TASK-009: Add the schema discovery CLI without regressing document mode

**Parallelizable**: Yes after TASK-004 and TASK-005

**Files**:

- `Sources/KaibaCLIKit/GraphQLSchemaCommand.swift`
- `Sources/AppCLI/main.swift`
- `Sources/AppCore/Command.swift`
- `Tests/KaibaCLIKitTests/GraphQLSchemaCommandTests.swift`
- `Tests/AppServerTests/GraphQLSchemaCLIIntegrationTests.swift`

**Work**:

- Recognize `schema` only as the first token after `graphql`; route every other
  invocation through the unchanged `GraphQLCommand.parse/run` path.
- Parse required endpoint and mutually exclusive auth flags plus filter,
  output, `--allow-remote-unauthenticated`, and `--allow-insecure-http`.
  Validate env names and compile regex before network activity; resolve the
  token just in time.
- Render stable success and failure text/JSON to the correct stream with
  stable exit codes, redacted endpoint, and next action.
- Exercise the real server boundary for auth and introspection; use injected
  transports for parser/output/error fixtures.

**Completion Criteria**:

- [x] Matrix tests cover missing/conflicting flags and values, invalid env name,
      unset/empty env, invalid regex, invalid endpoint, remote HTTP policy,
      non-loopback unauthenticated policy,
      full/filtered/empty results, 401/403, connection failure, malformed and
      disabled introspection.
- [x] Invalid regex and missing credential make zero requests.
- [x] Golden text and JSON contain sorted stable fields and no bearer value,
      raw response body, query string, or URL user info; mock-transport schema
      metadata sentinels remain absent from SDK values, renderers, stdout, and
      stderr. Active tokens embedded in accepted endpoint paths remain absent
      from success and failure output regardless of equivalent percent encoding.
- [x] Runtime auth, connection, HTTP, response-envelope, and schema failures use
      exact local per-code message/next-action copy in both text and JSON.
- [x] Golden JSON always contains `filter` (`null` when absent), and exit-code
      tests prove 0 for success, 2 for usage/configuration errors, and 1 for
      endpoint/runtime/schema failures.
- [x] The original filter drives selection, but a filter changed by active
      authentication redaction is published as one opaque marker; stdout,
      stderr, result values, reflection, and dumps retain neither the complete
      credential nor a co-located substring.
- [x] Executable usage failures preserve a valid `--output json` request for
      unknown, duplicate, missing, and conflicting arguments; runtime failures
      render the validated normalized endpoint. Parse-error endpoint diagnostics
      redact every resolved valid `--api-key-env` value, including duplicate
      credential options, and never echo unknown or positional argument values.
      A missing endpoint remains `invalid_usage`; a present malformed endpoint
      is `invalid_endpoint` with exit 2 and zero client creation.
- [x] All type/member/reference identifiers satisfy GraphQL Name syntax before
      publication; malformed introspection names fail as `schema_unavailable`
      without reaching text rendering.
- [x] Missing credentials render the credential-specific recovery action
      exactly in both text and structured JSON diagnostics.
- [x] Existing document, file, stdin, variables, operation, local-store, and
      endpoint command forms pass unchanged.
- [x] Executable routing handles `graphql schema` before note-root/Kaiba
      configuration loading; an invalid ambient `KAIBA_CONFIG_PATH` cannot
      preempt schema argument validation. `graphql` must itself be the command
      token, and missing/duplicate global configuration options retain valid
      JSON failure rendering.
- [x] Top-level command/help resolution consumes recognized option values;
      schema filters equal to `serve`, `-h`, or other routing tokens remain
      values and cannot select another command or global help.

### TASK-010: Refresh user-facing documentation

**Parallelizable**: No; depends on TASK-006 through TASK-009

**Files**:

- `README.md`
- `design-docs/specs/command.md`
- `design-docs/specs/kaiba-note.md` only if needed for the additive fields
- `design-docs/specs/kaiba-client-sdk.md` only for implementation-confirmed
  corrections; do not reopen accepted scope
- `impl-plans/completed/kaiba-client-sdk.md`

**Work**:

- Document SwiftPM product/import and authenticated/explicit-unauthenticated
  examples without literal credentials.
- Document readiness, typed operation families, schema command syntax, filter
  candidate/closure semantics, output contracts, errors, and remote HTTP risk.
- Keep local `kaiba graphql` examples and behavior visible.
- Mark completed tasks and record actual verification evidence and any low
  residual risks in this plan's progress log.

**Completion Criteria**:

- [x] README and command spec agree with implementation and `--help`.
- [x] No example persists or prints a token; examples use environment-variable
      names and placeholders only.
- [x] Documentation names the no-store/no-fallback boundary and current upload
      body limit.

### TASK-011: Run focused and full verification

**Parallelizable**: No; final gate

**Commands**:

```bash
cd /Users/taco/gits/tacogips/kaiba
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift package describe --type json
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter KaibaClientTests
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter KaibaCLIKitTests
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'GraphQLIntrospection|GraphQLSchemaCLI|NoteGraphQLClientBoundary|NoteGraphQLLongTermMemory'
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'httpClient|endpointURLAppendsGraphQL'
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint --strict --no-cache
{ git diff --name-only -- '*.swift'; git ls-files --others --exclude-standard -- '*.swift' | rg -v '^\.riela/'; } \
  | sort -u \
  | while IFS= read -r file; do lines=$(wc -l < "$file"); \
      if [ "$lines" -gt 1000 ]; then printf '%s %s\n' "$lines" "$file"; fi; \
    done
rg -n 'case "[^"]+"|== "[^"]+"|!= "[^"]+"|status: String|type: String|kind: String|mode: String|decision: String|provider: String' Sources/KaibaClient Sources/KaibaCLIKit --glob '*.swift'
git diff --check
git status --short
```

If dependency preparation requires the repository wrapper, run the equivalent
`mise run build`, `mise run test`, and `mise run lint` and record both the
reason and exact results. Web/Tauri gates are not required unless implementation
touches `web/` or `web/src-tauri/`; if it does, scope has expanded and requires
review before proceeding.

**Completion Criteria**:

- [x] Focused SDK, CLI, introspection, server-boundary, additive operation, and
      legacy client tests pass.
- [x] Full build and test pass with zero failures.
- [x] SwiftLint has no feature-caused finding; three baseline errors are
      recorded with file/line evidence and not silently ignored.
- [x] New client/CLI files are below 1,000 lines and the enum-candidate review
      leaves only intentional boundary/free-form strings.
- [x] `git diff --check` passes and `git status --short` contains only intended
      files plus preserved pre-existing `.riela/` state.
- [x] No commit or push occurs because authorization is false.

## Review Checklists

### Design-to-plan consistency

- [x] Standalone dependency direction and no-fallback rule are represented.
- [x] Endpoint normalization, explicit auth, insecure transport, redirect, error,
      redaction, readiness, and token-persistence rules are tasks and tests.
- [x] Every typed operation family and required additive server field is owned.
- [x] Introspection, regex seed/closure behavior, deterministic outputs, and
      compatibility have implementation and verification coverage.

### Completion and progress discipline

- [x] Mark a checkbox complete only with matching code/tests or evidence.
- [x] Record deviations as design defects or plan-only defects before changing
      scope.
- [x] Keep exact commands, pass/fail counts, skipped gates, and residual risks
      in the progress log.
- [x] Stop before commit/push and return the exact changed-file list.

## Progress Log

- 2026-09-04: Plan created from the accepted
  `design-docs/specs/kaiba-client-sdk.md`. No implementation, commit, or push
  performed in the feature-local planning worker.
- 2026-09-04: Implemented the standalone `KaibaClient` and internal
  `KaibaCLIKit` targets, bounded redirect-refusing HTTP transport, endpoint and
  authentication policy, arbitrary typed/untyped execution, readiness,
  schema parsing/introspection/filtering/rendering, and typed note, notebook,
  tag, attachment, comment, ingest/document, conversation, and admin-gated
  long-term-memory conveniences. Added authenticated server introspection and
  the missing additive GraphQL fields without a local-store fallback.
- 2026-09-04: Added focused SDK, schema, CLI, executor, and server authorization
  tests. `swift package describe --type json` confirmed `KaibaClient` has no
  target dependency. `swift build` passed. The final pre-plan-update full
  `swift test` ran 769 XCTest tests and 54 Swift Testing tests with zero
  failures. Final post-update verification then ran 769 XCTest tests and 56
  Swift Testing tests with zero failures.
- 2026-09-04: Strict SwiftLint reported no feature-caused finding and retained
  exactly three pre-existing errors:
  `Sources/AppCore/NoteService.swift:654` (`large_tuple`),
  `Sources/AppCore/ResendGatewayCLIMailSender.swift:75` (`large_tuple`), and
  `Tests/AppCoreTests/AITranslationTests.swift:71` (`type_body_length`). New
  client/CLI Swift files remain below 1,000 lines. Security audits found no
  client/CLI store coupling or credential persistence. `git diff --check`
  passed; `.riela/` remained preserved; no commit or push was performed.
- 2026-09-04: Plan deviation recorded: the new coverage is consolidated into
  responsibility-based test files rather than one fixture file per operation,
  and no `design-docs/specs/kaiba-note.md` change was necessary because the
  additive wire contract is documented by the accepted SDK design and the
  authoritative GraphQL schema.
- 2026-09-04: Completed the ingest attachment contract after the initial gate:
  requests now prevalidate bounded inline source-document/page-image data,
  create pages writable for attachment, restore read-only state, and return
  committed notebook/note/attachment identities on post-create failure for
  reconciliation. The focused ingest boundary test covers both attachment
  scopes.
- 2026-09-04: The implementation self-review rejected an unrelated PageRank
  production/test adjustment; both files were restored to the pre-issue state,
  leaving the implementation scoped to the accepted SDK/schema work.
- 2026-09-04: Added
  `Tests/AppServerTests/KaibaClientServerIntegrationTests.swift`; a real
  loopback `KaibaServerRuntime` accepted typed SDK create/list operations and
  schema discovery over HTTP with no in-process client fallback. Final full
  verification passed 770 XCTest tests and 56 Swift Testing tests with zero
  failures.
- 2026-09-04: Revision pass resolved `SELF-IMPL-001` with syntax-aware selected-
  operation introspection parsing/projection and adversarial unknown, malformed,
  comment/string, mixed-field, named-operation, fragment, and `__type` tests.
  Resolved `SELF-IMPL-002` by revalidating administrator state inside each
  long-term-memory transaction while preserving authenticated user and
  `client:<id>` audit attribution; live HTTP coverage includes admin,
  non-admin, revoked, disabled, missing, and unauthenticated callers.
- 2026-09-04: Resolved `SELF-IMPL-003` by completing the 43 remaining plan
  criteria. Coverage now includes live redirect refusal/stream cancellation,
  exact transport bounds, all typed-operation documents/variables plus shared
  success/rejection/GraphQL/decode matrices, schema kinds/descriptions/
  deprecations/wrapper bounds/canonicalization, ingest rejection/rollback/
  partial reconciliation, CLI parser/output/error/redaction/routing matrices,
  and long-term-memory idempotency/source/association behavior.
- 2026-09-04: Final revision gate passed 779 XCTest tests and 77 Swift Testing
  tests with zero failures. The long-term-memory visibility fixture now keeps
  its visible source text distinct from the internal-memory search query so it
  verifies exclusion rather than relaxed-search matching. PageRank production
  behavior remains restored. Strict SwiftLint reports only the same three
  repository-baseline findings; all feature-caused findings were fixed. No
  commit or push was performed.
- 2026-09-04: Resolved `SELF-IMPL-005` by moving the root-field inventory test
  into `Tests/AppGraphQLTests/NoteGraphQLSchemaInventoryTests.swift`.
  `Tests/AppGraphQLTests/NoteGraphQLTests.swift` is now 980 lines and the new
  focused file is 92 lines. Replaced the narrow client/CLI size command with an
  audit of every tracked and untracked modified Swift file; it reports no file
  above 1,000 lines.
- 2026-09-04: Test-integrity revision resolved `TEST-INTEGRITY-001` by rejecting
  ports outside `1...65535` and percent-decoded path control characters during
  endpoint construction. SDK and CLI regressions cover ports `0`/`65536` and
  encoded NUL/newline paths, assert `invalid_endpoint`, CLI exit `2`, and zero
  transport/client calls.
- 2026-09-04: Test-integrity revision resolved `TEST-INTEGRITY-002` by replacing
  substring-driven response synthesis with exact canonical document and exact
  variable fixtures for every public typed convenience. Each method now proves
  nontrivial decoded success and control-plane rejection values and independently
  propagates GraphQL and decode failures. The stronger nonempty notebook-file
  fixture exposed that `NotebookFileAttachment` has no `position` field, so the
  shared client model now represents `position` as optional.
- 2026-09-04: Test-integrity revision resolved `TEST-INTEGRITY-003`: live HTTP
  tests bind OS-assigned ephemeral ports and await runtime shutdown on success
  and failure paths. Focused endpoint, CLI, typed-contract, and live-server tests
  passed with zero failures; no fixed `8898`/`8899` binding remains.
- 2026-09-04: Post-revision verification passed 779 XCTest tests and 80 Swift
  Testing tests with zero failures. One preceding full-suite attempt reproduced
  the pre-existing exact-floating-point PageRank flake after the accepted scope
  review required restoring that unrelated production file; the immediate full
  retry passed without changes. Strict SwiftLint reports only the same three
  repository-baseline findings. The all-modified Swift-file size audit, plan
  completion audit, `git diff --check`, and status review passed. No commit or
  push was performed.
- 2026-09-04: Step 7 reopened the affected redaction, schema validation/
  rendering, typed-note parity, CLI failure-mode, and stable-order completion
  criteria. The revision added full Riela list/search filters with exact request
  and decoded success/rejection/error fixtures plus live-server parity; strict
  kind-specific introspection validation; JSON-compatible control escaping;
  extension-code credential redaction; sanitized GraphQL locations; structured JSON invalid-
  regex failures before client construction; and the documented canonical type
  order. All reopened criteria are rechecked.
- 2026-09-04: The live Riela filter parity case also exposed a missing
  `termCoverage` selection entry in the document executor inventory. The entry
  now matches the authoritative schema and DTO, and the filtered list/search
  operations pass through the real HTTP server boundary.
- 2026-09-04: Step 7 revision verification passed the focused suite with 2
  XCTest and 46 Swift Testing tests, then the full suite with 779 XCTest and 84
  Swift Testing tests, all with zero failures. `swift build`, the all-modified
  Swift-file size audit, completion audit, `git diff --check`, and status review
  passed. Strict SwiftLint retains only the same three repository-baseline
  findings. No TypeScript files changed; no commit or push was performed.
- 2026-09-04: The second Step 7 revision reopened executable routing, file DTO,
  operation-status, bearer-reflection, URL-user-info redaction, and schema-text
  relationship criteria. The revision routes schema discovery before local
  configuration loading; restores all Riela file storage attributes and derived
  S3 URL parity; uses `not_found`/`invalid_request`; redacts `Mirror`, `dump`,
  and URL credentials; and renders sorted object/interface `implements` clauses.
  Exact fixtures, real-server responses, live file payload parity, text goldens,
  and the invalid-ambient-`KAIBA_CONFIG_PATH` executable regression all pass.
- 2026-09-04: Final revision verification passed the focused suite with 11
  XCTest and 50 Swift Testing tests and the full suite with 779 XCTest and 88
  Swift Testing tests, all with zero failures. Package description, build,
  all-modified Swift-file size, zero-unchecked-criteria, TypeScript-change,
  wire-spelling, diff, and status audits passed. Strict SwiftLint reports only
  the same three repository-baseline findings. No commit or push was performed.
- 2026-09-04: The third Step 7 revision resolved `STEP7-REVIEW-014` by
  preserving a valid JSON output request across unknown, duplicate, missing,
  and conflicting executable arguments. It resolved `STEP7-REVIEW-015` by
  validating all type, field, argument, input, enum, interface, possible-type,
  and named-reference identifiers against GraphQL Name syntax before schema
  publication. It resolved `STEP7-REVIEW-016` by retaining the validated
  normalized endpoint for runtime failure rendering while safely redacting
  unvalidated endpoint input.
- 2026-09-04: Third-revision verification passed the focused suite with 11
  XCTest and 32 Swift Testing tests and the full suite with 779 XCTest and 94
  Swift Testing tests, all with zero failures. Package description, build,
  all-modified Swift-file size, zero-unchecked-criteria, TypeScript-change,
  diff, and status audits passed. Strict SwiftLint reports only the same three
  repository-baseline findings. No commit or push was performed.
- 2026-09-04: The fourth Step 7 revision (`comm-000028`) reopened TASK-006,
  TASK-007, and TASK-008. Typed note, notebook, ingest/document, and
  conversation mutations now accept a distinct optional `KaibaAutoActionID`
  and preserve it through exact request fixtures and the live service boundary;
  the live regression proves workflow-originated writes do not redispatch auto
  actions.
- 2026-09-04: Long-term-memory period conversion is now throwing, accepts
  ISO-8601 values with or without fractional seconds, preserves accepted
  metadata, and rejects malformed values without creating notes. Arbitrary and
  typed recall request-encoding failures for NaN and infinities now map to
  `invalid_request` before transport.
- 2026-09-04: Fourth-revision verification passed the focused suite with 11
  XCTest and 41 Swift Testing tests and the full rerun with 779 XCTest and 95
  Swift Testing tests, all with zero failures. Package description, build,
  all-modified Swift-file size, zero-unchecked-criteria, TypeScript-change,
  diff, and status audits passed. Strict SwiftLint reports only the same three
  repository-baseline findings. No commit or push was performed.
- 2026-09-04: The fifth Step 7 revision (`comm-000032`) reopened and rechecked
  TASK-002 and TASK-003 redaction/envelope criteria. Typed-decoding coding keys
  and GraphQL string path components now use the active-token and
  Authorization-pattern scrubber. GraphQL paths accept only strings and
  integers; nested arrays/objects, booleans, nulls, and non-integer numbers fail
  as `invalid_response`. Injected-transport regressions prove the exact bearer
  token is absent from associated errors, descriptions, reflection, and dumps.
- 2026-09-04: Fifth-revision verification passed 43 focused Swift Testing tests
  and the full suite with 779 XCTest and 97 Swift Testing tests, all with zero
  failures. Package description, build, all-modified Swift-file size,
  zero-unchecked-criteria, TypeScript-change, diff, and status audits passed.
  Strict SwiftLint reports only the same three repository-baseline findings. No
  commit or push was performed.
- 2026-09-04: The sixth Step 7 revision (`comm-000036`) reopened and rechecked
  TASK-004 and TASK-009 schema-validation and executable-routing criteria.
  `KaibaGraphQLSchema.init(from:)` now validates and canonicalizes decoded
  values, rejects duplicate names, malformed wrappers/kinds, invalid GraphQL
  identifiers, kind/member mismatches, dangling references, and declared
  reference-kind conflicts. Schema selection and validation no longer use
  trapping duplicate-key dictionary initialization.
- 2026-09-04: Executable routing now validates `graphql` as the command token,
  handles complete global-option pairs deterministically, preserves structured
  JSON for missing/duplicate `--config` and `--note-root`, and rejects
  arbitrary-value routing. Sixth-revision verification passed the focused suite
  with 16 XCTest and 63 Swift Testing tests and the full suite with 779 XCTest
  and 101 Swift Testing tests, all with zero failures. Package description,
  build, all-modified Swift-file size, zero-unchecked-criteria, TypeScript-change,
  duplicate-key, diff, and status audits passed. Strict SwiftLint reports only
  the same three repository-baseline findings. No commit or push was performed.
- 2026-09-04: The Step 6 self-review revision (`comm-000038`) reopened and
  rechecked TASK-004. `SELF-IMPL-006` is resolved: decoded wrapper references
  reject non-null names, decoded named references reject non-null `ofType`, and
  duplicate interface/possible-type relationships fail before implementor
  normalization. Validation moved to
  `Sources/KaibaClient/KaibaGraphQLSchemaValidation.swift` to keep each modified
  Swift file below 1,000 lines.
- 2026-09-04: Seventh-revision verification passed 17 focused schema tests, the
  complete focused matrix with 16 XCTest and 63 Swift Testing tests, and an
  unchanged full-suite retry with 779 XCTest and 101 Swift Testing tests. The
  initial full run reproduced the pre-existing PageRank exact-floating-point
  flake. Package description, build, all-modified Swift-file size,
  zero-unchecked-criteria, TypeScript-change, diff, and status audits passed.
  Strict SwiftLint reports only the same three repository-baseline findings. No
  commit or push was performed.
- 2026-09-04: The eighth Step 7 revision (`comm-000042`) reopened and rechecked
  TASK-007. `GraphQLRequestLimits.maximumSerializedBodyBytes` is now the shared
  2 MiB ceiling used by `KaibaHTTPRequestParser` and direct ingest validation.
  `ingestNotebookPages` rejects an encoded aggregate above that ceiling before
  attachment decoding or mutation, and the direct boundary regression asserts
  `invalid_request` plus unchanged notebook and note counts.
- 2026-09-04: Eighth-revision verification passed 4 direct boundary XCTest
  tests, the complete focused matrix with 16 XCTest and 63 Swift Testing tests,
  and the full suite with 779 XCTest and 101 Swift Testing tests. Package
  description, build, all-modified Swift-file size, zero-unchecked-criteria,
  TypeScript-change, diff, and status audits passed. Strict SwiftLint reports
  only the three unchanged repository-baseline findings. No commit or push was
  performed.
- 2026-09-04: The ninth Step 7 revision (`comm-000046`) reopened and rechecked
  TASK-002, TASK-004, and TASK-009. Shared `KaibaRedaction` now sanitizes
  schema descriptions, deprecation reasons, and `schema_unavailable` reasons;
  credential-tainted identifiers are rejected before publication. Mock-
  transport regressions cover returned schema values, text/JSON renderers,
  stdout/stderr, descriptions, reflection, and dumps. Missing credentials now
  use the exact credential-specific next action in text and JSON.
- 2026-09-04: Ninth-revision verification passed the focused schema/CLI suite
  with 40 Swift Testing tests, the complete focused matrix with 16 XCTest and
  67 Swift Testing tests, and the full suite with 779 XCTest and 105 Swift
  Testing tests. Package description, build, all-modified Swift-file size,
  zero-unchecked-criteria, TypeScript-change, diff, status, and exact executable
  missing-credential checks passed. Strict SwiftLint reports only the three
  unchanged repository-baseline findings. No commit or push was performed.
- 2026-09-04: The adversarial revision (`comm-000051`) reopened and rechecked
  TASK-002, TASK-003, and TASK-009. Authentication-aware endpoint diagnostics
  now redact active tokens from readiness and every schema-command endpoint
  field. `KaibaClientError` reflection and dumps expose only opaque code
  metadata while programmatic GraphQL partial data remains available. The
  URLSession transport now enforces the configured timeout as an absolute
  request/resource deadline with explicit cancellation, and a trickling
  response regression proves progress cannot extend it.
- 2026-09-04: Adversarial-revision verification passed the focused client/CLI
  matrix with 70 Swift Testing tests and the unchanged full-suite retry with
  779 XCTest and 108 Swift Testing tests. The preceding count-only full-suite
  run reproduced the documented unrelated PageRank exact-floating-point flake;
  the immediate retry passed without changes. Package description, build,
  all-modified Swift-file size, zero-unchecked-criteria, TypeScript-change,
  diff, and status audits passed. Strict SwiftLint reports only the three
  unchanged repository-baseline findings. No commit or push was performed.
- 2026-09-04: The Step 6 self-review revision (`comm-000053`) reopened and
  rechecked TASK-002, TASK-003, and TASK-009. `SELF-IMPL-007` is resolved by
  detecting bearer values in the decoded endpoint path before diagnostic
  rendering. Mixed-case percent escapes and optional percent encoding of
  unreserved token characters now produce the same redacted endpoint;
  readiness and schema-command regressions cover both forms.
- 2026-09-04: Self-review-revision verification passed the focused client/CLI
  matrix with 70 Swift Testing tests and the full suite with 779 XCTest and 108
  Swift Testing tests. Package description, build, all-modified Swift-file
  size, zero-unchecked-criteria, TypeScript-change, diff, status, and both exact
  executable encoding regressions passed. Strict SwiftLint reports only the
  three unchanged repository-baseline findings. No commit or push was
  performed.
- 2026-09-04: The Step 7 revision (`comm-000057`) reopened and rechecked
  TASK-002 and TASK-009. `KaibaClient.init` now revalidates configurations
  mutated after their throwing initializer, covering zero, negative, NaN, and
  infinite timeouts plus non-positive request/response limits. Parse-error
  endpoint rendering now applies every supplied valid credential-environment
  value and fails closed for malformed credential options; the duplicate
  `--api-key-env` regression proves the second token cannot be emitted.
- 2026-09-04: Latest-revision verification passed the focused matrix with 16
  XCTest and 72 Swift Testing tests and the full suite with 779 XCTest and 110
  Swift Testing tests. Package description, build, reviewer reproduction,
  all-modified Swift-file size, zero-unchecked-criteria, TypeScript-change,
  whitespace, diff, and status audits passed. Strict SwiftLint reports only the
  three unchanged repository-baseline findings. No commit or push was
  performed.
- 2026-09-04: The Step 6 self-review revision (`comm-000059`) reopened and
  rechecked TASK-002 and TASK-009. Unknown and positional argument values are
  no longer echoed by schema-command parse diagnostics; text and JSON
  regressions prove an active credential remains absent when supplied as either
  a positional value or an option-shaped unknown value.
- 2026-09-04: Latest self-review-revision verification passed the focused
  matrix with 16 XCTest and 73 Swift Testing tests and the unchanged full-suite
  retry with 779 XCTest and 111 Swift Testing tests. Package description,
  build, exact text/JSON reproductions, all-modified Swift-file size,
  zero-unchecked-criteria, TypeScript-change, diff, and status audits passed.
  Strict SwiftLint reports only the three unchanged repository-baseline
  findings. No commit or push was performed.
- 2026-09-04: The Step 7 revision (`comm-000063`) reopened and rechecked
  TASK-002 and TASK-006. Every typed operation result now passes its control-
  plane diagnostics through the active authentication redactor after decoding
  and before public return. A focused regression covers direct, operation,
  value, and long-term-memory append payload shapes with active bearer,
  Authorization-like, URL-user-information, and control-character content.
- 2026-09-04: Latest-revision verification passed the focused client/server
  matrix with 2 XCTest and 50 Swift Testing tests, and the full suite passed on
  an unchanged retry. Package description, build, all-modified Swift-file
  size, zero-unchecked-criteria, TypeScript-change, diff, and status audits
  passed. Strict SwiftLint reports only the three unchanged repository-
  baseline findings. No commit or push was performed.
- 2026-09-04: The Step 7 revision (`comm-000067`) reopened and rechecked
  TASK-006, TASK-007, and TASK-009. Schema CLI runtime failures now use exact
  local per-code message/next-action copy; ingest pages preserve Riela read-only,
  tag, and metadata fields through client, SDL, executor, service, and live HTTP
  boundaries; note comments preserve optional author attribution.
- 2026-09-04: Revision verification passed package description, build, the
  focused schema/ingest/comment matrix with 12 XCTest and 28 Swift Testing
  tests, and the full suite on an unchanged retry with 779 XCTest and 112 Swift
  Testing tests. Strict SwiftLint reports only the three unchanged repository
  baseline findings. File-size, plan, TypeScript, diff, and status audits
  passed. No commit or push was performed.
- 2026-09-04: The Step 7 revision (`comm-000071`) reopened and rechecked
  TASK-006 and TASK-008. Bearer-authenticated note creation, tag assignment,
  comments, and conversations now preserve explicit Riela attribution while
  `client:` remains a server-reserved verified identity namespace. Long-term-
  memory validation and missing-resource failures now reuse the shared stable
  `invalid_request` and `not_found` status mapping.
- 2026-09-04: Latest-revision verification passed build, the requested focused
  matrix with 6 XCTest and 28 Swift Testing tests, and the final unchanged full
  suite with 780 XCTest and 112 Swift Testing tests. Strict SwiftLint reports
  only the three unchanged repository-baseline findings. File-size, plan,
  TypeScript-change, diff, and status audits passed. No commit or push was
  performed.
- 2026-09-04: The Step 7 revision (`comm-000075`) reopened and rechecked
  TASK-002 and TASK-009. Endpoint validation now uses the explicit authority
  port range as well as its parsed integer, so overflowing ports cannot bypass
  validation when Foundation returns a nil integer. Schema-command parsing now
  distinguishes a missing `--endpoint` (`invalid_usage`) from a present
  unparseable endpoint (`invalid_endpoint`). SDK and structured CLI regressions
  cover overflowing and alphabetic ports with zero transport/client creation.
- 2026-09-04: Latest-revision verification passed package description, build,
  41 focused Swift Testing tests, and the full suite with zero failures. Exact
  reviewer CLI reproductions now return structured `invalid_endpoint` and exit
  2. Strict SwiftLint reports only the three unchanged repository-baseline
  findings. File-size, plan, TypeScript-change, diff, and status audits passed.
  No commit or push was performed.
- 2026-09-04: The self-review revision (`comm-000077`) reopened and rechecked
  TASK-002 and TASK-009. Raw authority parsing is IPv6-safe and rejects an
  explicitly empty port before Foundation can normalize it away. SDK and
  structured CLI regressions cover hostname and IPv6 empty ports with zero
  transport/client creation.
- 2026-09-04: Self-review revision verification passed package description,
  build, 41 focused Swift Testing tests, the full suite with 780 XCTest and 112
  Swift Testing tests, exact hostname/IPv6 CLI reproductions, file-size, plan,
  TypeScript-change, diff, and status audits. Strict SwiftLint reports only the
  three unchanged repository-baseline findings. No commit or push was performed.
- 2026-09-04: The adversarial-review revision (`comm-000082`) reopened and
  rechecked TASK-007 and TASK-008. Ingest now keeps attachment and read-only
  restoration failures inside one post-create partial-failure state machine,
  continues restoration after individual failures, and reads every committed
  note back without losing notebook, note, or attachment identities. Fault
  injection covers first, middle, and final restoration failures both with and
  without a partially committed attachment sequence.
- 2026-09-04: Long-term-memory idempotency is now scoped by acting user and
  backed by a persisted SHA-256 digest of canonical normalized entries and
  effective attribution. Exact canonical retries replay, while changed body,
  tags, period, source IDs, related IDs, metadata, or attribution conflict.
  Tests cover independent administrator namespaces plus concurrent identical
  and conflicting reuse; live HTTP maps a changed request to `invalid_request`.
- 2026-09-04: Revision verification passed package description, build, the
  focused matrix with 23 XCTest and 4 Swift Testing tests, ten consecutive
  focused stress runs, and the final full suite with 783 XCTest and 112 Swift
  Testing tests. One earlier count-only full run reported one XCTest failure
  without retaining its identity; the unchanged retry passed. File-size,
  zero-unchecked-criteria, TypeScript-change, diff, and status audits passed;
  the largest modified Swift file is 991 lines. Strict SwiftLint reports only
  the three unchanged repository-baseline findings. No commit or push was
  performed.
- 2026-09-04: The adversarial-review revision (`comm-000087`) reopened and
  rechecked TASK-002, TASK-005, TASK-008, and TASK-009. Default-operator
  idempotency now recognizes and transactionally adopts fully matching legacy
  key-only batches; introspection enforces selection, projection-complexity,
  and serialized-response budgets; custom endpoint descriptions are opaque in
  description/reflection/dump; and command/help routing consumes option values
  before interpreting tokens.
- 2026-09-04: Revision verification passed package description, build, 24
  focused XCTest and 34 focused Swift Testing tests, exact `serve`/`-h` filter
  executable reproductions, and the complete suite with 786 XCTest and 114
  Swift Testing tests. File-size, zero-unchecked-criteria, TypeScript-change,
  diff, and status audits passed; the largest
  modified Swift file remains 991 lines. Strict SwiftLint reports only the
  three unchanged repository-baseline findings. No commit or push was
  performed.
- 2026-09-04: The Step 7 revision (`comm-000091`) reopened and rechecked
  TASK-009 and TASK-011. The CLI now applies the caller's original schema
  filter internally but replaces a credential-bearing published filter with
  one opaque marker. Direct-result and reflection/dump regressions prove the
  active token and a co-located token substring are absent.
- 2026-09-04: Revision verification passed package description, build, all 26
  schema-command tests, and the complete suite with 786 XCTest and 115 Swift
  Testing tests. File-size, zero-unchecked-criteria, TypeScript-change, diff,
  and status audits passed; strict SwiftLint reports only the three unchanged
  repository-baseline findings. No commit or push was performed.
- 2026-09-05: The adversarial-review revision (`comm-000096`) reopened and
  rechecked TASK-002, TASK-007, TASK-008, and TASK-011. Multi-stage ingest now
  defers durable auto-action eligibility until attachments, read-only
  reconciliation, and readback are terminal. Association depth rejects
  negatives, honors zero/one, and caps above five. Every custom endpoint path
  is opaque in published diagnostics independently of bearer matching.
- 2026-09-05: Revision verification passed package description, build, the
  focused matrix with 27 XCTest and 46 Swift Testing tests, the final unchanged
  full-suite retry with 789 XCTest and 117 Swift Testing tests, and the exact
  custom-path reviewer reproduction. File-size, zero-unchecked-criteria,
  TypeScript-change, deleted-file, diff, and status audits passed; the largest
  modified Swift file is 991 lines. Strict SwiftLint reports only three
  unchanged repository-baseline findings. No commit or push was performed.
- 2026-09-05: The latest Step 6 rerun re-audited all ten supplied mid-severity
  findings against TASK-002, TASK-004, TASK-006, TASK-007, TASK-008, TASK-009,
  and TASK-011. The remaining public-surface defect is resolved by replacing
  `KaibaEndpoint.url` with a module-internal `transportURL`; a source-contract
  regression and the emitted public symbol graph prove callers cannot recover
  or serialize the complete custom path. Existing focused regressions confirm
  URL-user-info redaction, implements clauses, comment author attribution,
  invalid/empty ports, option-aware CLI routing, finalized ingest dispatch,
  association-depth bounds, and opaque custom-path diagnostics.
- 2026-09-05: Latest rerun verification passed the focused matrix with 25
  XCTest and 80 Swift Testing tests, `mise run build`, and the final unchanged
  full suite with 789 XCTest and 118 Swift Testing tests. Two preceding full
  attempts each reported one XCTest failure before the unchanged final pass.
  Strict SwiftLint reports only the same three repository-baseline findings.
  Package dependency, public-symbol-graph, file-size, zero-unchecked-criteria,
  TypeScript-change, whitespace, diff, and status audits passed. No commit or
  push was performed.
- 2026-09-05: The Step 6 self-review revision (`comm-000102`) reopened and
  rechecked TASK-007. Ingest now returns its committed partial-failure evidence
  before deferred auto-action finalization whenever attachment handling,
  requested read-only restoration, or authoritative readback fails. Dedicated
  fault-injection tests prove those paths create no eligible outbox rows and
  invoke no dispatcher.
- 2026-09-05: Self-review revision verification passed the requested focused
  matrix with 9 XCTest tests, `mise run build`, and an unchanged full-suite
  retry with 791 XCTest and 118 Swift Testing tests. The preceding full run hit
  the documented unidentified XCTest flake. Strict SwiftLint reports only the
  same three repository-baseline findings. File-size, zero-unchecked-criteria,
  TypeScript-change, whitespace, diff, and status audits passed. No commit or
  push was performed.
- 2026-09-05: The Step 7 adversarial-review revision (`comm-000107`) reopened
  and rechecked TASK-002 and TASK-009. Authentication-independent fallback
  endpoint construction now makes every custom path opaque before regex
  compilation or credential lookup, covering missing-credential and invalid-
  regex failures without relying on successful bearer construction.
- 2026-09-05: Revision verification passed 81 focused Swift Testing tests, both
  exact reviewer CLI reproductions, and `mise run build`. The unmodified full
  suite passed 790 XCTest tests after excluding the identified baseline
  floating-point exact-equality failure in `NoteRetrievalFusionTests`, plus all
  119 Swift Testing tests. Strict SwiftLint reports only the same three
  repository-baseline findings. File-size, zero-unchecked-criteria,
  TypeScript-change, whitespace, diff, and status audits passed. No commit or
  push was performed.
- 2026-09-05: The Step 7 review revision (`comm-000111`) reopened TASK-002,
  TASK-007, and TASK-011. Page-image ingest now persists the explicit page note
  number or one-based request index as attachment position, with direct and
  live HTTP boundary assertions. The brittle endpoint source-text test was
  replaced by a generated public-symbol-graph regression.
- 2026-09-05: Revision verification passed the requested 7-test XCTest matrix,
  the generated public-symbol-graph test, and `mise run build`. The full suite
  passed 790 XCTest tests after excluding the reproduced unchanged exact-
  floating-point baseline failure in `NoteRetrievalFusionTests`, plus all 119
  Swift Testing tests. Strict SwiftLint reports only the same three repository-
  baseline findings. Package-description, file-size, zero-unchecked-criteria,
  TypeScript-change, whitespace, diff, and status audits passed. No commit or
  push was performed.
- 2026-09-05: The Step 7 adversarial-review revision (`comm-000116`) reopened
  TASK-002, TASK-003, and TASK-011. Client configuration and direct URLSession
  transport now reject timeouts above 24 hours before `Duration` conversion;
  execution preserves `CancellationError` across native and cancelled-URL
  transport failures; and public HTTP request/response reflection is opaque to
  bearer values, endpoint paths, and bodies.
- 2026-09-05: Revision verification passed 56 focused Swift Testing tests, the
  71-XCTest/84-Swift-Testing reviewer matrix, and `mise run build`. The full
  suite passed 790 XCTest tests after excluding the reproduced unchanged exact-
  floating-point baseline failure in `NoteRetrievalFusionTests`, plus all 122
  Swift Testing tests. Strict SwiftLint reports only the same three repository-
  baseline findings. Package-description, file-size, zero-unchecked-criteria,
  TypeScript-change, deletion, whitespace, and diff audits passed. No commit or
  push was performed; the untracked `.riela` directory remains untouched.
- 2026-09-05: The Step 6 self-review revision (`comm-000118`) reopened and
  rechecked TASK-003. `probeReadiness` is now throwing and preserves structured
  cancellation for both native `CancellationError` and cancellation-originated
  `URLError.cancelled`; SDK callers and documentation use `try await`.
- 2026-09-05: Self-review revision verification passed the requested focused
  matrix with 57 Swift Testing tests and `mise run build`. The full suite passed
  790 XCTest tests after excluding the reproduced unchanged exact-floating-
  point baseline failure in `NoteRetrievalFusionTests`, plus all 123 Swift
  Testing tests. Strict SwiftLint reports only the same three repository-
  baseline findings. Package-description, file-size, zero-unchecked-criteria,
  TypeScript-change, deletion, whitespace, and diff audits passed. No commit or
  push was performed; the untracked `.riela` directory remains untouched.
- 2026-09-05: The Step 7 review revision (`comm-000122`) reopened and rechecked
  TASK-002. Authorization-pattern redaction now consumes complete quoted,
  bracketed, and parenthesized credential expressions across GraphQL errors,
  typed control-plane diagnostics, and schema metadata. Boundary-specific
  regressions prove co-located credential material is absent.
- 2026-09-05: Revision verification passed 57 focused Swift Testing tests, the
  71-XCTest/85-Swift-Testing reviewer matrix, `mise run build`, and the full
  suite with 791 XCTest and 123 Swift Testing tests. Strict SwiftLint reports
  only three repository-baseline findings. An unchanged skip-build repeat
  reproduced the documented intermittent exact-equality failure in
  `NoteRetrievalFusionTests` while all 123 Swift Testing tests passed. Package-
  description, file-size, zero-unchecked-criteria, TypeScript-change, deletion,
  whitespace, and diff audits passed. No commit or push was performed; `.riela`
  remains untouched.
- 2026-09-05: The Step 6 self-review revision (`comm-000124`) reopened and
  rechecked TASK-002. Unterminated quoted, bracketed, and parenthesized
  Authorization values now redact through the next comma, semicolon, newline,
  or diagnostic boundary. GraphQL error, control-plane diagnostic, and schema
  metadata regressions cover every unmatched wrapper form.
- 2026-09-05: Self-review revision verification passed 57 focused Swift
  Testing tests, the 71-XCTest/85-Swift-Testing reviewer matrix, and `mise run
  build`. The full suite passed 790 XCTest tests after excluding the reproduced
  unchanged `NoteRetrievalFusionTests` exact-equality baseline failure, plus all
  123 Swift Testing tests. Strict SwiftLint reports only three repository-
  baseline findings. Package-description, file-size, zero-unchecked-criteria,
  TypeScript-change, deletion, whitespace, and diff audits passed. No commit or
  push was performed; `.riela` remains untouched.
- 2026-09-05: The Step 6 self-review revision (`comm-000126`) reopened and
  rechecked TASK-002. Authorization sanitization now consumes the complete
  assignment through its comma, semicolon, newline, or diagnostic boundary
  without treating escaped quote, bracket, or parenthesis characters as safe
  terminators. GraphQL error, control-plane diagnostic, and schema metadata
  regressions cover all three escaped delimiter forms.
- 2026-09-05: Escaped-delimiter revision verification passed 57 focused Swift
  Testing tests, the 71-XCTest/85-Swift-Testing reviewer matrix, `mise run
  build`, package description, file-size, zero-unchecked-criteria, TypeScript-
  change, deletion, whitespace, and diff audits. An initial full-suite run hit
  an unrelated intermittent assertion at
  `Tests/AppServerTests/AgentReplyStreamHubTests.swift:754`; the unchanged
  `swift test --skip-build` retry passed all 791 XCTest and 123 Swift Testing
  tests. Strict SwiftLint reports only three repository-baseline findings. No
  commit or push was performed; `.riela` remains untouched.
- 2026-09-05: The Step 6 self-review revision (`comm-000128`) reopened and
  rechecked TASK-002. Authorization assignment recognition now consumes plain,
  quoted, and backslash-serialized keys before applying diagnostic-boundary
  redaction. GraphQL errors, control-plane diagnostics, and schema metadata
  exercise quoted keys combined with escaped credential-value delimiters.
- 2026-09-05: Quoted-key revision verification passed 57 focused Swift Testing
  tests, the 71-XCTest/85-Swift-Testing reviewer matrix, `mise run build`, and
  the full suite with 791 XCTest and 123 Swift Testing tests. Strict SwiftLint
  reports only three repository-baseline findings. Package-description, file-
  size, zero-unchecked-criteria, TypeScript-change, deletion, whitespace, and
  diff audits passed. No commit or push was performed; `.riela` remains
  untouched.
- 2026-09-05: The Step 6 self-review revision (`comm-000130`) reopened and
  rechecked TASK-002. The shared sanitizer now recognizes underscored,
  hyphenated, compact, and HTTP-prefixed Authorization header aliases before
  consuming the complete assignment. GraphQL error messages, paths, extension
  codes, control-plane diagnostics, and schema metadata combine alias keys with
  escaped credential-value delimiters.
- 2026-09-05: Authorization-alias verification passed 57 focused Swift Testing
  tests, the 71-XCTest/85-Swift-Testing reviewer matrix, and `mise run build`.
  Full-suite runs reproduced the unrelated exact-equality failure at
  `Tests/AppCoreTests/NoteRetrievalFusionTests.swift:148`; excluding that test
  passed 790 XCTest and all 123 Swift Testing tests. Strict SwiftLint reports
  only three repository-baseline findings. Package-description, file-size,
  zero-unchecked-criteria, TypeScript-change, workflow-change, deletion,
  whitespace, and diff audits passed. No commit or push was performed; `.riela`
  remains untouched.
- 2026-09-05: The Step 6 self-review revision (`comm-000132`) reopened and
  rechecked TASK-002. Authorization-key recognition now normalizes identifier
  suffixes instead of enumerating prefixes, covering snake-case and camel-case
  proxy aliases plus other prefixed `authorization` and `authorizationheader`
  forms. GraphQL errors, control-plane diagnostics, and schema metadata combine
  those aliases with escaped credential-value delimiters.
- 2026-09-05: Prefixed-alias verification passed 57 focused Swift Testing
  tests, the 71-XCTest/85-Swift-Testing reviewer matrix, and `mise run build`.
  Full-suite runs reproduced the unrelated exact-equality failure at
  `Tests/AppCoreTests/NoteRetrievalFusionTests.swift:148`; excluding that test
  passed 790 XCTest and all 123 Swift Testing tests. Strict SwiftLint reports
  only three repository-baseline findings. Package-description, file-size,
  zero-unchecked-criteria, TypeScript-change, workflow-change, deletion,
  whitespace, and diff audits passed. No commit or push was performed; `.riela`
  remains untouched.
- 2026-09-05: The Step 6 self-review revision (`comm-000134`) reopened and
  rechecked TASK-002. Authorization-key matching now consumes Unicode letter,
  mark, number, and connector prefixes and uses a Unicode-aware suffix boundary.
  GraphQL errors, control-plane diagnostics, and schema metadata combine Latin
  and CJK-prefixed aliases with escaped credential-value delimiters.
- 2026-09-05: Unicode-prefixed-alias verification passed 57 focused Swift
  Testing tests, the 71-XCTest/85-Swift-Testing reviewer matrix, `mise run
  build`, and the full suite with 791 XCTest and 123 Swift Testing tests. Strict
  SwiftLint reports only three repository-baseline findings. Package-
  description, file-size, zero-unchecked-criteria, TypeScript-change, workflow-
  change, deletion, whitespace, and diff audits passed. No commit or push was
  performed; `.riela` remains untouched.
- 2026-09-05: The Step 7 adversarial revision (`comm-000139`) reopened and
  rechecked TASK-007. GraphQL and typed SDK ingest now require a caller-provided,
  principal-scoped idempotency key. AppCore persists the canonical request
  digest and exact terminal result, coalesces concurrent retries, replays a
  committed result after response loss, and rejects changed input under the
  same key. Pending resources are hidden from reads, listings, search, and
  change publication; completion atomically reveals them and emits one
  finalized notebook-created event. Direct GraphQL, NoteChangeFeed concurrency,
  typed-wire, and live HTTP replay regressions cover the corrected contract.
- 2026-09-05: `comm-000139` verification passed 13 focused XCTest and four
  Swift Testing regressions, the 40-XCTest/85-Swift-Testing reviewer matrix,
  `mise run build`, package description, file-size, zero-unchecked-criteria,
  TypeScript-change, workflow-change, deletion, whitespace, and diff audits.
  The full suite passed all 123 Swift Testing tests and reproduced only the
  unrelated exact-equality baseline at
  `Tests/AppCoreTests/NoteRetrievalFusionTests.swift:148`; excluding that test
  passed all 792 remaining XCTest tests. Strict SwiftLint reports only the three
  repository-baseline findings. No commit or push was performed; `.riela`
  remains untouched.
- 2026-09-05: The Step 6 test-integrity revision (`comm-000142`) rechecked
  TASK-007. The blocked attachment and read-only phases now assert that direct
  `getNotebook`/`getNote`, notebook/note listings, `searchNotes`, and
  `NoteChangeFeed` cannot observe pending resources, then prove those same
  direct reads and search become available at terminal completion. A concurrent
  two-user regression proves one idempotency key is independently scoped and
  replayable for each principal.
- 2026-09-05: `comm-000142` verification passed 14 focused XCTest and four
  Swift Testing tests, the 41-XCTest/85-Swift-Testing reviewer matrix, and
  `mise run build`. The full suite reproduced only the documented PageRank
  exact-equality baseline while passing 793 of 794 XCTest and all 123 Swift
  Testing tests; excluding that test passed all 793 XCTest and 123 Swift
  Testing tests. Strict SwiftLint reports only three repository-baseline
  findings. Package-description, file-size, plan, TypeScript, workflow,
  deletion, whitespace, and diff audits passed. No commit or push was
  performed; `.riela` remains untouched.
- 2026-09-05: The Step 7 implementation-review revision (`comm-000146`)
  reopened and rechecked TASK-007. Pending ingest exclusion now lives in the
  SQL scope shared by strict FTS, relaxed lexical, LIKE, filter-only, and
  linked-graph searches, so hidden hits cannot consume limit or offset.
  AppCore and the live GraphQL create-notebook boundary reject the
  `_kaibaNotebookIngest` marker. Terminal completion failures persist committed
  identities, the exact result, and dispatch policy; retry resumes only the
  atomic reveal transition and then uses normal exact replay.
- 2026-09-05: `comm-000146` verification passed 11 focused XCTest tests, the
  16-XCTest/51-Swift-Testing reviewer matrix, `mise run build`, and the full
  XCTest/123-Swift-Testing suite. Strict SwiftLint reports only three
  repository-baseline findings. Package-description, file-size, plan,
  TypeScript, workflow, deletion, whitespace, and diff audits passed. No
  commit or push was performed; `.riela` remains untouched.
- 2026-09-05: The Step 6 self-review revision (`comm-000148`) reopened and
  rechecked TASK-007. Long-term-memory association recall and link
  materialization now pass the pending-ingest SQL scope into graph traversal.
  The ingest claim, marker capability, completion, recovery, and abandonment
  types and methods are package-internal, with a generated public-symbol-graph
  regression proving they are absent from AppCore's public API.
- 2026-09-05: `comm-000148` verification passed 29 focused XCTest tests, the
  36-XCTest/51-Swift-Testing reviewer matrix, `mise run build`, and the full
  XCTest/123-Swift-Testing suite. Strict SwiftLint reports only the three
  repository-baseline findings. Public-symbol-graph, package-description,
  file-size, plan, TypeScript, workflow, deletion, whitespace, and diff audits
  passed. No commit or push was performed; `.riela` remains untouched.
- 2026-09-05: The session-6 Step 6 rerun rechecked every supplied high/mid
  finding and completed TASK-007's validation-before-mutation contract.
  Notebook ingest now validates bounded pages, effective numbering, serialized
  input, attachments, and metadata before writing its idempotency claim.
  Pending retries re-enter the atomic claim operation, so an already-waiting
  identical request acquires a claim abandoned before notebook creation.
  Regressions prove invalid preflight inputs observe zero claims and a waiting
  retry creates exactly one notebook, then replays the terminal result.
- 2026-09-05: Session-6 verification passed the two new regressions, the
  reviewer-focused matrix with 35 XCTest and 57 Swift Testing tests, `mise run
  build`, and `mise run test` including all 123 Swift Testing tests. `mise run
  lint` completed with zero serious violations and only the three unchanged
  repository-baseline warnings. No TypeScript files changed. No commit or push
  was performed; `.riela` remains untouched.
- 2026-09-05: The session-6 Step 7 adversarial revision (`comm-000157`)
  rechecked TASK-007. Notebook creation and the durable `created` identity
  record now share one transaction; a restarted service resumes reconciliation
  while live retries remain serialized. Matching committed attachments are
  reused after process loss. Pending tag counts, comments, memo-source lookup,
  memo identity, and agent context apply the shared ingest exclusion. Pending
  mutations suppress action history, and terminal reveal atomically records
  `notebookIngested` while legacy premature entries remain hidden until reveal.
- 2026-09-05: `comm-000157` verification passed restart-before-reconciliation,
  restart-after-attachments, live retry, tag isolation, action-history
  publication, reconciliation, and validation regressions; the reviewer matrix
  passed 46 XCTest and 85 Swift Testing tests. `mise run build` and the complete
  `mise run test` suite passed 801 XCTest and 123 Swift Testing tests. `mise run
  lint` completed with zero serious violations and the same three baseline
  warnings. Package-boundary, file-size, TypeScript-change, workflow-change,
  whitespace, and diff audits passed. No commit or push was performed; `.riela`
  remains untouched.
- 2026-09-05: The session-6 Step 6 self-review revision (`comm-000159`)
  records tag IDs first created by the hidden ingest in its server-owned marker
  and excludes only those IDs from public AppCore, GraphQL, CLI, and agent-tool
  tag catalogs until terminal reveal. AppCore and GraphQL regressions prove
  pending absence, terminal visibility, and preservation of pre-existing
  unused tags.
- 2026-09-05: `comm-000159` verification passed the two new targeted
  regressions, the 47-XCTest/85-Swift-Testing reviewer matrix, `mise run build`,
  and the complete `mise run test` suite including all 123 Swift Testing tests.
  `mise run lint` completed with zero serious violations and the same three
  baseline warnings. Package-boundary, file-size, TypeScript-change, workflow-
  change, whitespace, and diff audits passed. No commit or push was performed;
  `.riela` remains untouched.
- 2026-09-05: The session-6 Step 7 revision (`comm-000163`) moved
  process-local ingest ownership cleanup to the claimed-executor scope so it
  runs on every exit, including simultaneous terminal-completion and
  recovery-persistence failures. A deterministic fault-injection regression
  proves the next retry in the same process resumes the durable `created`
  state, reveals the original resources, and then replays the result.
- 2026-09-05: `comm-000163` verification passed all 6 ingest-reconciliation
  tests, the reviewer-focused matrix with 48 XCTest and 85 Swift Testing tests,
  `mise run build`, the complete `mise run test` suite including 123 Swift
  Testing tests, and `mise run lint` with zero serious violations and three
  unchanged baseline warnings. Package-boundary, file-size, TypeScript-change,
  workflow-change, deleted-file, whitespace, and diff audits passed. No commit
  or push was performed; `.riela` remains untouched.
- 2026-09-05: The session-6 Step 6 self-review revision (`comm-000165`)
  disarms owner-scope deferred cleanup after successful pre-create abandonment
  because abandonment has already released the registry. Failed abandonment
  still falls back to deferred release. The abandonment regression now holds a
  replacement owner across the old invocation's exit and proves a probe remains
  pending rather than acquiring concurrently.
- 2026-09-05: `comm-000165` verification passed the targeted stale-release
  regression, all 13 ingest concurrency/reconciliation XCTest tests, the
  48-XCTest/85-Swift-Testing reviewer matrix, `mise run build`, the complete
  `mise run test` suite including 123 Swift Testing tests, and `mise run lint`
  with zero serious violations and three unchanged baseline warnings. Package-
  boundary, file-size, TypeScript-change, workflow-change, deleted-file,
  whitespace, and diff audits passed. No commit or push was performed; `.riela`
  remains untouched.
- 2026-09-05: The session-6 Step 7 revision (`comm-000169`) completes TASK-007
  preflight by validating every page metadata object and both attachment-role
  domains before the durable claim. Boundary regressions assert `invalid_request`,
  zero claim observations, zero notebooks, and zero notes for malformed page
  metadata and unsupported source-document or page-image roles.
- 2026-09-05: `comm-000169` verification passed the targeted preflight test,
  all 5 client-boundary tests, all 6 ingest-reconciliation tests, the 48-XCTest/
  85-Swift-Testing reviewer matrix, `mise run build`, and the complete `mise run
  test` suite with 123 Swift Testing tests. The first full-suite attempt hit an
  unrelated approximately 1e-17 exact-floating-point comparison flake in
  `NoteRetrievalFusionTests`; its isolated rerun and the complete suite rerun
  passed. `mise run lint` reported zero serious violations and three unchanged
  baseline warnings. Package-boundary, file-size, web, TypeScript, workflow,
  deleted-file, whitespace, and diff audits passed. No commit or push was
  performed; `.riela` remains untouched.
- 2026-09-05: The session-6 self-review revision (`comm-000171`) strengthens
  TASK-007's zero-note-mutation proof by comparing the complete note-ID set
  before and after every invalid ingest, including encoded and decoded budget
  failures. This replaces the capped `limit: 1` count that could not detect an
  additional note in a pre-populated fixture.
- 2026-09-05: `comm-000171` verification passed the strengthened targeted
  regression, the 48-XCTest/85-Swift-Testing reviewer matrix, `mise run build`,
  the complete `mise run test` suite including 123 Swift Testing tests, and
  `mise run lint` with zero serious violations and three unchanged baseline
  warnings.
- 2026-09-05: The session-6 Step 7 revision (`comm-000175`) makes the generic
  deferred-ingest policy, overload, and finalizer package-internal. Deferred
  creation now persists an exact-note lifecycle marker in its transaction;
  finalization atomically validates and consumes it, records terminal history,
  enqueues notebook/note actions, and publishes one notebook-created event.
  Observer and repeated/immediate-finalization regressions prove exactly-once
  terminal publication and dispatch eligibility.
- 2026-09-05: `comm-000175` verification passed the targeted lifecycle test,
  all 3 AppCore ingest public-API tests, the reviewer-focused 16-XCTest/
  85-Swift-Testing matrix, `mise run build`, and the complete `mise run test`
  suite including 123 Swift Testing tests. The first full-suite run reproduced
  the pre-existing exact-floating-point flake in `NoteRetrievalFusionTests`;
  its isolated run and the complete-suite rerun passed. `mise run lint`
  reported zero serious violations and three unchanged baseline warnings.
  Package-boundary, file-size, TypeScript, workflow, web, deleted-test,
  whitespace, and diff audits passed. No commit or push was performed;
  `.riela` remains untouched.
- 2026-09-05: The session-6 adversarial revision (`comm-000180`) replaces the
  10 ms ingest-claim polling loop with process-local release notification and
  25 ms to 500 ms exponential fallback under the existing 30-second bound.
  Cancellation removes waiters immediately. The local HTTP server now tracks
  route tasks by connection, monitors peer closure while routing, and cancels
  work on SDK timeout, disconnect, and server stop. Load-style regressions
  prove twelve cancelled duplicates perform one claim each, bounded timeout
  stops further claims, only one durable claim exists, and terminal replay
  remains exact.
- 2026-09-05: `comm-000180` verification passed the 39-XCTest/
  85-Swift-Testing reviewer matrix, `mise run build`, and `mise run lint` with
  zero serious violations and three unchanged baseline warnings. One complete
  `mise run test` rerun passed all 807 XCTest and 123 Swift Testing tests;
  other complete attempts reproduced only the pre-existing exact-floating-
  point comparison flake in `NoteRetrievalFusionTests`, whose isolated rerun
  passed. Package-boundary, file-size, TypeScript, workflow, web, deleted-test,
  whitespace, and diff audits passed. No commit or push was performed;
  `.riela` remains untouched.
- 2026-09-05: The session-6 self-review revision (`comm-000182`) atomically
  gates route-handler entry through the connection-owned task handle. A task
  cancelled after registration but before execution now exits without calling
  the handler, and route-task observability counts workers until they actually
  terminate. A deterministic held-start regression proves zero handler calls
  and complete worker cleanup after disconnect.
- 2026-09-05: `comm-000182` verification passed the targeted held-start test,
  all 15 route/transport/ingest concurrency tests, the 40-XCTest/
  85-Swift-Testing reviewer matrix, `mise run build`, and `mise run lint` with
  zero serious violations and three unchanged baseline warnings. Complete
  `mise run test` attempts reached all 808 XCTest and 123 Swift Testing tests
  but were blocked solely by the pre-existing exact-floating-point comparison
  at `Tests/AppCoreTests/NoteRetrievalFusionTests.swift:148`; its isolated
  rerun passed. Package-boundary, file-size, TypeScript, workflow, web,
  deleted-test, whitespace, and diff audits passed. No commit or push was
  performed; `.riela` remains untouched.
