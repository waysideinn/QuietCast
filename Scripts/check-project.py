#!/usr/bin/env python3
"""Static packaging checks, not an iOS build or device test."""
import json, pathlib, plistlib, subprocess, xml.etree.ElementTree as ET
root=pathlib.Path(__file__).resolve().parents[1]
info=plistlib.loads((root/'App/Info.plist').read_bytes())
assert info['UIBackgroundModes']==['audio']
assert info['CFBundleURLTypes'][0]['CFBundleURLSchemes']==['quietcast']
assert info['UIFileSharingEnabled'] is False
pbx=json.loads(subprocess.check_output(['plutil','-convert','json','-o','-',str(root/'QuietCast.xcodeproj/project.pbxproj')]))
objects=pbx['objects']; targets=[o for o in objects.values() if o.get('isa')=='PBXNativeTarget'];assert len([o for o in targets if o.get('productType')=='com.apple.product-type.application'])==1
assert targets[0]['productType']=='com.apple.product-type.application'
refs={o.get('path') for o in objects.values() if o.get('isa')=='PBXFileReference'}
for file in (root/'App').rglob('*.swift'): assert str(file.relative_to(root)) in refs, file
for file in refs:
    if not file.endswith(('.app','.xctest')): assert (root/file).exists(), file
assert 'PodcastCore' in {o.get('productName') for o in objects.values() if o.get('isa')=='XCSwiftPackageProductDependency'}
for o in objects.values():
    if o.get('isa')=='XCBuildConfiguration':
        s=o['buildSettings']
        if 'PRODUCT_BUNDLE_IDENTIFIER' in s: assert s['PRODUCT_BUNDLE_IDENTIFIER'] in ('org.quietcast.family','org.quietcast.family.verification')
        if 'IPHONEOS_DEPLOYMENT_TARGET' in s: assert s['IPHONEOS_DEPLOYMENT_TARGET']==('17.0' if s.get('PRODUCT_BUNDLE_IDENTIFIER')=='org.quietcast.family.verification' else '16.0')
ET.parse(root/'QuietCast.xcodeproj/xcshareddata/xcschemes/QuietCast.xcscheme')
bundled=json.loads((root/'App/Resources/content-filter.json').read_text())
assert bundled['schemaVersion'] in ('1.0','1.1') and bundled['status'] in ('example','production')
if bundled['ruleVersion']=='example-2026-10-25':
    assert (root/'App/Resources/content-filter.json').read_bytes()==(root/'rules/example-fiction.json').read_bytes()
subprocess.run(['swiftc','-frontend','-parse',*[str(p) for p in (root/'App').rglob('*.swift')]],check=True)
print('PASS: project refs, plist background config, scheme, local package, stable bundle ID, resources and Swift syntax')
print('NOT VERIFIED: iOS SDK type checking, linking, simulator or device behavior')
