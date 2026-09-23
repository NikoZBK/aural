// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "Aural", platforms: [.macOS(.v14)], products: [.executable(name: "Aural", targets: ["Aural"])], targets: [
    .target(name: "DSP", publicHeadersPath: "include", linkerSettings: [.linkedFramework("CoreAudio")]),
    .executableTarget(name: "Aural", dependencies: ["DSP"])
])
