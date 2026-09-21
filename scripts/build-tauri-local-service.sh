#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${TAURI_ENV_PLATFORM:-}" == "ios" || "${TAURI_ENV_PLATFORM:-}" == "android" ]]; then
  exit 0
fi
cd "$repo_root"
scripts/build-anydoc-native.sh
configuration="${1:-debug}"
target="${TAURI_ENV_TARGET_TRIPLE:-$(rustc -vV | sed -n 's/^host: //p')}"
case "$target" in
  aarch64-apple-darwin) swift_target="arm64-apple-macosx14.0" ;;
  x86_64-apple-darwin) swift_target="x86_64-apple-macosx14.0" ;;
  *) printf 'Unsupported local service target: %s\n' "$target" >&2; exit 1 ;;
esac
swift build -c "$configuration" --triple "$swift_target" --product kaiba
binary_dir="$(swift build -c "$configuration" --triple "$swift_target" --show-bin-path)"
mkdir -p web/src-tauri/local-service
cp "$binary_dir/kaiba" "web/src-tauri/local-service/kaiba-$target"
