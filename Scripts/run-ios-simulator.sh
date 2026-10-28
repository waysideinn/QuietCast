#!/bin/sh
# Installation/launch smoke check only. This does not certify feature or physical-device behavior.
set -eu
cd "$(dirname "$0")/.."
. Scripts/apple-env.sh
mkdir -p build/delivery
xcrun simctl list devices available -j > build/delivery/simulator-devices.json
SIMULATOR_ID="$(python3 - <<'PY'
import json,os,sys
rows=[]
for runtime,devices in json.load(open('build/delivery/simulator-devices.json'))['devices'].items():
    if 'iOS-' not in runtime: continue
    for device in devices:
        if device.get('isAvailable',True) and (device.get('deviceTypeIdentifier','').split('.')[-1].startswith('iPhone') or device.get('name','').startswith('iPhone')):
            rows.append(device)
wanted=os.environ.get('QUIETCAST_SIMULATOR_UDID')
if wanted:
    rows=[row for row in rows if row['udid']==wanted]
if not rows:
    sys.exit('No available iPhone simulator. Install an iOS Simulator runtime in Xcode Settings > Components and add an iPhone device.')
rows.sort(key=lambda row: (row['state']!='Booted',row['name']),reverse=False)
print(rows[0]['udid'])
PY
)"
export QUIETCAST_SIMULATOR_ID="$SIMULATOR_ID"
Scripts/build-ios.sh > build/delivery/simulator-build.log 2>&1
python3 - <<'PY'
import json,os,subprocess
id=os.environ['QUIETCAST_SIMULATOR_ID']
rows=[row for values in json.load(open('build/delivery/simulator-devices.json'))['devices'].values() for row in values]
if next(row for row in rows if row['udid']==id)['state']!='Booted':
    subprocess.run(['xcrun','simctl','boot',id],check=True,timeout=60)
subprocess.run(['xcrun','simctl','bootstatus',id,'-b'],check=True,timeout=180)
PY
APP_PATH="$PWD/build/DerivedData/Build/Products/Debug-iphonesimulator/QuietCast.app"
xcrun simctl install "$SIMULATOR_ID" "$APP_PATH"
xcrun simctl launch "$SIMULATOR_ID" org.quietcast.family > build/delivery/simulator-launch.txt
xcrun simctl io "$SIMULATOR_ID" screenshot --display=primary build/delivery/simulator-launch.png
python3 - <<'PY'
import json,os,pathlib
report={'simulatorUDID':os.environ['QUIETCAST_SIMULATOR_ID'],
        'bundleIdentifier':'org.quietcast.family',
        'installAndLaunchCommandsSucceeded':True,'featureTestsPassed':False,'physicalDeviceVerified':False,
        'notVerified':['background audio','progress across device restart','subscriptions in UI','real download/offline audio','PIN/keychain on iPhone','all UI filter entrances','Sideloadly install/refresh'],
        'nextStep':'Complete Docs/DEVICE_ACCEPTANCE.md; this is only an installation/launch smoke result.'}
pathlib.Path('build/delivery/simulator-smoke.json').write_text(json.dumps(report,indent=2)+'\n')
print('Simulator install/launch commands completed. No feature or iPhone verification is claimed.')
PY
