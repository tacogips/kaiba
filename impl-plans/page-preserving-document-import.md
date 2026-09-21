# Page-preserving PDF and image import

## Required outcome

Kaiba must render PDFs (and accept standalone images), analyze document status,
language, title, writing direction and binding, create one note per physical page,
retain origin images for paginated origin/text reader modes, extract figures into
Markdown, and support selectable analysis, OCR and figure providers. LLM providers
must use agent-gateway including Codex and Claude subscription access. Automatic
notebook/note tags must honor configured enablement, registered tags and prompts.
Import must support zero/N/all OCR pages with subsequent manual per-page OCR.
Verification must include PDFs downloaded on September 13, 2026, with only a few
pages OCRed, plus relevant Swift, web and Tauri checks.

## Current evidence and remaining integration

- Existing import splits Anydoc Markdown by headings; it cannot satisfy physical
  page identity or pending OCR. Preserve it for other document formats.
- Added DocumentPageProcessor with replaceable analyzer/recognizer/extractor,
  ordered original images, per-page analysis, and nil Markdown for pending OCR.
  Zero/N/all limits apply before analyzer and OCR calls. Missing renders fail
  rather than shifting page identity. Standalone images retain original bytes.
- Added Apple Vision local OCR and adapter for existing gateway conversion.
- Unit tests cover limits, figure ownership, layout metadata, incomplete renders,
  standalone images. An environment-gated real-PDF test runs only two OCR pages.
- Completed core/CLI storage and deferred OCR are described below. The client
  now renders figure Markdown and has paginated origin/text modes and a manual
  OCR button backed by GraphQL. The New Notebook upload form is implemented.
  The final functional audit is complete; see design-docs/document-import-completion-audit.md.
- Existing worktree contains substantial unrelated subscription and client work;
  do not revert it or claim it verified by these focused tests.

## Real fixture verification

Use KAIBA_TEST_IMPORT_PDF with an absolute Downloads PDF path and run
`mise exec -- swift test --filter DocumentPageProcessingTests`.
Do not commit the downloaded PDF or its recognized text.

Verified September 13, 2026: `KAIBA_TEST_IMPORT_PDF='/Users/taco/Downloads/10.1.1.69.8949.pdf' mise exec -- swift test --filter DocumentPageProcessingTests`
passed all 5 tests. The downloaded PDF yielded 25 original page images, nonempty
local OCR on 2 pages, and 23 pending pages. CoreGraphics emitted a nonspecific PDF
diagnostic; all page renders and assertions succeeded. This verifies processing,
not notebook persistence, OCR transcription accuracy, or the reader UI.
`mise exec -- swiftlint lint --quiet` passed with three existing warnings outside
these additions. `git diff --check` passed.

## Persistence and deferred OCR implementation

- Added `NoteService.importDocumentPages`: stages source/origin/figure blobs,
  inserts notebook, notes and file associations in one database transaction,
  and deletes staged blobs if the transaction fails. Physical page number and
  `documentPage` metadata include analysis, origin ID and OCR pending/complete
  state. Figure Markdown references `/files/<id>`; web rendering still needs
  authenticated image support.
- Added `recognizeDocumentPage`: validates pending status, stored-origin relation,
  ownership, explicit note lock and pending-body digest before recognition and
  again at commit. The final snapshot comparison rejects concurrent mutations.
  It preserves figure references, updates FTS and emits normal note-update actions.
- CLI PDF/image imports use the page pipeline. `--max-ocr-pages N|all` overrides
  `import.maximumOCRPages` (integer or "all", default 3). `--ocr-engine` accepts
  `vision` or `agent-gateway`; `import.ocrEngine` persists that choice. Configured
  gateway OCR is used by default when present; otherwise local Vision is used.
  Other document formats retain heading-based conversion.
- Added `page-ocr <note-id>` CLI completion using the configured OCR engine.
- Automatic gateway analysis, UI/manual OCR mutation, authenticated Markdown
  images, reader modes, automatic tag runtime integration and Claude image
  transport are still required. Do not treat this core/CLI work as completion.

Verified persistence/CLI increment: all 12 DocumentPageImportTests and
DocumentPageProcessingTests passed with the same downloaded 25-page PDF, including
atomic file-link rollback and concurrent-edit rejection. The persistence fixture
created 25 notes and OCRed only its first two pages. A separate CLI smoke imported
all 25 pages with `--max-ocr-pages 0 --ocr-engine vision`, then successfully ran
`page-ocr` for one pending note. Evidence/store: `tmp/page-import-cli-gs1g5d4u`.
Do not publish this local data. CoreGraphics emitted its nonspecific diagnostic
again; every original was present and readable.

Next integration should expose imports/manual OCR through the authenticated
server and client, add Markdown image parsing with authenticated file fetches,
and add a notebook-level origin/text mode with direction-aware page navigation.
The CLI currently opens a plain NoteService without an auto-action dispatcher;
although imports enqueue actions according to enabled store actions, automatic
CLI tagging requires explicit runtime wiring and verification. Production
analysis providers must also be wired (current CLI recognition alone leaves
analysis unknown); figure crop providers must cover vector graphs and scanned
figures, not just PDF embedded raster images.

Additional validation: `mise exec -- swift test --skip-build --filter
'NoteServiceTests|NoteReadOnlyLockTests|NotebookIngestPublicAPITests|DocumentImportServiceTests|CommandTests|CommandCLITests'`
passed (54 XCTest cases and 53 Swift Testing tests). `mise exec -- swift build`
passed after the help-text update. `mise exec -- swiftlint lint --quiet` passed
with only the three pre-existing warnings; `git diff --check` passed. Web files
were not changed in this increment, and no web/Tauri completion claim is made.


## Reader and manual OCR API

- `DocumentNotebookReader` displays one physical page in Text or Original mode,
  preserving the page on mode changes. Buttons, keyboard arrows and touch swipes
  follow binding direction. Pending-page unknown binding/writing mode inherits
  known analysis from loaded document pages. Go-to-page can load further note
  batches. Note editing, heading anchors and tag highlighting remain available.
- `NoteFileImage` fetches through the authenticated client, owns/revokes its
  object URL, discards late responses on page change, and supports retry.
  Markdown recognizes image syntax and renders `/files/<id>` figures through it.
- `recognizeDocumentPage(noteId: String!)` is a GraphQL mutation returning the
  updated note and metadata. The scoped core service enforces ownership,
  pending state, original linkage and edit protection. Admission bounds OCR work.
  Its current server default is local Apple Vision, with analyzer/recognizer
  injection supported in GraphQL service initialization. Server configuration
  for gateway providers is not yet wired and must not silently diverge from CLI.
- The reader's OCR button reports errors, permits retry, refreshes notes on
  success and disappears once the page is complete. It works under the imported
  notebook lock while respecting explicit per-note locks.
- Three focused GraphQL tests passed (successful mutation/repeat rejection,
  foreign-owner refusal, schema inventory). Full web checks passed with 167
  unit tests and 51 DOM integration tests, including original/text switching,
  right/left navigation, batch boundaries, late image responses, authenticated
  Markdown images, and manual OCR retry. `mise run tauri:check` passed.
- Browser visual inspection could not run: the browser runtime initialized but
  reported no available browser and an empty browser list. No alternate browser
  control was used. Visual layout and a real interactive end-to-end import still
  need verification; DOM tests do not prove those outcomes.

Final checks for this increment: `mise exec -- swift test --skip-build --filter
AppGraphQLTests` passed 140 XCTest cases and 6 Swift Testing tests.
`mise run web:check` passed on the final reader changes. `mise exec -- swiftlint
lint --quiet` passed with the same three existing warnings, and `git diff --check`
passed. No new PDF OCR was needed for this client/API increment; the prior real
PDF storage/CLI evidence remains the source-data verification.

## Structured analysis and visual figures

- Added `StructuredDocumentPageAnalyzer`, a typed JSON adapter usable with any
  DocumentConverting provider, and gateway prompts for document status, language,
  writing mode, binding and visible book/document title.
- Added independent `DocumentFigureLocating` and `DocumentPageFigureExtracting`
  seams, structured gateway region detection, and ImageIO cropping of upright
  page rasters. Coordinates are normalized from top-left; invalid or excessive
  regions fail rather than producing misleading images.
- `import.analysis` and `import.figures` independently select gateway vendor/model
  settings; CLI import and page-ocr wire them separately from the OCR engine.
  Page-limit gating covers all three visual stages. When visual figures are
  selected, pending pages wait for manual OCR before figure detection.
- Deferred OCR now stages figure blobs and commits their links, Markdown, text
  and analysis in one transaction, with cleanup on failure or concurrent edits.
- Server-side provider configuration, Claude subscription transport, automatic
  tag runtime setup and end-to-end verification still remain. Do not infer those
  features from the new CLI factory or the injectable protocols.

Validation of visual providers: 19 focused tests completed with zero failures;
17 ran and two environment-gated real-PDF tests were skipped because the separate
live CLI scenario was used. An additional 11 converter/import/GraphQL regressions
passed. The crop pixel test proves top-left coordinates; the deferred file-link
failure test proves both database rollback and removal of the staged blob.

Live Codex gateway evidence is in `tmp/visual-import-live-if1p57b5` (private test
data; do not commit). Using today's `10.1.1.69.8949.pdf`, an import with an OCR
limit of 1 produced 25 notes and extracted the real title "Time Series Prediction
with the Self-Organizing Map: A Review". Saved analysis was document=true,
language=en, writingMode=horizontal, binding=unknown. A manual `page-ocr` of page
8 ran the same configured analysis and figure stages, saved one vector-graph
crop and its Markdown reference, and left 23 notes pending. No other pages were
OCRed in that test store. Page 8 was selected via the existing PDF text layer,
not full-document OCR.

Visual inspection of the first live graph crop found clipped axis labels. The
cropper now adds a 1% page-relative margin, clamped to page bounds. Four focused
visual-provider tests passed after this adjustment. A standalone-image rerun
using the saved original of page 8 is used to inspect the padded crop.

The standalone-image rerun succeeded: one note, one extracted figure. Inspection
of `padded-figure-1.png` confirmed that axes and tick labels are retained with the
new margin. This also exercises actual single-image import with the independent
analysis and figure providers. SwiftLint completed with the same three existing
warnings, and `git diff --check` passed. These changes touched Swift only; the
previous web/Tauri checks are not new verification of server provider wiring.

## Server provider wiring and gateway process lifecycle

- Image conversion now uses the shared gateway subprocess runner, including its
  output bounds, deadline, process-group cleanup and termination handling.
- Served image calls use the existing isolated environment/filesystem context;
  page bytes are copied into that workspace before invocation. API vendors get
  only the selected credential. Explicitly enabled Codex subscriptions get the
  existing isolated configuration/auth workspace and disabled tools. Images are
  appended after the proper gateway/vendor argument boundary.
- `KaibaServerRuntime` now supplies configured OCR, analysis and figure providers
  to GraphQL. Codex server imports require
  `ai.userAgent.allowCodexSubscription=true`; API vendors retain served isolation.
  The request handler runs synchronous page processing on a blocking worker so
  the shared async gateway runner does not starve Swift's cooperative executor.
- Live loopback HTTP verification succeeded against the existing private PDF
  test store: `recognizeDocumentPage` on page 12 used local Vision plus isolated
  Codex analysis/figure providers, returned accepted/ok, persisted English,
  horizontal document analysis and one graph figure. The test server was stopped
  afterward. The store now has pages 1, 8 and 12 processed, with 22 pending.
  Evidence: `tmp/visual-import-live-if1p57b5/server-ocr-result.json` and
  `server-log.txt`. This fixture used loopback unauthenticated mode; separate
  ownership tests cover authorization, and this run does not prove auth itself.
- Claude transport, automatic tagging runtime and final full-workflow audit still
  remain. GUI upload was planned but has not been implemented.


The new positive sandbox image test exposed an API-provider workspace bug:
logical `/var` temporary paths did not match the physical `/private/var` paths
used by macOS seatbelt. Served workspace creation now resolves the physical
path before constructing its sandbox rules, as subscription workspaces already
did. The mock ACP fixture also needed its required `stopReason` field; the
production parser was not relaxed. Regression tests cover actual staged-file
access, credential filtering, diagnostic redaction and process timeout.

Verification after the physical workspace path fix:

- `mise exec -- swift test --filter 'DocumentGatewayIsolationTests|AgentGatewayServedSafetyTests|DocumentPageOCRGraphQLTests|KaibaServerRuntimeTests'`: 11 tests passed.
- `mise exec -- swift test --filter 'AgentGateway|ImageOCRDocumentConverter|DocumentImportProvider|DocumentPageProcessing'`: 45 discovered, 43 passed, 2 skipped, no failures.
- `mise exec -- swiftlint lint --quiet`: completed with the three existing warnings in NoteService, ResendGatewayCLIMailSender and AITranslationTests.
- `git diff --check`: passed.

Next integration point for automatic tagging: the page importer already queues
notebook/note creation actions, but CLI `makeService` does not install an AI
dispatcher. Existing `AITagExtractionService` supplies registered tags and tag
class descriptions, while its prompt is currently fixed. Complete explicit
configuration, custom registration prompt handling, CLI execution, pending-page
behavior and manual-OCR follow-up tests before claiming the tagging requirement.

## Configurable post-import tagging

Implemented `ai.autoTag.prompt` in the shared tag extraction prompt, together
with registered tags and class descriptions. Server dispatcher and manual CLI
tagging receive it. Added `DocumentAutoTagging` for synchronous CLI import and
page OCR: configuration off makes no provider calls, on tags the notebook and
completed notes, pending notes are skipped, and failed subjects return redacted
warnings while preserving imported text/files. CLI exposes `taggingWarnings` in
JSON and warning lines in text. Server tag dispatch also skips pending pages.

Verification:

- `mise exec -- swift test --filter 'DocumentAutoTaggingTests|KaibaAutoActionDispatcherTests|DocumentPageImportTests|AITagExtraction|AIConfigurationTests|KaibaServerRuntimeTests'`: 28 passed, 1 skipped, no failures. Tests cover configured prompt/catalog, notebook and note assignments, off mode, provider failure preserving content, legacy configuration, and an actual pending image import becoming taggable after manual OCR.
- `mise exec -- swiftlint lint --quiet`: same three existing warnings.

The corrected Claude crop retained both panel titles, axes and graph content,
but still included a left-clipped caption despite the exclusion instruction.
Do not claim figure visual QA complete. The next crop improvement should refine
boundaries against actual page content (for example, whole intersected text
lines), rather than repeatedly increasing uniform padding. Corrected image:
`tmp/visual-import-live-if1p57b5/claude-visual-corrected-store/files/6f/file-1789284737324-f2c0e806-89d9-4017-87e4-f3720b4a981a`.
- Live CLI import of `page-8.jpg`, saved from today's PDF fixture, used native OCR and real Codex agent-gateway tagging (`gpt-5.6-luna`). It returned one note and no tagging warnings. Direct database inspection confirmed `graph-algorithms` on both notebook and note with provenance `ai` and assigned-by `kaiba-ai-tagger`. Private evidence: `tmp/visual-import-live-if1p57b5/tagging-import.json`, `note_tags-tagging-evidence.json`, `notebook_tags-tagging-evidence.json`, and `tagging-config.json`.

The first live command used the unsupported `--json` flag and failed before
import; the successful run used `--output json`. A new test initially assumed
the catalog contained only the added tag; corrected it to assert the registered
tag is present among the existing system tags, without weakening tag persistence
checks. Still needed: live server automatic-tag lifecycle verification, Claude
image transport/subscriptions, and final requirement-by-requirement audit.

Command regression: `mise exec -- swift test --filter 'Command|command'` passed 53 Swift Testing tests. `git diff --check` passed after the tagging changes.

## Claude image transport

Inspected installed gateway/Claude help and the gateway's local source. The
gateway CLI adapter forwards prompt stdin verbatim to Claude Code. Implemented
`ClaudeImageInput` to encode a newline-terminated stream-json user message with
base64 image bytes, MIME type and prompt; no Read tool or file-path prompt is
needed. CLI vendor arguments disable tools, hooks, MCP, slash commands, settings
sources and session persistence. Existing gateway process timeout, ACP parsing
and cleanup remain shared. Supported vendor list now includes `claude-code`.
Server subscription isolation still supports only Codex and rejects Claude.

Live checks used the existing authenticated Claude session (`claude auth status`
reported logged in with OAuth; no credentials were printed). Import of saved
PDF page 8 via `import.ocr={vendor:claude-code,model:sonnet}` succeeded and stored
2,102 characters including the figure caption and body. Separate native-OCR
import with Claude analysis/figure providers returned document=true, language=en,
horizontal writing, unknown binding, one cropped figure and its Markdown link.
The page had no document title, so analysis correctly omitted it. Private
evidence lives in `tmp/visual-import-live-if1p57b5/claude-*` files/stores.

Visual inspection caught clipped panel titles and a partially included caption
in the first Claude crop. The locator prompt now explicitly includes whole panel
titles and excludes captions; the cropper margin is now 2% of page dimensions.
A live rerun checks this correction on the same page, without processing more
physical PDF pages.

- `mise exec -- swift test --filter 'ClaudeImageInputTests|DocumentConverterRoutingTests|DocumentGatewayIsolationTests'`: 9 passed.
- `mise exec -- swift test --filter 'DocumentVisualProviderTests|ClaudeImageInputTests|DocumentConverterRoutingTests'`: 10 passed after crop adjustment.
- `mise exec -- swiftlint lint --quiet`: same three existing warnings.


## Text-aware figure boundaries and server tagging evidence

Added `DocumentFigureTextBounds`: local Vision fast text-line recognition supplies
bounds, discarding recognized strings. Whole text lines intersecting the initial
crop are included with a small margin; expansion does not cascade into adjacent
paragraphs and stays inside the image. It runs only when figure extraction runs,
so pending pages beyond the OCR limit do not incur this pass. The initial text
rectangle detector grouped caption/body content and failed the real fixture;
fast line recognition resolved that failure.

Full pipeline inspection exposed an additional pixel ownership issue: passing the
thumbnail directly to Vision's fast recognizer removed graph dots and labels from
subsequent crops. Detection now receives independently rendered pixels. A fixture
regression snapshots the original thumbnail bytes and verifies they stay equal.
Final visual inspection of `tmp/visual-import-live-if1p57b5/text-refined-figure.png`
confirms the entire caption, panel titles, dots, arrows and internal labels are
preserved. The artifact is produced through the actual figure extractor with a
fixed box reproducing Claude's clipped result, without another remote model call.

Verification commands (fixture variables point to the private page-8.jpg and PNG):

- `KAIBA_TEST_FIGURE_PAGE=... KAIBA_TEST_FIGURE_OUTPUT=... mise exec -- swift test --filter 'DocumentFigureTextBoundsTests|DocumentVisualProviderTests|DocumentPageImportTests'`: 15 passed, 1 unrelated real-PDF test skipped before the pixel isolation fix.
- `KAIBA_TEST_FIGURE_PAGE=... KAIBA_TEST_FIGURE_OUTPUT=... mise exec -- swift test --filter 'DocumentFigureTextBoundsTests|DocumentVisualProviderTests'`: final 7 tests passed, including actual fixture and source-pixel preservation.
- `mise exec -- swiftlint lint --quiet`: existing three warnings only.

Live server tagging check: imported the saved page with maximumOCRPages=0,
started a private loopback server with automatic tagging enabled and isolated
Codex subscription, then called recognizeDocumentPage over HTTP. OCR returned
accepted/ok. Its note-updated tagging outbox row reached dispatched with no error,
but neither notebook nor note had the requested graph-algorithms assignment.
The assertion failed; do not treat successful dispatch as proof of tag assignment.
A no-proposal result or filtered proposal remains possible; the response itself
was not captured. Private evidence: server-tagging-config.json,
server-tagging-evidence.json and server-tagging-log.txt under the fixture directory.
The wrapper stopped the server in finally. Next investigate with a semantically
matching registered time-series tag and/or a capturing deterministic gateway to
separate provider judgment from dispatch/persistence behavior. Full server tagging
verification and Claude server isolation remain incomplete.


## Verified server tagging and Claude document subscription

The follow-up live tagging check registered the semantically relevant `time-series`
tag and imported page 8 with zero OCR pages and an explicit Time Series Prediction
title. CLI post-import tagging assigned that tag to the notebook while the note
remained untagged. HTTP manual OCR then completed the note, and the server's
isolated Codex action assigned `time-series` with AI provenance. The action reached
`dispatched`. The model also proposed additional tags despite the prompt's request
not to create tags; prompt instructions are not a hard proposal allow-list. This
proves the server lifecycle and persistence, not guaranteed provider obedience.
Evidence: server-timeseries-evidence.json/config/log under the private fixture
root. A new deterministic dispatcher regression verifies no provider call for a
pending page and configured prompt/text/tag assignment after OCR. Nine focused
tagging/dispatcher tests passed. Test servers were stopped in finally blocks.

Added `import.allowClaudeSubscription` (off unless true) for server document
providers. The factory requires this opt-in independently of Codex settings.
`ClaudeSubscriptionExecution` supplies only CLAUDE_CODE_OAUTH_TOKEN plus private
HOME, CLAUDE_CONFIG_DIR, TMPDIR, CLAUDE_CODE_TMPDIR and XDG_RUNTIME_DIR, with the
existing macOS filesystem sandbox and tools/hooks/MCP/session persistence disabled.
The gateway receives stream-json image bytes, not a filesystem Read instruction.

Live failure diagnosis found two concrete path problems: the gateway's Homebrew
symlink was not its permitted physical executable, and Claude tried to use shared
/tmp/claude-501 despite TMPDIR. Resolving the gateway path and setting Claude's
supported private runtime/temp overrides fixed both. A temporary direct-Claude
diagnostic isolated the startup error; that diagnostic was removed. Product
processing and the retained live test invoke Claude only through agent-gateway.

Verification:

- `KAIBA_TEST_CLAUDE_IMAGE=... mise exec -- swift test --filter ClaudeSubscriptionExecutionTests`: 3 passed, including authenticated sandbox image processing.
- Corrected live HTTP `recognizeDocumentPage` on the previously pending fixture returned accepted/ok and persisted 2,114 OCR characters using Claude subscription isolation. Evidence: server-claude-corrected-evidence.json and server-claude-corrected-log.txt. No additional physical PDF page was processed.
- `mise exec -- swift test --filter 'Document|ClaudeSubscriptionExecutionTests|AgentGatewayServedSafetyTests|KaibaServerRuntimeTests'`: 109 XCTest cases, 4 environment-gated skips, no failures; 6 Swift Testing cases also passed.
- Earlier provider/isolation focused run: 9 passed. Opt-in/served/Codex subscription regression: 6 passed.

Remaining work is the final full-objective audit, remaining real-world layout/photo
coverage and GUI entry-point/visual verification. Do not mark the goal complete
based on these transport and lifecycle checks alone.

Final subscription SwiftLint run completed with the same three existing warnings; `git diff --check` passed.


## UI document upload

Added DocumentImportForm to NewNotebookEditor and importDocument to the client,
GraphQL contract/router and service. Controls cover file/title/zero/N/all OCR,
busy state and validation. The server uses configured providers, creation actions
and execution admission; staging is private and cleaned up. Limits are 1 MiB and
1...500 PDF pages, with larger files supported by CLI. The mutation is not
idempotent, so the UI warns to check notebooks before retrying uncertain results.

Verification:

- `mise run web:check`: final 167 Bun tests, 53 DOM tests, typecheck, lint and build passed.
- `mise run tauri:check`: passed; no Rust changes.
- `mise exec -- swift test --filter 'DocumentUploadGraphQLTests|NoteGraphQLSchemaInventoryTests'`: final 3 passed. Covers exact stored originals, zero OCR, later OCR, invalid path/payload/limit rejection and unchanged notebook count on rejection.
- `mise exec -- swiftlint lint --quiet`: same three existing warnings. `git diff --check` passed.
- Live HTTP upload of today's 340,593-byte 10.1.1.69.8949.pdf with maximumOCRPages=0 returned accepted/ok: 25 notes, 25 originals, 25 pending pages, no OCR. Evidence: tmp/visual-import-live-if1p57b5/upload-evidence.json and upload-server-log.txt. The server stopped in finally. This live run preceded the added 500-page PDF preflight; focused tests passed afterward.

Initial regression failures were the explicit schema field inventory and a text
notebook test selecting the first form globally. Added the inventory entry and
scoped that test to its named form, retaining title-free text editing and stable
retry-key assertions. New DOM tests cover import controls, duplicate-submit
suppression while busy, upload size rejection and uncertain-response messaging.

Browser availability recheck returned agent.browsers.list() == []. No interactive
visual test is claimed; retain that distinction in the final requirement audit.


## Final layout coverage and audit

The selected page 3 from today's 考える技術.pdf (268 pages) was rendered as a
single-image fixture. Claude OCR timed out; Codex succeeded with 647 characters,
starting at the rightmost column, and persisted ja/vertical/right document
analysis. Evidence: japanese-codex-evidence.json and japanese-codex-import.txt in
the private fixture directory. Only the selected page was OCRed, not the book.

A text-free bar-chart fixture generated in AppKit was classified isDocument=false,
with unknown language/writing/binding, and imported as one figure Markdown image
with empty recognized text. Evidence: nontext-evidence.json. A separate captioned
graph was classified as document content and produced figures, so no universal
classification-accuracy claim is made.

Created design-docs/document-import-completion-audit.md with requirement-by-
requirement current-source and test evidence. README now links the configuration
and shows limited/all/manual OCR commands. Full `mise run check` initially failed
on an existing PID-file readiness race: the process test observed file creation
before the PID contents were written. It now waits for a parsed positive PID and
cancels its task on every exit. The focused regression passed. The orphaned test
process group was verified by PID, group and fixture script path before cleanup;
the old runner then returned failure normally. A fresh full check is running.


## Completion

Final `mise run check` passed (exit 0): 867 XCTest cases with 6 optional fixture
skips, 123 Swift Testing cases, 167 Bun tests, 53 DOM tests, SwiftLint and web/Tauri
checks. A concurrency-sensitive HTTP timing assertion failed in the preceding
run, then passed alone in 0.119 seconds and in the final full suite without a
threshold change. The earlier PID-file test race was fixed, not suppressed.

The completed requirement audit is design-docs/document-import-completion-audit.md.
File hashes, physical page/origin mapping, SQLite integrity, foreign keys and
search index health were also verified on private live stores. Main PDF remains
25 originals with only pages 1, 8 and 12 processed and 22 pending. Japanese layout
and a non-text graphic have separate successful evidence. Browser visual testing
was unavailable; functional DOM behavior and actual image artifacts were checked.
No required implementation work remains; configuration and usage are documented
in README and the document-import specification.
