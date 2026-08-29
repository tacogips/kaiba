# Right-Pane Agent Memo/Chat Composer

**Status**: Implementation and the older-server capability gate are complete
and verified (TASK-010 through TASK-012, TASK-014 executed 2026-08-29; the whole
gate RE-EXECUTED 2026-08-30 against the current tree, which turned `tsc --noEmit`
red on a test-only `noUncheckedIndexedAccess` violation that was then fixed —
`mise run check` now `EXIT=0` unpiped). All four mutations this plan cites by
number were RE-EXECUTED against HEAD 2026-08-30: 4, 8 and 11 held; 12 was
CAUGHT, falsifying the DISCLOSURE that called the retry arm of
`effectiveNoteEdit` unreached. That box is now a checked, pinned criterion and
NO DISCLOSURE remains, so the unchecked count is 6, not 7.
TASK-008's three browser-runtime criteria remain openly environment-blocked: no
browser runtime is installed and adding a headless one is an unauthorized open
user decision. That single unmet deliverable keeps this plan in
`impl-plans/active/`.
**Workflow Mode**: `issue-resolution`
**Issue Reference**: `direct-workflow:comm-002100`
**Design References**:

- `design-docs/specs/web-chatbook-ui.md` (issue scope, W9-W12, composer data flow)
- `design-docs/specs/ai-agent-integration.md` (issue scope, AI10-AI11, security boundary)
- `design-docs/user-qa/ai-agent-runtime-and-ui.md` (resolved shared adapter decision)
- `design-docs/user-qa/web-chatbook-ui.md` (open decision: automating the
  browser-runtime composer checks)
- `design-docs/specs/tauri-client-apps.md:159-171` (authoritative web gate
  definition, read-only)

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
- Commit only the files this verification work changes. `README.md` is
  pre-existing dirty work and must not be staged, reverted, or formatted.
  Do not push.

## Deliverables

- [ ] RETRACTED (2026-08-29, TASK-001): "Correct the accepted design's
      screenshot date." The decision below establishes that the two dates name
      two distinct captures, so there is nothing to correct. A RETRACTED item is
      a withdrawn obligation, not an open one: it is left unchecked so no
      checkbox claims work the tree contradicts, and it does not gate the move
      to `impl-plans/completed/`.
- [x] Issue traceability in the accepted design names the workflow issue, the
      2026-08-12 composer screenshot, the gate definition, and the open user
      decision (`design-docs/specs/web-chatbook-ui.md:9-15`).
- [x] Server-authoritative model catalog and immutable per-turn model snapshot.
- [x] Atomic pending-turn creation with zero-to-four validated UTF-8 attachments.
- [x] Deterministic, bounded, prompt-isolated attachment context on dispatch and retry.
- [x] Complete GraphQL catalog/send contracts and authenticated service wiring.
- [x] Web client types, model-setting persistence, and attachment request encoding.
- [x] Rounded accessible composer, memo-only toggle, model selector, attachment chips,
      Enter/Shift+Enter/IME behavior, far-right submit control, and New chat boundary.
- [x] Focused Swift and web tests plus full lint/test/build verification.
      Executed 2026-08-29: three focused Swift suites (24/11/19 tests, 0
      failures), `mise run web:check` green (155 Bun unit, 28 Vitest
      integration after TASK-011c's twelve tests), `mise run lint` (2 pre-existing
      `large_tuple` warnings, 0 serious), `mise run test` (523 XCTest + 34
      swift-testing, 0 failures),
      `mise run build` complete. Browser smoke is TASK-008's separate
      criteria set and remains environment-blocked.

## Tasks

### TASK-001: Close documentation feedback and establish the implementation baseline

**Write Scope**: `design-docs/specs/web-chatbook-ui.md`, this plan only

**Dependencies**: None

**Parallelizable**: No

**Deliverables**:

- **DECISION (2026-08-29) — the date correction is RETRACTED; the two
  references are distinct captures, and no edit is made.** The plan's original
  bullet cited `design-docs/specs/web-chatbook-ui.md:33`; that line is now `:36`
  (this closeout's own diff inserted three Design Reference lines above it) and
  reads `(reference: the user's chatbook screenshot, 2026-08-10)`. It sits in the
  **Summary** section describing the three-pane chatbook READER — the W1-W8
  surface this issue's Scope Guard says to preserve, introduced by `c4de25e`.
  The composer capture `Screenshot 2026-08-12 at 21.13.56.png` is cited
  separately at `:10-11` (Traceability) and `:131-132` (W9), each time as the
  COMPOSER composition reference for this issue. Rewriting `:36` to 2026-08-12
  would falsify the reader design's provenance by attributing an out-of-scope
  W1-W8 section to a later capture that does not depict it.
  Evidence: `git log -S "chatbook screenshot, 2026-08-12" --oneline --
  design-docs/specs/web-chatbook-ui.md` returns nothing, so the 2026-08-12 form
  never existed at `:36`; `grep -n -i screenshot design-docs/specs/web-chatbook-ui.md`
  returns exactly `:10`, `:11`, `:36`, `:131`, `:132`.
  Consequence: `design-docs/specs/web-chatbook-ui.md` still appears in TASK-014's
  commit enumeration, but for the Traceability and Verification edits already in
  the dirty worktree, NOT for a date change. No task writes `:36`.
- Reconfirm the current dirty-worktree diff before implementation and record the
  baseline in this plan's progress log without reverting or normalizing user work.

**Completion Criteria**:

- [ ] RETRACTED (2026-08-29): "The traceability and summary name the same
      screenshot/date." They deliberately name different captures — the
      Traceability/W9 composer screenshot (2026-08-12) and the Summary's earlier
      chatbook reader capture (2026-08-10). Withdrawn, not open; see the decision
      above.
- [x] Each screenshot citation names the capture that actually depicts the
      surface it documents (`:10-11` and `:131-132` composer, `:36` reader).
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
- [x] Existing note/file and chat lifecycle tests remain green.
      Closed by TASK-010's executed output: `mise run test` reports 523 XCTest
      tests and 34 swift-testing tests with 0 failures (2026-08-29).

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
  of sending unknown fields. **REGRESSED at HEAD** — `catalogAvailable` was
  dropped from `agentComposerExtensionsEnabled` by `fb3997a` after `b076a33`
  introduced it. Restored by TASK-011b; do not treat this bullet as delivered
  until that task's regression test passes.

**Completion Criteria**:

- [x] Selected model normalizes against catalog/fallback and persists across reloads.
- [x] Memo-only sends neither model nor attachments but retains model selection.
- [x] New chat never silently falls back to `latestConversationId` before first send.
- [x] Pure tests cover keyboard, mode, model, new-chat, and attachment state
      transitions, including the older-server capability-unavailable path.
      Closed 2026-08-29 by TASK-011a/TASK-011b: `memoComposer.test.ts`'s
      "an unavailable composer-extension catalog rests the controls and
      withholds every extension field" is the capability-unavailable test the
      Step 5 high finding said was missing.

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

These three are browser-runtime checks under `web-chatbook-ui.md`'s evidence
rule. Reading CSS, compiling, or static review never satisfies them. TASK-013
either executes them against a real runtime or records them as
environment-blocked; they stay unchecked while blocked.

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
  and older-server capability behavior. The older-server clause is **not
  delivered at HEAD**; TASK-011a writes the missing test and TASK-011b makes it
  pass.
- Full lint, tests, builds, and manual browser smoke.

**Completion Criteria**:

- [x] Every verification command below passes, or an environment-only blocker is
      recorded with command, output summary, and unaffected checks. (Every
      command executed green; the browser smoke list is recorded as blocked in
      TASK-013.)
- [x] No unrelated dirty changes are reverted, overwritten, formatted, or committed.
- [ ] All deliverables are checked and the final progress entry records files,
      tests, decisions, residual risks, and completion date. (Open only because
      TASK-008's browser-runtime deliverables stay unchecked while blocked.)

Test authoring for TASK-009 is complete. Its remaining work is executing the
gate, which TASK-010 through TASK-014 decompose.

### TASK-010: Execute the focused Swift suites with the mise prerequisite inherited

**Write Scope**: no production or test file unless a run fails; on failure,
only the narrowest file the failure implicates under `Sources/AppCore/`,
`Sources/AppGraphQL/`, or `Tests/`

**Dependencies**: TASK-003 through TASK-005 (complete)

**Parallelizable**: No; shares the SwiftPM `.build` directory with TASK-012

**Deliverables**:

- Run `mise run anydoc:native` once, then each focused suite with
  `PKG_CONFIG_PATH` inherited, per `ai-agent-integration.md` item 11.
- Capture real output for `AgentChatTests`, `AgentGatewayCLIInvokerTests`, and
  `AgentChatGraphQLTests`, including pass/fail counts.
- If a run fails, fix the narrowest cause this feature introduced; do not
  weaken, skip, `XCTSkip`, or delete an existing test to make it pass.
- If linking still fails on `anydoc_ffi` or `SwiftUICore` after the prerequisite
  is satisfied, record the exact command, an output summary, the reason, and the
  checks the blocker leaves unaffected.

**Completion Criteria**:

- [x] All three focused suites report executed results, or each is recorded as
      environment-blocked with command, output summary, and reason. Executed
      2026-08-29 after `mise run anydoc:native`: `AgentChatTests` 24 tests /
      0 failures, `AgentGatewayCLIInvokerTests` 11 / 0, `AgentChatGraphQLTests`
      19 / 0. The previously recorded `anydoc_ffi`/`SwiftUICore` linking
      blocker did NOT recur under the `PKG_CONFIG_PATH=... mise exec --` form.
- [x] TASK-003's "Existing note/file and chat lifecycle tests remain green"
      is decided from executed output only.
- [x] No test was weakened, skipped, or removed.

### TASK-011: Execute the web gate as one command

**Write Scope**: no file unless the gate fails; on failure, only the narrowest
file under `web/` that the failure implicates — usually `web/src/`, but a
typecheck or build failure may instead implicate `web/tsconfig.json`,
`web/vite.config.ts`, or `web/eslint.config.js`. Never edit an unrelated dirty
file to make the gate pass.

**Dependencies**: TASK-006 through TASK-008 (authoring complete)

**Parallelizable**: Yes with TASK-010 and TASK-012; the web gate touches
`web/` and `node_modules`, not `.build/`

**Deliverables**:

- Run `mise run web:check`, the single gate defined in `web-chatbook-ui.md`.
  It resolves `bun` through mise and runs `web/package.json`'s `check`
  (typecheck, test, lint, build) in that order.
- Record the executed output, including the Bun unit count and the Vitest
  integration count, rather than citing a prior partial run.
- Do not substitute the four separate `bun run` scripts for the gate, and do not
  treat a wrapper timeout after partial output as a pass.
- Fix any failure in the narrowest web file it implicates.

**Completion Criteria**:

- [x] `mise run web:check` completed with recorded output, or the blocker is
      recorded with command, output summary, and reason. Baseline run
      (2026-08-29, pre-TASK-011a): typecheck, 154 Bun unit tests across 21
      files, 13 Vitest integration tests across 5 files, eslint, and `vite
      build` all green.
- [x] The recorded evidence names the single gate command, not a subset.

### TASK-011a: Verify the gate actually covers each design-named check

**Write Scope**: `web/src/notes/memoComposer.test.ts` (the mapped DOM-free
assertions, plus migration of the existing call sites),
`web/src/components/MemoTab.integration.tsx` (supplementary rendered wiring
coverage), and `web/src/components/MemoComposerControls.integration.tsx`
(FIXTURE MIGRATION ONLY — two added `catalogAvailable` properties, no assertion
added, changed, or removed). No production file. `MemoComposerControls.integration.tsx`
is in scope only because TASK-011b's REQUIRED `catalogAvailable` prop makes its
two `createComponent` literals miss a required property, and `web/tsconfig.json`
includes `src`, so leaving it alone turns the typecheck leg of `mise run web:check`
red on a file no production task writes. It remains OUT of scope for new
assertions — the admissibility rule below still bars a literal catalog test there.
The repository splits the two runners: `bun test src` runs `*.test.ts`, while
`web/vitest.config.ts` includes only `src/**/*.integration.tsx` under happy-dom.

**Dependencies**: TASK-011 (a first recorded gate run establishes the baseline)

**Parallelizable**: No; TASK-011b edits the module this task tests, and both
share `web/src/`

**Rationale**: a green `mise run web:check` proves the tests that exist pass, not
that the design's required tests exist. `web-chatbook-ui.md:309-316` names the
gate-enforced set, so gate coverage must be audited against that list.

**Deliverables**:

- Map each gate-enforced item at `design-docs/specs/web-chatbook-ui.md:309-316`
  to a named test file and test name under `web/src`: `router.test.ts`,
  `toc.test.ts`, `chatState.test.ts`, `paneState.test.ts`, and the composer
  items (Enter/Shift+Enter/IME, memo-only accessibility and blocking, model
  fallback/persistence, new-chat conversation intent, attachment
  validation/removal, older-server capability fallback).
- Record that mapping verbatim in the progress log, naming any item with no
  covering test. Map the older-server item at `web-chatbook-ui.md:314` to the
  DOM-free half in `memoComposer.test.ts`, not to a rendered test:
  `web-chatbook-ui.md:309-316` defines the gate-enforced list as DOM-free logic
  tests and :315-316 places composer behavior expressible as pure state or
  encoding logic there. (Line 308 is blank; the earlier :308-315 / :315-317
  citations were off by one.) The rendered half is recorded as supplementary wiring coverage.
  Both run inside `mise run web:check`, so gate coverage is unchanged either way.
- Write the mapped DOM-free half in `memoComposer.test.ts`: with the catalog
  unavailable, `agentComposerExtensionsEnabled(false, ...)` is false and `model`,
  `attachments`, and `mode: "edit"` are all withheld from the request built by
  `buildAgentChatComposerRequest`.
- Write the supplementary rendered half in `MemoTab.integration.tsx`: render
  `MemoTab` with a client whose `agentModels()` REJECTS, then assert the model
  select, attach button, and note-edit toggle render disabled. The note-edit
  assertion is satisfied by TASK-011b's `catalogAvailable` prop (its binding
  reads `!props.catalogAvailable || (!props.canNoteEdit && !props.noteEdit)`), not
  by `extensionsEnabled`; assert the rendered DOM state, not the prop name. The file already
  stubs `agentModels` (:59-66) and has `settle`/`waitFor` helpers (:28-46) —
  reuse `waitFor` so the assertion survives MemoTab's async discovery instead of
  passing spuriously on first paint. The assertion is non-tautological at HEAD:
  the file's fixtures are writable (`subject.readOnly: false` at :13, stub
  `notebook()` `readOnly: false` at :90), so `canNoteEdit` is true and the
  note-edit toggle currently renders ENABLED under a rejecting catalog. If a
  future fixture makes the note read-only, the note-edit half of the assertion
  becomes vacuous and must be re-based on the model select and attach button.
- **Admissibility rule**: a rendered test that passes a literal
  `extensionsEnabled: false` is NOT admissible pre-fix evidence. It duplicates
  the already-green test at `MemoComposerControls.integration.tsx:43`, because
  `MemoComposerControls` (exported from `MemoTab.tsx:555`) takes
  `extensionsEnabled` as a plain prop with no catalog knowledge. The
  catalog-unavailable wiring lives in MemoTab's `extensionControlsEnabled` memo
  (`MemoTab.tsx:117-118`) and the discovery `.catch` (`MemoTab.tsx:130-139`),
  which is why the rendered half must drive a rejecting `agentModels` stub
  through `MemoTab` itself.
- **Option-shape decision (binding on TASK-011b): `extensionsAvailable` is a
  REQUIRED `boolean` on `AgentChatComposerRequestOptions`, matching `b076a33`
  (`memoComposer.ts:77`).** Required fails closed: typecheck forces every call
  site, present and future, to state its answer. An optional field would let a
  new call site omit it silently; if a later revision makes it optional anyway,
  it must default to WITHHOLDING the fields, because a compatibility gate that
  defaults to true fails open.
- Migrate every call site the restored signature and the required option break.
  All are in this task's test file; the production call site `MemoTab.tsx:301`
  belongs to TASK-011b:
  1. `memoComposer.test.ts:68-70` — three two-argument
     `agentComposerExtensionsEnabled` assertions.
  2. `memoComposer.test.ts:86-93` — the shared `options` fixture consumed at
     :94, :98, and :100.
  3. `memoComposer.test.ts:108-111` — the bare-request literal.
  4. `memoComposer.test.ts:161-168` — the note-edit `options` fixture consumed at
     :169-170. (Not in the Step 5 list; found while verifying the finding. It
     breaks identically once the option is required.)
  Each is a call-site update to keep an existing test compiling against a
  restored signature — NOT a weakening, skip, or deletion, so it does not breach
  the no-weakening rule. Keeping them here leaves TASK-011b's production write
  scope capped at `memoComposer.ts` + `MemoTab.tsx`.
- Migrate `MemoComposerControls.integration.tsx`'s two prop literals for
  TASK-011b's required prop: add `catalogAvailable: true` beside
  `extensionsEnabled: true` at `:18` (the `:7` test) and `catalogAvailable: false`
  beside `extensionsEnabled: false` at `:53` (the `:43` test), mirroring each
  fixture's existing `extensionsEnabled` value. Both existing assertions must still pass unchanged
  (`:7` asserts `title="Edit note mode"` from the untouched title expression;
  `:43` asserts `aria-disabled="true"`, already true from `canNoteEdit: false`).
  This is a call-site migration compelled by a required prop, not a weakening.
- Write the POSITIVE rendered counterpart in `MemoTab.integration.tsx`, using
  the file's existing resolving `agentModels` stub (:59-66,
  `discoveryAvailable: true`): assert via `waitFor` that the model select, attach
  button, and note-edit toggle end ENABLED. Add ONE further assertion in that same
  resolving-catalog test: after dispatching the memo-only toggle so memo-only is
  ON, the note-edit toggle is still ENABLED. That is the only planned check that
  fails if the toggle is ever gated on the composite `extensionsEnabled`
  (`catalogAvailable && !memoOnly && !busy`) instead of `catalogAvailable` alone,
  which would make `noteEditToggleResult`'s "Disable memo-only mode before
  enabling note edit mode." explanation (`memoComposer.ts:84-86`,
  `MemoTab.tsx:513`) unreachable while its tooltip still read "Edit note mode". `b076a33` initialized
  `createSignal(false)`, so a verbatim restoration renders the controls disabled
  until discovery resolves and nothing else planned pins that they re-enable.
  This one assertion is the only planned check that catches BOTH a
  permanently-pending signal and the `discoveryAvailable` mis-wiring TASK-011b
  forbids. It is expected to pass both pre-fix and post-fix; it is a regression
  guard, not pre-fix evidence.
- Run the new tests with the mise-resolved runners and record that they FAIL
  against HEAD:
  `(cd web && mise exec -- bun test src/notes/memoComposer.test.ts)` and
  `(cd web && mise exec -- bun run test:integration)`.
  `bun` is supplied by mise (`[tools] bun`, verified 1.3.14); do not assume an
  ambient install.
- **What the pre-fix failure looks like, and what it must NOT be.** `bun test`
  and `vitest` transpile TypeScript without typechecking, so the new tests still
  RUN against HEAD: TypeScript's excess-property error on `extensionsAvailable`
  is a typecheck-leg failure, while at runtime HEAD's builder simply ignores the
  unknown property and emits `model`/`attachments`/`mode` anyway. The admissible
  pre-fix evidence is therefore a runtime ASSERTION failure from the two negative
  tests. A `tsc` error alone is not that evidence — it only shows the interface
  does not exist yet. Record the assertion failure text, not just a non-zero exit.
- A failing new test is
  the evidence that authorizes TASK-011b's production change under the workflow
  constraint "do not change the implemented composer behavior beyond what a
  failing check requires."

**Completion Criteria**:

- [x] Every item at `web-chatbook-ui.md:309-316` is mapped to a named test or
      recorded as uncovered. The mapping is recorded verbatim in the 2026-08-29
      TASK-011a progress entry; no item is uncovered.
- [x] Three new tests exist: the DOM-free negative half, the rendered negative
      half, and the rendered positive counterpart. A FOURTH was added
      2026-08-29 answering the test-integrity gate's mid finding: the
      deferred-rejection test pinning the `.catch`'s `setAttachments([])`.
- [x] The two NEGATIVE tests are recorded failing pre-fix, each with its runner
      command and its runtime assertion-failure text. The positive counterpart is
      expected to PASS pre-fix and is not pre-fix evidence; record it as a
      regression guard. (It passed pre-fix, 15 tests with 1 failure.)
- [x] The rendered half fails pre-fix by driving a rejecting `agentModels` stub
      through `MemoTab`, not by passing a literal `extensionsEnabled: false`.
- [x] All four enumerated call sites are migrated — `memoComposer.test.ts:68-70`
      to the three-argument signature, and `:86-93`, `:108-111`, `:161-168` to the
      required-option form — with each recorded as a call-site update, not a
      weakening.
- [x] `MemoComposerControls.integration.tsx` gained exactly two
      `catalogAvailable` properties (`true` at `:19`, `false` at `:55`, each
      beside the `extensionsEnabled` line the plan cited as `:18`/`:53`) and no
      assertion change; its two tests still pass.
- [x] The resolving-catalog rendered test pins that the note-edit toggle stays
      ENABLED with memo-only ON.
- [x] No production file was edited by this task.

### TASK-011b: Restore the older-server capability gate

**Write Scope**: `web/src/notes/memoComposer.ts`,
`web/src/components/MemoTab.tsx`; no other production file

**Dependencies**: TASK-011a (the failing test must exist first)

**Parallelizable**: No; serializes with TASK-011 and TASK-011a on `web/src/`

**Scope decision — option (a), narrowly justified**: the plan takes the
restoration, not the out-of-scope declaration. The change is bounded by the
constraint rather than an exception to it: TASK-011a's design-mandated test
(`web-chatbook-ui.md:314`) fails against HEAD, and this is the minimum change
that failing check requires. Nothing beyond the capability gate may change.

**Deliverables**:

- Restore `agentComposerExtensionsEnabled(catalogAvailable, memoOnly, busy)` in
  `web/src/notes/memoComposer.ts:43`, matching the `b076a33` signature and its
  "Older servers do not understand either extension field" rationale.
- Thread a catalog-availability signal from the discovery effect at
  `web/src/components/MemoTab.tsx:130-139` into `extensionControlsEnabled` at
  `MemoTab.tsx:118`. The `.catch` branch currently sets `models([])` while
  leaving the model, attachment, and note-edit controls enabled.
- **The signal's source is whether the `agentModels` QUERY RESOLVED — true in
  `.then`, false in `.catch`, matching `b076a33` (`setAgentExtensionsAvailable(true)`
  unconditionally in `.then`, `false` in `.catch`).**
  `AgentModelsResult.discoveryAvailable` is explicitly NOT that signal. It exists
  (`web/src/notes/types.ts:164`), is fetched (`client.ts:456,465`), and is read by
  no production code — an unused boolean whose name invites exactly the wrong
  wiring. `discoveryAvailable: false` means the VENDOR could not enumerate models;
  per `web-chatbook-ui.md:154` and `ai-agent-integration.md:253` the configured
  model stays the fallback and the controls stay ENABLED. Only a failed
  `agentModels` query (an older server) disables them. Wiring
  `catalogAvailable = catalog.discoveryAvailable` would still satisfy TASK-011a's
  rejecting-stub test while silently breaking W11 on every vendor-enumeration
  failure — which is what TASK-011a's positive counterpart assertion exists to catch.
- Add the REQUIRED `extensionsAvailable: boolean` field to
  `AgentChatComposerRequestOptions` in `web/src/notes/memoComposer.ts` and guard
  all three optional spreads in the `buildAgentChatComposerRequest` body
  (`memoComposer.ts:146-148`), so `model`, `attachments`, and `mode: "edit"`
  cannot be emitted when the catalog is unavailable — satisfying
  `web-chatbook-ui.md:245` and `:255` (an older server would answer as a memo,
  which must never masquerade as an applied edit). Restoring only
  `agentComposerExtensionsEnabled` disables the controls but leaves the builder
  able to emit unsupported fields on any path that does not read the memo.
- Update the production builder call site at `MemoTab.tsx:301` to pass the new
  option. The four test-file call sites are TASK-011a's.
- **Gate the note-edit toggle on the CATALOG-AVAILABILITY term alone, not on the
  composite `extensionsEnabled`.** Thread the availability signal to
  `MemoComposerControls` as its own prop and write `MemoTab.tsx:585-586` as:

  - `aria-disabled={!props.catalogAvailable || (!props.canNoteEdit && !props.noteEdit)}`
  - `disabled={props.busy || !props.catalogAvailable || (!props.canNoteEdit && !props.noteEdit)}`

  Every existing term is kept exactly as it is today, and `aria-disabled` keeps
  its current busy-free semantics.
  **Why not `extensionsEnabled`:** `MemoTab.tsx:505` passes
  `extensionsEnabled={extensionControlsEnabled()}`, which after this task becomes
  `catalogAvailable && !memoOnly && !busy` (`MemoTab.tsx:117-118`). Using the
  composite would also disable the note-edit toggle whenever memo-only is ON
  against a fully catalog-available server, and would newly make `aria-disabled`
  reflect `busy`. That deadens a designed, implemented, tested affordance:
  `noteEditToggleResult` (`memoComposer.ts:84-86`) returns "Disable memo-only mode
  before enabling note edit mode.", asserted at `memoComposer.test.ts:147-149` and
  dispatched from `MemoTab.tsx:513`; a disabled button can never reach it, leaving
  an inert control whose tooltip still reads "Edit note mode". The DOM-free test
  would keep passing, so nothing planned would catch it. Widening past the
  catalog-availability term is therefore NOT required by any failing check and
  would breach this task's own "Do not change any other composer behavior" cap and
  the workflow constraint "do not change the implemented composer behavior beyond
  what a failing check requires". The composer keeps mutual exclusivity
  (`web-chatbook-ui.md:252`) through `noteEditToggleResult`'s explanation path, not
  through a disabled control.
  **Prop shape (binding on TASK-011a): add `catalogAvailable: boolean` as a
  REQUIRED prop on `MemoComposerControlsProps` (the interface at
  `MemoTab.tsx:530-551`; declare it beside `extensionsEnabled` at `:543`), passed at
  the `MemoTab.tsx:505` call site as the same availability signal that feeds
  `extensionControlsEnabled`.** Required matches the fail-closed rule this plan
  already adopted for `extensionsAvailable`: typecheck forces every call site to
  state its answer instead of silently inheriting a default. It also compels the
  `MemoComposerControls.integration.tsx` fixture migration that TASK-011a owns
  (see below) rather than letting an optional prop silently disable a control no
  test pins.
  This is NEW code, like the `mode: "edit"` builder guard: `b076a33` had no
  note-edit toggle at all (its `extensionsEnabled` gated only the file input at
  :491, the attach button at :499-500, and the model select at :522), and
  `canEnableNoteEdit` (`memoComposer.ts:68-75`) takes subject/note/notebook only,
  with no catalog input. It is required for TASK-011a's rendered negative test to
  pass POST-fix; without it that test fails both before and after and the web gate
  ends red. It also satisfies `web-chatbook-ui.md:254-257`: against an older server
  the builder withholds `mode`, so an enabled toggle would let a memo answer
  masquerade as an applied edit.
- **Restoration vs new code**: the `agentComposerExtensionsEnabled` signature and
  the `model`/`attachments` guards restore `b076a33` (`memoComposer.ts:77`,
  `:105-106`). `mode: "edit"` postdates `b076a33`, so gating it is NEW code
  satisfying `web-chatbook-ui.md:255`, not a restoration. Both are inside this
  task's justification; the distinction is recorded so the "restores a signature
  that existed at b076a33" framing is not over-read.
- **Restore `setAttachments([])` in the `.catch` branch**, as `b076a33` had
  (`MemoTab.tsx:445`). Without it, files staged before discovery settles
  unavailable keep their chips rendered while the builder silently withholds
  `attachments` — a silent drop, not the disabled-control behavior
  `web-chatbook-ui.md:245` describes.
  **REACHABILITY, established by probe on 2026-08-29 (not assumed):** because
  `catalogAvailable` initializes `false`, the file input renders DISABLED from
  first paint, so a real user cannot reach this ordering through the control
  today. A probe rendering `MemoTab` against a rejecting stub measured
  `picker.disabled === true`. The change handler is nevertheless LIVE — the same
  probe dispatched `change` on that disabled input and the chip rendered
  (`chipAfterDispatch === true`), because `change` is not in Solid's delegated
  event set and is therefore a direct `addEventListener` that fires regardless of
  `disabled`. So the clear is defensive rather than user-reachable, and it is
  worth keeping and pinning: any path that stages while discovery is still
  pending must not survive a failed catalog. TASK-011a's deferred-rejection test
  covers exactly that ordering and is mutation-verified load-bearing.
- **Explicitly excluded (1)**: `b076a33`'s `catalogAvailable` prop driving the
  "Attachments require a newer server" tooltip (`b076a33 MemoTab.tsx:497`). It is
  presentation-only and falls under the no-styling-changes cap below. Recorded as
  a deliberate exclusion rather than left unmentioned.
- **Explicitly excluded (2)**: the note-edit toggle's `title` expression at
  `MemoTab.tsx:584`, which stays
  `canNoteEdit || noteEdit ? "Edit note mode" : "Note edit mode requires a
  writable note"`. Consequence, accepted rather than fixed here: with a WRITABLE
  note and the catalog unavailable, the toggle renders disabled while its tooltip
  still reads "Edit note mode". The disabled state is what
  `web-chatbook-ui.md:254-257` requires; a third tooltip branch is presentation
  work under the same no-styling cap as exclusion (1). Named so it is a recorded
  consequence, not an unlabeled inconsistency.
  **RELEASE-PATH CARVE-OUT, added 2026-08-29 after Step 7 found a deadlock.**
  The exclusion above accepts stale tooltip TEXT, which is presentation. It must
  not be read as accepting the disabled BINDING in whatever form, because one
  form of it trapped the user. `!props.catalogAvailable` was originally added
  bare, without the `&& !props.noteEdit` escape the adjacent `canNoteEdit` term
  already carried, so a toggle already pressed when the catalog dropped could not
  be released — and with note edit still latched, the send refused, while
  memo-only refused with "Disable note edit mode before enabling memo-only mode."
  Every exit the UI offered pointed at a control the same commit had disabled.
  The binding now gates only the ON transition: note edit still cannot be turned
  on without a catalog (`web-chatbook-ui.md:254-257` holds), but it can always be
  turned OFF. The attachment analogue never had this trap — chip remove buttons
  carry no disabled binding — which is what shows the omission was accidental
  rather than a design choice.
- **`MemoComposerControls.integration.tsx` needs a two-line fixture migration,
  owned by TASK-011a, not by this task.** A REQUIRED `catalogAvailable` prop makes
  both `createComponent(MemoComposerControls, {...})` literals (`:7` and `:43`)
  miss a required property, and `web/tsconfig.json` includes `src`, so
  `bun run typecheck` — the first leg of `mise run web:check` — goes red on a file
  no production task writes. The migration is therefore compelled by the prop
  choice, not optional. Values: the `:7` test gets `catalogAvailable: true` beside
  its `extensionsEnabled: true` at `:18`; the `:43` test gets
  `catalogAvailable: false` beside its `extensionsEnabled: false` at `:53`. Both existing assertions survive
  unchanged: `:7` asserts `aria-label`/`title="Edit note mode"`, which the
  untouched title expression still produces; `:43` asserts `aria-disabled="true"`,
  already true from `canNoteEdit: false` and now also from `catalogAvailable:
  false`. No assertion is added, removed, or weakened there — the admissibility
  rule barring a literal-`false` catalog test in that file still stands. If either
  fixture changes later, re-check this.
- Do not change any other composer behavior: no styling, no keyboard handling,
  no request-shape change on the catalog-available path.
- Re-run `mise run web:check` after the fix and record the result.
- The three existing call sites at `memoComposer.test.ts:68-70` are migrated by
  TASK-011a, not here. This task's write scope stays capped at the two production
  files, which is what justifies the change under the workflow constraint.

**Completion Criteria**:

- [x] The TASK-011a regression test passes and its post-fix output is recorded.
- [x] Every line of this task's and TASK-011c's diff surface that a test can
      pin IS pinned, mutation-verified rather than assumed.
      **Evidence form (changed 2026-08-29): each mutation is recorded by the
      IDENTITY of the test it breaks, not by an "N passed" count.** Suite-relative
      counts proved structurally fragile — adding one test silently invalidates
      every previously recorded figure at once, which is exactly how this
      criterion drifted twice. A named failing test stays true no matter how many
      tests are added later. The suite size at the time of measurement is stated
      once, below, rather than repeated eight times.
      All eight mutations were EXECUTED against HEAD on 2026-08-29 at suite size
      20; each was reverted immediately and `git diff --stat` on `MemoTab.tsx`
      was empty afterwards.
      1. Drop `!props.catalogAvailable` from the toggle's `disabled` binding →
         breaks "an older server whose agentModels query rejects rests every
         composer extension control".
      2. Drop `setAttachments([])` from the `.catch` → breaks "a file staged
         before discovery settles unavailable does not keep its chip"; the chip
         `staged.txt ×` survives.
      3. Drop the `setError(...)` explaining that drop → breaks the same test
         with `expected '' to contain 'staged files were removed'`. Pinned
         2026-08-29 after Step 7 showed the line was unpinned AND undisclosed.
      4. Revert the Retry binding to `disabled={busy()}` → breaks "retrying a
         failed note-edit turn never silently downgrades it to a memo".
      5. Replace the transport-kind check with `if (false)` → breaks all THREE
         transport tests: the transient-recovery, never-clears, and
         post-exhaustion-reconnect tests. (Earlier rounds recorded two; the
         reconnect test added later also depends on the discriminator.)
      6. Delete the bounded retry → breaks the same three tests.
      7. Delete the `void app.state.catalogRevision` reconnect read → breaks
         "discovery recovers when the server becomes reachable again after the
         retry budget is spent".
      8. Narrow the generalized note-edit refusal back to its old
         `retry?.noteEdit && !catalogAvailable()` form → breaks "a direct send
         never downgrades a latched note-edit to a plain memo". Deleting the
         refusal outright breaks the same one test.
      10. Delete the attachment refusal → breaks "a direct send never silently
         drops staged attachments while the catalog is unavailable".
      11. Replace `retry ? 0 : attachments().length` with `attachments().length`
         → breaks "a memo retry during an outage is not refused for chips it
         would never send".
      12. Replace `retry ? retry.noteEdit : noteEdit()` with `noteEdit()` →
         breaks "retrying a failed note-edit turn never silently downgrades it
         to a memo", at the assertion that the retried REQUEST carries
         `mode: 'edit'`. **RE-DERIVED 2026-08-30; this entry read "breaks
         NOTHING" for one round after it stopped being true.** See the pinning
         record that replaced the former DISCLOSURE below for the cause.
      16-19. **Added 2026-08-30, from the first EXHAUSTIVE probe of the
         builder's retry arms rather than the one a reviewer named.** The
         builder takes four `retry ? … : …` arms and mutation 11 pins only the
         GUARD's copy of the attachments one. Probing all four:
         **16.** `const attachmentInputs = retry ? [] : await Promise.all(…)` →
         drop the retry arm. SURVIVED when first measured; now breaks "a retry
         ignores staged chips and a pending New chat". Non-equivalent: chips
         persist through an outage and nothing clears them on the retry path, so
         the mutant sends attachments on a retry — against the plan's own stated
         invariant that a retry never carries attachments.
         **17.** `newConversation: retry ? false : newConversation()` → drop the
         arm. SURVIVED; now breaks the same test. Non-equivalent: a pending New
         chat would turn a retry into the first message of a different
         conversation.
         **18.** `activeConversationId: retry ? retry.conversationId : activeConversationId()`
         → drop the arm. SURVIVED; now breaks the same test. Non-equivalent: the
         retry would post into whatever conversation the UI has selected rather
         than the failed turn's.
         **19.** `conversations: retry ? [] : conversations()` → drop the arm.
         SURVIVES, and is recorded as a **MEASURED EQUIVALENT MUTANT, not a
         gap.** `buildAgentChatComposerRequest` reads `conversations` only
         through `options.activeConversationId ?? latestConversationId(...)`, and
         on the retry path `activeConversationId` is `retry.conversationId`,
         typed `NotebookId` and always sourced from `entry.conversationId`. The
         right operand is never evaluated, so the mutant cannot differ. **A
         second equivalent mutant is recorded for the same reason:** re-reading
         `!catalogAvailable()` in place of `!extensionsAvailable` at the
         attachments guard survives, because the capture is assigned three lines
         above with no await between.
         **A THIRD SURVIVOR, in a DIFFERENT category:** dropping `busy()` from
         `send()`'s re-entry guard survives. It is NOT equivalent — a programmatic
         call while busy would differ — but it is unreachable through all three
         entry points, each busy-gated at the DOM. Its full derivation is at the
         pinning criterion above.
         **Surviving ≠ unpinned, and the two reasons are not the same reason.**
         All three were measured and then RULED OUT by reading — two as provably
         equivalent, one as unreachable — so a later round does not re-find them
         and "fix" a non-problem.
      15. **Added 2026-08-30 after the enumeration was found INCOMPLETE.**
         Revert the BUILDER ARGUMENT `noteEdit: effectiveNoteEdit` to its
         pre-`b05ebcc` form `noteEdit: retry ? retry.noteEdit : noteEdit()` →
         SURVIVED the entire gate when first measured, and now breaks "a mid-send
         read-only lock cannot downgrade an already-admitted note edit" with
         `expected { … } to match object { mode: 'edit' }`.
         **This is the enumeration's own blind spot, and it is worth stating
         plainly:** mutations 1-14 walk `send()`'s DEFINITION lines, and the
         capture has two halves — a definition and a USE. `extensionsAvailable`
         had its use pinned by the mid-send catalog-flip test; `noteEdit` did
         not, so half of the round's headline fix was unpinned while the plan
         asserted the opposite. An enumeration over definitions is not an
         enumeration over call sites. Rule 4 applies to mutation lists too.
      13. Restore the note-edit toggle's bare `!props.catalogAvailable` (drop the
         `&& !props.noteEdit` escape) → breaks "a latched note-edit toggle can
         still be released while the catalog is unavailable".
      14. Delete the `catalogAvailable` term from that binding entirely → breaks
         "an older server whose agentModels query rejects rests every composer
         extension control". **Both directions are pinned**, which is what makes
         the ON-transition gating load-bearing rather than merely present: 13
         proves the escape is needed, 14 proves the gate still is.
      **A THIRTEENTH measurement was run and its subject then DELETED rather
      than disclosed.** The refusal's `setError` was briefly a ternary with
      retry-specific wording; collapsing it to the single message left the suite
      green, so the untested branch was removed instead of shipped. One message
      now serves both paths.
      **EVERY SUB-EXPRESSION ON THE PROBED SURFACE IS PINNED, and the surface is
      named rather than left implicit: `send()`'s THREE guards — its re-entry
      guard `if (!body || busy()) return` plus its two refusal guards — its three
      capture definitions, and the builder's four `retry ? … : …` arms. TEN
      sites.** All three survivors are on it and are recorded with their
      ruling-out reasoning; nothing else on it survives.
      **The re-entry guard was added to this list on 2026-08-30, after the first
      draft said "two refusal guards" and then claimed three survivors on that
      nine-site surface.** Only two were: the `busy()` survivor lives in the
      re-entry guard, which the list did not name. It had been PROBED, so it
      belonged on the surface — the list was under-drawn, not the survivor
      misplaced. Membership is now checkable against the code: `grep -n 'if
      (!extensionsAvailable' web/src/components/MemoTab.tsx` gives the two refusal
      guards, and `grep -n 'if (!body'` gives the re-entry guard.
      **`send()`'s is meant literally.** That same `grep -n 'if (!body'` returns a
      SECOND hit, in `addMemoOnly()`. That guard was never probed, is not on this
      surface, and this wording must not be read as covering it.
      **This sentence read "NO sub-expression remains unpinned", unscoped, and
      was falsified FOUR times, three of them after being "corrected".** The
      unscoped form is retired for the reason the falsifications share: a claim
      whose scope is not stated cannot be checked, only disproved. A scoped claim
      can be re-measured, and that is the whole difference. All FOUR are named
      below, in the order they happened, because each was found by measurement
      after the previous had already "closed" it:
      **Two different counters run through this document and they are not the
      same number.** FOUR is how many times THIS SENTENCE was falsified — the
      list (i)-(iv) below. SEVEN is how many stale COPIES of a pinning claim have
      been corrected across the whole plan, counted in the risk register, and it
      is larger because one falsification can leave several copies stale at once.
      Neither number is the other, and the earlier wording "falsified SEVEN times
      — three of them after being corrected" conflated them.
      (i) It said "EXACTLY ONE remains unpinned … the RETRY ARM of
      `effectiveNoteEdit` (mutation 12)" until mutation 12 was re-executed
      against HEAD and came back CAUGHT — it breaks "retrying a failed note-edit
      turn never silently downgrades it to a memo" at the assertion on the
      retried request's `mode`. That DISCLOSURE is withdrawn, not reworded.
      (ii) The rewritten sentence was then ITSELF false, because the enumeration
      it summarizes stops at `send()`'s definition lines and never reached the
      BUILDER ARGUMENT `b05ebcc` introduced. Reverting `noteEdit:
      effectiveNoteEdit` to `noteEdit: retry ? retry.noteEdit : noteEdit()` left
      the entire gate green — half the round's headline capture was unpinned
      under a sentence claiming none was. Closed by measurement, not by wording:
      mutation 15 and the new test "a mid-send read-only lock cannot downgrade an
      already-admitted note edit" kill it.
      (iii) And the sentence was STILL false after (ii), because fixing the arm a
      reviewer named is not the same as applying the rule the fix stated. The
      first exhaustive probe of the builder's four retry arms found THREE more
      survivors — mutations 16, 17 and 18 — all closed by one new test, "a retry
      ignores staged chips and a pending New chat". **The claim now rests on an
      exhaustive probe rather than on a list someone believed was complete**, and
      it is stated with its two measured exclusions: mutation 19 and the
      attachments-guard re-read are EQUIVALENT mutants, ruled out by reading
      rather than left as open gaps.
      (iv) It was then false a FOURTH time, on a site outside the builder
      entirely: dropping the `busy()` term from `send()`'s re-entry guard
      (`if (!body || busy()) return` → `if (!body) return`) SURVIVES the whole
      web leg. That is the THIRD survivor — third SURVIVOR, fourth
      FALSIFICATION; the two counts differ and are deliberately not merged. It is
      **not** an equivalent mutant
      — it is UNREACHABLE-BY-EVERY-ENTRY-POINT, a weaker and separately stated
      category. Verified by reading all three call paths into `send()`, each
      busy-gated at the DOM before the guard is reached: the submit button
      (`disabled={props.busy || !props.draft.trim()}`), the textarea keydown
      (`handleComposerKeyDown` via `composerKeyDownAction`, which returns `'none'`
      when busy), and the Retry button (`disabled={busy() || …}`). A programmatic
      call while busy WOULD differ, so the term is real defense-in-depth rather
      than dead code — which is why it is written down here instead of being
      called equivalent and forgotten.
      **This clause was written as "(iv) … a THIRD time" and placed ABOVE the
      third clause on 2026-08-30.** It was appended where the author was reading
      rather than where it belonged, so the list ran (i), (ii), (iv), (iii) and
      two clauses claimed the third slot. Moved and re-ordinalled the same day.
      The ordering is checkable, and the check is SCOPED TO THE LIVE REGION for
      the same reason rules 1 and 2 are — dated Progress Log entries quote these
      markers by design and would otherwise register as extra clauses:

          PL=$(grep -n '^## Progress Log$' impl-plans/active/right-pane-agent-composer.md | head -1 | cut -d: -f1)
          awk -v n="$PL" 'NR<n' impl-plans/active/right-pane-agent-composer.md \
            | grep -cE '^[[:space:]]+\((i|ii|iii|iv)\)'

      It must return 4, and `grep -n` on the same region must give strictly
      ascending line numbers. This paragraph says "the third clause" in prose
      rather than reprinting its marker for that reason. The first draft of this
      paragraph reprinted it, registered as a fifth clause, and was caught by
      running the sweep; the progress entry recording the fix then did it a
      second time and was caught the same way.
      **The cause, recorded so this does not rot a third time.** `b05ebcc` is
      what pinned it, and pinned it as a side effect nobody re-derived: that
      commit changed the builder from re-reading `retry ? retry.noteEdit :
      noteEdit()` to consuming the guard local `effectiveNoteEdit`. That made
      the local OBSERVABLE in the outgoing request, so a mutation to it now
      changes a request the suite already asserts on. The disclosure was
      measured before that commit and carried forward through it unre-derived.
      **This is the third failure of one kind and the rule that follows from it
      is stated at the evidence criterion as rule 5:** a mutation RESULT is a
      measurement of a tree, exactly like a line number is a pointer into one.
      It must be re-executed against HEAD, not recalled — and re-executing one
      copy of a mutation claim does not re-execute the others, which is why all
      four live mutation citations were re-run this round, not just the flagged
      one.
      **Retained because it is still instructive:** the derivation that used to
      justify this arm as unreachable stopped at the retry call site and never
      continued to the DIRECT call site, which was both reachable and unguarded
      — the HIGH finding of 2026-08-29. A derivation must enumerate every call
      site, not the first one that explains the measurement. The lesson now has a
      companion: a derivation, however complete, expires when the code it
      describes changes.
      9. Delete `setCatalogAvailable(false)` from the `.catch` → breaks "a
         server that stops understanding agentModels mid-session rests the
         controls again". **This line was DISCLOSED as an unpinned no-op for
         several rounds; that disclosure was FALSIFIED on 2026-08-29 and is
         withdrawn.** It stopped being a no-op the moment the reconnect trigger
         made discovery re-runnable: the `.catch` can now fire after a success,
         so this is the write that returns `catalogAvailable` to false on a
         mid-session server rollback. It is live code enforcing the headline
         invariant, and it is now pinned rather than disclosed.
      **Why re-running the mutation could never have caught this:** "deleting it
      leaves the suite green" is equally consistent with "dead code" and with
      "live code no test reaches". The disclosure was re-confirmed by
      re-measurement for several rounds while its RATIONALE silently went stale
      under a later change. A disclosure has to be re-DERIVED when the
      surrounding code changes, not just re-measured.
- [x] `mise run web:check` is green after the change, with recorded counts.
- [x] The diff touches only this enumerated surface and nothing else: the
      `agentComposerExtensionsEnabled` signature; the `extensionsAvailable`
      request-options field and its three guarded spreads; the
      `extensionControlsEnabled` memo; the availability signal and both discovery
      branches including `setAttachments([])`; the `MemoTab.tsx:301` builder
      call; the REQUIRED `catalogAvailable` prop on `MemoComposerControlsProps`
      and its `MemoTab.tsx:505` call-site value; and the note-edit toggle's
      `aria-disabled`/`disabled` bindings at `MemoTab.tsx:585-586`, which gain
      `!props.catalogAvailable` and nothing else. Verified against
      `git diff -- web/src/components/MemoTab.tsx web/src/notes/memoComposer.ts`.
- [x] The toggle's new term is `props.catalogAvailable`, NOT
      `props.extensionsEnabled`; memo-only ON against an available catalog leaves
      the toggle enabled so `noteEditToggleResult`'s "Disable memo-only mode
      before enabling note edit mode." explanation is still reachable, and
      `aria-disabled` still does not reflect `busy`. Pinned by the rendered
      positive test's memo-only assertions.
- [x] The note-edit toggle's title expression is unchanged. Cited by token, not
      by coordinate: the expression ending
      `: 'Note edit mode requires a writable note'` is byte-identical in
      `git diff -- web/src/components/MemoTab.tsx`. (Its planning-frame
      coordinate was `MemoTab.tsx:584`. The "now `:600` after the insertions"
      form this criterion carried until 2026-08-30 was itself a rotted pointer,
      which is why the current-state half is now a token; the 2026-08-30 progress
      entry records where it had actually drifted to.)
- [x] **The tooltip consequence of the binding above is stated here, beside the
      binding, not only in the analysis section.** The toggle gains
      `!props.catalogAvailable` in `disabled`/`aria-disabled` while the title
      expression stays untouched, so with a WRITABLE note (`canNoteEdit` true)
      and the catalog unavailable the toggle renders disabled and its tooltip
      still reads "Edit note mode". That is accepted, not overlooked: the
      disabled state is what `web-chatbook-ui.md:254-257` requires, and a third
      tooltip branch is presentation work under the same no-styling cap that
      excluded the "Attachments require a newer server" tooltip. The two
      exclusions are therefore symmetric and both are named at their own
      control's criterion — the asymmetry three review rounds kept re-finding
      was that only the attachment half was named where the change was
      enumerated.
- [x] The availability signal is driven by whether the `agentModels` query
      resolved, NOT by `AgentModelsResult.discoveryAvailable`.
      Evidence: `grep -n discoveryAvailable web/src/components/MemoTab.tsx`
      returns exactly one line, `:135`, and it is the COMMENT naming
      `discoveryAvailable` as NOT the signal; no expression in the file reads
      `catalog.discoveryAvailable`. The field's only readers remain
      `web/src/notes/client.ts:456,465` (fetch/projection) and its declaration at
      `web/src/notes/types.ts:164`, exactly as at HEAD.
- [x] No existing test was weakened, skipped, or deleted.

### TASK-011c: Close the adversarial review's two capability-gate defects

**Write Scope**: `web/src/components/MemoTab.tsx` (production),
`web/src/components/MemoTab.integration.tsx` (tests). No other file.

**Dependencies**: TASK-011b. Both defects are in code TASK-011b introduced.

**Rationale**: the adversarial gate reproduced two defects with probes that
HEAD's suite did not cover. Both are authorized under "do not change the
implemented composer behavior beyond what a failing check requires" because a
failing check now exists for each, written before the fix.

**Deliverables**:

- **HIGH — the Retry path bypassed the capability gate.** `Retry` was gated on
  `busy()` alone and takes `noteEdit` from the PERSISTED turn (`turn.mode ===
  'edit'`), never from the toggle, while `send()` passes
  `extensionsAvailable: catalogAvailable()`. Retrying a failed edit turn before
  discovery settled therefore withheld `mode: "edit"` from a fully capable
  server: the server answered as a plain memo, the turn reported answered, and
  the note was never edited — the exact masquerade `web-chatbook-ui.md:254-257`
  forbids and this whole task exists to prevent. FIX: the Retry button is
  disabled for an edit turn while `!catalogAvailable()`, and `send()` refuses a
  `retry.noteEdit` send with an explanation rather than downgrading it.
- **MID — every rejection kind was read as "older server".** `NoteTransportError`
  carries `kind: 'network' | 'http' | 'graphql' | 'result' | 'registration'`
  (`client.ts:42-51`), and only a `graphql` rejection is the unknown-field case
  that proves an older server. The `.catch` collapsed all of them, and the effect
  never retried, so one network blip rested every extension control for the whole
  session against a capable server. FIX: only a non-`graphql` `NoteTransportError`
  is treated as transport failure — retried up to `catalogDiscoveryAttempts` (3)
  and then reported via `setError` — while a `graphql` rejection keeps the
  original older-server behavior.
  **CORRECTED 2026-08-29 (adversarial review), because the first wording
  overstated this:** three immediate attempts with no backoff are consumed in
  milliseconds, so they do NOT survive a real outage — a server restart, wifi
  handoff or sleep/wake outlives the whole budget. Claiming "a blip no longer
  rests every control for the session" was therefore credit the code had not
  earned. What actually delivers session recovery is the effect's read of
  `app.state.catalogRevision`, which the store increments ONLY after a catalog
  reload succeeds (`grep -n "setState('catalogRevision'" web/src/state/appStore.tsx`)
  and which the sibling reload effect already consumes — `grep -n 'void
  app.state.catalogRevision' web/src/components/MemoTab.tsx` returns TWO hits,
  the discovery effect and that sibling. The immediate budget covers a one-shot
  blip; the reconnect trigger covers everything longer. Both are needed, and
  only the pair makes the banner's "until it loads" wording true.
- The older-server branch now explains the attachment drop before clearing, and
  only when files were staged. PINNED 2026-08-29 by an added assertion in the
  existing deferred-rejection test, after Step 7 mutation-showed the line
  survived deletion; deleting the `setError(...)` now fails that test with
  `expected '' to contain 'staged files were removed'`.
- The unreachable banner is retired by `load()`'s existing unconditional
  `setError('')` (`grep -n "setError('')" web/src/components/MemoTab.tsx` — the
  hit inside `load()`), which re-runs on the same
  `catalogRevision` bump that re-runs discovery. A dedicated clear was written,
  measured as UNPINNED (deleting it left the suite fully green because `load()`
  had already cleared the banner), and REMOVED rather than shipped with a
  DISCLOSURE. (At the time that decision was made two DISCLOSURE boxes stood and
  this would have been a third; both have since been falsified by re-measurement
  and converted to pinned criteria, so the plan now carries none. The decision to
  remove the line rather than disclose it is unaffected — it stands on the line
  being a no-op, which was and remains true.)

**Deliverables (added 2026-08-29, Step 7 regression round)**:

- **The reconnect trigger introduced a regression, now fixed.** Making discovery
  re-runnable meant the `.catch` could fire AFTER a success, and its
  unconditional `setModels([])` ran before the transport-kind check. The
  normalization effect then evaluated
  `normalizeSelectedAgentModel(selected, [], configuredModel)`, which returns
  `configuredModel`, so `updateSettings` overwrote and debounce-persisted the
  user's chosen model — silently, with the controls re-enabled and no banner.
  FIX: `setModels([])` moved BELOW the `kind !== 'graphql'` early return, so a
  retryable blip leaves the catalog intact and only a genuine older-server
  verdict clears it.
- **Generation guard.** `catalogRevision` is bumped by a debounced refresh, so a
  slow request can settle after a newer one. Both `.then` and `.catch` now bail
  on `requested !== catalogGeneration`, the same idiom `load()` uses.
- **Per-outage retry budget.** `setCatalogAttempt(0)` on success, so a later blip
  gets a fresh set of immediate attempts instead of being condemned on its first
  try by a budget an earlier outage already spent.

**Completion Criteria**:

- [x] Three new tests were recorded FAILING pre-fix and pass post-fix.
- [x] The Step 7 regression round added three more, each mutation-verified by
      the IDENTITY of the test it breaks: moving `setModels([])` back above the
      kind check breaks "a transient discovery failure after a success does not
      rewrite the persisted model"; dropping the `.catch` generation guard breaks
      "a stale discovery rejection cannot overwrite a newer successful one";
      dropping `setCatalogAttempt(0)` breaks "a success refreshes the retry
      budget so a later blip is retried, not condemned".
      **Both of the latter two tests were first written in a VACUOUS form that
      passed with the line deleted** — the stale-rejection one because a stale
      NETWORK rejection self-heals via the retry, and the budget one because it
      asserted a control that was already enabled. They were sharpened (stale
      GRAPHQL rejection; assert the banner's absence) until each discriminates.
      Recorded because a test that looks load-bearing and is not is exactly what
      the mutation discipline exists to catch.
- [x] **Evidence is recorded as CONTENT, never as a pointer** — the rule five
      separate rounds each learned the hard way, in five shapes. Shapes 4 and 5
      were both added 2026-08-30; the Progress Log sentence beginning "The
      generalization, now stated once for all three shapes" was true when
      written and is left as that round's record, cited by its own words rather
      than a line number since a plan-internal coordinate shifts on any plan
      edit. A pointer is valid-looking after it rots and nothing goes red;
      content can be re-derived from the tree. The five pointer forms are a
      count, a line number, an unrewritten claim, a partial list, and a recorded
      mutation result — every one of them a fact ABOUT a tree, stored outside
      that tree, where nothing re-checks it. Concretely, and each half
      checkable:
      1. **Counts** — no live criterion carries a suite-relative count.
         The sweep is `grep -nE '[0-9]+ (failed|passed)'` above the Progress
         Log, and it returns nothing. **WIDENED 2026-08-30 from
         `[0-9]+ failed / [0-9]+ passed`.** The narrow form matched one
         SPELLING of a count rather than the class the rule names, so a
         pipe-separated failed/passed pair sat in the swept region for a round
         while the sweep reported clean. A check that matches a spelling instead
         of a class is the same defect as a pointer that matches a location
         instead of a fact.
         **The withdrawn figure's digits are deliberately NOT reproduced here or
         in the criterion that carried them.** Writing them out would make this
         document match its own widened sweep and falsify the "returns nothing"
         claim in the same edit that widened it — which is what the first draft
         of this correction did, caught by running the sweep. A withdrawn count
         is recorded as "a count stood here", never as the count.
      2. **Claims** — a corrected claim is rewritten at EVERY copy, not
         contradicted at one. Grep the claim's own words before recording it
         corrected.
      3. **Coordinates** — a CURRENT-STATE claim about the CODE cites by
         searchable token (a test name, a distinctive expression), never
         `File.ts:NNN`. Planning-era text inside the TASK write-scope blocks
         keeps its PRE-FIX coordinates deliberately: those describe the tree the
         plan was written against. The criterion recording that the note-edit
         title expression is unchanged used to carry BOTH frames ("now `:600`
         after the insertions"); that exemplar was withdrawn on 2026-08-30 after
         the current-state half rotted to a wrong line. A planning-frame
         coordinate may be kept and labelled as such, but the current-state half
         must be a token, never a second coordinate — a second coordinate is
         just another pointer and rots the same way.
      4. **Enumerations** — added 2026-08-30, after this same shape recurred
         three rounds running, each time one level further down: a list of what a
         commit contains is GENERATED from `git show --numstat <sha>` and
         `git show <sha> -- <file> | grep '^@@'`, never written from memory. An
         enumeration fails the way a count and a coordinate fail — it stays
         readable while going incomplete, and an incomplete enumeration reads as
         "that is all of it". The corollary that actually caught the recurrences:
         **when a fact is stated for one member of a set, state it for every
         member or say why it does not apply.** Three rounds each flagged one
         silent member — the note-edit tooltip beside the named attachment
         tooltip, `MemoTab.integration.tsx`'s carry-forward beside
         `MemoTab.tsx`'s, and the plan file's carry-forward beside both. Silence
         about the third case is what the rule now forbids. A fourth instance
         landed the same round from the other direction: the atomicity sentence
         listed `attachments` alongside `mode` as protected by the capture when
         only `extensionsAvailable` and `noteEdit` are captured — an enumeration
         that was too LONG rather than too short. Both directions fail the rule.
      5. **Mutation results** — added 2026-08-30, after a mutation claim went
         stale in three consecutive rounds, each time in a different box. A
         mutation RESULT is a measurement of a tree, exactly as a line number is
         a pointer into one, and it rots the same way: the code moves, the
         sentence does not, and nothing goes red. Every mutation a live
         criterion cites by number is RE-EXECUTED against HEAD before the plan
         is submitted, never carried forward from a recorded outcome. Two
         corollaries, both learned the hard way: re-executing one copy of a
         mutation claim does not re-execute the others (a mutation claim lives
         in more than one box — mutation 12's did, in two); and the commit that
         changes the code a disclosure describes is the commit that owes the
         re-derivation, which is exactly what `b05ebcc` failed to do. The
         2026-08-30 sweep re-ran every LIVE citation — mutations 4, 8 and 12 —
         plus mutation 11, whose only citation sits in the Progress Log and
         which was re-run anyway. 12 was the one that had gone false. The
         live/Progress-Log split is itself derived, not recalled: classify each
         hit of `grep -noE 'mutation(s)? [0-9]+'` against the line of
         `grep -n '^## Progress Log'`.
      **SCOPE, stated so the rule does not outrun its check.** Rule 3's sweep is
      `grep -noE '(MemoTab\.tsx|MemoTab\.integration\.tsx|appStore\.tsx):[0-9]+'`
      restricted to the current-state regions — i.e. exactly the CODE files this
      commit modifies. It does NOT cover, and rule 3 therefore does NOT claim:
      plan-internal `` `:NNN` `` self-references, or design-doc citations
      (`web-chatbook-ui.md:36` and friends). Both are excluded for a stated
      reason, not overlooked. Design-doc coordinates point at files this commit
      never edits, so they cannot shift from this work. Plan-internal
      self-references CAN shift on any plan edit and are the weaker case — they
      are avoided in live criteria as a convention rather than enforced by grep,
      because criteria are interleaved with TASK blocks in this document and no
      line-range predicate separates them. **This scope note exists because the
      first version of rule 3 stated the rule wider than its grep and then broke
      it in its own sentence** by citing a plan-internal coordinate; the check
      passed anyway, because the pattern could not see it. A check that passes
      proves only what it covers.
      Verified 2026-08-29 by re-resolving every code citation above the Progress
      Log against the tree: the three current-state ones were stale and are now
      token-based, and the rest are pre-fix-frame or in `client.ts`, which this
      commit never modifies (`git diff 50b0470 HEAD -- web/src/notes/client.ts`
      is empty, so its coordinates cannot have shifted).
- [x] Each fix is mutation-verified load-bearing, recorded by the IDENTITY of
      the test it breaks rather than by a suite-relative count (see TASK-011b's
      criterion for why). **NO live criterion carries a suite-relative count at
      all**, and that is checkable rather than intended: `grep -nE '[0-9]+
      failed / [0-9]+ passed'` over the lines above the Progress Log returns
      nothing. The rule needed this numeric form because the prose-level
      "grep every copy of a claim" rule could not catch it — a stale FIGURE is
      invisible to a grep for the sentence that carries it, and one slipped
      through in the very round that rule was written. Dated progress entries
      keep their counts; they record what was measured on their dates: reverting the Retry binding to `disabled={busy()}`
      breaks "retrying a failed note-edit turn never silently downgrades it to a
      memo"; replacing the kind check with `if (false)` breaks all THREE
      transport tests; deleting the bounded retry breaks the same three.
      Re-executed against HEAD 2026-08-29.
- [x] **The RETRY ARM of `effectiveNoteEdit` is PINNED. This box was a
      DISCLOSURE claiming the opposite until 2026-08-30; it is converted, not
      reworded.** It read: the retry arm is "defense-in-depth that no test
      reaches", and "replacing the whole expression with `noteEdit()` leaves the
      suite fully green (mutation 12)". Re-executed against HEAD on 2026-08-30,
      that mutation is CAUGHT: it fails
      `MemoTab.integration.tsx > MemoTab integration > retrying a failed
      note-edit turn never silently downgrades it to a memo`, at the assertion
      that the retried request carries `mode: 'edit'`.
      **Recorded by the IDENTITY of the test it breaks**, per rule 1; the count
      belongs to the dated progress entry, not here. **This box carried a
      suite-relative failed/passed figure for the length of one review round
      while the sentence you are reading contradicted it in the same breath** —
      a count in a live criterion, introduced by the very edit that was fixing a
      stale measurement. Rule 1's sweep missed it because the figure used a PIPE
      where the sweep expected a slash; the sweep is now widened to match the
      rule it checks, and the figure's digits are not reproduced here for the
      reason rule 1 now states.
      **Why it changed, stated so the next round does not have to rediscover
      it.** `b05ebcc` pinned this arm without anyone noticing: it routed the
      builder through the guard local `effectiveNoteEdit` instead of re-reading
      `retry ? retry.noteEdit : noteEdit()`. That made the local observable in
      the outgoing retry request, so mutating it now changes a value the suite
      already asserts on. The commit that broke the disclosure did not re-derive
      it — the same omission this box has now recorded three times, and the
      reason rule 5 exists.
      **Two things this box previously got right are kept.** (1) Its NARROWING
      history: it once disclosed the entire `send()` refusal for
      `retry.noteEdit && !catalogAvailable()` as unreached, which went stale
      when the guard was generalized to the effective request; deleting that
      refusal now breaks "a direct send never downgrades a latched note-edit to
      a plain memo", and mutation 8 is the NARROWING mutation, not the deletion
      — re-confirmed against HEAD 2026-08-30. (2) Its reason for carrying no
      figure: a suite-relative count stood here and was itself stale, and was
      deleted rather than refreshed because refreshing only resets the clock.
      **Consequence for the arithmetic:** there is now no DISCLOSURE box in this
      plan, so the unchecked count drops from 7 to 6 and the plan-location
      criterion's breakdown is updated to match.

### TASK-012: Execute the full Swift sweep

**Write Scope**: no file unless a sweep step fails; on failure, only the
narrowest implicated file

**Dependencies**: TASK-010

**Parallelizable**: No; shares `.build/` with TASK-010

**Deliverables**:

- Run `mise run lint`, `mise run test`, and `mise run build`, recording each
  command's real output.
- Distinguish the pre-existing `large_tuple` SwiftLint warning in
  `NoteService.swift` from any warning this feature introduced; do not silence
  the pre-existing one as part of this work.
- Record any native-link or toolchain blocker with the exact command, an output
  summary, the reason, and the checks it leaves unaffected.
- `mise run tauri:check` is deliberately excluded, not overlooked. `AGENTS.md:32-37`
  and `tauri-client-apps.md:159-171` define the repository gate set as
  `mise run check` = test + lint + web:check + tauri:check, but no write scope in
  TASK-010 through TASK-014 includes a Rust or Tauri path, so this work leaves
  `mise run check`'s tauri leg unaffected. Record this as a decision, not a gap.

**Completion Criteria**:

- [x] Each of the three commands has recorded executed output or a recorded
      environment blocker. `mise run lint`, `mise run test`, and `mise run build`
      all exited 0 on 2026-08-29.
- [x] The `tauri:check` exclusion is recorded as a decision with its rationale.
- [x] No new lint warning is attributable to this feature. SwiftLint reports
      exactly 2 violations, 0 serious, in 181 files: the pre-existing
      `large_tuple` at `Sources/AppCore/NoteService.swift:572` and a second
      pre-existing `large_tuple` at
      `Sources/AppCore/ResendGatewayCLIMailSender.swift:75`. Neither file is in
      any write scope of this feature, and neither was silenced.
- [x] A command-wrapper timeout is reported as a tooling limitation, never as a
      pass. No command timed out in this closeout.

### TASK-013: Resolve the browser-runtime checks or record them as blocked

**Write Scope**: `design-docs/user-qa/web-chatbook-ui.md` Status section only if
the user answers Question 1; otherwise no file but this plan

**Dependencies**: TASK-011b. The smoke must run against a `web/dist` built
AFTER TASK-011b, or it records browser-runtime evidence against composer
behavior that TASK-011b then changes.

**Parallelizable**: Yes with TASK-010 and TASK-012

**Deliverables**:

- Attempt the manual smoke list below against `kaiba serve --web-root web/dist`.
- If no browser runtime is available, record each of TASK-008's three criteria
  as environment-blocked with the exact attempted command, the output summary,
  and the reason, and state which checks remain unaffected.
- Do not add a headless-browser dependency to `web/package.json`'s `check`
  script; that is the open user decision in
  `design-docs/user-qa/web-chatbook-ui.md` and is not authorized by this issue.

**Completion Criteria**:

- [x] Each browser-runtime item is either executed with recorded evidence or
      openly recorded as environment-blocked. All are BLOCKED; see the
      2026-08-29 TASK-013 progress entry for the attempted commands and output.
- [x] No browser-runtime checkbox is marked from CSS reading or static review.
      TASK-008's three criteria remain unchecked.
- [x] The user-QA question remains open unless the user answers it. It was not
      answered, so `design-docs/user-qa/web-chatbook-ui.md` is unchanged by
      TASK-013 and no headless-browser dependency was added.

### TASK-014: Reconcile the plan with the evidence and commit the scoped change

**Write Scope**: `impl-plans/active/right-pane-agent-composer.md`. The commit
enumerates every path this closeout changed:

1. `design-docs/specs/ai-agent-integration.md`
2. `design-docs/specs/web-chatbook-ui.md`
3. `design-docs/user-qa/web-chatbook-ui.md` (new file)
4. `impl-plans/active/right-pane-agent-composer.md`
5. `web/src/notes/memoComposer.test.ts` (TASK-011a)
6. `web/src/components/MemoTab.integration.tsx` (TASK-011a)
7. `web/src/components/MemoComposerControls.integration.tsx` (TASK-011a,
   fixture migration compelled by TASK-011b's required `catalogAvailable` prop)
8. `web/src/notes/memoComposer.ts` (TASK-011b)
9. `web/src/components/MemoTab.tsx` (TASK-011b)

plus any file a failing check forced TASK-010 through TASK-012 to change. Path 2
is committed for its Traceability and Verification edits only; TASK-001's
screenshot-date change is RETRACTED and `:36` is not touched. Paths 5-9 are NOT
"changed by a failing check" — TASK-011a's three files CREATE the failing check
(the third is a compelled fixture migration) and TASK-011b's two files answer it — so an enumeration limited to
failing-check fallout would commit a plan claiming the gate is restored while the
restoration and its tests stay unstaged.

**Dependencies**: TASK-010, TASK-011, TASK-012, TASK-013

**Parallelizable**: No

**Deliverables**:

- Update every checkbox from executed evidence only, leaving blocked items
  unchecked with their blocker recorded.
- Append a dated progress entry naming files changed, exact commands and
  results, decisions, residual risks, and the completion date.
- Keep the plan in `impl-plans/active/` while any deliverable is unmet; move it
  to `impl-plans/completed/` only when every deliverable is genuinely satisfied.
- Commit only this work's files with `git add <path>` for each path. Never
  `git add -A` or `git add .`, and never stage `README.md`. Do not push.

**Completion Criteria**:

- [x] Checkbox state, the progress log, and the recorded output agree.
- [x] `git status --short` after the commit shows ONLY ` M README.md` — every
      path this closeout changed is staged and committed, and `README.md` remains
      unstaged pre-existing work.
- [x] The plan's location matches the actual deliverable state. Blocker 2 below
      is now RESOLVED (TASK-011a/TASK-011b landed and are green); blocker 1
      remains, so the plan stays in `impl-plans/active/`.
- [x] The move to `impl-plans/completed/` is gated on BOTH named blockers, not
      only the browser-runtime one:
      1. TASK-008's three browser-runtime criteria — STILL BLOCKED. No browser
         runtime is installed on this machine and adding a headless one is the
         open user decision in `design-docs/user-qa/web-chatbook-ui.md`.
      2. The older-server capability deliverable (TASK-006, TASK-009's
         older-server clause) — RESOLVED 2026-08-29. TASK-011a's two negative
         tests were recorded failing pre-fix and TASK-011b made them pass, so
         `web-chatbook-ui.md:245` and `:255` are no longer an open
         design-conformance defect.
- [x] The 2026-08-13 progress entry claiming "model/attachment capability
      gating" is directly tested is annotated as superseded by `fb3997a`.
- [x] RETRACTED items (TASK-001's screenshot-date deliverable and its
      matching criterion) are recorded as withdrawn with their decision, and are
      NOT counted as unmet deliverables when deciding the plan's location.

## Dependencies and Execution Order

1. TASK-001 establishes accepted documentation and baseline.
2. TASK-002 defines shared validation contracts.
3. TASK-003 establishes durable atomicity before any UI can send attachments.
4. TASK-004 completes invocation data flow; TASK-005 then freezes GraphQL shape.
5. TASK-006 builds the web contract/state layer; TASK-007 consumes it.
6. TASK-008 completes visual behavior; TASK-009 integrates and verifies all layers.
7. Verification closeout: TASK-010 (focused Swift) precedes TASK-012 (full Swift
   sweep) because both drive `.build/`. The web chain is strictly ordered
   TASK-011 (baseline gate run) -> TASK-011a (coverage audit + failing
   regression test) -> TASK-011b (capability-gate fix + green gate re-run).
   TASK-013 (browser runtime) needs TASK-011b's rebuilt `web/dist`. TASK-014
   waits for the whole Swift chain, the whole web chain, and TASK-013.

No model or attachment UI is enabled before TASK-003 through TASK-005 are complete.

## Parallel Work Map

- TASK-008 CSS may proceed alongside focused Swift test additions in TASK-009.
- TASK-009 final integration waits for TASK-008 even when its Swift test authoring
  starts concurrently.
- The web chain (TASK-011, TASK-011a, TASK-011b) may run alongside TASK-010 and
  TASK-012: it writes under `web/` and `node_modules/`, while the Swift commands
  write under `.build/`.
- TASK-011, TASK-011a, and TASK-011b are NOT parallel with each other. TASK-011a
  writes `memoComposer.test.ts`, `MemoTab.integration.tsx`, and the two fixture
  literals in `MemoComposerControls.integration.tsx`; TASK-011b writes
  `memoComposer.ts` and `MemoTab.tsx`; TASK-011a's assertions exercise the
  signature TASK-011b restores, so the tests must exist and fail before the fix.
- TASK-013 may run alongside the Swift chain once TASK-011b has produced a
  post-fix `web/dist`.
- TASK-010 and TASK-012 must not run concurrently; both drive the same SwiftPM
  `.build/` directory.
- TASK-014 is strictly serial. It is not the only closeout task that writes files:
  TASK-011a writes three test files and TASK-011b writes two production files, and
  TASK-010/011/012 may write a narrowest-implicated file on failure. TASK-014 is
  the only task that writes the plan itself and the only one that commits.
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
  design-docs/user-qa/web-chatbook-ui.md \
  impl-plans/active/right-pane-agent-composer.md

# Focused Swift suites. `PKG_CONFIG_PATH` is task-scoped in mise.toml, so
# `mise exec` alone supplies the toolchain but not the variable; a bare
# `swift test --filter` outside this form can fail at native linking and its
# result is not evidence (ai-agent-integration.md item 11).
mise run anydoc:native
PKG_CONFIG_PATH="$PWD/.build/anydoc-native/host/pkgconfig" mise exec -- \
  swift test --filter AgentChatTests
PKG_CONFIG_PATH="$PWD/.build/anydoc-native/host/pkgconfig" mise exec -- \
  swift test --filter AgentGatewayCLIInvokerTests
PKG_CONFIG_PATH="$PWD/.build/anydoc-native/host/pkgconfig" mise exec -- \
  swift test --filter AgentChatGraphQLTests

# The web gate has one definition. Do not substitute the four `bun run`
# scripts it wraps (web-chatbook-ui.md, tauri-client-apps.md:159-171).
mise run web:check

mise run lint
mise run test
mise run build

# `mise run tauri:check` (the fourth leg of `mise run check`, per AGENTS.md:32-37)
# is excluded by decision: no closeout write scope includes a Rust or Tauri path.

# Gate-coverage audit (TASK-011a) — the gate proves existing tests pass, not that
# the design's required tests exist.
sed -n '309,316p' design-docs/specs/web-chatbook-ui.md
grep -rn "test(" web/src/notes/memoComposer.test.ts
grep -n "agentComposerExtensionsEnabled" web/src/notes/memoComposer.ts \
  web/src/components/MemoTab.tsx
# The gate's two runners cover disjoint file patterns: `bun test src` matches
# *.test.ts; web/vitest.config.ts includes only src/**/*.integration.tsx.
find web/src -name "*.test.ts" -o -name "*.integration.tsx"

# Focused pre-fix/post-fix runs for TASK-011a and TASK-011b.
(cd web && mise exec -- bun test src/notes/memoComposer.test.ts)
(cd web && mise exec -- bun run test:integration)
# Facts behind TASK-011a's admissibility rule and the call-site migration.
sed -n '43,70p' web/src/components/MemoComposerControls.integration.tsx
grep -n 'extensionsEnabled' web/src/components/MemoTab.tsx
# Surfaces all four TASK-011a migration sites (:68-70, :86-93, :108-111, :161-168)
# from one command rather than spot-checking one.
grep -n 'agentComposerExtensionsEnabled\|buildAgentChatComposerRequest' \
  web/src/notes/memoComposer.test.ts
# The note-edit toggle bindings TASK-011b must gate, and the memo-only
# explanation path the catalogAvailable-only term keeps reachable.
sed -n '578,590p' web/src/components/MemoTab.tsx
sed -n '77,90p' web/src/notes/memoComposer.ts
sed -n '140,152p' web/src/notes/memoComposer.test.ts
# The two MemoComposerControls fixtures TASK-011a must migrate.
grep -n 'extensionsEnabled\|canNoteEdit' \
  web/src/components/MemoComposerControls.integration.tsx
# TASK-001's retraction evidence: the two screenshot captures are distinct.
grep -n -i 'screenshot' design-docs/specs/web-chatbook-ui.md
git log -S "chatbook screenshot, 2026-08-12" --oneline -- \
  design-docs/specs/web-chatbook-ui.md
```

Evidence rule for every command above: a checklist item is satisfied only by
executed output. Compilation, static review, and a command-wrapper timeout after
partial output are not passes. Record an unavailable command as
environment-blocked with the exact command, an output summary, the reason, and
the checks the blocker leaves unaffected.

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
- [x] Focused and full verification pass with exact commands recorded, or each
      unavailable command is recorded as environment-blocked with its reason.
      Every gate command executed green on 2026-08-29 and was RE-EXECUTED green
      on 2026-08-30 against the current tree (`mise run check` `EXIT=0`
      unpiped, after fixing the one typecheck failure the re-run exposed); only
      the manual browser smoke list is recorded as environment-blocked.
- [x] The plan stays in `impl-plans/active/` while any deliverable is unmet and
      moves to `impl-plans/completed/` only when all are satisfied. It stays
      active: TASK-008's three browser-runtime criteria are unmet and blocked. A RETRACTED
      item (TASK-001's screenshot-date deliverable and its matching criterion) is
      a withdrawn obligation, not an unmet one, and does not hold the plan open.
      **The arithmetic, stated once so every place that cites it agrees, and
      RE-DERIVED 2026-08-30:** 6 unchecked boxes = 2 RETRACTED + 3 TASK-008
      browser-runtime criteria + 1 TASK-009 rollup (open only because of those
      three). UNMET DELIVERABLES = 1.
      **It was 7 = the same four terms + 1 DISCLOSURE until 2026-08-30.** That
      last term is gone because the box it counted — TASK-011c's claim that the
      RETRY ARM of `effectiveNoteEdit` was unreached — was falsified by
      re-executing mutation 12 against HEAD and is now a checked, pinned
      criterion. No DISCLOSURE box remains in this plan. TASK-011b's former
      signal-write disclosure had already been withdrawn on 2026-08-29 after
      being falsified the same way, which makes this the second disclosure to
      die by re-measurement rather than by argument — the pattern rule 5
      generalizes. TASK-008's three boxes are three
      CRITERIA of a single deliverable — browser-runtime verification — not
      three deliverables; that is the reading the Status line at the top and the
      TASK-014 progress entry both use, and it is the reading this plan adopts
      throughout.
- [x] Every gate-enforced item at `web-chatbook-ui.md:309-316` is mapped to a
      named test, and the older-server capability fallback is one of them. The
      mapping is recorded verbatim in the 2026-08-29 TASK-011a progress entry.
- [x] The older-server capability gate is restored and regression-tested, or
      recorded as an open design-conformance defect that keeps the plan active.
      Restored by TASK-011b and pinned by SIXTEEN new tests: the DOM-free
      negative, the rendered negative, the rendered positive counterpart, the
      deferred-rejection test for the `.catch`, and TASK-011c's TWELVE — the
      note-edit retry guard, the two transport-failure tests, the
      post-exhaustion reconnect-recovery test, the three from the Step 7
      regression round (persisted-model preservation, stale-rejection
      suppression, per-outage budget), the mid-session rollback test that pins
      what had been disclosed as a no-op, and the three from the direct-send
      round (direct note-edit refusal, direct attachment refusal, and the memo
      retry that must NOT be refused). **The figure is checkable, not asserted:**
      `grep -c "^  test('" web/src/components/MemoTab.integration.tsx` = 16
      against 1 at the 50b0470 baseline = 14 rendered, plus the one DOM-free
      negative in `memoComposer.test.ts` (12 against 11) = SIXTEEN. Recount both
      greps whenever a test is added; this line and the deliverable line at :68
      carry the same figures and have drifted apart four times.
- [x] Design feedback is resolved, documentation remains under `design-docs/`, and this
      plan's progress log is current.
- [x] The user's pre-existing dirty work is preserved; `README.md` is never
      staged; only this work's files are committed and nothing is pushed.

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
- **Pending-discovery model-withholding window** (Step 7 low finding, ACCEPTED
  as a consequence of the deliberate fail-closed design; no behavior change).
  `catalogAvailable` initializes `false`, and the textarea and submit button are
  gated on `busy` alone, so a send issued while the catalog is unavailable passes
  `extensionsAvailable: false` and withholds the user's persisted
  `settings.agentModel` — the server answers on its configured default.
  **REWRITTEN 2026-08-29 (Step 7 mid) — the two premises this entry used to rest
  on were both false, and were deleted rather than softened:**
  1. It claimed the discovery effect "reads no reactive source, so it runs once
     per mount and the signal only ever goes false -> true". Untrue since the
     reconnect trigger: the effect reads `app.state.catalogRevision` and re-runs,
     and the commit's own test "a server that stops understanding agentModels
     mid-session rests the controls again" (`MemoTab.integration.tsx`) drives
     `catalogAvailable` true -> false on a mid-session server rollback.
  2. It claimed "the window is one GraphQL round-trip and self-corrects". Untrue
     during a transport outage. The bounded retry budget can be spent while the
     server is still unreachable, after which `catalogAvailable` stays false
     until a `catalogRevision` bump proves the server reachable again. **The
     model-withholding window is UNBOUNDED for the duration of an outage**, not
     one round-trip.
  What remains accepted is therefore narrower in cause but wider in duration:
  only MODEL withholding, for as long as the catalog is unavailable. It stays
  accepted because the model is the one extension whose absence is not a
  correctness violation — the server answers on its configured default rather
  than mislabelling the result. The other two extensions are no longer withheld
  silently at all: as of 2026-08-29 a send carrying `noteEdit` or staged
  attachments while `catalogAvailable()` is false is REFUSED with an
  explanation, on BOTH the retry and the direct path, so neither an edit request
  answered as a memo nor a dropped file can happen unannounced.
- **A latched note-edit toggle is deliberately NOT reset when availability goes
  true -> false** (decision recorded 2026-08-29 against the Step 7 prompt to
  consider resetting it). Resetting would discard user intent on a transient
  blip and, worse, make the send SUCCEED as a plain memo — the exact masquerade
  the gate forbids. Refusing the send instead preserves the toggle and the
  staged chips so the user can send unchanged once the catalog returns, and the
  refusal message says why. The toggle's own `disabled`/`aria-disabled` still
  reflect unavailability, so the latched state is visible rather than silent.
- **The `.catch`'s attachment clear carries no explanation** — CLOSED
  2026-08-29, not merely accepted. The older-server branch now sets an
  explanation before clearing, and only when files were actually staged, so a
  drop is never silent and an ordinary mount gains no spurious error. The
  adversarial review asked for exactly this as its minimum.
- **An `agent-unavailable` server still renders every extension control live**
  (adversarial low finding, ACCEPTED and recorded; no behavior change).
  `NoteGraphQLService+AgentChat.swift:13-18` answers `accepted: true`,
  `status: "agent-unavailable"`, `models: []`, `configuredModel: nil` when no
  agent is configured, but `client.ts:463-467` projects only
  models/discoveryAvailable/configuredModel and drops `result.status`, so
  `catalogAvailable` becomes true. Visible consequence: an ENABLED but EMPTY
  model select, and an enabled note-edit toggle, against a server with no agent.
  Not a regression — the controls were live here before this commit too — and
  not a masquerade, because the turn lands as `unavailable` and surfaces both
  the banner and the per-turn retry affordance, so it fails visibly. Closing it
  means carrying `result.status` through the client projection, which is a
  contract change beyond a verification-closing issue's scope.
- **A disclosure can go stale without its measurement changing** (added
  2026-08-29, replacing the entry this supersedes). `setCatalogAvailable(false)`
  was disclosed for several rounds as an unpinned no-op, and the mutation was
  re-executed each round to confirm it. The measurement never changed, but the
  RATIONALE was falsified by a later change of mine — the reconnect trigger made
  the `.catch` reachable after a success, so the line became live code enforcing
  the older-server invariant. "Deleting it leaves the suite green" is equally
  consistent with dead code and with live code no test reaches, so
  re-measurement could not have caught it. Mitigation, now applied: the line is
  PINNED by the mid-session rollback test, and any surviving disclosure must be
  re-derived — not re-measured — whenever the surrounding code changes.
- **Defensive code that pins nothing** — SUPERSEDED ENTIRELY 2026-08-29, and
  left standing one round too long. This entry used to say, in the present
  tense, that `setCatalogAvailable(false)` "is a no-op while the signal
  initializes `false`, so no test distinguishes it from its own absence", with
  disclosure as the mitigation. That claim was falsified and withdrawn — the
  entry immediately above records the withdrawal and the line is now PINNED by
  the mid-session rollback test — but this copy kept asserting it, so the risk
  register contradicted itself for a round.
  **CORRECTED AGAIN 2026-08-30, and this entry was itself the fourth stale
  copy.** Until then it read "the ONLY unpinned sub-expression is the RETRY ARM
  of `effectiveNoteEdit` (mutation 12)". Mutation 12 was re-executed against
  HEAD on 2026-08-30 and is CAUGHT, so that arm is PINNED.
  **CORRECTED A THIRD TIME the same day — this entry is the FIFTH stale copy of
  a pinning claim, and the second time this particular entry went stale.** It
  then read "and NO unpinned sub-expression remains", which was false: the
  builder argument `noteEdit: effectiveNoteEdit` was unpinned, because the
  14-mutation enumeration walks definitions and never reached that call site.
  The current state of all three cases, each by the test that pins it: the retry
  arm by "retrying a failed note-edit turn never silently downgrades it to a
  memo"; the builder's use of the captured `noteEdit` by "a mid-send read-only
  lock cannot downgrade an already-admitted note edit" (mutation 15); the
  builder's three other retry arms — attachments, `newConversation`,
  `activeConversationId` — by "a retry ignores staged chips and a pending New
  chat" (mutations 16-18, all three SURVIVING until that test existed); and the
  sibling `setAttachments([])` by the mutation-verified deferred-rejection test.
  **CORRECTED A FOURTH TIME, making this the sixth stale copy of a pinning claim
  and the third time this entry went stale.** Its previous form said no unpinned
  sub-expression remained while three builder arms were open.
  **CORRECTED A FIFTH TIME, SEVENTH stale copy, FOURTH time for this entry.**
  Even after the arms were closed, the claim was still stated UNSCOPED, and a
  survivor was found outside the builder entirely — the `busy()` term in
  `send()`'s re-entry guard. The scope is now stated where the claim is made:
  `send()`'s three guards — re-entry plus the two refusal guards — its three
  capture definitions, and the builder's four retry arms: ten sites. (The
  re-entry guard was added 2026-08-30; the first draft named only the two refusal
  guards and then counted three survivors on that nine-site list, when the
  `busy()` one sat in the guard the list omitted. `addMemoOnly()`'s identical
  guard is NOT on this surface and was never probed.) THREE survivors on that
  surface are recorded with their reasons — mutations 19 and the attachments-guard re-read as provably EQUIVALENT,
  and the `busy()` term as UNREACHABLE through all three busy-gated entry points,
  which is a weaker claim and is labelled as one.
  **What finally worked was narrowing, not re-asserting.** Seven falsifications
  of one sentence, three of them after a "correction", all shared a cause: an
  unscoped claim cannot be checked, only disproved. A scoped claim can be
  re-measured, which is what makes it worth writing down.
  **The generalized mitigation:** a superseded claim must be REWRITTEN where it
  lives, not merely contradicted by a newer entry elsewhere. FOUR copies of this
  plan's disclosures have now gone stale independently — TASK-011b's criterion,
  TASK-011c's criterion, this register entry (twice, on 2026-08-29 and again on
  2026-08-30) — each because a correction was applied at one site while the
  others kept asserting the old fact.
  **The fourth is the instructive one: it was missed by the same round that
  wrote rule 5's corollary saying correcting one copy does not correct the
  others.** Stating the rule is not running it. So the rule now carries a
  SWEEP rather than an intention, the way rules 1 and 3 do:

```sh
PL=$(grep -n '^## Progress Log$' impl-plans/active/right-pane-agent-composer.md | head -1 | cut -d: -f1)
awk -v n="$PL" 'NR<n' impl-plans/active/right-pane-agent-composer.md \
  | grep -nE 'unpinned|no test reaches|breaks NOTHING|defense-in-depth'
```

  Run it over the live region before recording any disclosure as corrected, and
  read every hit, not just the one the reviewer named. That sweep is what found
  this copy.
  **This command is written to be COPY-PASTE RUNNABLE, and that is a
  requirement, not a nicety.** Its first draft — added 2026-08-30 and caught the
  same day — put the `$(...)` inside a single-quoted `awk` program, so the shell
  never expanded it: run verbatim, the pipeline emitted nothing and exited 1. It
  reported CLEAN UNCONDITIONALLY. That is worse than the narrow rule-1 spelling
  it was meant to improve on, because a false all-clear does not depend on the
  region happening to be clean. It is also the exact failure this rule names,
  committed by the rule itself: a check that is STATED rather than RUN.
  **So the standard, stated once for every sweep this plan prints:** a sweep is
  verified by executing the DOCUMENTED TEXT VERBATIM and recording its hit
  count — never by executing an equivalent and documenting a variant. Executed
  verbatim on 2026-08-30, the block above returned a hit for every live mention
  of a pinning claim, and every one was read.
  **The hit COUNT is deliberately not written here, and that is the second
  lesson of the same day.** A figure stood in this sentence and went stale
  within hours: correcting the register entry added two matching lines, so the
  recorded number was wrong by the next edit — the drift a reviewer had already
  predicted as a low risk. Refreshing it would only reset the clock, exactly as
  rule 1 says of suite counts. Run the block; read what it returns.

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
  normalization are directly tested. **SUPERSEDED (2026-08-29):** the
  capability-gating claim no longer holds at HEAD — `fb3997a` dropped the
  `catalogAvailable` parameter that `b076a33` added, and no capability-unavailable
  test exists. See TASK-011a/TASK-011b. Added memo-only accessible-control state
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
- 2026-08-29: Step 4 plan revision for the verification-closeout issue. Added
  `design-docs/user-qa/web-chatbook-ui.md` and the authoritative
  `tauri-client-apps.md:159-171` gate to Design References. Replaced the four
  `cd web && bun run ...` lines with the single `mise run web:check` gate and
  gave the focused Swift runs their mise-inheriting form, since
  `PKG_CONFIG_PATH` is task-scoped in `mise.toml` and `mise exec` alone does not
  supply it. Decomposed the open verification work into TASK-010 (focused Swift),
  TASK-011 (web gate), TASK-012 (full Swift sweep), TASK-013 (browser runtime or
  blocked record), and TASK-014 (reconcile and scoped commit), with the evidence
  rule from `ai-agent-integration.md` items 11-12 applied to each. Also applied
  the two optional low findings from the Step 3 review to the design docs. No
  verification command was executed in this step and no commit or push occurred.
- 2026-08-29: Step 4 self-review correction. Added
  `design-docs/user-qa/web-chatbook-ui.md` to the `git diff --check` path list so
  the whitespace gate covers every file this work changes, and widened TASK-011's
  failure write scope from `web/src/` to `web/` because a typecheck or build
  failure can implicate `web/tsconfig.json`, `web/vite.config.ts`, or
  `web/eslint.config.js`. Empirically confirmed the recorded focused-run form:
  `PKG_CONFIG_PATH="$PWD/.build/anydoc-native/host/pkgconfig" mise exec -- ...`
  passes the variable through and resolves Apple Swift 6.3.3.
- 2026-08-29: Step 5 review revision (one high, one low finding; both addressed).
  Independently confirmed the high finding against HEAD:
  `web/src/notes/memoComposer.ts:43` is `agentComposerExtensionsEnabled(memoOnly,
  busy)`; `git show b076a33` has the three-parameter form with the "Older servers
  do not understand either extension field" comment; `fb3997a` (Release Kaiba
  0.1.7) dropped it; `MemoTab.tsx:118` passes only `memoOnly()/busy()` while the
  catalog `.catch` at `MemoTab.tsx:130-139` sets `models([])` and leaves the
  controls enabled; `grep -rn -i capabilit web/src` returned nothing AT THAT TIME
  (re-running it after TASK-011b now matches the new `MemoTab.tsx:135` comment,
  which is the gate this entry said was missing). So TASK-006's
  older-server deliverable and TASK-009's older-server clause were checked over a
  real gap that a green `mise run web:check` cannot detect. Unchecked both,
  annotated the 2026-08-13 entry as superseded, and added TASK-011a (gate-coverage
  audit against `web-chatbook-ui.md:309-316` plus the missing failing regression
  test) and TASK-011b (restore the `catalogAvailable` gate). The plan takes the
  reviewer's option (a), justified inside the workflow constraint rather than as
  an exception: TASK-011a's design-mandated test fails against HEAD, so the fix is
  what a failing check requires. TASK-014 now gates the move to
  `impl-plans/completed/` on this deliverable as well as the browser-runtime
  blocker. Also recorded the `mise run tauri:check` exclusion as a decision (no
  closeout write scope touches Rust). No verification command was executed in this
  step beyond the read-only greps above; no production file changed; no commit.
- 2026-08-29: Step 4 self-review correction to the new closeout tasks. TASK-011a's
  write scope was `web/src/notes/memoComposer.test.ts` alone, which cannot hold its
  own "controls are disabled" deliverable: `web/vitest.config.ts` includes only
  `src/**/*.integration.tsx` under happy-dom while `bun test src` matches
  `*.test.ts`, so the rendered assertion belongs in
  `web/src/components/MemoComposerControls.integration.tsx` (which already has a
  resting disabled-control test). Split the deliverable across both files, widened
  the write scope, and named the mise-resolved focused runners
  (`bun test src/notes/memoComposer.test.ts`, `bun run test:integration`; bun 1.3.14
  via `mise exec`) so the pre-fix failure record cannot be produced by a
  wrong-runner miss. Confirmed the cited design lines resolve correctly:
  `web-chatbook-ui.md:245` is the disabled-controls sentence, `:255` the
  catalog-gated `mode` sentence, `:314` the older-server gate-enforced item.
- 2026-08-29: Second Step 5 review revision (one mid, three low; all addressed).
  Independently confirmed each against HEAD. MID: TASK-011a's rendered half could
  not fail pre-fix — `MemoComposerControls.integration.tsx:43` already renders
  `extensionsEnabled: false` and asserts the disabled state, and
  `MemoComposerControls` takes that as a plain prop with no catalog knowledge, so a
  new test there would have been tautological. Moved the rendered half to
  `MemoTab.integration.tsx` (rejecting `agentModels` stub driven through the
  `extensionControlsEnabled` memo and the discovery `.catch`, reusing the file's
  `waitFor`/`settle` helpers) and added an explicit admissibility rule barring the
  literal-`false` form. LOW: `memoComposer.test.ts:68-70` holds three two-argument
  assertions that the restored signature breaks and no task owned their migration
  — assigned to TASK-011a, which already owns that file, and labeled a call-site
  update rather than a weakening, keeping TASK-011b capped at `memoComposer.ts` +
  `MemoTab.tsx`. LOW: TASK-013's Dependencies said TASK-011 while the execution
  order and parallel map said TASK-011b — corrected, with the post-fix `web/dist`
  requirement stated. LOW: the older-server item at `web-chatbook-ui.md:314` is now
  mapped to the DOM-free half, since :308 defines the gate-enforced list as
  DOM-free logic tests and :315-317 places pure-state behavior there; the rendered
  half is labeled supplementary wiring coverage. (Line citations in this entry are
  off by one; corrected to :309-316 and :315-316 in the 2026-08-29 third-review
  entry below. The placement conclusion is unaffected.) No design file changed; no
  production file changed; no commit.
- 2026-08-29: Step 4 self-review correction to the Parallel Work Map. Its line
  "TASK-014 ... is the only closeout task that writes files" was falsified by this
  revision's own tasks: TASK-011a writes three test files, TASK-011b writes two
  production files, and TASK-010/011/012 may write a narrowest-implicated file on
  failure. Restated TASK-014 as the only task that writes the plan and the only one
  that commits. Also replaced the stale non-parallel rationale (which named only
  `memoComposer.ts` and its test) with the four actual files, and recorded that
  TASK-011a's rendered assertion is non-tautological at HEAD because
  `MemoTab.integration.tsx`'s fixtures are writable (`subject.readOnly: false` :13,
  stub `notebook()` `readOnly: false` :90), so `canNoteEdit` is true and the
  note-edit toggle renders enabled under a rejecting catalog today.
- 2026-08-29: Third Step 5 review revision (three mid, three low; all addressed).
  Each verified against HEAD and `b076a33` first. MID-1 (signal source): named the
  signal as "the `agentModels` query resolved" (`.then` true / `.catch` false, per
  `b076a33 MemoTab.tsx:97-112`) and ruled out `AgentModelsResult.discoveryAvailable`
  explicitly — it is declared at `types.ts:164`, fetched at `client.ts:456,465`, and
  read by no production code, and per `web-chatbook-ui.md:154` /
  `ai-agent-integration.md:253` a false value means the vendor could not enumerate
  models, which must leave controls ENABLED. MID-2 (builder surface): added the
  required `extensionsAvailable` option and the three guarded spreads at
  `memoComposer.ts:146-148` plus the `MemoTab.tsx:301` call site to TASK-011b's
  deliverables, restated its diff cap as the six enumerated edits, and recorded that
  the `mode: "edit"` gate is new code satisfying `web-chatbook-ui.md:255` rather than
  a `b076a33` restoration. MID-3 (option optionality): decided REQUIRED, matching
  `b076a33 memoComposer.ts:77`, because required fails closed; enumerated the four
  test-file migration sites — `:68-70`, `:86-93`, `:108-111`, and `:161-168` (the
  note-edit fixture, which Step 5 did not list but breaks identically). LOW-4:
  corrected the gate-enforced citation to `:309-316` and the pure-state rule to
  `:315-316` throughout; line 308 is blank. LOW-5: mandated restoring
  `setAttachments([])` in the `.catch` branch and named the "Attachments require a
  newer server" tooltip as a deliberate exclusion under the no-styling cap. LOW-6:
  added the positive rendered counterpart using the existing resolving stub, which
  is the only planned assertion catching both a permanently-pending signal and the
  `discoveryAvailable` mis-wiring. No design file changed; no production file
  changed; no commit.
- 2026-08-29: Step 4 self-review correction to TASK-011a's criteria. Its
  pre-fix-evidence criterion still said "both halves", written before the positive
  counterpart made three new tests, and would have demanded a pre-fix failure from
  a test that is expected to pass; split it so only the two negative tests are
  pre-fix evidence and the positive counterpart is recorded as a regression guard.
  Its migration criterion still named only `:68-70` while the deliverable
  enumerates four sites; restated to cover all four. Also recorded what the pre-fix
  failure actually looks like: `bun test` and `vitest` transpile without
  typechecking, so the new tests run against HEAD and fail on runtime assertions
  (HEAD's builder ignores the unknown `extensionsAvailable` property and emits the
  fields anyway), while TypeScript's excess-property error is a separate
  typecheck-leg failure that is NOT admissible evidence on its own.
- 2026-08-29: Fourth Step 5 review revision (one high, one mid, one low; all
  addressed). HIGH — verified against HEAD that TASK-011a's rendered negative test
  could not pass POST-fix: the note-edit toggle at `MemoTab.tsx:585-586` reads
  `canNoteEdit`/`noteEdit`/`busy` and never `props.extensionsEnabled`;
  `canEnableNoteEdit` (`memoComposer.ts:68-75`) takes subject/note/notebook only;
  and `b076a33` had no note-edit toggle at all, its `extensionsEnabled` gating only
  the file input (:491), attach button (:499-500), and model select (:522). Took the
  reviewer's recommended resolution rather than deleting coverage: TASK-011b now
  gates the toggle while keeping the existing terms, recorded
  as NEW code under `web-chatbook-ui.md:254-257`
  (**SUPERSEDED (2026-08-29, fifth review):** the gating term is
  `catalogAvailable`, not the composite `extensionsEnabled` — see the fifth-review
  entry below) (an enabled toggle whose `mode` is
  silently withheld is the masquerade that clause forbids), and added it as a
  seventh item in the enumerated diff cap. MID — TASK-014's commit scope now
  enumerates all eight paths, calling out that the four web paths are not
  failing-check fallout, plus a criterion that `git status --short` after the commit
  shows ONLY ` M README.md`. LOW — corrected the stale `sed -n '308,316p'` to
  `:309,316p` and replaced the single-site `sed -n '68,70p'` with a grep that
  surfaces all four migration sites, adding a `sed -n '578,590p'` command for the
  toggle bindings. No design file changed; no production file changed; no commit.
- 2026-08-29: Fifth Step 5 review revision (two mid; both addressed). Each was
  reproduced against the tree before deciding.
  MID-1 (TASK-001 screenshot date, plan :48/:70/:77) — reproduced: `sed -n
  '30,40p' design-docs/specs/web-chatbook-ui.md` shows `:36` still reading
  "(reference: the user's chatbook screenshot, 2026-08-10)", and `git log -S
  "chatbook screenshot, 2026-08-12" -- design-docs/specs/web-chatbook-ui.md`
  returns nothing, so the checked deliverable claimed work never applied.
  DECISION: took the reviewer's second option — the two dates name two DISTINCT
  captures, so the correction is RETRACTED rather than applied. `:36` sits in the
  Summary describing the three-pane chatbook READER (W1-W8, out of this issue's
  scope and preserved by the Scope Guard, introduced by `c4de25e`), while
  `Screenshot 2026-08-12 at 21.13.56.png` is cited at `:10-11` and `:131-132` as
  the COMPOSER reference for W9-W12. Rewriting `:36` would falsify the reader
  design's provenance. Unchecked `:48` and the matching criterion, marked both
  RETRACTED with the rule that a withdrawn obligation does not gate the move to
  `impl-plans/completed/`, replaced them with two claims the tree actually
  supports, updated the stale `:33` citation to `:36`, and recorded in TASK-014
  that `web-chatbook-ui.md` is committed for its Traceability/Verification edits
  only. No design file was changed.
  MID-2 (TASK-011b toggle gating, plan :567-579) — reproduced: `MemoTab.tsx:505`
  passes `extensionsEnabled={extensionControlsEnabled()}` (`:117-118`), so the
  composite term would also disable the note-edit toggle with memo-only ON against
  an available catalog and would newly make `aria-disabled` reflect `busy`,
  deadening `noteEditToggleResult`'s "Disable memo-only mode before enabling note
  edit mode." path (`memoComposer.ts:84-86`, asserted `memoComposer.test.ts:147-149`,
  dispatched `MemoTab.tsx:513`). DECISION: took the reviewer's recommended
  narrowing — a REQUIRED `catalogAvailable` prop on `MemoComposerControlsProps`,
  with `aria-disabled={!props.catalogAvailable || (!props.canNoteEdit &&
  !props.noteEdit)}` and `disabled={props.busy || !props.catalogAvailable ||
  (!props.canNoteEdit && !props.noteEdit)}`, keeping every existing term. Chose
  REQUIRED for consistency with the plan's fail-closed `extensionsAvailable` rule;
  the consequence is that `MemoComposerControls.integration.tsx`'s two prop
  literals miss a required property and `web/tsconfig.json` includes `src`, so the
  typecheck leg would go red — that file therefore joins TASK-011a's write scope
  for a two-property fixture migration with no assertion change, and joins
  TASK-014's commit enumeration as path 7 (now nine paths). Updated TASK-011b's
  enumerated diff cap, added two criteria pinning the narrow term and the
  untouched `MemoTab.tsx:584` title, updated TASK-011a's rendered-test deliverable
  to assert rendered DOM state rather than a prop name, and added one covering
  assertion to the resolving-catalog rendered test: the note-edit toggle stays
  ENABLED with memo-only ON — the only planned check that fails if the composite
  term is ever reintroduced. No production file changed; no commit.
- 2026-08-29: Step 4 self-review pass on the toggle-gating revision. Confirmed
  TASK-011b's new binding does not break
  `MemoComposerControls.integration.tsx` (out of TASK-011b's write scope; the
  entry above moved its two fixture literals into TASK-011a's): its `:7` test passes
  `extensionsEnabled: true` with `canNoteEdit: true`, and its `:43` test passes
  `extensionsEnabled: false` with `canNoteEdit: false`, so both assertions hold
  under the added term either way — recorded in TASK-011b so the next reader does
  not have to re-derive it. Also named a second explicit exclusion: the note-edit
  toggle's `title` expression at `MemoTab.tsx:584` is NOT changed, so a writable
  note under an unavailable catalog renders a disabled toggle whose tooltip still
  reads "Edit note mode". The disabled state satisfies
  `web-chatbook-ui.md:254-257`; the tooltip branch is presentation work under the
  same no-styling cap as the excluded attachment tooltip. Recorded as an accepted
  consequence rather than left unlabeled.
- 2026-08-29: TASK-010 executed. `mise run anydoc:native` resolved the Apple
  XCFramework, then each focused suite ran as
  `PKG_CONFIG_PATH="$PWD/.build/anydoc-native/host/pkgconfig" mise exec -- swift
  test --filter <suite>`: `AgentChatTests` executed 24 tests with 0 failures,
  `AgentGatewayCLIInvokerTests` 11 with 0, `AgentChatGraphQLTests` 19 with 0
  (each exit 0). The `anydoc_ffi`/`SwiftUICore` executable-linking blocker
  recorded across the 2026-08-13 entries did NOT recur under this form, so
  TASK-003's "Existing note/file and chat lifecycle tests remain green" is now
  decided from executed output. No test was weakened, skipped, or removed, and
  no file was edited by this task.
- 2026-08-29: TASK-011 executed. `mise run web:check` (the single gate) ran
  green as the pre-change baseline: `tsc --noEmit`, then `bun test src` at
  154 pass / 0 fail / 398 expect() calls across 21 files, then `vitest run` at
  13 passed across 5 files, then `eslint .`, then `vite build` (57 modules).
  bun resolved through mise at 1.3.14. No subset was substituted for the gate
  and no file was edited.
- 2026-08-29: TASK-011a executed. Gate-coverage audit of
  `design-docs/specs/web-chatbook-ui.md:309-316`, recorded verbatim — every
  item is covered, none uncovered:
  1. `router.test.ts` → `web/src/router.test.ts`.
  2. `toc.test.ts` (heading tree, slug dedupe) → `web/src/notes/toc.test.ts`.
  3. `chatState.test.ts` (turn-status reducer incl. unavailable/pending/failed)
     → `web/src/notes/chatState.test.ts`.
  4. `paneState.test.ts` (fold/tab persistence) → `web/src/state/paneState.test.ts`.
  5. Enter/Shift+Enter/IME → `memoComposer.test.ts` "Enter submits but
     Shift+Enter and IME composition do not".
  6. Memo-only accessibility and blocking → `memoComposer.test.ts` "memo-only
     control exposes its selected accessible state and tooltip" and "rests model
     and attachment controls during memo-only and while busy".
  7. Model fallback/persistence → `memoComposer.test.ts` "normalizes persisted
     model selection against the current catalog fallback".
  8. New-chat conversation intent → `memoComposer.test.ts` "new chat request
     omits existing conversation while preserving model and attachment contract"
     and "new chat clears transient composer state and attachment removal is
     deterministic".
  9. Attachment validation/removal → `memoComposer.test.ts` "rejects unsafe,
     empty, duplicate, unsupported, and non-UTF-8 files" plus the
     `removeComposerAttachment` assertion in item 8's second test.
  10. Older-server capability fallback → the NEW `memoComposer.test.ts` test
      "an unavailable composer-extension catalog rests the controls and
      withholds every extension field". Rendered wiring coverage is
      supplementary, in `MemoTab.integration.tsx`.
  Files written (three, no production file): `web/src/notes/memoComposer.test.ts`
  (four call-site migrations at `:68-70`, `:86-93`, `:108-111`, `:161-168`, plus
  the new DOM-free negative test), `web/src/components/MemoTab.integration.tsx`
  (the rendered negative and positive tests), and
  `web/src/components/MemoComposerControls.integration.tsx` (exactly two added
  `catalogAvailable` properties, no assertion touched).
  **Harness decision (closing the Step 5 low finding that left this to the
  implementer):** `testStore` was PARAMETERIZED with an optional third argument
  `{ rejectAgentModels?: boolean }` rather than duplicated into a second helper.
  One harness keeps the rejecting and resolving fixtures byte-identical apart
  from the catalog behavior under test, so a future fixture drift cannot silently
  make only one of the two tests vacuous. `agentModels` now throws
  `Unknown field "agentModels"` when the flag is set — the shape an older
  server's rejection actually takes.
  PRE-FIX EVIDENCE, both negative tests, runtime assertion failures (not `tsc`
  errors):
  `(cd web && mise exec -- bun test src/notes/memoComposer.test.ts)` → 10 pass,
  2 fail. The new negative test failed at `memoComposer.test.ts:80` with
  `error: expect(received).toBe(expected) / Expected: false / Received: true`
  for `agentComposerExtensionsEnabled(false, false, false)`. The migrated
  `:68-70` call site failed alongside it at `:70` (`Expected: true / Received:
  false`), which is the expected consequence of a call-site migration to a
  signature HEAD does not have yet, not a weakening.
  `(cd web && mise exec -- bun run test:integration)` → 14 passed, 1 failed:
  `MemoTab integration > an older server whose agentModels query rejects rests
  every composer extension control` failed at
  `MemoTab.integration.tsx:218` with `AssertionError: expected false to be true`
  on the model select's `.disabled`. It failed by driving the rejecting
  `agentModels` stub through `MemoTab`, never by a literal
  `extensionsEnabled: false`.
  The positive counterpart PASSED pre-fix, as planned; it is recorded as a
  regression guard, not pre-fix evidence.
- 2026-08-29: TASK-011b executed. Restored the capability gate in exactly the
  two planned production files and nothing else.
  `web/src/notes/memoComposer.ts`: `agentComposerExtensionsEnabled(catalogAvailable,
  memoOnly, busy)` returning `catalogAvailable && !memoOnly && !busy`; a REQUIRED
  `extensionsAvailable: boolean` on `AgentChatComposerRequestOptions`; and all
  three optional spreads guarded, so `model`, `attachments`, and `mode: "edit"`
  are withheld when the catalog is unavailable.
  `web/src/components/MemoTab.tsx`: a `catalogAvailable` signal initialized
  `false` (matching `b076a33`), set `true` in the `agentModels` `.then` and
  `false` in the `.catch`; `setAttachments([])` restored in the `.catch`;
  `extensionControlsEnabled` reads the new term; the `buildAgentChatComposerRequest`
  call passes `extensionsAvailable: catalogAvailable()`; a REQUIRED
  `catalogAvailable` prop on `MemoComposerControlsProps` passed at the
  `MemoComposerControls` call site; and the note-edit toggle's bindings gained
  `!props.catalogAvailable` and nothing else.
  DECISION HELD: the signal is whether the `agentModels` query RESOLVED.
  `grep -n discoveryAvailable web/src/components/MemoTab.tsx` returns exactly one
  line — `:135`, the comment naming `discoveryAvailable` as NOT the signal — and
  no expression in the file reads `catalog.discoveryAvailable`, so the mis-wiring
  the plan forbids did not happen. (An earlier draft of this entry and of
  TASK-011b's criterion said the grep "returns nothing"; that command does not
  reproduce, because the comment matches it. The decision itself is unchanged;
  only the stated evidence is corrected.)
  DECISION HELD: the toggle's new term is `props.catalogAvailable`, not the
  composite `extensionsEnabled`, so memo-only ON against an available catalog
  leaves the toggle enabled and `noteEditToggleResult`'s "Disable memo-only mode
  before enabling note edit mode." explanation stays reachable — now pinned by a
  rendered assertion. `aria-disabled` still does not reflect `busy`.
  EXCLUSIONS HELD as recorded: the "Attachments require a newer server" tooltip
  was not added, and `MemoTab.tsx:584`'s title expression is byte-identical in
  the diff (it now sits at `:600`). The accepted consequence stands: a writable
  note under an unavailable catalog renders a disabled toggle whose tooltip still
  reads "Edit note mode".
  POST-FIX: `(cd web && mise exec -- bun test src/notes/memoComposer.test.ts)` →
  12 pass / 0 fail / 62 expect() calls; `(cd web && mise exec -- bun run
  test:integration)` → 15 passed across 5 files. Then the full gate,
  `mise run web:check`, green: `tsc --noEmit`, `bun test src` at 155 pass / 0
  fail / 403 expect() calls across 21 files (+1 vs the baseline), `vitest run` at
  15 passed across 5 files (+2 vs the baseline), `eslint .`, `vite build`. No
  existing test was weakened, skipped, or deleted.
- 2026-08-29: TASK-012 executed. `mise run lint` → "Done linting! Found 2
  violations, 0 serious in 181 files" (exit 0). Both are PRE-EXISTING
  `large_tuple` warnings — `Sources/AppCore/NoteService.swift:572:40` and
  `Sources/AppCore/ResendGatewayCLIMailSender.swift:75:73` — in files no write
  scope of this feature touches; neither was silenced and no new warning is
  attributable to this work. `mise run test` → 523 XCTest tests with 0 failures
  plus 34 swift-testing tests passed, finished in 13.48s (exit 0).
  `mise run build` → "Build complete!" (exit 0). No command-wrapper timeout
  occurred anywhere in this closeout. `mise run tauri:check` remains a recorded
  DECISION, not a gap: no closeout write scope includes a Rust or Tauri path.
- 2026-08-29: TASK-013 attempted and recorded as ENVIRONMENT-BLOCKED. The
  post-TASK-011b `web/dist` was rebuilt by the gate's build leg and is served
  correctly: the first attempt,
  `mise exec -- swift run kaiba serve --web-root web/dist --port 8791`, failed
  with `Error: unsupportedLegacyVersion(found: 10, required: 17)` — the developer's
  own `~/.kaiba` store is on an older schema — so it was re-run against an
  isolated root, `... kaiba serve --note-root /tmp/kaiba-smoke-root --web-root
  web/dist --port 8791`, which started and answered `curl http://127.0.0.1:8791/`
  with HTTP 200 and the built `index.html`. The blocker is therefore NOT the
  server or the build: it is that no browser runtime exists to drive the smoke
  list. `command -v` finds none of playwright, puppeteer, chromedriver, chrome,
  google-chrome, or chromium, and neither `web/package.json` nor
  `web/node_modules` contains playwright or puppeteer. Adding one is barred —
  it is the open user decision in `design-docs/user-qa/web-chatbook-ui.md`,
  which this task left unanswered and unchanged. BLOCKED items: TASK-008's three
  criteria (breakpoint overflow/reorder, selected/disabled/hover/focus states in
  both themes, keyboard-only and responsive light/dark smoke) plus the six
  manual smoke bullets in Verification Commands. They stay UNCHECKED. UNAFFECTED
  by this blocker: every DOM-free and happy-dom test in `mise run web:check`
  (170 assertions' worth of composer behavior across the two runners), the
  typecheck, eslint, and `vite build` legs, and the entire Swift sweep — the
  server started, so nothing here is evidence of a runtime defect.
- 2026-08-29: TASK-014 executed. Reconciled every checkbox against executed
  output only. Newly checked from evidence: the "Focused Swift and web tests plus
  full lint/test/build verification" deliverable, TASK-003's lifecycle criterion,
  TASK-006's older-server pure-test criterion, TASK-009's first two criteria, and
  all of TASK-010, TASK-011, TASK-011a, TASK-011b, TASK-012, TASK-013 and
  TASK-014. Still UNCHECKED and correctly so: TASK-008's three browser-runtime
  criteria (blocked, above), TASK-009's "All deliverables are checked" criterion
  (open only because of them), and the two RETRACTED TASK-001 items (withdrawn
  obligations, which per the recorded rule do not gate the plan's location).
  DECISION: the plan STAYS in `impl-plans/active/`. Of TASK-014's two named
  blockers, blocker 2 (the older-server capability deliverable) is RESOLVED, but
  blocker 1 (browser runtime) is not, and one genuinely unmet deliverable is
  enough to hold the plan open. Also applied the Step 5 reviewer's optional
  citation cleanups: the stale "two test files" count is now three in both
  places, the note-edit fixture citation is `:161-168` (consumed at `:169-170`)
  in all four places, the `MemoTab.integration.tsx` stub citation is `:59-66`
  and its helpers `:28-46` in both places, and the "out-of-scope" phrase for
  `MemoComposerControls.integration.tsx` now reads "out of TASK-011b's write
  scope" so it no longer contradicts TASK-011a's write scope.
  RESIDUAL RISKS carried forward: (1) the browser-runtime smoke is still
  unexecuted, so responsive/theme/keyboard-only regressions would not be caught
  by the gate; (2) TASK-011a's rendered assertions stay non-vacuous only while
  `MemoTab.integration.tsx`'s fixtures remain writable (`subject.readOnly: false`,
  stub `notebook()` `readOnly: false`) — if either flips, the note-edit half must
  be re-based on the model select and attach button; (3) mutual exclusivity under
  memo-only rests on `noteEditToggleResult`'s explanation path, pinned by exactly
  one rendered assertion; (4) `mise run tauri:check` was not run, by recorded
  decision, so a Rust/Tauri regression would not be caught here — no file in this
  commit is a Rust or Tauri path. Committed only this work's nine enumerated
  paths with individual `git add`; `README.md` was never staged and nothing was
  pushed.
- 2026-08-29: Test-integrity gate revision (one mid, one low). The gate
  mutation-tested the commit and found that the `.catch`'s `setAttachments([])`
  — an explicitly enumerated TASK-011b deliverable — had ZERO coverage: deleting
  it left `bun run test:integration` at 15 passed, identical to the unmutated
  run. Confirmed rather than taken on trust, then investigated before fixing.
  PROBE (temporary test, since removed; working tree returned to ` M README.md`
  before any further edit): rendering `MemoTab` against a rejecting `agentModels`
  stub measured `picker.disabled === true` — the fail-closed initialization
  really does disable the control from first paint — but a dispatched `change` on
  that disabled input STILL staged the file and rendered its chip
  (`chipAfterDispatch === true`). `change` is not in Solid's delegated event set,
  so it is a direct `addEventListener` that fires regardless of `disabled`.
  CONCLUSION: the plan's original rationale for the line was imprecise. A real
  user cannot reach "stage a file, then discovery fails" through the control,
  because staging requires the catalog to have already resolved. The line is
  therefore DEFENSIVE, not a fix for a user-reachable silent drop — and the
  rationale at TASK-011b is now corrected in place to say so, with the probe
  numbers, instead of leaving a justification the tree contradicts.
  FIX (one test, matching the gate's recommended scope): added a fourth test to
  `MemoTab.integration.tsx`, "a file staged before discovery settles unavailable
  does not keep its chip". `testStore` gained a second option,
  `rejectAgentModelsAfter?: Promise<void>`, so the stub awaits a caller-held gate
  before rejecting. The test stages a file while discovery is still PENDING,
  asserts the chip is really rendered first (so the later assertion cannot pass
  vacuously), then releases the gate and asserts the chip is gone and
  `.attachment-chips` is absent. MUTATION-VERIFIED load-bearing: dropping
  `setAttachments([])` fails it with `AssertionError: expected ... not to contain
  'staged.txt'` and the received DOM showing `staged.txt ×` still present —
  1 failed / 15 passed. Restored immediately; `git diff --stat` on
  `MemoTab.tsx` is empty.
  LOW FINDING ACCEPTED AND DISCLOSED, not silently fixed:
  `setCatalogAvailable(false)` in the same `.catch` is a no-op given
  `createSignal(false)` at `:81`, and deleting it leaves the suite green. It is
  kept for `b076a33` parity and becomes load-bearing if the initialization ever
  changes. Recorded as a new unchecked TASK-011b criterion and in Risks so the
  evidence package does not read more complete than it is — which was the gate's
  actual objection.
  POST-FIX GATE: `mise run web:check` green — `tsc --noEmit`; `bun test src`
  155 pass / 0 fail / 403 expect() calls across 21 files (unchanged, the new test
  is a Vitest integration test); `vitest run` 16 passed across 5 files (+1);
  `eslint .`; `vite build`. No production file changed in this revision, so the
  Swift sweep and the focused Swift suites are unaffected and were not re-run.
- 2026-08-29: Step 6 self-review correction to the test-integrity revision's own
  bookkeeping. Two defects it introduced, both found by re-reading the plan
  rather than the diff. (1) The new UNPINNED criterion was left as a bare
  unchecked box, so counting unchecked boxes yielded a second apparent blocker
  that contradicted the Status line ("That single unmet deliverable") and
  TASK-014's "blocker 2 RESOLVED". Relabelled DISCLOSURE with the same explicit
  rule the plan already uses for RETRACTED — left unchecked so no checkbox
  overclaims, but not a deliverable and not holding the plan open — and stated
  the arithmetic in the plan-location criterion: 7 unchecked boxes, 3 unmet
  deliverables. (2) The global criterion still read "pinned by three new tests"
  after the fourth was added; corrected to FOUR and each named. No production,
  test, or design file changed in this correction.
- 2026-08-29: Step 7 review revision (two mid, two low; all addressed, no
  production or test file changed). MID-1 — the Deliverables line at `:68` that
  closes this issue still read "155 Bun unit, 15 Vitest integration", stale from
  before the deferred-rejection test landed, and it contradicted this log's own
  test-integrity entry ("`vitest run` 16 passed across 5 files (+1)").
  Corrected to 16 after re-running the gate. The historical counts elsewhere are
  accurate for their dates and were deliberately left alone: TASK-011's baseline
  record (13 Vitest, `:439`), the TASK-011b post-fix entry ("15 passed across 5
  files (+2 vs the baseline)"), and the test-integrity entry's two mutation
  records ("at 15 passed, identical to the unmutated run" and "1 failed / 15
  passed"). Those are cited by quoted text rather than by line number, because
  this log is append-only and every later entry shifts its predecessors' line
  numbers — which is exactly how the stale citations in this entry's own first
  draft arose, caught in Step 6 self-review before Step 7 saw them. The same drift in
  `abc661c`'s commit message ("15 Vitest tests", and "Three tests cover it")
  was corrected by amendment; the commit is local and unpushed.
  MID-2 — the unmet-deliverable arithmetic disagreed with itself: `:7` and the
  TASK-014 entry said one, while the plan-location criterion this log's previous
  entry added said three. The previous entry claimed to have closed that
  contradiction but had edited only one of the three sites, so it CREATED the
  mismatch. Resolved by choosing one reading and stating it once, at the
  plan-location criterion: TASK-008's three browser-runtime boxes are three
  CRITERIA of a single deliverable, not three deliverables, so 7 unchecked boxes
  correspond to 1 unmet deliverable. `:7` and the TASK-014 entry already used
  that reading and are unchanged. The plan's location is unaffected either way.
  LOW-1 and LOW-2 — the pending-discovery model-withholding window and the
  explanation-free attachment clear are both accepted consequences of the
  deliberate fail-closed design. Per the reviewer's instruction they were
  recorded in Risks and Mitigations rather than fixed, since widening the gate to
  the textarea or adding an error message would change composer behavior that no
  failing check requires.
  Re-ran `mise run web:check` after the edits: green — `tsc --noEmit`;
  `bun test src` 155 pass / 0 fail / 403 expect() calls across 21 files;
  `vitest run` 16 passed across 5 files; `eslint .`; `vite build`. The Swift
  sweep was NOT re-run and does not need to be: `git show --numstat HEAD`
  contains no `Sources/` or `Tests/` path.
- 2026-08-29: Adversarial Step 7 revision — TASK-011c (one high, one mid; both
  FIXED, not accepted). Both were reproduced from source before any edit, then
  pinned by tests written BEFORE the fix, per this plan's evidence rule.
  HIGH — the Retry button (`disabled={busy()}`) takes `noteEdit` from the
  persisted turn, so it bypasses every control the capability gate disables.
  Retrying a failed edit turn before discovery settled sent with `mode: "edit"`
  withheld to a fully capable server, and the note was silently never edited.
  This is the masquerade the whole commit exists to prevent, and it REFUTED this
  plan's own accepted-risk sentence claiming `mode` and `attachments` "cannot be
  affected because their controls render disabled from first paint" — that
  sentence is now corrected in Risks and Mitigations rather than left standing.
  FIX: the Retry button is disabled for an edit turn while `!catalogAvailable()`,
  and `send()` refuses such a retry with an explanation.
  MID — `NoteTransportError` distinguishes `network`/`http`/`graphql`/`result`/
  `registration` (`client.ts:42-51`), and only `graphql` is the unknown-field
  case that proves an older server; an older server's rejection arrives that way
  because `envelope.errors` maps to `'graphql'` at `client.ts:739`. The `.catch`
  collapsed every kind, and the effect never retried, so one blip rested every
  extension control for the entire session against a capable server. FIX: a
  non-`graphql` transport failure is retried up to 3 attempts and then REPORTED
  via `setError`, never silently converted into a capability verdict. The
  older-server branch additionally explains the attachment drop before clearing,
  and only when files were staged — closing the Step 7 low finding outright
  instead of carrying it as accepted.
  PRE-FIX EVIDENCE — `bun run test:integration` 3 failed / 16 passed:
  "expected false to be true" (Retry not disabled pre-settle), "expected true to
  be false" (controls stuck disabled after a recovered blip), and "expected '' to
  contain 'agent model catalog'" (no explanation surfaced).
  MUTATION-VERIFIED post-fix, each fix load-bearing: reverting the Retry binding
  to `disabled={busy()}` → 1 failed / 18 passed; replacing the kind check with
  `if (false)` → 2 failed / 17 passed; deleting the bounded retry → 2 failed / 17
  passed. All mutations reverted; `git diff --stat` on `MemoTab.tsx` returned to
  the intended 37+/5- afterwards.
  DISCLOSED, not claimed: the `send()` refusal is unreachable by test — deleting
  it leaves 19 passed, because the disabled button swallows the click before
  `send()` runs. Kept as an invariant guard for future callers and recorded as a
  TASK-011c DISCLOSURE, which per the plan's rule is not an unmet deliverable.
  The test fixtures now throw real `NoteTransportError`s with correct kinds
  rather than a bare `Error`, so the older-server and transport-failure paths are
  modelled faithfully; that is a fidelity improvement, not a weakening, and no
  assertion was removed or relaxed.
  POST-FIX GATE: `mise run web:check` green — `tsc --noEmit`; `bun test src` 155
  pass / 0 fail / 403 expect() calls across 21 files; `vitest run` 19 passed
  across 5 files (+3); `eslint .`; `vite build`. The Swift sweep is unaffected —
  no Swift path is in the commit — and was not re-run.
  The plan STAYS in `impl-plans/active/`: TASK-008's browser-runtime deliverable
  is still blocked, and that remains the single unmet deliverable.
- 2026-08-29: Step 7 review revision (one mid, one low). MID — Step 7 deleted the
  older-server `setError(...)` explaining the attachment drop and the suite
  stayed at 19 passed, so the line was UNPINNED and, unlike
  `setCatalogAvailable(false)`, carried no DISCLOSURE either. That falsified this
  plan's own CHECKED criterion claiming "The one exception is recorded below" —
  there were two unpinned lines, not one — and it left the commit message's
  "with an explanation, so files never vanish unannounced" asserted but
  unverified. Reproduced before fixing.
  FIX, taking the reviewer's stated smallest correct option rather than the
  weaker one: the line is user-facing and the test that reaches it already
  existed, so it is PINNED, not disclosed. One assertion was added to the
  existing deferred-rejection test after `releaseDiscovery()`; deleting the
  `setError(...)` block now fails it with `AssertionError: expected '' to contain
  'staged files were removed'` (1 failed / 18 passed), re-recorded here rather
  than carried over from the review. The criterion is rewritten to enumerate all
  SIX mutations with their results, and to state that exactly two lines remain
  unpinned with a DISCLOSURE each — so the count is checkable instead of
  asserted, which is what failed last time.
  LOW — the file-accounting finding is against the test-integrity gate's own
  report (it listed `web/package.json`, `web/src/notes-detail.css` and
  `mise.toml`, none of which are in the commit, and omitted the three
  design-docs paths). No repository file is implicated and nothing here changes;
  recorded so the discrepancy is not silently dropped. The three design-docs
  paths ARE in the commit and were reviewed by Step 7 in this round.
  NOTED, no action: Step 7 observes the `.catch` is chained after `.then`, so a
  throw inside the `.then` body would be misclassified as an older server. The
  `.then` body is three setter calls, so it is unreachable today; recorded rather
  than restructured, since no failing check compels it.
  POST-FIX GATE: `mise run web:check` green — `tsc --noEmit`; `bun test src` 155
  pass / 0 fail / 403 expect() calls across 21 files; `vitest run` 19 passed
  across 5 files; `eslint .`; `vite build`. Test count is unchanged at 19 because
  this revision added an assertion to an existing test rather than a new test.
  The Swift sweep is unaffected — no Swift path is in the commit — and was not
  re-run. The plan STAYS in `impl-plans/active/`.
- 2026-08-29: Step 6 self-review correction to the criterion this plan had just
  rewritten. The six mutation results were restated at the current suite size,
  but mutations 1 and 2 had actually been executed at suite sizes 15 and 16
  ("1 failed / 14 passed", "1 failed / 15 passed") — so two of the six figures
  in a CHECKED criterion were normalized rather than measured. Rather than
  soften the wording, all seven mutations were RE-EXECUTED against the current
  19-test suite: toggle binding 1/18, `setAttachments([])` 1/18, `setError(...)`
  1/18, Retry binding 1/18, transport-kind check 2/17, bounded retry 2/17, and
  the disclosed `send()` guard 19 passed. Every figure now reproduces as
  written. `MemoTab.tsx` was restored after each mutation and
  `git diff --stat` on it is empty. No production, test or design file changed.
- 2026-08-29: Adversarial Step 7 revision (one mid, two low). MID — the gate
  escalated the retry budget from the correctness review's low and was right.
  Verified from source before fixing: the discovery effect's only reactive read
  was `catalogAttempt()`; `app.client` is a plain non-reactive field
  (`appStore.tsx:169`/`:476`); after exhaustion `catalogAttempt` is pinned, so
  nothing in the pane could re-run discovery. Three immediate attempts are spent
  in milliseconds, so the end state after any real outage was byte-for-byte the
  pre-commit failure — every extension control dead for the session against a
  server that recovered seconds later — while the banner told the user to wait
  for a recovery the reactive graph could not produce. The plan and commit
  message credited a deliverable the code did not deliver.
  FIX: the effect now reads `app.state.catalogRevision`, which the store
  increments ONLY after a catalog reload succeeds (`appStore.tsx:322`) and which
  the sibling reload effect at `MemoTab.tsx:209` already consumes — a real
  reconnect signal, not a timer, and the repository's existing convention for
  exactly this. TASK-011c's deliverable is corrected in place to stop claiming
  the immediate budget survives an outage.
  TEST, written before the fix and failing on HEAD with `expected true to be
  false`: exhaust the 3-attempt budget with a transport-failing stub, assert the
  controls rest and the banner shows, bump `catalogRevision`, assert the controls
  come back. The harness needed `catalogRevision` to be reactive, so the fixture
  now exposes it as a signal-backed getter — matching the real store, where it
  lives in `createStore` — rather than the plain number it was.
  MUTATION-VERIFIED: deleting the reconnect read fails that test (1 failed / 19
  passed).
  A SECOND line was written and then REMOVED rather than shipped: a dedicated
  clear for the unreachable banner on the success path. Measured UNPINNED —
  deleting it left 20 passed, because `load()` already clears the error
  unconditionally (`MemoTab.tsx:254`) and re-runs on the same `catalogRevision`
  bump. Shipping it would have added a third DISCLOSURE for a line whose only
  effect a test cannot distinguish; removing it keeps behavior identical on every
  path the suite reaches. Recorded here rather than quietly dropped.
  LOW 1 — the `agent-unavailable` server case is now recorded in Risks and
  Mitigations, naming the empty-but-enabled model select as the visible
  consequence. LOW 2 — the pre-discovery model-substitution window was already
  an ACCEPTED low; the gate confirmed it is not amplified by tab remount, since
  `draft` resets, and that attachments cannot enter the window at all.
  POST-FIX GATE: `mise run web:check` green — `tsc --noEmit`; `bun test src` 155
  pass / 0 fail / 403 expect() calls across 21 files; `vitest run` 20 passed
  across 5 files (+1); `eslint .`; `vite build`. No Swift path is in the commit,
  so the Swift sweep is unaffected and was not re-run.
- 2026-08-29: Test-integrity gate revision (one mid). The gate re-executed every
  mutation and found six of eight recorded figures did not reproduce: items 1-4
  read "1 failed / 18 passed" where HEAD gives 1 failed / 19 passed, items 5-6
  read "2 failed / 17" where HEAD gives THREE failures (the reconnect test added
  later also depends on the transport-kind discriminator), and the `send()`
  DISCLOSURE said "leaves 19 passed" where HEAD leaves 20. The gate is right,
  and so is its diagnosis of the mechanism: a previous round re-executed items
  1-6 at suite size 19, the next round added the 20th test and re-ran only item
  7, and the rest were carried forward. My own preceding self-review asserted
  "Each figure was re-verified against the tree in this pass"; that was not true
  of items 1-6, and asserting it was the defect.
  SUBSTANCE UNCHANGED, as the gate also confirmed independently: every one of the
  seven guarded lines is genuinely load-bearing, and every mutation breaks the
  test the plan names. Only the recorded numbers were wrong.
  FIX — both halves, not just the instance. (a) All EIGHT mutations were
  re-executed against HEAD at suite size 20, and each result reproduces the
  gate's figures exactly. (b) The evidence FORM changed, taking the gate's own
  residual-risk recommendation: each mutation is now recorded by the IDENTITY of
  the test it breaks, with the suite size stated once rather than repeated per
  item. A named failing test survives any later test addition; an "N passed"
  count is invalidated by every one. That removes the mechanism that produced
  this finding twice, rather than the instance. TASK-011c's parallel criterion
  and the `send()` DISCLOSURE were restated the same way.
  Historical progress entries keep their original figures — they are dated
  records of what was measured then, and rewriting them would falsify the log.
  No production file, no test file and no assertion changed; the gate scoped this
  as a plan-text correction and that is what it is.
  POST-EDIT GATE: `mise run web:check` green — `tsc --noEmit`; `bun test src`
  155 pass / 0 fail / 403 expect() calls across 21 files; `vitest run` 20 passed
  across 5 files; `eslint .`; `vite build`.
- 2026-08-29: Step 7 review revision (one mid, three low). MID — a REGRESSION my
  own reconnect trigger introduced, and the reviewer reproduced it against HEAD~
  to prove it was not pre-existing. Making the discovery effect reactive meant
  the `.catch` could run after a success; its unconditional `setModels([])` ran
  before the transport-kind check, so the normalization effect re-derived the
  selection from an empty catalog and silently overwrote — and debounce-persisted
  — the user's chosen model, with the controls re-enabled and no banner. Verified
  from source before fixing, then reproduced by a test written first: `expected
  'configured' to be 'compact'`.
  FIX (all three of the reviewer's recommendations taken): `setModels([])` moved
  below the `kind !== 'graphql'` early return; a `catalogGeneration` guard added
  to both `.then` and `.catch`, matching `load()`'s idiom; and
  `setCatalogAttempt(0)` on success so the budget is per outage rather than per
  session.
  TESTS — three added, each mutation-verified by failing-test identity. Worth
  recording HOW two of them were reached: both were first written in a form that
  PASSED with the line deleted. The stale-rejection test used a network-kind
  rejection, which self-heals via the retry and therefore proved nothing; it now
  uses a graphql-kind rejection, a permanent verdict the guard must suppress. The
  budget test asserted a control that was already enabled from the previous
  recovery; it now asserts the banner's absence. Both were caught by running the
  mutation rather than by reading the test — which is the whole point of the
  discipline, and it is the second time this round that a plausible-looking
  assertion turned out to be vacuous.
  LOW — the `:885` bullet had a sentence pasted verbatim from the preceding
  attachment-drop bullet, misattributing that evidence to the removed banner
  clear. Deleted; the bullet now states only what it actually measured.
  POST-FIX GATE: `mise run web:check` green — `tsc --noEmit`; `bun test src` 155
  pass / 0 fail / 403 expect() calls across 21 files; `vitest run` 23 passed
  across 5 files (+3); `eslint .`; `vite build`. No Swift path is in the commit.
- 2026-08-29: Test-integrity gate revision (one mid). The gate DISPROVED, by
  probe rather than argument, this plan's own DISCLOSURE that
  `setCatalogAvailable(false)` is a no-op. It is not, and has not been since my
  own reconnect trigger landed: making discovery re-runnable on `catalogRevision`
  lets the `.catch` fire AFTER a success, so that write is what returns
  `catalogAvailable` to false when a server is rolled back mid-session — the
  headline invariant of this whole commit, on the one path where availability
  goes true -> false, with zero coverage.
  Confirmed from source before acting: the signal initializes `false` at
  `MemoTab.tsx:95` (the disclosure still cited the pre-shift `:81`) and the
  `.catch` write is at `:177`.
  FIX — pinned, not re-disclosed, using the gate's own proven shape: a new test
  gates call 1 'ok' and call 2 'graphql', bumps `catalogRevision`, and asserts
  the model select and attach button go back to disabled. MUTATION-VERIFIED:
  deleting `setCatalogAvailable(false)` breaks "a server that stops
  understanding agentModels mid-session rests the controls again"
  (1 failed / 23 passed).
  BOOKKEEPING: the falsified DISCLOSURE is WITHDRAWN rather than reworded, the
  unpinned count drops from two lines to one, the unchecked-box arithmetic drops
  from 8 to 7, and the stale `:81` citation is gone with it.
  THE STRUCTURAL LESSON, recorded in Risks because it generalises: I re-executed
  that mutation every round and it never changed, because "deleting it leaves
  the suite green" is equally consistent with "dead code" and with "live code no
  test reaches". Re-measurement can confirm a disclosure's NUMBER forever while
  its RATIONALE quietly goes false under a later change. A disclosure has to be
  re-DERIVED when the surrounding code moves.
  POST-FIX GATE: `mise run web:check` green — `tsc --noEmit`; `bun test src` 155
  pass / 0 fail / 403 expect() calls across 21 files; `vitest run` 24 passed
  across 5 files (+1); `eslint .`; `vite build`. No Swift path is in the commit.

### 2026-08-29 — TASK-011c: the capability gate generalized from one call site to the effective request (Step 7 HIGH + two MIDs)

Step 7 (`step7-review-attempt-1-exec-39`) found the masquerade guard added in the
previous round protected only the RETRY path, while the DIRECT path — strictly
the more reachable of the two — stayed open. Reproduced before fixing.

- **HIGH, `MemoTab.tsx`: a direct send downgraded a latched note edit to a memo.**
  The guard tested `retry?.noteEdit`, but the request built `noteEdit: retry ?
  retry.noteEdit : noteEdit()`. Nothing resets the toggle when availability goes
  true -> false (`setNoteEdit` is called at four sites, none of them on that
  transition), so a user who enabled note edit against a healthy catalog and then
  hit a server rollback could submit from a still-enabled composer: the request
  went out with `mode` withheld and the server answered an edit request as a
  plain memo — the masquerade `web-chatbook-ui.md:254-257` forbids. The Retry
  button is disabled in that state; the textarea and submit are not.
- **MID, same root cause: a direct send dropped staged attachments silently.**
  The transport branch deliberately KEEPS staged files, so the chips still render
  during an outage. A send then withheld `attachments` entirely, and `send()`'s
  own `setError('')` wiped the unreachable banner first, so nothing told the user
  the file they could still see was not sent.
- **Fix (one shape for both):** guard the EFFECTIVE request, not a call site.
  `effectiveNoteEdit` and `effectiveAttachments` are computed before the guard,
  and a send carrying either while `catalogAvailable()` is false is REFUSED with
  an explanation. Refusal, not silent clearing, was chosen for attachments: it
  preserves the staged files so the user can send unchanged once the catalog
  returns, and it is symmetric with the note-edit refusal.
- **The guard and the builder now read ONE captured availability value.**
  `const extensionsAvailable = catalogAvailable()` is taken once at the top of
  `send()` and used by both the refusal guards and
  `buildAgentChatComposerRequest`, which also reuses `effectiveNoteEdit` rather
  than re-reading `noteEdit()`. Without that capture the invariant held only at
  the send's ENTRY: the builder runs after two awaits, and discovery (which
  re-runs on every `catalogRevision` bump and is not gated on `busy()`) could
  flip availability false inside that window, silently stripping `mode` from a
  request the guard had already admitted. Captured, "guard the EFFECTIVE
  request" holds across the whole await window for the TWO values actually
  captured — `extensionsAvailable` and `noteEdit` — so `mode` and the extension
  flag are atomically either both sent or the send is refused, and an
  actually-old server rejects the extension field loudly rather than answering
  an edit as a memo.
- **NAMED, ACCEPTED CONSEQUENCE: `attachments` is NOT among the captured
  values, and this sentence claimed it was until 2026-08-30.** The guard reads
  `attachments().length` into `effectiveAttachments` before the awaits, but the
  BUILDER re-reads `attachments()` afterwards (`retry ? [] : await
  Promise.all(attachments().map(fileToAttachment))`), and the older-server
  discovery branch calls `setAttachments([])`. So on the first send of a note
  with no subject yet, a `graphql`-kind downgrade landing inside the
  `await props.ensureSubject?.()` window lets a request the guard admitted with
  one attachment go out with zero while `extensionsAvailable` is still true.
  **Accepted rather than fixed here, for the same reason as the two tooltip
  exclusions**: no failing check compels it, and the constraint on this round is
  to change composer behavior only where a failing check requires. It is also
  materially milder than the masquerade the capture exists to stop — the drop is
  ANNOUNCED, not silent: that branch sets "This server does not accept
  attachments, so the staged files were removed.", and `send()` clears the error
  BEFORE the awaits, so the message survives to the user. A masquerade is
  answering an edit as a memo with nothing said; this is a narrower window with
  an explanation attached.
  **The one-line close, recorded so it is a decision and not an oversight:**
  hoist `const stagedAttachments = retry ? [] : attachments()` above the
  `ensureSubject` await and map that captured array in the builder. Deliberately
  NOT done in this round; it is behavior change without a failing check.
- **A retry arm prevents a FALSE refusal, and is pinned.** A retry never carries
  attachments, and the Retry button is disabled only for EDIT turns — so a failed
  MEMO turn stays retryable during an outage. Reading `attachments().length`
  instead of `retry ? 0 : ...` would refuse that retry over chips it was never
  going to send. A new `failedMemoTurn` fixture pins it.

THREE tests added, with TWO DIFFERENT evidence forms — stated separately,
because conflating them is how a verification claim goes false:
- The first two were recorded FAILING FIRST against the unfixed tree, both with
  "expected [ Array(1) ] to have a length of +0 but got 1" (the request was
  sent), then passing after the guard, then mutation-verified: mutations 8 and
  10 in the TASK-011b record.
- The third ("a memo retry during an outage is not refused for chips it would
  never send") was NEVER run against an unfixed tree, and could not have failed
  there. It asserts the ABSENCE of a refusal, and the false refusal it guards
  against exists only under mutation 11 — the unfixed tree simply had no refusal
  to be wrong about. Its sole evidence is that mutation: replacing
  `retry ? 0 : attachments().length` with `attachments().length` breaks it
  (1 failed / 26 passed). Mutation-only evidence is weaker than failing-first
  and is recorded as such rather than folded into the same sentence.

A FOURTH test was added for the await-window hole, and WAS recorded failing
first: "a mid-send catalog flip cannot strip extensions from an already-admitted
request" latches note edit and stages a file against a healthy catalog, parks the
send inside `fileToAttachment` by gating the staged `File`'s `arrayBuffer` (gated
only AFTER staging, since `validateComposerFiles` reads the file too and gating
it earlier would block the chip instead of the send), flips the catalog to
unavailable via `bumpCatalog()` + a `graphql` discovery rejection while the send
is parked, then asserts the released request still carries `mode: 'edit'`,
`attachments`, and `model`. Against the pre-capture tree it failed with
"expected undefined to be 'edit'" — the request was sent with `mode` stripped,
which is the masquerade itself rather than a proxy for it. After the capture:
17 passed in `MemoTab.integration.tsx`.

**Two findings the fix surfaced that were not in the review:**
1. The refusal's `setError` was first written as a ternary with retry-specific
   wording. Collapsing it left the suite green, so the untested branch was
   DELETED rather than shipped with a disclosure. One message serves both paths.
2. `MemoTab.integration.tsx:394` ("retrying a failed note-edit turn never
   silently downgrades it") does NOT depend on the `send()` refusal at all —
   deleting the whole refusal leaves it green, because it is pinned by the
   disabled Retry button. That is why the surviving disclosure is now stated as
   ONE ARM of the guard rather than the guard.

**The disclosure's derivation was wrong, not its measurement.** The prior round
re-measured "deleting the `send()` refusal breaks nothing" correctly and
concluded the refusal was unreachable. It stopped at the retry call site. The
direct call site was reachable and unguarded, and that is precisely how HIGH-1
passed the gate. The lesson generalizes the one recorded last round: re-deriving
a disclosure is necessary but not sufficient — the derivation must enumerate
EVERY call site, not the first one that explains the number.

The risk register's "Pending-discovery model-withholding window" entry was
rewritten. Both its load-bearing premises were false — the discovery effect does
read a reactive source and the signal does go true -> false, and the window is
UNBOUNDED during an outage rather than "one GraphQL round-trip". The accepted
residue is now narrower in cause (model only) and honestly wider in duration.

Also recorded there: the deliberate decision NOT to reset the note-edit toggle on
a true -> false transition, which Step 7 asked to consider. Resetting would make
the send succeed as a memo — the masquerade itself.

POST-FIX GATE: `mise run web:check` green — `tsc --noEmit`; `bun test src` 155
pass / 0 fail across 21 files; `vitest run` 27 passed across 5 files (+3);
`eslint .`; `vite build`. No Swift path is in the commit.

### 2026-08-29 — A stale FIGURE, and why the prose rule could not catch it (self-review mid)

The previous round recorded the rule "grep every copy of a claim before
recording it as corrected", and in the same round left a stale suite-relative
count eighteen lines below the criterion forbidding one. The TASK-011c
disclosure said deleting the note-edit refusal breaks "a direct send never
downgrades a latched note-edit to a plain memo" **(1 failed / 25 passed)**.
Re-measured this round: 1 failed / 26 passed (27). The 25 was measured before
the memo-retry test landed.

**The identity was right; only the number was wrong** — which is precisely why
the number should not have been there. `grep -nE '[0-9]+ failed / [0-9]+
passed'` over the live criteria returned it as the sole violation of the
convention stated at TASK-011c's own criterion head.

**Why the prose rule missed it.** "Grep every copy of a claim" works by
searching for the SENTENCE that carries the claim. A figure carries no
sentence: nothing about "1 failed / 25 passed" says what it measures, so no
grep for a claim can find it, and nothing goes red when it rots. Numbers need
their own sweep, by shape rather than by meaning.

**Fixed by deletion, not refresh.** The count is removed; the failing-test
identity stands alone. Refreshing it would have reset the clock rather than
stopped it. The criterion now states the numeric rule in checkable form: no
live criterion carries a suite-relative count, and `grep -nE '[0-9]+ failed /
[0-9]+ passed'` over everything above the Progress Log returns nothing.

**A near-miss worth recording, because it proves the rule's edge.** The first
attempt at this fix wrote the CORRECTED figure into the correction note — which
re-introduced the forbidden pattern and falsified the grep-clean claim in the
same edit. The sweep caught it immediately. A dated progress entry like this one
may carry figures, because it records what was measured on its date; a live
criterion may not, because it asserts what is true now.

VERIFICATION: `mise run web:check` green — `tsc --noEmit`; `bun test src` 155
pass / 0 fail across 21 files; `vitest run` 27 passed across 5 files; `eslint .`;
`vite build`. No web file changed this round; the plan is the only edit.

### 2026-08-29 — Evidence recorded as a POINTER, third shape: the line citation (self-review mid)

Three live current-state citations pointed at the wrong lines. Each was accurate
when written and rotted when a later round grew `MemoTab.tsx` by ~104 lines:

- "the sibling reload effect already consumes (`MemoTab.tsx:209`)" — :209 is
  `const normalized = normalizeSelectedAgentModel(`. The sibling read is at :240.
- "`load()`'s existing unconditional `setError('')` (`MemoTab.tsx:254`)" — :254
  is `if (pending) {`. The clear is at :267.
- "the commit's own test at `MemoTab.integration.tsx:627`" — :627 is a bare `}`.
  The test is at :636. This was the load-bearing one: it is the evidence the
  risk-register rewrite rests on, and it is the coordinate the Step 7 gate itself
  cited.

**Fixed by conversion, not correction.** Re-numbering would have reset the clock
exactly as refreshing a stale count would. All three now cite by searchable
token: two greps for distinctive expressions, and the test by NAME. Every new
pointer was re-resolved against the tree — `void app.state.catalogRevision`
returns two hits (the discovery effect and the sibling), the test name returns
one, `setState('catalogRevision'` returns one.

**Why the two existing sweeps could not catch it.** The claim-grep searches for a
SENTENCE; the numeric-grep searches for a SHAPE. A stale `File.ts:NNN` has
neither — it is syntactically valid and resolves to real text, just the wrong
text. It can only be caught by re-resolving it against the tree.

**The audit that makes the new rule true rather than asserted.** Every code
citation above the Progress Log was re-resolved this round. The remaining ones
are sound for two distinct reasons, now stated in the criterion: they sit inside
TASK write-scope blocks and deliberately use the PRE-FIX coordinate frame (a
convention the plan already documented at `:851`, "now `:600` after the
insertions"), or they point into `client.ts`, which this commit never modifies.
That gives the sweep a decision rule instead of case-by-case judgement: a bare
coordinate in a deliverable, criterion, disclosure or risk entry is a defect; the
same coordinate inside a TASK write scope is correct.

**The generalization, now stated once for all three shapes:** record evidence as
CONTENT, not as a pointer. A count, a line number and an unrewritten claim all
fail the same way — they stay syntactically valid while going false, so nothing
goes red. This is the third round to close one shape of that; the criterion above
now states all three as checks rather than intentions.

VERIFICATION: `mise run web:check` green — `tsc --noEmit`; `bun test src` 155
pass / 0 fail across 21 files; `vitest run` 27 passed across 5 files; `eslint .`;
`vite build`. No web file changed this round; the plan is the only edit.

### 2026-08-29 — The rule outran its check, and broke itself in its own sentence (self-review mid)

The coordinate rule added last round said "a CURRENT-STATE claim cites by
searchable token, never `File.ts:NNN`" — and then, two lines later, cited a
plan-internal coordinate to support itself. The checked box asserted a rule its
own text violated.

**Why the check did not catch it.** The sweep pattern is
`(MemoTab\.tsx|MemoTab\.integration\.tsx|appStore\.tsx):[0-9]+`. Running it
against the literal `` `:851` `` returns nothing. The RULE's scope was "any bare
coordinate in a criterion"; the CHECK's scope was "three code filenames". The
grep passed, so the gap was invisible — and a plan-internal coordinate is the
worst case of the three, because this file is edited every round, so it rots
faster than any code citation. It had survived only because this round's edits
landed below it.

**Fixed two ways.** The self-citation is converted to the criterion's own
identifying text, so it survives plan edits. And rule 3 now carries an explicit
SCOPE note: it claims only what its grep covers (code citations to the files
this commit modifies), and names the two excluded classes with reasons —
design-doc coordinates point at files this commit never edits, so they cannot
shift from this work; plan-internal self-references can shift but are avoided by
convention rather than grep, because criteria are interleaved with TASK blocks
and no line-range predicate separates them.

**The generalization, which is broader than the previous three rounds':** a rule
stated more widely than its check is a claim, not a verification. Each of the
last three rounds wrote a check to stop a recurrence and the recurrence landed
just outside it — counts, then coordinates, now the rule's own sentence. The
common failure is not the shape of the evidence; it is asserting coverage the
check does not deliver. Stating scope explicitly, as rule 3 now does, is what
makes a passing check mean something.

VERIFICATION: `mise run web:check` green — `tsc --noEmit`; `bun test src` 155
pass / 0 fail across 21 files; `vitest run` 27 passed across 5 files; `eslint .`;
`vite build`. No web file changed this round; the plan is the only edit.

### 2026-08-29 — A composer deadlock the whole gate chain missed (Step 7 mid)

The `!props.catalogAvailable` term this work added to the note-edit toggle went
in BARE, without the `&& !props.noteEdit` escape the `canNoteEdit` term sitting
in the same expression already carried. So a toggle already pressed when the
catalog dropped went hard-disabled, and every exit closed at once:

- the toggle could not be released (`disabled`, click leaves `aria-pressed="true"`);
- memo-only refused with "Disable note edit mode before enabling memo-only mode.";
- the send refused with the note-edit refusal THIS work added.

The composer could send nothing at all, and every instruction the UI gave pointed
at a control the same commit had disabled. The only real exits — navigate away, or
wait for a `catalogRevision` bump — are never stated to the user.

**Fixed by gating the ON transition only**, mirroring the idiom already beside it:
`(!props.catalogAvailable && !props.noteEdit)`. Note edit still cannot be turned
ON without a catalog, so `web-chatbook-ui.md:254-257` is untouched; it can now
always be turned OFF.

**Recorded FAILING FIRST**: `expected true to be false` on `noteEdit.disabled`.
Then mutation-verified in BOTH directions, which is the part worth keeping —
mutation 13 (restore the bare term) breaks the new release test, and mutation 14
(drop the term) breaks the older-server test. One mutation alone would have left
the other half of the condition unpinned.

**Why every prior gate missed it, including four of my own self-reviews.** The
suite asked "is the control disabled when the catalog is gone?" and the answer
was yes, which is what the fail-closed requirement asked for. Nobody asked what
the user does NEXT. The refusals added in earlier rounds each individually made
the composer safer, and the last one closed the final exit — the trap was
assembled across rounds, and no single round's diff contained it. The attachment
analogue is the tell: chip remove buttons carry no disabled binding, so that path
always had an escape. Reviewing a guard means reviewing the state it leaves the
user in, not only the state it prevents.

ACCEPTED LOW, not fixed (no failing check compels it, per the no-behavior-change
constraint): `setCatalogAttempt(0)` on the success path costs one redundant
`agentModels` round-trip after a recovered blip, because the effect tracks
`catalogAttempt()`. Terminating, not a loop.

VERIFICATION: `mise run web:check` green — `tsc --noEmit`; `bun test src` 155
pass / 0 fail across 21 files; `vitest run` 28 passed across 5 files (+1);
`eslint .`; `vite build`. No Swift path is in the commit.

### 2026-08-30 — TASK-009/010/011/012 re-executed against the working tree; the gate went red and was fixed

**Why this round exists at all.** Every gate leg had been recorded green on
2026-08-29, but those runs predated the uncommitted composer work still in the
tree (`web/src/components/MemoTab.tsx`, `web/src/components/MemoTab.integration.tsx`,
`README.md`, this plan). A green recorded against a different tree is exactly the
"evidence as pointer" failure this plan already names: it stays valid-looking
while the thing it points at moves. So the whole sweep was re-run against the
tree as it actually stands.

**It went red.** `mise run web:check` failed its FIRST leg, `tsc --noEmit`:

```
src/components/MemoTab.integration.tsx(793,14): error TS2532: Object is possibly 'undefined'.
src/components/MemoTab.integration.tsx(794,14): error TS2532: Object is possibly 'undefined'.
src/components/MemoTab.integration.tsx(795,14): error TS2532: Object is possibly 'undefined'.
```

The mid-send-flip test added last round asserted through bare `requests[0].mode`
/ `.attachments` / `.model`, and `web/tsconfig.json` sets
`noUncheckedIndexedAccess: true`. The failure is in the TEST, not in production
code, so the fix stayed inside the test and inside the file's own existing idiom
(`:257-259`):

```ts
expect(requests[0]).toMatchObject({ mode: 'edit', model: 'configured' })
expect(requests[0]?.attachments).toHaveLength(1)
```

**No assertion was weakened.** `toMatchObject` fails when an expected key is
ABSENT, which is precisely the masquerade the test exists to catch — a request
that went out with `mode` stripped. `?.attachments` resolving to `undefined`
fails `toHaveLength(1)` for the same reason. Three assertions became two only
because `mode` and `model` merged into one object match; the third, the
attachment count, is unchanged. Nothing was skipped, deleted, or relaxed.

**Why the first sweep looked like it passed.** The first `mise run check` was
piped (`mise run check 2>&1 | tail -80`), so the shell reported `tail`'s status,
not mise's. The failure was visible in the text (`[web:check] ERROR task failed`)
while the exit code read 0. Re-run unpiped, `mise run check` reported `EXIT=0`
honestly once the typecheck was fixed. Recorded because "exit code 0" is another
pointer that can be read off the wrong process; this is not a mise defect.

**EXECUTED EVIDENCE, 2026-08-30, after `mise run anydoc:native`:**

- Focused Swift, `PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter 'AgentChatTests|AgentGatewayCLIInvokerTests|AgentChatGraphQLTests'`:
  `AgentChatTests` 24 / 0 failures, `AgentChatGraphQLTests` 19 / 0,
  `AgentGatewayCLIInvokerTests` 11 / 0; suite rollup 54 executed, 0 failures.
- Focused web, `vitest run src/components/MemoTab.integration.tsx`: 17 passed / 17.
- `mise run test` (full Swift): `Test Suite 'All tests' passed` — 523 executed,
  0 failures (0 unexpected); swift-testing leg 34 tests, 0 failures.
- `mise run lint` (SwiftLint): `Found 2 violations, 0 serious in 181 files` —
  `NoteService.swift:572:40` and `ResendGatewayCLIMailSender.swift:75:73`, both
  `large_tuple` warnings. Both are PRE-EXISTING at HEAD in files this feature
  never touched (no Swift file is in this commit), and `0 serious` is why
  SwiftLint exits 0. Named rather than folded into "lint green".
- `mise run web:check`: `tsc --noEmit` clean; `bun test src` 155 pass / 0 fail
  across 21 files; `vitest run` 29 passed across 5 files; `eslint .` clean;
  `vite build` ✓ 57 modules.
- `mise run tauri:check`: exit 0. Re-run component-by-component for real
  evidence, since `CARGO_TERM_QUIET` suppresses the per-command output:
  `cargo fmt --check` clean, `cargo check` `Finished dev profile`,
  `cargo clippy -- -D warnings` `Finished dev profile`.
- `mise run check` (the whole gate, unpiped): `EXIT=0`.

**STILL ENVIRONMENT-BLOCKED, and this is the only thing holding the plan open:**
TASK-008's three browser-runtime criteria — controls not overflowing at pane
breakpoints, selected/disabled/hover/focus states distinguishable in both
themes, and a keyboard-only responsive/light/dark smoke. No browser runtime is
installed on this machine, and installing a headless one is an open user
decision recorded in `design-docs/user-qa/web-chatbook-ui.md`, not something this
task may decide. `web-chatbook-ui.md`'s evidence rule is explicit that reading
CSS, compiling, or static review never satisfies them, so they stay UNCHECKED
rather than argued closed. Everything else the gate covers is unaffected: no
Swift, GraphQL, core, typecheck, unit, lint, or build result depends on a
browser.

**PLAN LOCATION: stays in `impl-plans/active/`.** The move to
`impl-plans/completed/` is conditioned on every deliverable being satisfied, and
one is not. The box arithmetic is unchanged by this round — 7 unchecked = 2
RETRACTED + 3 TASK-008 criteria + 1 TASK-009 rollup (open only because of those
three) + 1 DISCLOSURE; UNMET DELIVERABLES = 1.

**REVIEW FEEDBACK ADDRESSED (mid, carried from the previous round).** The finding
was that the note-edit toggle's tooltip consequence was left unlabelled where the
`disabled`/`aria-disabled` change is enumerated, while the exactly-analogous
attachment tooltip WAS named as a deliberate exclusion. Two things were wrong,
and both are fixed above the Progress Log:

1. The consequence is now stated as its own criterion sitting directly beside the
   binding criterion, not only in the far-away analysis section. Both exclusions
   are now named at their own control.
2. **The criterion that was supposed to pin the untouched title expression was
   itself citing a rotted line number.** It read "`MemoTab.tsx:584`'s title
   expression is unchanged (now `:600` after the insertions)". The expression is
   at `:674` at HEAD and `:686` in this tree; `:600` had not resolved to it for
   several rounds. The current-state half is now a searchable token
   (`: 'Note edit mode requires a writable note'`) verified against
   `git diff -- web/src/components/MemoTab.tsx`, and the planning-frame
   coordinate is kept and labelled as such.

   The coordinate rule's own text has been corrected too, because it cited this
   exact criterion — "carrying both frames (`now :600 after the insertions`)" —
   as the EXEMPLAR of the convention. The exemplar was false. The rule now says
   what it should have said: a planning-frame coordinate may be kept and
   labelled, but the current-state half must be a token, never a second
   coordinate, since a second coordinate is just another pointer and rots
   identically. This is the fourth round to close one shape of "evidence recorded
   as a pointer", and the first where the rot was inside the rule that forbids it.

Historical progress entries that quote the old `:600` form are left as written;
they are a record of what was believed at the time, and this entry is the
correction.

VERIFICATION FOR THIS ROUND: the executed evidence block above.

**WHAT THE COMMIT ACTUALLY CONTAINS, corrected.** The first version of this line
read, verbatim from `git show c7b4fb0`'s removed side:

> VERIFICATION FOR THIS ROUND: the executed evidence block above. One code file
> changed (`web/src/components/MemoTab.integration.tsx`, test-only assertion
> reshaping to satisfy `noUncheckedIndexedAccess`); no production behavior changed.

Two of its three clauses were wrong about the commit, and they were wrong in this
plan's own forbidden way — a sentence that stays readable while going false. The
count "one code file" was wrong, and "no production behavior changed" was wrong.
Naming `MemoTab.integration.tsx` as test-only was NOT wrong: it is a test file,
and the reshaping is what this round authored. Stating that precisely matters,
because an overstated self-correction is still an inaccurate claim in a document
that polices claims. `git show --numstat b05ebcc` reports THREE files:

- `impl-plans/active/right-pane-agent-composer.md` (+179/-8) — SEVEN changed
  regions, enumerated from `git show b05ebcc -- <this file> | grep '^@@'` rather
  than from memory: (1) `@@ -1,7` the Status line; (2) `@@ -870` the note-edit
  title criterion and the new tooltip criterion; (3) `@@ -992` the coordinate
  rule; (4) `@@ -1330` the root "Focused and full verification pass" completion
  criterion; (5) `@@ -2315` the "guard and the builder now read ONE captured
  availability value" analysis paragraph; (6) `@@ -2336` the "A FOURTH test was
  added" paragraph; (7) `@@ -2533` this progress entry. **Regions 5 and 6 were
  themselves uncommitted prior-round plan text carried into b05ebcc** — the same
  carry-forward disclosure the two code-file bullets below make, which the first
  version of this bullet made for the code files and silently dropped for the
  plan file. Only regions 1-4 and 7 were authored this round.
- `web/src/components/MemoTab.integration.tsx` (+80/-0) — NOT a three-assertion
  reshaping. The whole mid-send-flip test (`a mid-send catalog flip cannot strip
  extensions from an already-admitted request`) was still UNCOMMITTED from the
  prior round, so the commit lands the entire test, with this round's
  `noUncheckedIndexedAccess` reshaping folded into it. The reshaping is the only
  part authored this round.
- `web/src/components/MemoTab.tsx` (+16/-4) — PRODUCTION code. The
  `const extensionsAvailable = catalogAvailable()` capture was likewise
  uncommitted from the prior round. It is production behavior authored EARLIER
  and committed HERE. "No production behavior changed" was true of what this
  round authored and false of what this commit contains; the two are not the
  same claim and the line conflated them.

The distinction that matters to a reviewer: this round authored one test-only
edit, but this commit is the first time the capture fix and its pinning test
enter history, so `MemoTab.tsx` is in scope for independent review even though no
one edited it today. The correction is recorded rather than silently patched,
because the same conflation — describing what was AUTHORED as if it were what was
COMMITTED — is what would let a carried-forward production change ship
unreviewed.

This correction itself is a markdown-only follow-up commit; it changes no
TypeScript, so it cannot move any gate result recorded above. `b05ebcc` is left
in history rather than amended: the self-review's evidence cites that sha, and
rewriting it would make the citation unresolvable.

### 2026-08-30 — A disclosure that had quietly become false, and the rule that ends the class

Step 7 re-executed mutation 12 against HEAD and got a different answer than the
plan recorded. It was right. Reproduced independently before changing anything:

```
perl -0pi -e 's/const effectiveNoteEdit = retry \? retry\.noteEdit : noteEdit\(\)/const effectiveNoteEdit = noteEdit()/' web/src/components/MemoTab.tsx
bun run vitest run
→ 1 failed | 28 passed
FAIL src/components/MemoTab.integration.tsx > MemoTab integration >
     retrying a failed note-edit turn never silently downgrades it to a memo
     at :432, expect(requests[0]).toMatchObject({ mode: 'edit' })
```

The plan said that mutation "breaks NOTHING". It breaks a test. The RETRY ARM of
`effectiveNoteEdit` is PINNED, not defense-in-depth nobody reaches.

**What pinned it, and why nobody noticed.** `b05ebcc` — the commit at the centre
of this whole round — changed the builder from re-reading
`retry ? retry.noteEdit : noteEdit()` to consuming the guard local
`effectiveNoteEdit`. That single substitution made the local OBSERVABLE in the
outgoing retry request, so mutating it now changes a value the suite already
asserts on. The pin was a side effect of a fix aimed at something else, and the
commit that caused it did not re-derive the disclosure it invalidated. The
disclosure kept being re-READ and re-QUOTED across three rounds; it was never
re-MEASURED.

**Both copies were fixed, because that is the specific way this failed before.**
The claim lived in two places — the numbered mutation list ("12. ... → breaks
NOTHING. This is the DISCLOSURE below.") and the DISCLOSURE box itself. The
plan's own text already warned that "a disclosure lives in more than one place,
and re-deriving one copy does not re-derive the others", having been burned by
exactly that on 2026-08-29. Fixing one copy again would have been the same
mistake a third time.

**The box is CONVERTED, not reworded.** `- [ ] DISCLOSURE` became
`- [x]` recording the pin, the test identity, and the cause. Rewording it would
have preserved a box whose premise is gone.

**ARITHMETIC CHANGED, and every live copy was updated together:** 6 unchecked
boxes = 2 RETRACTED + 3 TASK-008 browser-runtime criteria + 1 TASK-009 rollup.
It was 7 = those four terms + 1 DISCLOSURE. The sweep is
`grep -cE '^- \[[ ]\]' impl-plans/active/right-pane-agent-composer.md` → 6.
(Written with a bracket expression on purpose: the obvious spelling of that
pattern contains an unchecked box literal, so documenting it the obvious way
makes the document match its own sweep and report 7. Found by running it.)
No DISCLOSURE box remains in this plan. **The "7 unchecked" figure in this same
day's earlier progress entry was true when written and is left as that entry's
record; this entry supersedes it.**

**THE FULL MUTATION SWEEP, not just the flagged one.** Step 7's feedback was to
re-execute every mutation the plan cites by number rather than fix the one that
was caught. All four live citations were re-run against HEAD on 2026-08-30:

- **Mutation 4** — revert the Retry binding to `disabled={busy()}` → CAUGHT.
  FAIL "retrying a failed note-edit turn never silently downgrades it to a memo"
  at `:422`, the DISABLED assertion. Claim holds.
- **Mutation 8** — narrow the guard from `effectiveNoteEdit` to
  `Boolean(retry?.noteEdit)` → CAUGHT. FAIL "a direct send never downgrades a
  latched note-edit to a plain memo". Claim holds; 8 is still the NARROWING
  mutation, not the deletion.
- **Mutation 11** — replace `retry ? 0 : attachments().length` with
  `attachments().length` → CAUGHT. FAIL "a memo retry during an outage is not
  refused for chips it would never send". Claim holds.
- **Mutation 12** — CAUGHT, contradicting the plan. The one stale claim of four.

Mutations 4 and 12 break the SAME test at DIFFERENT assertions (`:422` disabled,
`:432` request `mode`), which is precisely why the old derivation looked sound:
it reasoned that the disabled Retry button swallows the click before `send()`
runs, and that is still true of the button — but the test also drives a
retryable path that reaches the builder, and the builder now reads the local.
Reasoning about one assertion of a two-assertion test is how a derivation goes
stale while staying persuasive.

The tree was restored from a pristine copy after each mutation and verified with
`git diff --stat web/src/components/MemoTab.tsx` returning empty. No mutation
artifact was committed.

**RULE 5 — Mutation results.** Added to the evidence criterion. A mutation
result is a measurement of a tree, exactly as a line number is a pointer into
one; both are facts ABOUT a tree stored OUTSIDE it, where nothing re-checks
them. Every mutation a live criterion cites by number is re-executed against
HEAD before submission. Two corollaries, both paid for: re-executing one copy
does not re-execute the others, and the commit that changes the code a
disclosure describes owes the re-derivation.

**LOW finding, addressed by naming rather than by code.** Step 7 also found the
atomicity paragraph overreaching: it claimed the capture makes the request
"atomically either fully extended or refused", listing `mode` AND `attachments`
as protected. `attachments` is not captured. The guard reads
`attachments().length` before the awaits, but the builder re-reads
`attachments()` after `await props.ensureSubject?.()`, and the older-server
discovery branch calls `setAttachments([])`. On a first send of a note with no
subject yet, a downgrade landing in that window sends zero attachments on a
request admitted with one.

Narrowed to the two values actually captured, and the window is now a NAMED,
ACCEPTED consequence stated beside the binding — the same treatment the
attachment tooltip and note-edit tooltip exclusions already get, which is the
consistency three earlier rounds each flagged the absence of. Accepted rather
than fixed because no failing check compels it and this round's constraint is to
change composer behavior only where a failing check requires. It is also milder
than the masquerade the capture exists to stop: the drop is ANNOUNCED — that
branch sets "This server does not accept attachments, so the staged files were
removed." and `send()` clears the error before the awaits, so the message
survives. The one-line close is recorded in the plan so it is a decision, not an
oversight: hoist `const stagedAttachments = retry ? [] : attachments()` above the
`ensureSubject` await and map that array in the builder.

Rule 4's enumeration corollary gained a fourth instance from this: the atomicity
list was too LONG, not too short. Both directions fail the same rule.

VERIFICATION: `mise run web:check` re-run after the four mutations were reverted
— `tsc --noEmit` clean; `bun test src` 155 pass / 0 fail across 21 files;
`vitest run` 29 passed across 5 files; `eslint .` clean; `vite build` ✓ 57
modules. This round changed no TypeScript — `git diff` on the code files is
empty and the only committed path is this plan — so the Swift, SwiftLint and
Tauri legs recorded above still describe HEAD unchanged.

STILL ENVIRONMENT-BLOCKED, unchanged: TASK-008's three browser-runtime criteria.
The plan stays in `impl-plans/active/`.

### 2026-08-30 — The fourth copy, and a rule that now runs instead of intending

Self-review found two live defects introduced or left behind by the previous
commit. Both are in this file; no code changed.

**ONE: a fourth stale copy of the retry-arm claim, in the risk register.** The
previous round corrected three sites — the numbered mutation list, TASK-011b's
"EXACTLY ONE remains unpinned" paragraph, and the DISCLOSURE box it converted —
and missed the `## Risks and Mitigations` entry, which still read "the ONLY
unpinned sub-expression is the RETRY ARM of `effectiveNoteEdit` (mutation 12)".
Mutation 12 is CAUGHT at HEAD. Three sites agreed; the fourth contradicted them.

The missed paragraph is the one that says "a superseded claim must be REWRITTEN
where it lives, not merely contradicted by a newer entry elsewhere", and it
enumerates the copies that had previously gone stale. It is now the fourth entry
in its own list — and it was missed by the same commit that added rule 5's
corollary stating that correcting one copy does not correct the others.

**Stating a rule is not running it.** That is the whole lesson of this round, and
the fix is mechanical rather than hortatory: rule 2 now carries a SWEEP, the way
rules 1 and 3 already do —

```
awk 'NR<$(grep -n "^## Progress Log" <plan> | head -1 | cut -d: -f1)' <plan> \
  | grep -nE 'unpinned|no test reaches|breaks NOTHING|defense-in-depth'
```

run over the live region before recording any disclosure as corrected, reading
EVERY hit rather than the one a reviewer named. Run now, it returns twelve hits
and all twelve are correct: past-tense history of the withdrawn signal-write
disclosure, quotations of withdrawn text explicitly marked as withdrawn, the
corrected register entry, and the sweep command itself.

**TWO: the converted criterion carried a suite-relative count.** It recorded the
mutation result as a pipe-separated failed/passed pair while the next sentence
said "the count belongs to the dated progress entry, not here". The box
contradicted itself, and it falsified the neighbouring rule-1 criterion's claim
that no live criterion carries such a count.

Rule 1's sweep had reported clean the whole time, because it matched
`[0-9]+ failed / [0-9]+ passed` — one SPELLING — while the figure used a pipe.
**A check that matches a spelling instead of the class its rule names is the
same defect as a pointer that matches a location instead of a fact.** The sweep
is widened to `grep -nE '[0-9]+ (failed|passed)'`, and the figure is removed
from the criterion; the test identity was always the durable record.

**A trap inside the fix, worth recording because running the check is what
caught it.** The first draft of this correction quoted the withdrawn figure's
digits while explaining its removal. That made this document match its own newly
widened sweep, falsifying "returns nothing" in the same edit that widened it —
the identical shape as an earlier round writing `grep -c` with an unchecked-box
literal and thereby making the plan match its own box count. A withdrawn count is
now recorded as "a count stood here", never as the count. Both sweeps were run
after the edit, not assumed: rule 1's returns nothing over the live region, and
the checkbox sweep returns 6.

**LOW, also fixed:** rule 5 described the round's work as re-running "all four
live citations — mutations 4, 8, 11 and 12". Mutation 11's only citation sits in
the Progress Log, so it is not a live citation; running it anyway was right, but
the classification was wrong. Rule 5 now says "every LIVE citation (4, 8, 12),
plus mutation 11, cited in the Progress Log and re-run anyway", and states how
the split is derived rather than recalled.

VERIFICATION: `mise run web:check` green — `tsc --noEmit`; `bun test src`
155 pass / 0 fail across 21 files; `vitest run` 29 passed across 5 files;
`eslint .`; `vite build` 57 modules. `git diff --stat -- web/ Sources/` is empty:
this round changed no TypeScript, Swift or Rust, so the Swift, SwiftLint and
Tauri legs recorded above still describe HEAD.

Unchanged and still true: TASK-008's three browser-runtime criteria are
environment-blocked, they are the single unmet deliverable, and the plan stays in
`impl-plans/active/`.

### 2026-08-30 — The sweep that proved the rule did not run

Self-review executed the rule-2 sweep this plan printed one round earlier —
verbatim, rather than an equivalent — and it returned nothing.

The command had been written as `awk 'NR<$(grep -n "^## Progress Log" <plan> |
head -1 | cut -d: -f1)' <plan> | grep -nE '...'`. The `$(...)` sits inside a
SINGLE-quoted awk program, so the shell never expands it; awk gets the literal
text, the line-number comparison is not the one intended, and the pipeline emits
nothing and exits 1.

**It reported CLEAN UNCONDITIONALLY.** That is strictly worse than the rule-1
defect it was written to improve on. Rule 1's narrow spelling reported clean only
when the region happened to contain no slash-separated pair; this one reports
clean whatever the document says. A future round copy-pasting it would have got a
false all-clear on the very check introduced to stop stale claims.

**And it is the failure the rule itself names, committed by the rule.** The
paragraph's own heading is "Stating the rule is not running it." The command
under that heading had never been run. Every 12-hit figure the previous round
recorded came from a working variant typed at the shell, while a broken variant
was what got written down — authored-versus-executed, the same split rule 5
exists to close for mutation results.

**The fix, and the standard it generalizes.** The sweep is now a fenced,
copy-paste-runnable two-line block using a `PL` variable and `awk -v n="$PL"`,
with the plan path literal so there is no placeholder to substitute. The plan now
states, once and for every sweep it prints: **a sweep is verified by executing
the DOCUMENTED TEXT VERBATIM and recording its hit count — never by executing an
equivalent and documenting a variant.**

**Verified the only way this finding permits.** The block was EXTRACTED FROM THE
FILE and executed, not retyped:

```
awk '/^```sh$/{f=1;next} /^```$/{f=0} f' <plan> > /tmp/documented-sweep.sh
bash /tmp/documented-sweep.sh | wc -l   →  12
```

Twelve hits, each read: past-tense history of the withdrawn signal-write
disclosure, quotations of withdrawn text explicitly marked as withdrawn, the
corrected risk-register entry, and the sweep's own pattern inside the fenced
block. No live false assertion remains.

Rule 1's sweep re-run over the live region after this edit: CLEAN. Unchecked
boxes: 6, unchanged. `git diff --stat -- web/ Sources/` empty — this round
changed no TypeScript, Swift or Rust, so the Swift, SwiftLint and Tauri legs
recorded above still describe HEAD.

VERIFICATION: `mise run web:check` green — `tsc --noEmit`; `bun test src`
155 pass / 0 fail across 21 files; `vitest run` 29 passed across 5 files;
`eslint .`; `vite build` 57 modules.

Unchanged: TASK-008's three browser-runtime criteria are environment-blocked,
they are the single unmet deliverable, and the plan stays in
`impl-plans/active/`.

### 2026-08-30 — Half the headline fix was unpinned, and the sentence saying otherwise was the fifth stale copy

The test-integrity step mutated a line the plan's 14-mutation enumeration never
covered, and the whole gate stayed green. Reproduced before changing anything:

```
perl -0pi -e 's/        noteEdit: effectiveNoteEdit,\n/        noteEdit: retry ? retry.noteEdit : noteEdit(),\n/' web/src/components/MemoTab.tsx
mise run web:check   →  GREEN. Mutation SURVIVED.
```

**What that means.** The capture at the top of `send()` holds TWO values.
`extensionsAvailable`'s USE in the builder was pinned by the mid-send
catalog-flip test. `noteEdit`'s USE was not. Half of this round's headline fix
could be reverted silently, under a plan sentence asserting NO sub-expression
remained unpinned.

**The enumeration's blind spot, stated so it does not recur.** Mutations 1-14
walk `send()`'s DEFINITION lines. A capture has a definition AND a use, and the
use is where the masquerade actually happens — the builder is what puts `mode`
on the wire. **An enumeration over definitions is not an enumeration over call
sites.** That is rule 4's enumeration corollary applied to mutation lists, and it
is why this survived five self-review attempts: every one of them checked that
the enumeration's entries were accurate, and none checked that the enumeration
was complete.

**Closed by a test, not by a disclosure.** The hazard is reachable, and the
production comment at the builder already named it: the read-only effect clears
`noteEdit()` when a note stops being editable, and it is not gated on `busy()`,
so it can fire inside the send's await window. New test — "a mid-send read-only
lock cannot downgrade an already-admitted note edit" — latches note edit, parks
the send on a gated attachment read, locks the notebook so the effect clears the
toggle (asserted via `aria-pressed` going false), releases, and requires the
released request to still carry `mode: 'edit'`.

Recorded FAILING FIRST against the mutation, by identity:
`FAIL … a mid-send read-only lock cannot downgrade an already-admitted note edit`
— `AssertionError: expected { … } to match object { mode: 'edit' }`. That is the
masquerade itself, not a proxy for it. Restored, the test passes.

**One test-harness change, disclosed because it is not cosmetic.** `testStore`'s
`notebook()` returned a frozen literal, so `noteEditAvailable` could never
recompute and the read-only effect was unreachable from any test. It now reads a
signal, with a `bindLockNotebook` option symmetric with the existing
`bindBumpCatalog`. No existing test's behavior changes — `readOnly` still starts
`false` — and this is an ADDITION to reachability, not a relaxation: it makes a
previously untestable production path testable.

**FIFTH stale copy of a pinning claim, and the second time the risk-register
entry went stale.** Both live copies are corrected in place: the TASK-011b
paragraph now names both corrections (the withdrawn DISCLOSURE, and the sentence
that replaced it being itself false), and the register entry now lists all three
pinned cases each by the test that pins it. The pattern is now five for five:
every time this plan has asserted coverage wider than its checks, measurement
found it.

VERIFICATION: `mise run web:check` GREEN after the fix — `tsc --noEmit`;
`bun test src` 155 pass / 0 fail across 21 files; `vitest run` 30 passed across 5
files (was 29; the new test is the +1); `eslint .`; `vite build` 57 modules.
Mutation 15 re-run against the restored tree: KILLED. `git diff` on
`web/src/components/MemoTab.tsx` empty — no production line changed this round.

Unchanged: TASK-008's three browser-runtime criteria are environment-blocked,
they remain the single unmet deliverable, and the plan stays in
`impl-plans/active/`.

### 2026-08-30 — Applying the rule instead of the finding: three more arms were open

The previous entry added mutation 15 for `noteEdit`'s definition-vs-use split and
stated the lesson: *an enumeration over definitions is not an enumeration over
call sites.* Then it fixed only the arm a reviewer had named. Self-review applied
the rule instead of the finding, probed the builder's OTHER retry arms, and found
three more survivors.

**The full probe, all four arms of `buildAgentChatComposerRequest`'s call:**

| mutation | arm | before | after |
| --- | --- | --- | --- |
| 16 | `attachments`: drop `retry ? [] :` | SURVIVED | KILLED |
| 17 | `newConversation`: drop `retry ? false :` | SURVIVED | KILLED |
| 18 | `activeConversationId`: drop `retry ? retry.conversationId :` | SURVIVED | KILLED |
| 19 | `conversations`: drop `retry ? [] :` | SURVIVES | equivalent mutant |

**One test closes three.** "a retry ignores staged chips and a pending New chat"
— healthy catalog, failed memo turn, New chat clicked, chips staged, then Retry.
It asserts the request carries no `attachments` and targets
`conversationNotebookId: 'conversation-old'`, the failed turn's conversation. That
single scenario distinguishes all three arms at once, which is why it is one test
and not three.

**Ordering inside the test is load-bearing, and was found by measurement.** The
first draft staged the chips BEFORE clicking New chat; `startNewChat` resets the
composer, so the chips were cleared and the attachments assertion was vacuous —
mutation 16 survived that very test. Measured, reordered, re-measured. Recorded
because a test that looks like it covers something and does not is exactly what
the mutation discipline exists to catch.

**TWO EQUIVALENT MUTANTS, measured then RULED OUT rather than reported as gaps.**
Surviving is not the same as unpinned:
- Mutation 19, `conversations: retry ? [] : conversations()`. The builder reads
  `conversations` only via `options.activeConversationId ?? latestConversationId(…)`,
  and on the retry path `activeConversationId` is `retry.conversationId` — typed
  `NotebookId`, always sourced from `entry.conversationId`. The right operand is
  never evaluated, so the mutant cannot differ.
- The attachments guard re-reading `!catalogAvailable()` instead of
  `!extensionsAvailable`. The capture is assigned three lines above with no await
  between them.
Both are recorded so a later round does not re-find them and "fix" a non-problem.

**SIXTH stale copy of a pinning claim, and the third time the risk-register entry
went stale.** Both live copies are corrected again, and the claim now rests on an
exhaustive probe of all four arms with its two exclusions named — not on a list
someone believed was complete. The honest summary of this document's record: six
for six, every coverage claim stated wider than its checks has been falsified by
measurement, and the only ones that have held are the ones a mutation killed.

VERIFICATION: `mise run web:check` GREEN — `tsc --noEmit`; `bun test src` 155 pass
/ 0 fail across 21 files; `vitest run` 31 passed across 5 files (was 30; the new
test is the +1); `eslint .`; `vite build` 57 modules. All four mutations reverted
from a pristine copy; `git diff --stat -- web/src/components/MemoTab.tsx` empty —
no production line changed this round either.

Unchanged: TASK-008's three browser-runtime criteria are environment-blocked, they
remain the single unmet deliverable, and the plan stays in `impl-plans/active/`.

### 2026-08-30 — Narrowing the sentence that had been falsified seven times

Test-integrity ran one command this round and it settled a question eight rounds
had not: `if (!body || busy()) return` → `if (!body) return` SURVIVES the whole
web leg. Reproduced here before editing anything — `vitest run` 31 passed.

**Two defects, and the second is the one that mattered.**

1. A third survivor existed in `send()` and was recorded nowhere — neither pinned
   nor listed with a ruling-out argument, which is this plan's own stated
   convention for survivors.
2. **The previous round's payload told Step 7 the plan's claim was "correctly
   scoped to the four builder retry arms".** No such wording existed in the file.
   `grep -c 'builder retry arms'` over the plan returned 0. The scope lived only
   in the report, and the file said, unscoped, "NO sub-expression remains
   unpinned". An assurance about a document that the document does not contain is
   worse than the overclaim it was describing.

**The fix is narrowing, not another correction.** The claim now states its
surface where the claim is made: `send()`'s three guards — its re-entry guard
plus its two refusal guards — its three capture definitions, and the builder's
four `retry ? … : …` arms. Ten sites. Both live copies say the same thing.
**Corrected the same day:** this list first read "two refusal guards", which
made its own next sentence — "three survivors on that surface" — false by one,
since the `busy()` survivor lives in the re-entry guard. The guard had been
probed, so the list was under-drawn. `addMemoOnly()`'s identical
`if (!body || busy()) return` is deliberately NOT on the surface: it was never
probed, and "`send()`'s" is meant literally.

**Why narrowing rather than a ninth re-assertion.** That sentence has now been
falsified SEVEN times, three of them after being "corrected" — by mutation 12, by
the builder's `noteEdit` argument, by three more builder arms, and now by
`busy()`. The falsifications share one cause: **an unscoped claim cannot be
checked, only disproved.** Nobody can run "no sub-expression is unpinned"; anyone
can run the nine-site surface and disagree with the result. That is the whole
difference, and it is why this round retires the form instead of repairing it
again.

**CORRECTED 2026-08-30, same day, inline per this plan's convention for dated
entries.** Two numbers in the paragraph above are wrong and are left visible
rather than rewritten. (1) "falsified SEVEN times" then lists FOUR causes —
mutation 12, the builder's `noteEdit` argument, three more builder arms, and
`busy()`. FOUR is the count of falsifications of the sentence; SEVEN is the count
of stale COPIES corrected across the plan, which is larger because one
falsification can strand several copies. The live criterion now states both
counters and says they are not the same number. (2) "the nine-site surface" was
widened to TEN later the same day, when the re-entry guard — already probed — was
found to be missing from the list.

**The third survivor, categorized precisely rather than lumped in.** It is NOT an
equivalent mutant. Mutation 19 and the attachments-guard re-read are provably
equivalent — an operand never evaluated, and a capture assigned three lines above
with no await between. `busy()` is different: a programmatic call while busy WOULD
behave differently, so the term is real defense-in-depth. It is unreachable only
because every entry point gates on busy first, verified by reading all three:

- submit button — `disabled={props.busy || !props.draft.trim()}`
- textarea keydown — `handleComposerKeyDown` → `composerKeyDownAction` returns
  `'none'` when busy
- Retry button — `disabled={busy() || (turn.mode === 'edit' && !catalogAvailable())}`

UNREACHABLE-BY-EVERY-ENTRY-POINT is a weaker claim than EQUIVALENT and is
labelled as one. Collapsing the two would be the same overclaiming, one level
down.

VERIFICATION: `mise run web:check` GREEN — `tsc --noEmit`; `bun test src` 155 pass
/ 0 fail across 21 files; `vitest run` 31 passed across 5 files; `eslint .`;
`vite build` 57 modules. The `busy()` mutation was reverted from a pristine copy;
`git diff --stat -- web/src/components/MemoTab.tsx` empty. No production or test
file changed this round — the entire fix is the plan's wording.

Unchanged: TASK-008's three browser-runtime criteria are environment-blocked, they
remain the single unmet deliverable, and the plan stays in `impl-plans/active/`.

### 2026-08-30 — The surface list was under-drawn by one guard

Self-review checked membership rather than wording and found the replacement
sentence miscounting. The surface read "`send()`'s two refusal guards, its three
capture definitions, and the builder's four retry arms" — nine sites — and the
next sentence claimed "three survivors on that surface". Only two were.

Checked against the code, not from memory:

```
grep -n 'if (!extensionsAvailable' web/src/components/MemoTab.tsx  → :379, :383
grep -n 'if (!body'               web/src/components/MemoTab.tsx  → :357, :427
```

The two refusal guards are :379 and :383. The `busy()` survivor is at :357 — the
RE-ENTRY guard, which the list did not name.

**Fixed by widening the list, not by re-counting the survivors.** The re-entry
guard had been PROBED, so it belonged on the surface all along; the defect was an
under-drawn list, not a misplaced survivor. The surface is now `send()`'s THREE
guards plus three capture definitions plus four builder retry arms — ten sites —
and all three survivors are genuinely on it.

**`send()`'s is meant literally, and that is now said out loud.** The same grep
returns a SECOND `if (!body || busy()) return`, in `addMemoOnly()` at :427. It has
never been probed by any step, it is not on this surface, and the wording must not
be read as covering it. Naming the near-identical site that is EXCLUDED is the
same discipline as naming the ones included.

**Why this is a small instance of the round's own recurring defect, stated
plainly.** Narrowing the claim was right, but a hand-drawn surface is only as
accurate as the hand. The first draft of the narrowed sentence was wrong about
its own membership within hours of being written. What makes this version better
is not that more care went into it — it is that membership is now checkable by
two greps a reviewer can run, which the nine-site version also permitted and
which is exactly how the error was caught. The check working on its first outing
is the point.

VERIFICATION: plan wording only. `git diff --stat -- web/ Sources/` empty — no
production or test file touched this round. `mise run web:check` GREEN: `tsc
--noEmit`; `bun test src` 155 pass / 0 fail across 21 files; `vitest run` 31
passed across 5 files; `eslint .`; `vite build` 57 modules. Rule 1's sweep over
the live region: clean. Unchecked boxes: 6.

Unchanged: TASK-008's three browser-runtime criteria are environment-blocked, they
remain the single unmet deliverable, and the plan stays in `impl-plans/active/`.

### 2026-08-30 — The clause list was appended to, not maintained

Self-review read the criterion top to bottom instead of reading only the sentence
under review, and found the list beneath the pinning claim broken in three ways
at once. All three verified before editing:

- **COUNT.** The lead-in said "Its three corrections are named" and then named
  FOUR clauses.
- **ORDER.** `grep -nE '^\s+\((i|ii|iii|iv)\)'` returned :915 (i), :920 (ii),
  :928 (iv), :940 (iii) — not ascending. Clause (iv) sat above clause (iii).
- **ORDINAL.** Clause (iv) opened "It was then false a THIRD time" while the
  third clause already held that slot and said "STILL false after the second".

**Cause: `375e395` appended clause (iv) where the author was reading rather than
where it belonged, and updated nothing around it.** That is the same shape as
five earlier findings — a correction applied to its own spot and not to the
enumeration containing it — landing inside the paragraph written to retire that
shape. It survived a full round because every prior check read the CLAIM; none
read the LIST under it.

**Fixed by moving the clause, not by renumbering it.** (iv) is chronologically
fourth — mutation 12 (`976ea82`), the builder `noteEdit` argument (`92ef089`),
the three retry arms (`7f28224`), then `busy()` (`375e395`) — so it belongs after
(iii), and its ordinal was wrong rather than its label. The list now runs
(i)-(iv) in the order the corrections happened.

**Two counters were being conflated and are now separated.** FOUR is how many
times the sentence itself was falsified — the clauses. SEVEN is how many stale
COPIES of a pinning claim have been corrected across the plan, and it is larger
because one falsification can strand several copies at once. The old wording
"falsified SEVEN times — three of them after being corrected" attached the
copy-counter to a list of four falsifications. Both counters are now named at the
criterion, and the earlier Progress Log paragraph carrying the conflated form has
a dated inline correction rather than a rewrite.

**The sweep caught its own documentation TWICE, and the second catch changed the
fix.** The paragraph recording this correction first wrapped so that "(iii)"
began a line, making the sweep return FIVE hits — a fifth clause that does not
exist, breaking the check in the act of documenting it. Rewritten to say "the
third clause" in prose. Then THIS progress entry did the same thing, on the
bullet describing the ordinal defect, and the sweep caught it again.

Two catches in one edit meant prose discipline was the wrong fix on its own, so
the check is now **SCOPED TO THE LIVE REGION** the way rules 1 and 2 already are:
dated Progress Log entries quote these markers by design and always will, so a
whole-file sweep was guaranteed to keep breaking as the log grew. The live-region
form is written out at the criterion and returns 4.

This is the third and fourth instance of one trap — rule 1 hit it by quoting
withdrawn digits, rule 2's checkbox sweep by printing an unchecked box, and this
sweep twice in one sitting. The general form, stated once: **a document that
greps itself must either not quote the pattern it greps for, or scope the sweep
to the region where quoting it is not allowed.** The second half is new, and it
is the more durable half, because it does not depend on remembering.

ALSO CORRECTED, low, carried from the self-review: the previous payload reported
`grep -c 's two refusal guards, its three'` as 0. Against the committed file it
returns 1 — the figure was measured before the progress entry was appended, and
that entry quotes the superseded wording. The hit is at a Progress Log line, a
labelled quotation the convention permits, so the substance held; the number did
not describe the commit it was reported against. Stated correctly here: ZERO live
copies, ONE labelled quotation below the Progress Log.

VERIFICATION: plan wording only. `git diff --stat -- web/ Sources/` empty — no
production or test file touched. `mise run web:check` GREEN: `tsc --noEmit`;
`bun test src` 155 pass / 0 fail across 21 files; `vitest run` 31 passed across 5
files; `eslint .`; `vite build`. Clause sweep over the live region: exactly 4
hits, ascending. Rule 1 over the live region: clean. Rule-2 sweep extracted and executed: 17. All three
copies of the ten-site surface agree. Unchecked boxes: 6.

Unchanged: TASK-008's three browser-runtime criteria are environment-blocked, they
remain the single unmet deliverable, and the plan stays in `impl-plans/active/`.
