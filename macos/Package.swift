// swift-tools-version:6.0
// Brêge for macOS. Build the core first: scripts/build-core-apple.sh
import Foundation
import PackageDescription

let generated = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Generated").path

let package = Package(
    name: "Brege",
    platforms: [.macOS(.v13)],
    targets: [
        .systemLibrary(name: "brege_ffiFFI", path: "Generated/brege_ffiFFI"),
        .target(
            name: "BregeCore",
            dependencies: ["brege_ffiFFI"],
            path: "Generated/Swift",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .unsafeFlags(["-L", generated]),
                .linkedLibrary("brege_ffi"),
                .linkedFramework("Security"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("SystemConfiguration"),
            ]
        ),
        .executableTarget(
            name: "Brege",
            dependencies: ["BregeCore"],
            path: "Sources/Brege",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Helper in ~/Library/Services that answers the per-phone Services entries.
        .executableTarget(
            name: "BregeServices",
            path: "Sources/BregeServices",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
