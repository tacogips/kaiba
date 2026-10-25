# Document workflow E2E scenarios, 2026-10-24

## Acceptance and method

The goal is a usable PDF/image import → original/plain OCR text → ontology tags →
translation/search/AI workflow, verified through Brave computer use. A passing
component test or API request alone is not a UI pass. Start with this scenario,
self-review it, execute it, record observed evidence, fix defects, and rerun the
affected case plus adjacent regressions. Never count an unavailable provider or
an empty AI result as successful extraction.

Use a fresh store on port 8790 from the current root checkout (schema 25), a unique
Meilisearch prefix, and synthetic public test material. Keep the existing 8788
preview and user documents intact. Browser interactions must use Computer Use.
CLI/API/SQLite checks supplement browser evidence for persistence, indexing, and
exact bytes. Live providers must use an installed, authenticated runtime; never
substitute a stub for a live OCR/tag/translation success. Keep secrets out of
logs and scenario artifacts.

## Fixtures and exact oracles

- F1 `native.pdf`: three native-text pages with distinct tokens, a person name,
  book title, place, date, and literal Markdown characters. Expected native text,
  correct physical-page count, plain-text display, and no OCR invocation.
- F2 `scanned.pdf`: two image-only pages with distinct English tokens and entity
  names. Expected OCR output includes those tokens and correct page association.
- F3 `vertical-ja.pdf`: synthetic vertical Japanese image-only page containing
  `大前研一`, `世界が見える／日本が見える`, `東京`, `1986年`, and a unique token.
  Expected useful Japanese text and ontology entities, not just a page number.
- F4 `mixed.pdf`: native, scanned, and blank pages. Expected independent page
  states; blank success clearly differs from pending/failure.
- F5 standalone PNG plus invalid/corrupt PDF and oversized input. Expected an
  image page on valid import; actionable errors and no half-created notebook on
  rejection.
- F6 Markdown with standalone `<><>`, escaped `\<><>`, old hyphen markers,
  normal `---`, fenced/indented/inline code, Unicode and HTML-looking text. Only
  unescaped standalone markers outside code split; escapes display literally.

## Scenario matrix

All rows begin **Not run**. Record actual result and evidence in the execution log.

| ID | UI steps and expected outcome | Priority |
| --- | --- | --- |
| ENV-01 | Open current-checkout test server; confirm no stale bundle/schema errors and working Meilisearch. | P0 |
| IMP-01 | Menu → Import popup; opening/closing preserves selected document/page and draft. | P0 |
| IMP-02 | Import F1 with default filename title; exactly 3 physical pages, original PDF opens. | P0 |
| IMP-03 | Native-text preference with OCR limit 0 still extracts embedded text without rendering/OCR. | P0 |
| IMP-04 | Import F2 with OCR limit 0; all pages pending, original remains readable. | P0 |
| IMP-05 | Import F2 with limit 1 and then all; correct processed/pending boundaries. | P0 |
| IMP-06 | Settings default extraction mode persists after reload; per-import override wins without changing the default. | P0 |
| IMP-07 | Import F4; native/scanned/blank pages independently handled and numbered. | P0 |
| IMP-08 | Import F5 PNG; correct original, OCR, filename title, and page count. | P1 |
| IMP-09 | Invalid/oversize/corrupt import: visible dismissible error, retry usable, no partial notebook. | P0 |
| IMP-10 | Busy import prevents duplicate submissions; uncertain failures never auto-reupload. | P1 |
| OCR-01 | Pending OCR view → Recognize; actual recognition, busy feedback, new stored/plain displayed text and searchable token. | P0 |
| OCR-02 | Analysis recognition performs the same queued action on the selected physical page. | P0 |
| OCR-03 | OCR split arrow → run again on a complete page; actual provider invocation, replaces text, preserves memos/tags/title. | P0 |
| OCR-04 | Explicit OCR bypasses native PDF extraction even for an already searchable F1 page. | P0 |
| OCR-05 | Queue 3 pages; header names running task and additional count; serial execution and no duplicate active page. | P0 |
| OCR-06 | Header → Tasks → jump back restores page and Original/OCR/Translated mode; open task page also supports return. | P0 |
| OCR-07 | Cancel queued work; failure is visible with retry; work continues while viewing another page. | P0 |
| OCR-08 | Blank recognition gives explicit no-text outcome; rerun remains available. | P1 |
| OCR-09 | F3 vertical Japanese: verify meaningful text, names/book title, and reading order against original. | P0 |
| OCR-10 | Reload during work: document state reconciles honestly; no false completed/pending claims or silent loss warning. | P0 |
| TAG-01 | Extract F1/F2 tags with live AI; actual proposals saved, shown in header and Tags, and retained after reload. | P0 |
| TAG-02 | Extract F3 names/book/place/year with suitable OCR; ontology classes correct and original-language names preserved. | P0 |
| TAG-03 | No usable OCR or unavailable/failed provider gives an actionable error, not empty successful extraction. | P0 |
| TAG-04 | Add free-text and typed tags, edit and remove; correct page only; reload persists changes. | P0 |
| TAG-05 | Click header tag → matching notes/pages popup; preview, jump, and jump back work. | P0 |
| TAG-06 | Same-topic/related-topic results identify shared/related tag evidence matching visible assignments. | P1 |
| TR-01 | Translated view and its arrow remain enabled before any translation exists; empty state offers generation. | P0 |
| TR-02 | Language list supports prefix filtering, selection, and keyboard; current-page translation creates associated saved output. | P0 |
| TR-03 | Inclusive page range and whole-document translation affect intended pages only; validation rejects invalid bounds. | P0 |
| TR-04 | Repeat translation from arrow; updates selected language/version, no unrelated page changes. | P0 |
| TR-05 | Switch Original/OCR/Translated across pages and reload; associations and language remain correct; outdated translations are explained. | P0 |
| NAV-01 | Footer shows current/total physical page and valid page jump; prev/next, left/right edges, arrows, Ctrl+U/D respect bounds and binding. | P0 |
| NAV-02 | Typing in input/chat/editor never triggers page shortcuts; page changes do not show stale text/errors. | P0 |
| NAV-03 | Fit-to-page fits whole page without scrolling across resize; zoom preserves readable original. | P0 |
| NAV-04 | Settings opens and returns; jump-back works across pages, tags, Tasks, and search. | P0 |
| NAV-05 | Filename default title can be renamed with one-line icon controls; survives reload and OCR rerun. | P1 |
| SEARCH-01 | Unique native/OCR tokens find correct page after completion; absent query shows clear empty state; selection jumps correctly. | P0 |
| SEARCH-02 | Notebook Analysis → rebuild index; native/OCR/AI history searchable afterward. | P0 |
| AI-01 | Footer chat receives current notebook/page OCR context; live answer cites known fixture fact and can be continued. | P0 |
| AI-02 | Saved AI conversations visible in AI tab/footer, reopen/continue, survive reload, and appear in database/search. | P0 |
| AI-03 | Area-selection overlay opens chat with correct cropped page image; cancellation and page/zoom coordinate accuracy. | P1 |
| MD-01 | Menu new notebook; auto-create/save after typing with Saved status; F6 splits only standalone `<><>`, with Markdown-style escapes and code exclusions. | P0 |
| MD-02 | Add/rename/delete note/notebook controls consistent with autosave and locks; original import protection explained. | P1 |
| DATA-01 | Original bytes unchanged; no persisted PDF page images; OCR stored as plain page text; page memos separate. | P0 |
| DATA-02 | Read-only/ownership errors visible; failures do not overwrite content; slow page switch and repeated clicks do not corrupt selection. | P0 |
| UI-01 | Header single line, footer page controls, AI-first tab order; tooltips on icons; no clipped/wrapped captions at normal/narrow widths. | P1 |
| UI-02 | Errors have readable contrast; toasts dismiss manually/time out, hover/focus pause; success/error are distinct. | P1 |
| UI-03 | Popovers close on outside click/Escape, focus returns; controls work by keyboard and do not block reading. | P1 |
| CLEAN-01 | Remove only disposable test content via UI; verify original user store untouched and test artifacts accounted for. | P1 |

## Scenario self-review (before execution)

1. **Avoid false positives:** OCR success requires the fixture token in displayed
   text and canonical storage, and tag success requires real typed entity tags.
   Task completion alone is insufficient. Translation success requires meaningful
   target-language text associated with the right source page.
2. **Avoid implementation-only evidence:** every user-facing P0 flow needs a UI
   trace; exact bytes, provider invocation, storage/index behavior need additional
   authoritative checks. Mark API-only cases explicitly until UI confirmed.
3. **Cover boundaries:** include zero/one/all OCR, first/last/blank pages, invalid
   input, unavailable provider, retries, repeated processing, reload, and stale
   requests. Include image imports and Markdown creation rather than only PDFs.
4. **Protect fidelity:** compare the same source page through original/text/tag/
   translation/search/chat. Check Japanese vertical layout and explicit entity
   classes, not only easy English/native text.
5. **Cover surrounding behavior:** tasks, jump back, editor shortcuts, zoom,
   tooltips, errors, AI context/history/index rebuild, locks, and storage are
   included because they can break a nominally successful import workflow.
6. **Environment validity:** test schema 25 current code, not the schema-24
   compatibility preview; use real configured providers with synthetic material.
   Keep unavailable capabilities outstanding, not passed or silently mocked.
7. **Completion review:** every P0/P1 row must have direct evidence or a concrete
   unresolved blocker. Rerun fixed failures and affected adjacent cases. Record
   remaining failures honestly and keep the goal active until the requested
   workflow is verified.

## Execution log

Not started. Results will be added with timestamp, fixture, observation, evidence,
defect/fix, and rerun outcome.

### Run 1: native text, tags and scanned OCR

- Current root checkout is running on `http://127.0.0.1:8790`, fresh schema-25
  store under `tmp/document-e2e-20261024/store`, separate Meilisearch prefix.
  Synthetic fixtures generated by `scripts/make-document-e2e-fixtures.py` and
  native/Japanese rendered output visually inspected before import.
- IMP-02/03 passed via UI: `native.pdf` has exactly three physical pages; with
  zero OCR budget all native text is complete with source `pdf-text`. OCR view
  shows ORCHID731 and literal `#`, `**`, `<img src=x>` as plain text.
- NAV-01 partial: Ctrl+D/U switched to page 2/CEDAR953 and back to page 1.
- TAG-01 found **E2E-001**: real AI extracted six typed entities (person/name/
  place/date/year/topic), but Tags displayed `[missing: tag-id]` and the header
  remained empty. Background dispatcher used a service without change observers;
  header also preferred stale notebook-list data over the refreshed selected note.
  Fixed shared observer wiring, selected-note precedence and tag-name fallback.
  Regression UI rerun is pending; component regression added.
- IMP-09 partial passed: oversized fixture rejected visibly; selecting a valid
  file cleared the previous error and permitted import. No notebook was created
  for the oversized attempt.
- IMP-04 passed: UI imported two scanned physical pages with zero OCR budget,
  pending state and readable original.
- OCR-01 passed: live Codex gateway recognized page 1 and page 2; respective
  MAPLE624/BIRCH275 output is stored separately from note body. No stub provider.
- OCR-06 passed: header opened Tasks with page 2 Running and page 1 Completed;
  jump back returned to physical page 2 with OCR selected and BIRCH275 displayed.
- Canonical page evidence: `tmp/document-e2e-20261024/page-evidence.json`.

### Run 2: fix verification and Japanese/translation/AI

- E2E-001 rerun passed without navigating or reloading: live extraction on
  scanned page 2 automatically displayed Kyoto and The Orchid Atlas in the
  header and typed Tags pane. No `[missing: ...]` placeholders.
- IMP-05 partial / IMP-06 partial: Japanese fixture imported through UI with
  explicit OCR-only override and limit 1. OCR-09 and TAG-02 passed: exact
  vertical-column text appeared, followed by live typed person `大前研一`, name
  `世界が見える／日本が見える`, place `東京` and year `1986` in header and Tags.
- TAG-05 partial: header person chip opened matching-page popup and selected
  the correct page. Cross-document jump/back remains to be exercised.
- TR-01/02 passed: enabled Translated/arrow before output; language prefix Jap
  filtered to Japanese; keyboard Eng+Down+Enter selected English. Live Japanese
  translation of scanned page 2 persisted only for that source page.
- **E2E-002**: translation was completed in canonical storage, but the current
  Translated view said no output existed. Its resource watched catalog changes,
  while translation completion emits a notebook note update. Added notebook
  revision dependency and a regression test.
- E2E-002 rerun passed with a new English translation of the Japanese page:
  while Translated was selected, the empty state automatically became meaningful
  English output including Kenichi Ohmae, Tokyo, 1986 and Sakura 731.
- IMP-06 partial: OCR-only Settings preference persisted to `app_settings` and
  survived reload after the debounced save. Immediate reload before the 500ms
  debounce can lose a change; this requires follow-up UX/persistence review.
- **E2E-003**: reloading Settings loses the source reader route; Back to reader
  returns to the empty notebook draft instead of the source PDF. Not fixed yet.
- NAV-04 partial: the normal Settings entry/return UI exists and search status is
  Active, but E2E-003 prevents a full pass.
- AI-01 partial: footer labels vertical-ja.pdf · Page 1. A real streamed answer
  correctly gave author/book/city/year/record from OCR without being supplied
  those answers in the question. Completion/history/search verification pending.
- Canonical evidence files: page-evidence.json, tag-evidence.json and
  translation-evidence.json under tmp/document-e2e-20261024.
- Mechanical checks so far: 196 Bun tests, 182 Vitest tests; 107 selected Swift
  tests (two optional skips); SwiftLint two existing warnings; Tauri check passed.

### Run 3: saved AI/search/index and Settings regression

- AI-01 passed: completed live answer accurately included all five facts from
  the selected Japanese page; a second turn returned only 桜七三一.
- AI-02 partial passed: AI tab listed the saved conversation, reopening retained
  the source PDF and showed both turns; UI full-text query `previous` returned
  Chat Turn 2 including user question and assistant answer. Actual Meilisearch
  independently returned that turn (meili-ai-history.json).
- SEARCH-01 partial passed: UI query MAPLE624 returned only the scanned page-1
  result; selection opened that page and jump back restored the Japanese source
  with its English translation selected.
- SEARCH-02 partial passed: Analysis → Rebuild reported `1 notes/pages and 2 AI
  conversation turns`, with engine refresh queued. Post-rebuild queries remain
  to be rechecked.
- E2E-003 fixed with session-scoped source reader route storage, cleared across
  account reset, plus an app-remount regression test. Browser rerun passed:
  source PDF → Settings → reload → Back to reader restored the exact Japanese
  page with its persisted tags. View mode on a full reload still defaults Original.
- IMP-06 override passed: global preference remained OCR-only; mixed.pdf imported
  with explicit prefer-PDF-text override and limit 0, first page was searchable
  through embedded text. Remaining mixed/blank handling is in progress.

### Run 4: blank-page defect and current UI blocker

- IMP-07 partial passed: mixed.pdf has three physical pages; page 1 native text
  complete, page 2 scanned and page 3 blank pending with budget 0. UI page-number
  jump reached physical page 3, and OCR view correctly showed pending text.
- **E2E-004**: live recognition of the truly blank page failed with generic
  `note operation failed`. A direct real-provider trace proved a successful
  `end_turn` with explicit empty `resultText`; the adapter incorrectly rejected it.
- Fixed empty successful OCR handling, retained rejection of missing/truncated
  output, added subprocess regression tests, and made document-processing errors
  actionable without exposing provider diagnostics.
- Real local HTTP API rerun succeeded: blank page 3 is now complete with OCR
  source and empty canonical text (`blank-live-retry.json`). Browser rerun of the
  blank outcome/retry remains pending because Computer Use lost its Brave window.
- DATA-01 passed supplemental checks: all four original files identical across
  fixture, stored bytes and HTTP download; exactly four files, nine page records,
  zero persisted page images, all page note bodies empty; SQLite quick_check ok
  and no foreign-key violations. Evidence: data-integrity-evidence.json.
- Rebuild supplemental check passed: actual Meilisearch still returns the saved
  AI turn for `previous` and source/AI results for 桜七三一 after reindex.
- Open follow-ups: tag UI still leaves “queued” wording after result arrival;
  missing/failed-provider completion status needs explicit lifecycle verification.
  OCR queue reload behavior, three-item count/cancel, standalone image, invalid
  PDF, range/all/repeat translation, page-edge/zoom/input shortcut behavior,
  typed-tag edits/cross-document popup jumps, Markdown autosave/splits, area AI,
  locks, UI contrast/tooltips/narrow layout, and disposable cleanup remain.
- Computer Use error: `cgWindowNotFound` from both the existing target and a fresh
  `cua.getApp('com.brave.Browser')`. This is not treated as an E2E pass. The goal
  remains active; the user was asked asynchronously whether Brave is available.

### Run 5: remaining lifecycle and popover corrections

- **E2E-005**: queued extraction wording persisted even after tags appeared.
  Added an ownership-scoped status query over the real dispatch outbox and UI
  polling for queued/running/retrying/completed/failed states. Duplicate submits
  are disabled while work is active; navigating away cancels only polling, and
  reopening can retrieve the current request state. Raw provider diagnostics
  are not exposed. Tests cover no-op success, retrying failure and foreign-note
  access denial. Real API lifecycle observed Running → Completed; GUI rerun
  pending (`tag-status-live-lifecycle.json`).
- **E2E-006**: translation options could reset on a same-page resource refresh,
  and Escape after focus moved outside the popover did not close it. Added a
  stable page key, document-level Escape handling, accurate expanded state,
  and main-view dismissal. Regression tests pass; browser rerun pending.
- Latest web gate: 198 Bun and 186 Vitest tests, TypeScript, ESLint and build pass.
  SwiftLint has only two existing warnings. Broader Swift regression encountered
  a pre-existing process-cleanup test's 1-second PID startup timeout; its isolated
  rerun and the broad rerun are recorded separately, not ignored.

### Checkpoint and next execution

Scenario status is recorded in tmp/document-e2e-20261024/scenario-status.json:
13 passed, 18 partial, 19 not run. This is not a completion decision. Resume
with the blank page UI outcome/retry, tag lifecycle and popover regressions,
then the outstanding cases listed above. Restore only the disposable 8790 tab;
keep the existing 8788 preview and user documents intact.

Fixtures require Python 3.10+ with reportlab, Pillow and pypdf. The checked
runtime used tmp/document-e2e-20261024/venv312/bin/python and the generator
scripts/make-document-e2e-fixtures.py. Test config stores provider/model and the
explicit local subscription opt-in, never credential values. Only synthetic
fixture content was sent to the live provider.

Final checks at this checkpoint: 198 Bun and 186 Vitest tests; 247 XCTest cases
with two optional skips and six Swift Testing cases; build, web lint/type/build,
SwiftLint (two existing warnings), Tauri check and git diff --check pass. The
initial broader run hit an existing process-fixture PID startup timeout; both
isolated and broad reruns passed (process-cancellation-rerun.log and
regression-check-rerun.log). No tests were removed or weakened to obtain a pass.

### Continuation: full gate and reload protection

Previous goal turn made concrete progress: real UI/API evidence and six fixes.
The next continuation revalidated the live 8790 server and current worktree;
Brave still returned cgWindowNotFound on a fresh app selection, so remaining
browser cases could not resume.

- `mise run check` passed in 81.41 seconds: 1,228 XCTest cases (10 optional skips),
  149 Swift Testing cases, schema check, SwiftLint (two existing warnings), web
  type/lint/tests/build and Tauri check.
- Reviewed OCR-10 reload behavior: active client-side queued work could previously
  disappear without an unload warning. Extended the existing draft protection to
  queued/running OCR and added a Tasks explanation to keep the app open until
  work finishes. A real workspace event test confirms clean unload is allowed,
  queued/running work prevents silent unload, and completion removes protection.
- After that web-only change, `mise run web:check` passed with 198 Bun and 187
  Vitest tests; `mise run tauri:check` and git diff --check passed.
- OCR-10 remains **not browser-verified**. No scenario pass count was increased
  from mechanical evidence alone. Counts remain 13 passed, 18 partial, 19 not run.
- The user question about restoring a Brave window remains pending. No test data
  was deleted, and no replacement browser/API-only walkthrough was represented
  as Computer Use evidence.

### Blocked audit

A third consecutive goal turn rechecked Brave using a fresh app selection and
surface inventory. Brave is listed running, but getApp still returns
cgWindowNotFound and no browser surfaces are exposed. The live test server is
still listening on 8790. Latest full/web/Tauri logs confirm the completed gates;
no repeated tests or extra API requests can establish the outstanding browser
behavior. The objective remains incomplete: 13 passed, 18 partial, 19 not run.

The goal is blocked pending an accessible Brave window. Resume from the existing
scenario list and disposable 8790 store once Computer Use reconnects. Do not
replace missing UI evidence with assertions from the passing mechanical tests.

### Resumed browser run and separator steering

Brave became accessible after the user resumed the goal. The blank-page retry
from Analysis completed and returned to OCR view with the explicit no-text
outcome and no old error. Live tag extraction displayed active/busy status then
completion; new tags appeared automatically. Translation options retained the
English input while background tagging refreshed the same page. Two Escapes
closed the picker and popover, restoring the arrow focus. The user then chose
`<><>` as the replacement note separator with `\<><>` for literal text; F6 and
MD-01 are updated. The new-rule browser rerun passed on 8790: Separator E2E
initially split into three notes; escaped prose rendered the literal marker,
fenced code preserved both marker and backslash, and old hyphen/equal markers
stayed in the third note. Add note inserted `<><>`; autosave and reload retained
four pages including Fourth note. Notebook ID:
`notebook-1792848964807-040b30a0-7c9f-460a-9433-32ecd587e461`.
The latest web gate passed 1299 Bun and 193 Vitest tests; Tauri formatting passed.
The broader E2E objective remains active and incomplete.

### Continued imports, previews, layout, search, and image chat

- IMP-08 passed: `scanned-page-1.png` imported through the popup with `all`,
  filename title and exactly one page. Original image visually matched the
  fixture; OCR displayed MAPLE624. Canonical text is plain `ocr` text and the
  note body is empty.
- IMP-09 corrupt PDF displayed “PDF upload must contain 1...500 readable pages”.
  No notebook was created. Selecting a valid scanned PDF cleared the error and
  the same form imported successfully. Its limit of one recognized physical
  page 1 while page 2 remained pending. The all-pages scanned PDF boundary is
  still outstanding for IMP-05.
- **E2E-007**: tag occurrence rows had no preview. Reused the shared destination
  preview, mounted inside the outer modal so its controls remain in the focus
  boundary. Browser verified native PDF text, Original page preview, Open page,
  and Jump back to the source. Component regression checks independent Escape
  dismissal and explicit navigation.
- **E2E-008**: many tags compressed the title to one character, and a narrow
  reader clipped header actions. Reserved title width and made version controls
  icons with accessible names/tooltips below 40rem reader width. Native window
  resize verified a single header row with title, horizontally scrollable tags,
  add, Original/OCR/Translated, both action arrows, status, back, and tools.
  The window was restored after testing.
- NAV-05/OCR-04 passed together: renamed mixed.pdf to `Mixed E2E renamed`,
  explicitly recognized its already searchable native-text page via OCR arrow,
  displayed ORCHID731, verified canonical source changed to `ocr`, retained six
  tags, and reloaded with the renamed title intact. Memo preservation still
  needs its own OCR-03 rerun.
- Same-topic and related-topic tabs displayed the supporting tag names. A
  distinct hierarchy-edge fixture is still needed for TAG-06.
- NAV-03 passed: Fit rendered the entire page without scrolling and computed
  49%, then 50% and 54% across native window resize. Manual zoom increased
  100% to 125% and enlarged the readable original with scrolling available.
- **E2E-009**: identically titled search hits omitted their notebook names.
  Search results now show the notebook name beside the position. UI search for
  ORCHID731 distinguished `native.pdf`, `Mixed E2E renamed`, Markdown content,
  and saved AI turns. Selecting native.pdf and Jump back returned correctly.
  An absent query showed an explicit empty state. Ctrl+D in its query field
  did not change the underlying page. SEARCH-01 is passed, including the earlier
  scanned OCR token search.
- AI-03 passed: Escape canceled area selection. At 100% a selected token line
  opened the footer composer with a 600×71 crop; stored attachment inspection
  showed exactly “Project token: ORCHID731.” and the live AI returned that line.
  At 125%, a second selection produced the location/date line, also confirmed
  in the stored image and live reply. Crops are user-selected chat attachments,
  not persisted full-page PDF rendering intermediates.
- AI-02 reload continuation passed: both crop turns survived browser reload;
  reopening the current discussion restored them. A third prompt continued the
  saved conversation and returned ORCHID731. Footer history listed the saved
  conversation. UI search found its first and third turns; all three exist in
  the canonical database.
- Latest web gate: 1299 Bun tests and 195 Vitest tests passed; typecheck, lint,
  production build and Tauri formatting passed. The broader goal remains active.
  Exact note/file IDs and canonical evidence are in
  `tmp/document-e2e-20261024/resumed-import-and-reader-evidence.json` and
  `image-chat-evidence.json`.

### Translation scopes, queue latency, and manual tags

- TR-03 passed: Japanese inclusive range 2–3 produced correct CEDAR953 and
  WILLOW842 translations while page 1 remained untranslated. Reversed 2–1 and
  out-of-bounds 2–4 ranges disabled submission with a readable range message.
  Whole-document French then produced and displayed all three physical pages.
- TR-04/TR-05 passed: French and Japanese versions switched correctly; Japanese
  remained selected across page navigation. Explicit OCR on page 3 changed the
  source and marked existing translations outdated, with a source-changed
  explanation in the tooltip. Rerunning only current-page French updated that
  row, cleared its outdated status, and left the other four translation rows'
  timestamps/content unchanged. Original/OCR/Translated and reload retained
  the correct physical-page associations. Reload initially displays Original;
  selecting Translated restores the stored version.
- OCR-05/OCR-07/OCR-10 passed using a temporary 20-second delay **before the
  real OCR provider**, solely in the disposable 8790 runtime. Three queued
  pages showed the running title and “2 more”. Active pages disabled duplicate
  reruns. Tasks showed page 1 Completed, page 2 Running, and page 3 Queued;
  canceling page 3 left page 2 running. A reload attempt while running showed
  Brave's native confirmation; Cancel kept the app and task alive. Page 2
  completed, and a subsequent real reload retained CEDAR953. The canceled page
  had no new canonical update. The original config and normal timing were
  restored after all tasks drained. Queue history remains app-session-only;
  persisted page results survive reload.
- TAG-04 passed: a free tag was added, renamed, then removed. A date-class tag
  was entered through the native segmented date input, saved as `2026-10-24`,
  and retained after reload only on native physical page 2. Earlier Place tag
  add/edit/remove evidence is also retained. Canonical assignment checks show
  neither free-tag name remains assigned.
- **E2E-010**: date-tag form grid placed the save/cancel controls before the
  date input. Assigned explicit grid columns/rows. Browser visual rerun shows
  the date input on the left and check/close icons on the right; ontology type
  and existing-tag explanation appear below. Web and Tauri checks passed.
- UI-03 remains open: header tag/title popovers still need reliable outside
  click and global Escape dismissal with focus restoration. Native date input
  Escape moved focus to HTML without dismissing the tag form. Do not count
  the passing translation/crop dismissal cases as proving all popovers.
- Evidence: `translation-range-evidence.json`,
  `translation-scope-rerun-evidence.json`, `ocr-queue-latency-evidence.json`,
  `manual-tag-evidence.json`, and `tag-form-layout-web-check.log` under the
  disposable E2E artifact directory. Status: 32 passed, 13 partial, 5 not run.

### Popover dismissal and remaining import/keyboard boundaries

- **E2E-011**: tag/title popovers could remain open after a native input moved
  focus to the document body. Added shared outside-pointer and global Escape
  handling. Outside clicks retain the destination focus; keyboard/cancel
  dismissal restores the opening control. A notebook change discards an
  unsaved title draft. Pending saves keep their existing dismissal protection.
- Browser rerun passed for title and date-tag outside-click dismissal and
  global Escape focus restoration. Native input initially consumed Escape to
  release focus; the next Escape closed the form from document-body focus and
  restored Rename/Edit tag. The unsaved test title did not replace the stored
  title. Clicking OCR outside either form closed it and focused OCR.
- Search, tag-result, and import modals now also have a global Escape fallback.
  Modal listeners respect prevented/stopped events, so Escape inside a nested
  destination preview closes only that preview. Regressions caught and fixed
  this nested-dismissal case. Final browser reruns for these modal additions
  remain pending after Brave lost its window handle.
- IMP-05/IMP-10 passed: imported scanned.pdf as `Scanned all E2E` with `all`
  and double-clicked Import. During actual OCR, Import, file controls, options,
  and Close were disabled. Exactly one notebook was created. Its two physical
  pages displayed MAPLE624 and BIRCH275, with both canonical sources `ocr`.
  This completes the earlier zero/one/all budget boundary checks.
- NAV-02 passed: title input and AI textarea navigation keys did not advance
  native PDF page 2. Chat draft was cleared without sending. Markdown editor
  Left/Right/Ctrl+D stayed on the same note in both Vim normal and insert modes,
  without changing its body. Earlier page switches showed the correct source
  text and cleared page-specific errors.
- Latest gate passed 1299 Bun / 197 Vitest tests, typecheck, lint, production
  build, and Tauri formatting. No Swift source changed in this continuation.
- Brave subsequently returned `cgWindowNotFound` during the next draft test;
  a fresh app lookup also failed. The 8790 server is still live, normal config
  restored. This is the first new blocked observation after the earlier window
  recovery; the goal remains active. An async window-availability question is
  pending. Status: 35 passed, 12 partial, 3 not run.

### Settings persistence hardening while browser access is unavailable

- A fresh Brave lookup still returns `cgWindowNotFound`; surface inventory
  lists Brave running but exposes no browser surfaces. This is the second
  consecutive goal turn with the renewed window blocker. No new UI passes are
  claimed and the window-availability question remains pending.
- **E2E-012** fixes the earlier immediate-reload finding for IMP-06: optimistic
  preferences were debounced without an unsaved indicator or reload guard,
  and concurrent settings writes could acknowledge an older snapshot last.
  Added a serialized/coalescing save owner. Pending and failed preferences stay
  dirty until the latest write succeeds; Settings shows saving/saved/error with
  an icon retry action. Reload protection includes these unsaved preferences.
  Reset cancels deferred writes and ignores old-session completions. A delayed
  initial settings read cannot replace an optimistic edit.
- Regressions prove serialized ordering, retry after failure, session reset,
  and actual workspace reload protection during debounce/failure/retry. The
  full web gate passes 1299 Bun / 201 Vitest tests, typecheck, lint, build;
  Tauri formatting also passes. IMP-06 stays partial until browser verification.
- Refreshed integrity audit after the expanded run: 28 notes, 14 document
  pages, six PDF originals byte-identical to their fixtures, zero retained PDF
  page-image attachments, zero document-page Markdown bodies, SQLite quick
  check `ok`, and no foreign-key violations. Selected chat crops remain explicit
  user attachments. Evidence: `data-integrity-after-expanded-run.json`.

### Renewed window blocker: third-turn audit

A third consecutive goal turn made a fresh Brave app lookup, which still fails
with `cgWindowNotFound`. The 8790 test server is live (PID 65737); the latest web
gate remains 1299 Bun / 201 Vitest passed and Tauri formatting passed. The
remaining 15 scenarios require direct browser evidence, including the new
settings and modal reruns; no further independent fix is currently identified.
Repeating mechanical checks cannot establish those UI outcomes. The goal is
blocked, not complete, at 35 passed / 12 partial / 3 not run. Preserve the store,
fixtures, and server and resume the remaining scenario ledger when a controllable
Brave window returns. The async window-availability question remains pending.
