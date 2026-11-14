# Page recognition tasks

The Recognize button beside “No searchable text on this page yet” starts page
recognition directly. Analysis uses the same action. Opening Analysis is a
separate settings button, so recognition no longer silently changes tabs.

The app owns one OCR queue shared by both controls. Duplicate active requests
for a page are coalesced and pages run serially to respect server admission.
Each task records its document/page, timestamps, state, and error. Queued work
can be cancelled; failures can be retried. Retry checks the persisted page state
before recognizing again, covering a lost response after successful OCR.
Explicit page locks report an actionable error. An imported notebook's source
lock does not prevent completing its writable pending pages.

The header shows the current document/page OCR and a count of additional active
tasks. Its link opens `#/tasks`, with queued, running, completed, failed, and
cancelled entries. Running work is listed first, then queued work, failures, and
finished work. Jump back restores the source route, including its page and
Fast Note query/layout where applicable. Opening a task's page also remembers
the task list as a return destination.
The reader's Original/OCR/Translated selection is retained when returning from
Tasks, so the same page opens in the same display mode.

Task execution belongs to the app store rather than a mounted page component,
so page/view changes do not cancel it. Queue/history are scoped to the current
app session; they are not a durable server job registry and are cleared on app
reload or account reset. OCR results themselves remain in the canonical store.
Authentication failures clear queued work, and late responses cannot update a
different account session. Server changes already reload the app.

Recognition uses the existing scoped API: native PDF text is preferred when the
document's mode permits it, otherwise OCR runs. Completion refreshes the selected
note, notebook revision, and text resource. An already processed blank page says
that no text was detected instead of repeatedly offering a pending-page action.
Background failures also show an error toast; task-list errors remain available
for retry after the toast expires.

## Verification, 2026-10-24

- Queue tests cover serial execution, duplicate clicks, queued cancellation,
  retries after a lost response, explicit page locks, and account reset/failure.
- UI integration covers direct empty-text recognition, disabled busy controls,
  a three-task header summary, task-list navigation/jump-back, continuing work
  while the page is unmounted, page text refresh, completion history, and a
  processed blank page.
- A full workspace integration verifies that opening Tasks and jumping back
  preserves both the page and its OCR display selection.
- Final checks passed: 196 Bun tests, 177 Vitest tests, web lint/build, and
  `mise run tauri:check`.
- A temporary PDF was imported with deferred OCR and OCR-only extraction. A
  component integration against the actual local API recognized both pages with
  local Vision, navigated through Tasks, refreshed the displayed text, and
  verified persisted OCR output. No external OCR provider was used. The
  compatibility preview adapted only the legacy metadata status field.
- Native browser verification was unavailable because the native window had
  closed and the in-app browser provider was unavailable. The real-API test is
  distinct from the mocked integration tests.
- Evidence: `tmp/pdf-validation-20261024/ocr-tasks-runtime-check.json` and
  `ocr-tasks-live-integration.log`. The temporary notebook was removed afterwards.

## Explicit reruns and header actions, 2026-10-24

OCR and Translated are split buttons. The main area always opens the view,
including before output exists. The right arrow opens an action list; OCR runs
recognition and translation opens the language/page-scope form. Existing output
can be generated again.

Explicit OCR uses `forceOCR` through the queue and scoped GraphQL mutation. It
bypasses native PDF text extraction and the complete-page shortcut, replacing
stored page text while retaining page memos. Default extraction remains unchanged.
The CLI equivalent is `page-ocr <note-id> --force-ocr`. Ownership, explicit page
locks, concurrent-change checks, revision updates, and search refresh still apply.

The reported page 196 in `考える技術.pdf` contained only `198` in its OCR text.
Its original is vertical Japanese; local Vision returned only that page number
again, including in a separate Japanese-language trial. The preview has no AI
agent configured. Manual extraction now reports unusable page text explicitly
instead of attempting a tag workflow with only a page number. Missing agent
configuration appears as an error in Tags. The extraction prompt explicitly
requests people, organizations, book/work titles, places and dates and preserves
proper names in their original language.

Browser verification on the linked page confirmed enabled view buttons, both
arrow action lists, the translation scope form, an actual repeat OCR task marked
Completed, jump back, and the actionable extraction error. The OCR quality and
missing AI runtime remain unresolved for actual entity extraction on that page.

The workspace's existing unload protection now includes queued/running OCR.
Tasks explains that queued work needs the app kept open. This prevents silent
loss on accidental reload; choosing to leave still discards this session queue,
while results already committed by the server remain stored. The event-level
regression passes; a native browser reload check remains in the E2E scenario.
