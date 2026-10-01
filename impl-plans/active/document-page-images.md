# Document Page Images: Implementation Plan Index

**Status**: Ready for implementation
**Design Reference**: `design-docs/specs/design-document-page-images.md` (DP1-DP10, I1-I6)
**Related design updates**: `design-docs/specs/document-import.md`,
`design-docs/specs/ai-agent-integration.md` (AI12), `design-docs/specs/note-retrieval-fusion.md`,
`design-docs/user-qa/document-page-images.md`

## Purpose

PDF and standalone-image imports must be read as deterministic page images only.
OCR text becomes hidden search/RAG text (`notes.search_text`). Agent chat on a page
sends the page image plus retrieved OCR text. Every other import format and all
normal notes stay exactly as they are today.

This file is the index and the shared contract. Each plan file below is owned by
one implementation worker. A worker edits only its own plan file's Progress Log.
This index is edited only during serial reconciliation (P10).

## Plans and waves

| Wave | planId | Plan file | dependsOn |
| --- | --- | --- | --- |
| 1 | P1-storage-contract | `impl-plans/active/document-page-images-p1-storage-contract.md` | - |
| 1 | P2-agent-image-contract | `impl-plans/active/document-page-images-p2-agent-image-contract.md` | - |
| 1 | P9-web-reader | `impl-plans/active/document-page-images-p9-web-reader.md` | - |
| 2 | P3-import-ocr-pipeline | `impl-plans/active/document-page-images-p3-import-ocr-pipeline.md` | P1 |
| 2 | P4-retrieval-consumers | `impl-plans/active/document-page-images-p4-retrieval-consumers.md` | P1 |
| 2 | P5-undo-snapshots | `impl-plans/active/document-page-images-p5-undo-snapshots.md` | P1 |
| 2 | P6-page-chat-context | `impl-plans/active/document-page-images-p6-page-chat-context.md` | P1, P2 |
| 2 | P7-gateway-image-transport | `impl-plans/active/document-page-images-p7-gateway-image-transport.md` | P2 |
| 2 | P8-toolloop-image-transport | `impl-plans/active/document-page-images-p8-toolloop-image-transport.md` | P2 |
| 3 | P10-integration-contracts | `impl-plans/active/document-page-images-p10-integration-contracts.md` | P3, P4, P5, P6, P7, P8, P9 |

The dependency graph is a DAG with three waves. Wave-2 plans have disjoint
`writePaths`. Shared contracts, meaning the `search_text` column, the
retrieval-text helpers, `AgentInvocationImage` and the `ToolLoopModelRequest`
image fields, are pinned in wave 1.

## Pinned cross-plan contracts (owned by wave 1; do not redefine)

P1 owns these, in `Sources/AppCore/NoteRetrievalText.swift`, which is new:

- `func noteRetrievalText(bodyMarkdown: String, searchText: String?) -> String`.
  If `searchText` is nil or empty, return `bodyMarkdown`. If `bodyMarkdown` is
  empty, return `searchText`. Otherwise return `bodyMarkdown + "\n\n" + searchText`.
- `func noteSearchText(_ noteId: NoteID, in database: SQLiteDatabase) throws -> String?`
- `func noteSearchTexts(_ noteIds: [NoteID], in database: SQLiteDatabase) throws -> [NoteID: String]`.
  The result contains only rows whose `search_text` is not NULL.
- `func isDocumentPageMetaJSON(_ metaJSON: String?) -> Bool`. It returns true
  exactly when `NoteService.importedPageMetadata` would succeed.
- `extension NoteService { static func isDocumentPageNote(_ note: Note) -> Bool }`
- `func documentPageTextMigration(bodyMarkdown: String, searchText: String?, metaJSON: String?) -> (bodyMarkdown: String, searchText: String?)`.
  If the meta JSON describes a page and `searchText` is nil, return
  `("", bodyMarkdown)`. Otherwise return the inputs unchanged.
- `extension NoteService { func retrievalText(for note: Note) throws -> String; func retrievalTexts(for notes: [Note]) throws -> [NoteID: String] }`
- `NotePageDraft.searchText: String?`. The init parameter defaults to `nil`.
- Column `notes.search_text TEXT` is nullable and is the last column of the
  table. `NoteStoreSchema.currentVersion == 22`.

P2 owns these, in `Sources/AppCore/AgentInvoking.swift` and `Sources/AppCore/ToolLoopModelClient.swift`:

- `public struct AgentInvocationImage: Equatable, Sendable { public var data: Data; public var mediaType: String }`
  with `public static let maximumBytes = 3_750_000` and
  `public static let allowedMediaTypes: Set<String> = ["image/jpeg", "image/png", "image/gif", "image/webp"]`.
- `AgentInvocationRequest.images: [AgentInvocationImage]`. The init parameter is
  `images: [AgentInvocationImage] = []`, placed last.
- `AgentInvocationRequest.imageFallbackNotice`, a static String, equal to
  "The page image could not be sent to this model; answer from the recognized text."
- `func droppingImagesWithNotice() -> AgentInvocationRequest`. If `images` is
  empty, it returns `self` unchanged. Otherwise it returns a copy with
  `images = []` and the notice appended to `contextMarkdown`, separated by a
  blank line. If `contextMarkdown` is nil or empty, the notice becomes the
  context.
- `ToolLoopModelRequest` gains `var images: [AgentInvocationImage] = []` and
  `var imageMessageIndex: Int? = nil`. The images belong to the `.user`
  message at that index.

## Shared execution rules for every worker

1. **Same branch and directory**: all workers run on branch `main` in the same
   working directory. Workers do not run `git` write commands (`add`, `commit`,
   `stash`, `checkout`, `reset`, `rebase`). They do not create worktrees or
   branches. Commits happen only in serial reconciliation.
2. **Fresh reads and drift detection**:
   - Before each edit, read the target file fresh.
   - Record `shasum -a 256 <file>` before and after the edit in your Progress
     Log.
   - If the pre-edit hash differs from the hash you recorded after your previous
     edit, another worker changed the file. Stop editing that file, re-read it,
     and re-apply only your intended change. Never revert someone else's lines.
3. **Intent snapshot**: write a one-paragraph intent snapshot for your plan into
   your Progress Log before the first edit.
4. **Ownership**:
   - Edit only your `writePaths`.
   - `sharedPaths` are read-only for you unless the plan says otherwise.
   - Never touch `.riela/`, this index, other plans' files, lockfiles, or any
     file outside your write paths.
   - Never run broad formatters.
5. **Swift files**: keep every Swift file under 1000 lines (`wc -l`). Run
   `mise run lint` (swiftlint) after Swift edits and report its exit code.
6. **Evidence**:
   - Tests need the anydoc pkg-config path. Run `mise run build` once, then run
     tests as:
     `PKG_CONFIG_PATH="$PWD/.build/anydoc-native/host/pkgconfig" mise exec -- swift test --filter <Filter> 2>&1 | tee tmp/document-page-images/<planId>/<name>.log; echo "exit=${PIPESTATUS[0]}"`
   - Record the exit code and the log path. A truncated log or a nonzero exit is
     not a pass.
   - The verification commands in every plan use bash syntax (`PIPESTATUS`) and
     must be run under bash (for example `bash -c '<command>'`), because the
     default shell is zsh, where `PIPESTATUS` is undefined. A blank `exit=`
     value is not evidence; re-run the command under bash. Create the log
     directory first with `mkdir -p tmp/document-page-images/<planId>` because
     `tee` does not create directories.
   - Concurrent workers share one `.build` directory. SwiftPM serializes
     concurrent builds on the `.build` lock, so waiting on that lock is normal.
     A failure in a file inside your own `writePaths` is always yours to fix. If
     a build or test run fails only because of a compile error in a file outside
     your `writePaths` that another in-flight plan owns, do not edit that file.
     Wait a few minutes and re-run the same command (up to 3 attempts). If it
     still fails, record the failing file, the error line, the owning plan and
     the log path in your Progress Log, and mark that verification item
     "blocked by peer <planId>", not passed. P10 re-runs it during serial
     reconciliation.
   - Run web checks with `mise exec -- bun ...` inside `web/`.
7. **Secrets**:
   - No emojis anywhere.
   - No secrets, downloaded PDFs or real recognized text in commits.
   - Test fixtures must be generated in code or be synthetic strings.
   - Docs and tests must not contain machine-local absolute home-directory
     paths. The pre-commit hook rejects them.

## Serial reconciliation and finalization (P10 owner only)

- P10 runs after all wave-2 plans report done. It performs these steps:
  1. Re-read every plan's Progress Log.
  2. Run the full suite.
  3. Fix only cross-plan integration breaks, serially.
  4. Update this index's status.
- Archiving plans to `impl-plans/completed/` is out of scope for the
  implementation workers. It happens at workflow finalization.

## Completion criteria (whole feature)

- [ ] All ten plans are marked done in their Progress Logs, with evidence logs.
- [ ] `grep -rn "Page display mode" web/src` returns no matches.
- [ ] `PKG_CONFIG_PATH=... mise run check` exits 0. Log path recorded in P10.
- [ ] `git status --short` shows no change to `.riela/` and no unrelated files.

## Progress Log

- 2026-10-01: Index and plans created from the accepted design (Step 3 accepted, no open high/mid findings).
