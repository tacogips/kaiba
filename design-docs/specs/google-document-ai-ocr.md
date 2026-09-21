# Google Document AI OCR

Kaiba can use the installed `google-document-ocr-gateway` CLI for PDF-page and
standalone-image OCR. This is Google's dedicated Document AI service, separate
from Gemini and `agent-gateway`. The same recognizer serves CLI imports,
`page-ocr`, HTTP imports, and the reader's deferred OCR action.

## Configuration

Install the gateway including its discovery resource bundle. Set these fields
in your Kaiba configuration (default `~/.config/kaiba/config.json`):

```json
{
  "import": {
    "ocrEngine": "google-document-ai",
    "maximumOCRPages": 3,
    "googleDocumentAI": {
      "processorName": "projects/PROJECT/locations/us/processors/PROCESSOR",
      "commandPath": "/opt/homebrew/bin/google-document-ocr-gateway",
      "serviceAccountEnvironmentVariable": "GOOGLE_APPLICATION_CREDENTIALS_JSON",
      "languageHints": ["ja"],
      "timeoutSeconds": 120
    },
    "analysis": { "vendor": "codex", "model": "gpt-5.6-luna" },
    "figures": { "vendor": "codex", "model": "gpt-5.6-luna" }
  }
}
```

`processorName` must identify an existing OCR processor. To pin its model, append
`/processorVersions/VERSION`. The gateway method and region derive from this
resource name; no separate Gemini model or API key is involved.

`commandPath` is optional if the gateway is on the backend's PATH. It must be an
absolute executable path when supplied. `languageHints` is optional; omit it for
automatic language detection. `timeoutSeconds` accepts 1–600, default 120.

Enable `documentai.googleapis.com` in the processor's project and grant the
service account access to process documents (for example, Document AI API User).
A processor in another project requires permissions in that project.

Inject the existing kinko credential into the backend process:

```sh
kinko exec --env GOOGLE_APPLICATION_CREDENTIALS_JSON -- \
  kaiba --config /path/to/config.json import /path/to/book.pdf --max-ocr-pages 1

kinko exec --env GOOGLE_APPLICATION_CREDENTIALS_JSON -- \
  kaiba --config /path/to/config.json page-ocr NOTE_ID

kinko exec --env GOOGLE_APPLICATION_CREDENTIALS_JSON -- \
  kaiba --config /path/to/config.json serve
```

The default credential variable is `GOOGLE_APPLICATION_CREDENTIALS_JSON`.
Alternatively, configure `accessTokenEnvironmentVariable` and inject that token.
Do not configure both authentication modes. Config files store variable names,
never credentials. An already-running backend must be restarted with the injected
environment and new configuration.

The `analysis` and `figures` sections are optional and independently configured.
Server-side Codex analysis still requires the existing explicit subscription
opt-in. Selecting Document AI for OCR does not enable Codex subscription access.

An explicit `ocrEngine` wins. If it is omitted, `googleDocumentAI` configuration
selects Document AI; otherwise the existing agent-gateway/Vision defaults apply.
`--ocr-engine google-document-ai` overrides the engine for CLI imports.
Zero-page imports retain all originals and defer OCR; N/all limits are unchanged.
Other document formats retain the existing Anydoc conversion path.

## Text fidelity and execution

Kaiba preserves `document.text` exactly as returned, including Japanese Unicode,
line breaks, and Google's reading order. It does not rewrite text with an LLM or
reorder columns from bounding boxes. Plain text is stored in the note body; this
adapter does not synthesize Markdown tables or headings. Empty text on a valid
blank page is accepted. Missing page results, page errors, invalid JSON, failed
exit status, and truncated output fail instead of committing partial OCR.

Each request passes image bytes as base64 JSON on stdin. The child receives only
the selected credential, a fixed system PATH/locale, and a private temporary
HOME/TMPDIR. It calls the tool-free gateway directly, without the coding-agent
filesystem sandbox. The installed executable and its discovery bundle must be
trusted server software. Credentials and provider response bodies are excluded
from error diagnostics. The shared subprocess runner bounds output and timeout
and terminates descendants. Page images are limited to 20 MiB; request workspaces
are removed after completion. The gateway owns service-account signing and token
exchange; Kaiba does not implement Google authentication.

## Verification

`GoogleDocumentAIPageRecognizerTests` covers JSON input, service-account and token
routing, pinned processor versions, Japanese text preservation, blank/failed
pages, secret isolation, error redaction, timeout, config round-trip, CLI import,
and deferred OCR. The factory is also exercised in server execution mode.
`GoogleDocumentAIOCRGraphQLTests` verifies successful deferred OCR and preservation
of pending pages after gateway failure through the GraphQL mutation.

Live setup on 2026-09-13:

- After the operator refreshed Google login, `google-service-gateway-writer
  services enable` successfully enabled `documentai.googleapis.com` in
  `ai-tools-proj`.
- Created `kaiba-document-ocr` in `us`:
  `projects/1080572319740/locations/us/processors/d96ef4658dec92f`.
  Its default model is `pretrained-ocr-v2.1-2024-08-07`.
- Granted the kinko service account `roles/documentai.apiUser` in that project.
  OCR calls succeeded after IAM propagation. No credentials were persisted.
- Processed `japanese-page-3.png`, the same vertical Japanese page used for Luna.
  Google returned 658 characters in correct right-to-left column order. After
  normalizing whitespace and width, the only differences from Luna's output
  were `○○` versus `〇〇`, and Google's retained page number `2`. Visual inspection
  supported the reading order and text fidelity. This is one page, not a
  ground-truth character-error-rate benchmark.
- Full Google responses include image/layout data (~790 KB on this fixture),
  exceeding the shared 256 KiB subprocess-output limit. Kaiba now requests
  `fieldMask: "text,error,pages.pageNumber"`, reducing this response to ~2 KB
  without changing the OCR text. Document-level errors are checked before
  accepting text. The output limit remains unchanged.

Private setup, comparison, and gateway evidence are in
`tmp/google-document-ai-integration/`; `config.json` selects the real processor
and the kinko service-account variable.

Verification before the live field-mask adjustment:

- `mise run test`: 876 XCTest cases (6 optional skips), plus 123 Swift Testing
  cases; zero failures.
- `mise run lint`: passed with only the three pre-existing warnings.
- `git diff --check`: passed.

Final live verification after the field-mask fix:

- A complete Kaiba import succeeded using `kinko exec --env
  GOOGLE_APPLICATION_CREDENTIALS_JSON`, the dedicated gateway, and the selected
  Japanese page. One note and its source-page original were stored with OCR
  state `complete`; stored text matches the gateway response after outer
  whitespace trimming. SQLite quick-check passed.
- `mise exec -- swift test --filter 'GoogleDocumentAI'`: all 9 adapter and
  GraphQL tests passed, including the field-mask contract and document-error
  rejection.
- `mise run lint`: only the three existing warnings; no new violations.

Run the configured backend with `--config
/Users/taco/gits/tacogips/kaiba/tmp/google-document-ai-integration/config.json`
and inject `GOOGLE_APPLICATION_CREDENTIALS_JSON` with kinko. This explicit config
selects Google OCR; no user-wide default configuration was overwritten.
