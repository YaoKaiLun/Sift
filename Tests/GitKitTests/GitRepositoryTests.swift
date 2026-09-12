import XCTest
@testable import GitKit

final class GitRepositoryTests: XCTestCase {
    func testStatusAndDiffTogether() async throws {
        let fixture = try FixtureRepo()
        try fixture.write("line1\nline2\n", to: "a.txt")
        try fixture.commit("initial")
        try fixture.write("line1\nCHANGED\n", to: "a.txt")

        let repo = GitRepository(root: fixture.url)
        let status = try await repo.status()
        XCTAssertEqual(status.count, 1)

        let diff = try await repo.diff(path: status[0].path, staged: false)
        XCTAssertEqual(diff.addedLineCount, 1)
    }

    func testWorktreesIncludesMain() async throws {
        let fixture = try FixtureRepo()
        try fixture.write("a\n", to: "a.txt")
        try fixture.commit("initial")

        let repo = GitRepository(root: fixture.url)
        let worktrees = try await repo.worktrees()
        XCTAssertEqual(worktrees.count, 1)
        XCTAssertTrue(worktrees[0].isMain)
    }

    func testUntrackedFileContentsAreReadFromDisk() async throws {
        let fixture = try FixtureRepo()
        try fixture.write("a\n", to: "a.txt")
        try fixture.commit("initial")
        try fixture.write("brand new\nsecond line\n", to: "new.txt")

        let repo = GitRepository(root: fixture.url)
        let contents = try await repo.fileContents(path: "new.txt")
        XCTAssertEqual(contents, "brand new\nsecond line\n")
    }

    func testDiscoverRootFromSubdirectory() async throws {
        let fixture = try FixtureRepo()
        try fixture.write("a\n", to: "nested/deep/a.txt")
        try fixture.commit("initial")

        let subdirectory = fixture.url.appendingPathComponent("nested/deep")
        let root = try await GitRepository.discoverRoot(at: subdirectory, runner: GitRunner())
        // 临时目录路径可能带 /private 前缀，比较解析后的真实路径。
        XCTAssertEqual(root.resolvingSymlinksInPath().path,
                       fixture.url.resolvingSymlinksInPath().path)
    }

    func testDiscoverRootThrowsOutsideRepository() async throws {
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("not-a-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        do {
            _ = try await GitRepository.discoverRoot(at: temporary, runner: GitRunner())
            XCTFail("期望在非 git 目录中抛错")
        } catch {
            // 符合预期
        }
    }

    // MARK: - 行数统计

    func testLineStatsCountsAdditionsAndDeletions() async throws {
        let fixture = try FixtureRepo()
        try fixture.write("a\nb\nc\n", to: "a.txt")
        try fixture.commit("initial")
        try fixture.write("a\nB CHANGED\nc\nd\ne\n", to: "a.txt")

        let stats = try await GitRepository(root: fixture.url).lineStats()
        let entry = try XCTUnwrap(stats.unstaged["a.txt"])
        XCTAssertEqual(entry.added, 3)
        XCTAssertEqual(entry.deleted, 1)
        XCTAssertNil(stats.staged["a.txt"])
    }

    func testLineStatsSeparatesStagedAndUnstaged() async throws {
        let fixture = try FixtureRepo()
        try fixture.write("a\n", to: "staged.txt")
        try fixture.write("a\n", to: "unstaged.txt")
        try fixture.commit("initial")
        try fixture.write("a\nstaged addition\n", to: "staged.txt")
        try fixture.git("add", "staged.txt")
        try fixture.write("a\nunstaged addition\n", to: "unstaged.txt")

        let stats = try await GitRepository(root: fixture.url).lineStats()
        XCTAssertEqual(stats.staged["staged.txt"]?.added, 1, "已暂存的改动应出现在 staged 映射")
        XCTAssertNil(stats.unstaged["staged.txt"], "已全部暂存的文件不应出现在 unstaged")
        XCTAssertEqual(stats.unstaged["unstaged.txt"]?.added, 1)
        XCTAssertNil(stats.staged["unstaged.txt"])
    }

    func testLineStatsDoesNotMergeBothSidesOfSameFile() async throws {
        let fixture = try FixtureRepo()
        try fixture.write("a\n", to: "both.txt")
        try fixture.commit("initial")
        try fixture.write("a\nstaged line\n", to: "both.txt")
        try fixture.git("add", "both.txt")
        try fixture.write("a\nstaged line\nunstaged line\n", to: "both.txt")

        let stats = try await GitRepository(root: fixture.url).lineStats()
        XCTAssertEqual(stats.staged["both.txt"]?.added, 1)
        XCTAssertEqual(stats.unstaged["both.txt"]?.added, 1)
    }

    func testLineStatsMarksBinaryFiles() async throws {
        let fixture = try FixtureRepo()
        try fixture.write("placeholder\n", to: "img.bin")
        try fixture.commit("initial")
        try Data((0..<512).map { UInt8($0 % 256) })
            .write(to: fixture.url.appendingPathComponent("img.bin"))

        let stats = try await GitRepository(root: fixture.url).lineStats()
        XCTAssertTrue(stats.unstaged["img.bin"]?.isBinary ?? false)
    }

    /// -z 模式下重命名记录的路径字段为空，后面跟两个独立的 NUL 字段。
    /// 和 StatusParser 一样，这是最容易导致后续记录错位的地方。
    func testLineStatsHandlesRenameRecords() async throws {
        let fixture = try FixtureRepo()
        try fixture.write(String(repeating: "content\n", count: 20), to: "old.txt")
        try fixture.write("other\n", to: "zzz.txt")
        try fixture.commit("initial")
        try fixture.git("mv", "old.txt", "new.txt")
        try fixture.write("other changed\n", to: "zzz.txt")

        let stats = try await GitRepository(root: fixture.url).lineStats()
        XCTAssertNotNil(stats.staged["new.txt"], "git mv 后的新路径应出现在暂存区统计")
        XCTAssertNotNil(stats.unstaged["zzz.txt"], "重命名记录之后的文件不应被吞掉")
    }
}
