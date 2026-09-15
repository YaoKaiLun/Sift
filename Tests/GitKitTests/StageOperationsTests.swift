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

    func testDiscardDeletedFileRestoresWorkingTree() async throws {
        let fixture = try FixtureRepo()
        try fixture.write("keep\n", to: "gone.txt")
        try fixture.commit("initial")
        try FileManager.default.removeItem(at: fixture.url.appendingPathComponent("gone.txt"))

        let repo = GitRepository(root: fixture.url)
        let diff = try await repo.diff(path: "gone.txt", staged: false)
        try await repo.discard(hunk: try XCTUnwrap(diff.hunks.first),
                               path: "gone.txt", originalPath: nil, kind: .deleted)

        XCTAssertEqual(
            try String(contentsOf: fixture.url.appendingPathComponent("gone.txt"), encoding: .utf8),
            "keep\n")
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

    func testStageMultiplePathsInOneCall() async throws {
        let fixture = try FixtureRepo()
        try fixture.write("a\n", to: "a.txt")
        try fixture.write("b\n", to: "b.txt")
        try fixture.commit("initial")
        try fixture.write("A\n", to: "a.txt")
        try fixture.write("B\n", to: "b.txt")

        let repo = GitRepository(root: fixture.url)
        try await repo.stage(paths: ["a.txt", "b.txt"])
        let status = try await repo.status()
        XCTAssertEqual(status.filter(\.hasStagedChanges).map(\.path).sorted(), ["a.txt", "b.txt"])
        XCTAssertTrue(status.allSatisfy { !$0.hasUnstagedChanges })

        try await repo.unstage(paths: ["a.txt", "b.txt"])
        let unstaged = try await repo.status()
        XCTAssertEqual(unstaged.filter(\.hasUnstagedChanges).map(\.path).sorted(), ["a.txt", "b.txt"])
        XCTAssertTrue(unstaged.allSatisfy { !$0.hasStagedChanges })
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

    func testDeleteUntrackedRefusesTrackedFile() async throws {
        let fixture = try FixtureRepo()
        try fixture.write("keep me\n", to: "tracked.txt")
        try fixture.commit("initial")

        let repo = GitRepository(root: fixture.url)
        let path = fixture.url.appendingPathComponent("tracked.txt").path
        do {
            try await repo.deleteUntracked(path: "tracked.txt")
            XCTFail("应拒绝删除已跟踪文件")
        } catch {
            // 符合预期
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path),
                      "已跟踪文件不得被 FileManager.removeItem")
        XCTAssertEqual(
            try String(contentsOf: fixture.url.appendingPathComponent("tracked.txt"), encoding: .utf8),
            "keep me\n")
    }

    func testStageAndUnstageBinaryFile() async throws {
        let fixture = try FixtureRepo()
        let original = Data((0..<512).map { UInt8($0 % 256) })
        try original.write(to: fixture.url.appendingPathComponent("img.bin"))
        try fixture.commit("initial")
        let changed = Data((0..<512).map { UInt8(255 - ($0 % 256)) })
        try changed.write(to: fixture.url.appendingPathComponent("img.bin"))

        let repo = GitRepository(root: fixture.url)
        try await repo.stage(path: "img.bin")
        var status = try await repo.status()
        let staged = try XCTUnwrap(status.first { $0.path == "img.bin" })
        XCTAssertTrue(staged.hasStagedChanges)
        XCTAssertFalse(staged.hasUnstagedChanges)

        try await repo.unstage(path: "img.bin")
        status = try await repo.status()
        let unstaged = try XCTUnwrap(status.first { $0.path == "img.bin" })
        XCTAssertTrue(unstaged.hasUnstagedChanges)
        XCTAssertFalse(unstaged.hasStagedChanges)
    }

    func testHunkApplyUsesMatchingSideWhenBothStagedAndUnstaged() async throws {
        let fixture = try FixtureRepo()
        let original = (1...60).map { "line\($0)" }.joined(separator: "\n") + "\n"
        try fixture.write(original, to: "a.txt")
        try fixture.commit("initial")
        var lines = (1...60).map { "line\($0)" }
        lines[2] = "FIRST"
        try fixture.write(lines.joined(separator: "\n") + "\n", to: "a.txt")
        try fixture.git("add", "a.txt")
        lines[50] = "SECOND"
        try fixture.write(lines.joined(separator: "\n") + "\n", to: "a.txt")

        let repo = GitRepository(root: fixture.url)
        let stagedDiff = try await repo.diff(path: "a.txt", staged: true)
        let unstagedDiff = try await repo.diff(path: "a.txt", staged: false)
        XCTAssertEqual(stagedDiff.hunks.count, 1)
        XCTAssertEqual(unstagedDiff.hunks.count, 1)

        try await repo.stage(
            hunk: try XCTUnwrap(unstagedDiff.hunks.first),
            path: "a.txt", originalPath: nil, kind: .modified)

        var staged = try await repo.diff(path: "a.txt", staged: true)
        var unstaged = try await repo.diff(path: "a.txt", staged: false)
        XCTAssertTrue(staged.hunks.flatMap(\.lines).contains(where: { $0.text == "FIRST" }))
        XCTAssertTrue(staged.hunks.flatMap(\.lines).contains(where: { $0.text == "SECOND" }))
        XCTAssertTrue(unstaged.hunks.isEmpty)

        let firstHunk = try XCTUnwrap(
            staged.hunks.first(where: { hunk in hunk.lines.contains { $0.text == "FIRST" } }))
        try await repo.unstage(
            hunk: firstHunk, path: "a.txt", originalPath: nil, kind: .modified)

        staged = try await repo.diff(path: "a.txt", staged: true)
        unstaged = try await repo.diff(path: "a.txt", staged: false)
        XCTAssertFalse(staged.hunks.flatMap(\.lines).contains(where: { $0.text == "FIRST" }))
        XCTAssertTrue(staged.hunks.flatMap(\.lines).contains(where: { $0.text == "SECOND" }))
        XCTAssertTrue(unstaged.hunks.flatMap(\.lines).contains(where: { $0.text == "FIRST" }))
        XCTAssertFalse(unstaged.hunks.flatMap(\.lines).contains(where: { $0.text == "SECOND" }))
    }

    func testDiscardWorktreeRestoresModifiedFile() async throws {
        let fixture = try FixtureRepo()
        try fixture.write("a\nb\nc\n", to: "a.txt")
        try fixture.commit("initial")
        try fixture.write("a\nB\nc\n", to: "a.txt")

        let repo = GitRepository(root: fixture.url)
        try await repo.discardWorktree(paths: ["a.txt"])

        let contents = try String(contentsOf: fixture.url.appendingPathComponent("a.txt"), encoding: .utf8)
        XCTAssertEqual(contents, "a\nb\nc\n")
        let status = try await repo.status()
        XCTAssertTrue(status.isEmpty, "放弃工作区修改后应变干净，实际是 \(status)")
    }

    func testDiscardWorktreeKeepsStagedChanges() async throws {
        let fixture = try FixtureRepo()
        try fixture.write("a\n", to: "a.txt")
        try fixture.commit("initial")
        try fixture.write("staged\n", to: "a.txt")
        try fixture.git("add", "a.txt")
        try fixture.write("unstaged\n", to: "a.txt")

        let repo = GitRepository(root: fixture.url)
        try await repo.discardWorktree(paths: ["a.txt"])

        let contents = try String(contentsOf: fixture.url.appendingPathComponent("a.txt"), encoding: .utf8)
        XCTAssertEqual(contents, "staged\n")
        let status = try await repo.status()
        let file = try XCTUnwrap(status.first)
        XCTAssertTrue(file.hasStagedChanges)
        XCTAssertFalse(file.hasUnstagedChanges)
    }

    func testDiscardWorktreeRestoresDeletedFile() async throws {
        let fixture = try FixtureRepo()
        try fixture.write("keep\n", to: "a.txt")
        try fixture.commit("initial")
        try FileManager.default.removeItem(at: fixture.url.appendingPathComponent("a.txt"))

        let repo = GitRepository(root: fixture.url)
        try await repo.discardWorktree(paths: ["a.txt"])

        XCTAssertEqual(
            try String(contentsOf: fixture.url.appendingPathComponent("a.txt"), encoding: .utf8),
            "keep\n")
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
