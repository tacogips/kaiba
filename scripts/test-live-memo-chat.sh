#!/usr/bin/env bash
set -euo pipefail

# Explicit live-provider entry point. Never targets or clears the user's store.
if [[ "$(uname -s)" != Darwin ]]; then
  echo "This HTTP scenario requires macOS Network.framework." >&2
  exit 1
fi
if ! command -v agent-gateway >/dev/null 2>&1; then
  echo "Install agent-gateway and sign in to its Codex provider first." >&2
  exit 1
fi

# Keep SwiftPM and the symbol-graph/compiler helpers on the same Xcode toolchain.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
scenario_swift="$(xcrun --find swift)"
export PATH="$(dirname "$scenario_swift"):$PATH"
export KAIBA_LIVE_LUNA_SCENARIO=1
exec "$scenario_swift" test --filter LiveMemoChatScenarioTests
