#!/usr/bin/env bash
set -euo pipefail

# Assembles Kaiba.app from a built KaibaApp executable and (optionally) the
# built web SPA. Pure staging — no signing — so it runs locally without Apple
# credentials. The cask release builder signs and notarizes the result
# (`design-docs/specs/macos-menu-bar-app.md`).

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
app_name="Kaiba.app"
executable_name="KaibaApp"

usage() {
  cat <<EOF
Usage:
  scripts/assemble-macos-app-bundle.sh <executable-path> <version> <output-dir> [web-root]

Arguments:
  executable-path  Built KaibaApp Mach-O executable.
  version          Archive-safe version (e.g. 0.1.8); fills CFBundle*Version.
  output-dir       Directory to create Kaiba.app inside.
  web-root         Optional built SPA directory copied to Resources/web so the
                   app's "Open web UI" serves the reader.

Prints the assembled bundle path.
EOF
}

main() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" || "$#" -lt 3 ]]; then
    usage
    return 2
  fi

  local executable version output_dir web_root
  executable="$1"
  version="$2"
  output_dir="$3"
  web_root="${4:-}"

  if [[ ! -x "$executable" ]]; then
    printf 'missing or non-executable KaibaApp binary: %s\n' "$executable" >&2
    return 1
  fi
  if [[ ! "$version" =~ ^[0-9]+[.][0-9]+[.][0-9]+([-+][0-9A-Za-z][0-9A-Za-z.+-]*)?$ ]]; then
    printf 'unsafe app bundle version: %s\n' "$version" >&2
    return 1
  fi

  local template app_dir macos_dir resources_dir
  template="$repo_root/packaging/macos/Info.plist.template"
  if [[ ! -f "$template" ]]; then
    printf 'missing Info.plist template: %s\n' "$template" >&2
    return 1
  fi

  app_dir="$output_dir/$app_name"
  macos_dir="$app_dir/Contents/MacOS"
  resources_dir="$app_dir/Contents/Resources"

  rm -rf "$app_dir"
  mkdir -p "$macos_dir" "$resources_dir"

  cp "$executable" "$macos_dir/$executable_name"
  chmod 0755 "$macos_dir/$executable_name"

  sed "s/@VERSION@/$version/g" "$template" > "$app_dir/Contents/Info.plist"
  printf 'APPL????' > "$app_dir/Contents/PkgInfo"

  if [[ -n "$web_root" ]]; then
    if [[ ! -f "$web_root/index.html" ]]; then
      printf 'web-root has no index.html: %s\n' "$web_root" >&2
      return 1
    fi
    mkdir -p "$resources_dir/web"
    cp -R "$web_root/." "$resources_dir/web/"
  fi

  printf '%s\n' "$app_dir"
}

main "$@"
