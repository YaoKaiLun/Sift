import XCTest
import GitKit
import AIClient
@testable import RepoStore

@MainActor
final class FileFilterStoreTests: XCTestCase {
    func testVisibleFileStatusesHidesMatchingPaths() async throws {
        let url = try makeRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("shot", to: "shot.png", in: url)
        try write("text", to: "a.txt", in: url)

        let store = makeStore()
        await store.addRepository(at: url)

        store.fileFilterPatterns = ["*.png"]
        store.hidesFilteredFiles = true
        XCTAssertFalse(store.visibleFileStatuses.contains { $0.path.hasSuffix(".png") })
        XCTAssertTrue(store.visibleFileStatuses.contains { $0.path == "a.txt" })
        XCTAssertTrue(store.fileStatuses.contains { $0.path == "shot.png" })
    }

    func testDisabledFilterLeavesAllFilesVisible() async throws {
        let url = try makeRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("shot", to: "shot.png", in: url)
        try write("text", to: "a.txt", in: url)

        let store = makeStore()
        await store.addRepository(at: url)
        store.fileFilterPatterns = ["*.png"]
        store.hidesFilteredFiles = false
        XCTAssertEqual(Set(store.visibleFileStatuses.map(\.path)), ["shot.png", "a.txt"])
    }

    private func makeRepository() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sift-filter-\(UUID().uuidString)")
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
