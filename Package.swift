// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DDPAIDashcam",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "DDPAIDashcam",
            targets: ["DDPAIDashcam"]
        )
    ],
    dependencies: [
        // Persistence: SQLite via GRDB.
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        // Property-based testing.
        .package(url: "https://github.com/typelift/SwiftCheck.git", from: "0.12.0")
    ],
    targets: [
        // Main app/library target. The iOS app shell (@main App) is layered on
        // top of this module; keeping the feature code in a library target lets
        // the pure logic, subsystems, and view models build and test from the
        // command line and inside Xcode.
        .target(
            name: "DDPAIDashcam",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/DDPAIDashcam"
        ),
        // Example / unit tests.
        .testTarget(
            name: "Tests",
            dependencies: ["DDPAIDashcam"],
            path: "Tests/Tests"
        ),
        // Property-based tests (SwiftCheck).
        .testTarget(
            name: "PropertyTests",
            dependencies: [
                "DDPAIDashcam",
                .product(name: "SwiftCheck", package: "SwiftCheck")
            ],
            path: "Tests/PropertyTests"
        )
    ]
)
