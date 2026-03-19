// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ExifEdit",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "ExifEditCore", targets: ["ExifEditCore"]),
        .executable(name: "ExifEditMac", targets: ["ExifEditMac"])
    ],
    targets: [
        .target(name: "ExifEditCore"),
        .executableTarget(
            name: "ExifEditMac",
            dependencies: ["ExifEditCore"],
            path: "Sources/Ledger"
        ),
        .testTarget(
            name: "ExifEditCoreTests",
            dependencies: ["ExifEditCore"]
        ),
        .testTarget(
            name: "ExifEditMacTests",
            dependencies: ["ExifEditMac", "ExifEditCore"],
            path: "Tests/LedgerTests"
        )
    ]
)
