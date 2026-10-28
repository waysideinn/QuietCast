#!/bin/sh
# Build actual iPhone code and package an unsigned IPA for Sideloadly re-signing.
set -eu
cd "$(dirname "$0")/.."
. Scripts/apple-env.sh
xcrun --sdk iphoneos --show-sdk-path >/dev/null
xcodebuild -project QuietCast.xcodeproj -scheme QuietCast -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build/Device CODE_SIGNING_ALLOWED=NO build
APP_PATH="$PWD/build/Device/Build/Products/Release-iphoneos/QuietCast.app"
mkdir -p build/delivery
python3 Scripts/verify-ios-app.py "$APP_PATH" > build/delivery/device-app.json
STAGING_PATH="$(mktemp -d "$PWD/build/ipa-staging.XXXXXX")"
trap 'rm -rf "$STAGING_PATH"' EXIT HUP INT TERM
mkdir -p "$STAGING_PATH/Payload"
/usr/bin/ditto "$APP_PATH" "$STAGING_PATH/Payload/QuietCast.app"
/usr/bin/ditto -c -k --keepParent "$STAGING_PATH/Payload" "$STAGING_PATH/QuietCast-unsigned.ipa"
python3 - "$STAGING_PATH/QuietCast-unsigned.ipa" <<'PY'
import plistlib,sys,zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    assert z.testzip() is None
    info=plistlib.loads(z.read('Payload/QuietCast.app/Info.plist'))
    assert info['CFBundleIdentifier']=='org.quietcast.family'
    assert info['CFBundleSupportedPlatforms']==['iPhoneOS']
    assert 'Payload/QuietCast.app/'+info['CFBundleExecutable'] in z.namelist()
PY
mv "$STAGING_PATH/QuietCast-unsigned.ipa" build/QuietCast-unsigned.ipa
python3 - <<'PY'
import hashlib,json,pathlib,subprocess
ipa=pathlib.Path('build/QuietCast-unsigned.ipa').resolve()
manifest=json.loads(pathlib.Path('build/delivery/device-app.json').read_text())
manifest.update(ipaPath=str(ipa),ipaSHA256=hashlib.sha256(ipa.read_bytes()).hexdigest(),sourceCommit=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),sourceTrackedDirty=bool(subprocess.check_output(['git','status','--porcelain','--untracked-files=no'],text=True).strip()))
pathlib.Path('build/delivery/ipa-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print(f'Produced {ipa}. Unsigned: install only after Sideloadly re-signing.')
PY
