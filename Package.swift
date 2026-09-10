// swift-tools-version: 6.1
// FocusGuardCore holds the pure logic (reducer, policy, persistence, config) so it can be
// unit-tested with `swift test` without AppKit. The AppKit/SwiftUI layer lives in
// Sources/FocusGuardApp and is built only by FocusGuard.xcodeproj, which compiles both
// directories into the app. SwiftPM ignores undeclared directories under Sources/.

import PackageDescription

let package = Package(
    name: "FocusGuard",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "FocusGuardCore", targets: ["FocusGuardCore"])
    ],
    targets: [
        .target(name: "FocusGuardCore"),
        .testTarget(
            name: "FocusGuardCoreTests",
            dependencies: ["FocusGuardCore"]
        )
    ]
)
