# AI Agent Runtime, Import, UI Scope, and Auto-Tagging Decisions

Recorded 2026-08-12 while planning the AI/import/chatbook feature set.

## Question 1

The agent runtime (session/prompt handling, spawning claude/codex CLIs)
has not been extracted from riela into agent-gateway yet; agent-gateway
currently holds only provider-routing configuration. How should kaiba
get agent capability now?

## Answer 1

Wait for agent-gateway. Build UI, PDF import, and persistence first;
wire agent chat and tagging only after the runtime is extracted into
agent-gateway. Kaiba defines the `AgentInvoking` seam and configuration
now; the adapter and end-to-end verification are a blocked final phase.

Superseded and resolved 2026-08-12: agent-gateway now exposes the ACP stdio
runtime, and Kaiba integrates it through
`Sources/AppCore/AgentGatewayCLIInvoker.swift`. Agent chat, tagging, model
discovery, streaming, and end-to-end verification are no longer blocked by
runtime extraction. Codex and Cursor remain vendor choices behind this shared
adapter rather than direct provider-specific integrations.

## Question 2

How should kaiba integrate anydoc-swift for PDF/document-to-markdown?

## Answer 2

Make tacogips/anydoc-swift usable (mechanism left to implementation).
Superseded 2026-08-12: use `AnydocKit` directly as a pinned SwiftPM library.
The resolved dependency builds its Rust FFI during Kaiba build preparation;
there is no installed CLI or `import.anydocPath` runtime setting.

## Question 3

Where does the chatbook-style three-pane screen live in the web viewer?

## Answer 3

Full redesign: the three-pane layout replaces the main screen entirely.

## Question 4

When should AI tag auto-extraction run?

## Answer 4

Automatic extraction toggles via configuration (`ai.autoTag.auto`
on/off), and manual triggering must also exist (CLI and UI).

## Question 5

Recorded 2026-08-31 while documenting the gateway process-termination boundary.

Group cleanup fails closed when process-group inspection is `unavailable`: it
refuses to treat an unreadable group as empty, and keeps polling. The wait is
therefore unbounded if inspection never recovers. Fail-closed is the right
default — completing on an unreadable group would leak or orphan descendants —
but the alternative is an upper bound after which the invocation gives up,
reaps the witness, and reports a cleanup-indeterminate diagnostic instead of
blocking a serve worker indefinitely.

Should the `unavailable` wait stay unbounded, or gain a bound plus a
diagnostic?

## Status 5

Pending. Blocking nothing today on Darwin, and that scope is the whole point:
no observed path reaches sustained `unavailable` there, because Darwin reports
`unavailable` only when the `sysctl` enumeration itself fails. The escalation
is not a safety net for a sustained case either. The one-shot final cleanup
fires at most one SIGKILL per termination request, so an `unavailable` state
that first appears after that shot was already spent on a live group receives
no SIGKILL, and cleanup blocks with no escalation left.

The second question this raised — should a per-entry stat failure degrade to
skipping that entry, leaving `unavailable` to mean genuine enumeration failure
on both runtimes? — is now decided. Yes, for a PID the kernel reports as gone,
and only for that. Two errnos carry that report and both are honored at both
syscall sites: `ENOENT`, meaning the `/proc/<pid>` directory is already gone,
and `ESRCH`, meaning the directory survives but procfs cannot resolve it to a
task. A stat file that exists and cannot be read or parsed for any other
reason, and a `/proc` listing that fails outright, still produce `unavailable`.
The discrimination is taken from the errno of the failing syscall at the
instant it fails, rather than from a later existence re-check, so there is no
window in which a genuine failure gets reclassified as a vanished PID. Blind
skipping was rejected: it would under-report a live descendant as `none` and
let cleanup reap the witness while a descendant is still running, which is
worse than the fail-closed defect it would replace. See the Portability
boundary section of `design-docs/specs/ai-agent-integration.md`.

An earlier revision of this entry decided the narrower `ENOENT`-only rule and
recorded it as "established by construction and unit-level reasoning; not
executed on Linux". Both halves have since been superseded and are corrected
here rather than left standing. The rule is wider: `ESRCH` was measured firing
at 1.56% of enumerations under churn, so the `ENOENT`-only form left the
routine transient it was written to remove. And the evidence is no longer
reasoning alone. Two claims that were previously merged must now be kept apart:

- The `/proc` inspector block **has been executed on Linux**, in isolation,
  compiled into a probe binary and run under deliberate PID churn. That is what
  the measurements below rest on.
- The **served-gateway runtime** has still **not** been executed on Linux, and
  remains a named deferral. No `swift test` runs on the Linux pipeline, and
  nothing exercises the inspector through an actual gateway invocation there.

A probe that executes the enumeration logic is not the same evidence as running
the product, and this entry no longer states the second claim in a way that
denies the first.

What stays open is the original question: whether the fail-closed `unavailable`
wait should remain unbounded or gain a bound plus a cleanup-indeterminate
diagnostic. Narrowing `unavailable` to genuine failure removes the transient
misreading that could spend the one-shot escalation on a zombie-only group. It
does not decide what a sustained `unavailable` should do on either runtime.

The decision should now be made against measurement rather than against the
reasoning this entry originally carried. Two results, both from executing the
Linux inspector block in a container as described above:

- **The transient case is settled.** Under heavy PID churn, the adversarial
  review gate measured the pre-fix inspector returning `unavailable` on 85.6%
  of enumerations, an `ENOENT`-only skip leaving 1.56%, and skipping `ENOENT`
  and `ESRCH` at both the open and the read leaving 0.00% across 14,455
  enumerations. The implementing step independently confirmed the shipped
  variant at 0.00% across 21,165 enumerations against its own same-host pre-fix
  control of 91.25%. Zero fail-open in every arm of both sets. The absolute
  pre-fix rates differ because the runs sat on different hosts; the conclusion
  does not. So the routine-churn driver of `unavailable` is gone, and a bound
  is not needed to defend against it. See the Portability boundary section of
  `design-docs/specs/ai-agent-integration.md` for both tables with their
  provenance.
- **The sustained case is real and is what the open question is actually
  about.** On a `/proc` mounted with `hidepid=1` or higher, another user's
  `/proc/<pid>/stat` returns `EACCES` at open. That is a genuine inspection
  failure on a process that still exists, so the contract correctly classifies
  it `unavailable` — and it does so on essentially every enumeration, not
  transiently. On such a host every gateway invocation would block forever in
  the fail-closed wait with no escalation left. This is **not a regression**:
  the pre-fix code discarded the same failure and returned `unavailable`
  identically, so behavior at `74d0048` is the same. It is out of scope for the
  narrowing work. But it converts the open question from a hypothetical into a
  concrete one with a named trigger, and the bounded-versus-unbounded choice
  should be decided against it.

The shape of the answer that follows from these two results: a bound is not
required to absorb churn, but it is the only thing that would stop a
`hidepid`-mounted host from hanging indefinitely. Still pending.
