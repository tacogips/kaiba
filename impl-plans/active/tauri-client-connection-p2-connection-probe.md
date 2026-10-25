# P2: Test connection probe

planId: `tauri-client-connection-p2-connection-probe`. Wave 1, with no
dependencies.
Index and shared rules: `impl-plans/active/tauri-client-connection.md`.
Design: `design-docs/specs/tauri-client-apps.md`, section "Test connection".
Decisions D3, D4 and D5 are in
`design-docs/user-qa/tauri-client-connection-20261025.md`.

## Intent and context

Add a pure, injectable probe that tells a user whether an unsaved remote URL
is a reachable kaiba server, before they switch to it. Server facts, checked
in source:

- `GET /healthz` is unauthenticated and answers 200 with the top-level JSON
  `{"service":"kaiba","status":"ok"}`. See
  `Sources/AppServer/ServerContracts.swift:193-197`; the body is encoded
  directly as the object at `Sources/AppServer/KaibaHTTPContracts.swift:135`.
- `POST /graphql` answers 401 without a valid bearer
  (`Sources/AppServer/NoteAPIAuthenticating.swift:noteAPIUnauthorizedResponse`),
  and 200 when the server runs with `--allow-unauthenticated`.

## writePaths

- `web/src/notes/serverProbe.ts` (new)
- `web/src/notes/serverProbe.test.ts` (new)
- `tmp/tauri-client-connection/P2`

## Exact contract (consumed by P3; names and signatures are fixed)

```ts
export type ServerProbeResult =
  | { kind: 'connected' }
  | { kind: 'auth-required'; savedCredential: boolean }
  | { kind: 'server-error'; status: number }
  | { kind: 'not-kaiba' }
  | { kind: 'unreachable' }
export type ProbeFetch = (input: string, init: RequestInit) => Promise<Response>
export const serverProbeTimeoutMs = 5000
export async function testServerConnection(
  candidate: string,
  options?: { fetch?: ProbeFetch; storage?: Pick<EndpointStorage, 'getItem'>; timeoutMs?: number },
): Promise<ServerProbeResult>
export function describeServerProbe(result: ServerProbeResult): string
```

Import only these existing symbols from `./serverEndpoint`:
`normalizeServerEndpoint`, `assertServerOrigin`, `serverCredentialKey` and
`type EndpointStorage`. Do not edit `serverEndpoint.ts`; P1 owns it.

Algorithm:

1. `const origin = normalizeServerEndpoint(candidate)`. Let the validator's
   `Error` propagate (throw it), and send nothing. P3 shows its message.
2. Pick the fetch: `options.fetch`, or else the result of
   `(await import('@tauri-apps/plugin-http')).fetch`. Use a dynamic import,
   as `serverEndpoint.ts:serverRequest` does, so the web bundle carries no
   static Tauri import.
3. Healthz: let `target = ${origin}/healthz` and call
   `assertServerOrigin(target, origin)`. Then fetch with method `GET`,
   headers `{ Accept: 'application/json' }`, and the signal from a fresh
   `AbortController` that is aborted after `timeoutMs ?? serverProbeTimeoutMs`.
   Clear the timer in `finally`. The outcome is as follows:
   - A thrown fetch error (network failure or abort) gives `unreachable`.
   - A status other than 200 gives `not-kaiba`.
   - A body that fails to parse as JSON, or does not have
     `service === 'kaiba' && status === 'ok'`, gives `not-kaiba`.
4. GraphQL: let `target = ${origin}/graphql` and call
   `assertServerOrigin(target, origin)`. POST with headers
   `{ 'Content-Type': 'application/json', Accept: 'application/json' }`,
   body `JSON.stringify({ query: '{ __typename }' })`, and its own timeout
   controller. The outcome is as follows:
   - A thrown fetch error gives `unreachable`.
   - 200 gives `connected`.
   - 401 gives `auth-required`, with `savedCredential` set to
     `Boolean(storage?.getItem(serverCredentialKey(origin)))`.
   - Anything else gives `server-error` with the status.
   The response body is not read.
5. Storage default: when `options.storage` is absent, use a guarded
   `globalThis.localStorage` access. Wrap it in try/catch and use `undefined`
   on failure, mirroring `serverEndpoint.ts:availableEndpointStorage` but
   needing only `getItem`. A missing storage means `savedCredential: false`.

`describeServerProbe` returns fixed English sentences. P3's tests match these
substrings, so keep them:

- `connected`: `'Connected to a kaiba server.'`
- `auth-required`: `'Kaiba server found. Sign-in required.'`, followed by
  `' A saved key for this server will be used after connecting.'` when
  `savedCredential` is true, or `' Paste an API key after connecting.'`
  when it is false.
- `server-error`: `` `Kaiba server found, but it answered HTTP ${status}.` ``
- `not-kaiba`: `'This address answered, but it is not a kaiba server.'`
- `unreachable`: `'The server could not be reached.'`

## Patterns to imitate

- `web/src/notes/serverEndpoint.ts:serverRequest` for the dynamic import of
  `@tauri-apps/plugin-http`.
- `web/src/notes/serverEndpoint.test.ts`, which uses bun:test with plain
  in-memory fakes.

## Pitfalls (what not to do)

- Never set an `Authorization` header, never read a bearer value into a
  request, and never route through `serverRequest`, `NoteGraphQLClient` or
  `resolveServerRequest`. Those resolve against the saved endpoint and attach
  the current bearer.
- Do not consult the bare pre-scoping key `kaiba-note-bearer`. Only
  `serverCredentialKey(origin)` counts, and it is checked only for presence.
- The probe never writes storage: no endpoint, mode, recent-list or
  credential writes.
- Abort must map to `unreachable` and must not surface as a thrown error. Any
  fetch rejection maps to `unreachable`. Only a validator error escapes.
- Do not add a third request, retries or redirect handling.

## Tests to add (`web/src/notes/serverProbe.test.ts`, bun:test, injected fetch)

The fake fetch records `(input, init)` and returns a scripted `Response` or
rejects. Each case is a situation followed by its expected outcome:

- healthz 200 `{"service":"kaiba","status":"ok"}`, graphql 200: `connected`.
  Exactly two calls are made, to
  `https://notes.example.com/healthz` (GET) and
  `https://notes.example.com/graphql` (POST, body `{"query":"{ __typename }"}`).
- healthz ok, graphql 401, with the storage holding
  `kaiba-note-bearer:https://notes.example.com` and also
  `kaiba-note-bearer:https://other.example`: the result is
  `{ kind: 'auth-required', savedCredential: true }`. For every call,
  `new Headers(init.headers).has('Authorization')` is false, and no call
  body or header contains either stored token string.
- healthz ok, graphql 401, empty storage: `savedCredential: false`.
- healthz ok, graphql 503: `{ kind: 'server-error', status: 503 }`.
- healthz 404: `not-kaiba`, and graphql is not called.
- healthz 200 with the body `'<html>'`: `not-kaiba`.
- healthz 200 `{"service":"other","status":"ok"}`: `not-kaiba`.
- fetch rejects `TypeError('network')` on healthz: `unreachable`.
- healthz ok, then graphql rejects: `unreachable`.
- fetch never resolves until its signal aborts, with `timeoutMs: 10`: the
  result is `unreachable` within 1 s.
- candidate `'ftp://x'` or `'https://x.example/p'`: the promise rejects with
  the validator message, and fetch is not called.
- candidate `'https://Notes.Example.com/'`: the targets use the normalized
  `https://notes.example.com`.
- `describeServerProbe` returns the five pinned sentences, including both
  `savedCredential` variants.

## Verification (tee'd into `tmp/tauri-client-connection/P2/`)

- `cd web && bun test src/notes/serverProbe.test.ts`: exit 0 and a pass
  count of at least 12.
- `bunx tsc --noEmit -p web`: exit 0. Failures that point only at peer files
  are recorded as peer drift.
- `cd web && bunx eslint src/notes/serverProbe.ts src/notes/serverProbe.test.ts`:
  exit 0.

## Done criteria

- `grep -n "Authorization" web/src/notes/serverProbe.ts` matches nothing.
- `grep -c "^import .*@tauri-apps" web/src/notes/serverProbe.ts` prints 0
  (the import is dynamic only).
- Both new files exist, each under 1000 lines.
- `tmp/tauri-client-connection/P2/progress.md` ends with `status: done`.
