#!/bin/sh
# Same core test functions, using a small assertion adapter when Command Line Tools lack XCTest.
set -eu
cd "$(dirname "$0")/.."
export SWIFT_MODULECACHE_PATH="$PWD/.build/module-cache"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
swift build --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security
BIN_DIR="$(swift build --show-bin-path --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security)"
python3 Scripts/generate_cli_runner.py
python3 Scripts/core-object-list.py "$BIN_DIR"
mkdir -p .build/CLIFixtures.bundle/Fixtures
cp Tests/PodcastCoreTests/Fixtures/* .build/CLIFixtures.bundle/Fixtures/
export QUIETCAST_TEST_RESOURCES="$PWD/.build/CLIFixtures.bundle"
swiftc -DCORE_CLI_TESTS -parse-as-library -enable-testing -I "$BIN_DIR/Modules" Tests/CLISupport.swift Tests/PodcastCoreTests/*Tests.swift .build/CLIRunner.swift @.build/core-objects.txt -o .build/core-tests
.build/core-tests "$@"
