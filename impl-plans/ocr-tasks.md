# Page OCR action and task list

- [x] Trace the empty-text button and separate recognition from opening Analysis.
- [x] Share a deduplicated OCR queue between page text and Analysis controls.
- [x] Add status/error/retry/cancel handling and account-session invalidation.
- [x] Show current OCR and remaining active tasks in the header.
- [x] Add task-list route, source navigation, and jump-back behavior.
- [x] Refresh text on completion and explain processed blank pages.
- [x] Cover queue lifecycle and navigation with focused integration tests.
- [x] Verify actual local OCR and persisted output against the API.
- [x] Complete final web/Tauri checks and remove the temporary validation notebook.

## Follow-up: explicit reruns and tag extraction

- [x] Add a forced OCR option through service, GraphQL, CLI, queue, and controls.
- [x] Make OCR/Translated split buttons with action lists and enabled views.
- [x] Reproduce the linked page's poor OCR and unavailable AI runtime.
- [x] Explain unusable OCR and unavailable tag extraction visibly.
- [x] Include proper names and book titles in the extraction prompt.
- [x] Verify repeated OCR, menus, task history, and extraction errors in Brave.
- [x] Run Swift tests (26, one skipped), SwiftLint (two existing warnings),
  web checks (196 Bun and 180 Vitest tests), and Tauri checks.

Actual entity extraction for the linked vertical-Japanese page requires a suitable
OCR engine and an AI agent configuration; neither has been silently substituted.
