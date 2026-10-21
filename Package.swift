// swift-tools-version: 6.0
import Foundation
import PackageDescription

/// libimobiledevice built for macOS 13 by scripts/build-dependencies.sh, when
/// present; otherwise Homebrew's copy (Apple silicon and Intel prefixes), whose
/// minimum macOS is that of the machine it was built for.
let dependencyPrefixes: [String] = {
    let prefix = Context.environment["CITRUS_DEPS_PREFIX"] ?? "\(Context.packageDirectory)/.build/deps"
    if FileManager.default.fileExists(atPath: "\(prefix)/lib/libimobiledevice-1.0.dylib") {
        return [prefix]
    }
    return ["/opt/homebrew", "/usr/local"]
}()

let package = Package(
    name: "CitrusBattery",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CitrusKit", targets: ["CitrusKit"]),
        .executable(name: "CitrusBattery", targets: ["CitrusBattery"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .target(name: "CSMC", linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]),
        .target(name: "CPowerUI", linkerSettings: [.linkedFramework("Foundation")]),
        .target(
            name: "CIDevice",
            cSettings: [.unsafeFlags(dependencyPrefixes.map { "-I\($0)/include" })],
            linkerSettings: [
                .unsafeFlags(dependencyPrefixes.map { "-L\($0)/lib" }),
                .linkedLibrary("imobiledevice-1.0"),
                .linkedLibrary("plist-2.0"),
            ]
        ),
        .target(
            name: "CitrusKit",
            dependencies: ["CSMC", "CPowerUI", "CIDevice"],
            linkerSettings: [.linkedFramework("IOKit"), .linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "CitrusBattery",
            dependencies: ["CitrusKit", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "CitrusKitTests", dependencies: ["CitrusKit"]),
    ]
)
