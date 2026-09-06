# KaibaClient source release 0.1.13

Riela requires the public `KaibaClient` SwiftPM product. The previous published
revision, `b436b91d39a5eaee8243a43096dd13f1e8ad819e` (0.1.12), did not contain
the SDK that had been implemented in this worktree. This source release publishes
the SDK, its schema-discovery CLI, and the associated authenticated server
operations and regression tests described in `kaiba-client-sdk.md`.

The release also fixes two issues reproduced during verification:

- Personalized PageRank now accumulates in input-node order instead of hash
  iteration order. Identical inputs retain exact deterministic output; the
  existing exact-equality assertion now runs twenty times.
- Connection-capacity rejection half-closes the response and drains pending
  request bytes before cancellation, with a one-second cleanup deadline. This
  prevents an immediate TCP reset from hiding the HTTP 429 response.

This is a SwiftPM source release. It does not replace the signed 0.1.12 macOS
installer assets or update the Homebrew Cask. Riela should pin the published
commit instead of relying on a local SwiftPM editable dependency.

Verification on 2026-09-06 used Xcode's Swift toolchain: `swift test` passed
808 XCTest tests and 123 Swift Testing tests after both fixes. The focused
connection-capacity suite passed all four tests. SwiftLint passed on the release
fixes; the full lint run retained three existing warnings and no errors.

## 0.1.14 Linux compiler compatibility

The Linux release build of 0.1.13 exceeded the compiler's type-checking budget
on two chained schema-validation array expressions. Version 0.1.14 replaces
those expressions with explicitly typed arrays and incremental appends, without
changing validation rules. It remains a SwiftPM source release; the signed
macOS installer assets are unchanged.

The CI image also lacked the SQLite development headers required by
`CKaibaSQLite3`. The Linux job now installs `libsqlite3-dev` and `pkg-config`
before building the CLI.

The subsequent Linux compile exposed stricter non-null `posix_spawn` argument
types and an oversized tag-comment binding expression. Explicit pointer guards
and incremental binding construction preserve behavior across Darwin and Glibc.
The affected process-invocation and tag-detail suites passed all 47 tests.

The local listener was already implemented only with Apple's Network framework.
The runtime now guards that implementation on Linux, and `kaiba serve` reports
an unsupported-platform error before creating a store. The Linux CI job checks
this diagnostic and absence of store creation, as well as the CLI version.
The portable SDK can still connect to a supported remote server from Linux.
