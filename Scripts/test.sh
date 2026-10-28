#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
. Scripts/apple-env.sh
export SWIFT_MODULECACHE_PATH="$PWD/.build/module-cache"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
swift test --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security "$@"
