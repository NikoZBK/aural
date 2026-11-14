from pathlib import Path
import plistlib
import subprocess
import json
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
config = root / "Configuration"
load = lambda name: plistlib.loads((config / name).read_bytes())
provider = load("Provider.entitlements")
extension = load("Extension.entitlements")
protocol = "media-device-protocol.local.aural.route-probe"
key = "com.apple.developer.media-device-extension"
assert provider == extension == {key: [protocol]}, "Both containers must declare the actual protocol"
info = load("Extension.plist")
assert info["EXAppExtensionAttributes"]["EXExtensionPointIdentifier"] == "com.apple.media-device-extension"
assert info["AuralRouteDeviceIdentifier"] == "41555241-4C52-4F55-A000-000000000001", "Retain the tested prototype identity"
assert info["UTExportedTypeDeclarations"][0]["UTTypeIdentifier"] == protocol
assert protocol in (root / "Extension/RouteExtension.swift").read_text()
assert info["AuralDiagnosticReceiverIPv4"] == "$(AURAL_DIAGNOSTIC_RECEIVER_IPV4)"
assert "AuralDiagnosticWithdrawHALOnStop" not in info, "HAL withdrawal no longer needs an experimental switch"
assert "UIBackgroundModes" not in load("Provider.plist"), "Provider is installation-only"
assert load("Receiver.plist")["UIBackgroundModes"] == ["audio"]
assert not (config / "Receiver.entitlements").exists(), "Receiver must not hold the media extension entitlement"

project = json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(root / "AuralRoutePrototype.xcodeproj/project.pbxproj")]))
objects = project["objects"]
project_configs = objects[objects[project["rootObject"]]["buildConfigurationList"]]["buildConfigurations"]
for identifier in project_configs:
    config = objects[identifier]
    settings = config["buildSettings"]
    assert settings["AURAL_DIAGNOSTIC_RECEIVER_IPV4"] == "", "Normal builds must retain loopback"
    assert "AURAL_DIAGNOSTIC_WITHDRAW_HAL_ON_STOP" not in settings, "HAL withdrawal applies in Debug and Release"
    definitions = settings["GCC_PREPROCESSOR_DEFINITIONS"]
    assert ("DEBUG=1" in definitions) == (config["name"] == "Debug")
targets = {obj["name"]: obj for obj in objects.values() if obj.get("isa") == "PBXNativeTarget"}
assert set(targets) == {"AuralRouteTest", "AuralRouteProvider", "AuralRouteExtension"}
assert targets["AuralRouteExtension"]["productType"] == "com.apple.product-type.extensionkit-extension"
provider_target = targets["AuralRouteProvider"]
copies = [objects[phase] for phase in provider_target["buildPhases"] if objects[phase]["isa"] == "PBXCopyFilesBuildPhase"]
assert any("EXTENSIONS_FOLDER_PATH" in phase.get("dstPath", "") for phase in copies), "ExtensionKit must embed in Extensions, not PlugIns"
for name, target in targets.items():
    configs = objects[target["buildConfigurationList"]]["buildConfigurations"]
    for identifier in configs:
        settings = objects[identifier]["buildSettings"]
        if name == "AuralRouteTest":
            assert "CODE_SIGN_ENTITLEMENTS" not in settings
        else:
            assert settings["CODE_SIGN_ENTITLEMENTS"] == "Configuration/" + ("Provider" if name == "AuralRouteProvider" else "Extension") + ".entitlements"
for scheme in (root / "AuralRoutePrototype.xcodeproj/xcshareddata/xcschemes").glob("*.xcscheme"):
    ET.parse(scheme)
print("PASS matching entitlements, provider/receiver separation, ExtensionKit embedding and shared schemes")
