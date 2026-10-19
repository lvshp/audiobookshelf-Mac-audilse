#!/usr/bin/env python3
"""Generate the native app project without a globally installed project generator."""
from pathlib import Path
import hashlib
import json

root = Path(__file__).resolve().parent.parent
project = root / "Audilse.xcodeproj"
project.mkdir(exist_ok=True)
objects = {}

def identity(name):
    return hashlib.sha1(name.encode()).hexdigest()[:24].upper()

def quote(value):
    return json.dumps(str(value), ensure_ascii=False)

def add(object_name, isa, **fields):
    key = identity(object_name)
    objects[key] = "isa = " + isa + "; " + " ".join(f"{k} = {v};" for k, v in fields.items())
    return key

def array(values):
    return "(" + ", ".join(values) + ",)" if values else "()"

sources, source_refs = [], []
for path in sorted((root / "Sources/Audilse").rglob("*.swift")):
    relative = str(path.relative_to(root))
    ref = add(relative, "PBXFileReference", lastKnownFileType="sourcecode.swift", path=quote(relative), sourceTree="SOURCE_ROOT")
    source_refs.append(ref)
    sources.append(add("build:" + relative, "PBXBuildFile", fileRef=ref))

language_refs = []
for language in ("en", "zh-Hans"):
    path = f"Sources/Audilse/Resources/{language}.lproj/Localizable.strings"
    language_refs.append(add(path, "PBXFileReference", lastKnownFileType="text.plist.strings", name=quote(language), path=quote(path), sourceTree="SOURCE_ROOT"))
localized = add("localized", "PBXVariantGroup", children=array(language_refs), name="Localizable.strings", sourceTree=quote("<group>"))
resources = [add("localized:build", "PBXBuildFile", fileRef=localized)]
resource_refs = [localized]
for path in sorted((root / "Sources/Audilse/Resources").iterdir()):
    if path.suffix == ".lproj":
        continue
    relative = str(path.relative_to(root))
    ref = add(relative, "PBXFileReference", lastKnownFileType="folder" if path.is_dir() else "file", path=quote(relative), sourceTree="SOURCE_ROOT")
    resource_refs.append(ref)
    resources.append(add("build:" + relative, "PBXBuildFile", fileRef=ref))
for relative in ("Packaging/Licenses", "LICENSE", "Packaging/THIRD_PARTY_NOTICES.md", "Packaging/VLC_DISTRIBUTION.md"):
    path = root / relative
    if path.exists():
        ref = add(relative, "PBXFileReference", lastKnownFileType="folder" if path.is_dir() else "file", path=quote(relative), sourceTree="SOURCE_ROOT")
        resource_refs.append(ref)
        resources.append(add("build:" + relative, "PBXBuildFile", fileRef=ref))
if (root / "Packaging/AppIcon.icns").exists():
    icon = add("icon", "PBXFileReference", lastKnownFileType="image.icns", path=quote("Packaging/AppIcon.icns"), sourceTree="SOURCE_ROOT")
    resource_refs.append(icon)
    resources.append(add("icon:build", "PBXBuildFile", fileRef=icon))

local_package = add("package", "XCLocalSwiftPackageReference", relativePath=quote("."))
product_deps, frameworks = [], []
for product in ("AudilseCore", "AudilsePlayback"):
    dep = add("product:" + product, "XCSwiftPackageProductDependency", package=local_package, productName=product)
    product_deps.append(dep)
    frameworks.append(add("link:" + product, "PBXBuildFile", productRef=dep))

source_phase = add("sources", "PBXSourcesBuildPhase", buildActionMask="2147483647", files=array(sources), runOnlyForDeploymentPostprocessing="0")
verify_phase = add("verify-patched-vlc", "PBXShellScriptBuildPhase", buildActionMask="2147483647", files="()", inputPaths="()", outputPaths="()", runOnlyForDeploymentPostprocessing="0", alwaysOutOfDate="1", name=quote("Verify bundled audio decoder"), shellPath=quote("/bin/bash"), shellScript=quote('set -euo pipefail\nbash "$SRCROOT/scripts/prepare-vlc.sh"\n'))
resource_phase = add("resources", "PBXResourcesBuildPhase", buildActionMask="2147483647", files=array(resources), runOnlyForDeploymentPostprocessing="0")
framework_phase = add("frameworks", "PBXFrameworksBuildPhase", buildActionMask="2147483647", files=array(frameworks), runOnlyForDeploymentPostprocessing="0")
app_product = add("app", "PBXFileReference", explicitFileType="wrapper.application", includeInIndex="0", path="Audilse.app", sourceTree="BUILT_PRODUCTS_DIR")
source_group = add("source-group", "PBXGroup", children=array(source_refs), name="Sources", sourceTree=quote("<group>"))
resource_group = add("resource-group", "PBXGroup", children=array(resource_refs), name="Resources", sourceTree=quote("<group>"))
product_group = add("products", "PBXGroup", children=array([app_product]), name="Products", sourceTree=quote("<group>"))
main_group = add("main-group", "PBXGroup", children=array([source_group, resource_group, product_group]), sourceTree=quote("<group>"))

def config(name, app):
    settings = {"SDKROOT": "macosx", "MACOSX_DEPLOYMENT_TARGET": "14.0", "SWIFT_VERSION": "6.0", "CLANG_ENABLE_MODULES": "YES"}
    if app:
        settings.update({"PRODUCT_BUNDLE_IDENTIFIER": "app.audilse.client", "PRODUCT_NAME": "$(TARGET_NAME)", "INFOPLIST_FILE": "Packaging/Info.plist", "GENERATE_INFOPLIST_FILE": "NO", "CODE_SIGN_STYLE": "Manual", "CODE_SIGN_IDENTITY": "-", "CODE_SIGN_ENTITLEMENTS": "Packaging/Audilse.entitlements", "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/../Frameworks", "ENABLE_HARDENED_RUNTIME": "YES", "SWIFT_EMIT_LOC_STRINGS": "YES"})
    settings.update({"SWIFT_OPTIMIZATION_LEVEL": "-Onone" if name == "Debug" else "-O", "ONLY_ACTIVE_ARCH": "YES" if name == "Debug" else "NO"})
    return add(("app-" if app else "project-") + name, "XCBuildConfiguration", buildSettings="{ " + " ".join(f"{k} = {quote(v)};" for k, v in settings.items()) + " }", name=name)

app_configs = add("app-configs", "XCConfigurationList", buildConfigurations=array([config(n, True) for n in ("Debug", "Release")]), defaultConfigurationIsVisible="0", defaultConfigurationName="Release")
project_configs = add("project-configs", "XCConfigurationList", buildConfigurations=array([config(n, False) for n in ("Debug", "Release")]), defaultConfigurationIsVisible="0", defaultConfigurationName="Release")
target = add("target", "PBXNativeTarget", buildConfigurationList=app_configs, buildPhases=array([verify_phase, source_phase, framework_phase, resource_phase]), buildRules="()", dependencies="()", name="Audilse", packageProductDependencies=array(product_deps), productName="Audilse", productReference=app_product, productType=quote("com.apple.product-type.application"))
project_ref = add("project", "PBXProject", attributes="{ LastUpgradeCheck = 1600; }", buildConfigurationList=project_configs, compatibilityVersion=quote("Xcode 15.0"), developmentRegion="en", hasScannedForEncodings="0", knownRegions=array(["en", quote("zh-Hans"), "Base"]), mainGroup=main_group, packageReferences=array([local_package]), productRefGroup=product_group, projectDirPath=quote(""), projectRoot=quote(""), targets=array([target]))
text = "// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 60; objects = {\n"
text += "\n".join(f"{key} = {{ {value} }};" for key, value in sorted(objects.items()))
text += f"\n}}; rootObject = {project_ref}; }}\n"
(project / "project.pbxproj").write_text(text)
scheme_dir = project / "xcshareddata/xcschemes"
scheme_dir.mkdir(parents=True, exist_ok=True)
legacy_scheme = scheme_dir / "Audilse.xcscheme"
if legacy_scheme.exists():
    legacy_scheme.unlink()
(scheme_dir / "AudilseApp.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="Audilse.app" BlueprintName="Audilse" ReferencedContainer="container:Audilse.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="Audilse.app" BlueprintName="Audilse" ReferencedContainer="container:Audilse.xcodeproj"/></BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"/>
 <AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print(project)
