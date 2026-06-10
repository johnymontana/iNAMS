// swift-tools-version: 6.0
import PackageDescription

// iNAMSKit is the AppKit-free core (API client, models, Keychain, capture
// queue) so it builds and tests headlessly with `swift build` / `swift test`.
// The iNAMS executable target holds the menu bar app; `swift run iNAMS` works
// for development, while project.yml (XcodeGen) wraps the same sources into a
// signed .app bundle for distribution.
let package = Package(
    name: "iNAMS",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "iNAMSKit", targets: ["iNAMSKit"]),
        .executable(name: "iNAMS", targets: ["iNAMS"]),
    ],
    targets: [
        .target(name: "iNAMSKit"),
        .executableTarget(name: "iNAMS", dependencies: ["iNAMSKit"]),
        .testTarget(name: "iNAMSKitTests", dependencies: ["iNAMSKit"]),
    ]
)
