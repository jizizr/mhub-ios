// swift-tools-version: 6.2
// Platform-independent MHub client logic: models, API, queue and lyrics.
// It has no UI or AVFoundation dependency, so `swift test` runs on macOS.
import PackageDescription

let package = Package(
    name: "MHubKit",
    platforms: [.iOS(.v16), .macOS(.v13), .macCatalyst(.v16)],
    products: [.library(name: "MHubKit", targets: ["MHubKit"])],
    targets: [
        .target(name: "MHubKit"),
        .testTarget(name: "MHubKitTests", dependencies: ["MHubKit"]),
    ]
)
