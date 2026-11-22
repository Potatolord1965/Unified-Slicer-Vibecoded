// swift-tools-version:5.9
import PackageDescription

// The printer protocols of Unified Monitor for iPhone: accounts, one source per printer service,
// and the hub that refreshes them. Plain Foundation, Network and CryptoKit, so `swift test` runs
// the tests on a Mac without Xcode's simulator.
let package = Package(
    name: "UnifiedCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "UnifiedCore", targets: ["UnifiedCore"])],
    targets: [
        .target(name: "UnifiedCore"),
        .testTarget(name: "UnifiedCoreTests", dependencies: ["UnifiedCore"]),
    ]
)
