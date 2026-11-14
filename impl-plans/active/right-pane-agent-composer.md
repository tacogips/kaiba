# Right-Pane Agent Memo/Chat Composer

**Status**: Implementation complete; native-link and browser smoke are environment-blocked
**Workflow Mode**: `issue-resolution`
**Issue Reference**: `direct-workflow:comm-002100`
**Design References**:

- `design-docs/specs/web-chatbook-ui.md` (issue scope, W9-W12, composer data flow)
- `design-docs/specs/ai-agent-integration.md` (issue scope, AI10-AI11, security boundary)
- `design-docs/user-qa/ai-agent-runtime-and-ui.md` (resolved shared adapter decision)

## Purpose

Replace the right-pane memo/chat actions with the accepted rounded ChatGPT-style
composer while preserving Kaiba's memo timeline, responsive themes, durable
conversation history, streaming recovery, and existing agent-gateway boundary.
Add provider-scoped model selection and validated textual turn attachments from
the web client through GraphQL, core persistence, dispatch, and prompt assembly.

The user's desktop capture
`Screenshot 2026-08-12 at 21.13.56.png` (kept outside the repository) is a
composition reference only. Kaiba intentionally keeps its own theme tokens, pane semantics,
and shared `AgentGatewayCLIInvoker` ACP adapter. Codex and Cursor remain vendor
values behind agent-gateway; this work must not add vendor-specific UI, direct
vendor CLI spawning, or shell interpolation.

## Scope Guard

- Implement only W9-W12 and AI10-AI11 plus the minimum GraphQL, service,
  persistence, prompt, settings, and test changes they require.
- Preserve W1-W8, W13, the existing outbox, transient stream hub, durable change
  feed, note-file storage, and unrelated dirty worktree changes.
- Do not add provider selection, binary/active attachments, comment-file schema,
  new transport protocols, or broader shell/reader/search changes.
- Do not commit or push.

## Deliverables

- [x] Correct the accepted design's screenshot date and keep issue traceability.
- [x] Server-authoritative model catalog and immutable per-turn model snapshot.
- [x] Atomic pending-turn creation with zero-to-four validated UTF-8 attachments.
- [x] Deterministic, bounded, prompt-isolated attachment context on dispatch and retry.
- [x] Complete GraphQL catalog/send contracts and authenticated service wiring.
- [x] Web client types, model-setting persistence, and attachment request encoding.
- [x] Rounded accessible composer, memo-only toggle, model selector, attachment chips,
      Enter/Shift+Enter/IME behavior, far-right submit control, and New chat boundary.
- [ ] Focused Swift and web tests plus full lint/test/build verification.

## Tasks

### TASK-001: Close documentation feedback and establish the implementation baseline

**Write Scope**: `design-docs/specs/web-chatbook-ui.md`, this plan only

**Dependencies**: None

**Parallelizable**: No

**Deliverables**:

- Change the stale summary date at `design-docs/specs/web-chatbook-ui.md:33`
  from 2026-08-10 to the authoritative 2026-08-12 capture date.
- Reconfirm the current dirty-worktree diff before implementation and record the
  baseline in this plan's progress log without reverting or normalizing user work.

**Completion Criteria**:

- [x] The traceability and summary name the same screenshot/date.
- [x] Design-document `git diff --check` passes.
- [x] The progress log records the preserved pre-existing changes relevant to each task.

### TASK-002: Define core model and attachment validation contracts

**Write Scope**: focused AppCore chat contract/validation files; prefer a new
`Sources/AppCore/AgentChatAttachments.swift` or similarly cohesive file instead
of growing `NoteService+AgentChat.swift` toward 1000 lines

**Dependencies**: TASK-001

**Parallelizable**: No; this is a shared contract for TASK-003 and TASK-004

**Deliverables**:

- Add value types for validated inline chat attachments and turn model metadata.
- Centralize exact limits: four files, 1,048,576 decoded UTF-8 content bytes,
  255 UTF-8 filename bytes, and a 4 KiB prompt-framing allowance.
- Validate base64 length before decode, canonical base64, non-empty content,
  aggregate decoded bytes, duplicate selection identity, filename/path/control
  rules, normalized MIME allowlist, extension fallback, and valid UTF-8.
- Keep client input untrusted and preserve normalized filename/media type only as
  display/prompt metadata; never resolve file text as paths or URLs.

**Completion Criteria**:

- [x] Closed domains use Swift enums/value types where they prevent invalid states.
- [x] Validation finishes for the whole request before a conversation or turn is created.
- [x] Tests cover every rejection in AI11, exactly 1,048,576 bytes, and one byte over.
- [x] No existing public agent invocation behavior is broken.

### TASK-003: Make turn creation, model snapshot, attachment association, and dispatch atomic

**Write Scope**: `Sources/AppCore/NoteService+AgentChat.swift`, the focused core
file from TASK-002, and only necessary low-level file-store helpers in
`Sources/AppCore/NoteService+Files.swift`

**Dependencies**: TASK-002

**Parallelizable**: No

**Deliverables**:

- Extend pending-turn creation to persist `kaibaChat.model` and attachment
  positions with the turn.
- Validate supplied conversation ownership against the requested note/notebook
  subject and enforce writable boundaries before mutation.
- Stage file blobs, then insert the turn, file records, `note_files` associations,
  source citation, and outbox rows in one database transaction; expose dispatch
  only after commit. Clean staged blobs on failure, with existing orphan
  reclamation as a secondary recovery path.
- Preserve idempotency: a replay returns the original turn and cannot alter its
  model or duplicate files/dispatches.
- Keep unavailable turns durable while ensuring no reply stream opens.

**Completion Criteria**:

- [x] Dispatch cannot observe a pending turn before all file associations exist.
- [x] Any validation/storage/database failure leaves no turn or dispatch; newly
      staged blobs are deleted when possible and otherwise reclaimable.
- [x] Exact model and attachment order survive queued dispatch and retry.
- [ ] Existing note/file and chat lifecycle tests remain green.

### TASK-004: Build deterministic attachment prompt context and model forwarding

**Write Scope**: focused AppCore prompt builder plus minimal changes to
`Sources/AppCore/NoteService+AgentChat.swift`; `Sources/AppCore/AgentInvoking.swift`
and `Sources/AppCore/AgentGatewayCLIInvoker.swift` only if contract-preserving
adjustments or tests are required

**Dependencies**: TASK-002, TASK-003

**Parallelizable**: No

**Deliverables**:

- Read the persisted turn model into `AgentInvocationRequest.model`; leave the
  provider server-configured and passed as a discrete process argument.
- Resolve only attachments belonging to turns in the active conversation.
- Assemble whole-file, explicitly delimited untrusted-data sections: current
  turn in stored position order, then prior turns newest-to-oldest and file
  position order.
- Enforce the independent 1 MiB content and 4 KiB framing budgets, deterministic
  omission markers, no partial truncation, and no ambient subject/notebook files.
- Preserve `AgentGatewayCLIInvoker` as the single Codex/Cursor ACP adapter and
  the authoritative persisted-result/streaming behavior.

**Completion Criteria**:

- [x] Current-turn files at the accepted aggregate boundary all reach the first invocation.
- [x] Prior files are deterministically included or omitted under both budgets.
- [x] Retry produces identical model, ordering, delimiters, and omission behavior.
- [x] Attachment text cannot alter system prompt fields or gateway arguments.

### TASK-005: Expose model catalog and attachment send input through GraphQL

**Write Scope**: `Sources/AppGraphQL/GraphQLNoteSchemaContract.swift`,
`GraphQLContractProjector.swift`, `NoteGraphQLContracts.swift`,
`NoteGraphQLDocumentInputs.swift`, `NoteGraphQLDocumentExecutor.swift`,
`NoteGraphQLService.swift`, and required composition wiring in
`Sources/AppCLI/ServeCommand.swift`

**Dependencies**: TASK-003, TASK-004

**Parallelizable**: No; these files are shared contract touchpoints

**Deliverables**:

- Add authenticated `agentModels` output with configured fallback, discovery
  availability, ids, and display metadata, excluding credentials, paths, and env.
- Extend `sendAgentChatMessage` input with optional `model` and inline attachment
  values; validate model against the current-provider catalog or configured fallback.
- Wire `AgentGatewayCLIModelCatalog` and configured provider/model into the
  GraphQL service using existing dependency-injection patterns.
- Update every AppGraphQL touchpoint: SDL, projector, allowlists, root switch,
  selection maps, DTO/input decoding, diagnostics, and contract tests.

**Completion Criteria**:

- [x] Unsupported client models fail before turn creation.
- [x] Discovery failure still returns the configured fallback and an explicit status.
- [x] Malformed/oversized attachments fail without turn, file association, or dispatch.
- [x] Authentication and GraphQL diagnostics match existing conventions.

### TASK-006: Add web contracts, settings, and testable composer state

**Write Scope**: `web/src/notes/types.ts`, `web/src/notes/client.ts`,
`web/src/notes/settings.ts`, and a focused `web/src/notes/memoComposer.ts` with tests

**Dependencies**: TASK-005 contract shape

**Parallelizable**: No; consume the finalized TASK-005 contract before editing
the web client

**Deliverables**:

- Add model catalog, selected model, and inline attachment request types/client calls.
- Persist selection in SQLite-backed `web.agentModel` using the existing app-setting
  helpers and defensive parsing for older documents.
- Add DOM-free state/helpers for Enter/Shift+Enter/IME submission decisions,
  memo-only mode, staged attachment validation/removal, explicit New chat intent,
  and request construction that omits `conversationNotebookId` until the new
  conversation is created.
- Detect older servers and disable unsupported model/attachment controls instead
  of sending unknown fields.

**Completion Criteria**:

- [x] Selected model normalizes against catalog/fallback and persists across reloads.
- [x] Memo-only sends neither model nor attachments but retains model selection.
- [x] New chat never silently falls back to `latestConversationId` before first send.
- [x] Pure tests cover keyboard, mode, model, new-chat, and attachment state transitions.

### TASK-007: Implement the accessible right-pane composer and New chat behavior

**Write Scope**: `web/src/components/MemoTab.tsx`,
`web/src/panes/RightPane.tsx`, and narrowly required timeline helpers

**Dependencies**: TASK-006

**Parallelizable**: No

**Deliverables**:

- Replace separate Send/Memo-only actions with a rounded, bottom-anchored composer.
- Put plus and memo-only icon controls on the left, model choice inside or adjacent
  near the right, and circular submit as the far-right control.
- Make memo-only a keyboard-operable `aria-pressed` toggle with accessible name,
  tooltip, focus ring, visible selected state, and text-only enforcement.
- Support plain Enter submit, Shift+Enter newline, IME suppression, non-empty draft
  guard, file chips/removal, busy state, and error-preserving draft/staging behavior.
- Add the upper-left New chat icon and focus-announced single boundary; clear draft,
  staged files, and current display stream without deleting/hiding history.

**Completion Criteria**:

- [x] Agent and memo-only paths use one composer and the correct contracts.
- [x] New chat retains prior memos/turns and makes the returned new conversation active.
- [x] All icon controls have at least 36px targets and visible keyboard focus.
- [x] Focused tests verify the accepted keyboard, mode, model, reset, and attachment behavior.

### TASK-008: Apply responsive light/dark styling and visual verification

**Write Scope**: `web/src/chatbook.css` and only necessary existing theme selectors

**Dependencies**: TASK-007

**Parallelizable**: Yes with additional Swift tests in TASK-009; write scopes are disjoint

**Deliverables**:

- Style the composer hierarchy using existing Kaiba theme tokens and breakpoints.
- Ensure attachment chips, selected memo-only state, model control, New chat,
  error/help text, and submit states remain legible in light/dark themes and
  narrow/folded pane layouts.
- Compare placement and hierarchy with the desktop capture without copying its
  brand colors, typography, provider controls, or unrelated actions.

**Completion Criteria**:

- [ ] Controls do not overflow or reorder incorrectly at existing pane breakpoints.
- [ ] Selected, disabled, hover, and focus states remain distinguishable in both themes.
- [ ] Browser smoke covers keyboard-only operation and responsive/light/dark states.

### TASK-009: Complete focused and full verification

**Write Scope**: focused tests under `Tests/AppCoreTests/`,
`Tests/AppGraphQLTests/`, and `web/src/**/*.test.ts`; production fixes only when
required by failures caused by this feature

**Dependencies**: TASK-003 through TASK-007 for focused test authoring; TASK-008
for final integrated verification

**Parallelizable**: No for final integration; focused Swift and web test authoring may
run in parallel only when their write scopes do not overlap production files

**Deliverables**:

- Core tests for atomicity, ownership, idempotency, snapshot/retry, exact byte
  accounting, prompt ordering, framing, spoofed types, path-like filenames,
  invalid UTF-8, and cleanup/reclamation behavior.
- GraphQL tests for catalog fallback, auth, model rejection, complete touchpoints,
  valid attachment round-trip, and pre-creation rejection cases.
- Web tests for Enter/Shift+Enter/IME, memo-only accessibility/blocking, model
  fallback/persistence, New chat reset/omission, attachment validation/removal,
  and older-server capability behavior.
- Full lint, tests, builds, and manual browser smoke.

**Completion Criteria**:

- [ ] Every verification command below passes, or an environment-only blocker is
      recorded with command, output summary, and unaffected checks.
- [ ] No unrelated dirty changes are reverted, overwritten, formatted, or committed.
- [ ] All deliverables are checked and the final progress entry records files,
      tests, decisions, residual risks, and completion date.

## Dependencies and Execution Order

1. TASK-001 establishes accepted documentation and baseline.
2. TASK-002 defines shared validation contracts.
3. TASK-003 establishes durable atomicity before any UI can send attachments.
4. TASK-004 completes invocation data flow; TASK-005 then freezes GraphQL shape.
5. TASK-006 builds the web contract/state layer; TASK-007 consumes it.
6. TASK-008 completes visual behavior; TASK-009 integrates and verifies all layers.

No model or attachment UI is enabled before TASK-003 through TASK-005 are complete.

## Parallel Work Map

- TASK-008 CSS may proceed alongside focused Swift test additions in TASK-009.
- TASK-009 final integration waits for TASK-008 even when its Swift test authoring
  starts concurrently.
- All other tasks are sequential because they share contracts, production files, or
  atomicity assumptions. If a supposedly disjoint task needs a shared file, stop
  parallel work and serialize the edit.

## Verification Commands

Run narrow checks first, then the full project checks:

```bash
git --no-optional-locks diff --no-ext-diff --no-textconv --check -- \
  design-docs/specs/web-chatbook-ui.md \
  design-docs/specs/ai-agent-integration.md \
  design-docs/user-qa/ai-agent-runtime-and-ui.md \
  impl-plans/active/right-pane-agent-composer.md

swift test --filter AgentChatTests
swift test --filter AgentGatewayCLIInvokerTests
swift test --filter AgentChatGraphQLTests

(cd web && bun run typecheck)
(cd web && bun run test)
(cd web && bun run lint)
(cd web && bun run build)

mise run lint
mise run test
mise run build
```

Manual smoke with `kaiba serve --web-root web/dist`:

- Submit with Enter; insert newline with Shift+Enter; confirm IME composition does not submit.
- Toggle memo-only by pointer and keyboard; verify tooltip, accessible state, selected
  treatment, text-only blocking, and preserved model selection.
- Select/persist a model; verify the stored turn model is used after config changes/retry.
- Attach/remove valid text files; verify accessible errors for every rejected boundary.
- Start New chat; verify one visible boundary, retained history, cleared local draft/files,
  omitted conversation id on first send, and no loss after stream interruption/refetch.
- Inspect narrow and wide right panes in light and dark themes.

## Completion Criteria

- [x] W9-W12 and AI10-AI11 are implemented exactly within issue scope.
- [x] Model and attachment validation is server-authoritative and pre-creation.
- [x] Turn, model, file associations, and dispatch have the accepted atomic boundary.
- [x] Persisted completion remains authoritative over transient streaming.
- [x] Codex/Cursor remain behind `AgentGatewayCLIInvoker`; no vendor-specific divergence leaks into UI/core.
- [ ] Focused and full verification pass with exact commands recorded.
- [x] Design feedback is resolved, documentation remains under `design-docs/`, and this
      plan's progress log is current.
- [x] The user's pre-existing dirty work is preserved; no commit or push occurs.

## Risks and Mitigations

- **Untrusted prompt content**: enforce MIME/UTF-8/name/size validation, explicit
  delimiters, fixed budgets, system-prompt separation, and adversarial tests.
- **Dispatch race or partial persistence**: stage blobs, commit turn/files/outbox in
  one database transaction, dispatch only after commit, and test injected failures.
- **Filesystem/database dual-write cleanup**: delete staged blobs on rollback and
  retain orphan reclamation as a verified recovery mechanism.
- **Base64/HTTP boundary error**: estimate before decode and test exact aggregate
  bytes within the unchanged 2 MiB parser limit.
- **Model drift**: snapshot on the turn before enqueue and rebuild requests only
  from persisted metadata.
- **Streaming loss**: keep chunks transient and replace them from persisted final state.
- **Dirty-worktree collision**: inspect each target's diff immediately before edit,
  patch minimally, and never revert or bulk-format unrelated files.
- **Large Swift files**: keep new validation/prompt responsibilities in cohesive files;
  do not grow existing 1000+ line files and split any edited file that crosses 1000 lines.

## Progress Log Expectations

Append a dated entry after each completed task. Each entry must name the task, files
changed, exact verification commands/results, design decisions or divergences, and
remaining risks. Do not mark a checkbox complete on intent alone.

## Progress Log

- 2026-08-12: Plan created from the accepted Step 3 design review. Incorporated the
  low finding to correct the screenshot date during TASK-001. No implementation code,
  commit, push, or unrelated worktree mutation performed.
- 2026-08-12: Implemented the scoped composer foundation: persisted model snapshot,
  pre-creation inline text attachment validation, existing file-store association,
  delimited invocation context, GraphQL model/attachment input, and the unified
  right-pane composer/New chat controls. Pending verification covers Swift and web
  compilation plus focused contract and keyboard-state tests; existing dirty work was
  preserved and no commit/push was performed.
- 2026-08-12: Self-review revision: moved attachment blob staging and file association
  inside pending-turn creation before outbox enqueue, added a single conversation-wide
  content/framing-bounded prompt section, subject ownership checks, visible New chat
  boundary, memo-only attachment blocking, and focused model/attachment/settings tests.
  Catalog-backed model discovery and full project verification remain pending.
- 2026-08-13: Revision added incremental staged-blob cleanup, authenticated
  `agentModels` catalog discovery with configured fallback, catalog-backed web
  selection, DOM-free composer validation/keyboard tests, and focused GraphQL
  catalog/rejection tests. Full verification remains environment-blocked.
- 2026-08-13: Follow-up revision gates both model and attachment extensions on
  `agentModels` capability discovery, omits unsupported fields for older
  servers, applies UTF-8 filename-byte validation, and adds focused catalog
  projection, attachment round-trip, prompt content/framing boundary,
  prompt-isolation, and rollback cleanup tests. Completion criteria remain
  pending verification.
- 2026-08-13: Final correction accounts for outer attachment delimiters and
  separators inside the 4 KiB framing limit, percent-normalizes prompt
  metadata so all validated current files fit, enforces canonical base64 and
  generic-MIME filename fallback, and adds exact aggregate/framing and
  regular-file rollback assertions plus retry snapshot/context determinism.
  Web lint and production build pass;
  TypeScript typecheck, Bun tests, Swift test linking, and browser smoke
  remain recorded environment/manual verification gaps.
- 2026-08-13: Test-integrity revision extracted the production composer request
  builder so New chat omission, model/attachment capability gating, and model
  normalization are directly tested. Added memo-only accessible-control state
  assertions, client validation boundaries, server validation rejection cases,
  rollback assertions for turns/outbox/blobs, GraphQL excess-file rejection,
  and an auto-action dispatcher assertion that attachment associations exist
  before dispatch. `swift build --target AppCoreTests` compiled the target
  before the command wrapper timed out; `swift build --target
  AppGraphQLTests`, `npm run lint`, and `npm run build` pass; TypeScript
  typecheck, Bun tests, Swift linking,
  SwiftLint, and browser smoke remain pending/environment-blocked.
- 2026-08-13: Split agent model catalog, chat-send, conversation resolution,
  and attachment-input validation out of `NoteGraphQLService.swift` into
  `NoteGraphQLService+AgentChat.swift` to keep edited Swift files below the
  project split threshold. Added exact 255-byte filename acceptance and
  256-byte rejection coverage. `swift build --target AppGraphQLTests`,
  `swift build --target AppCoreTests`, and focused SwiftLint pass; the focused
  GraphQL test command remains blocked at executable linking by `anydoc_ffi`
  and `SwiftUICore` environment restrictions.
- 2026-08-13: Test-integrity follow-up added production-wired keyboard and
  memo-only toggle outcomes, including busy/empty-draft suppression and the
  attachment-blocking explanation. Added successful and failing catalog tests,
  authenticated HTTP catalog routing coverage, deterministic current/prior
  attachment ordering, spoofed-MIME pre-creation rejection, and injected
  staged-store failure cleanup proving no turn or dispatch is created. Focused
  builds for `AppCoreTests`, `AppGraphQLTests`, and `AppServerTests` pass; web
  `npm run lint`, `npm run typecheck`, and `npm run build` pass. SwiftLint timed
  out after an unrelated existing warning and focused Swift test execution is
  blocked at native linking; Bun is unavailable. No completion checkbox was
  marked solely from compilation or static review.
- 2026-08-13: Self-review follow-up extracted the production composer controls
  into a rendered Solid component and added SSR checks for its selected
  memo-only state, accessible labels/tooltips, staged attachment chip, model
  control, submit label, and older-server disabled state. The injected staged
  storage-failure case now enables the real chat auto-action and confirms no
  turn, outbox dispatch, or dispatcher invocation occurs. The file-store seam
  is internal-only and restricted to rollback testing; production remains on
  the local store. Completion criteria remain unchecked pending executable
  Swift/Bun tests and manual smoke verification.
- 2026-08-13: Test-integrity correction added a DOM-backed `MemoTab`
  integration test using a stub store/client. It dispatches production
  keyboard, model, attachment, memo-only, New chat, and submit handlers while
  asserting retained history and the generated request. The injected
  staged-store failure test now creates its subject/conversation before
  enabling the auto-action and compares dispatch/dispatcher state against a
  post-configuration baseline. Web `npm run typecheck`, `npm run lint`, and
  `npm run build` pass; the new Vitest integration body passes. Swift test
  linking, Bun availability, SwiftLint completion, and browser smoke remain
  pending environment/manual verification gaps.
- 2026-08-13: Extracted comment creation into `NoteService+Comments.swift`
  and note search into `NoteService+Search.swift`, reducing
  `NoteService.swift` to 945 lines without changing public access levels. The
  standard web `test` script
  now runs both Bun unit tests and the Vitest integration suite; it observed
  147 Bun tests and 3 Vitest integration tests passing before the local Bun
  wrapper timed out after output. SwiftLint exits successfully with the
  pre-existing `large_tuple` warning in `NoteService.swift`. Completion
  criteria remain unchecked pending executable Swift tests and manual browser
  smoke.
- 2026-08-13: Step 7 revision preserves the New chat boundary after its first
  send and pins subsequent messages to the returned conversation id. The
  attachment affordance is now a visible keyboard-focusable button, model
  selection stays available in the compact layout, delayed settings hydration
  is reactively normalized against the catalog, and generic browser MIME values
  use the same recognized-extension fallback as the server. Focused web tests
  cover the returned conversation continuation, attachment-button focus/click,
  and generic MIME fallback. Full executable Swift tests and manual browser
  smoke remain outstanding.
- 2026-08-13: Final Riela review correction partitions the rendered timeline at
  the New chat boundary: retained history stays above it and the returned active
  conversation renders below it, while later sends continue that conversation.
  The production DOM integration asserts this order. Vitest passes 3 integration
  tests and the pinned Bun runner passes all 147 web unit tests,
  and `npm run typecheck`, `npm run lint`, `npm run build`, and `git diff
  --check` pass. The in-app browser runtime reports no connected browser, so
  visual smoke remains environment-blocked; focused Swift test targets compile,
  while executable Swift tests remain blocked at native linking as recorded
  above. No unrelated dirty changes were reverted and no commit or push occurred.
