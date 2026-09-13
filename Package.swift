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
        .library(name: "Highlighter", targets: ["Highlighter"]),
        .library(name: "AIClient", targets: ["AIClient"]),
    ],
    targets: [
        .target(name: "GitKit"),
        .target(name: "DiffEngine", dependencies: ["GitKit"]),
        .target(name: "RepoStore", dependencies: ["GitKit", "DiffEngine", "AIClient"]),
        .target(name: "Highlighter"),
        .target(name: "AIClient"),
        .target(name: "SiftUI",
                dependencies: ["GitKit", "DiffEngine", "RepoStore", "Highlighter", "AIClient"],
                resources: [.process("Resources")]),
        .testTarget(name: "GitKitTests", dependencies: ["GitKit"]),
        .testTarget(name: "DiffEngineTests", dependencies: ["DiffEngine", "SiftUI"]),
        .testTarget(name: "RepoStoreTests", dependencies: ["RepoStore", "AIClient"]),
        .testTarget(name: "HighlighterTests", dependencies: ["Highlighter"]),
        .testTarget(name: "AIClientTests", dependencies: ["AIClient"]),
        .testTarget(name: "PerformanceTests", dependencies: ["GitKit", "DiffEngine", "RepoStore"]),
    ]
)
