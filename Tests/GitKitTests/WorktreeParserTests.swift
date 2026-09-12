import XCTest
@testable import GitKit

final class WorktreeParserTests: XCTestCase {
    private let runner = GitRunner()

    private func worktrees(of repo: FixtureRepo) async throws -> [Worktree] {
        let data = try await runner.run(["worktree", "list", "--porcelain"], in: repo.url)
        return WorktreeParser.parse(data)
    }

    func testSingleRepositoryReportsOneMainWorktree() async throws {
        let repo = try FixtureRepo()
        try repo.write("a\n", to: "a.txt")
        try repo.commit("initial")

        let result = try await worktrees(of: repo)
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].isMain)
        XCTAssertEqual(result[0].branch, "main")
        XCTAssertFalse(result[0].isDetached)
        XCTAssertFalse(result[0].isBare)
    }

    func testAdditionalWorktreeIsDiscovered() async throws {
        let repo = try FixtureRepo()
        try repo.write("a\n", to: "a.txt")
        try repo.commit("initial")

        let extra = repo.url.deletingLastPathComponent()
            .appendingPathComponent("wt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: extra) }
        try repo.git("worktree", "add", "-b", "feature", extra.path)

        let result = try await worktrees(of: repo)
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result[0].isMain, "第一条必须是主工作树")
        XCTAssertFalse(result[1].isMain)
        XCTAssertEqual(result[1].branch, "feature")
    }

    func testDetachedWorktree() async throws {
        let repo = try FixtureRepo()
        try repo.write("a\n", to: "a.txt")
        try repo.commit("initial")
        let sha = try repo.git("rev-parse", "HEAD")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let extra = repo.url.deletingLastPathComponent()
            .appendingPathComponent("wt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: extra) }
        try repo.git("worktree", "add", "--detach", extra.path, sha)

        let result = try await worktrees(of: repo)
        let detached = try XCTUnwrap(result.first { !$0.isMain })
        XCTAssertTrue(detached.isDetached)
        XCTAssertNil(detached.branch)
        XCTAssertEqual(detached.head, sha)
        XCTAssertEqual(detached.displayName, String(sha.prefix(7)))
    }

    func testParsesBareAndLockedFlagsFromRawOutput() {
        let raw = """
        worktree /repos/main
        HEAD 0123456789abcdef0123456789abcdef01234567
        branch refs/heads/main

        worktree /repos/locked-wt
        HEAD fedcba9876543210fedcba9876543210fedcba98
        detached
        locked

        worktree /repos/bare
        bare

        """
        let result = WorktreeParser.parse(Data(raw.utf8))
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].branch, "main")
        XCTAssertTrue(result[1].isLocked)
        XCTAssertTrue(result[1].isDetached)
        XCTAssertTrue(result[2].isBare)
        XCTAssertNil(result[2].head)
    }
}
