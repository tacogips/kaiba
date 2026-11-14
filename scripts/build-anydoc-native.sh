#!/usr/bin/env bash
# Resolve anydoc-swift and stage its Rust FFI for AnydocKit linkage.
# Usage: scripts/build-anydoc-native.sh [rust-target]
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rust_target="${1:-}"

if [[ "$rust_target" == */* || "$rust_target" == *..* ]]; then
  echo "error: invalid Rust target triple: $rust_target" >&2
  exit 2
fi

if [ -n "$rust_target" ] && ! rustup target list --installed | grep -Fxq "$rust_target"; then
  rustup target add "$rust_target"
fi

cd "$repo_root"
swift package resolve

anydoc_checkout="$repo_root/.build/checkouts/anydoc-swift"
if [ ! -x "$anydoc_checkout/scripts/build-native.sh" ]; then
  echo "error: resolved anydoc-swift checkout is missing its native builder" >&2
  exit 1
fi

prefix_name="${rust_target:-host}"
anydoc_prefix="$repo_root/.build/anydoc-native/$prefix_name"
arguments=(--prefix "$anydoc_prefix")
if [ -n "$rust_target" ]; then
  arguments+=(--target "$rust_target")
fi

"$anydoc_checkout/scripts/build-native.sh" "${arguments[@]}"
printf '%s\n' "$anydoc_prefix/pkgconfig"
