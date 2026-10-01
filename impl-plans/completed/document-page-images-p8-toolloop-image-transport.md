# P8: Tool-Loop (Anthropic Messages, OpenAI Chat Completions) Image Transport

**planId**: P8-toolloop-image-transport
**Wave**: 2
**dependsOn**: P2-agent-image-contract
**Status**: Completed. Accepted in session-246 (test-integrity, adversarial and serial integration review). The combined-tree `mise run check` exited 0 (`tmp/document-page-images/reconcile-session-246/wave5/full-check.log`). Archived at Step 8 on 2026-10-02.
**Design Reference**: `design-docs/specs/design-document-page-images.md` DP9 (tool-loop rows), I5; `design-docs/specs/ai-agent-integration.md` AI12
**Index**: `impl-plans/active/document-page-images.md`

## Intent and context

Users with a personal agent credential chat through `UserAgentToolLoopRunner`
(`Sources/AppCore/UserAgentToolLoopRunner.swift`), which `UserAgentRuntimeFactory.makeInvoker`
builds in `Sources/AppCore/UserAgentRuntime.swift`. The provider client
depends on the credential:

- `AnthropicMessagesToolLoopClient` for `anthropic`;
- `OpenAIChatCompletionsToolLoopClient` for `openai`, `openrouter` and
  `openai-compatible`.

This plan sends `AgentInvocationRequest.images` (P2) as provider-native image
content on the user message of the current turn. For `openai-compatible`, it
uses the P2 text fallback.

## Non-goals

- Do not change `ToolLoopMessage` cases or tool-call encoding.
- Do not change streaming parsing or the cache-breakpoint placement rules.
- Do not probe models or retry requests.
- Do not change the Codex credential path. It uses `AgentGatewayCLIInvoker`,
  which is P7.

## writePaths

- `Sources/AppCore/AnthropicMessagesToolLoopClient.swift`
- `Sources/AppCore/OpenAIChatCompletionsToolLoopClient.swift`
- `Sources/AppCore/UserAgentToolLoopRunner.swift`
- `Sources/AppCore/UserAgentRuntime.swift`
- `Tests/AppCoreTests/ToolLoopImageInputTests.swift` (new)
- `impl-plans/active/document-page-images-p8-toolloop-image-transport.md` (Progress Log only)

## sharedPaths (read-only)

- `Sources/AppCore/AgentInvoking.swift` and `Sources/AppCore/ToolLoopModelClient.swift`
  (P2: `images`, `imageMessageIndex`, `droppingImagesWithNotice()`).
- `Sources/AppCore/UserAgentCredential.swift` (`UserAgentProvider`).

## File-level changes

1. **`UserAgentToolLoopRunner`**:
   - Add a stored `var supportsImageInput: Bool`. Give it the default value
     `false` at the end of the memberwise init, so that existing constructions
     compile.
   - At the start of `invoke`, if `!supportsImageInput`, set
     `request = request.droppingImagesWithNotice()`. This happens before
     `systemPrompt(for:toolCount:)`, so the notice reaches the system prompt
     through `contextMarkdown`.
   - Compute `imageMessageIndex` as the index of the last `.user` message in
     `initialMessages(for:)`, which is the current turn. Pass `images` and
     `imageMessageIndex` in every `ToolLoopModelRequest` of the loop. The index
     stays valid because messages are only appended.
2. **`UserAgentRuntime.makeInvoker`**: set `supportsImageInput` to true for
   `.anthropic`, `.openai` and `.openrouter`, and false for `.openaiCompatible`.
3. **`AnthropicMessagesToolLoopClient.requestBody`**: for the message whose
   index is `request.imageMessageIndex` and is `.user(text)`, emit content as:
   - each image as `{"type":"image","source":{"type":"base64","media_type":<mediaType>,"data":<base64>}}`;
   - then the text block. The text block keeps `cache_control` when that index is
     the cache breakpoint.
   Every other message is unchanged.
4. **`OpenAIChatCompletionsToolLoopClient.requestBody`**: for that index, the
   user message `content` becomes an array:
   - `[{"type":"text","text":<text>}]`;
   - followed by each image as
     `{"type":"image_url","image_url":{"url":"data:<mediaType>;base64,<base64>"}}`.
   Other user messages keep string content.

## Pitfalls

- Images only reach the `.user` message at the exact index. If the index is out
  of range, or that message is not `.user`, ignore the images. Never attach them
  to tool-result or assistant messages.
- Requests without images must be byte-identical to today, including the
  Anthropic `cache_control` placement and OpenAI string content.
- The base64 must be standard with no line breaks (`base64EncodedString()` with
  no options).
- Keep `emptyUserMessage` substitution behaviour. An image-bearing turn always
  has user text in chat.

## Tests to add (`ToolLoopImageInputTests.swift`)

- Anthropic `requestBody`, a request with two messages (user, assistant), a third
  user message at index 2 with a PNG, and `imageMessageIndex: 2` -> decoded JSON:
  - `messages[2].content[0]` is an image with the matching base64 and media
    type;
  - `content[1]` is text with `cache_control`;
  - `messages[0].content` is a single text block.
- OpenAI `requestBody`, same request -> `messages[3].content` is an array with
  text then `image_url` (index 3, because the system message is first); the url
  starts with `data:image/png;base64,`; other user messages have string content.
- Without images, both `requestBody` outputs equal the output for the same
  request built without the new fields.
- Runner with a fake `ToolLoopModelClient` capturing requests (imitate fakes in
  `Tests/AppCoreTests/UserAgentToolLoopTests.swift`):
  - `supportsImageInput: true`, a request with one image and context "RAG chunk
    lighthouse", and a fake that returns one tool call and then end-turn -> both
    captured requests carry the same `images` and an `imageMessageIndex` that
    points at the first user message of the current turn; the system prompt
    contains "RAG chunk lighthouse".
  - `supportsImageInput: false` -> captured `images` is empty; the system prompt
    contains `AgentInvocationRequest.imageFallbackNotice` and "RAG chunk
    lighthouse".
- `UserAgentRuntimeFactory` mapping, if testable without network: anthropic,
  openai and openrouter give true; openai-compatible gives false. Otherwise
  expose a small internal static mapping function and test that.

## Verification commands and required evidence

Use the prefix `PKG_CONFIG_PATH="$PWD/.build/anydoc-native/host/pkgconfig" mise exec --`
and save logs to `tmp/document-page-images/P8/`.

- `swift test --filter ToolLoopImageInput`. Must exit 0.
- `swift test --filter UserAgentToolLoop`. Must exit 0, with no regression.
- `swift test --filter UserAgent`. Must exit 0.
- `mise run lint`. Must exit 0.

## Done criteria

- [x] `grep -n "image_url" Sources/AppCore/OpenAIChatCompletionsToolLoopClient.swift` matches.
- [x] `grep -n "\"base64\"" Sources/AppCore/AnthropicMessagesToolLoopClient.swift` matches.
- [x] `grep -n "supportsImageInput" Sources/AppCore/UserAgentRuntime.swift` matches.
- [x] All commands above exit 0, and logs are saved.

Step 8 re-check (2026-10-02): the three greps match 2, 1 and 2 lines. The
combined-tree check `tmp/document-page-images/reconcile-session-246/wave5/full-check.log`
ends with `exit=0`.

## Progress Log

- 2026-10-01: Plan created.
- 2026-10-02: Implemented P8 in the runner, runtime, and provider clients. The runner now forwards images and the last current-turn user-message index on every tool-loop request; providers without image support and non-transportable images use P2's notice fallback. Anthropic emits base64 image blocks before text while preserving the text cache breakpoint; OpenAI emits text then image_url data URLs only on the indexed user message. Added six contract tests for both payloads, no-image byte equality, two-round forwarding, fallback, and provider mapping. Final gates passed: `PKG_CONFIG_PATH="$PWD/.build/anydoc-native/host/pkgconfig" mise exec -- swift test --filter ToolLoopImageInput` (6/6, log `tmp/document-page-images/P8/toolloop-image-final2.log`); the same prefix with `swift test --filter UserAgentToolLoop` (12/12, `tmp/document-page-images/P8/user-agent-toolloop.log`); the same prefix with `swift test --filter UserAgent` (30/30, `tmp/document-page-images/P8/user-agent.log`); `mise run build` (exit 0, `tmp/document-page-images/P8/build.log`); `mise run lint` (exit 0, three pre-existing warnings in unrelated `ResendGatewayCLIMailSender.swift:75`, `AITranslationTests.swift:71`, and `NoteService.swift:720`, `tmp/document-page-images/P8/mise-lint.log`); strict changed-file SwiftLint over `tmp/document-page-images/P8/changed-swift-files.nul` (exit 0, `tmp/document-page-images/P8/changed-file-swiftlint-rerun.log`). Earlier same-tree test attempts were blocked before test execution by concurrent P7 compile failure (`tmp/document-page-images/P8/toolloop-image.log`) and then concurrent AppGraphQL test references to internal `noteSearchText` (`tmp/document-page-images/P8/toolloop-image-rerun.log`); both shared-tree issues were corrected before the passing final test runs. No P8 implementation criteria remain outstanding; review and integration checks remain downstream workflow steps.
- 2026-10-02: Final acceptance self-check aligned `supportsImageInput` to the plan's stored mutable property. Re-ran final-source gates successfully: `PKG_CONFIG_PATH="$PWD/.build/anydoc-native/host/pkgconfig" mise exec -- swift test --filter ToolLoopImageInput` (6 passed, 0 failed, `tmp/document-page-images/P8/toolloop-image-source-final.log`); corresponding `swift test --filter UserAgentToolLoop` (12 passed, 0 failed, `tmp/document-page-images/P8/user-agent-toolloop-source-final.log`); corresponding `swift test --filter UserAgent` (30 passed, 0 failed, `tmp/document-page-images/P8/user-agent-source-final.log`); `mise run lint` (exit 0, same three unrelated baseline warnings, `tmp/document-page-images/P8/mise-lint-source-final.log`); selected-file strict SwiftLint (exit 0, `tmp/document-page-images/P8/changed-file-swiftlint-final.log`).
- 2026-10-02: Post-alignment production build also passed: `mise run build` (exit 0, `tmp/document-page-images/P8/build-source-final.log`).
