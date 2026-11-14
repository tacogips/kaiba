#!/usr/bin/env bash

set -euo pipefail

command -v aws >/dev/null
command -v curl >/dev/null
command -v docker >/dev/null
command -v jq >/dev/null
command -v openssl >/dev/null

repository=$(cd "$(dirname "$0")/.." && pwd)
gateway_repository=${S3_GATEWAY_REPOSITORY:-"$repository/../s3-gateway"}
kaiba_binary=${KAIBA_BINARY:-"$repository/.build/debug/kaiba"}
gateway_binary=${GATEWAY_BINARY:-"$gateway_repository/.build/debug/s3-gateway"}
minio_image=${MINIO_IMAGE:-"quay.io/minio/minio@sha256:14cea493d9a34af32f524e538b8346cf79f3321eff8e708c1e2960462bd8936e"}

[[ -x "$kaiba_binary" ]]
[[ -x "$gateway_binary" ]]

mkdir -p "$repository/tmp"
work_directory=$(mktemp -d "$repository/tmp/s3-gateway-integration.XXXXXX")
gateway_pid=
minio_name="kaiba-minio-$RANDOM-$$"

cleanup() {
  if [[ -n "$gateway_pid" ]]; then
    kill -TERM "$gateway_pid" 2>/dev/null || true
    wait "$gateway_pid" 2>/dev/null || true
  fi
  docker stop "$minio_name" >/dev/null 2>&1 || true
  if [[ "$work_directory" == "$repository/tmp/s3-gateway-integration."* ]]; then
    rm -rf "$work_directory"
  fi
}
trap cleanup EXIT

available_port() {
  /usr/bin/python3 -c \
    'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

gateway_port=$(available_port)
minio_port=$(available_port)
inbound_access_key=KAIBAGATEWAYCLIENT
inbound_secret_key=kaiba-gateway-client-secret
minio_access_key=KAIBAMINIOADMIN
minio_secret_key=kaiba-minio-admin-secret

inbound_file="$work_directory/inbound.json"
upstream_file="$work_directory/upstream.json"
pagination_file="$work_directory/pagination.json"
jq -n \
  --arg access_key "$inbound_access_key" \
  --arg secret "$inbound_secret_key" \
  '{version: 1, records: [{accessKeyID: $access_key, secretAccessKey: $secret,
    principalID: "kaiba-client", enabled: true}]}' >"$inbound_file"
jq -n \
  --arg access_key "$minio_access_key" \
  --arg secret "$minio_secret_key" \
  '{version: 1, active: {accessKeyID: $access_key, secretAccessKey: $secret,
    sessionToken: null}}' >"$upstream_file"
jq -n \
  --arg secret "$(openssl rand -base64 32)" \
  '{version: 1, activeKeyID: "kaiba-page", keys: [{keyID: "kaiba-page",
    secretBase64: $secret, enabled: true}]}' >"$pagination_file"
chmod 600 "$inbound_file" "$upstream_file" "$pagination_file"

start_gateway() {
  local configuration=$1
  local ready_url="http://127.0.0.1:$gateway_port/.well-known/s3-gateway/ready"
  "$gateway_binary" serve --config "$configuration" \
    >"$work_directory/gateway.stdout" \
    2>"$work_directory/gateway.stderr" &
  gateway_pid=$!
  for _ in {1..100}; do
    if curl --silent --fail "$ready_url" >/dev/null; then
      return
    fi
    if ! kill -0 "$gateway_pid" 2>/dev/null; then
      sed -n '1,120p' "$work_directory/gateway.stderr" >&2
      return 1
    fi
    sleep 0.05
  done
  curl --silent --fail "$ready_url" >/dev/null
}

stop_gateway() {
  kill -TERM "$gateway_pid"
  wait "$gateway_pid" 2>/dev/null || true
  gateway_pid=
}

run_kaiba_round_trip() {
  local label=$1
  local config_path=$2
  local note_root="$work_directory/notes-$label"
  local input_file="$work_directory/input-$label.txt"
  local output_file="$work_directory/output-$label.txt"
  printf 'Kaiba via s3-gateway: %s\n' "$label" >"$input_file"

  local created note_id attached file_id migrated
  created=$(KAIBA_S3_ACCESS_KEY="$inbound_access_key" \
    KAIBA_S3_SECRET_KEY="$inbound_secret_key" \
    "$kaiba_binary" --note-root "$note_root" --config "$config_path" \
    add --body "# S3 gateway $label" --output json)
  note_id=$(printf '%s' "$created" | jq -r .noteId)
  attached=$(KAIBA_S3_ACCESS_KEY="$inbound_access_key" \
    KAIBA_S3_SECRET_KEY="$inbound_secret_key" \
    "$kaiba_binary" --note-root "$note_root" --config "$config_path" \
    attach "$note_id" "$input_file")
  file_id=$(printf '%s' "$attached" | sed -E 's/^Attached ([^ ]+).*/\1/')
  migrated=$(KAIBA_S3_ACCESS_KEY="$inbound_access_key" \
    KAIBA_S3_SECRET_KEY="$inbound_secret_key" \
    "$kaiba_binary" --note-root "$note_root" --config "$config_path" \
    storage migrate "$file_id" --profile gateway)
  [[ "$migrated" == "Migrated $file_id to s3://kaiba-files/"* ]]
  KAIBA_S3_ACCESS_KEY="$inbound_access_key" \
    KAIBA_S3_SECRET_KEY="$inbound_secret_key" \
    "$kaiba_binary" --note-root "$note_root" --config "$config_path" \
    file "$file_id" --out "$output_file" >/dev/null
  cmp "$input_file" "$output_file"
}

write_kaiba_config() {
  local destination=$1
  jq -n \
    --arg endpoint "http://127.0.0.1:$gateway_port" \
    '{database: {kind: "sqlite"}, storageProfiles: [{
      name: "gateway", endpoint: $endpoint, region: "us-east-1",
      bucket: "kaiba-files", accessKeyIdEnvironmentVariable: "KAIBA_S3_ACCESS_KEY",
      secretAccessKeyEnvironmentVariable: "KAIBA_S3_SECRET_KEY", keyPrefix: "attachments"
    }]}' >"$destination"
}

posix_root="$work_directory/posix-root"
posix_sidecar="$work_directory/posix-sidecar"
mkdir -p "$posix_root" "$posix_sidecar"
chmod 700 "$posix_sidecar"
posix_configuration="$work_directory/gateway-posix.json"
jq -n \
  --argjson port "$gateway_port" \
  --arg inbound "$inbound_file" \
  --arg upstream "$upstream_file" \
  --arg pagination "$pagination_file" \
  --arg root "$posix_root" \
  --arg sidecar "$posix_sidecar" \
  '{listener: {host: "127.0.0.1", port: $port, tls: null,
      developmentPlaintext: true, trustedProxyAddresses: []},
    limits: {maximumHeaderBytes: 32768, maximumXMLBytes: 1048576,
      maximumObjectBytes: 104857600, maximumChunkBytes: 65536,
      maximumInFlightBytes: 8388608, maximumConcurrentRequests: 16,
      requestTimeoutSeconds: 30},
    addressingStyles: ["path"], virtualHostSuffixes: [], acceptedSigV4Regions: ["us-east-1"],
    health: {livenessPath: "/.well-known/s3-gateway/live",
      readinessPath: "/.well-known/s3-gateway/ready"},
    telemetry: {enabled: false},
    credentials: {inboundPath: $inbound, upstreamPath: $upstream, paginationPath: $pagination},
    authorization: [{principalID: "kaiba-client", grants: [{
      operations: ["getObject", "headObject", "putObject", "deleteObject", "listObjectsV2"],
      bucket: "kaiba-files", keyPrefix: null}]}],
    backend: {kind: "posix", posix: {rootPath: $root,
      bucketDirectories: {"kaiba-files": "bucket"}, layoutPolicy: "sharedLocalDirectory",
      sidecarPath: $sidecar, durability: "data"}}}' >"$posix_configuration"
posix_kaiba_configuration="$work_directory/kaiba-posix.json"
write_kaiba_config "$posix_kaiba_configuration"
start_gateway "$posix_configuration"
run_kaiba_round_trip posix "$posix_kaiba_configuration"
stop_gateway
echo "Kaiba + s3-gateway POSIX round trip passed"

certificate_directory="$work_directory/minio-certs"
mkdir -p "$certificate_directory"
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$certificate_directory/private.key" \
  -out "$certificate_directory/public.crt" \
  -days 1 -subj /CN=localhost -addext subjectAltName=DNS:localhost \
  >/dev/null 2>&1
chmod 600 "$certificate_directory/private.key"
docker run --rm -d --name "$minio_name" \
  -p "127.0.0.1:$minio_port:9000" \
  -e MINIO_ROOT_USER="$minio_access_key" \
  -e MINIO_ROOT_PASSWORD="$minio_secret_key" \
  -v "$certificate_directory:/root/.minio/certs:ro" \
  "$minio_image" server /data >/dev/null
for _ in {1..200}; do
  if curl --silent --fail --cacert "$certificate_directory/public.crt" \
    "https://localhost:$minio_port/minio/health/ready" >/dev/null; then
    break
  fi
  sleep 0.1
done
AWS_ACCESS_KEY_ID="$minio_access_key" AWS_SECRET_ACCESS_KEY="$minio_secret_key" \
  AWS_DEFAULT_REGION=us-east-1 AWS_CA_BUNDLE="$certificate_directory/public.crt" \
  aws --endpoint-url "https://localhost:$minio_port" --no-cli-pager \
  s3api create-bucket --bucket kaiba-upstream >/dev/null

gateway_port=$(available_port)
s3_staging="$work_directory/s3-staging"
mkdir -p "$s3_staging"
chmod 700 "$s3_staging"
s3_configuration="$work_directory/gateway-s3.json"
jq -n \
  --argjson port "$gateway_port" \
  --arg inbound "$inbound_file" \
  --arg upstream "$upstream_file" \
  --arg pagination "$pagination_file" \
  --arg endpoint "https://localhost:$minio_port" \
  --arg staging "$s3_staging" \
  --arg ca "$certificate_directory/public.crt" \
  '{listener: {host: "127.0.0.1", port: $port, tls: null,
      developmentPlaintext: true, trustedProxyAddresses: []},
    limits: {maximumHeaderBytes: 32768, maximumXMLBytes: 1048576,
      maximumObjectBytes: 104857600, maximumChunkBytes: 65536,
      maximumInFlightBytes: 8388608, maximumConcurrentRequests: 16,
      requestTimeoutSeconds: 30},
    addressingStyles: ["path"], virtualHostSuffixes: [], acceptedSigV4Regions: ["us-east-1"],
    health: {livenessPath: "/.well-known/s3-gateway/live",
      readinessPath: "/.well-known/s3-gateway/ready"},
    telemetry: {enabled: false},
    credentials: {inboundPath: $inbound, upstreamPath: $upstream, paginationPath: $pagination},
    authorization: [{principalID: "kaiba-client", grants: [{
      operations: ["getObject", "headObject", "putObject", "deleteObject", "listObjectsV2"],
      bucket: "kaiba-files", keyPrefix: null}]}],
    backend: {kind: "s3", s3: {endpoint: $endpoint, region: "us-east-1",
      addressingStyle: "path", bucketMappings: {"kaiba-files": "kaiba-upstream"},
      stagingDirectory: $staging, trustedCAPath: $ca}}}' >"$s3_configuration"
s3_kaiba_configuration="$work_directory/kaiba-s3.json"
write_kaiba_config "$s3_kaiba_configuration"
start_gateway "$s3_configuration"
run_kaiba_round_trip minio "$s3_kaiba_configuration"
stop_gateway
echo "Kaiba + s3-gateway + MinIO round trip passed"
