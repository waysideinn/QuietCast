#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
. Scripts/apple-env.sh
xcrun --sdk iphonesimulator --show-sdk-path >/dev/null
xcodebuild -project QuietCast.xcodeproj -scheme QuietCast -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build
