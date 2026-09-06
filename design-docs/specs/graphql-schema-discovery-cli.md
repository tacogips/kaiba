# Authenticated GraphQL Schema Discovery CLI

**Status**: Accepted for implementation (2026-09-04)
**Feature ID**: `graphql-schema-discovery-cli`
**Issue**: `local-request:/Users/taco/gits/tacogips/kaiba:Add first-party Kaiba Swift client SDK and schema discovery CLI`
**Parent Design**: `design-docs/specs/kaiba-client-sdk.md`

## Purpose

Add endpoint-only GraphQL schema discovery to Kaiba without changing existing
`kaiba graphql` document execution. A caller authenticates through the public
`KaibaClient`, retrieves the served schema, optionally selects symbols with a
regular expression, and receives deterministic text or JSON. Selected roots
and types include the forward transitive type closure needed to interpret them.

This is the schema-discovery slice of the parent SDK issue. It extends the
accepted `KaibaClient` endpoint/authentication/transport/error boundary and
does not create another HTTP stack.

## Existing Constraints

- `Sources/AppCLI/GraphQLCommand.swift` currently executes exactly one document
  locally or, with `--endpoint`, remotely. That path and its outputs remain
  compatible.
- `GraphQLContractProjector.schemaContract` is authoritative SDL, but the live
  executor does not currently answer standard introspection fields.
- `ServerContracts.routeGraphQL` decides whether to authenticate before normal
  executor dispatch. `__schema` and `__type` must be explicitly authenticated,
  not mistaken for unsupported unauthenticated fields.
- The parent design creates public `KaibaClient` and internal `KaibaCLIKit`
  targets. Schema discovery adds to those targets and keeps the dependency
  direction `KaibaClient -> Foundation`, `AppGraphQL -> AppCore + KaibaClient`,
  `KaibaCLIKit -> KaibaClient`, and `AppCLI -> ... + KaibaCLIKit`.
- Riela must consume the SDK over HTTP(S). Neither the SDK nor this command may
  import or open `NoteService`, SQLite, local note roots, or server stores.

## Goals

- Retrieve live schema from localhost or remote HTTP(S) endpoints through
  `KaibaClient.fetchSchema()` and the same authentication as other SDK calls.
- Require bearer authentication named by environment variable or explicit
  unauthenticated opt-in; require a separate explicit opt-in for non-loopback
  HTTP.
- Filter query fields, mutation fields, and object/input/enum/scalar types by
  optional ICU regular expression.
- Include deterministic forward closure over all referenced types, including
  interface/union dependencies when required by a selected definition.
- Emit canonical SDL-like text and stable, sorted JSON.
- Return actionable typed failures for invalid regex, unavailable
  introspection/schema, connection failure, and authentication failure without
  exposing bearer values or unsafe raw diagnostics.
- Remain portable across the package's supported macOS and Linux builds.

## Non-Goals

- No local or compiled-SDL fallback after endpoint failure.
- No raw-token CLI argument, token persistence, new secret manager, code
  generation, schema diff, watch mode, or interactive explorer.
- No schema member-level filtering: a selected/reachable type is returned as a
  complete definition.
- No guarantee of a general-purpose GraphQL engine. The bounded introspection
  implementation must answer the canonical SDK document and the standard
  `__schema`/`__type` fields it uses; unrelated introspection selections may be
  rejected with GraphQL errors.
- No change to existing `kaiba graphql` local/remote document behavior.

## CLI Contract

```text
kaiba graphql schema --endpoint <url>
  (--api-key-env <NAME> | --allow-unauthenticated)
  [--allow-insecure-http]
  [--filter <regex>]
  [--output text|json]
```

Rules:

- `schema` is recognized only as the first token after the `graphql` command.
  It is never found by scanning arbitrary argument values. Existing inline
  documents, `--file`, stdin, variables, operation names, local execution, and
  remote execution retain current parsing and precedence.
- Top-level command and help resolution consume each recognized option value
  before interpreting command/help tokens. Values such as `--filter serve` and
  `--filter -h` therefore remain filter values and execute schema discovery.
- `--endpoint` is required and is normalized once by `KaibaEndpoint`: an empty
  path or `/` becomes `/graphql`; a non-root path is preserved.
- Endpoints require absolute HTTP(S) URLs with a host. User information, query,
  fragment, control characters, invalid ports, and decoded `.`/`..` path
  segments are rejected. Explicit ports must be non-empty decimal integers in
  `1...65535`; empty, malformed, and integer-overflowing ports fail as
  `invalid_endpoint` before transport.
- HTTP is accepted by default only for exact loopback (`localhost`,
  `127.0.0.0/8`, or `::1`). Non-loopback HTTP additionally requires
  `--allow-insecure-http`; TLS validation is never disabled.
- Exactly one authentication flag is required. `--api-key-env` reads a
  non-empty process-environment value whose name matches
  `[A-Za-z_][A-Za-z0-9_]*`. `--allow-unauthenticated` explicitly selects no
  Authorization header; non-loopback unauthenticated access must also satisfy
  the SDK's explicit remote-unauthenticated policy.
- `--filter` is compiled once with `NSRegularExpression`, with no implicit
  options. Matching is case-sensitive substring matching over Unicode unless
  the expression itself specifies otherwise.
- `--output` defaults to `text`. Duplicate scalar options, positionals, unknown
  flags, missing values, invalid output modes, and conflicting policies are
  usage errors. An absent `--endpoint` is a usage error; a present but
  unparseable endpoint is `invalid_endpoint`.
- A valid filter matching nothing succeeds with exit 0.

## Endpoint, Authentication, And Redaction

`KaibaCLIKit` reads the named environment value immediately before constructing
`KaibaClient`. The SDK represents authentication as the closed choice
`.bearer(KaibaBearerToken)` or `.unauthenticated`, with no default and no
optional-token initializer. The token is in memory only and appears solely in
the outbound Authorization header.

Schema retrieval uses the SDK's normalized endpoint, injectable transport,
finite timeout, no-retry policy, redirect refusal, standard JSON headers, and
typed `KaibaClientError`. No command path looks up a note root, configures a
driver, or retries against a compiled contract. Executable routing selects
`graphql schema` before global note-root/configuration loading, so ambient
`KAIBA_CONFIG_PATH` and `KAIBA_NOTE_ROOT` values cannot affect discovery. The
router recognizes `graphql` only when it is the command token after zero or
more complete `--config VALUE` or `--note-root VALUE` pairs. Those global
options are syntax-checked whether they appear before `graphql` or after
`schema`, but their values remain irrelevant to endpoint-only discovery.
Missing or duplicate global options use the selected schema output mode,
including structured JSON diagnostics.

An authenticated server applies the same bearer decision to introspection as
ordinary supported roots. Only the server's explicit loopback unauthenticated
mode permits credential-less introspection.

Safe diagnostics may contain the validated environment-variable name, HTTP
status, and normalized/redacted endpoint. They never contain token values,
request headers or body, response body, GraphQL server message verbatim, URL
user information/query, `localizedDescription`, or an unsanitized debug value.

## Introspection Contract

`KaibaClient.fetchSchema()` sends one canonical named document,
`KaibaSchemaIntrospectionV1`. It selects:

- query and optional mutation root identities;
- fields, arguments, descriptions, and deprecation metadata;
- type kind/name/description;
- object/interface fields;
- input fields;
- enum values;
- union possible types; and
- list/non-null type references through a fixed wrapper depth of eight.

The schema catalog rejects a deeper wrapper before publication, preventing
silent query truncation. It synthesizes GraphQL built-in `String`, `Int`,
`Float`, `Boolean`, and `ID` scalars when used but not explicitly declared.

The server builds introspection from a deterministic parse of
`GraphQLContractProjector.schemaContract`; it does not maintain a second
handwritten operation/type list. Tests compare the complete SDL and
introspection inventories. Malformed SDL, duplicate definitions, unsupported
declarations, or dangling named references fail closed.

The SDK rejects a missing query root, conflicting duplicates, duplicate
interface/possible-type relationships, invalid wrapper trees, wrapper
references with names, named references with `ofType` values, unsupported
reachable type kinds, absent named references, missing `data.__schema`, and
malformed GraphQL envelopes as `schema_unavailable` (or the parent transport's
`invalid_response` before schema decoding). An absent mutation root is valid.

Introspection meta-types whose names begin with `__` are excluded. `Query` and
`Mutation` are represented by dedicated root arrays, not duplicated among
ordinary types.

## Filter And Closure Semantics

With no filter, all query fields, mutation fields, and non-introspection types
are returned.

With a filter, direct seeds are object/input/enum/scalar types and root fields
whose regular expression matches either candidate:

| Seed | Candidates |
| --- | --- |
| Query field `notes` | `notes`, `Query.notes` |
| Mutation field `createNote` | `createNote`, `Mutation.createNote` |
| Any direct type `Note` | `Note`, `Type.Note` |

Interface and union types are not direct seeds under this feature contract, but
are included when transitively required by a selected/reachable definition.

The forward closure is:

1. Seed all directly matching root fields and types.
2. From a selected root field, follow every argument and result type.
3. From a selected/reachable object or interface, follow every complete field's
   arguments/result and every implemented interface.
4. From an input, follow every input field; from a union, follow every possible
   type; enum and scalar are terminal.
5. Repeat with a visited set until no type is added.

Closure never walks backwards from a type to unrelated roots. Selecting `Note`
does not add every root that references it. A selected/reachable type is emitted
whole; missing dependencies make the schema unavailable instead of truncating
output.

Canonical ordering is independent of endpoint order:

- query and mutation fields by name;
- types by stable kind order `object`, `input`, `enum`, `scalar`, `interface`,
  `union`, then name;
- fields, arguments, input fields, enum values, interfaces, and possible types
  by name.

## Stable Text Output

Text is a canonical SDL-like excerpt rendered from the normalized result:

```graphql
type Query {
  note(noteId: String!): NoteQueryPayload!
}

type NoteQueryPayload {
  result: ControlPlaneResult!
  value: Note
}
```

Only matching root fields are present; dependency closure never invents an
unmatched root field. Query, mutation, then ordinary definitions use the same
kind/name order as JSON, two-space member indentation, a single blank line
between definitions, and no extra blank line before the final newline. Text
omits descriptions. Deprecation uses `@deprecated` and, when present,
`reason: <JSON-escaped string>`, so server-controlled text cannot inject lines
or terminal controls. Object and interface definitions render their sorted
implemented interfaces as `implements A & B`. When nothing matches, stdout is
exactly:

```text
# No schema elements matched.
```

The executable writes one final newline.

## Stable JSON Output

Success is one sorted-key object. Arrays always exist. The endpoint is the
validated normalized/redacted URL; its construction rules prevent embedded
credentials, query secrets, or fragments. Only the fixed `/graphql` path is
published. Every custom path is rendered as one opaque `<redacted>` segment in
successes and failures, independently of authentication mode or whether the
path happens to contain the active bearer.

```json
{
  "endpoint": "https://kaiba.example.com/graphql",
  "filter": "Note|createNote",
  "mutationFields": [],
  "queryFields": [],
  "status": "ok",
  "types": []
}
```

Root fields contain `name`, sorted `arguments`, canonical `type`, and optional
description/deprecation metadata. Type records contain `kind`, `name`, optional
description, and exactly the applicable sorted member arrays (`fields`,
`inputFields`, `enumValues`, `interfaces`, or `possibleTypes`); scalar records
have no member array. `filter` is always present and is `null` when omitted. The
original filter is used for schema selection, but if authentication-aware
diagnostic sanitization changes it, the published JSON value is the opaque
`<redacted>` marker so neither the complete credential nor a co-located token
substring is retained. JSON keys are sorted by the encoder. Empty match uses
the same shape with empty arrays.

## Failures And Exit Behavior

Success writes text or JSON to stdout and leaves stderr empty. Failure writes
the selected text or JSON diagnostic to stderr and leaves stdout empty. If a
valid `--output json` was parsed, the failure shape is:

```json
{
  "code": "auth_failed",
  "endpoint": "https://kaiba.example.com/graphql",
  "message": "Kaiba rejected the configured credential.",
  "nextAction": "Check the API key environment variable and endpoint, then retry.",
  "status": "error"
}
```

Argument validation preserves any valid `--output json` selection even when a
different option is unknown, duplicate, missing a value, or conflicts with
another option. Parser failure before a valid output mode is known uses one
fixed code-prefixed text line. Fixed messages and next actions are produced
locally. Runtime failures report the validated normalized endpoint; invalid or
not-yet-validated endpoint input is reduced to redacted safe output. Every
published endpoint field applies decoded-path active-token redaction when a
credential is available, including local-validation and runtime failures.

Runtime diagnostics use this local, versioned copy and never interpolate
`KaibaClientError.description`, URL loading codes, HTTP status text, GraphQL
messages, or schema-validation reasons:

| Code | Message | Next action |
| --- | --- | --- |
| `auth_failed` | `Kaiba rejected the configured credential.` | `Check the API key environment variable and endpoint, then retry.` |
| `connection_failed` | `Kaiba could not reach the configured endpoint.` | `Check the endpoint and network path, then retry.` |
| `http_failed` | `Kaiba returned an unsuccessful HTTP response.` | `Check the Kaiba server status and endpoint, then retry.` |
| `invalid_response` | `Kaiba returned an invalid GraphQL response.` | `Verify the endpoint targets a compatible Kaiba GraphQL server.` |
| `schema_unavailable` | `Schema introspection is unavailable or invalid.` | `Enable authenticated introspection or update the server.` |

| Exit | Code | Condition |
| --- | --- | --- |
| 2 | `invalid_usage` | Missing/conflicting/unknown command arguments |
| 2 | `invalid_endpoint` | Endpoint or transport-security policy invalid |
| 2 | `invalid_regex` | ICU regex compilation fails; no request is sent |
| 2 | `missing_credential` | Named environment value missing/empty; no request is sent |
| 1 | `auth_failed` | HTTP 401 or 403 |
| 1 | `connection_failed` | DNS, refusal, TLS, timeout, or cancellation before response |
| 1 | `http_failed` | Other non-success HTTP response, status only |
| 1 | `invalid_response` | Non-JSON or invalid GraphQL response envelope |
| 1 | `schema_unavailable` | GraphQL rejects introspection or schema validation fails |

Invalid regex output never includes the regex engine's raw error. Transport
output never includes `localizedDescription`. Schema output never includes raw
GraphQL messages or response data. Redaction tests place sentinel values in
tokens, Authorization-like response text, URL components, and multiline errors
and assert absence from all descriptions, text, JSON, stderr, and stdout.
Authorization assignments are conservatively consumed through the next comma,
semicolon, newline, or diagnostic boundary and replaced by one redaction
marker. Quoted, bracketed, and parenthesized delimiters are not trusted as
boundaries, so escaped or missing closing delimiters cannot expose suffixes.
Quoted and backslash-serialized Authorization keys are recognized before
schema metadata is published. Identifier tokens are normalized across case and
separator variants with Unicode-aware prefix handling; any key whose normalized
identifier ends in `authorization` or `authorizationheader` is redacted,
including `proxy_authorization`, `proxyAuthorizationHeader`, Unicode-prefixed
aliases, and HTTP-prefixed aliases.
Introspection descriptions and deprecation reasons are sanitized before SDK
publication; identifiers or references that would change under credential
redaction fail as `schema_unavailable`. Retained schema-unavailable reasons use
the same sanitizer. Missing credentials use the credential-specific next action
in both human and JSON diagnostics.
Every published type, field, argument, input field, enum value, interface,
possible type, and named type reference must match GraphQL Name syntax
`[_A-Za-z][_0-9A-Za-z]*`; malformed introspection fails as
`schema_unavailable` before selection or rendering.

## Compatibility

- Existing `GraphQLHTTPDocumentClient` and `GraphQLDocumentExecuting` remain
  source-compatible; new endpoint code uses `KaibaClient`.
- `kaiba graphql schema ...` is the only new parse branch. `kaiba graphql`
  document/file/stdin modes keep their body, exit, and local/remote behavior.
- Existing `AppCore` and `AppGraphQL` public API spellings remain compatible.
  Introspection support is additive to the server.
- No web/Tauri behavior changes.

## Acceptance Criteria

- Authenticated localhost and remote endpoints return the same normalized
  result for the same served schema; loopback HTTP and explicitly opted-in
  remote HTTP follow the parent SDK policy.
- Missing auth choice or missing named credential fails before transport;
  explicit unauthenticated mode sends no Authorization header.
- Bearer values occur only in the outbound header and never in diagnostics or
  persistence. HTTP 401/403 maps to `auth_failed`.
- Endpoint failure never falls back to local/compiled schema or store APIs.
- Optional regex selects the specified root/type candidates; valid no-match is
  successful; invalid regex is actionable and request-free.
- Forward closure handles arguments, results, wrappers, cycles, inputs,
  interfaces, unions, enums, scalars, shared dependencies, and built-ins, while
  never reverse-adding roots.
- Shuffled equivalent introspection responses produce byte-identical text and
  JSON.
- Unavailable/disabled/malformed introspection, bad JSON, connection failure,
  and auth failure remain distinct, actionable, non-zero, and redacted.
- Existing local and remote `kaiba graphql` tests pass, including a document or
  argument containing the word `schema` that must not select the subcommand.

## Review Record

- Self-review: `accepted_after_corrections`. It made endpoint/auth policy,
  output channels, empty matches, failure codes, ordering, closure direction,
  built-in scalars, and finite wrapper depth explicit.
- Independent review: `accepted_after_corrections`. High integration finding:
  the first draft conflicted with the accepted parent SDK design on command
  path, target/API names, HTTP opt-in, introspection breadth, filter candidates,
  and output shape. All were aligned to `kaiba-client-sdk.md`. Mid security
  finding: introspection could bypass existing auth classification; explicit
  meta-field authentication and regression tests are now required.
- Decision: accepted with no remaining high/mid findings.

## Remaining Risks

- The bounded introspection executor is sufficient for the SDK contract but is
  not a replacement for a general GraphQL implementation.
- The SDL parser must be extended before the authoritative contract adopts
  syntax outside its supported subset.
- The feature cannot implement independently if the sibling SDK lands an
  incompatible endpoint/auth/error API; integration must resolve that boundary
  rather than duplicate it.
