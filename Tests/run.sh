#!/bin/bash
# Builds and runs the JSONFilter tests natively on macOS (no device, no Theos).
set -e
cd "$(dirname "$0")/.."
mkdir -p build
# xcrun pins compiler and SDK to the selected Xcode (a newer CommandLineTools SDK breaks linking)
env -u SDKROOT xcrun --sdk macosx clang -fobjc-arc -Wall -I. -framework Foundation JSONFilter.m Tests/JSONFilterTests.m -o build/jsonfilter-tests
build/jsonfilter-tests Tests/Fixtures
