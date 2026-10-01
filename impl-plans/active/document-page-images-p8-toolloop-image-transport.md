# P8: Tool-Loop (Anthropic Messages, OpenAI Chat Completions) Image Transport

**planId**: P8-toolloop-image-transport
**Wave**: 2
**dependsOn**: P2-agent-image-contract
**Status**: Not started
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

- [ ] `grep -n "image_url" Sources/AppCore/OpenAIChatCompletionsToolLoopClient.swift` matches.
- [ ] `grep -n "\"base64\"" Sources/AppCore/AnthropicMessagesToolLoopClient.swift` matches.
- [ ] `grep -n "supportsImageInput" Sources/AppCore/UserAgentRuntime.swift` matches.
- [ ] All commands above exit 0, and logs are saved.

## Progress Log

- 2026-10-01: Plan created.
