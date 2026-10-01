# P7: agent-gateway Chat Image Transport

**planId**: P7-gateway-image-transport
**Wave**: 2
**dependsOn**: P2-agent-image-contract
**Status**: Not started
**Design Reference**: `design-docs/specs/design-document-page-images.md` DP9 (gateway rows), I5; `design-docs/specs/ai-agent-integration.md` AI12
**Index**: `impl-plans/active/document-page-images.md`

## Intent and context

Chat replies run through `AgentGatewayCLIInvoker`
(`Sources/AppCore/AgentGatewayCLIInvoker.swift`) when the server `ai.agent`
backend or a user Codex credential is used. The modes are `.local`, `.served`
and `.subscription`; the subscription mode includes the Claude subscription via
`CLAUDE_CODE_OAUTH_TOKEN`.

Today the invoker sends only text. Image import OCR already knows how to pass an
image to each vendor through agent-gateway:
`Sources/AppCore/ImageOCRDocumentConverter.swift:performConversion`, lines
about 99-135. This plan gives chat the same per-vendor image transport when
`request.images` is non-empty. Vendors without image support use the P2 text
fallback.

## Non-goals

- Do not refactor `ImageOCRDocumentConverter.performConversion`. It is
  live-verified. Only widen the visibility of `supportedVendors`.
- Do not change text-only requests. Their argv and stdin must stay byte-identical.
- Do not change execution isolation, sandbox profiles, timeouts or ACP parsing.
- Send at most one image. P6 never sends more; if more arrive, transport only
  the first and note it in a code comment. Do not add multi-image support.

## writePaths

- `Sources/AppCore/AgentGatewayImageTransport.swift` (new)
- `Sources/AppCore/AgentGatewayCLIInvoker.swift`
- `Sources/AppCore/ClaudeImageInput.swift`
- `Sources/AppCore/ImageOCRDocumentConverter.swift` (visibility of
  `supportedVendors` only: change `private static let` to `static let`)
- `Tests/AppCoreTests/AgentGatewayImageTransportTests.swift` (new)
- `Tests/AppCoreTests/ClaudeImageInputTests.swift`
- `impl-plans/active/document-page-images-p7-gateway-image-transport.md` (Progress Log only)

## sharedPaths (read-only)

- `Sources/AppCore/AgentInvoking.swift` (P2: `AgentInvocationImage`,
  `droppingImagesWithNotice()`).
- `Sources/AppCore/AgentGatewayExecutionIsolation.swift` and
  `Sources/AppCore/AgentGatewaySubscription.swift`
  (`AgentGatewayExecutionContext`, `executionContext(mode:vendor:binary:arguments:environment:apiKeyEnvironment:)`).

## Required behaviour (mirror `ImageOCRDocumentConverter.performConversion` exactly)

| vendor | mode | before `executionContext` | after `executionContext` | stdin |
| --- | --- | --- | --- | --- |
| `claude-code` | local | append `["--"] + ClaudeImageInput.arguments` | - | Claude stream-json: image block plus the flattened prompt text |
| `claude-code` | served or subscription | - | append `["--input-format", "stream-json"]` | same stream-json |
| `codex` | local | append `["--", "--image", <temp file>]` | - | flattened prompt |
| `codex` | served or subscription | - | copy the image into `context.workspace` and append `["--image", <workspace file>]` | flattened prompt |
| `anthropic`, `openai`, `gemini`, `openrouter` | local | append `["--image", <temp file>]` | - | flattened prompt |
| same | served | - | copy into `context.workspace` and append `["--image", <workspace file>]` | flattened prompt |
| any other vendor | any | call `request.droppingImagesWithNotice()` before building the prompt | - | flattened prompt, which includes the notice inside `<document>` |

`--system` and `--api-key-environment` are added before any `--` separator.
They are already added before the image step in the current argument order;
keep that order.

## File-level changes

1. **`AgentGatewayImageTransport.swift`** (new): an internal type that holds the
   vendor rules.
   - `static let imageCapableVendors: Set<String>` must equal
     `ImageOCRDocumentConverter.supportedVendors`.
   - A function that writes the image to a fresh `0700` temporary directory, with
     the file extension taken from `DocumentImageNaming.fileExtension(forMediaType:)`.
     It returns the URL and a cleanup closure.
   - A function that returns the pre-context arguments for (vendor, mode, local
     path).
   - A function that mutates the context after creation for served and
     subscription modes. It throws `AgentInvocationError.failed("image workspace unavailable")`
     when the workspace is nil for vendors other than `claude-code`.
   - A function that produces the stdin `Data`. For `claude-code` it calls
     `ClaudeImageInput.encode(prompt:imageData:mediaType:)`; otherwise it returns
     the prompt as UTF-8.
2. **`ClaudeImageInput.swift`**:
   - Add `static func encode(prompt: String, imageData: Data, mediaType: String) throws -> Data`.
     It applies the same JSON shape, the 20 MiB cap and the media-type allow-list
     (`image/png`, `image/jpeg`, `image/gif`, `image/webp`).
   - Make the existing `encode(prompt:imageURL:)` delegate to it after its file
     checks. Its output must stay byte-identical.
3. **`AgentGatewayCLIInvoker.swift`**: one call site in `invokeGatewayUnsanitized`,
   15 lines or fewer, keeping the file under 1000 lines.
   - If `request.images` is non-empty and the vendor is not image-capable,
     replace `request` with `request.droppingImagesWithNotice()` before
     `flattenedPrompt`.
   - If the vendor is image-capable:
     - prepare the temp file;
     - `defer` its cleanup;
     - add the pre-context arguments;
     - after `executionContext`, apply the post-context mutation;
     - pass the transport's stdin to `Self.run`.
   - The streaming path shares `invokeGatewayUnsanitized`, so nothing extra is
     needed there.
   - Name new helpers distinctly. Do not overload `invoke`. An overload can
     recurse into itself, which shows up as a silent SIGKILL.
4. **`ImageOCRDocumentConverter.swift`**: `supportedVendors` becomes internal.
   Make no other change.

## Pitfalls

- The vendor is `request.provider ?? vendor`, which is the same selection as the
  existing `selectedVendor`.
- The temp file must outlive the process run and be deleted after it, by `defer`
  in the invoker scope. A workspace copy is cleaned up by `context.cleanUp()`.
- Do not include image bytes in error messages or logs. Sanitized diagnostics
  must not grow.
- With `claude-code`, the prompt text inside stream-json is the flattened prompt
  (context, history and the last user turn). Do not drop the `<document>` RAG
  context.
- Text-only turns must not gain the `ClaudeImageInput` restricted arguments.

## Tests to add

`AgentGatewayImageTransportTests.swift`:

- Set up a fake gateway executable script in a temporary directory. Imitate the
  fake-gateway helpers in `Tests/AppCoreTests/AgentGatewayCLIInvokerTests.swift`.
  The script records argv to a file and stdin to a file, copies any path that
  follows `--image` to a capture file, and prints a minimal valid ACP result
  line, copied from the existing tests.
- Local `anthropic`, request with a PNG image and context "RAG chunk lighthouse"
  -> argv contains `--image <path>` before any `--`; the captured image bytes
  equal the input; stdin contains "RAG chunk lighthouse"; the temp file no
  longer exists after return.
- Local `codex` -> argv ends with `--`, `--image`, `<path>`; the image is
  captured; stdin is plain text.
- Local `claude-code` -> argv contains `--` followed by
  `ClaudeImageInput.arguments`; stdin parses as JSON with
  `message.content[0].type == "image"`, base64 equal to the input, and
  `content[1].text` containing "RAG chunk lighthouse".
- Local `cursor` -> no `--image` and no stream-json; stdin contains
  `AgentInvocationRequest.imageFallbackNotice` and "RAG chunk lighthouse".
- Request without images, for each vendor above -> argv and stdin are
  byte-identical to a run of the same request made before this change. Compute
  the expected value with the same request and `images: []`, and assert that no
  `--image`, `stream-json` or `--` was added.
- Post-context mutation as a pure function: build an `AgentGatewayExecutionContext`
  with a temporary workspace and mode served.
  - `openai` -> the image is copied into the workspace, and argv ends with
    `--image <workspace path>`.
  - `claude-code` served -> argv ends with `--input-format stream-json`.
  - Workspace nil for `openai` -> throws.
- `AgentGatewayImageTransport.imageCapableVendors == ImageOCRDocumentConverter.supportedVendors`.

`ClaudeImageInputTests.swift` (append):

- `encode(prompt:imageData:mediaType:)` output equals
  `encode(prompt:imageURL:)` for the same bytes written to a `.png` file.
- `mediaType: "image/tiff"` -> throws.

## Verification commands and required evidence

Use the prefix `PKG_CONFIG_PATH="$PWD/.build/anydoc-native/host/pkgconfig" mise exec --`
and save logs to `tmp/document-page-images/P7/`.

- `swift test --filter AgentGatewayImageTransport`. Must exit 0.
- `swift test --filter AgentGateway`. Must exit 0, with no regression in the
  lifecycle, served-safety and subscription tests.
- `swift test --filter ClaudeImageInput`. Must exit 0.
- `swift test --filter DocumentGatewayIsolation`. Must exit 0, showing that OCR
  gateway isolation is unchanged.
- `mise run lint`. Must exit 0.
- `wc -l Sources/AppCore/AgentGatewayCLIInvoker.swift`. Must be under 1000.

## Done criteria

- [ ] `grep -n "AgentGatewayImageTransport" Sources/AppCore/AgentGatewayCLIInvoker.swift` matches.
- [ ] `grep -n "private static let supportedVendors" Sources/AppCore/ImageOCRDocumentConverter.swift` prints nothing.
- [ ] All commands above exit 0, and logs are saved.

## Progress Log

- 2026-10-01: Plan created.
