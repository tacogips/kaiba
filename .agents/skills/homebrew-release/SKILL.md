---
name: homebrew-release
description: Use when building, validating, publishing, or tap-rendering Homebrew formula tarball releases for this Swift project, including scripts/build-homebrew-release.sh, scripts/render-homebrew-formula.sh, and mise run build:homebrew or homebrew:formula commands.
---

# Homebrew Release

Use this skill for Formula releases installed with:

```bash
brew tap user/tap
brew install kaiba
```

Use `.agents/skills/macos-cask-release/SKILL.md` for signed and notarized Cask
DMGs.

## Release Contract

1. Confirm `VERSION` is the intended release version.
2. Build and test the Swift package.
3. Build macOS Homebrew tarballs with `scripts/build-homebrew-release.sh`.
4. Publish the tarballs to a GitHub Release only when explicitly requested.
5. Render the formula only after all referenced archives and checksums exist.
6. Update and verify the tap formula from the tap checkout.

The default Swift formula contract is macOS-only:

| Homebrew platform | Release asset |
| --- | --- |
| macOS Apple Silicon | `kaiba-<version>-darwin-arm64.tar.gz` |
| macOS Intel | `kaiba-<version>-darwin-x64.tar.gz` |

Do not add Linux assets unless the project has a reviewed Swift Linux runtime
contract.

## Standard Commands

Build:

```bash
mise run build
mise run test
mise run build:homebrew -- darwin-arm64 darwin-x64
```

Render locally:

```bash
version="$(tr -d '[:space:]' < VERSION)"
mise run homebrew:formula -- "$version"
```

Render into the default sibling tap:

```bash
version="$(tr -d '[:space:]' < VERSION)"
mise run homebrew:tap-formula -- "$version"
```

For a custom tap path:

```bash
version="$(tr -d '[:space:]' < VERSION)"
scripts/render-homebrew-formula.sh "$version" /path/to/homebrew-tap/Formula/kaiba.rb
```

## Publishing Notes

Before rendering a formula for public use, ensure the GitHub Release assets
exist:

```bash
version="$(tr -d '[:space:]' < VERSION)"
gh release view "v${version}" --repo user/repo
```

If publishing is explicitly requested:

```bash
version="$(tr -d '[:space:]' < VERSION)"
gh release upload "v${version}" \
  "dist/homebrew/kaiba-${version}-darwin-arm64.tar.gz" \
  "dist/homebrew/kaiba-${version}-darwin-x64.tar.gz" \
  --repo user/repo \
  --clobber
```

## Verification

From the tap checkout:

```bash
ruby -c Formula/kaiba.rb
brew audit --strict kaiba || brew audit --strict --formula kaiba
brew install user/tap/kaiba
kaiba --version
brew test user/tap/kaiba
```

If online audit fails because of local GitHub credentials or rate limits, run a
non-online audit and report the limitation.

## Tap API Metadata Gate

After pushing `Formula/kaiba.rb`, require `tacogips/homebrew-tap`'s
`update-api-metadata.yml` workflow to succeed for that commit. Verify the
GitHub Raw `api/formula/kaiba.json`: its `.versions.stable` must equal the
release version and its `.ruby_source_checksum.sha256` must equal the SHA-256
of the committed Formula. Do not consider the release complete while the
endpoint is missing or stale.
