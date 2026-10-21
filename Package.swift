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
        .target(name: "CSMC", linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]),
        .target(name: "CPowerUI", linkerSettings: [.linkedFramework("Foundation")]),
        // libimobiledevice from Homebrew (Apple silicon and Intel prefixes).
        .target(
            name: "CIDevice",
            cSettings: [.unsafeFlags(["-I/opt/homebrew/include", "-I/usr/local/include"])],
            linkerSettings: [
                .unsafeFlags(["-L/opt/homebrew/lib", "-L/usr/local/lib"]),
                .linkedLibrary("imobiledevice-1.0"),
                .linkedLibrary("plist-2.0"),
            ]
        ),
        .target(
            name: "CitrusKit",
            dependencies: ["CSMC", "CPowerUI", "CIDevice"],
            linkerSettings: [.linkedFramework("IOKit"), .linkedLibrary("sqlite3")]
        ),
        .executableTarget(name: "CitrusBattery", dependencies: ["CitrusKit"]),
        .testTarget(name: "CitrusKitTests", dependencies: ["CitrusKit"]),
    ]
)
