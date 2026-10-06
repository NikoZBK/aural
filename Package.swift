// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Aural",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Aural", targets: ["Aural"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .target(name: "DSP", publicHeadersPath: "include", linkerSettings: [.linkedFramework("CoreAudio")]),
        .executableTarget(
            name: "Aural",
            dependencies: ["DSP", .product(name: "Sparkle", package: "Sparkle")],
            resources: [.copy("Resources/Targets")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        )
    ]
)
