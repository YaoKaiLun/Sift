import XCTest
@testable import RepoStore

final class PersistedStateTests: XCTestCase {
    private func temporaryFile() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sift-state-\(UUID().uuidString)/state.json")
    }

    func testLoadReturnsEmptyStateWhenFileMissing() {
        let store = PersistedStateStore(fileURL: temporaryFile())
        let state = store.load()
        XCTAssertTrue(state.repositoryBookmarks.isEmpty)
        XCTAssertNil(state.selectedWorktreePath)
    }

    func testRoundTrip() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = PersistedStateStore(fileURL: url)
        let original = PersistedState(
            repositoryBookmarks: [Data([1, 2, 3])],
            selectedWorktreePath: "/repos/main",
            usesTreeView: true)
        try store.save(original)

        let loaded = PersistedStateStore(fileURL: url).load()
        XCTAssertEqual(loaded.repositoryBookmarks, [Data([1, 2, 3])])
        XCTAssertEqual(loaded.selectedWorktreePath, "/repos/main")
        XCTAssertTrue(loaded.usesTreeView)
    }

    func testSaveCreatesIntermediateDirectories() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = PersistedStateStore(fileURL: url)
        try store.save(PersistedState(repositoryBookmarks: [], selectedWorktreePath: nil, usesTreeView: false))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    /// 磁盘上的 JSON 损坏时必须优雅降级，不能让应用启动不了。
    func testCorruptFileFallsBackToEmptyState() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("this is not json".utf8).write(to: url)

        let state = PersistedStateStore(fileURL: url).load()
        XCTAssertTrue(state.repositoryBookmarks.isEmpty)
    }
}
