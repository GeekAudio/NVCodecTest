#!/bin/bash
set -euo pipefail
# 用途：用固定样本验证生产会话归属与模型计数，不创建 VT 会话或执行硬件探针。
# 用法：./Tests/run-session-evidence-tests.sh
# 依赖：macOS、Xcode Command Line Tools；不需要 root。
SESSION_TEST_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION_PROJECT_DIRECTORY="${SESSION_TEST_DIRECTORY%/Tests}"
SESSION_TEST_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/nvcodec-session-tests.XXXXXX")"
trap 'rm -rf "$SESSION_TEST_TEMP"' EXIT
SESSION_CORE_SOURCES=(
  "$SESSION_PROJECT_DIRECTORY/Sources/BenchModels.swift"
  "$SESSION_PROJECT_DIRECTORY/Sources/NullMothContract.swift"
  "$SESSION_PROJECT_DIRECTORY/Sources/EnvProbe.swift"
  "$SESSION_PROJECT_DIRECTORY/Sources/CodecBench.swift"
)
SESSION_FRAMEWORKS=(-framework Foundation -framework CoreMedia -framework Metal -framework VideoToolbox -framework CoreVideo -framework IOKit)

swiftc -swift-version 5 -target "$(uname -m)-apple-macos11.0" \
  "${SESSION_CORE_SOURCES[@]}" "$SESSION_TEST_DIRECTORY/SessionEvidenceTests.swift" \
  -o "$SESSION_TEST_TEMP/session-evidence-tests" "${SESSION_FRAMEWORKS[@]}"
"$SESSION_TEST_TEMP/session-evidence-tests"

swiftc -swift-version 5 -target "$(uname -m)-apple-macos11.0" -D MODEL_COUNT_ONLY \
  "${SESSION_CORE_SOURCES[@]}" \
  "$SESSION_PROJECT_DIRECTORY/Sources/DiagnosticLog.swift" \
  "$SESSION_PROJECT_DIRECTORY/Sources/CodecWorker.swift" \
  "$SESSION_PROJECT_DIRECTORY/Sources/Reporting.swift" \
  "$SESSION_PROJECT_DIRECTORY/Sources/Feedback.swift" \
  "$SESSION_PROJECT_DIRECTORY/Sources/TestModel.swift" \
  "$SESSION_TEST_DIRECTORY/SessionEvidenceTests.swift" \
  -o "$SESSION_TEST_TEMP/encoder-model-tests" "${SESSION_FRAMEWORKS[@]}" -framework AppKit -framework SwiftUI
"$SESSION_TEST_TEMP/encoder-model-tests"
