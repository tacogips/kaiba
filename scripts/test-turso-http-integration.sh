#!/usr/bin/env bash

set -euo pipefail

command -v docker >/dev/null
command -v jq >/dev/null

repository=$(cd "$(dirname "$0")/.." && pwd)
kaiba_binary=${KAIBA_BINARY:-"$repository/.build/debug/kaiba"}
libsql_image=${LIBSQL_IMAGE:-"ghcr.io/tursodatabase/libsql-server@sha256:07d5da358f37f7f327cc33c1cb5278e7892e04225f011a65a76049372a308982"}
[[ -x "$kaiba_binary" ]]

mkdir -p "$repository/tmp"
work_directory=$(mktemp -d "$repository/tmp/turso-http-integration.XXXXXX")
container_name="kaiba-libsql-$RANDOM-$$"
cleanup() {
  docker stop "$container_name" >/dev/null 2>&1 || true
  if [[ "$work_directory" == "$repository/tmp/turso-http-integration."* ]]; then
    rm -rf "$work_directory"
  fi
}
trap cleanup EXIT

server_port=$(/usr/bin/python3 -c \
  'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
docker run --rm -d --name "$container_name" \
  -p "127.0.0.1:$server_port:8080" \
  "$libsql_image" >/dev/null
for _ in {1..200}; do
  if curl --silent --fail "http://127.0.0.1:$server_port/health" >/dev/null; then
    break
  fi
  sleep 0.1
done

configuration="$work_directory/kaiba.json"
jq -n --arg url "http://127.0.0.1:$server_port" \
  '{database: {kind: "turso", url: $url,
    authTokenEnvironmentVariable: "KAIBA_TURSO_TEST_TOKEN",
    allowInsecureLoopbackHTTP: true}, storageProfiles: []}' >"$configuration"

note_root="$work_directory/notes"
created=$(KAIBA_TURSO_TEST_TOKEN=test-token \
  "$kaiba_binary" --note-root "$note_root" --config "$configuration" \
  add --body '# Turso HTTP integration
Cross-process persistence and FTS.' --output json)
note_id=$(printf '%s' "$created" | jq -r .noteId)
listed=$(KAIBA_TURSO_TEST_TOKEN=test-token \
  "$kaiba_binary" --note-root "$note_root" --config "$configuration" \
  list --output json)
[[ $(printf '%s' "$listed" | jq -r '.[0].noteId') == "$note_id" ]]
searched=$(KAIBA_TURSO_TEST_TOKEN=test-token \
  "$kaiba_binary" --note-root "$note_root" --config "$configuration" \
  search persistence --output json)
[[ $(printf '%s' "$searched" | jq -r '.[0].noteId') == "$note_id" ]]

echo "Kaiba Turso/libSQL SQL-over-HTTP round trip passed"
