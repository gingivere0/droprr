#!/usr/bin/env python3
"""Regenerates Droprr.xcodeproj/project.pbxproj.

The project uses folder-synced groups, so adding .swift files needs no regeneration.
Run this only when adding a target or changing build settings:

    python3 scripts/generate_project.py Droprr.xcodeproj/project.pbxproj

Object IDs are derived from names, so the output is stable between runs.
Personal values (team ID, bundle prefix) stay in Config/Local.xcconfig.
"""
import hashlib, sys

def I(name): return hashlib.md5(name.encode()).hexdigest()[:24].upper()

out_path = sys.argv[1] if len(sys.argv) > 1 else 'Droprr.xcodeproj/project.pbxproj'
P = I('project')
MAIN = I('maingroup'); PRODUCTS = I('products'); CONFIG_GRP = I('configgroup')
SYNC = {n: I('sync'+n) for n in ['Shared','Mac','iOS','ShareExtension','MacShareExtension']}
targets = {
 'DroprrMac':   dict(type='com.apple.product-type.application', prod='Droprr.app', ftype='wrapper.application', sync=['Shared','Mac']),
 'DroprriOS':   dict(type='com.apple.product-type.application', prod='Droprr.app', ftype='wrapper.application', sync=['Shared','iOS']),
 'DroprrShare': dict(type='com.apple.product-type.app-extension', prod='DroprrShare.appex', ftype='wrapper.app-extension', sync=['Shared','ShareExtension']),
 'DroprrMacShare': dict(type='com.apple.product-type.app-extension', prod='DroprrMacShare.appex', ftype='wrapper.app-extension', sync=['Shared','MacShareExtension']),
}
EMBEDS = {'DroprriOS': 'DroprrShare', 'DroprrMac': 'DroprrMacShare'}
for t,d in targets.items():
    d['id']=I('target'+t); d['prodref']=I('prod'+t)
    d['src']=I('src'+t); d['fw']=I('fw'+t); d['res']=I('res'+t)
    d['cfglist']=I('cfglist'+t); d['dbg']=I('dbg'+t); d['rel']=I('rel'+t)

WEBPHASE = I('webphaseDroprrMac')
WEBFILES = ['index.html', 'app.js', 'app.css', 'icon.png']
# Browser access over the internet: the host page the Mac runs hidden (host/ plus the shared site/rtc.js).
HOSTFILES = [('host', 'host.html'), ('host', 'host.js'), ('site', 'rtc.js')]
# Browsers as hosts (iPhone): the hidden guest page (apple/guest/) plus the shared site/rtc.js. Added to the project
# by hand as the DroprriOS phase "Copy browser guest".
PCFGLIST=I('pcfglist'); PDBG=I('pdbg'); PREL=I('prel'); BASECFG=I('basexcconfig')
cfgfiles = ['Base.xcconfig','Mac-Info.plist','iOS-Info.plist','Share-Info.plist','MacShare-Info.plist','Mac.entitlements','iOS.entitlements','Share.entitlements','MacShare.entitlements','Local.xcconfig.example']
CF = {f: I('cf'+f) for f in cfgfiles}
def ftype(f):
    return {'xcconfig':'text.xcconfig','plist':'text.plist.xml','entitlements':'text.plist.entitlements','example':'text'}[f.rsplit('.',1)[1]]

common = dict(
 CODE_SIGN_STYLE='Automatic', CURRENT_PROJECT_VERSION='3', MARKETING_VERSION='0.3.1',
 GENERATE_INFOPLIST_FILE='YES', SWIFT_VERSION='5.0', SWIFT_EMIT_LOC_STRINGS='YES',
 ENABLE_PREVIEWS='YES',
)
tset = {
 'DroprrMac': dict(SDKROOT='macosx', MACOSX_DEPLOYMENT_TARGET='14.0', PRODUCT_NAME='Droprr',
   PRODUCT_BUNDLE_IDENTIFIER='"$(DROPRR_BUNDLE_PREFIX).droprr.mac"', INFOPLIST_FILE='Config/Mac-Info.plist',
   INFOPLIST_KEY_CFBundleDisplayName='Droprr', INFOPLIST_KEY_LSApplicationCategoryType='"public.app-category.utilities"',
   COMBINE_HIDPI_IMAGES='YES', ENABLE_HARDENED_RUNTIME='YES', CODE_SIGN_ENTITLEMENTS='Config/Mac.entitlements',
   ASSETCATALOG_COMPILER_APPICON_NAME='AppIcon', LD_RUNPATH_SEARCH_PATHS='"@executable_path/../Frameworks"'),
 'DroprriOS': dict(SDKROOT='iphoneos', IPHONEOS_DEPLOYMENT_TARGET='17.0', PRODUCT_NAME='Droprr', TARGETED_DEVICE_FAMILY='"1,2"',
   PRODUCT_BUNDLE_IDENTIFIER='"$(DROPRR_BUNDLE_PREFIX).droprr"', INFOPLIST_FILE='Config/iOS-Info.plist',
   CODE_SIGN_ENTITLEMENTS='Config/iOS.entitlements', INFOPLIST_KEY_CFBundleDisplayName='Droprr',
   ASSETCATALOG_COMPILER_APPICON_NAME='AppIcon',
   ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES='"AppIcon-sunset AppIcon-cherry AppIcon-roseGold AppIcon-graphiteLime AppIcon-oliveMustard"',
   INFOPLIST_KEY_UILaunchScreen_Generation='YES', INFOPLIST_KEY_UIApplicationSceneManifest_Generation='YES',
   INFOPLIST_KEY_UISupportedInterfaceOrientations='"UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"',
   INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad='"UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"',
   LD_RUNPATH_SEARCH_PATHS='"@executable_path/Frameworks"'),
 'DroprrShare': dict(SDKROOT='iphoneos', IPHONEOS_DEPLOYMENT_TARGET='17.0', PRODUCT_NAME='DroprrShare', TARGETED_DEVICE_FAMILY='"1,2"',
   PRODUCT_BUNDLE_IDENTIFIER='"$(DROPRR_BUNDLE_PREFIX).droprr.share"', INFOPLIST_FILE='Config/Share-Info.plist',
   CODE_SIGN_ENTITLEMENTS='Config/Share.entitlements', INFOPLIST_KEY_CFBundleDisplayName='Droprr',
   SKIP_INSTALL='YES', APPLICATION_EXTENSION_API_ONLY='YES',
   LD_RUNPATH_SEARCH_PATHS='"@executable_path/Frameworks @executable_path/../../Frameworks"'),
 'DroprrMacShare': dict(SDKROOT='macosx', MACOSX_DEPLOYMENT_TARGET='14.0', PRODUCT_NAME='DroprrMacShare',
   PRODUCT_BUNDLE_IDENTIFIER='"$(DROPRR_BUNDLE_PREFIX).droprr.mac.share"', INFOPLIST_FILE='Config/MacShare-Info.plist',
   CODE_SIGN_ENTITLEMENTS='Config/MacShare.entitlements', INFOPLIST_KEY_CFBundleDisplayName='Droprr',
   ENABLE_HARDENED_RUNTIME='YES', SKIP_INSTALL='YES', APPLICATION_EXTENSION_API_ONLY='YES',
   LD_RUNPATH_SEARCH_PATHS='"@executable_path/../Frameworks @executable_path/../../../../Frameworks"'),
}
proj_common = dict(ALWAYS_SEARCH_USER_PATHS='NO', CLANG_ENABLE_MODULES='YES', ENABLE_USER_SCRIPT_SANDBOXING='YES',
  GCC_C_LANGUAGE_STANDARD='gnu17', ENABLE_STRICT_OBJC_MSGSEND='YES')
proj_dbg = dict(proj_common, DEBUG_INFORMATION_FORMAT='dwarf', ENABLE_TESTABILITY='YES', GCC_OPTIMIZATION_LEVEL='0',
  ONLY_ACTIVE_ARCH='YES', SWIFT_ACTIVE_COMPILATION_CONDITIONS='"DEBUG $(inherited)"', SWIFT_OPTIMIZATION_LEVEL='"-Onone"', MTL_ENABLE_DEBUG_INFO='INCLUDE_SOURCE')
proj_rel = dict(proj_common, DEBUG_INFORMATION_FORMAT='"dwarf-with-dsym"', ENABLE_NS_ASSERTIONS='NO', SWIFT_COMPILATION_MODE='wholemodule', VALIDATE_PRODUCT='YES')

def settings(d, ind):
    s = ''.join(f'{ind}{k} = {v};\n' for k,v in sorted(d.items()))
    return s

L=[]
a=L.append
a('// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {\n\t};\n\tobjectVersion = 77;\n\tobjects = {\n\n')
E = {host: dict(bf=I('embedbf'+host), phase=I('embedphase'+host), dep=I('dep'+host), proxy=I('proxy'+host), ext=ext) for host, ext in EMBEDS.items()}
a('/* Begin PBXBuildFile section */\n')
for host, e in E.items():
    ext = targets[e['ext']]
    a(f'\t\t{e["bf"]} /* {ext["prod"]} in Embed Foundation Extensions */ = {{isa = PBXBuildFile; fileRef = {ext["prodref"]} /* {ext["prod"]} */; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }};\n')
a('/* End PBXBuildFile section */\n\n')
a('/* Begin PBXContainerItemProxy section */\n')
for host, e in E.items():
    a(f'\t\t{e["proxy"]} /* PBXContainerItemProxy */ = {{\n\t\t\tisa = PBXContainerItemProxy;\n\t\t\tcontainerPortal = {P} /* Project object */;\n\t\t\tproxyType = 1;\n\t\t\tremoteGlobalIDString = {targets[e["ext"]]["id"]};\n\t\t\tremoteInfo = {e["ext"]};\n\t\t}};\n')
a('/* End PBXContainerItemProxy section */\n\n')
a('/* Begin PBXCopyFilesBuildPhase section */\n')
for host, e in E.items():
    ext = targets[e['ext']]
    a(f'\t\t{e["phase"]} /* Embed Foundation Extensions */ = {{\n\t\t\tisa = PBXCopyFilesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tdstPath = "";\n\t\t\tdstSubfolderSpec = 13;\n\t\t\tfiles = (\n\t\t\t\t{e["bf"]} /* {ext["prod"]} in Embed Foundation Extensions */,\n\t\t\t);\n\t\t\tname = "Embed Foundation Extensions";\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n')
a('/* End PBXCopyFilesBuildPhase section */\n\n')
a('/* Begin PBXFileReference section */\n')
for f,i in CF.items():
    a(f'\t\t{i} /* {f} */ = {{isa = PBXFileReference; lastKnownFileType = {ftype(f)}; path = {f}; sourceTree = "<group>"; }};\n')
for t,d in targets.items():
    a(f'\t\t{d["prodref"]} /* {d["prod"]} */ = {{isa = PBXFileReference; explicitFileType = {d["ftype"]}; includeInIndex = 0; path = {d["prod"]}; sourceTree = BUILT_PRODUCTS_DIR; }};\n')
a('/* End PBXFileReference section */\n\n')
a('/* Begin PBXFileSystemSynchronizedRootGroup section */\n')
for n,i in SYNC.items():
    a(f'\t\t{i} /* {n} */ = {{\n\t\t\tisa = PBXFileSystemSynchronizedRootGroup;\n\t\t\tpath = {n};\n\t\t\tsourceTree = "<group>";\n\t\t}};\n')
a('/* End PBXFileSystemSynchronizedRootGroup section */\n\n')
a('/* Begin PBXFrameworksBuildPhase section */\n')
for t,d in targets.items():
    a(f'\t\t{d["fw"]} /* Frameworks */ = {{\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n')
a('/* End PBXFrameworksBuildPhase section */\n\n')
a('/* Begin PBXGroup section */\n')
a(f'\t\t{MAIN} = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n' + ''.join(f'\t\t\t\t{i} /* {n} */,\n' for n,i in SYNC.items()) + f'\t\t\t\t{CONFIG_GRP} /* Config */,\n\t\t\t\t{PRODUCTS} /* Products */,\n\t\t\t);\n\t\t\tsourceTree = "<group>";\n\t\t}};\n')
a(f'\t\t{CONFIG_GRP} /* Config */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n' + ''.join(f'\t\t\t\t{i} /* {f} */,\n' for f,i in CF.items()) + '\t\t\t);\n\t\t\tpath = Config;\n\t\t\tsourceTree = "<group>";\n\t\t};\n')
a(f'\t\t{PRODUCTS} /* Products */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n' + ''.join(f'\t\t\t\t{d["prodref"]} /* {d["prod"]} */,\n' for d in targets.values()) + '\t\t\t);\n\t\t\tname = Products;\n\t\t\tsourceTree = "<group>";\n\t\t};\n')
a('/* End PBXGroup section */\n\n')
a('/* Begin PBXNativeTarget section */\n')
for t,d in targets.items():
    phases = [f'{d["src"]} /* Sources */', f'{d["fw"]} /* Frameworks */', f'{d["res"]} /* Resources */']
    if t == 'DroprrMac':
        phases.append(f'{WEBPHASE} /* Copy browser page */')
    deps = ''
    if t in E:
        phases.append(f'{E[t]["phase"]} /* Embed Foundation Extensions */')
        deps = f'\t\t\t\t{E[t]["dep"]} /* PBXTargetDependency */,\n'
    a(f'\t\t{d["id"]} /* {t} */ = {{\n\t\t\tisa = PBXNativeTarget;\n\t\t\tbuildConfigurationList = {d["cfglist"]} /* Build configuration list for PBXNativeTarget "{t}" */;\n\t\t\tbuildPhases = (\n' + ''.join(f'\t\t\t\t{p},\n' for p in phases) + '\t\t\t);\n\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n' + deps + '\t\t\t);\n\t\t\tfileSystemSynchronizedGroups = (\n' + ''.join(f'\t\t\t\t{SYNC[s]} /* {s} */,\n' for s in d['sync']) + f'\t\t\t);\n\t\t\tname = {t};\n\t\t\tpackageProductDependencies = (\n\t\t\t);\n\t\t\tproductName = {t};\n\t\t\tproductReference = {d["prodref"]} /* {d["prod"]} */;\n\t\t\tproductType = "{d["type"]}";\n\t\t}};\n')
a('/* End PBXNativeTarget section */\n\n')
a('/* Begin PBXProject section */\n')
a(f'\t\t{P} /* Project object */ = {{\n\t\t\tisa = PBXProject;\n\t\t\tattributes = {{\n\t\t\t\tBuildIndependentTargetsInParallel = 1;\n\t\t\t\tLastSwiftUpdateCheck = 2600;\n\t\t\t\tLastUpgradeCheck = 2600;\n\t\t\t\tTargetAttributes = {{\n' + ''.join(f'\t\t\t\t\t{d["id"]} = {{\n\t\t\t\t\t\tCreatedOnToolsVersion = 26.0;\n\t\t\t\t\t}};\n' for d in targets.values()) + f'\t\t\t\t}};\n\t\t\t}};\n\t\t\tbuildConfigurationList = {PCFGLIST} /* Build configuration list for PBXProject "Droprr" */;\n\t\t\tdevelopmentRegion = en;\n\t\t\thasScannedForEncodings = 0;\n\t\t\tknownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t);\n\t\t\tmainGroup = {MAIN};\n\t\t\tminimizedProjectReferenceProxies = 1;\n\t\t\tpreferredProjectObjectVersion = 77;\n\t\t\tproductRefGroup = {PRODUCTS} /* Products */;\n\t\t\tprojectDirPath = "";\n\t\t\tprojectRoot = "";\n\t\t\ttargets = (\n' + ''.join(f'\t\t\t\t{d["id"]} /* {t} */,\n' for t,d in targets.items()) + '\t\t\t);\n\t\t};\n')
a('/* End PBXProject section */\n\n')
a('/* Begin PBXResourcesBuildPhase section */\n')
for t,d in targets.items():
    a(f'\t\t{d["res"]} /* Resources */ = {{\n\t\t\tisa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n')
a('/* End PBXResourcesBuildPhase section */\n\n')
a('/* Begin PBXShellScriptBuildPhase section */\n')
web_in = ''.join(f'\t\t\t\t"$(SRCROOT)/../web/{f}",\n' for f in WEBFILES) + ''.join(f'\t\t\t\t"$(SRCROOT)/../{d}/{f}",\n' for d, f in HOSTFILES)
web_out = ''.join(f'\t\t\t\t"$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/web/{f}",\n' for f in WEBFILES) + ''.join(f'\t\t\t\t"$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/host/{f}",\n' for d, f in HOSTFILES)
a(f'\t\t{WEBPHASE} /* Copy browser page */ = {{\n\t\t\tisa = PBXShellScriptBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\tinputFileListPaths = (\n\t\t\t);\n\t\t\tinputPaths = (\n{web_in}\t\t\t);\n\t\t\tname = "Copy browser page";\n\t\t\toutputFileListPaths = (\n\t\t\t);\n\t\t\toutputPaths = (\n{web_out}\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t\tshellPath = /bin/sh;\n\t\t\tshellScript = "# The browser page is shared with Windows: web/ in the repository, copied as is.\\nmkdir -p \\"$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/web\\"\\ncp \\"$SRCROOT\\"/../web/* \\"$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/web/\\"\\nmkdir -p \\"$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/host\\"\\ncp \\"$SRCROOT\\"/../host/host.html \\"$SRCROOT\\"/../host/host.js \\"$SRCROOT\\"/../site/rtc.js \\"$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/host/\\"\\n";\n\t\t}};\n')
a('/* End PBXShellScriptBuildPhase section */\n\n')
a('/* Begin PBXSourcesBuildPhase section */\n')
for t,d in targets.items():
    a(f'\t\t{d["src"]} /* Sources */ = {{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n')
a('/* End PBXSourcesBuildPhase section */\n\n')
a('/* Begin PBXTargetDependency section */\n')
for host, e in E.items():
    a(f'\t\t{e["dep"]} /* PBXTargetDependency */ = {{\n\t\t\tisa = PBXTargetDependency;\n\t\t\ttarget = {targets[e["ext"]]["id"]} /* {e["ext"]} */;\n\t\t\ttargetProxy = {e["proxy"]} /* PBXContainerItemProxy */;\n\t\t}};\n')
a('/* End PBXTargetDependency section */\n\n')
a('/* Begin XCBuildConfiguration section */\n')
a(f'\t\t{PDBG} /* Debug */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbaseConfigurationReference = {CF["Base.xcconfig"]} /* Base.xcconfig */;\n\t\t\tbuildSettings = {{\n' + settings(proj_dbg,'\t\t\t\t') + '\t\t\t};\n\t\t\tname = Debug;\n\t\t};\n')
a(f'\t\t{PREL} /* Release */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbaseConfigurationReference = {CF["Base.xcconfig"]} /* Base.xcconfig */;\n\t\t\tbuildSettings = {{\n' + settings(proj_rel,'\t\t\t\t') + '\t\t\t};\n\t\t\tname = Release;\n\t\t};\n')
for t,d in targets.items():
    for cfg,key in (('Debug','dbg'),('Release','rel')):
        a(f'\t\t{d[key]} /* {cfg} */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n' + settings(dict(common, **tset[t]),'\t\t\t\t') + f'\t\t\t}};\n\t\t\tname = {cfg};\n\t\t}};\n')
a('/* End XCBuildConfiguration section */\n\n')
a('/* Begin XCConfigurationList section */\n')
a(f'\t\t{PCFGLIST} /* Build configuration list for PBXProject "Droprr" */ = {{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n\t\t\t\t{PDBG} /* Debug */,\n\t\t\t\t{PREL} /* Release */,\n\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t}};\n')
for t,d in targets.items():
    a(f'\t\t{d["cfglist"]} /* Build configuration list for PBXNativeTarget "{t}" */ = {{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n\t\t\t\t{d["dbg"]} /* Debug */,\n\t\t\t\t{d["rel"]} /* Release */,\n\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t}};\n')
a('/* End XCConfigurationList section */\n')
a(f'\t}};\n\trootObject = {P} /* Project object */;\n}}\n')
open(out_path,'w').write(''.join(L))
