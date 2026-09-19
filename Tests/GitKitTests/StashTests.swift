import XCTest
@testable import GitKit

final class StashTests: XCTestCase {
    func testStashesEmptyOnCleanRepository() async throws {
        let fixture = try FixtureRepo()
        try fixture.write("a\n", to: "a.txt")
        try fixture.commit("initial")

        let stashes = try await GitRepository(root: fixture.url).stashes()
        XCTAssertTrue(stashes.isEmpty)
    }

    func testStashesListsWIPEntryAfterStash() async throws {
        let fixture = try FixtureRepo()
        try fixture.write("a\n", to: "a.txt")
        try fixture.commit("initial")
        try fixture.write("changed\n", to: "a.txt")
        try fixture.git("stash", "push", "-m", "park a")

        let stashes = try await GitRepository(root: fixture.url).stashes()
        XCTAssertEqual(stashes.count, 1)
        XCTAssertFalse(stashes[0].sha.isEmpty)
        XCTAssertEqual(stashes[0].reflogSelector, "stash@{0}")
        XCTAssertTrue(stashes[0].message.contains("park a"), stashes[0].message)
    }

    func testStashFilesListsTrackedChange() async throws {
        let fixture = try FixtureRepo()
        try fixture.write("a\n", to: "a.txt")
        try fixture.commit("initial")
        try fixture.write("changed\n", to: "a.txt")
        try fixture.git("stash", "push", "-m", "park a")

        let files = try await GitRepository(root: fixture.url).stashFiles(selector: "stash@{0}")
        XCTAssertEqual(files.files.map(\.path), ["a.txt"])
        XCTAssertEqual(files.files[0].indexStatus, .modified)
        XCTAssertEqual(files.lineStats["a.txt"]?.added, 1)
        XCTAssertEqual(files.lineStats["a.txt"]?.deleted, 1)
    }

    func testStashFilesIncludesUntrackedWhenStashed() async throws {
        let fixture = try FixtureRepo()
        try fixture.write("a\n", to: "a.txt")
        try fixture.commit("initial")
        try fixture.write("new\n", to: "new.txt")
        try fixture.git("stash", "push", "-u", "-m", "park new")

        let files = try await GitRepository(root: fixture.url).stashFiles(selector: "stash@{0}")
        XCTAssertTrue(files.files.contains { $0.path == "new.txt" && $0.indexStatus == .added })

        let diff = try await GitRepository(root: fixture.url)
            .stashDiff(path: "new.txt", selector: "stash@{0}")
        XCTAssertGreaterThan(diff.addedLineCount, 0)
    }

    func testHasUncommittedChangesDetectsTrackedAndUntracked() async throws {
        let fixture = try FixtureRepo()
        try fixture.write("a\n", to: "a.txt")
        try fixture.commit("initial")
        let repo = GitRepository(root: fixture.url)
        var dirty = try await repo.hasUncommittedChanges()
        XCTAssertFalse(dirty)

        try fixture.write("changed\n", to: "a.txt")
        dirty = try await repo.hasUncommittedChanges()
        XCTAssertTrue(dirty)

        try fixture.git("checkout", "--", "a.txt")
        try fixture.write("u\n", to: "u.txt")
        dirty = try await repo.hasUncommittedChanges()
        XCTAssertTrue(dirty)
    }

    func testApplyStashRestoresWorktreeAndKeepsStash() async throws {
        let fixture = try FixtureRepo()
        try fixture.write("a\n", to: "a.txt")
        try fixture.commit("initial")
        try fixture.write("changed\n", to: "a.txt")
        try fixture.git("stash", "push", "-m", "park a")

        let repo = GitRepository(root: fixture.url)
        try await repo.applyStash(selector: "stash@{0}")
        XCTAssertEqual(try String(contentsOf: fixture.url.appendingPathComponent("a.txt"), encoding: .utf8),
                       "changed\n")
        let remaining = try await repo.stashes()
        XCTAssertEqual(remaining.count, 1)
    }

    func testDropStashRemovesEntry() async throws {
        let fixture = try FixtureRepo()
        try fixture.write("a\n", to: "a.txt")
        try fixture.commit("initial")
        try fixture.write("changed\n", to: "a.txt")
        try fixture.git("stash", "push", "-m", "park a")

        let repo = GitRepository(root: fixture.url)
        try await repo.dropStash(selector: "stash@{0}")
        let remaining = try await repo.stashes()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testRemoveLinkedWorktreeLeavesMain() async throws {
        let fixture = try FixtureRepo()
        try fixture.write("a\n", to: "a.txt")
        try fixture.commit("initial")
        let extra = fixture.url.deletingLastPathComponent()
            .appendingPathComponent("wt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: extra) }
        try fixture.git("worktree", "add", "-b", "feature", extra.path)

        let repo = GitRepository(root: fixture.url)
        try await repo.removeWorktree(at: extra)
        let remaining = try await repo.worktrees()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertTrue(remaining[0].isMain)
        XCTAssertFalse(FileManager.default.fileExists(atPath: extra.path))
    }
}
