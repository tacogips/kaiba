# Public Kaiba Swift Client SDK

**Status**: Accepted for implementation (2026-09-04)
**Issue**: `local-request:/Users/taco/gits/tacogips/kaiba:Add first-party Kaiba Swift client SDK and schema discovery CLI`
**Related**: `design-docs/specs/command.md`, `design-docs/specs/kaiba-note.md`,
`design-docs/specs/library.md`, `design-docs/specs/note-api-auth.md`

## Purpose

Publish a standalone Swift client for a running `kaiba serve` endpoint. The
client must execute arbitrary GraphQL documents and provide typed conveniences
for the note, notebook, tag, attachment, comment, ingest, document,
conversation, and long-term-memory operations used by Riela's `kaiba/*`
nodes. Localhost and remote endpoints use the same client. The client never
opens a Kaiba database and never falls back to `NoteService`, a store driver,
or another in-process service.

Add endpoint-backed GraphQL schema discovery to the Kaiba CLI. It uses the
same endpoint and authentication rules as the client, optionally filters the
schema with a regular expression, and emits deterministic text and JSON.

## Current State And Constraints

- `AppGraphQL.GraphQLHTTPDocumentClient` is public but depends on `AppCore`,
  returns synthetic GraphQL responses for transport failures, accepts a nil
  token as implicit unauthenticated access, and exposes no typed operations.
- `kaiba graphql` either opens the local store or sends one document to a
  remote endpoint. Existing invocations and their response-body output are a
  compatibility contract.
- `GraphQLContractProjector.schemaContract` is authoritative SDL, but a live
  executor does not currently answer standard introspection fields.
- Riela's typed add-ons currently call `NoteService` directly. The remote
  document add-on is the only no-store path. In particular, notebook ingest
  and long-term memory need additive server GraphQL fields before they can
  migrate without a local fallback.
- The SDK must not depend on `AppCore`, `AppGraphQL`, `AppServer`, SQLite,
  document converters, or other Kaiba implementation modules.
- Credentials may exist in memory long enough to make a request, but neither
  the SDK nor the CLI persists a raw bearer token. Diagnostics, descriptions,
  JSON, and text output never contain one.

## Package Boundary

`Package.swift` gains a public library product and target named
`KaibaClient`.

```text
KaibaClient  -> Foundation (+ FoundationNetworking where required)
AppGraphQL   -> AppCore + KaibaClient
KaibaCLIKit  -> KaibaClient
AppCLI       -> AppCore + AppGraphQL + AppServer + KaibaClient + KaibaCLIKit
```

The dependency direction is deliberate. `KaibaClient` owns transport-neutral
wire JSON, request/response envelopes, public client errors, public schema
models/filtering, and client DTOs. `AppGraphQL` may use those schema models to
serve introspection, but the client never imports server or store code.

Public client files stay responsibility-based and below 1,000 lines. Expected
groups are endpoint/auth policy, HTTP transport, GraphQL envelopes and errors,
schema discovery/filtering/rendering, shared DTOs, and operation families.
`KaibaCLIKit` is an internal, non-product target containing only the new schema
subcommand parser/runner so deterministic CLI tests do not force command policy
into the public SDK. The existing `AppCLI/GraphQLCommand.swift` execution path
remains in place.

## Public Client Contract

### Construction

Construction is throwing and requires an authentication choice:

```swift
let client = try KaibaClient(
  endpoint: URL(string: "https://kaiba.example.com")!,
  authentication: .bearer(try KaibaBearerToken(value))
)
```

The public concepts are:

- `KaibaClient`, a `Sendable` value using an injected
  `any KaibaHTTPTransporting`.
- `KaibaEndpoint`, a validated and normalized URL value.
- `KaibaAuthentication.bearer(KaibaBearerToken)` or
  `.unauthenticated`. There is no default and no optional-token initializer.
- `KaibaTransportSecurity.secureByDefault` or
  `.allowInsecureRemoteHTTP`. The default permits HTTP on loopback and requires
  HTTPS elsewhere. The explicit override supports controlled remote HTTP
  deployments without weakening default bearer handling.
- `KaibaClientConfiguration`, including a finite positive request timeout no
  greater than the documented 24-hour representability ceiling and
  transport-security policy, a 2 MiB encoded-request limit matching the
  current server parser, and an 8 MiB decoded-response limit. Limits are
  positive and explicitly configurable for a server with a different bounded
  policy. Production defaults to a 10-second absolute wall-clock deadline,
  enforced independently of response progress, and performs no automatic
  retry. Callers choose when to retry; ingest retries reuse the required
  principal-scoped idempotency key described below.

`KaibaBearerToken` trims no content: leading/trailing whitespace, empty values,
control characters, CR, and LF are rejected. It is intentionally not
`Codable`; its `description`, debug description, and reflected value are fixed
redaction text. The raw value is accessible only inside the module when the
Authorization header is built.

Unauthenticated use is always explicit. It is accepted on loopback endpoints.
For a non-loopback endpoint it additionally requires the configuration's
explicit remote-unauthenticated opt-in; otherwise construction fails. This
keeps remote HTTP(S) technically available while making accidental open remote
access fail closed.

### Endpoint normalization

Normalization happens exactly once during construction:

1. Require an absolute `http` or `https` URL with a non-empty host.
2. Reject user info, query, fragment, NUL/control characters, invalid ports,
   and decoded `.` or `..` path segments. An explicitly present authority port
   must be a non-empty decimal integer in `1...65535`; empty, malformed, and
   integer-overflowing ports fail as `invalid_endpoint` before transport.
3. Treat an empty path or `/` as `/graphql`.
4. Preserve any other explicit path, including its trailing slash and percent
   encoding. This preserves current custom GraphQL endpoint compatibility.
5. Lowercase scheme and host and omit only a default port (`80` for HTTP,
   `443` for HTTPS). Do not otherwise rewrite the URL.

Loopback means `localhost` (including a trailing dot), an address in
`127.0.0.0/8`, or IPv6 `::1`; substring and suffix matches are forbidden.
The same normalized GraphQL URL is used by arbitrary execution, typed
operations, readiness, and schema discovery.

`KaibaEndpoint.description`, debug reflection, `Mirror`, `dump`, and every
authentication-aware diagnostic expose the normalized URL only for the fixed
`/graphql` path. Every accepted custom path is represented by one opaque
`<redacted>` segment, regardless of whether it contains the active bearer or
uses unauthenticated mode. The complete path remains available only to the
transport.

### Arbitrary GraphQL execution

`execute(_:)` accepts a `KaibaGraphQLRequest` containing a non-empty UTF-8
document, JSON-object variables, and optional non-empty operation name. The
untyped overload returns `KaibaGraphQLResponse<KaibaJSONValue>`; the generic
overload decodes `data` into a caller-provided `Decodable & Sendable` type.
Any JSON request-encoding failure, including a non-finite numeric value, is
reported as `invalid_request` before transport rather than escaping as a raw
encoder error.

Every request is POST JSON with `content-type: application/json`,
`accept: application/json`, and, for bearer mode, exactly one
`authorization: Bearer ...` header. Caller-supplied headers cannot replace
Authorization, Host, Content-Length, or Content-Type.

The production transport does not follow redirects. A 3xx response is an
`http_failed` result with its status only; it never forwards a bearer to a new
origin or path. TLS trust evaluation remains the platform default and cannot
be disabled through the public client. Request and URLSession resource
timeouts share the configured deadline, and an explicit cancellation race
ensures a peer cannot extend it by continuously trickling response bytes.
Caller cancellation propagates as `CancellationError`; it is never converted
to the retryable `connection_failed` category. A transport-originated
`URLError.cancelled` likewise retains cancellation semantics.

The public `KaibaHTTPRequest` and `KaibaHTTPResponse` values expose raw fields
to the injected transport but provide safe description, debug-description,
`Mirror`, and `dump` surfaces. Request diagnostics contain only an opaque
endpoint, sorted header names, body byte count, and timeout. Response
diagnostics contain only status and body byte count.

Success requires all of the following:

- the transport completed;
- HTTP status is in `200...299`;
- the body is a JSON object matching a GraphQL response envelope; and
- `errors` is absent or empty.

The exact encoded request is rejected before transport when it exceeds the
configured request limit. The production transport cancels response collection
when the configured response limit would be exceeded and returns
`invalid_response`; it does not first buffer an unbounded body.

GraphQL partial data is retained on the typed GraphQL error for programmatic
recovery but is never interpolated into an error description, debug string,
`Mirror`, or `dump` output.

### Error taxonomy and redaction

`KaibaClientError` is `Error`, `Equatable`, `Sendable`, and
`CustomStringConvertible`, with stable categories and codes:

| Case | Stable code | Evidence retained |
| --- | --- | --- |
| invalid endpoint/configuration/request | `invalid_endpoint`, `invalid_configuration`, `invalid_request` | safe reason only |
| transport failed or timed out | `connection_failed` | typed transport category/`URLError.Code` |
| HTTP 401 or 403 | `auth_failed` | status code |
| other non-success HTTP | `http_failed` | status code |
| malformed/non-JSON envelope | `invalid_response` | status and bounded byte count |
| GraphQL `errors` present | `graphql_failed` | sanitized messages, locations, paths, extension codes; optional partial data |
| response data decoding failed | `decoding_failed` | coding path, never the value |
| schema/introspection missing or malformed | `schema_unavailable` | safe reason |

Raw response bodies, request documents, variables, headers, and bearer values
are not stored in diagnostics or rendered descriptions. Server GraphQL messages
are bounded and sanitized for the active token, Authorization-like fragments,
URL user info, and control characters before exposure. Endpoint diagnostics use
the normalized scheme/host/port/path only. The transport maps errors to a
closed category and does not forward `localizedDescription`, which can embed a
URL or system detail. Published endpoint diagnostics additionally redact the
active bearer token if it occurs in an accepted custom endpoint path. Detection
uses the decoded path, so percent-escape hex case and optional escaping of
unreserved characters cannot preserve a reversible credential representation.
Authorization sanitization conservatively consumes the complete assignment
through the next comma, semicolon, newline, or diagnostic boundary. It does not
treat quoted, bracketed, or parenthesized delimiters as trusted boundaries, so
escaped or missing closing delimiters cannot leave credential suffixes visible.
Quoted and backslash-serialized Authorization keys receive the same treatment.
Identifier tokens are normalized across case and separator variants with
Unicode-aware prefix handling; any key whose normalized identifier ends in
`authorization` or `authorizationheader` is redacted, including
`proxy_authorization`, `proxyAuthorizationHeader`, Unicode-prefixed aliases,
and HTTP-prefixed aliases.

Typed conveniences apply the same authentication-aware sanitizer to every
decoded control-plane `result.diagnostics` string before returning the public
payload. Domain values outside control-plane diagnostics remain unchanged.

GraphQL error paths accept only string and integer components. String path
components and typed-decoding coding keys receive the same active-token and
Authorization-pattern sanitization as GraphQL messages; arrays, objects, nulls,
booleans, and non-integer numeric path components make the envelope an
`invalid_response` rather than becoming public error payloads.

Schema descriptions and deprecation reasons receive that same active-token,
Authorization-pattern, URL-user-info, control-character, and length sanitization
before `fetchSchema()` returns. Schema identifiers and references are rejected
as `schema_unavailable` if sanitization would alter them, because redaction
cannot preserve their GraphQL meaning. Any retained `schema_unavailable` reason
is sanitized through the same boundary before description or reflection.

No public type conforming to `Codable`, `CustomStringConvertible`, or
`CustomDebugStringConvertible` contains a raw token. Tests exercise exact-token,
mixed-case Authorization, URL-user-info, query-string, endpoint-path, and
multiline redaction; `Mirror` and `dump` expose only opaque error metadata and
a redacted bearer-token child.

## Deterministic Readiness Probe

`try await probeReadiness()` sends one fixed, side-effect-free document with no
retries:

```graphql
query KaibaClientReadiness {
  kaibaReadiness: notes(limit: 0) {
    result { accepted status }
  }
}
```

The `notes(limit: 0)` field is bounded, already supported, and causes the
server's normal GraphQL authentication path to run. A ready result requires
HTTP 2xx, no GraphQL errors, and `accepted == true` at the expected alias.

The returned `KaibaReadinessResult` has a typed status:
`ready`, `authFailed`, `connectionFailed`, `serverRejected`, or
`incompatibleResponse`. It reports `authenticationMode` as `bearer` or
`unauthenticated`, the redacted endpoint, an optional HTTP status, and a safe
next action. It contains no body, variables, or credential. Invalid endpoint
and missing credential are construction/CLI errors and therefore cannot be
misreported as connection failures.

Classification is deterministic: 401/403 is authentication failure; transport
or timeout is connection failure; caller/transport cancellation propagates as
`CancellationError`; a valid GraphQL response with
`accepted == false` is server rejection; every other structurally unexpected
2xx response is incompatible. The SDK does not infer authentication failure
from message text.

## Typed Riela Operation Conveniences

Typed methods are small document builders over `execute`; they do not bypass
GraphQL, share stores, or reach service APIs. IDs are distinct public wrappers
(`KaibaNoteID`, `KaibaNotebookID`, `KaibaTagID`, `KaibaFileID`, and
`KaibaCommentID`) rather than interchangeable strings; auto-action causality
uses the distinct `KaibaAutoActionID` wrapper. Fixed producer-owned values are
enums. Externally extensible server statuses and roles decode as lossless open
enums with `.custom(String)`.

The first release covers these families:

- Notes: create, update, get, list, search, delete, set read-only, graph
  neighbors, and links needed to reconstruct Riela `note-get`, `note-search`,
  `note-tag-search`, `note-graph-neighbors`, and `note-chain` payloads. List
  accepts the Riela tag filter; search accepts tag/class filters, notebook,
  linked-neighbor inclusion, depth, limit, and offset.
- Notebooks: create, get, list, delete, and set read-only.
- Tags: list tags/classes, define tag/class, apply and remove note tags, and
  apply/remove notebook tags by ID or unambiguous name.
- Attachments: attach inline bytes to a note or notebook and list note or
  notebook attachments. Byte download remains the existing authenticated file
  route and is outside the GraphQL convenience layer.
- Comments and memos: add/list note and notebook comments. Both add methods
  accept optional author attribution, preserving Riela's `author`/`assignedBy`
  input; Riela may derive memo/agent-memo subsets locally from typed authors.
- Ingest and documents: ingest a bounded page array with optional inline source
  document and page-image attachments. Each page preserves its requested
  read-only state, note tags, metadata JSON, and page number; return the
  notebook, ordered notes, and attachments. `ingestDocument` accepts
  already-converted pages and source metadata. File conversion/OCR remains
  caller-owned, so `KaibaClient` does not import AnydocKit or an agent runtime.
  Both conveniences require a caller-provided idempotency key. Identical
  principal/key/request retries replay the committed result; reusing the key
  with changed input returns `invalid_request`.
- Conversations: save a typed conversation and list note/notebook
  conversations.

For bearer-authenticated mutations, database `createdBy`/`updatedBy` ownership
is always derived from the verified user. Caller-visible `author` and
`assignedBy` labels are preserved for Riela compatibility, while the
`client:` namespace is reserved for server-generated verified client identity.
When a caller omits a label, the server records `client:<verified-client-id>`;
a bearer caller cannot supply a value in that reserved namespace.
- Long-term memory: get the canonical notebook, append an idempotent batch,
  optionally create bounded associations, and recall with association evidence
  and recency weight.

`createNote`, `updateNote`, `createNotebook`, `ingestNotebookPages`,
`ingestDocument`, and `saveConversation` accept an optional
`originatingActionId`. When supplied, the identifier is forwarded unchanged
through GraphQL and service calls so auto-action dispatch can suppress
workflow-originated mutation loops; when absent, the wire input is omitted.

Convenience selection sets are constants and are covered by response fixtures.
They request every field needed by the current Riela payloads, including IDs,
timestamps, tags, metadata, file attributes, graph evidence, and control-plane
status. A caller can always use arbitrary execution for newer fields without
waiting for a typed SDK release.

File payloads include `storageKind`, `localPath`, `s3Profile`, `s3Bucket`,
`s3Key`, `mediaType`, `byteSize`, `sha256`, `originalFilename`, `createdAt`,
and `migratedAt`; the SDK derives Riela's `s3URL` from the bucket and key.
Control-plane status spellings match the server wire contract, including
`not_found` and `invalid_request`. Long-term-memory validation failures use
`invalid_request`, and missing long-term-memory resources use `not_found`
rather than the generic `error` status.

### Additive server fields

Existing GraphQL fields are reused where possible. The authoritative schema
and executor gain only the missing network boundary:

- `notebookFiles(notebookId: String!)`;
- `noteLinks(noteId: String!)`;
- `attachNotebookFile(input: AttachNotebookFileInput!)`;
- `ingestNotebookPages(input: IngestNotebookPagesInput!)`;
- `longTermMemoryNotebook`;
- `appendLongTermMemory(input: AppendLongTermMemoryInput!)`;
- `recallLongTermMemory(input: RecallLongTermMemoryInput!)`; and
- `linkLongTermMemoryAssociations(noteId: String!, limit: Int)`.

The ingest mutation owns one bounded request contract: at most 500 pages, each
page no larger than `MarkdownHeadingSplitter.maximumSectionBytes`, strictly
positive unique page numbers when supplied, a JSON-encoded input no larger than
the shared 2 MiB `GraphQLRequestLimits.maximumSerializedBodyBytes` also used by
`KaibaHTTPRequestParser`, decoded attachment bytes within the current server
request/attachment budget, and no filesystem path fields. The direct GraphQL
service validates the serialized-input limit before attachment decoding or any
mutation. It performs notebook/note creation with the service's existing
transactional method. Attachment failure is reported explicitly; no
client-side rollback or local-store retry is attempted. The returned payload
identifies committed resources so a caller can reconcile partial post-create
attachment failures. Pages are created writable only long enough to attach
page images, then each page's requested read-only state is restored; page tags
and metadata are written transactionally with the page.

Every failure after notebook creation remains inside the ingest partial-failure
state machine. Read-only restoration continues after an individual page fails,
then each committed note is read back independently so the response retains the
committed notebook, note, and attachment identities together with the best
authoritative read-only state available. A restoration or readback failure
cannot fall through to the pre-commit error payload that omits those identities.
Notebook- and note-created auto-actions are neither persisted as eligible nor
dispatched until attachment handling, read-only restoration, and authoritative
readback have all reached that terminal state. A pending ingest is excluded
from direct reads, notebook/note listings, search, the change feed, tags first
created by the pending ingest in the public tag catalog, tag detail counts, tag
comment projections, tag memo lookup/source resolution, tag agent context, and
action history. Search applies this exclusion in SQL across strict,
relaxed, fallback, filter-only, and linked-graph stages before ranking and
pagination. Public notebook metadata cannot contain the server-owned
`_kaibaNotebookIngest` member. Long-term-memory association recall and link
materialization apply the same pending-row scope before graph ranking, so
neither can expose or create links to an incomplete ingest. The capability and
lifecycle APIs that may persist this marker are package-internal AppCore
implementation details and absent from its public API.

Before an ingest idempotency claim is written, every page `metaJSON` must parse
as a JSON object and must not contain server-managed note metadata. Explicit
source-document and page-image roles must resolve to their respective closed
role enums. Invalid metadata or roles return `invalid_request` with no claim,
notebook, or note mutation.

Hidden notebook/note creation and a durable `created` record containing their
exact identities commit in one transaction. Process-local execution ownership
keeps concurrent live retries waiting, while a newly started service can resume
that durable state. Resume reuses matching committed attachments before
continuing read-only reconciliation, so a stop anywhere after creation does not
strand or duplicate resources. The server atomically records the canonical
request digest and terminal result, removes the pending marker, records the
single `notebookIngested` action, makes successful auto-actions eligible, and
then publishes one finalized notebook-created event. A concurrent identical
request waits for and replays that terminal result; a response lost after commit
can therefore be retried without duplicate resources or dispatches. If the
terminal reveal transaction itself fails, the server persists the committed
notebook, note, and attachment result identities plus the intended dispatch
policy. A retry resumes only that reveal transition and returns the exact
terminal result; it never creates a second ingest. Process-local execution
ownership is released whenever the owning invocation exits, including when
both terminal reveal and recovery-record persistence fail, so a same-process
retry can reacquire the durable `created` state instead of timing out. A
successful pre-create abandonment performs that release exactly once; the old
invocation cannot clear a replacement owner that reacquires the same scope
before it returns. Failed durable abandonment retains the deferred release as
a fallback.

Concurrent duplicate requests wait on the process-local execution owner's
release notification, with a 25 ms to 500 ms exponential fallback bounded by a
30-second overall deadline for cross-process durability changes. Cancellation
immediately removes a waiter and stops further claim transactions. The HTTP
server owns each asynchronous route task through its connection, monitors peer
closure while routing, and cancels the task on client disconnect, SDK timeout,
or server stop. Handler entry is atomically gated by that cancellation state,
so a task cancelled before it begins cannot invoke the GraphQL route at all.
Disconnected requests therefore cannot continue polling the
ingest claim after their response is no longer deliverable, while successful
waiters still replay the exact persisted terminal result.

The lower-level deferred notebook-ingest auto-action mode is package-internal,
not part of AppCore's public API. Its creation transaction persists a
server-owned lifecycle marker containing the exact page identities. Finalizing
atomically validates and consumes that marker, records the terminal ingest
history, and makes notebook/note auto-actions eligible before publishing one
notebook-created change event. Repeated finalization and attempts to finalize an
ordinary immediate ingest fail before mutation, preventing duplicate actions or
events; ordinary callers cannot forge the lifecycle marker through notebook
metadata.

The long-term-memory fields preserve service idempotency, bounds, and graph
semantics. They are reachable only by an authenticated enabled admin (or the
explicit loopback `--allow-unauthenticated --as-admin` operator mode). Ordinary
unauthenticated or non-admin calls fail closed without revealing the canonical
notebook. This is the HTTP equivalent of the current unscoped local-operator
guard and is required for Riela's machine credential.

Long-term-memory idempotency keys are scoped to the acting user principal; the
unscoped operator uses the default user identity. Each persisted batch records
a SHA-256 digest of the canonical normalized entries and effective attribution.
An identical request replays the original ordered notes, while reuse by the
same principal with a changed body, tags, period, source/related identifiers,
metadata, or attribution returns `invalid_request`. Different administrator
users may independently use the same key. The transaction serializes concurrent
reuse so a changed request cannot be reported as a successful replay.
For upgrade compatibility, a retry by the default operator also recognizes the
legacy key-only identifier scheme. It adopts that batch transactionally only
after the complete persisted body, tags, periods, source/related identities,
metadata, and legacy attribution match the canonical request; any difference
returns `invalid_request` instead of creating or claiming another batch.

Long-term-memory period boundaries accept ISO-8601 timestamps with or without
fractional seconds. Conversion is throwing: malformed values reject the
operation instead of being silently replaced with `nil`, and accepted period
metadata is preserved through the service boundary.

Association depth is caller-bounded: negative values return `invalid_request`,
zero returns no associated notes, one permits only one-hop results, and positive
values above `NoteGraphPolicy.maximumDepth` are capped at that maximum.

All additions are additive. Existing `AppCore` and `AppGraphQL` public APIs,
schema spellings, local `kaiba graphql`, and remote document execution remain
source- and behavior-compatible.

## Schema Discovery

### Server protocol

Kaiba serves standard GraphQL introspection for `__schema` and `__type` from
the same authoritative `GraphQLContractProjector.schemaContract`. Introspection
uses the same bearer authentication decision as ordinary supported root
fields; an authenticated server never exposes schema by accidentally treating
meta-fields as unsupported/unauthenticated. There is no local SDL fallback in
the SDK or CLI.

The implementation may use a bounded SDL parser and a dedicated introspection
executor rather than replacing Kaiba's document engine. It must answer the
canonical SDK introspection document and the standard fields it selects:
schema roots, type kind/name/description, fields and arguments, nested type
references, input fields, and enum values. Unsupported or malformed
introspection selections return GraphQL errors, not partial invented schema.
Before projection the executor enforces fixed selection-node and schema-aware
projection-complexity budgets. The serialized response is independently capped
at the server's bounded response limit, so alias breadth cannot amplify a
bounded request into unbounded allocation or output.

`KaibaClient.fetchSchema()` executes the canonical introspection document,
validates root identities and type references, rejects duplicate conflicting
definitions, and returns `KaibaGraphQLSchema`. Decoding a public
`KaibaGraphQLSchema` value applies the same GraphQL-name, kind/member,
wrapper-depth, known-field shape, uniqueness, relationship-list uniqueness,
reference-kind, dangling-reference, and canonical ordering checks before
exposing the value. Wrapper references reject non-null names, named references
reject non-null `ofType` values, and duplicate input never reaches a trapping
dictionary initializer.

### Filter semantics

The optional filter is an ICU regular expression compiled with
`NSRegularExpression`, case-sensitive with substring matching. Invalid syntax
fails before any network request with `invalid_regex`.

Filter candidates are the simple name and qualified name of every seed:

- `notes` and `Query.notes` for a query field;
- `createNote` and `Mutation.createNote` for a mutation field; and
- `Note` and `Type.Note` for an object/input/enum/scalar type.

Matching query and mutation fields and matching non-root types form the seed
set. The result then includes the transitive closure of every named type
referenced by a seeded root field's arguments/result or a seeded/reachable
type's fields, arguments, and input fields. Reachable object/input/enum/scalar
definitions are included whole. `Query` and `Mutation` are special: only
matching root fields appear, and traversal never pulls in their unmatched root
fields. Interface and union types are not direct filter seeds, but are included
with their possible/member types when a selected definition references them;
introspection meta-types are excluded. Built-in scalars are included when
referenced. An empty match is a successful empty schema, not an error. With no
filter, every root field and supported non-introspection type is returned.

Cycles use a visited set. All output is canonicalized independently of server
ordering: query fields and mutation fields by name; types by `(kind, name)`;
fields, arguments, input fields, and enum values by name. A dangling type
reference makes the schema unavailable rather than silently truncating the
closure.

### CLI surface and output

The new command is:

```text
kaiba graphql schema --endpoint <url>
  (--api-key-env <NAME> | --allow-unauthenticated)
  [--allow-remote-unauthenticated] [--allow-insecure-http]
  [--filter <regex>] [--output text|json]
```

`schema` is recognized only as the first token after `graphql`; all existing
document, `--file`, stdin, variables, operation-name, local-store, and remote
execution forms keep their current parsing and output.

Authentication choices are mutually exclusive and one is required. The CLI
accepts environment-variable names matching `[A-Za-z_][A-Za-z0-9_]*`, reads
the selected non-empty value only when constructing the client, and never
includes the value in options, results, or errors. `--allow-insecure-http` is
required only for non-loopback HTTP. `--allow-remote-unauthenticated` is valid
only with `--allow-unauthenticated` and is additionally required for any
non-loopback endpoint.

Text output is a canonical filtered SDL excerpt. It emits a root block only for
root kinds with selected fields and then emits the included type definitions;
it does not invent unmatched root fields merely to make the excerpt executable.
When nothing matches, text is the fixed line `# No schema elements matched.`
JSON then contains empty arrays. JSON is a sorted object with this stable
top-level shape:

```json
{
  "status": "ok",
  "endpoint": "https://kaiba.example.com/graphql",
  "filter": "Note|createNote",
  "queryFields": [],
  "mutationFields": [],
  "types": []
}
```

Without a filter, the JSON `filter` value is `null`; the key is never omitted.
The original filter drives selection. When authentication-aware diagnostic
sanitization changes a supplied filter, its published value is the opaque
`<redacted>` marker rather than a partially redacted expression, preventing a
co-located credential substring from remaining in command output or reflected
results.

Root field records contain `name`, sorted `arguments`, and canonical `type`.
Type records contain `kind`, `name`, and exactly the applicable sorted member
array (`fields`, `inputFields`, or `enumValues`); scalar records have no member
array. Types use the stable order `object`, `input`, `enum`, `scalar`,
`interface`, `union`, then name. Optional descriptions are included only when
present. JSON keys are sorted by the encoder. Text and JSON go to stdout only
on success.

Failures go to stderr, exit non-zero, and use stable code-prefixed human copy.
JSON error output is selected by `--output json` and has `status: "error"`,
`code`, `message`, redacted `endpoint` when available, and `nextAction`.
Any valid `--output json` occurrence is preserved when another argument causes
parsing to fail. A missing `--endpoint` is `invalid_usage`, while a present but
unparseable endpoint is `invalid_endpoint`. Runtime failures use the validated normalized endpoint;
invalid endpoint input is rendered only after user information, query, and
fragment removal.
Required codes are `invalid_regex`, `invalid_endpoint`, `missing_credential`,
`auth_failed`, `connection_failed`, `schema_unavailable`, and
`invalid_response`. No error output contains a response body or bearer token.
During schema discovery, authentication and connection failures preserve their
specific codes; GraphQL rejection of introspection, missing introspection data,
unsupported reachable kinds, conflicting definitions, and dangling references
all map to `schema_unavailable`.
Every schema identifier and named reference is validated against GraphQL Name
syntax before the schema is published or rendered; malformed names also map to
`schema_unavailable` without echoing the rejected value.
Descriptions and deprecation reasons are credential-sanitized before schema
publication. Credential-tainted identifiers are rejected rather than rewritten,
and both text and JSON output remain free of bearer and Authorization-like
values.
Usage/configuration errors (`invalid_regex`, `invalid_endpoint`,
`missing_credential`, and invalid flag combinations) exit 2. Network, auth,
HTTP, response, and schema failures exit 1. Successful full, filtered, and
empty-match results exit 0.

## Compatibility And Migration

- Keep `GraphQLHTTPDocumentClient` and `GraphQLDocumentExecuting` unchanged in
  the first SDK release. Marking or removing them is a separate compatibility
  decision. New code and Riela migrations target `KaibaClient`.
- Existing `kaiba graphql` exit behavior remains: it prints the GraphQL body
  and exits 1 for HTTP/GraphQL failures. The schema subcommand uses the new
  structured error contract without changing execution mode.
- The SDK has no singleton, global endpoint, process-environment lookup, config
  file lookup, database path, or note-root input.
- Riela migration is a downstream work package. This repository delivers the
  complete no-store boundary and fixtures needed for that migration but does
  not edit the Riela repository in this feature.
- This feature changes no web or Tauri file, so web/Tauri gates are not
  required.

## Acceptance Criteria

1. An external SwiftPM target can import only `KaibaClient`, send an arbitrary
   query through an injected transport, and use typed note and long-term-memory
   methods without linking `AppCore`, SQLite, or server code.
2. Bare localhost and remote HTTPS server URLs normalize to `/graphql`; custom
   paths remain unchanged; unsafe/unsupported URLs fail before transport.
3. Authentication is a required choice. Bearer headers are correct, missing
   CLI credentials are actionable, and unauthenticated/remote HTTP policies
   require their explicit opt-ins.
4. Transport, timeout, auth, HTTP, invalid-envelope, GraphQL, decode, and
   schema failures remain distinct and all rendered evidence is redacted.
5. Readiness uses the fixed zero-row query and deterministically distinguishes
   ready, auth failure, connection failure, rejection, and incompatibility.
6. Typed fixtures cover every declared family and the additive GraphQL fields
   support ingest and long-term-memory calls without any local-store fallback.
7. Authenticated admins can use long-term-memory fields; non-admin and ordinary
   unauthenticated requests fail closed.
8. Schema discovery is endpoint-only, authenticated by the same client, and
   returns deterministic full or regex-filtered text/JSON with transitive type
   closure.
9. Invalid regex performs zero requests. Unavailable introspection, connection
   failure, and 401/403 return distinct actionable, redacted failures.
10. Existing local and remote `kaiba graphql` tests pass unchanged.
11. The Swift package builds, all tests pass, SwiftLint passes, and
    `git diff --check` passes.

## Non-Goals

- Persisting endpoints, tokens, instance names, or Riela bindings.
- Secret management or token refresh.
- WebSocket subscriptions, event streaming, batching, caching, automatic
  retry, or offline/local execution.
- Running document conversion, OCR, or translation inside `KaibaClient`.
- Replacing the existing GraphQL executor with a general-purpose GraphQL
  framework.
- Migrating Riela add-ons in this Kaiba-side work package.

## Risks

- The hand-written SDL/introspection bridge can drift from the executor.
  Contract tests must compare every advertised root field and type reference
  with the authoritative SDL and fail on dangling or conflicting definitions.
- Base64 ingest is constrained by the existing HTTP body budget. The client
  must preflight encoded size and return an actionable `invalid_request`;
  streaming or chunked upload is a later protocol, not an implicit fallback.
- GraphQL error messages are server-controlled. Sanitization and truncation
  reduce leakage, but callers should log stable codes and redacted descriptions
  rather than arbitrary response content.
- Long-term memory changes from local unscoped access to remote admin access.
  Dedicated authorization tests are required to prevent either accidental
  denial to Riela's machine credential or exposure to ordinary users.
