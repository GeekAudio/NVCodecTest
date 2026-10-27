#!/bin/bash
set -euo pipefail
CONTRACT_TEST_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
cd "${CONTRACT_TEST_DIRECTORY%/Tests}"
CONTRACT_TEST_TEMP="$(mktemp -d)"
trap 'rm -rf "$CONTRACT_TEST_TEMP"' EXIT
swiftc -swift-version 5 -target "$(uname -m)-apple-macos11.0" Sources/NullMothContract.swift Sources/EnvProbe.swift Tests/NullMothContractTests.swift -o "$CONTRACT_TEST_TEMP/contract-tests" -framework Foundation -framework Metal -framework VideoToolbox -framework CoreVideo -framework IOKit
"$CONTRACT_TEST_TEMP/contract-tests"
