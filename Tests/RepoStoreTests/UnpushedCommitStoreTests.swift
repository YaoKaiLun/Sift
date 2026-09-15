import XCTest
import GitKit
import AIClient
@testable import RepoStore

@MainActor
final class UnpushedCommitStoreTests: XCTestCase {
    func testSelectCommitLoadsCommitFilesThenClearsBackToWorkingTree() async throws {
        let origin = try makeRepository()
        defer { try? FileManager.default.removeItem(at: origin) }
        try write("a\n", to: "a.txt", in: origin)
        try runGit(["add", "-A"], in: origin)
        try runGit(["commit", "-m", "initial"], in: origin)

        let cloneURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sift-unpushed-store-\(UUID().uuidString)")
        try runGit(["clone", origin.path, cloneURL.path], in: origin)
        defer { try? FileManager.default.removeItem(at: cloneURL) }
        try runGit(["config", "user.email", "t@sift.local"], in: cloneURL)
        try runGit(["config", "user.name", "T"], in: cloneURL)
        try runGit(["config", "commit.gpgsign", "false"], in: cloneURL)
        try write("new\n", to: "b.txt", in: cloneURL)
        try runGit(["add", "b.txt"], in: cloneURL)
        try runGit(["commit", "-m", "add b", "-m", "body line"], in: cloneURL)

        let store = makeStore()
        await store.addRepository(at: cloneURL)
        XCTAssertEqual(store.unpushedCommits.count, 1)
        await store.select(commit: store.unpushedCommits[0])
        XCTAssertEqual(store.fileStatuses.map(\.path), ["b.txt"])
        XCTAssertEqual(store.selectedCommit?.subject, "add b")
        await store.clearSelectedCommit()
        XCTAssertNil(store.selectedCommit)
        XCTAssertFalse(store.fileStatuses.contains { $0.path == "b.txt" })
    }

    func testUnpushedCommitsEmptyWithoutUpstream() async throws {
        let url = try makeRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("a\n", to: "a.txt", in: url)
        try runGit(["add", "-A"], in: url)
        try runGit(["commit", "-m", "initial"], in: url)

        let store = makeStore()
        await store.addRepository(at: url)
        XCTAssertTrue(store.unpushedCommits.isEmpty)
        XCTAssertFalse(store.hasUpstream)
    }

    private func makeRepository() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sift-commit-store-\(UUID().uuidString)")
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
