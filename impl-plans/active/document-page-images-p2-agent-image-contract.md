# P2: Agent Image Request Contract

**planId**: P2-agent-image-contract
**Wave**: 1
**dependsOn**: none
**Status**: Not started
**Design Reference**: `design-docs/specs/design-document-page-images.md` DP8 item 4, DP9 (fallback line), I5; `design-docs/specs/ai-agent-integration.md` AI12
**Index**: `impl-plans/active/document-page-images.md` ("Pinned cross-plan contracts" is binding)

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

- `PKG_CONFIG_PATH="$PWD/.build/anydoc-native/host/pkgconfig" mise exec -- swift test --filter AgentInvocationImage 2>&1 | tee tmp/document-page-images/P2/contract.log; echo "exit=${PIPESTATUS[0]}"`.
  Must exit 0.
- The same command with `--filter UserAgentToolLoop`, log `toolloop.log`. Must
  exit 0. This shows nothing else broke.
- The same command with `--filter AgentGatewayCLIInvoker`, log `gateway.log`.
  Must exit 0.
- `mise run lint`. Must exit 0.

## Done criteria

- [ ] `grep -n "struct AgentInvocationImage" Sources/AppCore/AgentInvoking.swift` matches.
- [ ] `grep -n "imageMessageIndex" Sources/AppCore/ToolLoopModelClient.swift` matches.
- [ ] Logs are saved with exit 0. The Progress Log records hashes.

## Progress Log

- 2026-10-01: Plan created.
