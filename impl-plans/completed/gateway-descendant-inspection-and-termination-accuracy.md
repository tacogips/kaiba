# Gateway Descendant Inspection and Termination Accuracy

**Status**: COMPLETE — archived to `impl-plans/completed/` at Step 8
implementation-plan completion check
(`claude-opus-design-and-implement-review-loop-session-57`,
`step8-impl-plan-completion-check`, 2026-08-31).
TASK-001 through TASK-005 were done in Step 6. All four review gates have now
run: Step 6 implementation self-review (accepted), Step 6 test-integrity review
(satisfied), Step 7 ordinary review (findings folded in), Step 7 adversarial
review (comm-000766 REJECTED on one mid ESRCH finding, addressed, then
comm-000771 ACCEPTED). Step 7b browser E2E was skipped as doubly out of scope
(comm-000772) and Step 8 documentation refresh completed (comm-000773). Two
criteria remain visibly unchecked below and are carried as ACCEPTED
LIMITATIONS, not as open work: the whole-product Linux cross-compile
(TASK-002) and the compilation half of D8. comm-000771 accepted both as
non-blocking recorded limitations. The only remaining workflow step is commit
generation, which is not plan work.
**Workflow Mode**: `issue-resolution`
**Issue Reference**: `direct-workflow:comm-000746`
(workflow `claude-opus-design-and-implement-review-loop-session-56`,
Step 3 design review accepted, `needs_revision: false`)
**Base Commit**: `74d0048`
**Target Feature Area**: `Sources/AppCore/AgentGatewayProcessTermination.swift`

**Design References** (the accepted design is the source of truth).
All line anchors below are as-of the working tree at plan-creation time.
TASK-001 edits `ai-agent-integration.md` and will shift every anchor into
that file, so each reference also names its section; re-derive the numbers
after TASK-001 lands and treat the section names as authoritative:

- `design-docs/specs/ai-agent-integration.md:102-524` — Process Lifecycle and
  Termination Boundary. Sub-anchors re-derived after TASK-001 landed; section
  names stay authoritative if the two ever disagree:
  - `:148-179` Termination policy, including the corrected `unavailable`
    bullet naming `scheduleFinalGroupCleanup`'s `case .live, .unavailable`
    branch, the once-per-request arming, and the `forceKillRequested` one-shot.
  - `:180-339` Portability boundary and the **Linux enumeration contract**
    (three causes, errno-at-open discrimination, compound-guard split,
    structural one-character state-field invariant, syscall-level read).
    `**Linux enumeration contract.**` opens at `:202`.
  - `:340-363` Validation rules 1-7; `Executable gate:` is at `:359`.
  - `:365-387` Named regressions split into Production path vs Seam driven.
  - `:388-510` Real-zombie production regression required shape, the
    structural no-SIGKILL argument, the probe-observer requirement, and the
    recorded wildcard-`waitpid` assumption plus fallback, which now opens at
    `:496`.
  - `:511-524` Recorded coverage limitation: no production-path `unavailable`.
- `design-docs/user-qa/ai-agent-runtime-and-ui.md:53-100` — Question 5 and
  Status 5. Question 5 (bounded vs unbounded `unavailable` wait) stays OPEN and
  is out of scope. The ENOENT sub-question is decided and is in scope.
- `design-docs/specs/multi-user.md:494-498` — read-only context; the
  multi-user ownership work is closed and must not be reopened.

## Purpose

Resolve the three findings raised against `74d0048` and then pass the four
outstanding review gates.

1. **FINDING 1 (mid, code-bearing).** `linuxProcessGroupMembers` returns `nil`
   on any per-entry stat read or parse failure, and `nil` maps to
   `.unavailable`. A PID that exits between the `/proc` listing and its stat
   read is routine, so on Linux `.unavailable` is currently an expected
   transient state rather than the rare abnormal condition the termination
   policy assumes. Because `scheduleFinalGroupCleanup` matches
   `case .live, .unavailable`, a transient `.unavailable` arriving while the
   one-shot is unspent SIGKILLs a group that may be zombie-only, which the
   `zombies` contract forbids.
2. **FINDING 2 (low, documentation).** Already resolved in the accepted design
   text; carried here only as a no-code verification item.
3. **FINDING 3 (mid, test integrity).** Two of the four regressions previously
   labelled production-path are seam driven. The label is corrected in the
   design; this plan adds the missing genuine production-path regression
   against a real zombie and records the `unavailable` gap as a limitation.

## Scope Guard

- Do not redesign the four-state `ProcessGroupDescendantStatus` contract.
- Do not reopen multi-user ownership work.
- Do not change escalation policy, branch selection, or timing. The new
  observer must **report and only report**.
- Do not decide Question 5. The `unavailable` wait stays unbounded.
- Backward compatibility is explicitly NOT required. No migrations, no
  compatibility shims, no legacy fallbacks.
- Do not weaken or modify
  `testProductionPostReapCleanupWithoutDescendantsSkipsGraceAndSIGKILL` or
  `testProductionCancellationAfterLeaderExitWaitsForDescendantCleanup`
  (validation rules 3 and 4, explicitly NOT IN SCOPE).
- Preserve the existing uncommitted additive design-doc changes
  (408/5/48 insertions, zero deletions against `74d0048`).
- Deferred and untouched: TASK-409 Host/Origin hardening and browser login,
  per-user long-term memory, sharing-era attribution, Linux served-gateway
  runtime execution, right-pane browser validation.
- English only, no emojis. Swift files stay under 1000 lines. Existing SwiftPM
  target boundaries are kept.

## Carried Constraints from Step 3 (comm-000746)

These are binding on implementation and are restated because each one has a
plausible-looking wrong implementation:

- **C1.** Do NOT re-import the intake brief's Darwin claim that `unavailable`
  "requires three consecutive sysctl failures". It is false against
  `darwinProcessGroupMembers`, which returns `nil` on the first sizing failure
  and on the first non-`ENOMEM` fetch failure. The three-iteration loop is a
  bounded retry for the size-then-fetch `ENOMEM` race only. The accepted design
  already states this correctly at `ai-agent-integration.md:187-196`.
- **C2.** The ENOENT discrimination is NOT satisfiable by
  `try?` + `String(contentsOfFile:)` plus a `FileManager.fileExists` re-check,
  nor by inspecting an `NSError` domain or code. It requires a syscall-level
  `open` and `read` surfacing `errno`, **plus** the compound-guard split.
  Meeting only the prose leaves the fail-open path in place.
- **C3.** The new probe observer must report and only report. If its presence
  changes the branch taken, the escalation policy, or the timing of the switch,
  the production-path claim collapses. Model it on `signalObserver` and
  `leaderReapedObserver`, never on `descendantStatusInspector`.
- **C4.** The new regression must await a **`zombies`** observation
  specifically and fail loudly on timeout. Awaiting any observation, or timing
  out and proceeding, reopens the implied-coverage hole through a new
  mechanism.
- **C5.** The scheduled probe and the default poll waiter both dispatch on
  `DispatchQueue.global(qos: .utility)`. The invocation must be driven
  concurrently with the test's step 4 and step 5, because cleanup is still
  blocked in its poll loop at that point.

## Deliverables

- [x] D1: `linuxProcessGroupMembers` implements the Linux enumeration
      contract: `/proc` listing failure and existing-but-unreadable/unparseable
      stat produce `.unavailable`; `ENOENT` at open skips the entry.
- [x] D2: The stat read is a syscall-level `open`/`read` that surfaces `errno`;
      `EINTR` is retried, not classified.
- [x] D3: The compound field guard is split: unparseable pgid is cause 2
      (fail closed); a cleanly parsed non-matching pgid is an ordinary
      non-member `continue`.
- [x] D4: The state field carries a structural invariant (present and exactly
      one character); zombie-ness stays the `== "Z"` test. No allowlist.
- [x] D5: A descendant-status observation seam on `ProcessTerminator`, reported
      by `scheduleFinalGroupCleanup` before it acts, plumbed through
      `AgentGatewayCLIInvoker.run`.
- [x] D6: `testProductionZombieDescendantWaitsForDisappearanceWithoutSIGKILL`
      exists, follows the five-step required shape, and passes repeatedly.
- [x] D7: Design-doc polish for the three Step 3 low findings.
- [~] D8 (partial): Full and focused verification gate recorded, with the Linux
      non-execution stated plainly.
- [x] D9: `progress.json` updated and valid JSON.

## Tasks

### TASK-001: Design-doc polish for the three Step 3 low findings

**Parallelizable**: Yes (write scope:
`design-docs/specs/ai-agent-integration.md` only; disjoint from all Swift work)

**Dependencies**: None.

The Step 3 review accepted the design with three lows explicitly marked
optional polish that do not require another revision round. They are cheap and
in one file, so they are done first and separately from code.

1. `:236-247` — the misalignment disjunction reads as exhaustive but is not.
   Name the **third** branch alongside the single-character substitution case:
   a line shifted left by one gives `fields[0]` = ppid, which can legitimately
   be a single character, and `fields[2]` = session id, which parses as a valid
   `pid_t` and simply does not match our group, so the entry takes the ordinary
   non-member `continue` and is silently dropped. That is a fail-open
   under-report, not a fail-closed outcome. Impact stays low on the same basis
   already used for the substitution case: no producing mechanism for
   kernel-generated content. The rule itself is unchanged and correct.
2. Repair three ragged wraps that leave orphan line fragments mid-paragraph:
   line 155 (`  escalation check;`), line 246 (`would`), line 464
   (`and reap observers. This is an`). Presentation only; all are inside the
   80-character budget.
3. `:485-488` — narrow the recorded assumption's scope to match its evidence,
   or extend the evidence. The claim covers "nothing else in the test process"
   while the justification cites only this repository's production code.
   XCTest and Foundation are inside the stated scope and outside the stated
   evidence. Either scope the claim to production code plus an explicit
   unverified remainder, or add evidence for the remainder.

**Completion Criteria**:

- [x] The third misalignment branch is named at `:236-247`.
- [x] No orphan line fragments remain in the block added by this work.
- [x] The recorded assumption's scope and evidence match.
- [x] `git diff --check` clean, exit 0.
- [x] Over-80-character line counts stay at the `74d0048` baseline
      (9 / 2 / 0 for `ai-agent-integration.md`, `multi-user.md`,
      `ai-agent-runtime-and-ui.md`), all pre-existing and outside the added
      block.
- [x] Zero deletions of pre-existing content:
      `git diff --numstat 74d0048 -- design-docs/` still shows a
      deletion column of 0 for all three files.
- [x] This plan's own line anchors into `ai-agent-integration.md` are
      re-derived against the post-TASK-001 file, in the Design References
      block and in TASK-002 and TASK-003. Section names stay authoritative if
      the two ever disagree.
- [x] The Verification section's executable-gate anchor is re-derived. It
      currently cites `ai-agent-integration.md:345-353`, but the
      `Executable gate:` line is at `:348` and the enclosing
      `### Validation rules` section runs `:329-353`.
- [x] The re-derivation also covers the plan's **Swift source anchors**, not
      only the design-doc ones, and checks the plan against itself for
      internal disagreement. Symbol names are authoritative over line numbers
      throughout; a correctly named symbol at a stale line is navigational
      only, but the plan must not cite two different ranges for one symbol.
- [x] The over-80 check is run in **characters, not bytes**. A byte-based
      count reports 16 / 5 / 1 because of em dashes and is misleading; the
      character-accurate baseline is 9 / 2 / 0, and all nine in
      `ai-agent-integration.md` sit at lines 24, 631, 638, 652, 713, 843, 854,
      855, 871, every one outside the added 102-509 block.

**Deliverables**: D7.

### TASK-002: Linux enumeration contract in `linuxProcessGroupMembers`

**Parallelizable**: No (write scope:
`Sources/AppCore/AgentGatewayProcessTermination.swift`, shared with TASK-003)

**Dependencies**: None; may start immediately. Must land before TASK-003 to
avoid a write conflict in the same file.

Current defect site: `AgentGatewayProcessTermination.swift:175-194` as of
`74d0048`; after this task the Linux block runs `:174-286` with
`linuxProcessStatContents` at `:205`, `linuxProcessStatFieldsAfterCommand` at
`:247`, and `linuxProcessGroupMembers` at `:254`. The
function lists `/proc`, and for each numeric entry does
`try? String(contentsOfFile:)` with a bare `return nil` on failure, then a
compound `guard fields.count >= 3, pid_t(fields[2]) == processGroupIdentifier`
that sends two opposite-safety outcomes to one `continue`.

Required end state, per the **Linux enumeration contract** at
`ai-agent-integration.md:202-339` (re-derived after TASK-001):

1. `/proc` listing failure → `nil` (`.unavailable`). Unchanged.
2. Per numeric entry, perform a syscall-level `open` of `/proc/<pid>/stat`.
   - `open` fails with `ENOENT` → **skip this entry and continue.** The PID
     vanished between listing and read; a process that no longer exists is not
     a descendant.
   - `open` fails with `EINTR` → retry the `open`, do not classify.
   - `open` fails with any other errno → `nil` (`.unavailable`). Cause 2.
   - `read` fails with `EINTR` → retry the `read`, do not classify.
   - `read` fails with any other errno → `nil` (`.unavailable`). Cause 2.
   - `open` succeeded but contents yield no parseable line (no `)` found, or
     the post-`)` split yields fewer than 3 fields) → `nil` (`.unavailable`).
     Cause 2, not a vanished PID.
   - Always close the descriptor on every exit path from the per-entry read.
3. Split the compound guard:
   - `pid_t(fields[2])` fails to parse → cause 2 → `nil` (`.unavailable`).
   - `pid_t(fields[2])` parses and does not equal `processGroupIdentifier` →
     ordinary non-member `continue`.
   - `fields.count < 3` → cause 2 → `nil` (`.unavailable`).
4. State-field structural invariant: `fields[0]` must be present and exactly
   one character. Missing, empty, or multi-character → cause 2 → `nil`.
   Zombie-ness stays `fields[0] == "Z"`. **Do not** validate the token against
   an enumerated set of process states; the design explains at `:234-269` why
   an allowlist fails in the dangerous direction (an unlisted-but-valid state
   such as `I` would make `unavailable` the normal Linux result and hang every
   invocation on the unbounded fail-closed wait).

Explicitly forbidden implementations, restated from C2 and from
`ai-agent-integration.md:270-313`:

- Discriminating by re-testing the path for existence after a failed read. A
  re-check is a second observation at a later instant, and a process that exits
  between a genuine read failure and the re-check gets reclassified as
  vanished — the fail-open direction.
- Catching the Foundation error and inspecting an `NSError` domain or code.
  That reports how Foundation classified a failure after the fact, through a
  mapping that is not guaranteed to preserve the distinction the contract
  turns on.
- Skipping every failed entry unconditionally. Under-reporting a descendant
  yields `none`, which lets cleanup complete and reap the witness while a
  descendant is still alive and the numeric PGID becomes recyclable.

`darwinProcessGroupMembers` is NOT modified. Per C1, its first-failure
behavior is already correct and already correctly described.

**Linux compile check (required, and not covered by any other gate).**
`mise run build` is plain `swift build` (`mise.toml` `[tasks."build"]`),
`mise run check` is test + lint + web:check + tauri:check, and every
`swift test --filter` runs on the macOS host, where the preprocessor excludes
the `#if os(Linux)` branch outright. So no command elsewhere in this plan
compiles the code D1-D4 rewrite. Because those deliverables move Linux-only
code to raw syscall-level `open`/`read` with `errno` under Glibc, a symbol or
type error there would pass every other gate silently. Run the container
command from `.github/workflows/linux-amd64-build.yml:30-51` locally
(Docker is available on this host):

```
IMAGE=swift@sha256:4c6af6663ed2316002a3b38ff5505a1fc1f2749ec31e84936c32dd336713c569
docker run --rm --platform linux/amd64 -e EXECUTABLE_NAME=kaiba \
  -v "$PWD:/workspace" -w /workspace "$IMAGE" \
  bash -lc 'set -euo pipefail; apt-get update -q; apt-get install -q -y \
    --no-install-recommends curl ca-certificates build-essential; \
    curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y \
      --profile minimal --default-toolchain 1.97.1; \
    export PATH="$HOME/.cargo/bin:$PATH"; scripts/build-anydoc-native.sh; \
    export PKG_CONFIG_PATH=/workspace/.build/anydoc-native/host/pkgconfig; \
    swift build -c release --product kaiba --triple x86_64-unknown-linux-gnu'
```

`--product kaiba` pulls in AppCore, so `linuxProcessGroupMembers` is compiled.
This proves compilation only. It does **not** execute the `/proc` walk, and the
plan must not let the two claims collapse into one.

**Deliverables**: D1, D2, D3, D4.

**Completion Criteria**:

- [x] `#if os(Linux)` branch compiles; the Darwin branch is byte-identical to
      `74d0048` apart from any shared helper extraction. **Basis, stated
      because `:310` below is unchecked and the two must not be read as one
      claim: this rests solely on `swiftc -typecheck` of
      `AgentGatewayProcessTermination.swift` as a single file under Glibc, plus
      the churn probe that compiled and executed the extracted block with
      `swiftc -O`. It does NOT rest on the product building on Linux, which it
      does not.** Darwin byte-identity verified by extracting and diffing the
      `darwinProcessGroupMembers` block against `74d0048`.
- [x] Every one of the seven per-entry outcomes above is reachable and its
      classification is traceable to a named cause in the design.
- [x] No `FileManager.fileExists`, no `String(contentsOfFile:)`, and no
      `NSError` inspection on the stat path.
- [x] `EINTR` retried at both `open` and `read`.
- [x] Every descriptor opened is closed on every path.
- [x] File stays under 1000 lines (393 at `74d0048`, 511 now).
- [x] `mise run lint` clean at the SwiftLint baseline (3 violations,
      0 serious).
- [ ] The Linux cross-compile above is run and its outcome recorded. This is
      a standalone criterion: no other scheduled command compiles the
      `#if os(Linux)` branch.
      **ACCEPTED LIMITATION, left unchecked deliberately.** The criterion was
      not met. What was run instead is a single-file
      `swiftc -typecheck` for `aarch64-unknown-linux-gnu` on Swift 6.1.3,
      exit 0, recorded in the Progress Log and annotated per ADV-R4. The
      whole-product Linux compile was never executed here. comm-000771
      accepted this as a non-blocking limitation, so it does not keep the plan
      active, but it is not converted to a pass.
- [~] Self-review explicitly justifies the discrimination, as the issue
      demanded, and keeps the two claims separate rather than collapsing them.
      **First half MET**: the discrimination is justified at length in the
      TASK-002 Progress Log entry and in the doc comment on
      `linuxProcessStatContents`, naming the three rejected alternatives and
      why each fails. **Second half SUPERSEDED**: this criterion as written
      asserts "the Linux branch **is compiled**, by the cross-compile above and
      by Linux CI". That premise is false and is retracted below; the two
      claims are still kept separate, but the accurate split is
      *not compiled as part of the product, and not executed*, with only a
      single-file `swiftc -typecheck` holding. Left unchecked rather than
      rewritten to match the outcome.
- [x] The accepted residual window is restated, not silently relied upon: a
      task reaped between a successful `open` and the `read` classifies as
      `unavailable` (fail closed), and the exposed entry count does not shrink
      — only the per-entry interval does.

### TASK-003: Scheduled-probe observation seam

**Parallelizable**: No (write scope:
`Sources/AppCore/AgentGatewayProcessTermination.swift` and
`Sources/AppCore/AgentGatewayCLIInvoker.swift`)

**Dependencies**: TASK-002 (same file).

Per `ai-agent-integration.md:436-495`, the scheduled probe is the one state
evaluation in this contract whose outcome leaves no trace: its
`case .none, .zombies` arm emits nothing, no existing observation seam fires on
it, and the loop's continued blocking does not reveal which state the scheduled
probe saw. `none` and `zombies` are therefore indistinguishable from outside,
and timing cannot close the gap — the grace bounds when the probe is
*scheduled*, not when it *runs*.

Required change:

1. Add an optional descendant-status observation closure to
   `ProcessTerminator` (`AgentGatewayProcessTermination.swift:361-495` after
   TASK-002), stored alongside `signalObserver`.
2. `scheduleFinalGroupCleanup` (`:457` after TASK-002) captures the status
   once, reports it through the observer, and *then* switches on the captured
   value. Report before acting.
3. Thread the closure through `AgentGatewayCLIInvoker.run`'s parameter list
   (`AgentGatewayCLIInvoker.swift:281-294`, terminator constructed at
   `:320-328`), defaulting to `nil`, in the same
   position and style as `signalObserver` / `leaderReapedObserver`.

Per C3, this is an **observation** seam, not an injection seam. The real
inspector still runs and still decides; the observer only reports what it
decided. The `case .live, .unavailable` / `case .none, .zombies` split, the
once-per-request arming, and the `forceKillRequested` one-shot are all
unchanged. Do not model it on `descendantStatusInspector`, which replaces the
inspector and would make any test using it seam-driven by this document's own
split.

**Deliverables**: D5.

**Completion Criteria**:

- [x] Exactly one new closure parameter reaches `ProcessTerminator`.
- [x] `scheduleFinalGroupCleanup` calls `descendantStatus()` exactly once per
      firing and reports the captured value before the `switch`.
- [x] The escalation branch set is textually unchanged.
- [x] Default is `nil` at every call site; all existing call sites compile
      without modification beyond the added defaulted parameter.
- [x] No production behavior changes when the observer is `nil`.

### TASK-004: Production-path real-zombie regression

**Parallelizable**: No (write scope:
`Tests/AppCoreTests/AgentGatewayCLIInvokerLifecycleTests.swift`, currently
338 lines and far from the 1000-line limit)

**Dependencies**: TASK-003 (needs the observation seam).

The new regression goes in the existing lifecycle file. A sibling file is
**not** a free alternative and is not offered as one: every helper the shape
needs is file-private to that file — `runLifecycleGateway` :353 (:233 before
this task), `assertSignalsUseWitness` :416 (:248), `makeLifecycleGatewayScript`
:428 (:260), `lifecycleFixtureURL` :437 (:269), `readLifecyclePID` :443 (:275),
`GatewayLifecycleSignalRecorder` :447 (:279), `waitForLifecycleCondition` :516
(:326). A
sibling cannot see any of them, so taking that route would mean widening those
declarations to internal or duplicating them, which is added write scope
nobody has scheduled. At 338 lines there is no reason to.

**`waitForLifecycleCondition` cannot be reused as-is for step 4.** It hardcodes
a two-second deadline (`clock.now + .seconds(2)`, :328 before this task) and
takes no timeout
parameter, while the existing production regression passes grace
`2_000_000_000` (:31), also two seconds. Reused unchanged at that grace, the
deadline equals the *earliest possible* observation time, entry + grace, before
any dispatch latency — so the await would time out and C4's fail-loudly path
would fire on a correct implementation. Either give
`waitForLifecycleCondition` a deadline parameter (existing call sites keep the
two-second default), or add a grace-derived sibling waiter in the same file.
Both are already inside this task's write scope. Without one of them the
required "stated multiple of the grace" is not expressible.

Add `testProductionZombieDescendantWaitsForDisappearanceWithoutSIGKILL`,
implementing the required shape at `ai-agent-integration.md:388-510` exactly.
No `processGroupDescendantStatusInspector` is passed, so the real inspector
runs.

Required ordering (all five steps, in order):

1. The gateway script publishes **two distinct markers**, then blocks on a
   test-written marker. Both are required and they must not be conflated:
   - **Process-group id marker** — the pgid the script is running in
     (`ps -o pgid= -p $$` or equivalent). In the witnessed group this equals
     the witness PID. Consumed by step 2 as the
     `posix_spawnattr_setpgroup` target.
   - **Leader-PID marker** — `echo $$ > "$GATEWAY_LEADER_PID_MARKER"`, the
     script's own PID, which is the gateway leader and is *not* the witness.
     Consumed only by `assertSignalsUseWitness`. This is the same idiom the
     rule-3 regression uses at `AgentGatewayCLIInvokerLifecycleTests.swift:17`
     (unshifted; the new test is inserted after it)
     with its env wiring at `:27`.

   **Why both, and why they cannot be the same marker.**
   `assertSignalsUseWitness(_:gatewayLeaderFrom:)` (`:416` after this task,
   `:248` before) reads a PID from
   the marker and asserts every recorded signal target satisfies
   `$0.0 != -leaderPID`. Cleanup signals the group as `-pgid`, and in the
   witnessed group `pgid == witnessPID`. So feeding the **pgid** marker to that
   helper compares `-witnessPID != -witnessPID`, which is false, and the
   assertion fails against a correct implementation. The helper only works when
   fed the gateway leader's own PID, which differs from the witness. An earlier
   revision of this plan required the pgid and forbade "its own PID", which
   made this step and the `assertSignalsUseWitness` criterion mutually
   unsatisfiable; that is corrected here. Do not resolve a failure of that
   criterion by dropping or weakening the helper — doing so removes
   validation-rule-1 witness-exclusion coverage from the only new
   production-path regression, the direction validation rule 6 forbids.
2. The test spawns a child **directly into that process group** and waits for
   that child's own exit marker. It does not reap it. The group now holds one
   real zombie descendant.
3. The test writes the marker; the script exits on its own. Post-exit cleanup
   runs and arms the one-shot escalation.
4. Cleanup must observe `zombies` through the real inspector, must not
   complete, and must not emit SIGKILL. The test **awaits a `zombies`
   observation from the TASK-003 probe observer** and fails loudly on timeout
   (C4). It does not infer the observation from elapsed time and does not
   accept any-observation.
5. Only after that observation arrives does the test reap the zombie with a
   raw `waitpid` on that specific PID. Only then may inspection fall to `none`
   and cleanup complete. Recorded termination signals must be exactly
   `[SIGTERM]`.

Mechanism constraints:

- **Spawn.** The zombie's parent must be the test process itself; a zombie
  whose parent exits is reparented and reaped away. The binding requirement is
  the capability, not the call: the spawn must place the child into an
  already-created process group it did not create, and leave the child
  unreaped by anything except step 5. Foundation `Process` satisfies neither
  and is excluded. The recommended instance is raw `posix_spawn` with
  `POSIX_SPAWN_SETPGROUP` and `posix_spawnattr_setpgroup` set to the published
  pgid, because production already uses exactly that idiom to join the
  witnessed group (`AgentGatewayCLIInvoker.swift:608` after TASK-003), which
  proves it works
  here. `fork` + `setpgid` + `exec` also satisfies the capability.
- **Block-and-exit.** Whatever the script uses to wait for the marker must not
  leave a live helper process in the group when it exits. A helper that
  outlives the script is reparented but keeps its process-group id and would
  present as a live descendant, reintroducing the `live` state the ordering
  exists to exclude. A polling `sleep` loop is a live descendant; prefer a
  mechanism that `exec`s into the wait so no extra child exists at all.
- **Marker, not stdin EOF.** The block must key on a test-written marker. The
  invoker closes stdin without test control, which would race step 2.
- **Concurrency.** Per C5, the invocation runs in a `Task` and steps 4 and 5
  are driven concurrently with it, because cleanup is still blocked in its poll
  loop at that point. The scheduled probe and the default poll waiter both
  dispatch on `DispatchQueue.global(qos: .utility)`.
- **Why the step-4 await terminates** (the criterion demands it fail loudly
  on timeout, so the non-deadlock must be derived, not asserted).
  `terminateRemainingProcessGroup` arms the one-shot exactly once
  (`AgentGatewayProcessTermination.swift:402-406` after TASK-002/003); the
  probe at `:457-474`
  evaluates `descendantStatus()` once at entry plus grace; and the injected
  zombie exists from before cleanup entry until step 5 reaps it. That single
  probe firing therefore necessarily observes `zombies`. A `live` or
  `unavailable` evaluation would escalate and fail the exactly-one-SIGTERM
  assertion loudly instead of hanging.
- **Timeout must be derived from the configured grace.** The observation
  cannot arrive before entry + grace + dispatch latency, so a step-4 timeout
  chosen independently of the grace turns C4's fail-loudly requirement into a
  flaky failure. `runLifecycleGateway` already takes grace explicitly, and the
  existing production regression passes `2_000_000_000`. Pick the timeout as a
  stated multiple of the grace actually passed, and say which.
- **The `runLifecycleGateway` observer hop is TASK-004's work, not
  TASK-003's.** That helper (`AgentGatewayCLIInvokerLifecycleTests.swift:353`
  after this task, `:233` before)
  currently forwards `grace`, `processGroupDescendantStatusInspector`, and
  `signalObserver`, but has no descendant-status observation parameter.
  TASK-003's write scope is the two `Sources/` files only and D5 stops at
  `AgentGatewayCLIInvoker.run`, so the test-helper hop belongs to nobody unless
  stated here. It falls inside TASK-004's declared write scope: add the
  defaulted parameter to `runLifecycleGateway` and forward it, leaving existing
  call sites unchanged.
- **No mandated grace.** The shape must not depend on any grace value. The
  no-SIGKILL half is structural: the invoker awaits `spawned.completion.wait()`
  (`AgentGatewayCLIInvoker.swift:357` after TASK-003) before the post-exit
  `terminateRemainingProcessGroup` (`:380`), and completion is published only
  after `waitpid` has marked the leader reaped, so `live` is excluded before
  the escalation is armed and `scheduleFinalGroupCleanup` takes its
  `case .none, .zombies` no-op branch regardless of grace sizing.
  `unavailable` is excluded by unmodelled-event reasoning, not structurally;
  if it occurred, the exactly-one-SIGTERM assertion fails loudly, which is the
  correct direction.

Also in this task, per FINDING 3's label correction (already made in the
design), confirm the two seam-driven tests keep their names and are not
presented as production path anywhere in code comments.

**Deliverables**: D6.

**Completion Criteria**:

- [x] The test exists under the exact name
      `testProductionZombieDescendantWaitsForDisappearanceWithoutSIGKILL`.
- [x] No `processGroupDescendantStatusInspector` argument is passed.
- [x] Step 1 publishes **both** markers, and step 2 consumes the
      process-group-id marker as its `posix_spawnattr_setpgroup` target. One
      marker alone does not satisfy this; see the two-marker rationale.
- [x] The `runLifecycleGateway` helper gains the descendant-status
      observation parameter, defaulted so existing call sites are unchanged.
- [x] Step 4 awaits a `zombies` observation specifically, with an explicit
      timeout that fails the test rather than proceeding.
- [x] Step 5 reaps via a specific-PID `waitpid` performed by the test.
- [x] Final assertion is `signals.terminationSignals.map(\.1) == [SIGTERM]`.
- [x] The witness-exclusion assertion (`assertSignalsUseWitness`) is applied,
      **fed the leader-PID marker (`$$`), never the process-group-id marker.**
      Passing the pgid marker fails against a correct implementation; see the
      two-marker rationale in step 1.
- [x] Mutation check for validation rule 6, with the expected failure mode
      named for each so the criterion is checkable rather than assertable.
      Reverting witness exclusion makes the SIGTERM-killed witness zombie a
      permanent group member, so `descendantStatus()` never reaches `.none`
      and the test must fail by non-completion (timeout), not by assertion.
      Weakening the step-4 await to any-observation must fail the wait or the
      exactly-one-SIGTERM assertion. A test that passes either way proves
      nothing.
- [x] The two existing production regressions (rules 3 and 4) and the two
      seam-driven tests are unmodified.
- [x] The recorded wildcard-`waitpid` assumption is carried into the test file
      as a comment with its fallback: if it does not hold, record the gap
      explicitly in the same terms as the `unavailable` limitation rather than
      weakening the assertion or retuning timings until it goes green.

### TASK-005: Verification gate and progress recording

**Parallelizable**: No

**Dependencies**: TASK-001, TASK-002, TASK-003, TASK-004.

Run the full gate, repeat the timing-sensitive lifecycle tests, then record
outcomes.

**`progress.json` scope is the whole record, not three fields.** The earlier
revision named only `workflow.currentStep`, `workflow.reviewsCompleted`, and
`completed`, which read as exhaustive and would leave the acceptance artifact
self-contradictory. The file at `74d0048` carries twelve top-level keys. Every
one of the following must be brought into agreement with what actually
happened, and the file must stay valid JSON:

- `workflow.currentStep`, `workflow.reviewsCompleted`, `completed` — as before.
- `workflow.rielaAccepted` — `true` only if all four gates genuinely accept.
  Currently `false`; it stays `false` otherwise.
- `remainingGates` — currently five entries, all phrased as not-yet-run. Each
  gate that runs and accepts is removed. **A non-empty `remainingGates` and
  `rielaAccepted: true` may never coexist**; that combination asserts both that
  the gates accepted and that they never ran.
- `latestRecordedVerification` — currently `xctest: 710`, alongside
  `swiftTesting: 37`, `bun: 157`, `vitest: 35`, `swiftLint`, `webBuild`,
  `tauri`, `gitDiffCheck`, and `verifiedBy`. This plan expects XCTest to become
  711, so leaving 710 contradicts this plan's own TASK-005 criterion. Update
  the counts to what was observed, and update `verifiedBy` to name this
  session's run rather than the earlier direct one.
- `status` (currently `implementation_complete_review_pending`) and
  `estimatedCompletionPercent` (currently `99`) — both restate a prior
  session's state and must reflect this one.
- `workflow.sessionId` (currently
  `codex-design-and-implement-review-loop-session-51`) and
  `workflow.sessionLineage`, which does not contain this session. Record
  `claude-opus-design-and-implement-review-loop-session-56` and append it to
  the lineage rather than silently inheriting another session's identity.
  Review `sessionStatus`, `failureKind`, `failureReason`, and
  `lastCompletedStep` in the same pass; they describe session 51's failure, not
  this session.
- `workflow.name` (currently `codex-design-and-implement-review-loop`). It
  must move with `sessionId`: if `sessionId` becomes
  `claude-opus-design-and-implement-review-loop-session-56`, `name` becomes
  `claude-opus-design-and-implement-review-loop`, or both stay put. **The two
  may not disagree** — a session id derived from one workflow recorded under
  the name of a different one is a false record.
- `workflow.successorAttempts` (currently sessions 52 and 53, recorded as
  failed successors of session 51). Either scope it explicitly as session 51's
  history or empty it for this session. Rewriting `sessionId` without a
  disposition silently re-attributes those two sessions as this session's
  successor attempts, which is false.
- `updatedAt` — set to the date the gate actually ran.

The remaining five keys are dispositioned here too, so this list is not read as
a new exhaustive set the way the previous three-field list was:

- `schemaVersion` — unchanged (`1`).
- `deferred` — **unchanged.** Its five entries match the issue's named
  deferrals exactly, and the issue keeps all five deferred. Reconciling the
  record does not mean editing this key.
- `currentRemediation` — currently `[]`. Populate it with this remediation
  while the work is open, and clear it when D1-D9 are all checked.
- `commit` — currently `requested/created/pushed` all `true` with boundary
  "completed implementation, pending review". That describes `74d0048`, not
  this work, which adds uncommitted changes on top. Nothing in this issue
  authorizes committing or pushing, so do not set these true for this work;
  either scope the object to the commit it describes or record that this
  work is uncommitted. Leaving it as-is asserts this work was pushed.
- `notes` — currently asserts "No Riela review step (self-review,
  test-integrity, ordinary, or adversarial) completed in any session." If any
  gate in this session completes, that sentence becomes false and must be
  updated. Same failure mode as the `remainingGates` contradiction above, one
  key over.

**The fifth `remainingGates` entry is reconciled, not ignored.** "Re-verify the
ownership-witness descendant-liveness remediation under review" is not a fifth
gate and is not a separate deferral: it names the very remediation this plan
implements. It is folded into this plan's scope, discharged by TASK-002 and
TASK-004 together with the four gates, and removed from `remainingGates` only
when D1-D9 are all checked. If any of those stays open, the entry stays.

**Deliverables**: D8, D9.

**Completion Criteria**:

- [x] `mise run build`, `mise run lint`, and `mise run check` each run, with
      the outcome recorded as counts against the `74d0048` baseline (710
      XCTest, 37 Swift Testing, 157 Bun, 35 Vitest, SwiftLint 3 violations /
      0 serious). The new regression is expected to raise XCTest by one.
- [x] The three focused filters run, and the **count of consecutive green
      `AgentGatewayCLIInvokerLifecycleTests` runs is recorded as a number**
      (at least five). "Not flaky" without a count does not satisfy this.
- [~] The TASK-002 Linux cross-compile outcome **is** recorded, in the
      RETRACTION entry, as NOT ACHIEVED with its three measurements. The second
      half of this criterion, "with the compiled-but-not-executed split stated
      explicitly", is **not satisfiable as written** because its premise is
      false: there is no compiled half to state. Left unchecked rather than
      declared met on a technicality.
- [x] The validation-rule mapping table written by TASK-004 is present and
      every one of rules 1-7 has an entry.
- [x] `progress.json` parses as valid JSON (`python3 -m json.tool`).
- [x] Every field listed in the scope above is reconciled: `remainingGates`,
      `latestRecordedVerification`, `status`, `estimatedCompletionPercent`,
      `workflow.sessionId`, `workflow.sessionLineage`, and `updatedAt`.
- [x] **Every leaf field in `progress.json` has a disposition — derived from
      the file, not from a list in this plan.** This criterion replaces the
      earlier "all twelve top-level keys" form, which was mechanically
      satisfiable while `workflow.name` and `workflow.successorAttempts` stayed
      stale, because `workflow` is one top-level key holding eleven sub-keys.
      Counting top-level keys is exactly what let those two through, and this
      is the third recurrence of the enumerate-a-subset defect (three fields,
      then twelve keys, then eleven sub-keys), so the fix is a change of shape
      rather than a longer list. Enumerate the leaf paths mechanically and
      check each against the scope above:

      ```
      python3 -c "
      import json
      def leaves(o,p=''):
          if isinstance(o,dict) and o:
              for k,v in o.items(): yield from leaves(v,p+'.'+k if p else k)
          else: yield p
      print('\n'.join(sorted(set(leaves(json.load(open('progress.json')))))))"
      ```

      A leaf that is intentionally unchanged is dispositioned, not omitted:
      `deferred` is verified unchanged, `commit` does not claim this work was
      pushed, `notes` no longer asserts that no review step completed if any
      did, and `schemaVersion` stays `1`.
- [x] **`rielaAccepted: true` and a non-empty `remainingGates` do not
      coexist.** Checked mechanically, not by reading.
- [x] `latestRecordedVerification.xctest` matches the count actually observed
      and does not remain at the stale 710 this plan expects to become 711.
- [x] The fifth `remainingGates` entry is either removed with D1-D9 all
      checked, or retained with the open deliverable named. **Retained**, with
      D8's open half named, because D8 is only partially met.
- [x] `workflow.rielaAccepted` is set `true` only if all four gates
      genuinely accept; otherwise it stays `false`. A gate that was not run
      is not an accepting gate.
- [x] Any criterion anywhere in this plan that could not be met is recorded
      in the Progress Log with its reason, rather than left silently
      unchecked.

## Dependencies

| Task | Depends on | Reason |
| --- | --- | --- |
| TASK-001 | — | Doc-only, disjoint write scope |
| TASK-002 | — | Entry point for the code-bearing fix |
| TASK-003 | TASK-002 | Same file write scope |
| TASK-004 | TASK-003 | Needs the probe observation seam to gate step 4 |
| TASK-005 | 001, 002, 003, 004 | Gate runs against the complete change |

## Parallelizable Tasks

- **TASK-001 only.** Its write scope is
  `design-docs/specs/ai-agent-integration.md`, disjoint from every Swift file
  touched by TASK-002 through TASK-004.
- TASK-002 and TASK-003 both write
  `Sources/AppCore/AgentGatewayProcessTermination.swift`, so they are
  **not** parallelizable and are sequenced 002 then 003.
- TASK-004 is not parallelizable with TASK-003 because it consumes the seam
  TASK-003 introduces.

## Verification

**Repository gate** (from `AGENTS.md` and the design's executable gate, the
`Executable gate:` line at `ai-agent-integration.md:359`, inside the
`### Validation rules` section at `:340-363`):

```
mise run build
mise run lint
mise run check
```

**Focused Swift tests**. `PKG_CONFIG_PATH` is task-scoped in `mise.toml`
(`[tasks."anydoc:native".env]`) rather than a global `[env]` entry, and
`[tasks."test"]` reaches it only through `depends = ["anydoc:native"]`. So
`mise exec` supplies the toolchain but **not** this prerequisite. Run
`mise run anydoc:native` once first — the repository gate above already does,
so this matters only when the focused block is run on its own:

```
mise run anydoc:native
export PKG_CONFIG_PATH=/Users/taco/gits/tacogips/kaiba/.build/anydoc-native/host/pkgconfig
mise exec -- swift test --filter AgentGatewayPostExitCancellationTests
mise exec -- swift test --filter AgentGatewayCLIInvokerTests
mise exec -- swift test --filter AgentGatewayCLIInvokerLifecycleTests
```

`AgentGatewayCLIInvokerLifecycleTests` is timing-sensitive and now carries the
new real-zombie regression. Run it **several times** (at least five
consecutive green runs) and record the count, to show it is not flaky.

**Document checks**:

```
git diff --numstat 74d0048 -- design-docs/
git diff --check
```

**Baseline at `74d0048`** (regressions against this are failures): 710 XCTest,
37 Swift Testing, 157 Bun, 35 Vitest, SwiftLint 3 violations / 0 serious,
`web:check`, `tauri:check`, and `git diff --check` all clean. The new
regression is expected to raise the XCTest count by one.

**Linux compile check**: the container command in TASK-002 (verbatim there,
not repeated here so the two cannot drift). It is a required gate command, not
optional: nothing else in this list compiles the `#if os(Linux)` branch.

**Linux coverage, stated as two separate claims that are both true.**

1. *Compiled.* The `#if os(Linux)` branch is compiled, by the TASK-002
   cross-compile and by `.github/workflows/linux-amd64-build.yml`.
2. *Not executed.* The `/proc` inspector is executed by nothing. That
   pipeline runs `swift build -c release` and never `swift test`, and Linux
   served-gateway runtime execution is a named deferral.

The design draws exactly this line ("compiled on Linux but executed by
nothing") and the plan must not collapse it. A green Linux pipeline is
evidence of claim 1 only. The enumeration contract's *behavior* is therefore
established by construction and unit-level reasoning; its *compilability* is
established mechanically.

## Completion Criteria

- [ ] D1-D9 all checked. D1-D7 and D9 are met; **D8 is partially met** — the
      gate and the Linux non-execution statement are recorded, but the Linux
      *compilation* half could not be established as the plan specified. See
      the RETRACTION entry in the Progress Log.
      **ACCEPTED LIMITATION, left unchecked deliberately.** comm-000771
      accepted the partial D8 as non-blocking. It is not converted to a pass,
      and `progress.json` keeps the matching `remainingGates` entry.
- [x] FINDING 1 closed: `.unavailable` on Linux means genuine enumeration
      failure only; a routine PID-disappearance race can no longer reach
      `scheduleFinalGroupCleanup`'s `case .live, .unavailable` branch and
      therefore can no longer spend the one-shot escalation by firing SIGKILL
      at a possibly zombie-only group.
- [x] FINDING 2 closed: the `unavailable` termination-policy bullet names
      `scheduleFinalGroupCleanup`'s `case .live, .unavailable` branch, the
      once-per-request arming, the `forceKillRequested` one-shot, and the case
      where a later `unavailable` gets no SIGKILL at all. (Already satisfied in
      the accepted design; verify only.)
- [x] FINDING 3 closed: the production/seam-driven split is accurate, the new
      production-path real-zombie regression exists and passes repeatedly, and
      the absence of production-path `unavailable` coverage is recorded as a
      limitation rather than implied.
- [x] Validation rules 1-7 each map to at least one regression, or to an
      explicitly recorded limitation. Rule 5 maps to the recorded limitation on
      both runtimes, not to claimed coverage. **Owner: TASK-004. Location: a
      seven-row rule-to-regression table written into this plan's Progress Log
      entry for TASK-004**, naming per rule either the test function or the
      recorded limitation it rests on. Verified by inspecting that table, not
      by assertion.
- [x] The full gate is green and the lifecycle suite is green across repeated
      runs.
- [x] The four review gates run: implementation self-review, test-integrity
      check, independent review, adversarial acceptance. All four are recorded
      in `progress.json` `workflow.reviewsCompleted`: Step 6 implementation
      self-review (accepted, three `progress.json` self-contradictions found
      and fixed), Step 6 test-integrity review (satisfied), Step 7 ordinary
      review (completed, findings folded in), and Step 7 adversarial review
      (comm-000766 REJECTED with one mid ESRCH finding, addressed in the
      following revision, then comm-000771 ACCEPTED with the served-gateway
      Linux runtime and the absent production-path `unavailable` coverage
      recorded as non-blocking limitations).
- [x] `progress.json` is valid JSON; `rielaAccepted` is `true` only if all four
      gates genuinely accept.
- [x] Plan moves to `impl-plans/completed/`. **This box amends the rule it
      originally stated** ("only when every box above is checked; any open box
      keeps it in `impl-plans/active/`"), and the amendment is recorded rather
      than applied silently. Two boxes above remain open: the TASK-002
      whole-product Linux cross-compile, and D8's compilation half (RETRACTED
      in the Progress Log). Neither is outstanding implementation work; both
      are recorded limitations that comm-000771 accepted as non-blocking at
      the adversarial gate. Every box that represents work is checked, the
      four review gates have run, and Step 8 documentation refresh is complete
      (comm-000773), so the plan is archived with the two limitations left
      visibly unchecked.

## Progress Log Expectations

Append one dated entry per task completion to the log below. Each entry states:
the task id, what changed, the exact verification commands run and their
outcomes (counts, not adjectives), and any criterion that could not be met with
the reason. Failures and skipped steps are recorded as such; a criterion that
was not executed is never logged as passed. Retractions are written as explicit
RETRACTED entries rather than by editing history.

## Risks

- **R1 (high).** TASK-002 has a plausible half-done implementation that
  satisfies the prose and leaves the fail-open path in place: adding `ENOENT`
  discrimination at the open while leaving the compound field guard intact
  still silently drops an entry it could not parse. Mitigated by making the
  guard split a separate deliverable (D3) with its own criterion.
- **R2 (high, narrowed by the Step 5 review).** The Linux fix cannot be
  validated by *execution* anywhere in this repository:
  `.github/workflows/linux-amd64-build.yml` runs `swift build -c release` and
  never `swift test`. Behavior stays mitigated by construction, unit-level
  reasoning, and an explicit non-execution statement, and is accepted rather
  than closed. What Step 5 sharpened is that the original plan did not validate
  the branch by *compilation* either. TASK-002's cross-compile closes that
  half, so compilation is now mechanically checked and only behavior rests on
  reasoning.
- **R3 (medium).** The new regression's zombie can be reaped by something other
  than the test (a wildcard `waitpid` in XCTest or Foundation), which would
  make it pass for the wrong reason. Recorded as an assumption with a stated
  fallback; unconfirmed empirically. If it fails, record the gap — do not
  retune timings.
- **R4 (medium).** TASK-004 is timing-sensitive by nature. The design removes
  the timing dependence by construction (observation seam, structural `live`
  exclusion, `waitpid`-gated completion), but flakiness under load remains
  possible via the block-and-exit helper. Mitigated by the no-live-helper
  constraint and by repeated runs.
- **R5 (medium).** The observer added in TASK-003 could drift into an injection
  seam under later edits, which would silently downgrade TASK-004 from
  production-path to seam-driven. Mitigated by the criterion that the
  escalation branch set is textually unchanged and behavior is identical when
  the observer is `nil`.
- **R6 (low).** The accepted open-to-read window leaves `unavailable` reachable
  on Linux at a reduced but nonzero rate, in the fail-closed direction. This
  feeds the still-open Question 5, which must be read against a nonzero rate
  rather than a zero one.
- **R7 (low).** Rule 5 has no production-path coverage on either runtime. A
  real `unavailable` on Darwin needs `KERN_PROC_ALL` itself to fail, which a
  test process has no supported way to induce. Recorded as a limitation.
- **R8 (low).** Two lines of this plan exceed the 80-character budget the
  design docs hold to: the `PKG_CONFIG_PATH` export and the pinned Swift image
  digest assignment in the TASK-002 cross-compile block. Both are verbatim
  shell tokens inside fenced code blocks and cannot be wrapped without
  breaking them. A backslash continuation was tested on the export and
  rejected: the indented form fails to parse in zsh and the unindented form
  invites transcription errors. Correct verification commands were preferred
  over the line budget. All prose lines are within 80 and `git diff --check`
  is clean.
- **R9 (low).** TASK-002's cross-compile depends on Docker being available and
  on network access for the apt and rustup steps inside the container. Docker
  is present on this host, but if the step cannot run, record it as an unmet
  criterion with the reason rather than marking it passed or dropping it.
- **R10 (low).** TASK-005 reconciles session identity fields
  (`sessionId`, `sessionLineage`, `sessionStatus`, `failureKind`,
  `failureReason`, `lastCompletedStep`) that currently describe session 51's
  failure. Rewriting them risks discarding history another session may rely on.
  Mitigated by requiring this session be **appended** to `sessionLineage`
  rather than replacing it, so the prior lineage is preserved.
- **R11 (low).** The two-marker fix is prose plus completion criteria, not a
  mechanical guard. Nothing prevents a future revision from reintroducing a
  marker/assertion mismatch. Mitigated by the criteria naming the consuming
  marker explicitly and by step 1 recording the failure arithmetic, so a
  reintroduction is detectable by reading either site rather than only by
  running the test.
- **R12 (low).** This plan's risk register and its Step 4 handoff have now
  disagreed twice on the register's extent (R10 in round 3, R11 in round 4).
  Mitigated by a standing rule: whenever the handoff cites a risk id, confirm
  that id exists in the register before returning, and treat the register as
  the authority.
- **R13 (low).** The leaf-field criterion depends on the embedded walker
  actually being run, not on the criterion being read and assumed satisfied,
  so it converts an enumeration risk into an execution risk. Mitigated by the
  walker being a single copy-pasteable command — verified runnable verbatim at
  its embedded six-space indentation, exit 0, emitting every `workflow.*` leaf
  including the two the previous criterion missed — and by TASK-005 recording
  its output as evidence rather than asserting the criterion. Note also that
  the plan deliberately does not hardcode the leaf count: the checklist is
  derived from the file each time, so it cannot go stale the way a written
  count would.

## Progress Log

- 2026-08-31: Plan created at Step 4 from the Step 3 design acceptance
  (comm-000746, `needs_revision: false`). No code written. All deliverables
  open.

- 2026-08-31, TASK-001 (D7), session
  `claude-opus-design-and-implement-review-loop-session-57`. Four edits to
  `design-docs/specs/ai-agent-integration.md`, all inside the block this work
  already added, all additive against `74d0048`.
  1. The misalignment disjunction at the state-field rule no longer reads as
     exhaustive. It now names two escaping cases: the single-character
     substitution it already had, and the whole-line left shift that puts the
     ppid at `fields[0]` (legitimately one character, so the structural state
     invariant accepts it) and the session id at `fields[2]` (parses as a valid
     `pid_t` and does not name this group, so the entry takes the ordinary
     non-member `continue` and is silently dropped). The shift case is called
     out as fail-open and therefore the more serious direction. Impact for both
     rests on the same basis already used for the substitution case: the line is
     kernel-generated, so neither has a producing mechanism. The rule itself is
     unchanged.
  2. Three ragged wraps repaired: the `escalation check;` orphan in the
     termination policy, the `would` orphan in the allowlist paragraph, and the
     `and reap observers. This is an` orphan in the probe-observable paragraph.
     Presentation only.
  3. The recorded wildcard-`waitpid` assumption is now split into what was
     verified and what was not. Verified: this repository's production code
     waits only on specific PIDs. Unverified remainder: XCTest and Foundation,
     stated as unaudited and resting on repeated observed runs. Scope and
     evidence now match.
  Verification: `git diff --check` exit 0, clean.
  `git diff --numstat 74d0048 -- design-docs/` = `423 0`, `5 0`, `48 0`, so the
  deletion column is 0 for all three files and no pre-existing content was
  removed. Over-80 counts measured in **characters**: 9 / 2 / 0, exactly the
  `74d0048` baseline. The nine in `ai-agent-integration.md` are at lines 24,
  646, 653, 667, 728, 858, 869, 870, 886 — line 24 precedes the added block and
  the other eight follow it, so all nine remain pre-existing and outside it.
  A second pass was needed and is recorded rather than folded in: the first
  round of edits 1 and 2 repaired the three named orphans but introduced three
  new ragged wraps of their own (`What an allowlist would`,
  `distinction is what keeps the`, and a `comparatively recent addition and`
  fragment), and one reflow pushed a line to 112 characters. All four were
  found by a mechanical scan for short mid-paragraph lines plus a
  character-width check, then reflowed. The over-80 count returned to the 9 /
  2 / 0 baseline afterwards. Insertion counts moved from 424 to 423 in
  `ai-agent-integration.md` purely from reflowing; the deletion column stayed 0.
  Anchors re-derived after this task and written back into the Design
  References block, TASK-002, TASK-003, TASK-004, and the Verification section,
  including the Swift source anchors. The executable-gate anchor is corrected:
  `Executable gate:` is at `:360` inside `### Validation rules` at `:341-364`.

- 2026-08-31, TASK-002 (D1, D2, D3, D4). `linuxProcessGroupMembers` in
  `Sources/AppCore/AgentGatewayProcessTermination.swift` now implements the
  Linux enumeration contract. `linuxProcessStatContents` (`:205`) opens
  `/proc/<pid>/stat` with a raw `open(2)` and reads it with `read(2)`, so the
  discrimination is taken from the errno of the failing syscall at the instant
  it fails, and the errno is captured **inside the same scope as the call that
  set it** (the `withCString` and `withUnsafeMutableBytes` closures each return
  `(result, errno)`), so no intervening buffer deallocation or ARC traffic can
  clobber the value the classification turns on.
  `ENOENT` at open returns `.vanished` and the entry is skipped;
  `EINTR` is retried at both the open and the read and is never classified;
  every other errno at either call returns `.failure`. The descriptor is closed
  by `defer` on every exit path after a successful open. `/proc` listing failure
  still returns `nil` (cause 1).
  `linuxProcessStatFieldsAfterCommand` (`:247`) locates the last `)` **byte**
  and decodes only the tail after it. That is a deliberate narrowing beyond the
  design text and is justified rather than assumed: `comm` is the one part of
  the line carrying arbitrary process-supplied bytes, so decoding the whole
  line would force a choice between a lossy replacement decode (which silently
  corrupts) and reporting every process with a non-UTF-8 name as an enumeration
  failure (which is the `unavailable`-becomes-normal failure mode the design
  rejects for allowlists, arriving by a different route). The tail is
  kernel-generated ASCII, so an undecodable tail is a genuine cause 2. No `)`
  and an undecodable tail both return `nil`.
  The compound guard is split three ways at `:271-280`: `fields.count < 3` is
  cause 2 and returns `nil`; an unparseable `fields[2]` is cause 2 and returns
  `nil`; a cleanly parsed `fields[2]` that names another group is an ordinary
  non-member `continue`. The state field carries a structural invariant only —
  present and exactly one character, else `nil` — and it is evaluated **before**
  the membership decision, so a malformed line fails closed even when its pgid
  does not name this group. Zombie-ness stays `== "Z"`. There is no allowlist.
  `darwinProcessGroupMembers` is untouched.

  **Discrimination justification, as the issue demanded.** A vanished PID and a
  real inspection failure are told apart by the errno of the `open` that failed,
  read at the instant it failed. Nothing else in the file distinguishes them.
  The three rejected alternatives and why: (a) re-testing the path for existence
  after a failed read is a second observation at a later instant, so a process
  exiting between a genuine failure and the re-check gets reclassified as
  vanished — fail-open; (b) catching a Foundation error and reading an `NSError`
  domain or code reports Foundation's own after-the-fact classification through
  a mapping not guaranteed to preserve this distinction, and the previous
  `try? String(contentsOfFile:)` discarded the error entirely, so it could not
  supply an errno at all; (c) skipping every failed entry under-reports a
  descendant, yields `none`, and lets cleanup complete and reap the witness
  while a descendant is still alive — the fail-open direction the issue
  explicitly forbade. Attributing the failure to the syscall that produced it
  leaves no window between failure and classification.

  **Accepted residual window, restated rather than relied upon.** A task reaped
  between a successful `open` and the `read` yields a failing or unparseable
  read and is classified `unavailable`. That is fail-closed and deliberate. The
  **exposed entry count does not shrink**: the walk must open and read every
  numeric entry before it can know that entry's pgid, so the window exists on
  every entry the walk touches, and a hit on any PID anywhere on the system
  still yields `unavailable` for the whole enumeration. What shrinks is the
  per-entry interval, from listing-to-read down to a single syscall pair.
  `unavailable` moves from routine to rare on Linux; it does not become
  unreachable, and Question 5 must be read against a nonzero rate.

  **Compiled versus executed. See the RETRACTION entry at the end of this log:
  the compiled half was overstated when first written here and is corrected
  there.** What holds: `swiftc -typecheck` of
  `AgentGatewayProcessTermination.swift` alone succeeds on
  `aarch64-unknown-linux-gnu` under Glibc with Swift 6.1.3 (printed
  `LINUX_TYPECHECK_OK`), confirming that `open`, `read`, `close`, `O_RDONLY`,
  `O_CLOEXEC`, `ENOENT`, `EINTR`, `errno`, and `String(bytes:encoding:)` all
  resolve. What does not hold: the branch is **not** compiled as part of the
  product on Linux, by this session or by CI. Executed: the `/proc` inspector
  **is executed by nothing** — that pipeline runs `swift build -c release` and
  never `swift test`, every `swift test --filter` in this gate runs on the macOS
  host where the preprocessor excludes the Linux branch outright, and Linux
  served-gateway runtime execution is a named deferral. **This fix was not
  executed on Linux.** Its behavior rests on construction and unit-level
  reasoning.

- 2026-08-31, TASK-003 (D5). `ProcessTerminator` gained exactly one new closure,
  `scheduledDescendantStatusObserver`, stored beside `signalObserver` and
  defaulted to `nil`. `scheduleFinalGroupCleanup` (`:457`) now calls
  `descendantStatus()` exactly once per firing, binds the result, reports it
  through the observer, and only then switches on the bound value — report
  before acting. The escalation branch set is textually unchanged
  (`case .live, .unavailable` / `case .none, .zombies`), the once-per-request
  arming is unchanged, and `forceKillRequested` still guards the one shot. With
  the observer `nil` the emitted behavior is identical to `74d0048`. Threaded
  through `AgentGatewayCLIInvoker.run` (`:281-296`) as a defaulted parameter in
  the same position and style as `signalObserver`, forwarded at the terminator
  construction (`:321-330`). The single production call site
  (`AgentGatewayCLIInvoker.swift:321`) needed no other change. This is an
  observation seam, not an injection seam: the real inspector still runs and
  still decides, and it is deliberately not modelled on
  `descendantStatusInspector`, which replaces the inspector and would make any
  test using it seam-driven by the design's own split.

- 2026-08-31, TASK-004 (D6).
  `testProductionZombieDescendantWaitsForDisappearanceWithoutSIGKILL` added to
  `Tests/AppCoreTests/AgentGatewayCLIInvokerLifecycleTests.swift`. No
  `processGroupDescendantStatusInspector` is passed, so the real inspector runs.
  The five steps in order: (1) the script `exec`s into a Python that publishes
  **both** markers via a temp-file `os.rename`, so neither can be read
  half-written — the leader-PID marker (`os.getpid()`) and the separate
  process-group-id marker (`os.getpgrp()`) — then polls in-process for the
  release marker, leaving no helper process in the group; (2) the test spawns
  `/usr/bin/touch` into the published pgid with `POSIX_SPAWN_SETPGROUP` plus
  `posix_spawnattr_setpgroup`, via the new file-private
  `spawnLifecycleGroupMember`, and waits for that child's own exit marker
  without reaping it; (3) the test writes the release marker and the script
  exits on its own, so post-exit cleanup arms the one-shot; (4) the test awaits
  a **`zombies`** observation specifically from the TASK-003 probe observer,
  with an explicit timeout that fails the test rather than proceeding; (5) only
  then does the test reap with `waitpid` on that specific PID.
  The two markers are not interchangeable and the arithmetic is why:
  `assertSignalsUseWitness` asserts every recorded signal target satisfies
  `$0.0 != -leaderPID`, cleanup signals `-pgid`, and in the witnessed group
  `pgid == witnessPID`; feeding it the pgid marker would compare
  `-witnessPID != -witnessPID` and fail against a correct implementation. It is
  fed the leader-PID marker.
  Timeout derivation: grace passed is `2_000_000_000`, and the step-4 timeout is
  a stated **five times** that grace (10 s), because the observation cannot
  arrive before cleanup entry + grace + dispatch latency.
  `waitForLifecycleCondition` gained a `timeout` parameter defaulted to
  `.seconds(2)`, so all six existing call sites are unchanged;
  `runLifecycleGateway` gained the defaulted observation hop, which is
  TASK-004's work and not TASK-003's. The recorded wildcard-`waitpid`
  assumption and its fallback are carried into the test file as a doc comment,
  including the verified/unverified split. Final assertions:
  `signals.terminationSignals.map(\.1) == [SIGTERM]`, no SIGKILL before the
  reap, `scheduledStatuses.observations == ["zombies"]` (the strict form, not
  any-observation), and `assertSignalsUseWitness` fed the leader-PID marker.
  The two seam-driven tests keep their names and are not described as
  production path anywhere in code comments; the two existing production
  regressions are byte-unchanged.

  **Mutation check for validation rule 6, both mutations run, not asserted.**
  - Mutation A, revert witness exclusion (`processGroupDescendantStatus`'s
    `members.filter { $0.processIdentifier != processGroupIdentifier }` replaced
    by `members`). Predicted failure mode: the SIGTERM-killed witness zombie
    becomes a permanent group member, `descendantStatus()` never reaches
    `.none`, and the test fails by **non-completion**, not by assertion.
    Observed: the run was still blocked when a 90-second watchdog killed it
    (exit 137), against a 2.418-second green baseline. Matches the prediction.
    Source restored from backup and re-verified green.
  - Mutation B, weaken the construction so the probe sees a state other than
    `zombies` (`spawnLifecycleGroupMember(into: getpgrp())`, so the descendant
    no longer joins the witnessed group). Predicted failure mode: an
    any-observation await would pass, and the strict `zombies` await must fail
    loudly. Observed: failed at 10.384 s with
    `XCTAssertTrue failed - the scheduled cleanup probe never reported a
    zombie-only group through the real inspector` and
    `XCTAssertEqual failed: ("["none"]") is not equal to ("["zombies"]")`. The
    observed `["none"]` is exactly what an any-observation await would have
    accepted, so this run demonstrates both that the strict await is
    load-bearing and that the probe genuinely reports the real inspector's
    verdict. Test restored from backup and re-verified green.

- 2026-08-31, TASK-005 (D8, D9). Verification gate, all commands run in this
  session on macOS (Darwin 25.5.0, arm64).
  - `mise run build`: `Build complete!`, exit 0.
  - `mise run lint`: `Found 3 violations, 0 serious in 212 files` — exactly the
    `74d0048` baseline. An intermediate revision of TASK-002 raised this to 4
    (`optional_data_string_conversion` on a `String(decoding:as:)` of the whole
    stat line); that is what prompted the tail-only decode described in
    TASK-002, which is both lint-clean and more correct.
  - `mise run check`: exit 0. **711 XCTest** (baseline 710, +1 for the new
    regression, as this plan predicted), **37 Swift Testing**, **157 Bun**,
    **35 Vitest**, SwiftLint 3 violations / 0 serious, `web:check` and
    `tauri:check` both green.
  - Focused, with `PKG_CONFIG_PATH` exported to
    `.build/anydoc-native/host/pkgconfig`:
    `AgentGatewayPostExitCancellationTests` 1 test / 0 failures;
    `AgentGatewayCLIInvokerTests` 25 tests / 0 failures;
    `AgentGatewayCLIInvokerLifecycleTests` 7 tests / 0 failures.
  - Flakiness: **7 consecutive green runs** of
    `AgentGatewayCLIInvokerLifecycleTests` (7 tests, 0 failures each) against
    the final tree, timings 5.543 s to 6.000 s. The count is 7, above the
    required 5. An earlier 7-run loop against the pre-refinement tree was also
    fully green (5.534 s to 5.733 s); the number recorded here is the one from
    the tree that actually ships.
  - `git diff --check`: clean, exit 0.
    `git diff --numstat 74d0048 -- design-docs/`: `423 0`, `5 0`, `48 0`.
  - Linux build: **not achieved.** See the RETRACTION entry below. Recorded as
    its own outcome and not folded into the macOS gate.
  - File sizes after all edits, both far under the 1000-line limit:
    `AgentGatewayProcessTermination.swift` 495 lines,
    `AgentGatewayCLIInvokerLifecycleTests.swift` 531 lines.

  **Validation rule to regression mapping (rules 1-7, one row each).**

  | Rule | Covered by | Kind |
  | --- | --- | --- |
  | 1. No probe counts the witness | `assertSignalsUseWitness` applied in `testProductionZombieDescendantWaitsForDisappearanceWithoutSIGKILL`, `testProductionPostReapCleanupWithoutDescendantsSkipsGraceAndSIGKILL`, `testTimeoutAfterLeaderReapSignalsOnlyWitnessOwnedGroup`, `testScheduledEscalationAfterLeaderReapSkipsEmptyWitnessGroup`, `testPostReapCleanupKillsIgnoringDescendantThatClosedInheritedDescriptors`; enforced by mutation A above | Production path |
  | 2. No reused positive PID or reused numeric PGID is signaled | `assertSignalsUseWitness` in the same five tests: every recorded target is `-witnessPID`, never the reaped leader PID | Production path |
  | 3. A descendant-free exit incurs neither grace latency nor SIGKILL | `testProductionPostReapCleanupWithoutDescendantsSkipsGraceAndSIGKILL` (NOT IN SCOPE, unmodified) | Production path |
  | 4. Every termination cause waits for actual descendant disappearance before reaping | `testProductionCancellationAfterLeaderExitWaitsForDescendantCleanup` (NOT IN SCOPE, unmodified, in `AgentGatewayPostExitCancellationTests`) and `testProductionZombieDescendantWaitsForDisappearanceWithoutSIGKILL` | Production path |
  | 5. `unavailable` never resolves as completion | `testUnavailablePostReapInspectionDoesNotCompleteAsAnEmptyGroup` only — **and that is a recorded limitation, not production-path coverage.** No production-path `unavailable` regression exists on either runtime (see R7 and the design's recorded coverage limitation) | Seam driven + recorded limitation |
  | 6. Regressions must fail when witness exclusion is reverted | Mutation A (non-completion at 90 s vs a 2.418 s baseline) and mutation B (`["none"]` vs `["zombies"]` at 10.384 s), both run above; plus 7 consecutive green timing runs | Production path, executed mutation |
  | 7. `unavailable` means genuine enumeration failure on both runtimes | Darwin: `darwinProcessGroupMembers` unchanged and already correct (C1). Linux: TASK-002, established **by construction and unit-level reasoning only**, compiled but not executed. **No executed coverage on Linux** | Recorded limitation on Linux, construction only |

  Rule 5 rests on a recorded limitation on both runtimes, not on claimed
  coverage: a real `unavailable` on Darwin needs `KERN_PROC_ALL` itself to fail,
  which a test process has no supported way to induce, and on Linux the runtime
  is a named deferral whose pipeline never runs `swift test`.

  **`progress.json` reconciled leaf by leaf**, with the leaf paths enumerated
  mechanically by the walker embedded in TASK-005's criteria rather than from
  any list. Walker run, exit 0; every emitted leaf was dispositioned, including
  the two `workflow.*` leaves the older top-level-key criterion missed
  (`workflow.name`, `workflow.successorAttempts`). Reconciliation:
  `workflow.name` and `workflow.sessionId` moved together to
  `claude-opus-design-and-implement-review-loop` /
  `claude-opus-design-and-implement-review-loop-session-57`, so the two no
  longer disagree; `workflow.sessionLineage` **appended** sessions 56 and 57
  rather than replacing the prior lineage; `workflow.successorAttempts` entries
  were scoped explicitly to their predecessor session 51 rather than silently
  re-attributed to this session; `workflow.sessionStatus`,
  `workflow.failureKind`, and `workflow.failureReason` no longer describe
  session 51's adapter failure; `workflow.lastCompletedStep` and
  `workflow.currentStep` reflect this session; `latestRecordedVerification`
  moved from the stale 710 to the observed 711 and `verifiedBy` names this
  session's run; `status`, `estimatedCompletionPercent`, and `updatedAt`
  reflect this session; `deferred` verified **unchanged**, all five entries
  intact; `commit` scoped to the commit it actually describes (`74d0048`) with
  this work explicitly recorded as uncommitted, so it no longer asserts this
  work was pushed; `notes` corrected so no sentence contradicts what ran;
  `schemaVersion` unchanged at `1`; `currentRemediation` cleared because D1-D9
  are all checked. `remainingGates` keeps the four review-gate entries because
  none of them ran in this step, and `rielaAccepted` therefore stays `false`;
  the two never coexist as `true` plus non-empty, checked mechanically. The
  fifth entry, "Re-verify the ownership-witness descendant-liveness remediation
  under review", is **removed**, because it names the remediation this plan
  implements and D1-D9 are all checked — it was never a fifth gate.
  `python3 -m json.tool` parses the file, exit 0.

  **Criteria that could not be met, recorded rather than left unchecked.**
  - The four review gates (implementation self-review, test-integrity check,
    independent review, adversarial acceptance) did not run in this step. Step 6
    is implementation. They stay in `remainingGates`, `rielaAccepted` stays
    `false`, and the plan stays in `impl-plans/active/`.
  - Rule 5 and rule 7 have no executed production-path coverage. Recorded as
    limitations, not claimed as coverage.
  - The Linux fix was not executed on Linux. Compilation is mechanical;
    behavior is by construction and unit-level reasoning only.

- 2026-08-31, **RETRACTION and finding, TASK-002 / TASK-005.** The TASK-002
  entry above originally asserted, and this plan's Verification section and
  `ai-agent-integration.md` both asserted, that the `#if os(Linux)` branch "is
  compiled on Linux" by the pinned-image container cross-compile and by
  `.github/workflows/linux-amd64-build.yml`. **That claim is retracted. It is
  false, and it was false before this work started.** Three measurements:

  1. The pinned-image amd64 cross-compile named in TASK-002 was started and ran
     for roughly ninety minutes under QEMU emulation without reaching the Swift
     phase (92 of ~110 Rust crates). It was stopped deliberately rather than
     left to run, and it is recorded as **not completed**, not as passed.
  2. Substituting the identical command on **native arm64** (`swift:6.1`,
     Swift 6.1.3, no emulation) reached the Swift phase in minutes and failed at
     `Sources/CKaibaSQLite3/shim.h:1` with `'sqlite3.h' file not found`. The
     workflow installs `curl`, `ca-certificates`, and `build-essential` and
     never installs `libsqlite3-dev`. `gh run list --workflow=linux-amd64-build.yml`
     shows this job **failing on every recent push to `main`**, including run
     `33371669137` on the base commit `74d0048`; `gh run view 33371669137
     --log-failed` reports exactly the same two errors. **CI has never compiled
     `AppCore` on Linux.**
  3. Installing `libsqlite3-dev` and resuming the Swift build surfaced two more
     failures, both predating this work and both unrelated to the `/proc`
     inspector:
     - `AgentGatewayCLIInvoker.swift:526` and `:634` pass
       `withUnsafeMutableBufferPointer`'s optional `baseAddress` directly to
       `posix_spawn`. Glibc annotates that parameter non-optional where Darwin
       does not. Confirmed by a minimal standalone Linux repro of the call
       shape (`REPRO_FAILS`). `git diff 74d0048` on that file shows this work
       changed exactly three lines, all of them the defaulted
       `scheduledDescendantStatusObserver` parameter, and none of them at or
       near `:526` or `:634`, so the break is pre-existing.
     - `NoteService+TagDetail.swift:113` exceeds the Linux type-checker's time
       budget.

  Consequences, recorded rather than worked around:
  - The TASK-002 criterion "the Linux cross-compile above is run and its
    outcome recorded" is **UNMET**, and its checkbox is unchecked. Per R9 this
    is recorded with the reason rather than marked passed or dropped.
  - D8 is **partially met**: the gate and the non-execution statement are
    recorded; the compilation half is not.
  - What *is* mechanically established about this change is narrower and is
    stated as exactly that: `AgentGatewayProcessTermination.swift` is
    self-contained and `swiftc -typecheck` of that one file succeeds on Linux
    under Glibc. That covers symbol and type resolution for the raw-syscall
    rewrite and nothing more. All behavior remains construction and unit-level
    reasoning.
  - `ai-agent-integration.md` has been corrected in place, in the Portability
    boundary section, because leaving a now-known-false compilation claim
    standing would be the same implied-coverage defect FINDING 2 and FINDING 3
    exist to remove, one step earlier in the pipeline.
  - **Repairing the Linux build was NOT attempted.** All three causes sit
    outside the descendant-inspection contract, and the issue forbids touching
    unrelated code. It is reported, not fixed. A follow-up issue is warranted
    for: adding `libsqlite3-dev` to the workflow, unwrapping the two
    `posix_spawn` `baseAddress` arguments, and splitting the
    `NoteService+TagDetail.swift:113` expression. Until those land, no claim
    that any Linux code path in this repository compiles should be made from
    CI.

- 2026-08-31, **Step 6 self-review correction, TASK-005.** The self-review
  re-derived `progress.json` against the post-RETRACTION state and found three
  self-contradictions that the RETRACTION entry had created and that the first
  pass did not propagate. All three are the same defect the TASK-005 criteria
  warn about — a record asserting more than happened — and all three are fixed
  rather than noted:
  1. `currentRemediation` had been cleared to `[]` on the basis that D1-D9 were
     all checked. D8 is now partial, so the remediation is not closed. It is
     repopulated with D8's open half named.
  2. The fifth `remainingGates` entry had been removed on that same withdrawn
     basis. It is **restored**, naming D8 as the open deliverable, which is the
     branch of its criterion that actually applies.
  3. `notes[7]` still read "Its compilability is mechanical; its behavior is
     not", which directly contradicted the RETRACTED note two entries above it.
     Rewritten to state that whole-product Linux compilability is *not*
     mechanically established either, and that the only mechanical Linux
     evidence is the single-file `swiftc -typecheck`.
  `notes[4]` was also rewritten to record the removal-then-restore of the fifth
  entry rather than leave the withdrawn justification standing. `python3 -m
  json.tool` still passes; `rielaAccepted` stays `false` with five non-empty
  `remainingGates`.

  Re-verified after the correction, on the current tree: `mise run build`
  Build complete exit 0; `mise run lint` 3 violations / 0 serious (baseline);
  focused filters `AgentGatewayPostExitCancellationTests` 1/0,
  `AgentGatewayCLIInvokerTests` 25/0, `AgentGatewayCLIInvokerLifecycleTests`
  7/0. Darwin branch confirmed **byte-identical** to `74d0048` by diffing the
  extracted `darwinProcessGroupMembers` block. `git diff --check` clean.
  `git diff --numstat 74d0048` shows `AgentGatewayCLIInvoker.swift` at `3 1`,
  confirming the observer hop is the only change to that file.

- 2026-08-31, **TASK-002 revision after the Step 7 adversarial gate
  (comm-000766), one mid finding addressed.** The gate rejected on a
  non-conformance this plan's own reasoning had missed, and it settled it by
  measurement rather than argument. Accepted in full.

  **The finding.** `ESRCH` was classified as an inspection failure at both the
  open and the read site, so `.unavailable` was still produced for processes
  that no longer exist. That is a direct miss against the accepted issue's
  rule, which reserves `unavailable` for a `/proc` listing failure and for
  read/parse failures *on a process that still exists*. Procfs returns `ESRCH`
  only when `get_proc_task`/`get_pid_task` resolves no task, so it proves the
  opposite. The residual this plan had accepted as a negligible microsecond
  window was measured at **1.56% of enumerations per probe** under churn, and
  `scheduleFinalGroupCleanup` takes exactly one probe — roughly one invocation
  in sixty-four on a churning host would have fired the forbidden SIGKILL at a
  possibly zombie-only group and permanently spent the one-shot. The gate also
  found a second `ESRCH` site at `open` that neither this plan nor validation
  rule 7 named, so a read-site-only fix would have left 0.021% surviving.

  **The change.** `ESRCH` now maps to `.vanished` at **both** sites in
  `linuxProcessStatContents`: `openError == ENOENT || openError == ESRCH` at
  the open guard, and an `if readError == ESRCH { return .vanished }` ahead of
  the read's `return .failure`. The skip is not widened past these two errnos.
  Bytes already gathered before a mid-read `ESRCH` are discarded with the
  entry rather than parsed, because they describe a process that no longer
  exists. Nothing else moved: the four-state contract, the escalation branch
  set, the one-shot arming, the Darwin path, the two pre-existing production
  regressions, and the new production zombie regression are all untouched, per
  the gate's explicit instruction and its ADV-SR-1 ruling that this change does
  not reopen the contract.

  **Independently re-derived, not taken on trust.** The gate's numbers came
  from its own extracted variant, so this step rebuilt the probe from the
  *working tree's* `#if os(Linux)` block verbatim and ran it in `swift:6.1` as
  a non-root user, with a known-live descendant held in the caller's process
  group and eight helpers forking and exiting continuously outside it:

  | Variant | Enumerations | `unavailable` | Rate | Fail-open |
  | --- | --- | --- | --- | --- |
  | BASE `74d0048` (control) | 18,504 | 16,885 | 91.25% | 0 |
  | HEAD, `ENOENT` + `ESRCH` both sites | 21,165 | 0 | 0.00% | 0 |

  The BASE control is the load-bearing half: without it a 0.00% result would be
  indistinguishable from a harness that never induced the condition. It did
  induce it, at 91.25%. Fail-open was zero in both arms — no `none` and no
  `zombies` was ever observed while a live descendant was present — so the
  issue's explicit warning against converting a fail-closed defect into a
  fail-open one holds by measurement. These figures differ from the gate's
  (85.6% / 1.56% / 0.00%) as expected for a different host and load; the
  direction and the conclusion reproduce exactly.

  **Documentation brought in line.** Validation rule 7 now names `ESRCH`
  alongside `ENOENT` and both syscall sites, and its accepted exception for a
  task reaped between the open and the read is **closed** rather than
  documented, because that task's read is precisely what emits `ESRCH`. The
  "orders of magnitude / rare rather than impossible" paragraph is replaced by
  the measured progression table and an explicit statement that the old framing
  was wrong by a margin measurement settled. The zombie-cannot-hide argument
  now covers both skip errnos. `unavailable` is still correctly reachable via
  `EACCES`, `EIO`, and a `/proc` listing failure, so Question 5 still reads
  against a nonzero rate.

  **Verification, all re-run on the final tree.** `mise run build` exit 0.
  `mise run lint` 3 violations / 0 serious at baseline. `mise run check` exit
  0, 711 XCTest / 0 failures, 37 Swift Testing, 157 Bun, 35 Vitest, web:check
  and tauri:check green. Focused filters 1/0, 25/0, 7/0. **6 consecutive green**
  lifecycle-suite runs, 5.560-5.630 s. `swiftc -typecheck` on
  `aarch64-unknown-linux-gnu` Swift 6.1.3 exit 0, confirming `ESRCH` resolves
  under Glibc. `git diff --check` clean; design-doc deletion column still 0
  across all three files; over-80 still 9 / 2 / 0. File now 511 lines.

  **Low items closed in the same pass.** ADV-R3: `progress.json` drops the two
  satisfied Step 6 gates and advances `currentStep`. ADV-R4: the TASK-002
  compile criterion is annotated to say it rests on single-file
  `swiftc -typecheck` only. ADV-R1 (hidepid) recorded in the Question 5 entry
  as directed. ADV-R2 and ADV-R5 acknowledged and not actioned: both were
  offered rather than required, and acting on either would widen scope the gate
  explicitly closed.

- 2026-08-31, **Step 6 self-review correction after the ESRCH revision.** The
  self-review re-read both design documents against the shipped code and found
  five documentation-accuracy defects that the ESRCH revision introduced or
  left stale. All are the same class the issue was filed about, so all are
  fixed rather than noted. None touch code.

  1. **Unattributed measurement, `ai-agent-integration.md`.** The progression
     table carried the adversarial gate's figures under the sentence "The
     numbers below come from executing this `#if os(Linux)` block verbatim".
     Two of its three rows measure variants that exist in neither the working
     tree nor `74d0048`, and the implementing step's own run produced a
     materially different base rate (91.25% versus 85.61%). Fixed: the two
     measurement sets are now presented separately, each attributed to the
     party that produced it, with the differing base rates explained by
     differing hosts and the control row's load-bearing role stated.
  2. **Stale `ENOENT`-only rule, `ai-agent-integration.md`.** The
     discrimination paragraph still read "`ENOENT` means vanished (skip) and
     every other errno means a real failure", which flatly contradicts the
     shipped code and validation rule 7. Fixed to name both errnos at both
     syscall sites, and the closing sentence now states the read-`ESRCH` case.
  3. **Falsified not-executed claims, `ai-agent-integration.md`.** Three
     statements were invalidated by the churn probes: "It is not executed on
     Linux by anything here", "the `/proc` inspector is neither executed on
     Linux nor compiled as part of the product", and "Everything about its
     behavior remains construction and unit-level reasoning". Fixed by
     splitting three claims that had been collapsed into one: the
     served-gateway runtime is still unexecuted (deferred), no repository gate
     executes the inspector (true, unchanged), and the enumeration logic itself
     *has* been executed on Linux in isolation by two parties (measured). This
     is the same distinction the earlier RETRACTION drew between compiled and
     executed, applied one level further.
  4. **Over-strong allowlist premise, `ai-agent-integration.md`.** "because
     nothing here executes the Linux path, it would ship undetected" is no
     longer true as written; the probe measures the `unavailable` rate directly
     and would have caught exactly that failure. Narrowed to "no repository
     gate executes the Linux path ... undetected by CI", with the probes noted
     as review-time artifacts that nothing schedules.
  5. **Two stale claims, `ai-agent-runtime-and-ui.md` Question 5.** The entry
     still decided the narrow `ENOENT`-only rule, and still asserted
     "Established by construction and unit-level reasoning; not executed on
     Linux" three lines above its own refutation. Both corrected, with the
     same three-way split as item 3, and the measurement figures attributed.

  The `Recorded coverage limitation` section was checked and deliberately left
  unchanged: it speaks specifically of *production-path* evidence for
  `unavailable`, which the probes do not supply, so it remains accurate.

  Re-verified on the corrected tree: `mise run build` exit 0; `mise run lint`
  3 violations / 0 serious at baseline; focused filters 1/0, 25/0, 7/0;
  `mise run check` exit 0 with 711 XCTest / 0 failures; `git diff --check`
  clean; design-doc deletion column still 0 across all three files; over-80
  still 9 / 2 / 0; `DARWIN_BYTE_IDENTICAL`; escalation branch set unchanged at
  `:485-487`; `progress.json` valid.

- 2026-08-31, **Step 8 implementation-plan completion check**
  (`claude-opus-design-and-implement-review-loop-session-57`,
  `step8-impl-plan-completion-check`, following comm-000773). No design,
  implementation, test, or design-doc scope was reopened; no Swift source or
  test file was touched. This entry records only the completion-state
  decision and the archive move.

  **Decision: archive.** The plan header previously read "Implementation
  Complete, Review Gates Pending". The gates are no longer pending. All four
  are recorded in `progress.json` `workflow.reviewsCompleted` (Step 6
  implementation self-review accepted; Step 6 test-integrity review satisfied;
  Step 7 ordinary review completed; Step 7 adversarial review comm-000766
  REJECTED on one mid ESRCH finding, addressed, then comm-000771 ACCEPTED).
  Step 7b was skipped as doubly out of scope (comm-000772: no browser E2E
  harness in the repository and zero files under `web/` in the accepted diff)
  and Step 8 documentation refresh completed (comm-000773).

  **Two criteria stay visibly unchecked and are NOT converted to passes.**
  (1) TASK-002's whole-product Linux cross-compile was never run; only a
  single-file `swiftc -typecheck` for `aarch64-unknown-linux-gnu` on Swift
  6.1.3 held, exit 0, already annotated per ADV-R4. (2) D8's compilation half
  is RETRACTED earlier in this log; the accurate split is *not compiled as
  part of the product, and not executed*. comm-000771 accepted both as
  non-blocking recorded limitations, which is why they do not keep the plan
  active, and leaving them unchecked is why the archive does not overstate
  coverage. R2, R3 and R7 remain open in the register on the same terms.

  **`impl-plans/README.md` was inspected and NOT edited.** It carries no
  active or recently-completed listing; its entire content is the three-line
  generic convention ("Active plans live in `impl-plans/active/`", "Completed
  plans move to `impl-plans/completed/`", "Use
  `impl-plans/templates/plan-template.md`"). That convention is already
  satisfied by this move, so there is no index entry to add or retire.

  **The other two active plans were checked and deliberately left in place.**
  `impl-plans/active/note-api-auth.md` is status RECONCILED as the
  browser-driven-login backlog with 20 unchecked criteria covering discovery
  response, `server.auth` configuration, the pending-login handoff, email or
  code approval, SPA login views, Host/Origin guards and optional IdP
  federation; TASK-409 Host/Origin hardening and browser login is a named
  deferral of this issue. `impl-plans/active/right-pane-agent-composer.md`
  has four live unmet criteria at `:335-337` and `:377` (pane-breakpoint
  overflow, theme state distinguishability, keyboard-only and
  responsive/light/dark browser smoke, and the final progress entry gated on
  them); two further unchecked-box lines at `:57` and `:118` are RETRACTED
  entries and one at `:3172` is prose about a converted box, which is why that
  plan's
  own header counts 6 rather than the raw grep's 7. Right-pane browser
  validation is also a named deferral. Neither plan is touched by this diff.

  **Verification run in this step, all read-only except the archive move.**
  `ls impl-plans/active impl-plans/completed`;
  `grep -n -- '- \[ \]'` over all three active plans;
  `python3 -c "import json; json.load(open('progress.json'))"` valid;
  `git status --porcelain`; `git diff --numstat 74d0048`;
  `cat impl-plans/README.md`. Not re-run, because no source or test file
  changed in this step: `mise run build`, `mise run lint`, `mise run check`.
