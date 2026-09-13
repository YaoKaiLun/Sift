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

    // MARK: - blob 读取

    func testReadBlobFromWorktreeIndexAndHEAD() async throws {
        let fixture = try FixtureRepo()
        try fixture.write(TestPNG.red, to: "icon.png")
        try fixture.commit("initial")
        try fixture.write(TestPNG.blue, to: "icon.png")
        try fixture.git("add", "icon.png")
        try fixture.write(TestPNG.red, to: "icon.png")

        let repo = GitRepository(root: fixture.url)
        let head = await repo.readBlob(path: "icon.png", from: .head)
        let index = await repo.readBlob(path: "icon.png", from: .index)
        let worktree = await repo.readBlob(path: "icon.png", from: .worktree)
        XCTAssertEqual(head, .bytes(TestPNG.red))
        XCTAssertEqual(index, .bytes(TestPNG.blue))
        XCTAssertEqual(worktree, .bytes(TestPNG.red))
    }

    func testReadBlobMissingPathIsMissing() async throws {
        let fixture = try FixtureRepo()
        try fixture.write("seed\n", to: "a.txt")
        try fixture.commit("initial")

        let repo = GitRepository(root: fixture.url)
        let head = await repo.readBlob(path: "gone.png", from: .head)
        let index = await repo.readBlob(path: "gone.png", from: .index)
        let worktree = await repo.readBlob(path: "gone.png", from: .worktree)
        XCTAssertEqual(head, .missing)
        XCTAssertEqual(index, .missing)
        XCTAssertEqual(worktree, .missing)
    }

    func testReadBlobSkipsContentWhenOverSizeLimit() async throws {
        let fixture = try FixtureRepo()
        try fixture.write(TestPNG.red, to: "icon.png")
        try fixture.commit("initial")

        let repo = GitRepository(root: fixture.url, maximumBlobBytes: 10)
        let worktree = await repo.readBlob(path: "icon.png", from: .worktree)
        let head = await repo.readBlob(path: "icon.png", from: .head)
        let index = await repo.readBlob(path: "icon.png", from: .index)
        XCTAssertEqual(worktree, .tooLarge(byteCount: TestPNG.red.count))
        XCTAssertEqual(head, .tooLarge(byteCount: TestPNG.red.count))
        XCTAssertEqual(index, .tooLarge(byteCount: TestPNG.red.count))
    }

    func testLooksBinaryDetectsNULInFirst8KB() {
        XCTAssertTrue(GitRepository.looksBinary(Data([0x00, 0x01, 0x02])))
        XCTAssertFalse(GitRepository.looksBinary(Data("hello\n".utf8)))
        var lateNUL = Data(repeating: 1, count: 8000)
        lateNUL.append(0)
        XCTAssertFalse(GitRepository.looksBinary(lateNUL), "git 只看前 8KB")
    }
}

enum TestPNG {
    /// 1×1 红
    static let red = Data([
        137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82,
        0, 0, 0, 1, 0, 0, 0, 1, 8, 2, 0, 0, 0, 144, 119, 83, 222,
        0, 0, 0, 12, 73, 68, 65, 84, 120, 156, 99, 248, 207, 192, 0, 0,
        3, 1, 1, 0, 201, 254, 146, 239, 0, 0, 0, 0, 73, 69, 78, 68,
        174, 66, 96, 130
    ])
    /// 1×1 蓝
    static let blue = Data([
        137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82,
        0, 0, 0, 1, 0, 0, 0, 1, 8, 2, 0, 0, 0, 144, 119, 83, 222,
        0, 0, 0, 12, 73, 68, 65, 84, 120, 156, 99, 96, 96, 248, 15, 0,
        1, 3, 1, 0, 8, 137, 194, 236, 0, 0, 0, 0, 73, 69, 78, 68,
        174, 66, 96, 130
    ])
}
