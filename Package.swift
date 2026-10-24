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

/// The macOS SDK being built against: $SDKROOT, else the one xcrun reports.
let sdkPath: String? = {
    if let sdk = Context.environment["SDKROOT"], !sdk.isEmpty { return sdk }
    let xcrun = Process()
    xcrun.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    xcrun.arguments = ["--sdk", "macosx", "--show-sdk-path"]
    let output = Pipe()
    xcrun.standardOutput = output
    xcrun.standardError = FileHandle.nullDevice
    guard (try? xcrun.run()) != nil else { return nil }
    xcrun.waitUntilExit()
    let path = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return xcrun.terminationStatus == 0 && !path.isEmpty ? path : nil
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
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                // SwiftPM links with --sysroot, from which clang can't read the SDK's
                // version, so the binary would record the deployment target as its SDK
                // and macOS would give it the look of that release instead of the
                // current one (no Liquid Glass). -isysroot lets clang read it.
            ] + (sdkPath.map { ["-Xclang-linker", "-isysroot", "-Xclang-linker", $0] } ?? []))]
        ),
        .testTarget(name: "CitrusKitTests", dependencies: ["CitrusKit"]),
    ]
)
