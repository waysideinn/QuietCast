# Source from project-root scripts. Select an installed full Xcode for this process only.
QUIETCAST_DEVELOPER_DIR="$(python3 Scripts/ios-preflight.py --print-developer-dir)" || return 2
export DEVELOPER_DIR="$QUIETCAST_DEVELOPER_DIR"
if ! xcodebuild -version >/dev/null 2>&1; then
    printf '%s\n' 'Open Xcode once and complete its license / first-launch component installation.' >&2
    return 2
fi
