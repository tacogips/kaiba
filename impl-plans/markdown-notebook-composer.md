# Markdown notebook composer implementation

- [x] Replace the bare New Notebook form with a writing workspace and note outline.
- [x] Parse first-line notebook titles and standalone `<--->` note boundaries.
- [x] Render separate previews and add notes through the same source syntax.
- [x] Save ordered notes through atomic, idempotent notebook ingestion.
- [x] Cover parsing, transport payloads, preview, and retries with focused tests.
- [x] Verify native browser creation, reload, exact SQLite records, and search.
- [x] Run web and Tauri checks and remove temporary validation data.

See `design-docs/specs/markdown-notebook-composer.md` for behavior and validation.

## Automatic save follow-up

- [x] Remove explicit creation and save after three quiet seconds from first input.
- [x] Keep typing active, serialize writes, retry immutable snapshots, and retain
      the save queue across view changes.
- [x] Add atomic existing-notebook reconciliation and stable note IDs on replay.
- [x] Show upper-right save status and a notebook menu with deletion.
- [x] Validate single-character creation, subsequent multi-note updates, and menu.
