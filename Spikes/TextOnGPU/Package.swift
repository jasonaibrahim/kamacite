// swift-tools-version: 6.0
import PackageDescription

// P1 spike: text on the GPU. Deliberately self-contained — nothing here may be
// imported by VWEngine. The good parts graduate into VWText/VWRender in P2.
let package = Package(
    name: "TextOnGPU",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "TextOnGPU")
    ],
    swiftLanguageModes: [.v6]
)
