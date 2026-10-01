# P2: Agent Image Request Contract

**planId**: P2-agent-image-contract
**Wave**: 1
**dependsOn**: none
**Status**: Implemented in the working tree, not yet accepted (resume in session-246)
**Design Reference**: `design-docs/specs/design-document-page-images.md` DP8 item 4, DP9 (fallback line), I5; `design-docs/specs/ai-agent-integration.md` AI12
**Index**: `impl-plans/active/document-page-images.md` ("Pinned cross-plan contracts" is binding)

## Resume instructions (session-246)

The code described below already exists, uncommitted, in
`Sources/AppCore/AgentInvoking.swift`, `Sources/AppCore/ToolLoopModelClient.swift`
and `Tests/AppCoreTests/AgentInvocationImageTests.swift`. The earlier runs failed
only because the P1 test target did not compile at the time (see the Progress
Log). P1 is now accepted and committed (`acceptedDependencies` in the dispatch
manifest).

1. Do not re-implement. Fresh-read each of the three files and record
   `shasum -a 256` in the Progress Log before any edit.
2. Check each item of "File-level changes" and "Tests to add" against the
   current code. Edit only to fix a mismatch, and only inside P2 `writePaths`.
   Do not touch P1 files (`NoteRetrievalText.swift`, `NoteService.swift`,
   `NoteStoreSchema*Tests.swift` and the rest of the P1 list) even if a
   compile error points there; record it as "blocked by peer
   P1-storage-contract" instead.
3. Run `mise run build` once, then run every verification command below with
   logs in `tmp/document-page-images/P2/attempt-2/` (create the directory
   first). Keep the earlier logs untouched.
4. Tick the third Done criterion only when all three focused logs show
   `exit=0` and `mise run lint` exits 0. Record each log path, its exit code
   and the post-run source hashes in the Progress Log.
5. P2 is accepted only after test-integrity and adversarial review. P6, P7 and
   P8 must not start before that.

## Intent and context

Agent chat on a document page must carry one page image. The image flows
through `AgentInvocationRequest`, the seam every chat runtime receives (see
`Sources/AppCore/AgentInvoking.swift`). The tool-loop runtime
(`UserAgentToolLoopRunner`) converts the request into `ToolLoopModelRequest`
(`Sources/AppCore/ToolLoopModelClient.swift`).

This plan adds only the data shapes and the shared fallback helper, so that P6
(producer) and P7 and P8 (transports) can work in parallel in wave 2.

## Non-goals

- Do not change any invoker, client, runner or chat code. P6, P7 and P8 do that.
- Do not change `ToolLoopMessage`. Changing its cases would break every
  exhaustive switch in parallel plans.
- Do not add images to tagging, translation, search or OCR requests.

## writePaths

- `Sources/AppCore/AgentInvoking.swift`
- `Sources/AppCore/ToolLoopModelClient.swift`
- `Tests/AppCoreTests/AgentInvocationImageTests.swift` (new)
- `impl-plans/active/document-page-images-p2-agent-image-contract.md` (Progress Log only)

## sharedPaths

none

## File-level changes

1. **`AgentInvoking.swift`**:
   - Add `public struct AgentInvocationImage: Equatable, Sendable` with
     `public var data: Data`, `public var mediaType: String` and a public
     memberwise init.
   - Add `public static let maximumBytes = 3_750_000` and
     `public static let allowedMediaTypes: Set<String> = ["image/jpeg", "image/png", "image/gif", "image/webp"]`.
   - Add `public var isTransportable: Bool`. It is true when
     `allowedMediaTypes.contains(mediaType)` and
     `!data.isEmpty && data.count <= maximumBytes`.
2. **`AgentInvocationRequest`**:
   - Add `public var images: [AgentInvocationImage]`.
   - Add the init parameter `images: [AgentInvocationImage] = []` as the last
     parameter, after `allowsTools`.
   - Add `public static let imageFallbackNotice = "The page image could not be sent to this model; answer from the recognized text."`.
   - Add `public func droppingImagesWithNotice() -> AgentInvocationRequest` with
     the semantics in the index. If `images` is empty, it returns an unchanged
     copy. Otherwise it sets `images = []` and sets `contextMarkdown` as follows:
     - empty or nil context: the notice alone;
     - otherwise: `context + "\n\n" + notice`.
3. **`ToolLoopModelClient.swift` `ToolLoopModelRequest`**:
   - Add `var images: [AgentInvocationImage] = []` and
     `var imageMessageIndex: Int? = nil`, with default values so that existing
     memberwise-init call sites compile unchanged.
   - Add a doc comment: "images belong to the `.user` message at
     `imageMessageIndex`; clients ignore images when the index is nil, out of
     range, or not a user message."

## Pitfalls

- `AgentInvocationRequest` is `Equatable`. `Data` keeps it `Equatable`. Do not
  make the image a class or a URL.
- Keep the existing init parameter order and add `images` last. Many call sites
  use the existing labels.
- Do not put the fallback notice into the system prompt here. It goes into
  `contextMarkdown`. Each runtime already renders `contextMarkdown`: the gateway
  uses a `<document>` section and the tool loop uses the system prompt.

## Tests to add (`AgentInvocationImageTests.swift`)

- 10-byte `image/png` -> transportable.
- `image/tiff` -> not transportable.
- 3,750,001 bytes `image/jpeg` -> not transportable.
- Empty data -> not transportable.
- Request without images -> `droppingImagesWithNotice()` equals the original.
- Request with an image and context "ctx" -> images empty; context is
  `"ctx\n\nThe page image could not be sent to this model; answer from the recognized text."`.
- Request with an image and nil context -> context is exactly the notice.
- `ToolLoopModelRequest(model:systemPrompt:messages:tools:)` still compiles and
  defaults to `images == []` and `imageMessageIndex == nil`.

## Verification commands and required evidence

Run under bash (`bash -c '...'`). For the session-246 resume, every log goes
to `tmp/document-page-images/P2/attempt-2/` instead of
`tmp/document-page-images/P2/`, as the dispatch manifest lists.

- `PKG_CONFIG_PATH="$PWD/.build/anydoc-native/host/pkgconfig" mise exec -- swift test --filter AgentInvocationImage 2>&1 | tee tmp/document-page-images/P2/contract.log; echo "exit=${PIPESTATUS[0]}"`.
  Must exit 0 and show the 8 `AgentInvocationImageTests` cases passing.
- The same command with `--filter UserAgentToolLoop`, log `toolloop.log`. Must
  exit 0. This shows nothing else broke.
- The same command with `--filter AgentGatewayCLIInvoker`, log `gateway.log`.
  Must exit 0.
- `mise run lint`. Must exit 0.

## Done criteria

- [x] `grep -n "struct AgentInvocationImage" Sources/AppCore/AgentInvoking.swift` matches.
- [x] `grep -n "imageMessageIndex" Sources/AppCore/ToolLoopModelClient.swift` matches; existing ToolLoopModelRequest memberwise initialization defaults the new image fields.
- [ ] All three focused test logs exit 0. Logs and source hashes are recorded below; current shared-tree compile errors block completion.

## Progress Log

- 2026-10-01: Plan created.
- 2026-10-02: Implemented the P2 image value, request fallback helper and tool-loop image fields; added eight contract tests. The initial `AgentInvocationImage` attempt (`tmp/document-page-images/P2/contract.log`, SHA-256 `276f89250362036e8c51c5210f41c97420424435b848d3e1e6608704f35e0ee2`) failed during compilation because concurrent retrieval/schema changes referenced helpers not yet present. Retry `contract-retry.log` (SHA-256 `b8584e2e5afe75add038e5d049149488eb0a0763bc420f0d917c3b8ffd0ef9f7`), `toolloop.log` (`d210ba0ec3718c2b11d10953d56a5098e38931e8eae3c8416d6ec21ca89205c0`) and `gateway.log` (`330447e40d8fa19a52a3e6434afc9ec710ba581ea4c5af32e54d1242504988c2`) also exited 1 on the moving shared tree: `NoteRetrievalText.swift` had an unhandled throwing call and `NoteService.swift` had a `noteTitle` shadowing error. These files are outside P2 write ownership; no edits made to them.
- 2026-10-02: Exact changed-file SwiftLint passed (`swiftlint-changed-retry.log`, SHA-256 `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`). The first strict lint attempt identified and prompted removal of an explicit `= nil`; Swift optional stored properties retain the required nil default. `mise run lint` exited 0 (`lint.log`, SHA-256 `5dda047a6661b4c3c00e254d33c7aa88eff844b480a5c90f704fde2dedc2053a`) with three warnings in unrelated existing files (`ResendGatewayCLIMailSender.swift`, `NoteService.swift`, `AITranslationTests.swift`). Source SHA-256: `AgentInvoking.swift` `a1c22e8c8439fb2ff6e5ad6e1a8bbe5613de8019b5feb91ff5d42830d0dc0414`; `ToolLoopModelClient.swift` `c0075a0987f93894c886352495732298b22abc2bfee5f1073fc03784231ca45a`; `AgentInvocationImageTests.swift` `e2290adaa326268d2b99f17a7dd35b35f09dc9c4dce6e6a9323e291d4079b305`.
- 2026-10-02: A final `AgentInvocationImage` retry (`contract-final.log`, SHA-256 `f98ebdff4e76a011f391b359f2b7682147b025f482f12c0f41e4b95f7ae49cae`) still exited 1 before running tests. The remaining shared-tree compile error is in `Tests/AppCoreTests/NoteStoreSchemaVersion22Tests.swift`: it calls `schemaVersions(in:)`, which is declared `private` in `NoteStoreSchemaTests.swift`. This test-file ownership is outside P2. Resume the focused P2 suites after the schema test owner fixes helper visibility and the test target compiles. P2 source hashes remained unchanged from the preceding entry.
