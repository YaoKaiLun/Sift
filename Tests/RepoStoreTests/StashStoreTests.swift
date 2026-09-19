import XCTest
import GitKit
import AIClient
import SiftLocalization
@testable import RepoStore

@MainActor
final class StashStoreTests: XCTestCase {
    func testRepositoryEntryListsStashesAfterAdd() async throws {
        let url = try makeRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("a\n", to: "a.txt", in: url)
        try runGit(["add", "-A"], in: url)
        try runGit(["commit", "-m", "initial"], in: url)
        try write("changed\n", to: "a.txt", in: url)
        try runGit(["stash", "push", "-m", "park a"], in: url)

        let store = makeStore()
        await store.addRepository(at: url)
        XCTAssertEqual(store.repositories.first?.stashes.count, 1)
        XCTAssertTrue(store.repositories.first?.stashes.first?.message.contains("park a") == true)
    }

    func testSelectStashLoadsStashFiles() async throws {
        let url = try makeRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("a\n", to: "a.txt", in: url)
        try runGit(["add", "-A"], in: url)
        try runGit(["commit", "-m", "initial"], in: url)
        try write("changed\n", to: "a.txt", in: url)
        try runGit(["stash", "push", "-m", "park a"], in: url)

        let store = makeStore()
        await store.addRepository(at: url)
        let stash = try XCTUnwrap(store.repositories.first?.stashes.first)
        await store.select(stash: stash)
        XCTAssertEqual(store.selectedStash?.sha, stash.sha)
        XCTAssertEqual(store.fileStatuses.map(\.path), ["a.txt"])
        XCTAssertNil(store.selectedCommit)
    }

    func testSelectStashFileLoadsUntrackedDiff() async throws {
        let url = try makeRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("a\n", to: "a.txt", in: url)
        try runGit(["add", "-A"], in: url)
        try runGit(["commit", "-m", "initial"], in: url)
        try write("line1\nline2\n", to: "new.txt", in: url)
        try runGit(["stash", "push", "-u", "-m", "park new"], in: url)

        let store = makeStore()
        await store.addRepository(at: url)
        let stash = try XCTUnwrap(store.repositories.first?.stashes.first)
        await store.select(stash: stash)
        let file = try XCTUnwrap(store.fileStatuses.first { $0.path == "new.txt" })
        await store.select(file: file, staged: false)

        guard case .ready(let diff) = store.loadedDiff else {
            return XCTFail("应加载 untracked stash 文件的 diff，实际是 \(String(describing: store.loadedDiff))")
        }
        XCTAssertGreaterThan(diff.addedLineCount, 0, "stash -u 的新文件在 ^3，不能只 diff WIP commit")
    }

    func testApplyStashRefusesWhenWorktreeHasUntrackedFile() async throws {
        let url = try makeRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("a\n", to: "a.txt", in: url)
        try runGit(["add", "-A"], in: url)
        try runGit(["commit", "-m", "initial"], in: url)
        try write("changed\n", to: "a.txt", in: url)
        try runGit(["stash", "push", "-m", "park a"], in: url)
        try write("u\n", to: "u.txt", in: url)

        let store = makeStore()
        await store.addRepository(at: url)
        let stash = try XCTUnwrap(store.repositories.first?.stashes.first)
        await store.applyStash(stash)

        XCTAssertEqual(store.errorMessage, L10n.cannotApplyStashWithLocalChanges)
        XCTAssertEqual(try String(contentsOf: url.appendingPathComponent("a.txt"), encoding: .utf8), "a\n")
        XCTAssertEqual(store.repositories.first?.stashes.count, 1)
    }

    func testApplyStashOnCleanWorktreeRestoresFilesAndKeepsStash() async throws {
        let url = try makeRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("a\n", to: "a.txt", in: url)
        try runGit(["add", "-A"], in: url)
        try runGit(["commit", "-m", "initial"], in: url)
        try write("changed\n", to: "a.txt", in: url)
        try runGit(["stash", "push", "-m", "park a"], in: url)

        let store = makeStore()
        await store.addRepository(at: url)
        let stash = try XCTUnwrap(store.repositories.first?.stashes.first)
        await store.select(stash: stash)
        await store.applyStash(stash)

        XCTAssertNil(store.errorMessage)
        XCTAssertNil(store.selectedStash)
        XCTAssertEqual(try String(contentsOf: url.appendingPathComponent("a.txt"), encoding: .utf8), "changed\n")
        XCTAssertEqual(store.repositories.first?.stashes.count, 1)
        XCTAssertTrue(store.fileStatuses.contains { $0.path == "a.txt" })
    }

    func testDropStashRemovesEntryAndClearsSelection() async throws {
        let url = try makeRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("a\n", to: "a.txt", in: url)
        try runGit(["add", "-A"], in: url)
        try runGit(["commit", "-m", "initial"], in: url)
        try write("changed\n", to: "a.txt", in: url)
        try runGit(["stash", "push", "-m", "park a"], in: url)

        let store = makeStore()
        await store.addRepository(at: url)
        let stash = try XCTUnwrap(store.repositories.first?.stashes.first)
        await store.select(stash: stash)
        await store.dropStash(stash)

        XCTAssertNil(store.selectedStash)
        XCTAssertTrue(store.repositories.first?.stashes.isEmpty == true)
    }

    func testRemoveWorktreeRefusesWhenDirty() async throws {
        let url = try makeRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("a\n", to: "a.txt", in: url)
        try runGit(["add", "-A"], in: url)
        try runGit(["commit", "-m", "initial"], in: url)

        let store = makeStore()
        await store.addRepository(at: url)
        let linked = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + "-wt")
        defer {
            try? runGit(["worktree", "remove", "--force", linked.path], in: url)
            try? FileManager.default.removeItem(at: linked)
        }
        try runGit(["worktree", "add", "-b", "feature-x", linked.path], in: url)
        await store.refreshFileList()
        let worktree = try XCTUnwrap(store.repositories.first?.worktrees.first { !$0.isMain })
        await store.select(worktree: worktree)
        try write("dirty\n", to: "dirty.txt", in: linked)

        await store.removeWorktree(worktree)
        XCTAssertEqual(store.errorMessage, L10n.cannotRemoveDirtyWorktree)
        XCTAssertEqual(store.repositories.first?.worktrees.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: linked.path))
    }

    func testRemoveLinkedWorktreeSucceedsWhenClean() async throws {
        let url = try makeRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("a\n", to: "a.txt", in: url)
        try runGit(["add", "-A"], in: url)
        try runGit(["commit", "-m", "initial"], in: url)

        let store = makeStore()
        await store.addRepository(at: url)
        let linked = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + "-wt")
        defer { try? FileManager.default.removeItem(at: linked) }
        try runGit(["worktree", "add", "-b", "feature-x", linked.path], in: url)
        await store.refreshFileList()
        let worktree = try XCTUnwrap(store.repositories.first?.worktrees.first { !$0.isMain })
        await store.select(worktree: worktree)
        await store.removeWorktree(worktree)

        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.repositories.first?.worktrees.count, 1)
        XCTAssertTrue(store.selectedWorktree?.isMain == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: linked.path))
    }

    func testRemoveMainWorktreeIsRejected() async throws {
        let url = try makeRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("a\n", to: "a.txt", in: url)
        try runGit(["add", "-A"], in: url)
        try runGit(["commit", "-m", "initial"], in: url)

        let store = makeStore()
        await store.addRepository(at: url)
        let main = try XCTUnwrap(store.selectedWorktree)
        await store.removeWorktree(main)
        XCTAssertEqual(store.errorMessage, L10n.cannotRemoveMainWorktree)
        XCTAssertEqual(store.repositories.first?.worktrees.count, 1)
    }

    private func makeRepository() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sift-stash-store-\(UUID().uuidString)")
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
