#!/bin/sh
# Hosted native XCTest. This does not certify physical-device behavior.
set -eu
cd "$(dirname "$0")/.."
. Scripts/apple-env.sh
mkdir -p build/delivery
if [ -z "${QUIETCAST_SIMULATOR_UDID:-}" ]; then
    printf '%s\n' 'Set QUIETCAST_SIMULATOR_UDID to a dedicated available iPhone simulator UDID (xcrun simctl list devices available).' >&2
    exit 2
fi
RESULT_PATH="$PWD/build/delivery/iOSVerification-$(date +%Y%m%d-%H%M%S).xcresult"
xcodebuild -project QuietCast.xcodeproj -scheme QuietCast -configuration Debug \
    -destination "platform=iOS Simulator,id=$QUIETCAST_SIMULATOR_UDID" \
    -derivedDataPath build/Verification -resultBundlePath "$RESULT_PATH" \
    -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- test
printf 'XCTest result: %s\n' "$RESULT_PATH"
