// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LedgerCore",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "LedgerCore", targets: ["LedgerCore"])
    ],
    targets: [
        .target(name: "LedgerCore"),
        .testTarget(
            name: "LedgerCoreTests",
            dependencies: ["LedgerCore"]
        )
    ]
)
