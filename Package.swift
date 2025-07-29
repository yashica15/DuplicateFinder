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
    dependencies: [],
    targets: [
        .target(
            name: "DuplicateFinder",
            dependencies: [],
            path: "Sources/DuplicateFinder"
        ),
        .testTarget(
            name: "DuplicateFinderTests",
            dependencies: ["DuplicateFinder"],
            path: "Tests/DuplicateFinderTests"
        ),
    ]
)
