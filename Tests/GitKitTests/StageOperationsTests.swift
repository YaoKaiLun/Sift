import XCTest
@testable import GitKit

final class StageOperationsTests: XCTestCase {
    func testStageAndUnstageWholeFile() async throws {
        let fixture = try FixtureRepo()
        try fixture.write("a\nb\n", to: "a.txt")
        try fixture.commit("initial")
        try fixture.write("a\nB\n", to: "a.txt")

        let repo = GitRepository(root: fixture.url)
        try await repo.stage(path: "a.txt")
        var status = try await repo.status()
        XCTAssertTrue(try XCTUnwrap(status.first).hasStagedChanges)
        XCTAssertFalse(try XCTUnwrap(status.first).hasUnstagedChanges)

        try await repo.unstage(path: "a.txt")
        status = try await repo.status()
        XCTAssertTrue(try XCTUnwrap(status.first).hasUnstagedChanges)
        XCTAssertFalse(try XCTUnwrap(status.first).hasStagedChanges)
    }

    func testStageOneOfTwoHunks() async throws {
        let fixture = try FixtureRepo()
        let original = (1...60).map { "line\($0)" }.joined(separator: "\n") + "\n"
        try fixture.write(original, to: "a.txt")
        try fixture.commit("initial")
        var lines = (1...60).map { "line\($0)" }
        lines[2] = "FIRST"
        lines[50] = "SECOND"
        try fixture.write(lines.joined(separator: "\n") + "\n", to: "a.txt")

        let repo = GitRepository(root: fixture.url)
        let diff = try await repo.diff(path: "a.txt", staged: false)
        XCTAssertEqual(diff.hunks.count, 2)
        try await repo.stage(hunk: diff.hunks[0], path: "a.txt",
                             originalPath: nil, kind: .modified)

        let status = try await repo.status()
        let file = try XCTUnwrap(status.first)
        XCTAssertTrue(file.hasStagedChanges)
        XCTAssertTrue(file.hasUnstagedChanges)

        let stagedDiff = try await repo.diff(path: "a.txt", staged: true)
        XCTAssertTrue(stagedDiff.hunks.flatMap(\.lines).contains(where: { $0.text == "FIRST" }))
        XCTAssertFalse(stagedDiff.hunks.flatMap(\.lines).contains(where: { $0.text == "SECOND" }))
    }

    func testDiscardHunkRestoresWorkingTree() async throws {
        let fixture = try FixtureRepo()
        try fixture.write("a\nb\nc\n", to: "a.txt")
        try fixture.commit("initial")
        try fixture.write("a\nB\nc\n", to: "a.txt")

        let repo = GitRepository(root: fixture.url)
        let diff = try await repo.diff(path: "a.txt", staged: false)
        try await repo.discard(hunk: try XCTUnwrap(diff.hunks.first),
                               path: "a.txt", originalPath: nil, kind: .modified)

        let contents = try String(contentsOf: fixture.url.appendingPathComponent("a.txt"), encoding: .utf8)
        XCTAssertEqual(contents, "a\nb\nc\n")
    }

    func testStageUntrackedFile() async throws {
        let fixture = try FixtureRepo()
        try fixture.write("a\n", to: "a.txt")
        try fixture.commit("initial")
        try fixture.write("new\n", to: "new.txt")

        let repo = GitRepository(root: fixture.url)
        try await repo.stage(path: "new.txt")
        let status = try await repo.status()
        let file = try XCTUnwrap(status.first { $0.path == "new.txt" })
        XCTAssertTrue(file.hasStagedChanges)
        XCTAssertFalse(file.isUntracked)
    }

    func testDeleteUntrackedRemovesFile() async throws {
        let fixture = try FixtureRepo()
        try fixture.write("a\n", to: "a.txt")
        try fixture.commit("initial")
        try fixture.write("new\n", to: "new.txt")

        let repo = GitRepository(root: fixture.url)
        try await repo.deleteUntracked(path: "new.txt")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.url.appendingPathComponent("new.txt").path))
    }

    func testDeleteUntrackedRejectsPathEscape() async throws {
        let fixture = try FixtureRepo()
        let repo = GitRepository(root: fixture.url)
        do {
            try await repo.deleteUntracked(path: "../outside.txt")
            XCTFail("应拒绝逃逸路径")
        } catch {
            // 符合预期
        }
    }

    func testApplyBadPatchThrows() async throws {
        let fixture = try FixtureRepo()
        try fixture.write("a\n", to: "a.txt")
        try fixture.commit("initial")
        let repo = GitRepository(root: fixture.url)
        do {
            try await repo.apply(patch: "not a patch\n", cached: true, reverse: false)
            XCTFail("应抛 nonZeroExit")
        } catch let error as GitError {
            guard case .nonZeroExit = error else {
                return XCTFail("期望 nonZeroExit，实际是 \(error)")
            }
        }
    }
}
