import XCTest
import GitKit
@testable import RepoStore

@MainActor
final class RepoStoreTests: XCTestCase {
    private func makeRepository() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sift-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], in: url)
        try runGit(["config", "user.email", "t@sift.local"], in: url)
        try runGit(["config", "user.name", "T"], in: url)
        try runGit(["config", "commit.gpgsign", "false"], in: url)
        return url
    }

    private func runGit(_ args: [String], in url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = url
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(args.joined(separator: " ")) failed")
    }

    private func write(_ contents: String, to path: String, in url: URL) throws {
        try contents.write(to: url.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }

    private func makeStore() -> RepoStore {
        let stateURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sift-state-\(UUID().uuidString)/state.json")
        return RepoStore(stateStore: PersistedStateStore(fileURL: stateURL))
    }

    func testRefreshReloadsSelectedDiff() async throws {
        let url = try makeRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("line1\nline2\n", to: "a.txt", in: url)
        try runGit(["add", "-A"], in: url)
        try runGit(["commit", "-m", "initial"], in: url)
        try write("line1\nCHANGED\n", to: "a.txt", in: url)

        let store = makeStore()
        await store.addRepository(at: url)
        let file = try XCTUnwrap(store.fileStatuses.first)
        await store.select(file: file, staged: false)

        guard case .ready(let first) = store.loadedDiff else {
            return XCTFail("首次加载应得到 ready，实际是 \(String(describing: store.loadedDiff))")
        }
        XCTAssertTrue(first.hunks.flatMap(\.lines).contains(where: { $0.text.contains("CHANGED") }))

        try write("line1\nCHANGED AGAIN\n", to: "a.txt", in: url)
        await store.refreshFileList()

        XCTAssertEqual(store.selectedFile?.path, "a.txt")
        XCTAssertFalse(store.selectedFileIsStaged)
        guard case .ready(let second) = store.loadedDiff else {
            return XCTFail("刷新后应重载 diff，实际是 \(String(describing: store.loadedDiff))")
        }
        XCTAssertTrue(second.hunks.flatMap(\.lines).contains(where: { $0.text.contains("CHANGED AGAIN") }),
                      "FSEvents/刷新必须重载当前打开的 diff")
    }

    func testRefreshClearsSelectionWhenSelectedSideVanishes() async throws {
        let url = try makeRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("line1\n", to: "a.txt", in: url)
        try runGit(["add", "-A"], in: url)
        try runGit(["commit", "-m", "initial"], in: url)
        try write("line1\nCHANGED\n", to: "a.txt", in: url)

        let store = makeStore()
        await store.addRepository(at: url)
        let file = try XCTUnwrap(store.fileStatuses.first)
        await store.select(file: file, staged: false)

        try write("line1\n", to: "a.txt", in: url)
        await store.refreshFileList()

        XCTAssertNil(store.selectedFile)
        XCTAssertNil(store.loadedDiff)
    }
}
