# Document Import

## Status

Accepted

## Summary

`kaiba import` converts a source document (PDF, Word, PowerPoint, Excel,
OpenDocument, RTF, EPUB, CSV) to markdown with the external `anydoc-swift`
CLI and stores the result as an imported-material notebook: one note per
top-level markdown section, with the original file attached to the
notebook as a `source-document` role file. The pipeline lives entirely in
`AppCore` behind a `DocumentConverting` protocol seam, so tests never
spawn the real binary.

## Design Decisions

- **DI1 — Conversion by spawning the `anydoc-swift` CLI with `--json`.**
  anydoc-swift links a locally built Rust static library whose artifacts
  are gitignored, so a SwiftPM git dependency cannot link from a clean
  checkout, and kaiba keeps its zero-external-SwiftPM-dependency policy
  (K3). The CLI's `--json` envelope is a versioned machine contract:
  `{"schemaVersion":1,"status":"ok","format":"pdf","markdown":...}` on
  success (exit 0) and `{"status":"error","error":{"kind":...,
  "message":...}}` on conversion failure (exit 1); usage errors exit 2.
  The binary path resolves from `import.anydocPath` in
  `config.json`, else `anydoc-swift` on `PATH`. Rejected: SwiftPM path
  dependency (couples every dev/release machine to a sibling checkout,
  a Rust toolchain, and `PKG_CONFIG_PATH`).
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
  `.toolNotFound` (binary missing: names the path tried and points at
  `import.anydocPath`), `.unsupported` (anydoc's error kind/message
  verbatim — covers scanned PDFs, since anydoc has no OCR),
  `.failed` (everything else). Non-UTF8 or oversized converter output is
  a failure, never a partial import.

## Components

- `Sources/AppCore/DocumentConverting.swift` — `DocumentConverting`
  protocol, `DocumentConversionResult` (markdown, source format, tool
  version), `DocumentConversionError`, and `AnydocCLIDocumentConverter`
  (Process spawn + envelope parsing; parsing is a pure function over
  `Data` for testability).
- `Sources/AppCore/MarkdownHeadingSplitter.swift` — pure
  markdown-to-`[NotePageDraft]` splitter implementing DI2.
- `Sources/AppCore/NoteService+DocumentImport.swift` —
  `importDocument(...)`: convert, split, create notebook (meta JSON
  records `{"source":{"originalFilename","format","tool","toolVersion",
  "importedAt"}}`), attach original file.
- `Sources/AppCore/CommandImport.swift` — `kaiba import <file>
  [--title <t>] [--kind-tag <tag>] [--anydoc-path <p>]`.
- `KaibaConfiguration` gains optional `import.anydocPath`.

## Configuration

```json
{
  "import": { "anydocPath": "/opt/homebrew/bin/anydoc-swift" }
}
```

Absent configuration falls back to `PATH` lookup. No secrets involved.

## Verification

- Unit: splitter (H1/H2/no-heading/fenced-code/oversize), envelope
  parsing fixtures (ok, error kinds, malformed JSON), import service
  with a stub converter (notebook kind, page numbering, meta JSON,
  source-document attachment).
- Smoke: install anydoc-swift, `kaiba import sample.pdf`, then inspect
  via `kaiba notebook show` / `kaiba show` / `kaiba file`.

## Future Work

- Browser upload + server-side import (chunked upload design needed).
- Page-aware import if anydoc-swift exposes per-page markdown
  (pdf-inspector upstream already computes it).
- OCR fallback for scanned PDFs.
