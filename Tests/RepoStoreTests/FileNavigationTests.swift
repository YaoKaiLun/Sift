import XCTest
import GitKit
import AIClient
@testable import RepoStore

@MainActor
final class FileNavigationTests: XCTestCase {
    func testSelectAdjacentFileWalksAndStopsAtEnds() async throws {
        let url = try makeRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("a", to: "a.txt", in: url)
        try write("b", to: "b.txt", in: url)
        try write("c", to: "c.txt", in: url)

        let store = makeStore()
        await store.addRepository(at: url)
        let files = store.fileStatuses.sorted(by: FileStatus.pathOrder)
        XCTAssertEqual(files.map(\.path), ["a.txt", "b.txt", "c.txt"])
        let ids = files.map { RepoStore.fileSelectionID(path: $0.path, staged: false) }

        await store.select(file: files[0], staged: false)
        await store.selectAdjacentFile(delta: 1, extending: false, orderedIDs: ids)
        XCTAssertEqual(store.selectedFile?.path, files[1].path)

        await store.selectAdjacentFile(delta: 1, extending: false, orderedIDs: ids)
        XCTAssertEqual(store.selectedFile?.path, files[2].path)

        await store.selectAdjacentFile(delta: 1, extending: false, orderedIDs: ids)
        XCTAssertEqual(store.selectedFile?.path, files[2].path)
    }

    func testParseCommitFileIDAllowsColonInPath() {
        let id = RepoStore.fileSelectionID(path: "foo:bar.txt", staged: false, commitSHA: "abc123")
        XCTAssertEqual(id, "c:abc123:foo:bar.txt")
        let parts = RepoStore.parseFileSelectionID(id)
        XCTAssertEqual(parts?.path, "foo:bar.txt")
        XCTAssertEqual(parts?.commitSHA, "abc123")
        XCTAssertEqual(parts?.staged, false)
    }

    private func makeRepository() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sift-nav-\(UUID().uuidString)")
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
        return RepoStore(
            stateStore: PersistedStateStore(fileURL: stateURL),
            keychain: MemoryKeychain())
    }
}
