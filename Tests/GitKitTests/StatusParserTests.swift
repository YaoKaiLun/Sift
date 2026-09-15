import XCTest
@testable import GitKit

final class StatusParserTests: XCTestCase {
    private let runner = GitRunner()
    private let statusArgs = ["status", "--porcelain=v2", "-z", "--untracked-files=all"]

    private func status(of repo: FixtureRepo) async throws -> [FileStatus] {
        let data = try await runner.run(statusArgs, in: repo.url)
        return try StatusParser.parse(data)
    }

    func testCleanRepositoryHasNoEntries() async throws {
        let repo = try FixtureRepo()
        try repo.write("a\n", to: "a.txt")
        try repo.commit("initial")
        let result = try await status(of: repo)
        XCTAssertTrue(result.isEmpty)
    }

    func testUnstagedModification() async throws {
        let repo = try FixtureRepo()
        try repo.write("a\n", to: "a.txt")
        try repo.commit("initial")
        try repo.write("changed\n", to: "a.txt")

        let result = try await status(of: repo)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].path, "a.txt")
        XCTAssertEqual(result[0].indexStatus, .unmodified)
        XCTAssertEqual(result[0].worktreeStatus, .modified)
        XCTAssertTrue(result[0].hasUnstagedChanges)
        XCTAssertTrue(result[0].hasWorkingTreeChanges)
        XCTAssertTrue(result[0].canDiscardWorktree)
        XCTAssertFalse(result[0].hasStagedChanges)
    }

    func testStagedAndUnstagedOnSameFile() async throws {
        let repo = try FixtureRepo()
        try repo.write("a\n", to: "a.txt")
        try repo.commit("initial")
        try repo.write("staged\n", to: "a.txt")
        try repo.git("add", "a.txt")
        try repo.write("staged then modified again\n", to: "a.txt")

        let result = try await status(of: repo)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].indexStatus, .modified)
        XCTAssertEqual(result[0].worktreeStatus, .modified)
        XCTAssertTrue(result[0].hasStagedChanges)
        XCTAssertTrue(result[0].hasUnstagedChanges)
    }

    func testUntrackedFile() async throws {
        let repo = try FixtureRepo()
        try repo.write("a\n", to: "a.txt")
        try repo.commit("initial")
        try repo.write("new\n", to: "new.txt")

        let result = try await status(of: repo)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].path, "new.txt")
        XCTAssertTrue(result[0].isUntracked)
        XCTAssertFalse(result[0].hasUnstagedChanges)
        XCTAssertFalse(result[0].canDiscardWorktree)
        XCTAssertTrue(result[0].hasWorkingTreeChanges)
    }

    func testDeletedFile() async throws {
        let repo = try FixtureRepo()
        try repo.write("a\n", to: "a.txt")
        try repo.commit("initial")
        try repo.delete("a.txt")

        let result = try await status(of: repo)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].worktreeStatus, .deleted)
        XCTAssertTrue(result[0].canDiscardWorktree)
    }

    /// 类型 2 的记录会消耗两个 NUL 字段。如果解析器没处理，
    /// 原路径会被当成下一条记录，导致后续全部错位。
    func testRenameRecordConsumesTwoFields() async throws {
        let repo = try FixtureRepo()
        try repo.write(String(repeating: "content line\n", count: 20), to: "old.txt")
        try repo.write("other\n", to: "zzz.txt")
        try repo.commit("initial")
        try repo.git("mv", "old.txt", "new.txt")
        try repo.write("other changed\n", to: "zzz.txt")

        let result = try await status(of: repo)
        let renamed = try XCTUnwrap(result.first { $0.indexStatus == .renamed })
        XCTAssertEqual(renamed.path, "new.txt")
        XCTAssertEqual(renamed.originalPath, "old.txt")
        // 关键断言：重命名之后的记录没有被吞掉或错位。
        XCTAssertTrue(result.contains { $0.path == "zzz.txt" },
                      "重命名记录后面的文件丢失了，说明多消耗或少消耗了字段：\(result)")
    }

    func testPathWithSpaces() async throws {
        let repo = try FixtureRepo()
        try repo.write("a\n", to: "dir with spaces/file name.txt")
        try repo.commit("initial")
        try repo.write("changed\n", to: "dir with spaces/file name.txt")

        let result = try await status(of: repo)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].path, "dir with spaces/file name.txt")
    }

    func testPathWithQuotesAndUnicode() async throws {
        let repo = try FixtureRepo()
        let tricky = "中文目录/it's \"quoted\".txt"
        try repo.write("a\n", to: tricky)
        try repo.commit("initial")
        try repo.write("changed\n", to: tricky)

        let result = try await status(of: repo)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].path, tricky,
                       "-z 模式下路径不应被转义，实际得到：\(result[0].path)")
    }

    func testMultipleFilesAllParsed() async throws {
        let repo = try FixtureRepo()
        for index in 0..<10 { try repo.write("v1\n", to: "f\(index).txt") }
        try repo.commit("initial")
        for index in 0..<10 { try repo.write("v2\n", to: "f\(index).txt") }

        let result = try await status(of: repo)
        XCTAssertEqual(result.count, 10)
    }
}
