# PDF reader validation, 2026-10-24

The checkout runs at http://127.0.0.1:8788 using isolated storage in `tmp/pdf-validation-20261024/store-text`. It uses the local Meilisearch instance, with index prefix `kaiba-pdf-text-test-20261024`; status reports available, activated, and no pending or failing indexing work. No production note storage was used.

All 45 Downloads PDFs were imported: 2,320 physical page notes and 45 original PDF attachments. Their 382,568,311 bytes were checked against source hashes, local storage, and HTTP downloads. There are no persisted page images. Database integrity, foreign keys, and local search-index checks pass. At the import OCR budget used for this test, 2,015 pages have searchable text and 305 remain pending. The extraction breakdown is 1,992 native-text pages and 23 OCR pages. Pending pages can be recognized from Analysis. English and Japanese queries return results; a deliberately absent term returns none.

Native browser checks covered original PDF rendering, plain text switching, physical-page navigation, a 386-page document's last page and reload, zoom, title editing, page-specific tags, tag result popup and selection, Settings return, extraction defaults/import overrides, and deferred OCR. Temporary page tags and the renamed paper title were restored after checking. The additional OCR-only QA upload was deleted; the store retains only the original 45 uploads and its seeded notebook. The browser was subsequently in active use elsewhere, so the latest saved-chat footer controls were verified with integration tests rather than a further native click-through.

The final UI has compact Original/OCR/Translated controls and translation scope selection in the header, page navigation and zoom in the footer, typed ontology tags and matching-page popups, and a 500-entry shared jump-back history. The right AI tab lists saved conversations. Both that list and the footer list continue chats in the footer while keeping the source document selected. Footer discussion includes source notebook/page context, preserves drafts, and can expand for longer threads.

Commands completed:

- `mise exec -- swift build -j 4`
- `mise exec -- swift test -j 4 --filter 'AITranslation|DocumentPageTranslation|NoteStoreSchema|SchemaInventory|SchemaAuthorization|PDFText|NotebookTitle|DocumentPage|DocumentUploadGraphQLTests|GoogleDocumentAIOCRGraphQLTests|ActionHistory'`: 161 tests, zero failures, two optional real-file tests skipped.
- `KAIBA_TEST_IMPORT_PDF=/Users/taco/Downloads/10.1.1.69.8949.pdf mise exec -- swift test -j 4 --skip-build --filter 'testRealDownloadedTextPDFPersistsEveryPageWithoutRasterAttachments|testDownloadedPDFUsesNativeTextWithoutRendering'`: both optional tests passed.
- `mise run lint`: passes with three pre-existing warnings (two large tuples and an existing long test class).
- `mise run web:check`: TypeScript, 185 Bun tests, 134 integration tests, ESLint, production build passed.
- `mise run tauri:check`: Rust formatting, check, and Clippy passed.
- `git diff --check`: passed.

Translation range handling, PDF search-text input, saved per-page source associations, version retrieval, and continued conversations are covered by deterministic provider fixtures. No live AI translation was sent during validation; this isolated server has no configured agent runtime. Translation requests report that state instead of creating an undrainable job.

Machine-readable import, storage, HTTP, and search evidence is in `tmp/pdf-validation-20261024/` (`imports-text.json`, `audit-text.json`, `final-search-check.json`, and gate logs). The default PDF extraction setting was restored to `prefer-pdf-text`.
