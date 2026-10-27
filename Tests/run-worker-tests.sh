#!/bin/bash
set -euo pipefail
WORKER_TEST_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
cd "${WORKER_TEST_DIRECTORY%/Tests}"
WORKER_TEST_TEMP="$(mktemp -d)"
trap 'rm -rf "$WORKER_TEST_TEMP"' EXIT
swiftc -swift-version 5 -target "$(uname -m)-apple-macos11.0" Sources/BenchModels.swift Sources/NullMothContract.swift Sources/EnvProbe.swift Sources/CodecBench.swift Sources/DiagnosticLog.swift Sources/Reporting.swift Sources/CodecWorker.swift Tests/CodecWorkerTests.swift -o "$WORKER_TEST_TEMP/worker-tests" -framework Foundation -framework Metal -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework IOKit
"$WORKER_TEST_TEMP/worker-tests"
