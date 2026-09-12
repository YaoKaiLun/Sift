import XCTest
import GitKit
@testable import DiffEngine

final class DiffEngineTests: XCTestCase {
    /// 在临时目录里建一个真仓库。DiffEngineTests 无法访问 GitKitTests 里的
    /// FixtureRepo，所以这里放一个最小版本。
    private func makeRepository() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sift-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], in: url)
        try runGit(["config", "user.email", "t@sift.local"], in: url)
        try runGit(["config", "user.name", "T"], in: url)
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
    }

    private func write(_ contents: String, to path: String, in url: URL) throws {
        let target = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: target, atomically: true, encoding: .utf8)
    }

    func testLoadsTextualDiff() async throws {
        let url = try makeRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("line1\nline2\n", to: "a.txt", in: url)
        try runGit(["add", "-A"], in: url)
        try runGit(["commit", "-m", "initial"], in: url)
        try write("line1\nCHANGED\n", to: "a.txt", in: url)

        let repository = GitRepository(root: url)
        let engine = DiffEngine()
        let status = try await repository.status()
        let loaded = try await engine.load(status: status[0], staged: false, from: repository)

        guard case .ready(let diff) = loaded else {
            return XCTFail("期望 ready，实际是 \(loaded)")
        }
        XCTAssertEqual(diff.addedLineCount, 1)
    }

    func testCollapsesGeneratedFile() async throws {
        let url = try makeRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("{}\n", to: "package-lock.json", in: url)
        try runGit(["add", "-A"], in: url)
        try runGit(["commit", "-m", "initial"], in: url)
        try write("{\"changed\": true}\n", to: "package-lock.json", in: url)

        let repository = GitRepository(root: url)
        let engine = DiffEngine()
        let status = try await repository.status()
        let loaded = try await engine.load(status: status[0], staged: false, from: repository)

        guard case .collapsed(let reason, let path) = loaded else {
            return XCTFail("期望 collapsed，实际是 \(loaded)")
        }
        XCTAssertEqual(path, "package-lock.json")
        XCTAssertEqual(reason, .pathRule("*-lock.json"))
    }

    func testLoadIgnoringCollapseForcesLoad() async throws {
        let url = try makeRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("{}\n", to: "package-lock.json", in: url)
        try runGit(["add", "-A"], in: url)
        try runGit(["commit", "-m", "initial"], in: url)
        try write("{\"changed\": true}\n", to: "package-lock.json", in: url)

        let repository = GitRepository(root: url)
        let engine = DiffEngine()
        let status = try await repository.status()
        let loaded = try await engine.loadIgnoringCollapse(
            status: status[0], staged: false, from: repository)

        guard case .ready = loaded else {
            return XCTFail("强制加载时应返回 ready，实际是 \(loaded)")
        }
    }

    func testUntrackedFileRendersAsAllAdded() async throws {
        let url = try makeRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("seed\n", to: "seed.txt", in: url)
        try runGit(["add", "-A"], in: url)
        try runGit(["commit", "-m", "initial"], in: url)
        try write("new line 1\nnew line 2\nnew line 3\n", to: "fresh.txt", in: url)

        let repository = GitRepository(root: url)
        let engine = DiffEngine()
        let status = try await repository.status()
        let untracked = try XCTUnwrap(status.first { $0.isUntracked })
        let loaded = try await engine.load(status: untracked, staged: false, from: repository)

        guard case .ready(let diff) = loaded else {
            return XCTFail("期望 ready，实际是 \(loaded)")
        }
        XCTAssertEqual(diff.addedLineCount, 3, "未跟踪文件应整个渲染为新增")
        XCTAssertEqual(diff.deletedLineCount, 0)
        XCTAssertEqual(diff.hunks.first?.newStart, 1)
    }

    func testSecondLoadHitsCache() async throws {
        let url = try makeRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("line1\n", to: "a.txt", in: url)
        try runGit(["add", "-A"], in: url)
        try runGit(["commit", "-m", "initial"], in: url)
        try write("changed\n", to: "a.txt", in: url)

        let repository = GitRepository(root: url)
        let cache = DiffCache()
        let engine = DiffEngine(cache: cache)
        let status = try await repository.status()

        _ = try await engine.load(status: status[0], staged: false, from: repository)
        let cached = await cache.value(for: DiffCacheKey(
            worktreePath: url, filePath: "a.txt", staged: false))
        XCTAssertNotNil(cached, "首次加载后应写入缓存")
    }
}
