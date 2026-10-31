#!/bin/bash
set -euo pipefail
HISTORY_TEST_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HISTORY_PROJECT_DIRECTORY="${HISTORY_TEST_DIRECTORY%/Tests}"
HISTORY_TEST_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/nvcodec-history-tests.XXXXXX")"
trap 'rm -rf "$HISTORY_TEST_TEMP"' EXIT

swiftc -swift-version 5 -target "$(uname -m)-apple-macos11.0" \
  "$HISTORY_PROJECT_DIRECTORY/Sources/MeasurementValidity.swift" \
  "$HISTORY_PROJECT_DIRECTORY/Sources/BenchModels.swift" \
  "$HISTORY_PROJECT_DIRECTORY/Sources/CodecTestPlan.swift" \
  "$HISTORY_PROJECT_DIRECTORY/Sources/NullMothContract.swift" \
  "$HISTORY_PROJECT_DIRECTORY/Sources/EnvProbe.swift" \
  "$HISTORY_PROJECT_DIRECTORY/Sources/CodecBench.swift" \
  "$HISTORY_PROJECT_DIRECTORY/Sources/DiagnosticLog.swift" \
  "$HISTORY_PROJECT_DIRECTORY/Sources/CodecWorker.swift" \
  "$HISTORY_PROJECT_DIRECTORY/Sources/Reporting.swift" \
  "$HISTORY_PROJECT_DIRECTORY/Sources/TestHistory.swift" \
  "$HISTORY_TEST_DIRECTORY/TestHistoryTests.swift" \
  -o "$HISTORY_TEST_TEMP/test-history-tests" \
  -framework Foundation -framework AppKit -framework Metal \
  -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework IOKit
"$HISTORY_TEST_TEMP/test-history-tests"
