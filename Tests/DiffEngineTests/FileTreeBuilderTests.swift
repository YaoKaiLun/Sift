import XCTest
import GitKit
@testable import DiffEngine

final class FileTreeBuilderTests: XCTestCase {
    private func status(_ path: String) -> FileStatus {
        FileStatus(path: path, originalPath: nil,
                   indexStatus: .unmodified, worktreeStatus: .modified)
    }

    private func names(_ nodes: [FileTreeNode]) -> [String] {
        nodes.map { node in
            switch node {
            case .directory(let name, _, _): name
            case .file(let status): status.fileName
            }
        }
    }

    func testFlatFilesProduceFlatTree() {
        let tree = FileTreeBuilder.build(
            from: [status("a.txt"), status("b.txt")],
            collapsingSingleChildDirectories: false)
        XCTAssertEqual(names(tree), ["a.txt", "b.txt"])
    }

    func testNestedPathsProduceDirectories() {
        let tree = FileTreeBuilder.build(
            from: [status("src/main.swift"), status("src/util.swift"), status("README.md")],
            collapsingSingleChildDirectories: false)
        // 目录排在文件前面，各自按名称排序。
        XCTAssertEqual(names(tree), ["src", "README.md"])
        guard case .directory(_, _, let children) = tree[0] else {
            return XCTFail("第一个节点应是目录")
        }
        XCTAssertEqual(names(children), ["main.swift", "util.swift"])
    }

    func testDirectoryPathIsFullPath() {
        let tree = FileTreeBuilder.build(
            from: [status("apps/web/src/App.tsx")],
            collapsingSingleChildDirectories: false)
        guard case .directory(let name, let path, _) = tree[0] else {
            return XCTFail("应是目录")
        }
        XCTAssertEqual(name, "apps")
        XCTAssertEqual(path, "apps")
    }

    func testCollapsesSingleChildDirectoryChains() {
        let tree = FileTreeBuilder.build(
            from: [status("apps/web/src/App.tsx")],
            collapsingSingleChildDirectories: true)
        XCTAssertEqual(names(tree), ["apps/web/src"],
                       "只有一个子节点的目录链应压成一行，避免无意义的层层缩进")
        guard case .directory(_, let path, let children) = tree[0] else {
            return XCTFail("应是目录")
        }
        XCTAssertEqual(path, "apps/web/src")
        XCTAssertEqual(names(children), ["App.tsx"])
    }

    func testDoesNotCollapseWhenDirectoryHasMultipleChildren() {
        let tree = FileTreeBuilder.build(
            from: [status("src/a.swift"), status("src/nested/b.swift")],
            collapsingSingleChildDirectories: true)
        XCTAssertEqual(names(tree), ["src"])
        guard case .directory(_, _, let children) = tree[0] else {
            return XCTFail("应是目录")
        }
        XCTAssertEqual(names(children), ["nested", "a.swift"])
    }

    func testSortsDirectoriesBeforeFilesAlphabetically() {
        let tree = FileTreeBuilder.build(
            from: [status("z.txt"), status("a.txt"), status("beta/x.txt"), status("alpha/y.txt")],
            collapsingSingleChildDirectories: false)
        XCTAssertEqual(names(tree), ["alpha", "beta", "a.txt", "z.txt"])
    }

    func testEmptyInputProducesEmptyTree() {
        XCTAssertTrue(FileTreeBuilder.build(from: [], collapsingSingleChildDirectories: true).isEmpty)
    }
}
