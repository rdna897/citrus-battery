// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CitrusBattery",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CitrusKit", targets: ["CitrusKit"]),
        .executable(name: "CitrusBattery", targets: ["CitrusBattery"]),
    ],
    targets: [
        .target(name: "CSMC", linkerSettings: [.linkedFramework("IOKit")]),
        .target(
            name: "CitrusKit",
            dependencies: ["CSMC"],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(name: "CitrusBattery", dependencies: ["CitrusKit"]),
        .testTarget(name: "CitrusKitTests", dependencies: ["CitrusKit"]),
    ]
)
