# P1: require swift-crypto 5.x

**Status**: In Progress
**planId**: swift-crypto-5-p1-dependency (wave 1, dependsOn: none)
**Design Reference**: `design-docs/specs/kaiba-note.md` K3 and Verification "K3 (swift-crypto 5.x)"
**Evidence**: `tmp/swift-crypto-5/P1/logs/`; progress in `tmp/swift-crypto-5/P1/progress.md`

## Intent and context

- `Package.swift:22` currently has `.package(url: "https://github.com/apple/swift-crypto.git", from: "4.5.1")`.
  `Package.resolved` pins swift-crypto 4.5.1 (rev 47d3869a) and swift-asn1 1.7.1.
- `Package.swift:41` links the `Crypto` product only on Linux
  (`condition: .when(platforms: [.linux])`). Seven files use
  `#if canImport(CryptoKit) import CryptoKit #else import Crypto #endif`:
  `Sources/AppCore/KaibaJWT.swift`, `LocalNoteFileStore.swift`, `AITranslation.swift`,
  `MeilisearchRequestBodies.swift`, `NoteService+APIClients.swift`, `S3NoteFileStore.swift`,
  `NoteService+EmailLogin.swift`. They use only `SHA256.hash(data:)`, incremental `SHA256()`,
  `HMAC<SHA256>.authenticationCode`, `HMAC<SHA256>.isValidAuthenticationCode` and
  `SymmetricKey(data:)`.
- macOS builds never compile kaiba against `Crypto`, so a macOS build cannot prove the
  Linux compile. The Linux check below covers that.

## Non-goals

- Do not change the conditional-import pattern, the `.when(platforms: [.linux])` condition,
  the anydoc-swift revision pin or the swift-tools-version.
- Do not edit a crypto source file unless the Linux compile fails on it. A "cleanup" edit is out of scope.
- Do not edit `tmp/ui-preview-compat/Package.swift` (gitignored scratch).
- Do not work around a cap. If resolution fails because something requires swift-crypto below 5,
  stop with `status: blocked (cap)` and copy the exact constraint from the resolver error.

## File-level changes

1. `Package.swift`: change only the swift-crypto line to `from: "5.0.3"`.
2. `Package.resolved`: produced by `swift package update swift-crypto`. Never hand-edit it.
   Only the swift-crypto entry, possibly the swift-asn1 entry, and `originHash` may change.
   The anydoc-swift entry must stay byte-identical.
3. The 7 crypto-importing sources: edit only to fix a Linux compile error or a
   swift-crypto 5 deprecation of an API listed above. Make the smallest edit that preserves
   the algorithm and output bytes, and record each one in the progress log with the
   compiler message.

## Steps

1. Pre-hash `Package.swift`, `Package.resolved` and the 7 sources into `logs/00-pre.sha256`.
2. Edit `Package.swift`, then run `swift package update swift-crypto` and log it.
3. Confirm that `Package.resolved` swift-crypto `version` starts with `5.` and is >= 5.0.3.
   Log `git diff Package.resolved`.
4. Record the swift-crypto 5 requirements. Log the first line of
   `.build/checkouts/swift-crypto/Package.swift` (its tools version) and its `platforms:`
   block. Grep `.build/checkouts/swift-crypto/Sources/Crypto` for `deprecated` or
   `unavailable` annotations on `SHA256`, `HMAC`, `SymmetricKey` and `HashFunction`, and
   log the result (an empty result is fine).
5. macOS gates: `swift build`, then
   `swift test --filter 'KaibaJWTTests|NoteFileStoreTests|AITranslationTests'`.
6. Linux compile check, only if `docker` is on PATH (`command -v docker`). Otherwise log
   `linux-local: unavailable (no docker)` and continue, because the post-push CI covers it.
   - Copy the tracked working-tree files into `tmp/swift-crypto-5/P1/linux-src`
     (`git ls-files -z | rsync -a --from0 --files-from=- ./ tmp/swift-crypto-5/P1/linux-src/`).
     Never mount the repository root. The container's `scripts/build-anydoc-native.sh` would
     overwrite the macOS `.build` used by P2.
   - Run the same container as `.github/workflows/linux-amd64-build.yml` (the same
     `SWIFT_IMAGE` digest, `--platform linux/amd64`), mounting `linux-src` at `/workspace`.
     Follow the same script up to `swift build -c release --product kaiba --triple x86_64-unknown-linux-gnu`
     and `kaiba --version`. Log `swift --version` from inside the container.
   - If the compile fails in a crypto source, apply the minimal fix in the real repository
     file (not only the copy), then re-copy and re-run until it passes.
7. Post-hash every owned file. Write the progress summary.

## Invariants

- The output bytes of SHA256 and HMAC-SHA256 are unchanged. KaibaJWTTests and
  NoteFileStoreTests pass with no test edits.
- `Package.swift` diff is exactly one line.

## Tests and verification (command -> required evidence)

- `bash -c 'swift package update swift-crypto 2>&1 | tee tmp/swift-crypto-5/P1/logs/01-update.log; code=${PIPESTATUS[0]}; echo exit=$code >> tmp/swift-crypto-5/P1/logs/01-update.log; exit $code'` -> exit 0.
- `bash -c 'jq -r ".pins[] | select(.identity==\"swift-crypto\" or .identity==\"swift-asn1\" or .identity==\"anydoc-swift\") | \"\(.identity) \(.state.version // .state.revision)\"" Package.resolved | tee tmp/swift-crypto-5/P1/logs/02-pins.log'` -> swift-crypto `5.x` >= 5.0.3; anydoc-swift `0aa4756d0ce3f97cc94f1de9efe26879808097c8`.
- `bash -c 'git diff --numstat Package.swift | tee tmp/swift-crypto-5/P1/logs/03-manifest-diff.log'` -> `1	1	Package.swift`.
- `bash -c 'swift build 2>&1 | tee tmp/swift-crypto-5/P1/logs/04-build.log; code=${PIPESTATUS[0]}; echo exit=$code >> tmp/swift-crypto-5/P1/logs/04-build.log; exit $code'` -> exit 0.
- `bash -c 'swift test --filter "KaibaJWTTests|NoteFileStoreTests|AITranslationTests" 2>&1 | tee tmp/swift-crypto-5/P1/logs/05-crypto-tests.log; code=${PIPESTATUS[0]}; echo exit=$code >> tmp/swift-crypto-5/P1/logs/05-crypto-tests.log; exit $code'` -> exit 0, with `Executed N tests, with 0 failures` and N > 0.
- Linux container build (when docker exists) -> exit 0 and the `kaiba --version` line in
  `logs/06-linux-build.log`. Otherwise the log contains `linux-local: unavailable (no docker)`.
- `bash -c 'git diff --stat -- Sources | tee tmp/swift-crypto-5/P1/logs/07-sources-diff.log'` -> empty unless step 6 required a fix. Every non-empty entry is explained in the progress log.

## Done criteria (mechanically checkable)

- [ ] `Package.swift` contains `from: "5.0.3"` for swift-crypto and no `4.5.1`.
- [ ] The swift-crypto pin in `Package.resolved` is 5.x >= 5.0.3.
- [ ] Logs 01, 04 and 05 end with `exit=0`. Log 06 is a pass or explicitly records unavailable.
- [ ] `progress.md` lists the swift-crypto version, the swift-asn1 version, the tools version and platforms of swift-crypto 5, the deprecation-grep result, and the Linux status. It ends with `status: done`.

## Progress Log

- 2026-10-27: Plan created.
