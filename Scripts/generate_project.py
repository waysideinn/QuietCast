#!/usr/bin/env python3
"""Dependency-free, deterministic Xcode project generation. Uses the local PodcastCore package."""
from pathlib import Path
import hashlib, json
root=Path(__file__).resolve().parents[1]
def ident(s): return hashlib.sha1(s.encode()).hexdigest()[:24].upper()
def quote(s): return json.dumps(str(s), ensure_ascii=False)
objects={}
def add(key,value): objects[ident(key)]=value; return ident(key)
def fmtids(ids): return '('+', '.join(ids)+', )' if ids else '()'
sources=[]; refs=[]; resources=[]
for p in sorted((root/'App').rglob('*.swift')):
    path=str(p.relative_to(root)); ref=add(path, '{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = '+quote(path)+'; sourceTree = SOURCE_ROOT; }');refs.append(ref)
    sources.append(add('build:'+path,'{isa = PBXBuildFile; fileRef = '+ref+'; }'))
for path,kind in [('App/Resources/content-filter.json','text.json'),('App/Resources/Assets.xcassets','folder.assetcatalog')]:
    ref=add(path, '{isa = PBXFileReference; lastKnownFileType = '+kind+'; path = '+quote(path)+'; sourceTree = SOURCE_ROOT; }');refs.append(ref)
    resources.append(add('build:'+path,'{isa = PBXBuildFile; fileRef = '+ref+'; }'))
refs.append(add('Info','{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = "App/Info.plist"; sourceTree = SOURCE_ROOT; }'))
testSources=[]
for p in sorted((root/'Tests/PodcastCoreTests').glob('*Tests.swift')) + sorted((root/'Tests/iOSVerification').glob('*.swift')):
    path=str(p.relative_to(root));ref=add(path,'{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = '+quote(path)+'; sourceTree = SOURCE_ROOT; }');refs.append(ref)
    testSources.append(add('test-build:'+path,'{isa = PBXBuildFile; fileRef = '+ref+'; }'))
fixture=add('fixtures','{isa = PBXFileReference; lastKnownFileType = folder; path = "Tests/PodcastCoreTests/Fixtures"; sourceTree = SOURCE_ROOT; }');refs.append(fixture)
fixtureBuild=add('fixture-build','{isa = PBXBuildFile; fileRef = '+fixture+'; }')
testProduct=add('test-product','{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = QuietCastVerification.xctest; sourceTree = BUILT_PRODUCTS_DIR; }')
product=add('product','{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = QuietCast.app; sourceTree = BUILT_PRODUCTS_DIR; }')
products=add('products','{isa = PBXGroup; name = Products; sourceTree = "<group>"; children = '+fmtids([product,testProduct])+'; }')
main=add('main','{isa = PBXGroup; sourceTree = "<group>"; children = '+fmtids(refs+[products])+'; }')
package=add('package','{isa = XCLocalSwiftPackageReference; relativePath = "."; }')
dependency=add('dependency','{isa = XCSwiftPackageProductDependency; package = '+package+'; productName = PodcastCore; }')
framework=add('framework','{isa = PBXBuildFile; productRef = '+dependency+'; }')
srcPhase=add('sources','{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = '+fmtids(sources)+'; runOnlyForDeploymentPostprocessing = 0; }')
resourcePhase=add('resources','{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = '+fmtids(resources)+'; runOnlyForDeploymentPostprocessing = 0; }')
frameworkPhase=add('frameworks','{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = '+fmtids([framework])+'; runOnlyForDeploymentPostprocessing = 0; }')
def configlist(key,settings):
    ids=[]
    for name in ['Debug','Release']:
        specific=dict(settings)
        if key=='project': specific.update({'ONLY_ACTIVE_ARCH':'YES' if name=='Debug' else 'NO','SWIFT_OPTIMIZATION_LEVEL':'-Onone' if name=='Debug' else '-O','DEBUG_INFORMATION_FORMAT':'dwarf' if name=='Debug' else 'dwarf-with-dsym','SWIFT_ACTIVE_COMPILATION_CONDITIONS':'DEBUG' if name=='Debug' else ''})
        body=' '.join(k+' = '+quote(v)+';' for k,v in specific.items())
        ids.append(add(key+name,'{isa = XCBuildConfiguration; name = '+name+'; buildSettings = {'+body+'}; }'))
    return add(key+'configs','{isa = XCConfigurationList; buildConfigurations = '+fmtids(ids)+'; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }')
projectConfigs=configlist('project',{'SDKROOT':'iphoneos','IPHONEOS_DEPLOYMENT_TARGET':'16.0','CLANG_ENABLE_MODULES':'YES','SWIFT_VERSION':'5.0','ENABLE_TESTABILITY':'YES','GCC_C_LANGUAGE_STANDARD':'gnu17','SWIFT_STRICT_CONCURRENCY':'targeted'})
targetConfigs=configlist('target',{'PRODUCT_BUNDLE_IDENTIFIER':'org.quietcast.family','PRODUCT_NAME':'$(TARGET_NAME)','INFOPLIST_FILE':'App/Info.plist','CODE_SIGN_STYLE':'Automatic','TARGETED_DEVICE_FAMILY':'1','ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon','SUPPORTED_PLATFORMS':'iphoneos iphonesimulator','SUPPORTS_MACCATALYST':'NO','GENERATE_INFOPLIST_FILE':'NO','LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks'})
target=add('target','{isa = PBXNativeTarget; buildConfigurationList = '+targetConfigs+'; buildPhases = '+fmtids([srcPhase,frameworkPhase,resourcePhase])+'; buildRules = (); dependencies = (); name = QuietCast; packageProductDependencies = '+fmtids([dependency])+'; productName = QuietCast; productReference = '+product+'; productType = "com.apple.product-type.application"; }')
testConfigs=configlist('test-target',{'IPHONEOS_DEPLOYMENT_TARGET':'17.0','PRODUCT_BUNDLE_IDENTIFIER':'org.quietcast.family.verification','PRODUCT_NAME':'$(TARGET_NAME)','GENERATE_INFOPLIST_FILE':'YES','TARGETED_DEVICE_FAMILY':'1','SUPPORTED_PLATFORMS':'iphoneos iphonesimulator','TEST_HOST':'$(BUILT_PRODUCTS_DIR)/QuietCast.app/QuietCast','BUNDLE_LOADER':'$(TEST_HOST)','FRAMEWORK_SEARCH_PATHS':'$(inherited) $(PLATFORM_DIR)/Developer/Library/Frameworks','LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks @loader_path/Frameworks','CODE_SIGN_STYLE':'Automatic'})
testSrc=add('test-sources','{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = '+fmtids(testSources)+'; runOnlyForDeploymentPostprocessing = 0; }')
testRes=add('test-resources','{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = '+fmtids([fixtureBuild])+'; runOnlyForDeploymentPostprocessing = 0; }')
testFramework=add('test-framework','{isa = PBXBuildFile; productRef = '+dependency+'; }')
testFrameworks=add('test-frameworks','{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = '+fmtids([testFramework])+'; runOnlyForDeploymentPostprocessing = 0; }')
proxy=add('test-host-proxy','{isa = PBXContainerItemProxy; containerPortal = '+ident('project')+'; proxyType = 1; remoteGlobalIDString = '+target+'; remoteInfo = QuietCast; }')
hostDependency=add('test-host-dependency','{isa = PBXTargetDependency; target = '+target+'; targetProxy = '+proxy+'; }')
testTarget=add('test-target','{isa = PBXNativeTarget; buildConfigurationList = '+testConfigs+'; buildPhases = '+fmtids([testSrc,testFrameworks,testRes])+'; buildRules = (); dependencies = '+fmtids([hostDependency])+'; name = QuietCastVerification; packageProductDependencies = '+fmtids([dependency])+'; productName = QuietCastVerification; productReference = '+testProduct+'; productType = "com.apple.product-type.bundle.unit-test"; }')
project=add('project','{isa = PBXProject; attributes = {BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 1600; TargetAttributes = {'+target+' = {CreatedOnToolsVersion = 16.0; }; }; }; buildConfigurationList = '+projectConfigs+'; compatibilityVersion = "Xcode 14.0"; developmentRegion = zh_CN; hasScannedForEncodings = 0; knownRegions = (en, zh_CN, Base); mainGroup = '+main+'; productRefGroup = '+products+'; packageReferences = '+fmtids([package])+'; projectDirPath = ""; projectRoot = ""; targets = '+fmtids([target,testTarget])+'; }')
folder=root/'QuietCast.xcodeproj'; folder.mkdir(exist_ok=True)
(folder/'project.pbxproj').write_text('// !$*UTF8*$!\n{archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(k+' = '+v+';' for k,v in objects.items())+'\n}; rootObject = '+project+'; }\n')
scheme=f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="QuietCast.app" BlueprintName="QuietCast" ReferencedContainer="container:QuietCast.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{testTarget}" BuildableName="QuietCastVerification.xctest" BlueprintName="QuietCastVerification" ReferencedContainer="container:QuietCast.xcodeproj"/></TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="QuietCast.app" BlueprintName="QuietCast" ReferencedContainer="container:QuietCast.xcodeproj"/></BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"/>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>'''
path=folder/'xcshareddata/xcschemes';path.mkdir(parents=True,exist_ok=True);(path/'QuietCast.xcscheme').write_text(scheme+'\n')
print('Generated', folder)
