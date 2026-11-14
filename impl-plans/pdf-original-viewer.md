# PDF reader implementation and verification

User decisions, 2026-10-24: retain original PDFs, use temporary raster data only for OCR, prefer native PDF text by default with a configurable OCR-only policy, and keep all versions and discussion scoped to physical source pages. See [the specification](../design-docs/specs/pdf-original-viewer.md).

## Implementation

- Store one PDF attachment per notebook; source page notes reference its file ID and physical page number. Render OCR input only when required and discard it after use.
- Extract usable PDF text before OCR under `prefer-pdf-text`; allow `ocr-only` as a Settings default and per-import/CLI override. Store plain text with paragraph/line breaks in the searchable-text field.
- Use PDF.js for authenticated viewing and reuse the loaded document while navigating its pages. Keep Original/OCR/Translated version selection in the compact header, alongside editable title, page tags, translation action, and searchable-state icon.
- Keep navigation, current-page position, page jump and original-PDF zoom in the footer. Support binding-aware page-edge/arrow navigation and Ctrl+U/Ctrl+D while respecting editable fields and dialogs.
- Centralize reader jumps in return-aware navigation with an in-memory maximum of 500 prior locations and a visible Back control.
- Provide a tag occurrence popup across notebooks. Keep add/edit/remove separate from tag navigation. Use ontology catalog classes for free-text typed tags, including Date/Name/Place, preserving existing tag classes and hierarchy.
- Request translations for the current page, a page range, or all pages. Persist linked per-page translations; switch versions by language without changing the source-page memo context or displaying stale previous-page translations.
- Place contextual notebook/page AI discussion in the footer. Keep tags, searchable-text actions, document/file information, and saved conversations under AI in the right pane and footer; merge file information into Analysis.
- Preserve standalone images and previously imported raster pages.

## Verification

- Swift tests: native-text precedence and OCR fallback/override, deferred OCR, physical page order, original byte integrity, no persisted PDF raster images, renamed titles, translation links/scope, and ontology classes.
- Web integration tests: PDF document lifetime and fetch reuse, plain extracted/translated text, stale-page rejection, source-note selection, footer positioning, keyboard/page-edge jumps, tag popup pagination/retry/close, typed-tag submission, translation range/version controls, contextual discussion, and 500-entry return history.
- Browser review: original PDF rendering, later-page jumps and Back, narrow layouts/popovers, compact icon controls, Settings return, searchable-state/Analysis interaction, tags, and version switching.
- Run SwiftLint and the repository's `web:check` and `tauri:check` gates. Record actual gate/browser outcomes in the delivery report; this plan does not claim that every check has already passed.
- Live provider translation/OCR requires a separately configured provider and explicit execution evidence. Mocked translation tests verify request/storage/UI behavior without validating live provider output.
