// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Sift",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SiftLocalization", targets: ["SiftLocalization"]),
        .library(name: "GitKit", targets: ["GitKit"]),
        .library(name: "DiffEngine", targets: ["DiffEngine"]),
        .library(name: "RepoStore", targets: ["RepoStore"]),
        .library(name: "SiftUI", targets: ["SiftUI"]),
        .library(name: "Highlighter", targets: ["Highlighter"]),
        .library(name: "AIClient", targets: ["AIClient"]),
        .library(name: "UpdateKit", targets: ["UpdateKit"]),
    ],
    targets: [
        .target(name: "SiftLocalization"),
        .target(name: "GitKit", dependencies: ["SiftLocalization"]),
        .target(name: "DiffEngine", dependencies: ["GitKit", "SiftLocalization"]),
        .target(name: "RepoStore", dependencies: ["GitKit", "DiffEngine", "AIClient", "SiftLocalization"]),
        .target(name: "Highlighter"),
        .target(name: "AIClient"),
        .target(name: "UpdateKit"),
        .target(name: "SiftUI",
                dependencies: ["GitKit", "DiffEngine", "RepoStore", "Highlighter", "AIClient", "UpdateKit", "SiftLocalization"],
                resources: [.process("Resources")]),
        .testTarget(name: "GitKitTests", dependencies: ["GitKit"]),
        .testTarget(name: "DiffEngineTests", dependencies: ["DiffEngine", "SiftUI", "UpdateKit", "SiftLocalization"]),
        .testTarget(name: "RepoStoreTests", dependencies: ["RepoStore", "AIClient"]),
        .testTarget(name: "HighlighterTests", dependencies: ["Highlighter"]),
        .testTarget(name: "AIClientTests", dependencies: ["AIClient"]),
        .testTarget(name: "UpdateKitTests", dependencies: ["UpdateKit"]),
        .testTarget(name: "PerformanceTests",
                    dependencies: ["GitKit", "DiffEngine", "RepoStore", "SiftUI"]),
    ]
)
