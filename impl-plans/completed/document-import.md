# Document Import Pipeline

**Status**: Completed
**Design Reference**: `design-docs/specs/document-import.md`

## Purpose

`kaiba import <file>` converts a source document to markdown with the
external `anydoc-swift` CLI and stores it as an imported-material
notebook with per-H1-section notes and the original file attached as a
`source-document`.

## Deliverables

- [x] `Sources/AppCore/DocumentConverting.swift` (seam + anydoc CLI converter)
- [x] `Sources/AppCore/MarkdownHeadingSplitter.swift`
- [x] `Sources/AppCore/NoteService+DocumentImport.swift`
- [x] `Sources/AppCore/CommandImport.swift` + `Command.swift` routing
- [x] `KaibaConfiguration` `import.anydocPath`
- [x] Unit tests in `Tests/AppCoreTests/`

## Tasks

### TASK-001: Spec (document-import.md)

**Parallelizable**: Yes

**Completion Criteria**:

- [x] `design-docs/specs/document-import.md` accepted (DI1-DI5)

### TASK-002: Converter seam and heading splitter

**Parallelizable**: Yes

**Completion Criteria**:

- [x] `DocumentConverting` protocol; envelope parsing is a pure function over `Data`
- [x] Typed errors `.toolNotFound` / `.unsupported(kind,message)` / `.failed`
- [x] Splitter: H1 split, H2 fallback, single-note fallback, preamble page, fenced-code aware, 400 KiB recursive guard
- [x] Unit tests for both

### TASK-003: Import service

**Parallelizable**: No (after TASK-002)

**Completion Criteria**:

- [x] `importDocument` creates notebook kind `imported-material` with meta JSON source record
- [x] Original file stored and attached with role `source-document`
- [x] Tests with stub converter assert kind, page numbers, meta, attachment

### TASK-004: CLI command and config

**Parallelizable**: No (after TASK-003)

**Completion Criteria**:

- [x] `kaiba import <file> [--title] [--kind-tag] [--anydoc-path]`
- [x] `import.anydocPath` decoded from config.json
- [x] Actionable stderr for tool-not-found and unsupported

### TASK-005: Verification

**Parallelizable**: No

**Completion Criteria**:

- [x] `mise run build` / `mise run test` / `mise run lint` clean
- [x] Manual smoke: import a PDF, inspect via `kaiba notebook show` / `kaiba show`

## Progress Log

- 2026-08-12: Plan created; spec accepted.
- 2026-08-12: Implemented, tested (swift build/test/lint clean), and completed.
