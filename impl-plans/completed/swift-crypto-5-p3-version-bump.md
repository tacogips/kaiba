# P3: patch version bump 0.1.18 -> 0.1.19

**Status**: In Progress
**planId**: swift-crypto-5-p3-version-bump (wave 1, dependsOn: none)
**Design Reference**: `design-docs/specs/kaiba-note.md` Verification "Release hygiene"
**Evidence**: `tmp/swift-crypto-5/P3/logs/`; progress in `tmp/swift-crypto-5/P3/progress.md`

## Intent and context

The repository convention (`git show --stat cf1254b`, "chore: bump version to 0.1.18") changes
exactly five lines in five files: `VERSION`, `Sources/AppCore/Version.swift`
(`public static let current = "0.1.18"`), `web/src-tauri/Cargo.toml` (`version = "0.1.18"`),
`web/src-tauri/Cargo.lock` (the `name = "kaiba-client"` package entry, line ~1790), and
`web/src-tauri/tauri.conf.json` (`"version": "0.1.18"`).

## Non-goals

- Do not run `cargo update` or regenerate `Cargo.lock`. Change only the kaiba-client version line.
- Do not edit README, the changelog, web/package.json, release scripts, or any other `0.1.18` occurrence
  (for example, in dependency versions inside Cargo.lock or in archived plans).
- No tags, releases, casks or formulas.

## File-level changes

Replace `0.1.18` with `0.1.19` at exactly the five sites above. Edit `Cargo.lock` by hand, on the
line that follows `name = "kaiba-client"` only.

## Pitfalls

- `Cargo.lock` may contain other `0.1.18` strings that belong to unrelated crates. A global replace is wrong.
- `cargo check` (tauri:check) can rewrite `Cargo.lock` if the version lines disagree. After the
  check, confirm `git diff --numstat web/src-tauri/Cargo.lock` is still `1	1`.

## Verification (command -> required evidence)

- `bash -c 'grep -n "0\.1\.19" VERSION Sources/AppCore/Version.swift web/src-tauri/Cargo.toml web/src-tauri/tauri.conf.json; grep -n -A1 "name = \"kaiba-client\"" web/src-tauri/Cargo.lock' 2>&1 | tee tmp/swift-crypto-5/P3/logs/01-version.log` -> 0.1.19 at all five sites.
- `bash -c 'git diff --numstat -- VERSION Sources/AppCore/Version.swift web/src-tauri | tee tmp/swift-crypto-5/P3/logs/02-numstat.log'` -> five rows, each `1	1`.
- `bash -c 'mise run tauri:check 2>&1 | tee tmp/swift-crypto-5/P3/logs/03-tauri-check.log; code=${PIPESTATUS[0]}; echo exit=$code >> tmp/swift-crypto-5/P3/logs/03-tauri-check.log; exit $code'` -> exit 0.
- `bash -c 'mise run web:check 2>&1 | tee tmp/swift-crypto-5/P3/logs/04-web-check.log; code=${PIPESTATUS[0]}; echo exit=$code >> tmp/swift-crypto-5/P3/logs/04-web-check.log; exit $code'` -> exit 0.
- Re-run the numstat command into `logs/05-numstat-after.log` -> still five rows of `1	1`.

## Done criteria

- [ ] Logs 03 and 04 end with `exit=0`. Logs 02 and 05 show exactly five `1	1` rows.
- [ ] `progress.md` ends with `status: done`.

## Progress Log

- 2026-10-27: Plan created.
