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
    dependencies: [
        .package(url: "https://github.com/chrislemarquand/SharedUI.git", exact: "1.0.0")
    ],
    targets: [
        .target(name: "ExifEditCore"),
        .executableTarget(
            name: "ExifEditMac",
            dependencies: [
                "ExifEditCore",
                .product(name: "SharedUI", package: "SharedUI")
            ],
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
