// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Sift",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "GitKit", targets: ["GitKit"]),
        .library(name: "DiffEngine", targets: ["DiffEngine"]),
        .library(name: "RepoStore", targets: ["RepoStore"]),
        .library(name: "SiftUI", targets: ["SiftUI"]),
    ],
    targets: [
        .target(name: "GitKit"),
        .target(name: "DiffEngine", dependencies: ["GitKit"]),
        .target(name: "RepoStore", dependencies: ["GitKit", "DiffEngine"]),
        .target(name: "SiftUI",
                dependencies: ["GitKit", "DiffEngine", "RepoStore"],
                resources: [.process("Resources")]),
        .testTarget(name: "GitKitTests", dependencies: ["GitKit"]),
        .testTarget(name: "DiffEngineTests", dependencies: ["DiffEngine"]),
        .testTarget(name: "RepoStoreTests", dependencies: ["RepoStore"]),
        .testTarget(name: "PerformanceTests", dependencies: ["GitKit", "DiffEngine", "RepoStore"]),
    ]
)
