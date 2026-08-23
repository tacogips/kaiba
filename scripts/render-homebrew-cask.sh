#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
artifact_name="kaiba"
product="kaiba"

usage() {
  cat <<EOF
Usage:
  scripts/render-homebrew-cask.sh <version> [output-file]

Reads archive checksums from:
  dist/homebrew-cask/$artifact_name-<version>-<target>.dmg.sha256

Environment:
  CASK_RELEASE_DIR       Directory containing archives and .sha256 files.
  CASK_RELEASE_BASE_URL  Release URL base. Defaults to GitHub v<version>.

Example:
  scripts/build-homebrew-cask-release.sh darwin-arm64 darwin-x64
  scripts/render-homebrew-cask.sh 0.1.0 ../homebrew-tap/Casks/$artifact_name.rb

This renderer expects signed, notarized, and stapled macOS .dmg artifacts.
EOF
}

sha_for_target() {
  local version target release_dir sha_file
  version="$1"
  target="$2"
  release_dir="$3"
  sha_file="$release_dir/$artifact_name-$version-$target.dmg.sha256"

  if [[ ! -f "$sha_file" ]]; then
    printf 'missing checksum file: %s\n' "$sha_file" >&2
    return 1
  fi

  awk '{print $1}' "$sha_file"
}

main() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    return
  fi
  if [[ "${1:-}" == "" ]]; then
    usage
    return 2
  fi

  local version output release_dir release_base_url
  version="$1"
  output="${2:-$repo_root/Casks/$artifact_name.rb}"
  release_dir="${CASK_RELEASE_DIR:-$repo_root/dist/homebrew-cask}"
  release_base_url="${CASK_RELEASE_BASE_URL:-https://github.com/tacogips/kaiba/releases/download/v$version}"

  local darwin_arm64_sha darwin_x64_sha
  darwin_arm64_sha="$(sha_for_target "$version" darwin-arm64 "$release_dir")"
  darwin_x64_sha="$(sha_for_target "$version" darwin-x64 "$release_dir")"

  mkdir -p "$(dirname "$output")"
  cat > "$output" <<EOF
cask "kaiba" do
  version "$version"
  arch arm: "darwin-arm64", intel: "darwin-x64"

  sha256 arm: "$darwin_arm64_sha",
         intel: "$darwin_x64_sha"

  url "$release_base_url/$artifact_name-#{version}-#{arch}.dmg",
      verified: "github.com/tacogips/kaiba/releases/download/"
  name "kaiba"
  desc "System-memory service for AI agents"
  homepage "https://github.com/tacogips/kaiba"

  livecheck do
    url :url
    strategy :github_latest
  end

  app "Kaiba.app"
  binary "$product"

  caveats do
    <<~EOS
      This cask installs the signed and notarized Kaiba.app (a resident menu-bar
      app that runs the note server) and the $product command line tool.
      Launch Kaiba from Applications to keep the server running in the menu bar,
      or run '$product serve' from the CLI. Homebrew links $product into the
      native Homebrew prefix for this Mac.
    EOS
  end
end
EOF

  printf 'rendered %s\n' "$output"
}

main "$@"
