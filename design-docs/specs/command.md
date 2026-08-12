# Command

## Status

Accepted

## Current CLI

```bash
kaiba [--note-root <dir>] [--config <path>] <command> ...
```

Global options: `--note-root <dir>` (default `~/.kaiba`, env
`KAIBA_NOTE_ROOT`) and `--config <path>` (default
`~/.config/kaiba/config.json`, env `KAIBA_CONFIG_PATH`), plus `--help` and
`--version`. Commands that render
entities accept `--output json|text` (default `text`).

### Notes

```bash
kaiba add    [--notebook <id>] [--title <t>] (--body <md>|--body-file <path>|-)
             [--tag <name>]... [--read-only]
kaiba edit   <note-id> (--body <md>|--body-file <path>) [--append]
kaiba show   <note-id>
kaiba list   [--notebook <id>] [--tag <name>]... [--limit N] [--offset N]
kaiba search <query> [--tag <name>]... [--class <id>] [--include-linked]
             [--sort created-desc|created-asc|updated-desc|title]
             [--created-after <iso8601>] [--created-before <iso8601>]
             [--limit N] [--offset N]
kaiba readonly <note-id> (--on|--off)
kaiba delete <note-id>
```

`add` creates a single-note notebook when `--notebook` is omitted. `-`
reads the body from stdin. Tag filters expand to the requested tag plus
all descendant tags.

### Tags and ontology

```bash
kaiba tag        <note-id> (--add <name>... | --remove <name>...)
kaiba tags       [--class <id>]
kaiba classes
kaiba tag-define <name> [--class <id>] [--parent <tag-name>]
kaiba class-define <class-id> --label <label> [--description <text>]
```

### Relations and files

```bash
kaiba comment <note-id> --body <text>
kaiba link    <from-note-id> <to-note-id> [--kind <kind>]
kaiba attach  <note-id> <file-path> [--role related|embedded|source-page-image]
              [--media-type <mime>]
kaiba file    <file-id> [--out <path>]
```

### Notebooks

```bash
kaiba notebook list     [--tag <name>]... [--sort <order>]
                        [--created-after <t>] [--created-before <t>]
                        [--limit N] [--offset N]
kaiba notebook show     <notebook-id>
kaiba notebook create   --title <t> [--kind <kind-tag>]
kaiba notebook delete   <notebook-id>
kaiba notebook progress <notebook-id> <none|progress|done|pending>
kaiba notebook readonly <notebook-id> (--on|--off)
```

Notebook read-only blocks note creation, body edits, attachments, and
deletion inside the notebook while still allowing comments, tags,
links, and progress changes.

### GraphQL from the CLI

```bash
kaiba graphql (<document>|--file <path>|-) [--variables <json>]
              [--operation <name>]
```

Executes a note GraphQL document against the local store and prints the
JSON response (`data`/`errors`). Exit code is non-zero when the
response carries GraphQL errors.

### API keys

```bash
kaiba client issue --name <display-name>   # prints the key once
kaiba client list [--all]
kaiba client revoke <client-id>
```

Issued keys are stored hashed in the `api_clients` table and are
accepted by `kaiba serve` as `Authorization: Bearer <api-key>` —
the same registry the QR registration flow uses. Revocation takes
effect immediately.

### Serve (HTTP note API + web viewer)

```bash
kaiba serve [--note-root <dir>] [--host <h>] [--port <p>]
            [--web-root <dir>] [--allow-unauthenticated]
```

Long-running local server (default `127.0.0.1:8787`): `POST /graphql`
(note GraphQL API), `GET|POST /note/register` (QR client registration;
a registration URL and terminal QR code are printed at startup),
`GET /note/events` (long-poll change feed), and `GET /healthz`.
`--web-root web/dist` additionally serves the built SolidJS note
viewer with SPA fallback. `--allow-unauthenticated` disables bearer
auth for trusted local use.

### Import

```bash
kaiba import <file-path> [--title <t>] [--kind-tag <tag>]
             [--anydoc-path <p>] [--output json|text]
```

Converts a source document (pdf, doc/docx, ppt/pptx, excel, odt/ods/odp,
rtf, epub, csv) to markdown by spawning the installed `anydoc-swift` CLI
with `--json`, then stores an imported-material notebook with one note
per top-level markdown section and the original file attached with the
`source-document` role. The binary resolves from `--anydoc-path`, then
`import.anydocPath` in the configuration, then `PATH`. See
`document-import.md`.

### AI

```bash
kaiba ai tag (--note <id> | --notebook <id>) [--dry-run]
kaiba ai status
```

`ai tag` extracts ontology tags with the configured agent backend
(`agent-gateway`, spawned per invocation) and applies them with
provenance `ai` (never overwriting human tags or redefining existing
tags); `--dry-run` prints proposals without applying. `ai status`
reports the `ai` configuration section and runtime availability. When
the backend, vendor, model, or binary is missing, `ai tag` exits `1`
with the specific reason. See `ai-agent-integration.md`.

### Storage

```bash
kaiba storage migrate (<file-id>|--all) --profile <name> --endpoint <url>
              --region <r> --bucket <b> --access-key-env <VAR>
              --secret-key-env <VAR> [--key-prefix <prefix>]
kaiba storage gc [--grace-hours N]
```

`migrate` moves local file content to S3-compatible storage; credentials
are read from the named environment variables. The endpoint, region, bucket,
credential environment-variable names, and key prefix may instead come from a
named `storageProfiles` entry in the Kaiba configuration. `file --out` uses the
same configured profile to retrieve S3-backed content. `gc` reclaims file
records no note or notebook references anymore and sweeps stray blobs,
with a grace window (default 24 hours) protecting recent files.

## Exit Codes

`0` success, `1` domain or IO error, `2` unknown argument.
