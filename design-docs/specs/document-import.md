# Document Import

Dedicated Google Document AI OCR is supported through `google-document-ocr-gateway`;
see [configuration and authentication](google-document-ai-ocr.md).

## Status

Accepted. PDF and standalone image imports follow
[design-document-page-images.md](design-document-page-images.md) (2026-10-01):

- Page notes are read as deterministic page images only.
- OCR text is stored in hidden `notes.search_text` and used only for search and
  RAG.
- Figure extraction and `import.figures` are removed.

That spec supersedes the Text/Original reader, the figure Markdown, and the
body-digest statements in the "Page-preserving import migration" section below.
The heading-split Markdown path (DI1 to DI5, DI7) for every other format is
unchanged.

## Summary

`kaiba import` converts a source document (PDF, Word, PowerPoint, Excel,
OpenDocument, RTF, EPUB, CSV) to markdown in-process with the `AnydocKit`
Swift library from `anydoc-swift`. Standalone PNG, JPEG, GIF, and WebP images are OCRed through the
external `agent-gateway` CLI using the configured AI vendor and model. Kaiba
stores the result as an imported-material notebook: one note per top-level
markdown section, with the original file attached to the notebook as a
`source-document` role file. The pipeline lives entirely in
`AppCore` behind a `DocumentConverting` protocol seam, so tests never
spawn the real binary.

## Design Decisions

- **DI1 — Direct `AnydocKit` Swift-library conversion.** Kaiba pins the
  `anydoc-swift` revision in SwiftPM and calls `Anydoc.convert(contentsOf:)`
  in-process. The resolved package's native builder compiles its exact Rust
  crate dependency and stages pkg-config metadata under Kaiba's `.build`.
  `mise`, Linux CI, and Homebrew cross-builds automate this prerequisite.
  There is no installed converter executable and no runtime anydoc path.
- **DI2 — Split at H1 boundaries; fallback H2; else a single note.**
  anydoc-swift returns one markdown string with no page or image
  structure, so ATX headings are the only available document structure.
  H1 sections match chapter-sized reading units for the web reader and
  its table-of-contents pane; deeper automatic splits fragment reading
  flow. Content before the first split heading becomes the first note.
  Headings inside fenced code blocks are ignored. Sections larger than
  400 KiB (safety margin under the 512 KiB GraphQL document cap) are
  recursively split at the next heading level, then at paragraph
  boundaries as a last resort.
- **DI3 — Import is CLI-only.** The HTTP server enforces a 2 MiB body
  cap with single-write responses and no multipart route; source
  documents routinely exceed it. Browser-triggered upload/import is
  explicit future work requiring a chunked upload design.
- **DI4 — Reuse the existing ingestion primitives.**
  `NoteService.createNotebookWithNotes` (the PDF/book import primitive)
  creates the notebook with kind tag `notebook-kind:imported-material`
  and per-page notes, and already enqueues `notebookCreated`/
  `noteCreated` auto-action events, so AI auto-tagging (see
  `ai-agent-integration.md`) composes with import without extra wiring.
  The original file is stored content-addressed and attached with
  `NotebookFileRole.sourceDocument`.
- **DI5 — Typed converter errors with actionable messages.**
  `.unsupported` (anydoc's error kind/message — covers scanned PDFs, since
  anydoc has no OCR),
  `.failed` (everything else). Non-UTF8 or oversized converter output is
  a failure, never a partial import.
- **DI6 — Standalone images use configured AI OCR.** Image extensions route
  to `agent-gateway client --image`; all other supported formats route to
  anydoc-swift. `import.ocr.vendor` and `import.ocr.model` are required for
  image import. The optional command path and credential environment-variable
  name follow the existing agent-gateway conventions; credential values are
  never stored in configuration. Direct API vendors use ACP image blocks.
  The Codex CLI vendor uses agent-gateway's vendor-argument passthrough to
  supply Codex's native `--image` flag because agent-gateway 0.1.2 does not
  yet forward ACP image blocks to CLI vendors. Other CLI vendors are rejected
  until their gateway image forwarding is defined.

- **DI7 — Source images are extracted by kaiba itself (2026-08-12).**
  AnydocKit yields only markdown, so import additionally runs a
  `DocumentImageExtracting` pass over the original file. For PDF
  (PDFKit/CoreGraphics, Apple platforms only): every page is rendered
  to a JPEG capture (longest side 1600 px, quality 0.8), and embedded
  raster XObjects are recovered conservatively — JPEG passthrough,
  JPEG 2000 re-encoded, and raw 8-bit RGB/Gray (directly named or
  behind an ICCBased profile, which Quartz-written PDFs use even for
  plain RGB) rebuilt as PNG; masks, CMYK, indexed and exotic spaces
  are skipped, as are images under 32 px / 1 KiB, with cross-page
  byte-identical dedupe and a 200-image cap. For EPUB (a minimal
  in-repo zip reader + XMLParser OPF/spine parse): images referenced
  by each spine document are extracted in order; EPUB is reflowable so
  it gets no page captures. Extraction failures never fail the import.
  Because notes are H1 sections with no page ground truth, pages map
  to notes via `DocumentPageNoteMapper`: a monotone first-match of
  each note's normalized title against per-page text; unmatched pages
  stay with the preceding note. Attachments use the existing
  `note_files` roles: `source-page-image` (position = 1-based page
  number) and `embedded` (position = per-note ordinal). The web reader
  lists them via the `noteFiles` GraphQL query and streams bytes from
  `GET /files/<fileId>` (bearer-authenticated like the other note
  routes; media types are sanitized against header injection).

## Components

- `Sources/AppCore/DocumentConverting.swift` — `DocumentConverting`
  protocol, `DocumentConversionResult` (markdown, source format, tool
  version), `DocumentConversionError`, and `AnydocKitDocumentConverter`.
- `Sources/AppCore/ImageOCRDocumentConverter.swift` — format router and
  agent-gateway image OCR adapter.
- `Sources/AppCore/MarkdownHeadingSplitter.swift` — pure
  markdown-to-`[NotePageDraft]` splitter implementing DI2.
- `Sources/AppCore/NoteService+DocumentImport.swift` —
  `importDocument(...)`: convert, split, create notebook (meta JSON
  records `{"source":{"originalFilename","format","tool","toolVersion",
  "importedAt"}}`), attach original file.
- `Sources/AppCore/CommandImport.swift` — `kaiba import <file>
  [--title <t>] [--kind-tag <tag>]`.
- `scripts/build-anydoc-native.sh` — resolves the pinned package. Apple builds
  consume `anydoc-swift`'s published XCFramework; Linux builds stage the
  package's native `pkg-config` fallback.

## Configuration

```json
{
  "import": {
    "ocr": {
      "commandPath": "/opt/homebrew/bin/agent-gateway",
      "vendor": "codex",
      "model": "gpt-5.6-luna"
    }
  }
}
```

No anydoc configuration is required. OCR configuration stores paths and
credential environment-variable names, never credential values.

## Verification

- Unit: splitter (H1/H2/no-heading/fenced-code/oversize), real small PDF/EPUB
  fixtures converted in-process with AnydocKit, mock image OCR through a fake gateway pinned to
  the Codex vendor and `gpt-5.6-luna`, and import service with a stub converter
  (notebook kind, page numbering, meta JSON, source-document attachment).
- Smoke: `kaiba import sample.pdf`, then inspect
  via `kaiba notebook show` / `kaiba show` / `kaiba file`.

## Future Work

- Browser upload + server-side import (chunked upload design needed).
- Page-aware import if anydoc-swift exposes per-page markdown
  (pdf-inspector upstream already computes it) — this would replace
  the DI7 title-matching heuristic with exact page-to-note mapping.
- OCR fallback for scanned or image-only pages embedded inside PDFs.
- EPUB page captures (needs an HTML renderer such as WKWebView
  snapshotting; DI7 deliberately excludes them).
- Embedded-image recovery for CMYK/indexed color spaces and
  Linux-side extraction (DI7 is Apple-platform only).

## Page-image reader (October 1, 2026)

PDF and standalone image page notes no longer carry OCR text in `bodyMarkdown`.

- **Reader**: shows only the stored origin image, which comes from the PDFKit
  raster or the uploaded image bytes. The Text/Original toggle is removed.
- **OCR storage**: OCR output from the first N pages at import, from `page-ocr`,
  and from `recognizeDocumentPage` is written only to `notes.search_text`.
  Search indexes it, and agent chat and tagging use it.
- **Figure extraction**: there is no figure extraction and no `/files/` figure
  Markdown. `import.figures` is ignored.
- **Page note bodies**: they cannot be edited. Annotate pages with comments.
- **Existing stores**: schema version 22 moves existing page bodies to
  `search_text` in one idempotent transaction.

Agent chat on a page sends the page image plus retrieved OCR text. See
[design-document-page-images.md](design-document-page-images.md) DP1 to DP10
for the behaviour, migration, budgets and provider transport. Statements below
that conflict with this section are historical.

## Page-preserving import migration (September 13, 2026)

The CLI now routes PDF and standalone image imports through kaiba's page
processor. Each physical page becomes one note with a dedicated
`source-page-image`, including pages whose OCR has been deferred. The default
OCR limit is three pages. Use `--max-ocr-pages 0` for originals only,
`--max-ocr-pages N` for the first N pages, or `--max-ocr-pages all` for every page.
`page-ocr <note-id>` completes a pending page using its stored original image.
Pending pages edited by a user are refused instead of overwritten.

`import.maximumOCRPages` accepts a nonnegative integer or `"all"`;
`import.ocrEngine` selects `"vision"` or `"agent-gateway"`. Without an explicit
engine, configured gateway OCR is used when present and local Apple Vision
otherwise. `--ocr-engine` overrides the engine for an import. Analysis is a
separate injectable provider; production analysis selection and client controls
are under implementation in `impl-plans/page-preserving-document-import.md`.

Page metadata resides in `notes.meta_json.documentPage` with `pageNumber`,
`ocrState`, `analysis`, and `originFileId`. Pending notes also carry the digest
of their initial body for edit protection. Notebook, notes and file references
commit together; downstream actions dispatch only after commit. Embedded figure
Markdown uses `/files/<fileId>` and the web reader resolves these through its
authenticated file client. Imported notebooks have a Text/Original reader with
physical page navigation and a manual OCR button. The button invokes
`recognizeDocumentPage(noteId: String!): NoteMutationPayload!`; the default server
recognizer is local Apple Vision. The server uses the same import provider configuration. Codex subscription
execution additionally requires `ai.userAgent.allowCodexSubscription=true`.
The previous heading-based path remains for Word, EPUB and other formats.

### Independent visual providers

`import.analysis` and `import.figures` accept the same gateway settings as
`import.ocr` (command path, vendor, model and credential environment-variable
name). They are independent: for example, use local Vision for text and Codex
for classification/layout/title and figure detection:

```json
{
  "import": {
    "ocrEngine": "vision",
    "maximumOCRPages": 2,
    "analysis": { "vendor": "codex", "model": "gpt-5.6-luna" },
    "figures": { "vendor": "codex", "model": "gpt-5.6-luna" }
  }
}
```

The analysis provider returns document status, language, writing mode, binding
and a visible document title. Uncertain fields stay unknown. The figure provider
returns normalized top-left bounding boxes; kaiba validates and crops the upright
page raster into PNGs, including vector graphs and scanned illustrations. On
macOS, local Vision line bounds expand crops to preserve whole intersected
labels or captions; recognition uses separate pixels and discards its text.
Analysis, OCR and visual figure detection run only within the OCR page limit.
With a visual figure provider selected, later pages defer figure extraction too;
`page-ocr` runs all configured stages and atomically stores text, analysis, figure
files and Markdown references. Without that provider, existing PDF raster-image
extraction remains the fallback. These configurations apply to CLI imports/completions and server-side manual
OCR. API providers run in the served sandbox with their selected credential;
Codex subscriptions require `ai.userAgent.allowCodexSubscription=true` and use
an isolated authentication/configuration workspace with tools disabled.

Local CLI imports also support `"vendor": "claude-code"` with an explicit
Claude model in any of `import.ocr`, `import.analysis`, or `import.figures`.
They use the installed Claude Code authentication, including subscription
authentication. Kaiba sends a structured user message containing base64 image
bytes through agent-gateway stdin and Claude's `stream-json` input. Tools,
hooks, MCP servers and session persistence are disabled for these image calls.
No image-reading filesystem tool is required. For server-side document processing,
set `import.allowClaudeSubscription=true` and provide `CLAUDE_CODE_OAUTH_TOKEN`
in the server environment. The macOS sandbox receives only that provider token,
a private home/config/temp directory and restricted runtime variables. It does
not inherit the user's Claude settings, API keys, hooks, tools or MCP servers.
Without the explicit import opt-in, served document calls reject Claude even if
Codex subscriptions are enabled. Local CLI calls keep their existing local
Claude authentication behavior.

### Automatic tags

Configure `ai.autoTag.auto` as `"on"` and configure `ai.agent` for the
agent-gateway text provider. `ai.autoTag.prompt` optionally supplies tag
registration instructions, alongside the registered tag catalog and tag class
descriptions. For example:

```json
{
  "ai": {
    "agent": {
      "backend": "agent-gateway-cli",
      "provider": "codex",
      "model": "gpt-5.6-luna"
    },
    "autoTag": {
      "auto": "on",
      "prompt": "Reuse registered research-topic tags whenever possible."
    }
  }
}
```

CLI import tags the notebook and each OCR-complete note after the import commits.
Pending pages are skipped until their OCR completes. CLI `page-ocr` tags the
completed note and refreshes notebook tags. Provider failures preserve the
import/OCR result and appear as text warnings or the JSON `taggingWarnings`
array; use `kaiba ai tag --note <id>` or `--notebook <id>` to retry. With tagging
off, these commands make no tagging provider calls. Server auto-actions and
manual tag requests use the same configured prompt; server note actions also
skip pending document pages. Existing assignment rules preserve human tags.


### UI upload

The New Notebook screen includes a PDF/image import form with optional title and
OCR-page controls. Blank uses the server limit; enter `0`, a count, or `all` to
override it. Successful import opens the new notebook in the page reader. Server
OCR/analysis/figure providers and normal creation auto-actions apply.

`importDocument(input: ImportDocumentInput!)` accepts filename, contentBase64,
optional title and optional maximumOCRPages (string), returning the notebook in
NoteMutationPayload. Uploads are limited to 1 MiB within the existing 2 MiB HTTP
envelope; macOS PDF preflight permits 1...500 readable pages. Larger documents can
use `kaiba import`. Filenames cannot carry paths, staging is private, and imports
share execution admission limits. This mutation is not idempotent: the UI does
not automatically retry uncertain responses and asks users to check notebooks.
