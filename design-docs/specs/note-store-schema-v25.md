# Note store schema v25: explicit page versions and ERD-generated DDL

User decisions, 2026-10-24:

- Review the database design after the PDF reader / page-linked AI change
  (`pdf-original-viewer.md`), especially how a page switches between its
  Original, OCR and Translated versions.
- Those three versions are a closed set. There is no user-defined or generic
  "note type" mechanism; a fourth version is added by adding its definition
  (schema, enum case, API field) explicitly.
- Local data may be discarded and backward compatibility is not required.
- The schema is authored as a nodetto ERD and the SQLite DDL is generated from
  it.

## Review findings (schema v24)

1. **Page identity lived in JSON.** `notes.meta_json.documentPage` carried
   the physical page number, OCR state (free string), origin file id (no
   foreign key), origin media type, text source, text extraction mode and the
   page analysis. Integrity checks (does the origin file exist and belong to
   the notebook?) were re-implemented in Swift, and the web client parsed the
   same JSON independently. `pendingBodySHA256` was never set.
2. **The OCR version was a generic column.** `notes.search_text` existed only
   for document pages, but every note carried it and every reader had to
   remember to merge it.
3. **Translations were whole notebooks.** Each translation request created a
   `notebook-kind:translation` notebook (title `X [lang]`); translating page 3
   and then page 4 created two notebooks. Translated notes pointed back at
   their source with `meta_json.kaibaTranslation.sourceNoteId`: no foreign key,
   no index (every lookup scanned all notes with `json_extract`), nothing
   stopped two outputs per page and language, and deleting a source left
   orphans. The run state (status, page range, continuation cursor, revision)
   was also notebook JSON.
4. **Upgrade code accumulated.** v19-v24 upgrade paths and the
   `documentPageTextMigration` shim stayed in the hot `prepare` path.
5. **No schema source of truth.** The DDL was hand-written Swift strings
   spread over two files.

## Page versions

`DocumentPageVersionKind` is the closed enum `original | ocr | translated`.
Each case has dedicated, typed storage:

| Version | Storage | Key |
| --- | --- | --- |
| `original` | `document_pages.origin_file_id` + `page_number` (the retained PDF page, or the page image) | `document_pages.note_id` |
| `ocr` | `document_pages.text`, `text_status`, `text_source` (native PDF text or OCR) | `document_pages.note_id` |
| `translated` | `note_translations.body` | `(note_id, language)` |

The source page note (`notes`) stays the anchor for memos, tags, links, AI
discussion and navigation; versions never create notes or notebooks of their
own. Adding a version means: a new enum case, its storage (column or table)
in the ERD, and its API field. Nothing is registered at runtime.

### `document_pages`

One row per physical page of an imported document (`ON DELETE CASCADE` from
`notes`).

- `origin_file_id` references `files`; `UNIQUE (origin_file_id, page_number)`
  keeps one page row per physical page of a retained original.
- Whether the original is a PDF page or a page image follows from the
  original's `files.media_type`; it is not stored twice.
- `text_extraction_mode` is `prefer-pdf-text` / `ocr-only` for PDFs and NULL
  for images.
- `text_status` is `pending` / `complete`; `text_source` is `pdf-text` / `ocr`
  and is set exactly when the text is complete (CHECK).
- `analysis_json` keeps the page analysis (language, writing mode, binding,
  title); it is descriptive data that no query filters on.

### `note_translations`

One translated body per source note and language, `PRIMARY KEY (note_id,
language)`, `ON DELETE CASCADE` from `notes`. `source_sha256` is the hash of the
source text the translation was produced from; a translation whose hash no
longer matches the source is stale and is re-translated by the next job.
Translations apply to any note (the CLI can translate ordinary notebooks); the
document reader exposes them as the Translated version, and every translation
is readable through `noteTranslations(noteId)` and `kaiba translations
<note-id>`. Translations are indexed in the
source note's FTS row (`translations` column), so a search in the target
language finds the source page.

### `translation_jobs`

A translation request is a job row instead of a notebook: source notebook,
target language, optional inclusive page range, status
(`pending/completed/failed/cancelled`), error, continuation cursor (`ON DELETE
SET NULL` note reference) and the source revision captured at the start of the
current pass. The auto-action event carries `translationJobId`. Completion
keeps the existing guarantees: a pass completes only when the source
notebook revision did not move.

`notebook_revisions` (renamed from `notebook_translation_revisions`) is now a
per-notebook counter incremented by every recorded notebook change, even when
action history is suppressed, and by page OCR completion. It previously stored
the action-log sequence, which suppressed history never advanced and which
OCR completion did not touch. Storing a translation does not advance it, so a
job never invalidates itself.

## Removed

- `notes.search_text`, `meta_json.documentPage`, `meta_json.kaibaTranslation`.
- `notebook-kind:translation` and translation notebooks.
- All v19-v24 upgrade code. Any store whose newest schema version is below 25
  is rejected with `unsupportedLegacyVersion`; the store must be recreated.

## ERD and DDL generation

- Source: `schema/note-store.erd.jsonl` (nodetto document, one ERD page).
- Generated SQL: `schema/note-store.sqlite.sql` via
  `nodetto-cli ddl schema/note-store.erd.jsonl --dialect sqlite --strict`.
- Generated Swift: `Sources/AppCore/NoteStoreSchemaDDL.generated.swift`
  (one string per statement) written by `scripts/generate-note-store-schema.py`.
- `mise run schema:generate` regenerates both; `mise run schema:check` fails
  when either is stale (needs `nodetto-cli`, so it runs locally). A Swift test
  checks that the generated Swift statements equal the committed `.sql` file,
  so CI on Linux catches hand edits.
- Not expressible in an ERD and kept in Swift: the contentless FTS5 table
  `note_fts` and seed rows.
- nodetto 0.5.5 added what the kaiba ERD needed: SQLite `STRICT` /
  `WITHOUT ROWID` table options, table and column comments, and
  self-referencing relations through `connect`.
- A fresh store executes the generated DDL once, inside one transaction, and
  records version 25; an existing v25 store skips DDL.

## Not changed (reviewed)

- Chat conversation subjects (`meta_json.kaibaChat.subjectNoteId`) remain
  JSON. They predate this change and are owned by the chat-branch design;
  promoting them is a separate change.
- `note_files` / `notebook_files` attachment rows are kept for the original
  file; `document_pages.origin_file_id` adds the integrity link and storage
  GC also treats it as a reference.
