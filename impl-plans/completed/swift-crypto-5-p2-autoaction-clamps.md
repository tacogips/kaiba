# P2: clamp the AutoAction retry limit and heartbeat interval

**Status**: In Progress
**planId**: swift-crypto-5-p2-autoaction-clamps (wave 1, dependsOn: none)
**Design Reference**: `design-docs/specs/kaiba-note.md` K15 and Verification "K15 (clamps)"
**Evidence**: `tmp/swift-crypto-5/P2/logs/`; progress in `tmp/swift-crypto-5/P2/progress.md`

## Intent and context

This ports the intent of Riela f5a26c83 and cf34383d into
`Sources/AppCore/AutoActionDispatching.swift` (920 lines).

- `retryPendingAutoActionDispatches(limit: Int = 50) throws -> Int` (around line 236) runs
  `requireStoreAdministrator(in:)` and `autoActionMaintenanceAuthHook?(db)`, returns `[]` when
  there is no dispatcher, then binds `.int(Int64(limit))` as the SQL `LIMIT` (around line 265).
  SQLite treats a negative LIMIT as unbounded.
- `private func autoActionDispatchLeaseHeartbeatIntervalNanos(staleness: TimeInterval) -> UInt64`
  (lines 15-24) returns `UInt64(interval * 1_000_000_000)` after an `interval > 0` guard.
  `+infinity` or a huge staleness traps. Its only consumer is the heartbeat task (around line 530).
- Optional: read `git -C /Users/taco/gits/tacogips/riela show f5a26c83` and `... show cf34383d`.
  If access is denied, log that and continue. K15 is the contract. If Riela uses a different
  clamp form (for example, a minimum of 1), record the difference in the progress log and still implement K15.

## Non-goals

- Do not change `autoActionDispatchLeaseCutoff`, `NoteService+AutoActionRecovery.swift`,
  `GoogleDocumentAIPageRecognizer.swift`, `SearchIndexSyncLoop.swift`, or any other caller or default value.
- Do not add an early `guard limit > 0 else { return 0 }` before the transaction. That would skip
  the authorization checks. Do not add new public API.
- Do not add tests to `Tests/AppCoreTests/AutoActionTests.swift`. It has 991 lines, and the
  limit is 1000.

## File-level changes

1. `Sources/AppCore/AutoActionDispatching.swift`
   - In the `retryPendingAutoActionDispatches` bindings, the LIMIT binding becomes
     `.int(Int64(max(limit, 0)))`. Nothing else in that function changes.
   - `autoActionDispatchLeaseHeartbeatIntervalNanos`: remove `private`, so it is internal and
     declared like `autoActionDispatchLeaseCutoff` just below it. Keep `interval = staleness / 3`
     and the `guard interval > 0 else { return 0 }`, which also rejects NaN. Cap the seconds
     before multiplying, using `min(interval, Double(UInt64.max / 1_000_000_000))`, then
     multiply by `1_000_000_000` and convert to `UInt64`. Update the doc comment with one
     sentence noting that huge or infinite staleness is capped rather than trapping.
2. `Tests/AppCoreTests/AutoActionRecoveryTests.swift` (244 lines): add test methods inside
   `AutoActionRecoveryTests`, reusing `makeRecoveryService()` and the file's private
   `RecoveryDeferredDispatcher`.

## Pitfalls

- `min` must run before the multiply. `UInt64(min(interval * 1e9, Double(UInt64.max)))` still
  traps, because `Double(UInt64.max)` rounds up to 2^64.
- Comparisons with NaN are false. Keep the `> 0` guard form (`guard interval > 0`), not
  `guard !(interval <= 0)`.
- Keep the 900 s default at exactly `300_000_000_000`.
- Run `swiftlint` on both files. Keep the doc-comment style of the surrounding code.

## Test cases (situation -> expected)

- Heartbeat helper, called directly through `@testable import AppCore`:
  - `staleness 900` -> `300_000_000_000`.
  - `.infinity`, `.greatestFiniteMagnitude`, `1e30` -> no trap, and each equals
    `UInt64(Double(UInt64.max / 1_000_000_000) * 1_000_000_000)`, which is > 0.
  - `0`, `-5`, `.nan`, `-.infinity` -> `0`.
- Retry limit:
  - Seed state: `let service = try makeRecoveryService()` (no dispatcher). Create two notes, so
    enabled seeded actions enqueue pending rows. Then
    `pendingBefore = listAutoActionDispatchAttempts().filter { $0.status == .pending }.count`,
    and assert `pendingBefore >= 2`.
  - `let recovered = try NoteService(driver: service.driver, autoActionDispatcher: RecoveryDeferredDispatcher())`.
  - `recovered.retryPendingAutoActionDispatches(limit: -1)` -> `0`, and the pending count is
    still `pendingBefore`.
  - `retryPendingAutoActionDispatches(limit: 0)` -> `0`, and the pending count is unchanged.
  - `retryPendingAutoActionDispatches(limit: 1)` -> `1`. Then `await recovered.drainAutoActionDispatches()`.
  - This test must fail before the fix (`limit: -1` returned every pending row). Prove it by
    running the new test once before the source edit (`logs/02-red.log` shows a failure) and
    once after (`logs/04-green.log` passes).

## Steps

1. Pre-hash both files into `logs/00-pre.sha256`.
2. Add the tests first and run them red (`logs/02-red.log`). The heartbeat tests cannot
   compile while the helper is `private`, so the red run covers only the limit test. Add the
   heartbeat tests after removing `private`.
3. Make the source edits, run the green filter, run the build, run lint, then post-hash.

## Verification (command -> required evidence)

- `bash -c 'swift test --filter AutoActionRecoveryTests 2>&1 | tee tmp/swift-crypto-5/P2/logs/04-green.log; code=${PIPESTATUS[0]}; echo exit=$code >> tmp/swift-crypto-5/P2/logs/04-green.log; exit $code'` -> exit 0, `Executed N tests, with 0 failures`, and N equals the 4 existing tests plus the new ones.
- `bash -c 'swift test --filter "AutoActionTests|AgentChatDispatchSecurityTests" 2>&1 | tee tmp/swift-crypto-5/P2/logs/05-neighbors.log; code=${PIPESTATUS[0]}; echo exit=$code >> tmp/swift-crypto-5/P2/logs/05-neighbors.log; exit $code'` -> exit 0 with 0 failures.
- `bash -c 'swiftlint lint Sources/AppCore/AutoActionDispatching.swift Tests/AppCoreTests/AutoActionRecoveryTests.swift 2>&1 | tee tmp/swift-crypto-5/P2/logs/06-lint.log; code=${PIPESTATUS[0]}; echo exit=$code >> tmp/swift-crypto-5/P2/logs/06-lint.log; exit $code'` -> exit 0 with no violations.
- `bash -c 'wc -l Sources/AppCore/AutoActionDispatching.swift Tests/AppCoreTests/AutoActionRecoveryTests.swift | tee tmp/swift-crypto-5/P2/logs/07-wc.log'` -> both < 1000.
- `bash -c 'git diff --stat | tee tmp/swift-crypto-5/P2/logs/08-diff.log'` -> P2 changed only its 2 files. Other plans' files may appear.

## Done criteria

- [ ] `grep -n "Int64(max(limit, 0))" Sources/AppCore/AutoActionDispatching.swift` matches once.
- [ ] `grep -n "private func autoActionDispatchLeaseHeartbeatIntervalNanos" Sources/AppCore/AutoActionDispatching.swift` has no match.
- [ ] The red log shows the limit test failing before the fix. Logs 04, 05 and 06 end with `exit=0`.
- [ ] `progress.md` records the Riela parity result (or access denied), the test names and counts, and ends with `status: done`.

## Progress Log

- 2026-10-27: Plan created.
