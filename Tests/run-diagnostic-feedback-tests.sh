#!/bin/bash
set -euo pipefail
# 用途：验证脱敏、日志留存和反馈草稿；只用固定样本，不执行 GPU 或联网上传。
# 用法：./Tests/run-diagnostic-feedback-tests.sh
# 依赖：macOS、Xcode Command Line Tools；不需要 root。
DIAGNOSTIC_TEST_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIAGNOSTIC_PROJECT_DIRECTORY="${DIAGNOSTIC_TEST_DIRECTORY%/Tests}"
DIAGNOSTIC_TEST_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/nvcodec-diagnostic-tests.XXXXXX")"
trap 'rm -rf "$DIAGNOSTIC_TEST_TEMP"' EXIT

swiftc -swift-version 5 -target "$(uname -m)-apple-macos11.0" \
  "$DIAGNOSTIC_PROJECT_DIRECTORY/Sources/DiagnosticLog.swift" \
  "$DIAGNOSTIC_TEST_DIRECTORY/DiagnosticLogTests.swift" \
  -o "$DIAGNOSTIC_TEST_TEMP/diagnostic-log-tests" -framework Foundation
"$DIAGNOSTIC_TEST_TEMP/diagnostic-log-tests"

swiftc -swift-version 5 -target "$(uname -m)-apple-macos11.0" \
  "$DIAGNOSTIC_PROJECT_DIRECTORY/Sources/DiagnosticLog.swift" \
  "$DIAGNOSTIC_PROJECT_DIRECTORY/Sources/MeasurementValidity.swift" \
  "$DIAGNOSTIC_PROJECT_DIRECTORY/Sources/Feedback.swift" \
  "$DIAGNOSTIC_TEST_DIRECTORY/FeedbackTests.swift" \
  -o "$DIAGNOSTIC_TEST_TEMP/feedback-tests" -framework Foundation
"$DIAGNOSTIC_TEST_TEMP/feedback-tests"

swiftc -swift-version 5 -target "$(uname -m)-apple-macos11.0" \
  "$DIAGNOSTIC_PROJECT_DIRECTORY/Sources/MeasurementValidity.swift" \
  "$DIAGNOSTIC_PROJECT_DIRECTORY/Sources/BenchModels.swift" \
  "$DIAGNOSTIC_PROJECT_DIRECTORY/Sources/NullMothContract.swift" \
  "$DIAGNOSTIC_PROJECT_DIRECTORY/Sources/EnvProbe.swift" \
  "$DIAGNOSTIC_PROJECT_DIRECTORY/Sources/CodecTestPlan.swift" \
  "$DIAGNOSTIC_PROJECT_DIRECTORY/Sources/CodecBench.swift" \
  "$DIAGNOSTIC_PROJECT_DIRECTORY/Sources/DiagnosticLog.swift" \
  "$DIAGNOSTIC_PROJECT_DIRECTORY/Sources/CodecWorker.swift" \
  "$DIAGNOSTIC_PROJECT_DIRECTORY/Sources/Reporting.swift" \
  "$DIAGNOSTIC_TEST_DIRECTORY/DiagnosticRecorderTests.swift" \
  -o "$DIAGNOSTIC_TEST_TEMP/diagnostic-recorder-tests" \
  -framework Foundation -framework CoreMedia -framework Metal \
  -framework VideoToolbox -framework CoreVideo -framework IOKit
"$DIAGNOSTIC_TEST_TEMP/diagnostic-recorder-tests"
