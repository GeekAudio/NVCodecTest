#!/bin/bash
set -euo pipefail
PROBE_TEST_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "${PROBE_TEST_ROOT%/Tests}"
PROBE_TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$PROBE_TEST_TMP"' EXIT
swiftc -swift-version 5 -target "$(uname -m)-apple-macos11.0" \
  Sources/EnvProbe.swift Tests/EnvProbeTests.swift -o "$PROBE_TEST_TMP/env-probe-tests" \
  -framework Foundation -framework Metal -framework VideoToolbox -framework CoreVideo -framework IOKit
"$PROBE_TEST_TMP/env-probe-tests"
