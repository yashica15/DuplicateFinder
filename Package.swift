// swift-tools-version:5.8
import PackageDescription

let package = Package(
    name: "DuplicateFinder",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "DuplicateFinder",
            targets: ["DuplicateFinder"]
        ),
    ],
    dependencies: [
        // Add external dependencies here if needed in the future
    ],
    targets: [
        .target(
            name: "DuplicateFinder",
            dependencies: [],
            path: "Sources/DuplicateFinder",
            resources: []
        ),
        .testTarget(
            name: "DuplicateFinderTests",
            dependencies: ["DuplicateFinder"],
            path: "Tests/DuplicateFinderTests"
        ),
    ]
)
