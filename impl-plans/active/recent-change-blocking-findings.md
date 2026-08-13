# Recent-Change Blocking Findings

**Status**: Ready for implementation
**Workflow Mode**: `issue-resolution`
**Workflow Execution**: `codex-design-and-implement-review-loop-session-690`
**Review Range**: `2ba3ed09693c6986c5c03b3f32b91cad8a1f5f56..b076a33`
**Issue Reference**: None; workflow-only issue resolution
**Codex Agent References**: None
**Accepted Design Review**: `comm-002213` (no findings; no revision required)
**Design References**:

- `design-docs/specs/tag-detail-pane.md` (T4, T6, T11, Data Flow, Verification)
- `design-docs/specs/ai-agent-integration.md` (AI8, verification item 10)
- `impl-plans/completed/tag-detail-pane.md` (original implementation traceability)

## Purpose

Resolve only the five mid-severity findings from the recent-change review:
preserve every active agent reply stream through terminal delivery; make tag-memo
creation idempotent under concurrency; enforce the complete tag-context budget in
UTF-8 bytes; load every tagged-note page; and prevent an earlier tag request from
leaving stale links visible or clickable after selection changes.

Unrelated dirty-worktree changes must be preserved. This plan does not redesign
the accepted tag pane, agent transport, GraphQL pagination contract, or database
schema.

## Deliverables

- [ ] Active agent reply streams cannot be evicted, and terminal retention returns
      to its configured bound after active streams finish.
- [ ] Concurrent tag-memo creation returns one notebook and emits creation side
      effects once.
- [ ] Tag context never exceeds `limitBytes`, including heading and separators,
      and truncation ends on a valid UTF-8 scalar boundary.
- [ ] Tag Links loads all offset pages beyond 200 notes and rejects non-progress.
- [ ] A tag change immediately clears old links and invalidates all older requests.
- [ ] Focused regression coverage and the complete Swift/web verification matrix pass.

## Tasks

### TASK-001: Preserve active reply streams and bound terminal cleanup

**Write Scope**:

- `Sources/AppServer/AgentReplyStreamHub.swift`
- `Tests/AppServerTests/AgentReplyStreamHubTests.swift`

**Dependencies**: None

**Parallelizable**: Yes, with TASK-002 and TASK-003; write scopes are disjoint.

**Deliverables**:

- Associate each pending poll request with its turn from registration through
  response return; publish/finish wakes only that turn's waiters, while response
  completion, timeout, or cancellation unregisters the request.
- At terminal transition, capture all in-flight poll requests as delivery
  obligations, including a request woken by an earlier chunk whose response has
  not returned. Protect the stream until each captured poll returns its buffered
  tail and terminal status, or is cancelled.
- Start a 35-second first-terminal-delivery grace at terminal transition, based on
  the route's 30-second maximum poll timeout plus five seconds for the next poll.
  Satisfy grace when one terminal snapshot returns or its deadline expires;
  cancellation releases its request obligation but does not count as delivery.
- Make only obligation-free, grace-satisfied terminal streams eligible for bounded
  late-poller retention, evicted by oldest terminal transition. Never
  capacity-evict an active or still-protected terminal stream.
- Permit temporary growth above `maximumStreams` while active streams, delivery
  obligations, or first-delivery grace account for the excess. Trigger cleanup on
  finish, poll completion/cancellation, hub access, and a scheduled grace deadline
  so no-poller entries expire without unrelated traffic.
- Keep buffered chunk ordering, cursor behavior, persisted terminal status, and
  immediate snapshots for terminal streams that remain retained.
- Add actor-level concurrent-capacity coverage that starts more than 64 streams,
  installs pollers, publishes identifiable chunks, and finishes every stream,
  proving every waiting poll receives its chunks and terminal status before its
  stream becomes evictable. Separately verify turn-specific wake-up, cancellation,
  the between-polls race, temporary excess retention, and oldest-first cleanup of
  eligible terminal entries. Inject or otherwise control time so the 35-second
  no-poller expiry is deterministic and does not slow the test suite.

**Completion Criteria**:

- [ ] No active turn is removed at or above capacity.
- [ ] Every poll waiting when an over-capacity stream finishes returns its buffered
      tail and terminal state unless explicitly cancelled.
- [ ] A terminal stream remains protected while any captured delivery obligation
      exists; unrelated streams cannot wake or discharge that obligation.
- [ ] A terminal stream with no in-flight poll remains protected until one terminal
      snapshot is delivered or its 35-second grace expires; cancellation is not delivery.
- [ ] After obligations discharge and grace is satisfied, eligible terminal retention
      is at most `maximumStreams` and oldest-terminal-transition eviction is deterministic.
- [ ] `swift test --filter AgentReplyStreamHubTests` passes.

### TASK-002: Make tag-memo creation atomic and context truncation byte-correct

**Write Scope**:

- `Sources/AppCore/NoteService+TagDetail.swift`
- `Tests/AppCoreTests/NoteTagDetailTests.swift`
- Narrow existing AppCore notebook helpers only if required to keep lookup,
  insertion, kind assignment, metadata persistence, and auto-action enqueueing
  inside one serialized transaction. Change-event publication and queued-action
  dispatch remain outside the transaction and run only after a successful commit.

**Dependencies**: None

**Parallelizable**: Yes, with TASK-001 and TASK-003; do not edit their files.

**Deliverables**:

- Put tag lookup, existing memo-notebook lookup, and conditional creation behind
  one database serialization/transaction boundary supported by the existing
  `SQLiteDatabase.transaction` and driver conventions. Do not call the public
  `createNotebook` API from inside `driver.withDatabase`; use a database-scoped
  helper so the operation does not re-enter the connection lock.
- Ensure only the winning creation path inserts the notebook, assigns its
  `notebook-kind:tag-memo` kind, records `kaibaTagMemo.subjectTagId`, and enqueues
  any notebook-created auto actions. Return a creation outcome from the transaction,
  then publish the change event and dispatch queued actions once after commit;
  concurrent callers return the same notebook without duplicate side effects.
- Avoid a schema change unless repository inspection proves serialization cannot
  guarantee the accepted invariant; document any such discovery before expanding
  scope.
- Account for heading, separators, and occurrence markdown within one
  `limitBytes` UTF-8 budget. Produce the longest valid scalar-aligned prefix that
  fits, including for non-positive and heading-smaller budgets.
- Add deterministic concurrency coverage for a shared tag and byte-boundary tests
  for ASCII, Japanese, and multi-byte scalar content at and beyond the limit.

**Completion Criteria**:

- [ ] Concurrent callers observe one notebook id, one persisted notebook, one kind
      assignment, one committed auto-action sequence, and one post-commit
      `notebook-created` change event.
- [ ] Failure rolls back the whole creation operation and exposes no partial memo notebook.
- [ ] `tagContextMarkdown` output UTF-8 count is never greater than `limitBytes`.
- [ ] Truncated output remains valid UTF-8 and scalar-aligned for all tested budgets.
- [ ] `swift test --filter NoteTagDetailTests` passes.

### TASK-003: Load every tag occurrence and invalidate stale link generations

**Write Scope**:

- `web/src/components/TagPane.tsx`
- `web/src/notes/client.ts` only if the page-loop boundary belongs in the client
- `web/src/notes/tagOccurrences.ts` and
  `web/src/notes/tagOccurrences.test.ts` for a focused DOM-free loader/controller,
  or an equivalently focused existing test module

**Dependencies**: None

**Parallelizable**: Yes, with TASK-001 and TASK-002; write scopes are disjoint.

**Deliverables**:

- Fetch `notesByTag(tagName, offset)` repeatedly at the API maximum page size of
  200 until a short page proves exhaustion; advance offsets by the received page
  length and treat a full page with no progress as an error.
- On tag id/name change, absent detail, or pane closure/unmount, increment the
  request generation and clear the prior occurrence set before awaiting network
  results, leaving no old occurrence button clickable.
- Check the captured tag identity and generation after every awaited page and
  before publishing the aggregate; an older request must never append or restore data.
- Preserve grouping, notebook titles, loading/error states, and return-stack
  navigation for the current tag.
- Add deterministic tests for 201+ results across pages, exact multiples of 200,
  non-progress/error behavior, and rapid A-to-B switching where A resolves last.

**Completion Criteria**:

- [ ] Result sets larger than 200 contain every occurrence exactly once.
- [ ] Exhaustion and offset advancement follow the accepted GraphQL contract.
- [ ] Old-tag links disappear synchronously and cannot reappear or navigate.
- [ ] Focused tag-occurrence tests pass under `bun run test`.

### TASK-004: Integrate, verify, and close plan traceability

**Write Scope**:

- `impl-plans/active/recent-change-blocking-findings.md`
- `impl-plans/completed/tag-detail-pane.md` only for a concise resolution entry
- Accepted design documents only if implementation uncovers a required behavioral
  change; such a change requires design review before implementation continues

**Dependencies**: TASK-001, TASK-002, TASK-003

**Parallelizable**: No; this is the integration and exit gate.

**Deliverables**:

- Review the combined diff against the five findings and confirm that no unrelated
  user changes were reverted, normalized, or included in the fix scope.
- Run focused checks first, then full Swift lint/tests and complete web verification.
- Record commands, outcomes, test counts where available, the pre-existing
  `large_tuple` SwiftLint warning if it remains, and any residual environment
  limitation in the Progress Log.
- Add a resolution note to the original completed tag-pane plan, mark every item
  here complete, and move this plan to `impl-plans/completed/` only after all exit
  criteria pass.

**Completion Criteria**:

- [ ] All five review findings have code and deterministic regression coverage.
- [ ] `mise run lint` passes, allowing only the documented pre-existing warning.
- [ ] `mise run test` passes all Swift suites.
- [ ] `bun run typecheck && bun run test && bun run lint && bun run build` passes
      from `web/`.
- [ ] `git diff --check` reports no whitespace errors.
- [ ] The final diff remains limited to the five findings, their tests, and plan traceability.

## Verification

Run from the repository root unless a command says otherwise:

```bash
swift test --filter AgentReplyStreamHubTests
swift test --filter NoteTagDetailTests
mise run lint
mise run test
cd web && bun run typecheck && bun run test && bun run lint && bun run build
git diff --check
```

If Bun task resolution is unavailable, run the accepted fallback from `web/`:

```bash
./node_modules/.bin/tsc --noEmit && ./node_modules/.bin/vitest run && ./node_modules/.bin/eslint . && ./node_modules/.bin/vite build
```

## Risks and Controls

- Database locking must not deadlock by nesting a public `NoteService` operation
  inside `driver.withDatabase`; use a database-scoped helper for the atomic path.
- In-memory serialization alone may not protect multiple service instances or
  processes; prefer the existing database transaction boundary and test through
  separate concurrent callers where supported.
- Temporary stream growth is intentional for active streams and terminal streams
  with delivery obligations or unsatisfied first-delivery grace; cleanup on poll
  completion/cancellation and the scheduled grace deadline bounds late-poller retention.
- Pagination must not publish partial data as success after a failed or stalled page.
- Generation checks must cover every await and the no-tag path, not only the final response.

## Progress Log

- 2026-08-13: Plan created after Step 3 accepted
  `design-docs/specs/tag-detail-pane.md` and
  `design-docs/specs/ai-agent-integration.md`. Baseline contains unrelated user
  changes; implementation must preserve them. No implementation changes made in
  this planning step.
- 2026-08-13: Step 3 acceptance `comm-002213` confirmed no design findings,
  unresolved user decisions, or Codex-reference obligations. Plan inspection
  clarified that tag-memo database work is transactional while change publication
  and queued dispatch execution occur once after the winning transaction commits.
- 2026-08-13: Step 4 self-review `comm-002215` identified contradictory TASK-002
  write-scope wording. Revised the scope to place only database mutation and
  auto-action enqueueing inside the transaction; change publication and queued
  dispatch execution now explicitly occur once after the winning commit.
- 2026-08-13: Self-review feedback resolved in AI8 and TASK-001 by defining
  turn-scoped waiters, terminal-delivery obligations, cancellation release, and
  oldest-first eviction only after obligations discharge.
- 2026-08-13: Follow-up self-review feedback resolved by adding a 35-second
  first-terminal-delivery grace, a scheduled no-poller expiry, and deterministic
  coverage of the sequential-poll gap.
- For each task, append: date, files changed, behavioral decision, focused command
  and result, full-suite impact, and any unresolved risk or follow-up.
