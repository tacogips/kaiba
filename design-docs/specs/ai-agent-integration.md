# AI Agent Integration

## Status

Accepted

## Traceability

- Agent contract references:
  `Sources/AppCore/AgentInvoking.swift` and
  `Sources/AppCore/AgentGatewayCLIInvoker.swift`

## Summary

Kaiba gains three AI capabilities without depending on riela:

1. **Note-level agent chat** — ask an agent about a note or imported
   document; conversations persist as `agent-conversation` notebooks.
2. **Ontology tag auto-extraction** — AI proposes tags (with tag
   classes) for notes and notebooks, applied with provenance `ai`.
3. **A pluggable agent runtime seam** — `AgentInvoking` — whose concrete
   implementation is the extracted `tacogips/agent-gateway` CLI runtime.

A second runtime, the per-user personal agent with in-process kaiba tools,
is specified separately in `design-docs/specs/user-agent-tools.md`; it plugs
into the same `AgentInvoking` / `AgentStreamingInvoking` seams and the same
chat reply path, and the gateway adapter described here is unchanged by it.

Configuration, model invocation, persistence, dispatch wiring, CLI, GraphQL,
streaming progress, and web UI share the same runtime boundary. When that
runtime is absent or invalid, every surface retains a well-defined
`agent-unavailable` state.

## Runtime and Provider Adapter Boundary

The agent runtime was extracted from riela into `tacogips/agent-gateway`,
which now ships an ACP (Agent Client Protocol) stdio agent: `agent-gateway
client --vendor <v> --model <m> --system <s> --prompt -` runs one prompt
turn and emits ACP JSONL on stdout; the `session/prompt` response's
`_meta.agentGateway.resultText` carries the authoritative reply. Supported
vendors: claude-code, codex, cursor, openai, anthropic, gemini,
openrouter.

- Kaiba owns: the `AgentInvoking` protocol, the `ai` configuration
  schema, prompt construction, reply validation, persistence, dispatch,
  and every user-facing surface.
- agent-gateway owns: the runtime that actually talks to a model.
- Codex and Cursor remain provider choices behind the same
  `AgentGatewayCLIInvoker` ACP adapter. Kaiba does not launch either vendor
  CLI directly, add provider-specific composer behavior, or interpolate
  provider/model values into shell commands. This intentionally diverges
  from copying a Codex- or Cursor-specific client integration: the desktop
  capture informs composition only, while agent-gateway owns vendor
  differences and Kaiba owns validation, prompt construction, and persistence.
- The bridge is `AgentGatewayCLIInvoker: AgentInvoking`
  (`Sources/AppCore/AgentGatewayCLIInvoker.swift`): process spawn
  mirroring the anydoc pattern (zero SwiftPM dependencies), flattening
  turns + subject context into one prompt, preferring `resultText` over
  concatenated `agent_message_chunk`s, and surfacing JSON-RPC error
  responses as typed failures. `AgentInvokerFactory` constructs it when
  `ai.agent` names the `agent-gateway-cli` backend with a vendor and
  model and the binary resolves (`commandPath` else `PATH`).
  `AgentGatewayCLIModelCatalog` similarly delegates model discovery to
  `agent-gateway models`, without requiring a configured model.
  Served requests are stricter than local operator commands: `codex`,
  `claude-code`, and `cursor` are refused before launch, while permitted API
  vendors require an explicit credential-variable name and execute in a fresh
  temporary working directory with an allowlisted environment. On macOS the
  child also runs under a filesystem sandbox that permits writes only inside
  that directory, reads the exact configured gateway executable plus approved
  system runtime paths (never its parent directory), and permits outbound
  network access for the selected API provider. Gateway diagnostics from served
  requests are not returned or persisted because provider tools can include
  credentials or local paths in their errors. Availability preflight applies
  these served restrictions before auto-actions are enabled. The credential
  variable must be an ASCII environment-variable identifier and must not be a
  sandbox runtime key (`HOME`, `TMPDIR`, `XDG_CONFIG_HOME`,
  `XDG_CACHE_HOME`, `PATH`, `LANG`, or `LC_ALL`). Every served invocation
  failure, including a binary that disappears after preflight or workspace and
  process-start failure, is converted to a fixed diagnostic before durable AI
  workflow state can record it.
  When invocation requirements are not met, every AI surface reports
  the unavailable state with the specific
  reason, and `kaiba serve` force-disables the AI auto-actions so the
  outbox never accumulates.
- While serving with a runtime available, a maintenance tick recovers
  and retries pending dispatches every 30 seconds, so rows enqueued by
  other processes (e.g. `kaiba import` in another terminal) are drained
  without a restart.

## Process Lifecycle and Termination Boundary

Every gateway invocation owns one process group. Kaiba starts a distinct direct
child as the group leader and deliberately leaves it unreaped for the whole
invocation; that unreaped PID is the **ownership witness**. Because a numeric
process-group id cannot be recycled while its leader remains unreaped, the
witness is what makes group signaling safe. This section states the behavioral
contract; `Sources/AppCore/AgentGatewayProcessTermination.swift` implements it.

### Identity rules (what may be signaled)

- The witness is the only signal path. Termination signals a negative witness
  PID (whole group) and nothing else.
- The gateway leader's own PID is never signaled after `waitpid` has consumed
  it, because that number is immediately reusable by an unrelated process.
- A numeric process-group id is never signaled unless an unreaped witness pins
  it. Reaping the witness permanently and irreversibly disables every later
  group signal from that invocation.
- Reaping happens once, after cleanup has finished; it is the release of
  ownership, not a step within cleanup.
- A group signal necessarily reaches the witness itself, and the witness is a
  `/bin/sleep` placeholder spawned with SIGTERM at its default disposition, so
  the first group SIGTERM normally kills it. Ownership survives anyway: a dead
  but unreaped child is a zombie, and a zombie's PID stays reserved until it is
  reaped. The witness therefore does not need to stay alive, only unreaped.
  Making the witness survive signals would be a misreading of this contract.
- One deliberate exception to the policy below: if the gateway process cannot
  be spawned into the already-created group, the invocation aborts with an
  immediate group SIGKILL and a detached reap. No gateway ran, so there is no
  descendant to wait for and no grace period to honor.

### Group state (what a probe may conclude)

Group inspection excludes the witness itself, so an idle group does not look
occupied by its own owner, and liveness can genuinely fall to false while
polling. Inspection yields exactly four states:

- `none` — no descendants besides the witness.
- `live` — at least one non-zombie descendant.
- `zombies` — descendants remain, all of them zombies.
- `unavailable` — inspection failed. This is explicitly **not** an empty group.

Once the witness is reaped, inspection reports `none`: the invocation no longer
owns the group, so a late caller completes rather than blocking on processes it
can no longer observe or signal.

### Termination policy (what each state does)

- `none` — reap the witness and return. A descendant-free normal exit pays no
  grace latency and receives no SIGKILL. This is the common path and it must
  stay free on the production code path, not only under an injected seam.
  Post-exit cleanup that finds termination not yet requested does send one
  group SIGTERM on entry before its first probe, and schedules the one-shot
  escalation check; the claim is that a clean invocation costs no grace wait
  and no SIGKILL, not that it sends no signal at all.
- `live` past the grace deadline — escalate to SIGKILL once per terminator,
  then keep polling for disappearance.
- `zombies` — wait for disappearance without SIGKILL. Signaling a zombie
  accomplishes nothing; only reaping clears it.
- `unavailable` — fail closed. Never complete and never reap on an unreadable
  inspection; keep polling. Escalation here is conditional, not promised, and
  the two escalation paths do not agree. The in-loop SIGKILL branch matches
  `live` only, so the polling loop itself never escalates on `unavailable`.
  `scheduleFinalGroupCleanup` matches `case .live, .unavailable`, so the
  scheduled path does fire SIGKILL against an `unavailable` group while its
  single shot is unspent. That shot is armed once per termination request and
  its force-kill is guarded by `forceKillRequested`, so it fires at most one
  SIGKILL: an `unavailable` state first seen after that shot has been spent gets
  no SIGKILL at all and the wait continues indefinitely. Only the fail-closed
  half is settled design: never complete on an unreadable group. The unbounded
  wait is its consequence, and whether it should stay unbounded is open, not
  decided. See `design-docs/user-qa/ai-agent-runtime-and-ui.md`, Question 5.

Cancellation, deadline expiry, and output-limit termination are three entrances
to one loop with one exit condition: descendants have actually disappeared.
None of them may reap the witness on a timer or on a fixed post-SIGKILL delay,
because a delay proves nothing about whether descendants are gone.

### Portability boundary

Group membership and zombie state come from `sysctl KERN_PROC` on Darwin and
from `/proc/<pid>/stat` on Linux. Both must produce the same four states for the
same reasons. In particular they must agree on what produces `unavailable`,
because the termination policy above treats `unavailable` as abnormal.

- Darwin takes one `KERN_PROC_ALL` snapshot. A process vanishing mid-inspection
  is simply absent from that snapshot, so it yields `none`, `live`, or
  `zombies` as appropriate. `unavailable` arises only when the `sysctl`
  enumeration itself fails, and it arises on the *first* such failure: the
  sizing call failing, or the fetch call failing with any errno other than
  `ENOMEM`, yields `unavailable` immediately. The three-iteration loop around
  the pair is a bounded retry for the size-then-fetch race alone — `ENOMEM`
  means the process table grew between sizing and fetching — and is not a
  tolerance for three consecutive failures. On this runtime, `unavailable` is
  still rare and abnormal, because a failing `KERN_PROC_ALL` is.
- Linux lists `/proc` and then reads `/proc/<pid>/stat` per entry. A PID
  disappearing between the listing and its stat read is routine on any busy
  system and is not an enumeration failure, so it must not produce
  `unavailable`.

**Linux enumeration contract.** `unavailable` on Linux is reserved for exactly
two causes; a third case is a deliberate skip.

1. `/proc` itself cannot be listed — `unavailable`. Nothing was enumerated, so
   nothing may be concluded.
2. `/proc/<pid>/stat` exists but cannot be read, or its contents cannot be
   parsed into the state and process-group fields — `unavailable`. This is a
   real inspection failure on a process that still exists, so the enumeration
   is incomplete and must be reported as incomplete.
3. `/proc/<pid>/stat` no longer exists — the PID vanished between the listing
   and the read. Skip that entry and continue. The enumeration is complete
   without it, because a process that no longer exists is not a descendant.

Cause 2 is not satisfied by errno handling alone, and this is the easiest part
of the contract to leave half-done. The existing field guard is compound: it
tests that the stat line has enough fields *and* that the parsed pgid matches,
and sends both outcomes to the same `continue`. Those two outcomes have opposite
safety directions and must be split. An unparseable pgid field is cause 2 and
fails closed; a pgid that parses cleanly and simply does not name this process
group is an ordinary non-member skip. Without that split, an implementation that
adds `ENOENT` discrimination at the open satisfies the letter of causes 1
through 3 and still silently drops an entry it could not parse, which is the
fail-open direction the next paragraph forbids.

The state field needs a rule of its own, because today it has no failure mode at
all: zombie-ness is decided by a bare equality test against `"Z"`, which cannot
fail to parse, so a clause about an unparseable state field reads as already
satisfied and would be skipped. The rule is **structural, not an allowlist**.
The state field must be present and exactly one character; a missing, empty, or
multi-character state token is cause 2 and fails closed; zombie-ness remains the
`== "Z"` test.

Validating the token against an enumerated set of known process states would
be the wrong rule, and wrong in the dangerous direction. The state and the
pgid are split from the same substring of the same line, so a misalignment of
that line shifts both tokens together: the pgid rule above fails closed on it,
or the state token stops being a single character and this rule does. That
disjunction reads as exhaustive and is not. Two narrow cases escape both
branches, and both are named rather than papered over.

The first is a substitution: a state token corrupted to a single wrong
character on a line whose pgid still parses and still matches would misclassify
a zombie as live. The second is a whole-line shift that both rules happen to
accept. A line shifted left by one field puts the ppid at `fields[0]`, which
can legitimately be a single character and so satisfies the structural state
invariant, and puts the session id at `fields[2]`, which parses as a valid
`pid_t` and simply does not name this process group. The entry then takes the
ordinary non-member `continue` and is silently dropped. That is a fail-open
under-report rather than a fail-closed outcome, so it is the more serious
direction of the two.

Impact stays low for both on the same basis, and that basis is why neither
changes the rule: there is no channel that produces either one. The line is
kernel-generated, not parsed from an external source, so neither a
single-character substitution nor a field shift has a producing mechanism. An
allowlist would not be the right answer to either, for the reason that follows.
What an allowlist would actually catch is the opposite case: a single
well-formed character the kernel emitted and the list does not happen to name.
The set is open-ended in practice — `I` for idle kernel threads is a
comparatively recent addition and many kernel threads sit in it at any instant
— so a list assembled from an older reference would make cause 2 fire on
essentially every enumeration, turn `unavailable` into the normal result on
Linux, and hang every invocation on the unbounded fail-closed wait. That is
strictly worse than the transient-`unavailable` defect this contract exists to
remove, and because no repository gate executes the Linux path, it would ship
undetected by CI. The probes described below would in fact have caught it, by
measuring the `unavailable` rate directly, but they are review-time artifacts
rather than gates and nothing schedules them. The structural invariant gets the
real guarantee the kernel offers without opening that failure mode.

The discrimination is made from the errno of the failing syscall, read at the
instant that syscall fails, and it is made at **both** the open and the read:
`ENOENT` and `ESRCH` mean vanished (skip), and every other errno means a real
failure (`unavailable`). It is deliberately **not** made by re-testing the path
for existence after a failed read. A re-check is a second
observation taken at a later instant, and a process that exits between a
genuine read failure and that re-check would be reclassified as vanished, which
is the fail-open direction. Attributing a failure to the syscall that produced
it leaves no window between the failure and its classification. A read
interrupted by `EINTR` is retried rather than classified; a read that fails
with `ESRCH` is a vanished PID, because the task was reaped between the open
and the read; and a successful open followed by content that yields no
parseable line is cause 2, not a vanished PID.

This has a mechanical consequence that the contract is not satisfiable without.
The stat read is currently a Foundation convenience read whose error is
discarded outright, so it cannot supply an errno to discriminate on — no
rearrangement of the surrounding logic changes that. The read must become a
syscall-level open and read that surfaces `errno` directly. Catching the
Foundation error and inspecting an `NSError` domain or code is not the same
observation: it reports how Foundation classified a failure after the fact,
through a mapping that is not guaranteed to preserve the distinction the
contract turns on. Reserve the judgement for the errno set by the failing
syscall itself.

An earlier revision of this section accepted a residual window rather than
closing it: a task reaped between the successful open and the read would fail
that read, and cause 2 would classify the vanished PID as `unavailable`. The
reasoning offered was that the window had shrunk from listing-to-read down to a
single syscall pair, collapsing the hit probability "by orders of magnitude"
and moving `unavailable` from the routine case to the rare case.

**That framing was wrong, and it was wrong by a margin that measurement rather
than argument settled.** The window is not microseconds of exposure on a
syscall pair; it is an ordinary event on a busy host, and it produces a
specific errno that identifies it exactly.

Two parties measured it independently, on different hosts, and the provenance
of each figure is given rather than merged, because the absolute rates differ
and a single unattributed table would misrepresent both. In both cases the
method was the same: compile the relevant `#if os(Linux)` block into a Linux
binary, run it in a container as a non-root user, hold a known-live descendant
in the caller's process group, and churn unrelated short-lived PIDs outside it.
Note that only the last row of each set is the code as it now stands; the
`Base` row is `74d0048`'s block and the `ENOENT`-only row is an intermediate
variant that exists in neither commit.

Measured by the adversarial review gate:

| Variant | Enumerations | `unavailable` | Rate | Fail-open |
| --- | --- | --- | --- | --- |
| Base (pre-fix, any failure is cause 2) | 11,620 | 9,948 | 85.61% | 0 |
| `ENOENT`-only skip | 16,673 | 260 | 1.56% | 0 |
| `ENOENT` + `ESRCH` at both sites | 14,455 | 0 | 0.00% | 0 |

That gate's second run reproduced 85.75% / 1.48% / 0.00%. Its 260 residual hits
in the middle row decompose as 257 `ESRCH` at the read and 3 `ESRCH` at the
open, so honoring `ESRCH` at the read site alone would have left the three
open-site events and the rule still unmet. Both sites are therefore covered.

Confirmed independently by the implementing step, which rebuilt the probe from
the working tree's own block rather than reusing the gate's variant:

| Variant | Enumerations | `unavailable` | Rate | Fail-open |
| --- | --- | --- | --- | --- |
| Base `74d0048` (control) | 18,504 | 16,885 | 91.25% | 0 |
| `ENOENT` + `ESRCH` at both sites (shipped) | 21,165 | 0 | 0.00% | 0 |

The absolute base rates differ (85.61% versus 91.25%) because the two runs sat
on different hosts under different load; the direction, the zero-fail-open
result, and the 0.00% outcome for the shipped code reproduce exactly. The
control row is the load-bearing half of the second set: without a pre-fix arm
measured on the same host under the same churn, a 0.00% result would be
indistinguishable from a harness that never induced the condition. It induced
it at 91.25%.

Two things follow. First, the accepted exception is **closed** rather than
documented: `ESRCH` is exactly the signal a reaped-mid-read task emits, so the
case that motivated the exception is now identified in band and skipped, not
guessed at by a later-instant re-check. Second, a 1.56% per-probe rate was
never compatible with this contract's own premises —
`scheduleFinalGroupCleanup` takes exactly one probe, so roughly one invocation
in sixty-four on a churning host would have fired the forbidden SIGKILL at a
possibly zombie-only group and permanently spent the one-shot. That is the
routine transient the whole section exists to eliminate, surviving at a rate
the prose had called rare.

What remains true from the old paragraph is the structural part, and it is
worth keeping. The walk must open and read every numeric entry's stat before it
can know that entry's pgid, so every entry the walk touches is exposed, and a
single hit anywhere on the system still yields `unavailable` for the whole
enumeration. The exposed entry count does not shrink. What changed is that the
two errnos which actually fire on that exposure are now classified as the
vanishes they are. `unavailable` is not thereby proven unreachable — a genuine
`EACCES`, `EIO`, or `/proc` listing failure still produces it, correctly — so
the still-open Question 5 unbounded-wait decision must continue to be read
against a nonzero rate. It must now be read against a rate that measured zero
under churn, rather than against 1.56%.

Across all three variants and roughly 42,000 enumerations, the fail-open count
was **zero**: no `none` and no `zombies` was ever observed while a live
descendant was present. The issue's explicit warning against converting a
fail-closed defect into a fail-open one is therefore satisfied by measurement,
not only by construction.

Two consequences are worth stating because they are easy to get backwards.

- Skipping every failed entry unconditionally is forbidden. Under-reporting a
  descendant yields `none`, and `none` lets cleanup complete and reap the
  witness while a descendant is still alive and the numeric PGID becomes
  recyclable. That converts a fail-closed defect into a fail-open one, which is
  strictly worse than the defect it replaces.
- A zombie keeps its `/proc/<pid>/stat` entry until it is reaped, so the skip
  rule cannot hide a zombie behind either skip errno. `ENOENT` means the
  `/proc/<pid>` directory is already gone. `ESRCH` means the directory survives
  but procfs cannot resolve it to a task, because the kernel's
  `get_proc_task`/`get_pid_task` lookup found nothing. Both mean reaped and
  gone, which is precisely not a descendant, so neither can conceal one.

Under this contract `unavailable` means genuine enumeration failure on both
runtimes, and the per-state policy above — written on the Darwin premise — is
sound on Linux as well. A routine PID-disappearance race no longer reaches
`scheduleFinalGroupCleanup`'s `case .live, .unavailable` branch, so it can no
longer spend the one-shot escalation by firing SIGKILL at a group that may be
zombie-only, which the `zombies` bullet forbids.

**No repository gate executes the `/proc` inspector.** Linux served-gateway
runtime execution is a named deferral, and
`.github/workflows/linux-amd64-build.yml` runs `swift build -c release` only
and never `swift test`, so no CI job and no `swift test --filter` in the
executable gate ever reaches this code.

That is a statement about the repository's gates, and it must not be widened
into a claim that the enumeration logic has never run on Linux, because it has.
The measurements in the preceding section come from compiling this block into a
standalone probe binary and executing it under deliberate PID churn in a Linux
container. Three claims are therefore distinct and only the first two are
limitations:

1. The **served-gateway runtime** has not been executed on Linux. Deferred.
2. No **repository gate** executes the inspector. True, and unchanged by the
   probes, whose evidence lives in the review record rather than in CI.
3. The **enumeration logic itself** has been executed on Linux, in isolation,
   by two independent parties under churn. Its fail-open behavior and its
   `unavailable` rate are measured, not reasoned.

An earlier revision of this section collapsed the third into the first two and
said the contract "can only be established by construction and by unit-level
reasoning". That was true when written and is no longer true. What still rests
on construction rather than measurement is narrower: the behavior of the
`zombies` and `none` classifications on a *real gateway process group* on
Linux, which only the deferred runtime would exercise.

An earlier revision of this section said the inspector "is compiled on Linux
but executed by nothing", and that overstated the compiled half. It is
corrected here rather than left standing, because a false compilation claim is
the same implied-coverage defect this section exists to remove, one step
earlier in the pipeline. Two facts were measured and neither supports it.

- The Linux pipeline is **red, not green**, and has been on every recent push
  to `main` including the commit this work is based on. It fails before any
  Swift source is compiled, at `Sources/CKaibaSQLite3/shim.h` with
  `'sqlite3.h' file not found`: the workflow installs `curl`,
  `ca-certificates`, and `build-essential` and never installs
  `libsqlite3-dev`. So CI has never compiled `AppCore` on Linux at all.
- Forcing the build past that gap locally, in a `swift:6.1` Linux container
  with `libsqlite3-dev` installed, `AppCore` still does not compile on Linux
  for two reasons that predate this work and are unrelated to the `/proc`
  inspector. `AgentGatewayCLIInvoker.swift` passes
  `withUnsafeMutableBufferPointer`'s optional `baseAddress` straight to
  `posix_spawn` in both spawn paths; Glibc annotates that parameter
  non-optional where Darwin does not, so Linux rejects it and macOS accepts
  it. Separately, `NoteService+TagDetail.swift` exceeds the type-checker's
  time budget on Linux.

The accurate statement is therefore that the `/proc` inspector is **not
compiled as part of the product on Linux**, by CI or by anything else. What is
mechanically established is narrower and is stated as such:
`AgentGatewayProcessTermination.swift` is self-contained, `swiftc -typecheck`
of that file alone succeeds under Glibc on `aarch64-unknown-linux-gnu` with
Swift 6.1.3, and the `#if os(Linux)` block compiles under `swiftc -O` and runs
as a probe binary on that same platform. A Linux pipeline is not evidence that
the two inspectors agree, and this one is not evidence of anything at all until
it goes green.

Repairing the Linux build is out of scope for the work that found this: both
causes sit outside the descendant-inspection contract, and one of them is in a
file this work touches only to thread a defaulted observer parameter. The
finding is recorded here so the next reader does not inherit the corrected
claim's predecessor.

### Validation rules

1. No probe counts the witness, in either liveness or completion.
2. No path signals a reused positive PID or a reused numeric PGID.
3. A descendant-free exit incurs neither grace latency nor SIGKILL.
4. Every termination cause waits for actual descendant disappearance before
   reaping.
5. `unavailable` never resolves as completion.
6. The regressions covering these rules must fail when witness exclusion is
   reverted; a test that passes either way proves nothing. Timing assertions
   must hold across repeated runs, and an injected inspector seam must not be
   the only thing exercising a rule that production also has to satisfy.
7. `unavailable` means genuine enumeration failure on both runtimes. A PID
   observably vanished — `ENOENT` **or `ESRCH`**, at **either** the open or the
   read — is not an enumeration failure and must not produce it; an entry that
   cannot be inspected while the process still exists must. This rule previously
   carried an accepted exception for a task reaped between the open and the
   read. **That exception is now closed**, not merely documented: the reaped
   task's read fails with `ESRCH`, which is honored as a vanish rather than a
   failure. Both errnos are honored at both syscall sites, because covering only
   the read site leaves the open site producing `ESRCH` and the rule unmet. The
   skip is not widened past these two errnos.

Executable gate:
`mise run build`, `mise run lint`, `mise run check`, and, with
`PKG_CONFIG_PATH` set to `.build/anydoc-native/host/pkgconfig`,
`mise exec -- swift test --filter` for `AgentGatewayPostExitCancellationTests`,
`AgentGatewayCLIInvokerTests`, and `AgentGatewayCLIInvokerLifecycleTests`.

### Named regressions, split by what actually executes

**Production path.** The real inspector runs — `sysctl KERN_PROC` on Darwin,
the `/proc` walk on Linux — with no `descendantStatusInspector` injection:

- `testProductionPostReapCleanupWithoutDescendantsSkipsGraceAndSIGKILL` —
  rule 3.
- `testProductionCancellationAfterLeaderExitWaitsForDescendantCleanup` —
  rule 4.
- `testProductionZombieDescendantWaitsForDisappearanceWithoutSIGKILL` (new) —
  the `zombies` policy bullet, against a real zombie, and rule 6.

**Seam driven.** These pass a `processGroupDescendantStatusInspector` closure,
which `ProcessGroupWitness.descendantStatus()` takes in preference to the real
inspector through its `descendantStatusInspector` branch. Neither
`sysctl KERN_PROC` nor the `/proc` walk executes, so no real zombie and no real
inspection failure is ever produced. They exercise the termination policy's
reaction to a state, not the inspector's ability to arrive at that state, and
must not be presented as production-path coverage:

- `testZombieOnlyPostReapGroupWaitsForDisappearanceWithoutSIGKILL`
- `testUnavailablePostReapInspectionDoesNotCompleteAsAnEmptyGroup`

### Real-zombie production regression (required shape)

Both assertions this regression makes — that cleanup waits, and that it never
escalates — must be structural. A zombie that appears only after cleanup could
already have completed proves nothing, and a no-SIGKILL assertion that holds
because a grace period happened to be long enough proves nothing either.
Validation rule 6 forbids resting on the second kind of claim, so the shape is
built to exclude the failing states by construction rather than to outrun them.

The zombie's parent must be the test process itself: a zombie whose parent exits
is reparented to `init`/`launchd` and reaped away, so the gateway script cannot
hold one, and a still-living in-group parent would make the group `live` rather
than `zombies`.

The ordering runs through the post-exit path, not through a termination request
issued while the gateway is still running:

1. The gateway script publishes the process-group id it is running in, then
blocks on a marker. The witnessed group is identified while the invocation is
still live. 2. The test spawns a child directly into that process group, waits
for that child's own exit marker, and does not reap it. The spawn mechanism
must do two things a convenience process API does not: place the child into an
already-created process group it did not create, and leave the child unreaped
by anything except the test's own step 5. The group now holds one real zombie
descendant; the witness stays excluded from inspection under rule 1. 3. The
test writes the marker and the script exits on its own. Post-exit cleanup then
runs and arms the one-shot escalation. 4. Cleanup must observe `zombies`
through the real inspector, must not complete, and must not emit SIGKILL. The
scheduled probe must additionally be *observed* to have evaluated `zombies`,
through the probe observer described below. The test waits for that
observation; it does not infer it from elapsed time. 5. Only after that
observation arrives does the test reap the zombie. Only then may inspection
fall to `none` and cleanup complete, and the recorded termination signals must
be exactly one SIGTERM.

**Why the no-SIGKILL assertion is structural here.** `scheduleFinalGroupCleanup`
escalates on two states, not one: it matches `case .live, .unavailable`. Each is
excluded, but not by the same kind of argument, and the difference matters.

`live` is excluded structurally. The only descendant that could be live is the
gateway leader, and the post-exit ordering removes it before the escalation is
armed: the invoker awaits the spawned process's completion before it calls
`terminateRemainingProcessGroup`, and that completion is published only after
`waitpid` has already marked the leader reaped. By the time the escalation is
armed the leader is gone, the injected zombie is the only descendant, and the
group is zombie-only from the first probe onward. `scheduleFinalGroupCleanup`
takes its `case .none, .zombies` no-op branch no matter how the grace is sized,
so this half of the assertion does not depend on any grace value being large
enough. This is the same post-exit shape the two existing production regressions
and the seam-driven helper already use.

`unavailable` is not excluded structurally, and the shape should not pretend
otherwise. On Darwin it requires the `KERN_PROC_ALL` enumeration itself to fail,
which the recorded limitation below already states cannot be induced on demand —
the same fact that makes a production-path `unavailable` regression unachievable
is what keeps it out of this one. If it did occur, the escalation would fire and
the regression would fail loudly on its exactly-one-SIGTERM assertion rather
than pass for the wrong reason, which is the correct direction for an
unmodelled event.

**The scheduled probe needs an observable, and this is why.** The scheduled
probe is the one state evaluation in this contract whose outcome leaves no
trace, direct or indirect. Its `case .none, .zombies` arm emits nothing, no
existing observation seam fires on it, and unlike the in-loop wait it has no
indirect tell either: the loop's continued blocking shows that cleanup has not
completed, but nothing shows which state the scheduled probe saw. So `none`
and `zombies` are indistinguishable from outside, and a regression asserting
the scheduled path behaved correctly against a zombie-only group cannot tell
whether it produced that state or merely missed it.

Timing cannot close that gap, and it is worth stating why, because a grace value
looks like it should. The scheduled probe is dispatched asynchronously at
`entry + grace`; the grace bounds when the probe is *scheduled*, not when it
*runs*. The real evaluation happens at `entry + grace + delta`, where delta is
queue-dispatch latency that no grace value controls and that grows on a loaded
host. The test's own reap has no lower bound either. So the probe can land
after the reap, `descendantStatus()` short-circuits to `none` once the witness
is reaped, the `none` arm evaluates, and the exactly-one-SIGTERM assertion
still passes. The regression would then report scheduled-path coverage against
a zombie-only group without ever having produced one, which is the
implied-coverage defect this whole section exists to remove. Shrinking the
grace improves the odds and nothing more; no value converts the race into a
construction.

The requirement is therefore an observable, not a timing.
`scheduleFinalGroupCleanup` reports the descendant status it evaluated, before
acting on it, through an observer in the same family as the existing signal and
reap observers. This is an *observation* seam, not an injection seam, and the
distinction is what keeps the regression production-path under this document's
own split: the real inspector still runs and still decides, the observer only
reports what it decided. Nothing about the escalation policy changes. With it,
step 4's requirement is checkable rather than assertable, step 5 is gated on the
observation rather than on a delay, and coverage is independent of both the
grace and the dispatch latency.
No grace value is mandated anywhere in this shape.

One constraint on the block-and-exit mechanism follows from the same reasoning.
Whatever the script uses to wait for the marker must not leave a live helper
process in the group when it exits: a helper that outlives the script is
reparented but keeps its process-group id, so it would present as a live
descendant and reintroduce exactly the `live` state the ordering exists to
exclude.

Step 5 is what makes completion a proof: it is gated on an actual `waitpid`
performed by the test, not on elapsed time. Step 2 completing before step 3 is
what keeps the wait assertion honest, because the zombie is in place before
cleanup can start rather than racing it.

**Recorded assumption and fallback.** The shape depends on nothing else in the
test process performing a wildcard `waitpid` that would reap the raw spawned
child before the test does. The evidence does not cover that whole scope, so
the two are stated separately rather than merged. Verified: this repository's
production code waits only on specific PIDs, never on `-1`, in both places it
waits at all. Unverified remainder: the test process also links XCTest and
Foundation, whose reaping behavior was not audited here, so the assumption over
them rests on repeated observed runs rather than on inspection. It is recorded
as an assumption rather than left as an unstated premise because the whole proof
collapses if it fails: the zombie would disappear on someone else's schedule
and the regression would pass for the wrong reason. If it does not hold, the
resolution is to record the gap explicitly, in the same terms as the
`unavailable` limitation below, rather than to weaken the assertion or to retune
timings until it goes green.

### Recorded coverage limitation: no production-path `unavailable`

Rule 5 is covered by the seam-driven
`testUnavailablePostReapInspectionDoesNotCompleteAsAnEmptyGroup` and by nothing
else, and that is a gap rather than coverage. A real `unavailable` on Darwin
requires `KERN_PROC_ALL` itself to fail, and a test process has no supported way
to make a global read-only `sysctl` fail on demand — the difficulty is inducing
one failure, not three. On Linux it requires a `/proc` listing failure or an
existing-but-unreadable stat file, and the Linux runtime is a named deferral
whose pipeline never runs `swift test`. There is therefore no production-path
evidence that the real inspector ever returns `unavailable` — only that the
policy reacts correctly when something says it does. Recorded as a limitation,
not claimed as coverage.

## Design Decisions

- **AI1 — `AgentInvoking` protocol seam.**

  ```swift
  public protocol AgentInvoking: Sendable {
    func invoke(_ request: AgentInvocationRequest) async throws
      -> AgentInvocationResult
  }
  ```

  `AgentInvocationRequest` = purpose (`chat` | `tagExtraction` |
  `translation` | `search`) + system prompt + prior turns + optional
  subject context markdown + optional provider/model.
  `AgentInvocationResult` = reply markdown. Streaming rides a separate
  seam (2026-08-12): `AgentStreamingInvoking` adds
  `invoke(_:onChunk:)`, which `AgentGatewayCLIInvoker` implements by
  parsing ACP `agent_message_chunk` lines incrementally. During serve,
  the dispatcher publishes chunks through `AgentReplyStreamPublishing`
  into `AgentReplyStreamHub`, and clients long-poll
  `GET /note/agent-stream?turn=<turnNoteId>&cursor=N` — the HTTP server
  still writes single responses; the final reply stays authoritative
  via persistence and the change feed.
- **AI2 — Configuration in the `ai` section of `config.json`.**

  ```json
  {
    "ai": {
      "agent": {
        "backend": "agent-gateway-cli",
        "commandPath": null,
        "provider": "openrouter",
        "model": "openai/gpt-5-mini",
        "apiKeyEnvironmentVariable": null
      },
      "autoTag": { "auto": "on" },
      "translate": {
        "provider": null,
        "model": null,
        "defaultTargetLanguage": null
      }
    }
  }
  ```

  `agent` absent means no runtime. `provider` names an agent-gateway
  vendor; `model` is required (the gateway takes an explicit model).
  `commandPath` overrides the `PATH` lookup for the `agent-gateway`
  binary. `apiKeyEnvironmentVariable` is the credential's environment
  variable NAME (never a value). Local operator commands may use the
  gateway's per-vendor default when it is absent, but served requests require
  the explicit variable so only that selected credential enters the sandbox.
  `autoTag.auto` defaults
  to `off`. `translate.provider`/`translate.model` override the agent
  vendor for translation requests only (set `model` whenever `provider`
  differs — model ids are vendor-specific);
  `translate.defaultTargetLanguage` backs `kaiba ai translate` when
  `--to` is omitted.
- **AI3 — Tag extraction contract.** The prompt carries the subject
  markdown plus an ontology snapshot (tag classes `person`, `year`,
  `event`, `document-kind`, `topic`; existing tag names; hierarchy) and
  demands a strict JSON array reply: `[{"name":..., "class":...,
  "parent":...?}]`. Validation rejects class `folder` and unknown
  classes; tags are resolved or created hierarchy-aware; assignments are
  applied with provenance `ai` at note and notebook level through the
  existing APIs, which already guarantee AI never overwrites or deletes
  human tags (D6). Agent-conversation notebooks are skipped.
- **AI4 — Auto-tagging rides the existing auto-action outbox.**
  `KaibaAutoActionDispatcher` implements the `AutoActionDispatching`
  seam and routes on workflow id: `note-auto-tagging` (tag extraction),
  `note-agent-reply` (chat reply). Failures return `.failed` and use
  the existing lease/retry machinery (3 attempts). At serve startup,
  when an invoker exists, actions are reconciled via the idempotent
  `configureAutoAction` upsert (seeding only runs on fresh stores):
  `autoTag.auto=on` enables `default-ai-tagging-note-created`,
  `default-ai-tagging-note-updated`, and the new
  `default-ai-tagging-notebook-created`; `off` (or no invoker) disables
  them. `seedAutoActions` gains the `.notebookCreated` row for fresh
  stores. This is data seeding, not a schema migration.
- **AI5 — Manual triggers always exist.** `kaiba ai tag --note <id> |
  --notebook <id> [--dry-run]` runs extraction synchronously (not via
  outbox) and prints results; `kaiba ai status` reports configuration
  and invoker availability. The web UI's Info tab exposes the
  `requestTagExtraction` mutation, which enqueues a `note-auto-tagging`
  dispatch when a dispatcher is installed and reports
  `agent-unavailable` otherwise.
- **AI6 — Chat data model: conversation notebooks, no new tables.** A
  chat about note X is a notebook with kind tag
  `notebook-kind:agent-conversation`. Subject binding is recorded twice,
  deliberately: notebook `meta_json` `{"kaibaChat":{"subjectNoteId":...,
  "subjectNotebookId":...}}` for fast lookup (`json_extract`), and
  `source-citation` note links from turns to the subject note so the
  subject surfaces in the note graph and the Linked tab. Rejected: a
  dedicated `chat_sessions` table (duplicates turn idempotency, kind
  tagging, and auto-action enqueueing that conversation notebooks
  already have).
- **AI7 — Pending-turn lifecycle.** The existing
  `NoteConversationTurn` couples user and assistant markdown in one
  note, but interactive replies arrive later. `NoteService+AgentChat`
  adds: `startConversation`, `appendPendingChatTurn` (user half, note
  meta `{"kaibaChat":{"status":"pending"}}`), `completeChatTurn` /
  `failChatTurn` (status `answered` / `failed`; completion writes pass
  `originatingActionId` to suppress auto-action loops), and
  `listConversations(subjectNoteId:)`.
- **AI8 — Reply transport: outbox + transient chunks + durable change feed.**
  When an invoker
  exists, serve upserts auto-action `agent-chat-reply` (trigger
  `noteCreated`, filter `{"notebookKindTag":
  "notebook-kind:agent-conversation"}`, workflow `note-agent-reply`).
  A pending turn note fires it; the dispatcher invokes the agent with
  prior turns, bounded attachments, and subject markdown. During invocation,
  ordered `agent_message_chunk` values flow through
  `AgentReplyStreamPublishing` to `AgentReplyStreamHub`; the web pane reads
  them through the turn-scoped `GET /note/agent-stream` long-poll route.
  This preserves the HTTP server's single-response boundary and deliberately
  avoids SSE, WebSocket, and a store-wide push channel. The completed or
  failed turn is persisted as the authority, then `GET /note/events` causes
  clients to refetch and replace transient stream state. Poll waiters are
  turn-scoped and remain tracked from registration until response return:
  publishing or finishing a turn wakes only that turn's waiters, while response
  completion, timeout, or client cancellation unregisters the request. Finishing
  a stream captures its in-flight poll requests as terminal-delivery obligations,
  including requests woken by a preceding chunk whose response has not returned.
  The stream remains protected until every captured request has
  returned a snapshot containing all buffered chunks after its cursor and the
  terminal status, or that request is cancelled. New polls after the terminal
  transition read the retained terminal snapshot immediately but do not add a
  delivery obligation. A terminal stream also receives a 35-second delivery
  grace measured from its terminal transition. This exceeds the route's 30-second
  maximum long-poll timeout by five seconds, covering the normal gap in which a
  client consumes a non-terminal response and starts its next poll. The grace is
  satisfied when at least one poll response returns a terminal snapshot, or when
  its deadline expires; cancellation alone does not satisfy it. Only after all
  captured obligations are discharged and the grace is satisfied does the stream
  enter the bounded late-poller retention set. Capacity cleanup evicts only
  entries in that set, oldest terminal transition first. Cleanup runs when a
  stream finishes, a poll returns or cancels, a poll or publication accesses the
  hub, and when the grace deadline fires, so a terminal stream with no poller
  eventually becomes eligible without requiring unrelated traffic. Active
  streams, terminal streams with undelivered obligations, and terminal streams
  still awaiting first delivery within grace are never capacity-evicted; the hub
  may temporarily exceed its target until protection ends. This guarantees
  concurrent and between-polls terminal delivery within the bounded grace without
  promising indefinite replay after an old terminal entry becomes eligible and
  is capacity-evicted. If the invoker is unavailable,
  `sendAgentChatMessage` still persists the user turn and returns
  `agentStatus: "agent-unavailable"`; no stream is opened.
- **AI9 — Notebook translation.** A translation is a
  `notebook-kind:translation` notebook created up front in `pending`
  state, with meta JSON `{"kaibaTranslation":{"sourceNotebookId":...,
  "targetLanguage":..., "status":"pending|completed|failed|cancelled",
  "error":...?}}` (the `kaibaChat` precedent). `AITranslationService`
  invokes the agent once per source note (purpose `translation`, prompt
  demands the translated markdown only, structure preserved, code/URLs
  untranslated; whole-document code fences are stripped from replies),
  appends each translated note (provenance `ai`, note meta
  `kaibaTranslation.sourceNoteId`, writes carry `originatingActionId`
  so no auto-actions fire), then flips the status. Already-translated
  notes are counted and skipped, so an outbox retry — the manual
  dispatch uses workflow `notebook-translation`, routed by
  `KaibaAutoActionDispatcher` — or `kaiba ai translate --resume <id>`
  resumes where a failed run stopped instead of re-paying for finished
  pages. `cancelled` is a terminal safety state: disabled or unavailable
  originating principals cancel the translation without provider execution,
  and recovery preserves that terminal state rather than retrying it. The
  durable dispatch processes one keyset page of at most 128 sources and
  persists its continuation before a later outbox lease resumes it. A
  synchronous CLI run advances unchanged pages to completion without consuming
  reconciliation rounds, including the empty completion page after an exact
  full page. Reconciliation rounds are charged only when a durable source
  revision changes and resets the cursor. That revision is a non-prunable
  per-notebook token committed with the source action, rather than a retained
  action-history row; provider-call and elapsed-time caps apply to
  each bounded page. Sustained churn therefore consumes the normal
  retry budget without making stable notebook cardinality a reconciliation
  failure. The
  per-feature vendor override rides
  `AgentInvocationRequest.provider/model` (`ai.translate` config, CLI
  `--provider`/`--model`). There is no automatic trigger: translation
  is always requested manually (CLI synchronously; UI/GraphQL via a
  manually enqueued dispatch, like `requestTagExtraction`).
- **AI10 — Chat model choice is an immutable turn snapshot.** Model
  discovery uses `AgentGatewayCLIModelCatalog` for the configured provider
  and exposes ids and display metadata to authenticated web clients. The
  configured `ai.agent.model` is always present as the fallback option even
  when the vendor cannot enumerate models. `sendAgentChatMessage` accepts an
  optional model id, validates it against the current-provider catalog (or
  the configured fallback), and records it in turn `kaibaChat.model` before
  dispatch. Reply generation reads that snapshot and supplies it as
  `AgentInvocationRequest.model`; later app-setting or config changes do not
  alter queued or retried turns. Provider remains server-configured. Model
  ids are data passed as a discrete process argument, never interpolated
  into a command string. Idempotent replay returns the original turn and
  cannot mutate its model.
- **AI11 — Agent-turn attachments reuse file storage without becoming
  ambient subject context.** `sendAgentChatMessage` accepts zero to four
  inline attachment values (base64 content, declared media type, original
  filename). The GraphQL/service boundary estimates base64 size before
  decoding, rejects malformed encodings, then enforces a 1 MiB decoded
  aggregate, filename validation, a UTF-8 textual media allowlist, and
  content decoding. Validation of all attachments completes before a turn
  is created. The core append operation stores each file through the
  existing SHA-256-tracked, file-ID-addressed file store and associates it
  with the generated turn note in the same dispatch boundary; rollback removes newly stored
  content or leaves it eligible for existing orphan reclamation. Reply
  dispatch must not observe the pending turn before its file associations
  exist.

  Reply prompt construction resolves only files attached to turns in the
  active conversation. Its file-content budget is exactly 1 MiB (1,048,576)
  of UTF-8 bytes and excludes framing. A separate 4 KiB allowance covers the
  fixed delimiters, normalized filename/media-type headers, and omission
  markers; accepted filenames are capped at 255 UTF-8 bytes, so four
  current-turn headers fit that allowance. Prompt construction adds whole,
  delimited sections in this order: current-turn attachments by stored
  position, then prior turns newest-to-oldest and their attachments by stored
  position. Current-turn validation guarantees all current file content fits
  the 1 MiB content budget, including an aggregate exactly at the limit. A
  prior file whose content would exceed the remaining content budget is
  omitted and represented by a stable filename/media-type omission marker;
  no file is partially truncated. If prior-file headers or omission markers
  would exhaust the framing allowance, remaining prior files are omitted
  without adding further markers. Sections label normalized filename and
  media type, treat contents as untrusted reference data, and never follow
  paths or URLs found inside a file. A retry uses persisted attachment
  positions and the model snapshot, producing the same ordering. Subject note
  and notebook files are not implicitly disclosed. Memo-only comments remain
  text-only because comments have no file relation; adding a comment-file
  schema is outside this change.

## Chat Composer Security and Validation Boundary

- Authentication, subject/conversation ownership, read-only enforcement,
  idempotency, and file validation are server-authoritative; client checks
  exist only for immediate feedback.
- A supplied `conversationNotebookId` must be an agent conversation for the
  supplied subject. Attachment file records cannot be borrowed by id from
  another note, notebook, client, or request.
- Original filenames are display metadata, never storage paths. The server
  rejects empty names, path-like names (any `/` or `\\`, including absolute
  paths and traversal components), control characters, and names longer than
  255 UTF-8 bytes before creating a turn; it does not silently strip or
  truncate them. Accepted names are preserved for display only.
- After removing parameters such as `charset`, the normalized media type must
  be one of `text/plain`, `text/markdown`, `text/csv`,
  `text/tab-separated-values`, `application/json`, `application/xml`,
  `application/yaml`, or `application/x-yaml`, and decoded bytes must be valid
  UTF-8. Empty or generic browser MIME values may use a recognized extension
  as a candidate type, but content validation remains mandatory. `text/html`,
  SVG, scripts, executables, archives, and other active or binary types are
  rejected even if a filename claims an allowed extension.
- Prompt inclusion has the independent 1 MiB UTF-8 file-content cap and 4 KiB
  framing allowance defined by AI11, deterministic whole-file ordering, and
  explicit delimiters. Attachment text cannot change the system prompt or
  introduce agent-gateway arguments.
- The inline aggregate remains at 1 MiB so base64 plus the GraphQL envelope
  fits the existing 2 MiB HTTP request limit. The global parser limit is not
  increased.

## GraphQL Surface Additions

Each field follows the full AppGraphQL touchpoint checklist (SDL,
projector line, field allowlists, root switch, selection types/fields,
service method, DTO, inputs, diagnostics, contract tests — updated in
the same change).

- Query `noteConversations(noteId, limit)` — conversations whose
  subject is the note.
- Query `agentModels` — authenticated catalog for the configured provider,
  including configured fallback and discovery availability; no credentials,
  command paths, or environment values are returned.
- Mutation `sendAgentChatMessage(input)` — creates the conversation on
  first message, validates and persists optional `model` and bounded textual
  `attachments`, appends a pending turn, returns
  `{conversationNotebookId, turnNoteId, agentStatus}` where
  `agentStatus` is `pending` or `agent-unavailable`. Optional `mode` is
  `memo` (default; answer in the conversation only) or `edit` (the reply
  rewrites the subject note). `edit` is validated before any conversation is
  created: it requires a note subject whose own read-only flag and whose
  notebook's flag are both clear, mirroring the `updateNoteBody` gate;
  `appendPendingAgentChatTurn` re-enforces the same rule inside its
  transaction. The mode is snapshotted immutably on the turn meta JSON
  (`kaibaChat.mode`, absent for memo) exactly like `model`, so a
  conversation can switch modes per turn and retries replay the original
  mode.
- Edit-mode replies carry no tool channel: the agent returns the complete
  replacement body between `<kaiba-note-body>` sentinel lines plus optional
  commentary, and the server applies it through `updateNoteBody` (the same
  guarded write path as `kaiba edit`), which keeps the feature portable
  across provider adapters and re-checks read-only state at apply time. A
  reply without usable sentinels (clarifying question, refusal, blank body)
  is persisted as a plain answer and the note is untouched. Edit turns skip
  chunk streaming — the raw body would render as markup mid-flight — and
  publish only the stream finish event.
- Mutation `requestTagExtraction(input)` — manual tag extraction for a
  note or notebook; returns `queued` or `agent-unavailable`.
- Mutation `requestNotebookTranslation(input)` — creates the pending
  translation notebook and queues the run; returns
  `{translationNotebookId, status}` where `status` is `queued` or
  `agent-unavailable` (nothing is created when unavailable). Translated
  notes arrive through the change feed as the dispatcher appends them.
- Query `noteTagDetails(noteId)` — structured tag assignments
  `{name, className, provenance, parentName}` for the Info tab.
- Turn listing reuses notes-by-notebook queries; turn status/role is
  read from note meta JSON (exposed if not already).

## Verification (Phase D checklist)

1. `kaiba ai status` reports the backend available.
2. `kaiba ai tag --note <id> --dry-run` proposes ontology tags; the
   real run applies them with provenance `ai`; re-running never touches
   a human assignment.
3. `kaiba ai tag --notebook <id>` works at notebook level.
4. With `autoTag.auto=on` and serve running, `kaiba import <pdf>`
   triggers notebook and note tag dispatches; the attempt listing shows
   `dispatched`; killing serve mid-dispatch recovers via lease
   staleness on restart.
5. UI chat round-trip: send, pending, answered via the events feed;
   conversation persisted with kind tag, meta JSON, and
   `source-citation` links; idempotent resends do not duplicate turns.
6. `requestTagExtraction` from the Info tab queues and completes.
7. Failure modes: an unsupported client-selected model is rejected before
   turn creation; a catalog-approved or configured model later rejected by
   the runtime yields a `failed` turn with a message; removing the agent
   binary yields `agent-unavailable` in UI and CLI.
8. Model contract: catalog fallback works when enumeration is unavailable;
   selection persists in app setting `web.agentModel`; queued/retried turns
   invoke their snapshotted model; unsupported model ids are rejected before
   turn creation.
9. Attachment contract: accepted UTF-8 files round-trip through turn file
   associations and reach prompt context; malformed base64, spoofed/binary
   media, invalid UTF-8, empty filenames, path-like filenames, filenames with
   control characters, filenames over 255 UTF-8 bytes, more than four files,
   and aggregate payloads over 1 MiB are rejected without dispatch. Boundary tests
   verify that exactly 1,048,576 content bytes across four maximum-length
   filenames fit with framing kept within 4 KiB, while one additional content
   byte is rejected before turn creation.
10. Stream capacity: register turn-scoped pollers for more concurrent active
    turns than the hub's retention target, publish chunks and terminal states
    for every turn, and verify every already-waiting poll returns its buffered
    chunks and terminal status before its stream becomes eviction-eligible.
    Verify an unrelated turn does not wake a waiter, cancellation releases its
    delivery obligation without satisfying first-delivery grace, and a client
    between sequential polls receives the retained terminal snapshot within the
    35-second window. Using a controllable clock, verify a terminal stream with no
    poller becomes eligible at the deadline, temporary excess retention is allowed
    while obligations or grace remain, and cleanup converges to the target by
    removing only the oldest eligible terminal streams.
11. Executable verification gate for composer work: the focused runs
    `swift test --filter AgentChatTests`,
    `swift test --filter AgentGatewayCLIInvokerTests`, and
    `swift test --filter AgentChatGraphQLTests`, then the full `mise run lint`,
    `mise run test`, and `mise run build`. The mise tasks are the gate rather
    than bare `swift` invocations because `build`/`test`/`run` depend on
    `anydoc:native` and set `PKG_CONFIG_PATH` to
    `.build/anydoc-native/host/pkgconfig`; a focused filter run outside mise
    must inherit the same prerequisite and variable or its result is not
    evidence. Because that variable is task-scoped in `mise.toml` rather than a
    global `[env]` entry, `mise exec` alone supplies the toolchain but not the
    variable, so the runnable focused form is `mise run anydoc:native` once,
    then
    `PKG_CONFIG_PATH="$PWD/.build/anydoc-native/host/pkgconfig" mise exec -- swift test --filter <Suite>`.
    Web-side gating is defined once in `web-chatbook-ui.md`.
12. Evidence and blocker recording: every item above is satisfied only by
    executed command output. Native-link, toolchain, or runtime unavailability
    is recorded with the exact command, an output summary, the reason, and the
    checks the blocker leaves unaffected. Compilation or static review never
    satisfies a checklist item, and a command-wrapper timeout is a tooling
    limitation to report, not a pass.
