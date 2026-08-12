# Document Import

## Status

Accepted

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
- `scripts/build-anydoc-native.sh` — resolves the pinned package and stages
  its Rust FFI for host or cross-compiled builds.

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
