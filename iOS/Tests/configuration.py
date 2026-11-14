from pathlib import Path
import json
import plistlib
import subprocess
import uuid

root = Path(__file__).resolve().parents[1]
project = json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(root / "AuralIOS.xcodeproj/project.pbxproj")]))
objects = project["objects"]
targets = {obj["name"]: obj for obj in objects.values() if obj.get("isa") == "PBXNativeTarget"}
protocol = "media-device-protocol.local.aural.route-probe"
load = lambda name: plistlib.loads((root / "Configuration" / name).read_bytes())
assert load("Provider.entitlements") == load("Extension.entitlements") == {"com.apple.developer.media-device-extension": [protocol]}
assert "UIBackgroundModes" not in load("Provider.plist")
assert load("Receiver.plist")["UIBackgroundModes"] == ["audio"]
assert load("Extension.plist")["CFBundleDisplayName"] == "Aural"
assert uuid.UUID(load("Extension.plist")["AuralRouteDeviceIdentifier"]) == uuid.UUID("41555241-4C52-4F55-A000-000000000001")
probe_info = plistlib.loads((root.parent / "prototypes/ios-route/Configuration/Extension.plist").read_bytes())
assert load("Extension.plist")["AuralRouteDeviceIdentifier"] == probe_info["AuralRouteDeviceIdentifier"], "Branding must preserve the installed route identity"
exported = load("Extension.plist")["UTExportedTypeDeclarations"][0]
assert exported == probe_info["UTExportedTypeDeclarations"][0], "The existing protocol declaration is shared by both targets"
assert exported["UTTypeIdentifier"] == protocol
assert exported["UTTypeDescription"] == "Aural Route Probe", "Protocol metadata must remain stable when the output display name changes"
for name in ("Aural", "AuralRoute", "AuralRouteExtension", "AuralPreview"):
    target = targets[name]
    for config in objects[target["buildConfigurationList"]]["buildConfigurations"]:
        settings = objects[config]["buildSettings"]
        if name in ("Aural", "AuralPreview"):
            assert "CODE_SIGN_ENTITLEMENTS" not in settings
        else:
            assert settings["CODE_SIGN_ENTITLEMENTS"].endswith(".entitlements")
    phases = [objects[p] for p in target["buildPhases"]]
    sources = [objects[objects[f]["fileRef"]]["path"] for p in phases if p["isa"] == "PBXSourcesBuildPhase" for f in p["files"]]
    if name == "Aural":
        assert "ProbeAudio.swift" in sources and "PreviewAudio.swift" not in sources and "AudioStub.swift" not in sources
        assert "DSP.c" in sources and "Profile.swift" in sources
    if name == "AuralPreview":
        assert "PreviewAudio.swift" in sources and "ProbeAudio.swift" not in sources
    if name == "AuralRoute":
        assert any("EXTENSIONS_FOLDER_PATH" in p.get("dstPath", "") for p in phases)
print("PASS production/preview source separation, existing protocol, entitlements and ExtensionKit embedding")
