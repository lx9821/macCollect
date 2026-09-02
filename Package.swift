// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "macCollectBasic",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "macCollectBasicCore", targets: ["macCollectBasicCore"]),
        .executable(name: "macCollectBasicApp", targets: ["macCollectBasicApp"])
    ],
    targets: [
        .target(
            name: "macCollectBasicCore",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("DiskArbitration")
            ]
        ),
        .executableTarget(
            name: "macCollectBasicApp",
            dependencies: ["macCollectBasicCore"]
        )
    ]
)
