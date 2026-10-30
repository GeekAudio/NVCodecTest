#!/bin/bash
set -euo pipefail
SELECTION_TEST_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELECTION_PROJECT_DIRECTORY="${SELECTION_TEST_DIRECTORY%/Tests}"
SELECTION_TEST_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/nvcodec-selection-tests.XXXXXX")"
trap 'rm -rf "$SELECTION_TEST_TEMP"' EXIT

swiftc -swift-version 5 -target "$(uname -m)-apple-macos11.0" \
  "$SELECTION_PROJECT_DIRECTORY/Sources/BenchModels.swift" \
  "$SELECTION_PROJECT_DIRECTORY/Sources/NullMothContract.swift" \
  "$SELECTION_PROJECT_DIRECTORY/Sources/EnvProbe.swift" \
  "$SELECTION_PROJECT_DIRECTORY/Sources/CodecBench.swift" \
  "$SELECTION_PROJECT_DIRECTORY/Sources/CodecTestPlan.swift" \
  "$SELECTION_PROJECT_DIRECTORY/Sources/DiagnosticLog.swift" \
  "$SELECTION_PROJECT_DIRECTORY/Sources/Feedback.swift" \
  "$SELECTION_PROJECT_DIRECTORY/Sources/CodecWorker.swift" \
  "$SELECTION_PROJECT_DIRECTORY/Sources/Reporting.swift" \
  "$SELECTION_PROJECT_DIRECTORY/Sources/TestHistory.swift" \
  "$SELECTION_PROJECT_DIRECTORY/Sources/TestModel.swift" \
  "$SELECTION_TEST_DIRECTORY/TestSelectionModelTests.swift" \
  -o "$SELECTION_TEST_TEMP/selection-model-tests" \
  -framework Foundation -framework AppKit -framework SwiftUI -framework Metal \
  -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework IOKit
"$SELECTION_TEST_TEMP/selection-model-tests"
