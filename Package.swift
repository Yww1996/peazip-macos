// swift-tools-version: 5.9
import PackageDescription

// tools-version 5.9 already uses the Swift 5 language mode by default, so no
// swiftSettings entry is needed (swiftLanguageMode requires PackageDescription 6.0).
let package = Package(
    name: "PeaZip27",
    // macOS 15 is required for `Scene.defaultLaunchBehavior`, which is what guarantees a
    // launch window instead of leaving it to AppKit's saved-state path.
    // Written as a version string because PackageDescription 5.9 has no `.v15` case, and
    // raising swift-tools-version to 6.0 would switch the language mode to Swift 6.
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(
            name: "PeaZip27",
            path: "Sources/PeaZip27"
        )
    ]
)
