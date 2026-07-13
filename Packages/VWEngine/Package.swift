// swift-tools-version: 6.0
import PackageDescription

// The vw engine: parse → style → layout → GPU render → interaction.
// Strict dependency DAG; everything below VWViewer is AppKit-free (Foundation,
// CoreText, Metal only) so parse/style/layout unit-test headlessly.
let package = Package(
    name: "VWEngine",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "VWViewer", targets: ["VWViewer"])
    ],
    dependencies: [
        // The only remote dependency in the repo (cmark-gfm under the hood).
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.4.0")
    ],
    targets: [
        .target(name: "VWCore"),
        .target(
            name: "VWParse",
            dependencies: ["VWCore", .product(name: "Markdown", package: "swift-markdown")]
        ),
        .target(name: "VWStyle", dependencies: ["VWCore", "VWParse"]),
        .target(name: "VWText", dependencies: ["VWCore", "VWParse", "VWStyle"]),
        .target(name: "VWLayout", dependencies: ["VWText"]),
        .target(name: "VWRender", dependencies: ["VWText", "VWLayout"]),
        .target(name: "VWInteraction", dependencies: ["VWCore", "VWStyle", "VWText", "VWLayout"]),
        .target(
            name: "VWViewer",
            dependencies: ["VWParse", "VWStyle", "VWText", "VWLayout", "VWRender", "VWInteraction"]
        ),
        .testTarget(
            name: "VWEngineTests",
            dependencies: ["VWCore", "VWParse", "VWStyle", "VWText", "VWLayout", "VWRender", "VWInteraction"],
            resources: [.copy("Goldens")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
