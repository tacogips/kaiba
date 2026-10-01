# Document import completion audit

Superseded in part (2026-10-01): the "Graph/figure crops in Markdown" and
"Original/Text page reader" rows describe behaviour that
[specs/design-document-page-images.md](specs/design-document-page-images.md)
replaces with an image-only reader, hidden OCR search text and no figure
extraction. The other rows remain a historical record of the September 13
state.

Audit date: 2026-09-13. Scope is the user's full PDF/image → analysis/OCR/figures
→ notebook/page-note → original/text reader → configurable tags workflow.
Current-state implementation and evidence were inspected, rather than inferring
completion from the implementation plan. Private document artifacts stay in tmp.

| Requirement | Implementation and evidence | Status |
| --- | --- | --- |
| Standalone PDF rendering | DocumentPageProcessor + PDFDocumentImageExtractor; live 25-page downloaded PDF stored 25 page originals via CLI and HTTP upload | Verified |
| One note per physical page | NoteService+PageImport atomically writes numbered notes and matching sourcePageImage files; exact-byte/page tests and 25-page database inspection | Verified |
| Document status, language, writing mode, binding | StructuredDocumentPageAnalyzer validates typed JSON; core layout tests; live English horizontal and Japanese vertical/right-bound metadata | Verified for demonstrated layouts; provider accuracy remains approximate |
| Extract notebook title | Analyzer title feeds notebook creation; live first-page English title “Time Series Prediction with the Self-Organizing Map: A Review”; explicit title override supported | Verified |
| Per-page OCR text | VisionDocumentPageRecognizer and converter adapter; live native Vision, Codex and Claude OCR; Japanese rightmost-column ordering checked | Verified |
| Graph/figure crops in Markdown | Independent locator + cropper + source-preserving text-bound refinement; stored embedded files linked in Markdown; real vector graph crop visually checked | Verified |
| Non-text page classification | Live text-free graphic: isDocument=false, no recognized text, one cropped figure and Markdown link (nontext-evidence.json) | Verified |
| Original/Text page reader | DocumentNotebookReader sorts physical pages, loads batches, handles buttons/arrows/swipes/page jump, displays authenticated original images; DOM tests cover mode switching, ownership of late responses, direction and OCR retry | Mechanically verified; no interactive browser available |
| Horizontal/vertical and left/right handling | Typed stored metadata, right-binding navigation, vertical-rl CSS, unknown-layout inheritance; unit/DOM direction tests and live vertical PDF evidence | Verified |
| Selectable modules and providers | Independent protocols for analysis, OCR, figure location/cropping; configuration factory; Vision and gateway adapters tested | Verified |
| Codex/Claude subscriptions through gateway | Native image argument for Codex; stream-json image content for Claude; live local calls and isolated server HTTP calls, explicit server opt-ins | Verified |
| Single-image import | Image bytes are their own original; live saved PDF rasters and unit tests; UI accepts supported images | Verified |
| Automatic notebook/note tags | Config autoTag toggle/prompt; catalog/class prompt context; post-commit CLI tagging and server creation/update outbox; live time-series notebook/note assignments with AI provenance | Verified |
| Zero/N/all OCR limits | DocumentOCRPageLimit parse/config tests; fake three-page all/zero tests; live first2/zero PDF imports; subsequent manual OCR from stored origin | Verified |
| No automatic OCR beyond N | Processor calls analysis/OCR/visual extraction only within limit; pending-state tests and 25 pending pages after zero-OCR HTTP upload | Verified |
| Manual OCR button for remaining pages | recognizeDocumentPage mutation enforces ownership, pending snapshot and body digest; reader button/failure/retry tests; live server completion via Codex/Claude | Verified |
| Test today's Downloads PDFs, few pages only | English 25-page PDF plus a single selected vertical page from today's 268-page Japanese PDF; no full-document OCR; saved private evidence listed in implementation plan | Verified |
| UI import entry point | New Notebook form, limit/title/file controls; importDocument mutation; zero-OCR HTTP PDF upload; DOM validation/busy tests | Verified mechanically/live API; 1 MiB/500-page UI limits |
| Required verification gates | Final `mise run check` exited 0: 867 XCTest cases (6 optional fixture skips), 123 Swift Testing cases, 167 Bun tests, 53 DOM tests, SwiftLint, web lint/type/build and Tauri checks | Verified |

## Practical limits and failed attempts

- Browser runtime currently returns no available browsers. No interactive visual
  walkthrough is claimed. Reader behavior is covered by DOM tests and actual
  crops/originals were inspected as images.
- AI metadata and tags are proposals, not infallible labels. Unknown binding is
  preserved when evidence is absent. A captioned graph was classified as document
  content; a text-free graphic separately exercises the false branch.
- Claude's attempt on the vertical Japanese page timed out. Codex successfully
  processed that page with vertical/right-bound/ja metadata and 647 characters
  starting at the rightmost column. No stored partial notebook was accepted as a
  success for the timed-out attempt.
- Server time-series tagging persisted the registered tag but also proposed new
  tags despite a restrictive prompt. Prompt wording is not a hard tag allow-list.
- UI uploads are limited to 1 MiB/500 PDF pages; larger files can use the CLI.
  Upload retries are not idempotent; uncertain failures tell users to inspect
  notebooks before retrying. No automatic retransmission is performed.
- The first full check hit a PID-file handshake race in an existing gateway
  cleanup test. It waited for file existence instead of parsed PID contents.
  The test now waits for a valid PID and always cancels its task; the focused
  regression passed. Its orphaned fixture group was positively identified and
  terminated so the completed test runner could release its output pipe.


Final private store integrity verification matched every origin file to its note
metadata and SHA-256 digest: 25 originals/22 pending in the main PDF fixture,
25 originals/25 pending in the zero-OCR upload fixture, one Japanese page, and one
non-text graphic. SQLite quick_check and foreign_key_check passed for each.
`kaiba db check` on the main fixture reported healthy storage/search indexes,
zero unreferenced files, zero missing search rows and zero foreign-key violations.
Evidence: tmp/visual-import-live-if1p57b5/final-store-integrity.json.


## Completion decision

The requested functional workflow is implemented and verified by current source,
unit/DOM/integration tests and live imports of today's PDFs. No required
implementation work remains. The unavailable interactive browser walkthrough is
an explicitly disclosed verification limit, not a claim of a visual test; page
navigation, mode switching, layout selection and OCR-button behavior have direct
DOM coverage, and original/cropped image artifacts were visually inspected.

Final full check: /tmp/kaiba-full-check-verified.log, exit 0, 86.52 seconds.
SwiftLint retains three pre-existing warnings. The incidental HTTP timing test
was not weakened: it passed alone and in the final full suite. Source files
edited for this task remain below 1,000 lines. `git diff --check` is clean.
