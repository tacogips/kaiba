# Document workflow E2E execution

- [x] Draft a comprehensive scenario matrix with exact content oracles.
- [x] Self-review scenario boundaries, evidence quality, and surrounding workflows.
- [x] Prepare isolated current-checkout runtime and synthetic fixtures.
- [ ] Execute import/native text/pending OCR/scanned Japanese flows via computer use.
- [ ] Execute live tag extraction, translation, search and AI context/history flows.
- [ ] Exercise navigation, tasks, Settings, Markdown, locks and error recovery.
- [ ] Fix observed defects and rerun affected scenarios.
- [ ] Run required mechanical checks and audit every scenario against evidence.
- [ ] Clean disposable content and publish the evidence-backed result.

Current progress: 50 cases; 13 passed, 18 partial, 19 not run. Six defects fixed
in source; E2E-001/002/003 browser reruns passed. E2E-004 blank OCR and E2E-005
status lifecycle have real API reruns; their UI reruns and E2E-006 popover UI
rerun remain. Computer Use currently returns cgWindowNotFound for Brave; the
user was asked asynchronously about restoring the window. The UI remains unavailable; the goal is active and completion is unproven.

Latest gates: 198 Bun, 186 Vitest, 247 XCTest (2 optional skips) plus 6 Swift
Testing cases; build, web lint/type/build, Tauri check, diff check and SwiftLint
pass (two existing warnings). A process-cleanup test hit its existing one-second
PID startup timeout in the initial broad run; isolated and broad reruns passed.
The isolated server remains on 8790, including live AI, with disposable fixtures
retained for remaining cases. Existing 8788 compatibility preview was untouched.

Continuation verification: full `mise run check` passed (1,228 XCTest with 10
optional skips; 149 Swift Testing). Added active-OCR unload protection and a
workspace event regression; latest web gate is 198 Bun / 187 Vitest, Tauri check
passed. Browser checks remain outstanding; the same fresh Brave lookup still
returns cgWindowNotFound. No additional UI passes claimed.

Blocked checkpoint: fresh Brave app selection still fails with cgWindowNotFound
on the third consecutive goal turn. Inventory lists Brave running but exposes no
browser surfaces. The goal is blocked until an accessible Brave window returns;
8790 and test fixtures are preserved for resumption. Completion remains unproven.

Resumed: Brave is available. Blank-page Analysis retry and tag status completed
through the UI; translation popover survived a background refresh and Escape
returned focus. User changed the note separator to `<><>` with Markdown-style
`\<><>` escaping. Implementation/tests and browser rerun passed: three draft
notes, escaped prose and fenced code, Add note inserting the new separator,
autosave, and reload retaining four separate notes. Latest web gate passed
1299 Bun tests and 193 Vitest tests; Tauri formatting check passed.

Continued run: standalone PNG, corrupt PDF recovery, scanned limit-one boundary,
tag text/original preview plus jump/back, explicit native-PDF OCR, rename/reload,
fit/resize/manual zoom, image-region AI at 100% and 125%, saved discussion reload
and continuation, and native/OCR/AI search now have direct UI evidence. Fixed
missing tag previews, header compression/clipping, and ambiguous search result
destinations. Latest web gate: 1299 Bun / 195 Vitest; Tauri passed. Continue the
remaining queue, range translation, ownership, error/toast, and cleanup cases;
do not treat the still-open scenarios as passed.

Latest continuation: translation range/all/rerun/version association and stale
warnings passed. Queue3/header counts/serial operation/cancel/reload warning
passed with temporary20s latency before realOCR; normal config restored.
Free/date manual tags passed including edit/remove/reload/page isolation. Fixed
the date-form grid and visually verified it; web/Tauri checks passed. Current
ledger:32passed,13partial,5notrun. Next fix: header tag/title popover dismissal
and focus restoration, then remaining import boundaries, shortcut guards,
ownership/error/toast behavior, Markdown locks/delete, and cleanup.

Popover fix implemented: shared outside/globalEscape handling for title/tags;
global fallback for search/tag-results/import; nested preview dismissal regression
fixed. Header browser reruns passed; final modal reruns pending. All-page scanned
import and double-submission guard passed, as did input/chat/editor shortcut
guards. Web gate1299Bun/197Vitest andTauri passed. Ledger35passed/12partial/3notrun.
Brave lost its handle again during the unsaved-draft import check; fresh getApp
failed, server65737 remains live. First new blocker observation; goalactive.

Second blocked-window turn: fresh Brave lookup still fails, inventory exposes
no browser surfaces. Made independent progress on the known IMP-06 preference
loss: serialized/coalesced saves, explicit saving/saved/error+retry, reload guard,
stale initial-read/session-completion protection. Gate1299Bun/201Vitest andTauri
passed. Browser rerun remains required; scenario count unchanged35/12/3.
Integrity audit refreshed:28notes/14pages, six unchangedPDF originals, no retained
PDF pageimages, healthySQLite. Next action: reconnectBrave, verify settings fast
reload and modal fallback, then continue the remainingUI scenarios.

Third consecutive window-blocker audit: fresh Brave getApp still returns
cgWindowNotFound. Server65737/live8790 and completedchecks verified; no new UI
passes. Goalblocked at35passed/12partial/3notrun until Brave is controllable.
Retain all runtime/data artifacts; resume fromscenario-status.json when available.
