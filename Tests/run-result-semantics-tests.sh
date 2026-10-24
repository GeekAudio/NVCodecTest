#!/bin/bash
set -euo pipefail
# 用途：验证 NVIDIA 归属、测试状态及结构化报告，不访问 GPU 或执行环境探针。
# 用法：./Tests/run-result-semantics-tests.sh
# 依赖：macOS、Xcode Command Line Tools（swiftc）；不需要 root。
RESULT_TEST_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULT_PROJECT_DIRECTORY="${RESULT_TEST_DIRECTORY%/Tests}"
RESULT_TEST_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/nvcodec-result-tests.XXXXXX")"
trap 'rm -rf "$RESULT_TEST_TEMP"' EXIT
swiftc -swift-version 5 -target "$(uname -m)-apple-macos11.0" \
  "$RESULT_PROJECT_DIRECTORY/Sources/BenchModels.swift" \
  "$RESULT_PROJECT_DIRECTORY/Sources/EnvProbe.swift" \
  "$RESULT_PROJECT_DIRECTORY/Sources/CodecBench.swift" \
  "$RESULT_PROJECT_DIRECTORY/Sources/Reporting.swift" \
  "$RESULT_TEST_DIRECTORY/ResultSemanticsTests.swift" \
  -o "$RESULT_TEST_TEMP/result-semantics-tests" \
  -framework Foundation -framework CoreMedia -framework Metal \
  -framework VideoToolbox -framework CoreVideo -framework IOKit
"$RESULT_TEST_TEMP/result-semantics-tests"
