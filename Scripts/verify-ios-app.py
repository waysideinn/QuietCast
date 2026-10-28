#!/usr/bin/env python3
"""Reject a simulator or malformed .app before packaging it for Sideloadly."""
import argparse, hashlib, json, pathlib, plistlib, re, subprocess
EXPECTED_ID = 'org.quietcast.family'

def inspect(app):
    app = pathlib.Path(app).resolve()
    info = plistlib.loads((app/'Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != EXPECTED_ID:
        raise ValueError('Unexpected Bundle ID; refusing to create a different application identity')
    if info.get('CFBundlePackageType') != 'APPL':
        raise ValueError('Not an iOS application bundle')
    executable = info.get('CFBundleExecutable', '')
    if not executable or pathlib.Path(executable).name != executable:
        raise ValueError('Invalid executable name')
    binary = app/executable
    if not binary.is_file() or binary.stat().st_size == 0:
        raise ValueError('Application executable is missing or empty')
    if info.get('CFBundleSupportedPlatforms') != ['iPhoneOS']:
        raise ValueError('Expected a physical-device iPhoneOS build, not an iPhone Simulator build')
    if not info.get('MinimumOSVersion') or tuple(int(v) for v in info['MinimumOSVersion'].split('.')[:2]) != (16, 0):
        raise ValueError('Expected the unchanged minimum deployment target iOS 16.0')
    if 'audio' not in info.get('UIBackgroundModes', []):
        raise ValueError('Background audio configuration missing')
    rules_file = app/'content-filter.json'
    rules = json.loads(rules_file.read_text())
    if rules.get('schemaVersion') not in ('1.0','1.1') or rules.get('status') not in ('example','production'):
        raise ValueError('Missing or unsupported bundled filtering rules')
    archs = subprocess.check_output(['xcrun','lipo','-archs',str(binary)], text=True).strip().split()
    if 'arm64' not in archs:
        raise ValueError('Physical-device arm64 architecture missing')
    output = subprocess.check_output(['xcrun','vtool','-show-build',str(binary)], text=True)
    platforms = re.findall(r'^\s*platform\s+(\S+)', output, re.MULTILINE)
    if not platforms or any(p not in ('IOS','2') for p in platforms):
        raise ValueError(f'Mach-O is not exclusively iOS device code: {platforms}')
    return {'appPath': str(app), 'bundleIdentifier': info['CFBundleIdentifier'],
            'minimumOSVersion': info['MinimumOSVersion'], 'architectures': archs,
            'ruleVersion': rules.get('ruleVersion'), 'ruleStatus': rules['status'],
            'rulesSHA256': hashlib.sha256(rules_file.read_bytes()).hexdigest(),
            'executableSHA256': hashlib.sha256(binary.read_bytes()).hexdigest(),
            'signedForInstallation': False, 'requiresSideloadlyResigning': True}

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('app', type=pathlib.Path)
    args = parser.parse_args()
    print(json.dumps(inspect(args.app), indent=2))
if __name__ == '__main__':
    main()
