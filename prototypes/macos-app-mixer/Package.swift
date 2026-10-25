// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AuralMixerProbe",
    platforms: [.macOS("14.2")],
    products: [.executable(name: "MixerProbe", targets: ["MixerProbe"])],
    targets: [
        .target(name: "ProbeCore", publicHeadersPath: "include", linkerSettings: [.linkedFramework("CoreAudio")]),
        .executableTarget(name: "MixerProbe", dependencies: ["ProbeCore"], linkerSettings: [.linkedFramework("AppKit")])
    ])
