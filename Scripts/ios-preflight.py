#!/usr/bin/env python3
"""Read-only Apple development environment audit; never installs tools or changes system selection."""
import argparse, glob, json, os, pathlib, shutil, subprocess, sys

def run(args, env=None):
    try:
        r = subprocess.run(args, capture_output=True, text=True, env=env, timeout=30)
        return {'exitCode': r.returncode, 'stdout': r.stdout.strip(), 'stderr': r.stderr.strip()}
    except (OSError, subprocess.TimeoutExpired) as error:
        return {'exitCode': -1, 'stdout': '', 'stderr': str(error)}

def developer_directory():
    candidates = []
    if os.environ.get('DEVELOPER_DIR'):
        candidates.append(os.environ['DEVELOPER_DIR'])
    selected = run(['/usr/bin/xcode-select', '-p'])['stdout']
    if selected:
        candidates.append(selected)
    candidates += ['/Applications/Xcode.app/Contents/Developer']
    candidates += sorted(glob.glob('/Applications/Xcode*.app/Contents/Developer'))
    candidates += sorted(glob.glob(str(pathlib.Path.home()/'Applications/Xcode*.app/Contents/Developer')))
    for candidate in candidates:
        p = pathlib.Path(candidate)
        if p.suffix == '.app':
            p = p/'Contents/Developer'
        if (p/'usr/bin/xcodebuild').is_file() and (p/'Platforms').is_dir():
            return str(p.resolve())
    return None

def audit():
    dev = developer_directory()
    env = dict(os.environ)
    if dev:
        env['DEVELOPER_DIR'] = dev
    result = {
        'bundleIdentifier': 'org.quietcast.family',
        'selectedDeveloperDirectory': run(['/usr/bin/xcode-select','-p']),
        'usableDeveloperDirectory': dev,
        'commandLineTools': run(['/usr/sbin/pkgutil','--pkg-info=com.apple.pkg.CLTools_Executables']),
        'macOS': run(['/usr/bin/sw_vers']),
        'freeGiB': round(shutil.disk_usage(pathlib.Path.cwd()).free / 1024**3, 1),
        'xcode': run(['/usr/bin/xcodebuild','-version'], env),
        'codesigningIdentities': run(['/usr/bin/security','find-identity','-v','-p','codesigning']),
        'sideloadlyInstalled': bool(glob.glob('/Applications/*Sideloadly*.app') + glob.glob(str(pathlib.Path.home()/'Applications/*Sideloadly*.app'))),
        'sdks': {}, 'runtimes': None,
    }
    errors = []
    if not dev:
        errors.append('Full Xcode was not found. Command Line Tools alone cannot build an iOS app.')
    if result['xcode']['exitCode'] != 0:
        errors.append('Xcode is unavailable or its first-launch setup/license has not completed.')
    for sdk in ('iphoneos','iphonesimulator'):
        check = run(['/usr/bin/xcrun','--sdk',sdk,'--show-sdk-path'], env)
        result['sdks'][sdk] = check
        if check['exitCode'] != 0:
            errors.append(f'{sdk} SDK is unavailable.')
    if dev:
        result['runtimes'] = run(['/usr/bin/xcrun','simctl','list','runtimes','-j'], env)
    result['buildReady'] = not errors
    result['blockingReasons'] = errors
    return result

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--print-developer-dir', action='store_true')
    parser.add_argument('--report', type=pathlib.Path)
    args = parser.parse_args()
    if args.print_developer_dir:
        dev = developer_directory()
        if not dev:
            print('Full Xcode missing. Install and open Xcode, then install iOS components. Do not reinstall Command Line Tools.', file=sys.stderr)
            return 2
        print(dev)
        return 0
    result = audit()
    encoded = json.dumps(result, ensure_ascii=False, indent=2) + '\n'
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(encoded)
    print(encoded, end='')
    return 0 if result['buildReady'] else 2
if __name__ == '__main__':
    sys.exit(main())
