# P3: connection settings UI and reachability tests

planId: `tauri-client-connection-p3-settings-ui`. Wave 2; it depends on P1
(`tauri-client-connection-p1-endpoint-store`) and P2
(`tauri-client-connection-p2-connection-probe`).
Status: accepted in session opus-luna-design-and-implement-review-loop-session-481
(test-integrity and adversarial review). Its changes are in the working tree.
Do not redispatch; the dispatch manifest lists it under `acceptedDependencies`.
Index and shared rules: `impl-plans/active/tauri-client-connection.md`.
Design: `design-docs/specs/tauri-client-apps.md`, sections "Connection
settings", "Switching and per-account state", "Test connection", "Recent
remote endpoints" and "Reachability".

## Intent and context

`web/src/components/ServerConnectionSettings.tsx` (80 lines) is the only
connection UI. `ConfigView.tsx:88` renders it in full, and `LoginView.tsx:70`
renders it with `compact`. Extend it with the active connection line, Test
connection, the Recent servers picker and the plain-`http` warning, using
the helpers from P1 and P2. Then prove that the form is reachable from the
error, unreachable and unauthenticated states.

## writePaths

- `web/src/components/ServerConnectionSettings.tsx`
- `web/src/components/ServerConnectionSettings.integration.tsx`
- `web/src/views/ConnectionReachability.integration.tsx` (new)
- `web/src/views/ConfigView.tsx`. Edit it only if the reachability test
  proves that ConfigView fails to render the connection form without a
  server. The expected outcome is no change.
- `tmp/tauri-client-connection/P3`
- `web/node_modules/.vite`, an artifact root for the vitest cache only.

## Consumed contracts (do not redefine; import them)

- From `../notes/serverEndpoint` (P1): `readRecentServerEndpoints`,
  `recordRecentServerEndpoint`, `isUnencryptedRemoteEndpoint`,
  `activeConnectionLabel` and `recentServerEndpointsStorageKey`. The last is
  for tests.
- From `../notes/serverProbe` (P2): `testServerConnection`,
  `describeServerProbe` and `type ServerProbeResult`.

## File-level changes: `ServerConnectionSettings.tsx`

- DOM order constraint: the existing tests use
  `container.querySelector('select')` for the mode select and
  `querySelector('input')` for the URL field. So the mode select must stay
  the first `<select>`, and the URL `<input type="url">` must stay the first
  `<input>`. The Recent servers select therefore goes after both.
- **Active connection line**: a direct-child `<p class="server-connection-active">`
  with the text `Active: {activeConnectionLabel()}`. Compute it once at
  mount, because it describes what is in effect, which only changes after a
  reload. Render it in both the compact and full forms, in both modes. Do
  not derive it from the `mode()` or `endpoint()` form signals.
- **Test connection**: a `<button type="button" class="secondary">` inside
  `.server-connection-row`, labeled `Test connection` (visible text and
  `aria-label`). It renders only when `mode() === 'remote'`, and it is
  disabled while a probe or a save is busy. On click:
  1. Clear the previous probe text and bump a generation counter.
  2. Call `testServerConnection(endpoint())`.
  3. If the generation still matches, set the probe text to
     `describeServerProbe(result)`. If the call threw, set it to the error
     message (the validator's message).
  The probe text renders as a direct-child
  `<p class="server-connection-probe" role="status">`. Do not use
  `role="alert"`, because that is reserved for the save failure the existing
  tests query. Typing in the URL field clears the probe text and bumps the
  generation, so a stale result never sits beside a different URL. A probe
  never saves, records or reloads.
- **Recent servers**: shown only when `mode() === 'remote'` and the list
  read at mount by `readRecentServerEndpoints()` is non-empty. Use a
  `<label>Recent servers <select aria-label="Recent servers">` with a first
  placeholder `<option value="">Choose a recent server</option>`, then one
  option per origin. On change with a non-empty value: set `endpoint(value)`,
  clear the probe text, and reset the select to `""`. It does not save or
  reload.
- **Plain-`http` warning**: a direct-child `<p class="server-connection-warning">`
  with the text `This server uses plain HTTP; the API key travels
  unencrypted.`. It shows when
  `mode() === 'remote' && isUnencryptedRemoteEndpoint(endpoint())`. It is
  reactive, and it never blocks saving.
- **Save**: keep the current order (`saveServerEndpoint`, then
  `saveConnectionMode`, then reload). For Remote only, call
  `recordRecentServerEndpoint(normalized)` after `saveConnectionMode`
  resolves and before `window.location.reload()`, where `normalized` is the
  return value of `saveServerEndpoint`. A Local save records nothing, and a
  failed save records nothing.
- Keep `props.compact`, the ids `login-server-endpoint` and
  `server-endpoint`, the native-only `<Show when={isTauriRuntime()}>` gate
  and the section chrome exactly as they are.
- Styling: rely on the existing `.server-connection > p` and `> label` rules
  in `web/src/chatbook.css`. Do not edit any CSS file.

## Patterns to imitate

- `ServerConnectionSettings.tsx:save` for the busy/failure signals and the
  error-to-message mapping.
- `web/src/views/ChatbookView.integration.tsx` (the `client()` stub,
  `settle()`, rendering with `<AppStoreProvider options={{ client }}>`,
  clicking `button[aria-label="Settings"]`) for the reachability test.
- `web/src/notes/localConnection.integration.tsx` for `vi.hoisted` plus
  `vi.mock('@tauri-apps/plugin-http')` and `vi.mock('@tauri-apps/api/core')`.
- `ServerConnectionSettings.integration.tsx` for `installStorage`,
  `withTauriRuntime`, `reloadSpy`, `mount` and `submit`. Reuse them, and do
  not rewrite the existing tests.

## Pitfalls

- Do not call `fetch` or the HTTP plugin directly from the component; the
  only network path is `testServerConnection`.
- Do not touch credential keys anywhere in the component.
- In `ServerConnectionSettings.integration.tsx`, add a hoisted
  `vi.mock('@tauri-apps/plugin-http', () => ({ fetch: http.fetch }))`
  with a per-test scripted `http.fetch`. Reset it in `beforeEach`. The
  existing six tests must still pass without modification. Their bodies
  stay unedited, and only shared mocks and imports are added.
- In `ConnectionReachability.integration.tsx`, the Tauri marker makes the
  note-events feed go through `serverRequest`, which imports the HTTP
  plugin. Mock it with a fetch that never resolves. Set
  `kaiba-connection-mode` to `remote` and an endpoint in the installed
  storage, so nothing calls `start_local_server`. Stub any client methods
  that ConfigView's children call (`userAgentCredential` and the
  search-engine settings calls) so that they reject. The test proves the
  form renders despite them.
- Solid's `value={endpoint()}` updates the input's value property. After a
  recent pick, assert `input.value`.
- Keep the component under 1000 lines. It should end up around 160.

## Tests to add

In `web/src/components/ServerConnectionSettings.integration.tsx`. Each case
is a situation followed by its expected outcome:

- Stored mode `remote` and endpoint `https://notes.example.com:8443`: the
  `.server-connection-active` text is `Active: Remote — notes.example.com:8443`.
  With `{ compact: true }` the same line is present.
- Stored mode `local`: the active line is `Active: Local — this Mac`, and
  Test connection and Recent servers are absent.
- Test connection with healthz ok and graphql 401, where the storage holds
  `serverCredentialKey('https://notes.example.com')='own'` and
  `serverCredentialKey('https://other.example')='foreign'`, and the field is
  `https://notes.example.com`:
  - the status text contains `Sign-in required` and `saved key`;
  - the `http.fetch` targets are exactly `https://notes.example.com/healthz`
    and `https://notes.example.com/graphql`;
  - no call has an `Authorization` header;
  - the storage keys `kaiba-server-endpoint`, `kaiba-connection-mode` and
    `kaiba-recent-server-endpoints` are unchanged;
  - the reload count is 0.
- Test connection with `http.fetch` rejecting: the status text is
  `The server could not be reached.`
- Test connection with healthz 200 `{"service":"other","status":"ok"}`: the
  status text contains `not a kaiba server`.
- Test connection with field `https://notes.example.com/path`: the status
  text contains `path`, and `http.fetch` is not called.
- Recent list preset `["https://a.example","https://b.example"]` in mode
  remote, then choose `https://b.example`:
  - the input value is `https://b.example` and the reload count is 0;
  - after submit, the reload count is 1 and
    `JSON.parse(localStorage.getItem(recentServerEndpointsStorageKey))`
    equals `["https://b.example","https://a.example"]`.
- Empty recent list, then save `https://notes.example.com/`: the recent list
  becomes `["https://notes.example.com"]`, and no Recent servers select is
  rendered before the save.
- A Local save (as in the existing local test): the recent key stays
  absent.
- An invalid URL submit: the recent key stays absent, matching the existing
  validation test.
- The field `http://192.168.1.20:8787` shows `.server-connection-warning`.
  The fields `http://127.0.0.1:8787` and `https://192.168.1.20` do not.
  Submitting `http://192.168.1.20:8787` still saves and reloads.

In `web/src/views/ConnectionReachability.integration.tsx` (new), with
`ChatbookView` mounted inside `AppStoreProvider`, the Tauri marker on,
storage remote, and the HTTP plugin and core mocked:

- The client's `tags`, `tagClasses`, `notebooks` and `appSetting` reject
  with `new NoteTransportError('Failed to fetch', 'network')`. After
  settling, the shell renders (`button[aria-label="Settings"]` exists).
  Clicking it shows `.config-view form.server-connection`, which contains
  `.server-connection-active` and a `Test connection` button.
- The client rejects with `NoteTransportError(..., 'http', 401)`: the
  `.login-view form.server-connection.compact` exists and contains the
  active line.

## Verification (tee'd into `tmp/tauri-client-connection/P3/`)

- `cd web && bunx vitest run src/components/ServerConnectionSettings.integration.tsx
  src/views/ConnectionReachability.integration.tsx`: exit 0. The pass count
  is at least 6 (existing) plus 11 (new) plus 2 (reachability), all passing.
- `cd web && bunx vitest run src/notes/localConnection.integration.tsx
  src/views/ChatbookView.integration.tsx src/views/CaptureView.integration.tsx`:
  exit 0 with a positive count. These are regression checks on the
  surfaces that embed the form.
- `cd web && bun run typecheck`: exit 0. (Corrected gate: never `bunx tsc
  --noEmit -p web` from the repository root.)
- `cd web && bunx eslint src/components/ServerConnectionSettings.tsx
  src/components/ServerConnectionSettings.integration.tsx
  src/views/ConnectionReachability.integration.tsx`: exit 0.

## Done criteria

- `git diff --quiet -- web/src/views/ConfigView.tsx` succeeds, unless the
  progress log records the failing reachability test that justified an
  edit.
- `grep -n "Authorization\|kaiba-note-bearer" web/src/components/ServerConnectionSettings.tsx`
  matches nothing.
- `git diff -- web/src/components/ServerConnectionSettings.integration.tsx`
  shows no removed lines inside the six pre-existing `test(...)` bodies.
- Each file is under 1000 lines.
- `tmp/tauri-client-connection/P3/progress.md` ends with `status: done`.
