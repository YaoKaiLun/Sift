import XCTest
import AIClient
import GitKit
import Security
@testable import RepoStore

@MainActor
final class RepoStoreTests: XCTestCase {
    private func makeRepository() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sift-store-\(UUID().uuidString)")
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

    private func makeStore(keychain: any KeychainStore = MemoryKeychain()) -> RepoStore {
        let stateURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sift-state-\(UUID().uuidString)/state.json")
        return RepoStore(
            stateStore: PersistedStateStore(fileURL: stateURL),
            keychain: keychain)
    }

    func testRefreshReloadsSelectedDiff() async throws {
        let url = try makeRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("line1\nline2\n", to: "a.txt", in: url)
        try runGit(["add", "-A"], in: url)
        try runGit(["commit", "-m", "initial"], in: url)
        try write("line1\nCHANGED\n", to: "a.txt", in: url)

        let store = makeStore()
        await store.addRepository(at: url)
        let file = try XCTUnwrap(store.fileStatuses.first)
        await store.select(file: file, staged: false)

        guard case .ready(let first) = store.loadedDiff else {
            return XCTFail("首次加载应得到 ready，实际是 \(String(describing: store.loadedDiff))")
        }
        XCTAssertTrue(first.hunks.flatMap(\.lines).contains(where: { $0.text.contains("CHANGED") }))

        try write("line1\nCHANGED AGAIN\n", to: "a.txt", in: url)
        await store.refreshFileList()

        XCTAssertEqual(store.selectedFile?.path, "a.txt")
        XCTAssertFalse(store.selectedFileIsStaged)
        guard case .ready(let second) = store.loadedDiff else {
            return XCTFail("刷新后应重载 diff，实际是 \(String(describing: store.loadedDiff))")
        }
        XCTAssertTrue(second.hunks.flatMap(\.lines).contains(where: { $0.text.contains("CHANGED AGAIN") }),
                      "FSEvents/刷新必须重载当前打开的 diff")
    }

    func testRefreshClearsSelectionWhenSelectedSideVanishes() async throws {
        let url = try makeRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("line1\n", to: "a.txt", in: url)
        try runGit(["add", "-A"], in: url)
        try runGit(["commit", "-m", "initial"], in: url)
        try write("line1\nCHANGED\n", to: "a.txt", in: url)

        let store = makeStore()
        await store.addRepository(at: url)
        let file = try XCTUnwrap(store.fileStatuses.first)
        await store.select(file: file, staged: false)

        try write("line1\n", to: "a.txt", in: url)
        await store.refreshFileList()

        XCTAssertNil(store.selectedFile)
        XCTAssertNil(store.loadedDiff)
    }

    func testRefreshDiscoversNewWorktrees() async throws {
        let url = try makeRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("line1\n", to: "a.txt", in: url)
        try runGit(["add", "-A"], in: url)
        try runGit(["commit", "-m", "initial"], in: url)

        let store = makeStore()
        await store.addRepository(at: url)
        XCTAssertEqual(store.repositories.first?.worktrees.count, 1)

        let linked = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + "-wt")
        defer {
            try? runGit(["worktree", "remove", "--force", linked.path], in: url)
            try? FileManager.default.removeItem(at: linked)
        }
        try runGit(["worktree", "add", "-b", "feature-x", linked.path], in: url)

        await store.refreshFileList()
        let names = store.repositories.first?.worktrees.map(\.displayName) ?? []
        XCTAssertEqual(store.repositories.first?.worktrees.count, 2)
        XCTAssertTrue(names.contains("feature-x"), "刷新必须重新跑 git worktree list，实际是 \(names)")
    }

    func testStageFileMovesToStagedGroup() async throws {
        let url = try makeRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("a\n", to: "a.txt", in: url)
        try runGit(["add", "-A"], in: url)
        try runGit(["commit", "-m", "initial"], in: url)
        try write("a\nB\n", to: "a.txt", in: url)

        let store = makeStore()
        await store.addRepository(at: url)
        let file = try XCTUnwrap(store.fileStatuses.first)
        await store.stage(file: file)

        let updated = try XCTUnwrap(store.fileStatuses.first)
        XCTAssertTrue(updated.hasStagedChanges)
        XCTAssertFalse(updated.hasUnstagedChanges)
    }

    func testContinuousPlanDoesNotLoadDiffs() async throws {
        let url = try makeRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("a\n", to: "a.txt", in: url)
        try write("b\n", to: "b.txt", in: url)
        try runGit(["add", "-A"], in: url)
        try runGit(["commit", "-m", "initial"], in: url)
        try write("a\nA\n", to: "a.txt", in: url)
        try write("b\nB\n", to: "b.txt", in: url)

        let store = makeStore()
        store.usesContinuousDiff = true
        await store.addRepository(at: url)

        XCTAssertEqual(store.continuousPlan.count, 2)
        XCTAssertTrue(store.continuousLoaded.isEmpty, "视口未报告前不得 load diff")
        XCTAssertNil(store.loadedDiff)
    }

    func testContinuousSelectScrollsInsteadOfLoading() async throws {
        let url = try makeRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("a\n", to: "a.txt", in: url)
        try write("b\n", to: "b.txt", in: url)
        try runGit(["add", "-A"], in: url)
        try runGit(["commit", "-m", "initial"], in: url)
        try write("a\nA\n", to: "a.txt", in: url)
        try write("b\nB\n", to: "b.txt", in: url)

        let store = makeStore()
        store.usesContinuousDiff = true
        await store.addRepository(at: url)
        let file = try XCTUnwrap(store.fileStatuses.first { $0.path == "b.txt" })
        await store.select(file: file, staged: false)

        XCTAssertEqual(store.selectedFile?.path, "b.txt")
        XCTAssertEqual(store.continuousRevealID, "u:b.txt")
        XCTAssertTrue(store.continuousLoaded.isEmpty)
        XCTAssertNil(store.loadedDiff)
    }

    func testContinuousVisibleRangeLoadsOnlyIntersectingFiles() async throws {
        let url = try makeRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("a\n", to: "a.txt", in: url)
        try write("b\n", to: "b.txt", in: url)
        try runGit(["add", "-A"], in: url)
        try runGit(["commit", "-m", "initial"], in: url)
        try write("a\nA\n", to: "a.txt", in: url)
        try write("b\nB\n", to: "b.txt", in: url)

        let store = makeStore()
        store.usesContinuousDiff = true
        await store.addRepository(at: url)
        XCTAssertEqual(store.continuousPlan.count, 2)

        let first = try XCTUnwrap(store.continuousPlan.first)
        let second = try XCTUnwrap(store.continuousPlan.dropFirst().first)
        store.loadContinuousEntries(
            visibleRange: NSRange(location: 0, length: 10),
            fileRanges: [
                first.id: NSRange(location: 0, length: 10),
                second.id: NSRange(location: 50, length: 10),
            ])

        let deadline = Date().addingTimeInterval(2)
        while store.continuousLoaded.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(Array(store.continuousLoaded.keys), [first.id],
                       "视口外的文件不得调用 git diff")
    }

    func testContinuousStageHunkReloadsOnNextVisibleRange() async throws {
        let url = try makeRepository()
        defer { try? FileManager.default.removeItem(at: url) }

        let original = (1...60).map { "line\($0)" }.joined(separator: "\n") + "\n"
        try write(original, to: "a.txt", in: url)
        try write("b\n", to: "b.txt", in: url)
        try runGit(["add", "-A"], in: url)
        try runGit(["commit", "-m", "initial"], in: url)

        var lines = (1...60).map { "line\($0)" }
        lines[2] = "FIRST"
        lines[50] = "SECOND"
        try write(lines.joined(separator: "\n") + "\n", to: "a.txt", in: url)
        try write("b\nB\n", to: "b.txt", in: url)

        let store = makeStore()
        store.usesContinuousDiff = true
        await store.addRepository(at: url)

        let unstagedA = try XCTUnwrap(store.continuousPlan.first { $0.id == "u:a.txt" })
        let unstagedB = try XCTUnwrap(store.continuousPlan.first { $0.id == "u:b.txt" })
        let visibleA = NSRange(location: 0, length: 10)
        let offscreenB = NSRange(location: 50, length: 10)
        store.loadContinuousEntries(
            visibleRange: visibleA,
            fileRanges: [
                unstagedA.id: visibleA,
                unstagedB.id: offscreenB,
            ])

        let loadDeadline = Date().addingTimeInterval(2)
        while store.continuousLoaded[unstagedA.id] == nil, Date() < loadDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard case .ready(let first) = store.continuousLoaded[unstagedA.id] else {
            return XCTFail("应先展开 a.txt，实际是 \(String(describing: store.continuousLoaded[unstagedA.id]))")
        }
        XCTAssertEqual(first.hunks.count, 2)
        XCTAssertTrue(first.hunks.flatMap(\.lines).contains(where: { $0.text == "FIRST" }))
        XCTAssertNil(store.continuousLoaded[unstagedB.id], "视口外不得 load")

        let hunk = try XCTUnwrap(first.hunks.first)
        let file = try XCTUnwrap(store.fileStatuses.first { $0.path == "a.txt" })
        await store.stage(hunk: hunk, file: file, stagedSide: false)

        guard case .ready(let second) = store.continuousLoaded[unstagedA.id] else {
            return XCTFail("可见文件应就地换成新 diff，实际是 \(String(describing: store.continuousLoaded[unstagedA.id]))")
        }
        XCTAssertFalse(second.hunks.flatMap(\.lines).contains(where: { $0.text == "FIRST" }),
                       "未暂存侧不应再含已暂存的 hunk")
        XCTAssertTrue(second.hunks.flatMap(\.lines).contains(where: { $0.text == "SECOND" }))
        XCTAssertNil(store.continuousLoaded[unstagedB.id], "不得为刷新而强制 load 视口外文件")
    }

    func testFullRefreshDropsContinuousLoadedBeforeCancelCanRace() async throws {
        let url = try makeRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("a\n", to: "a.txt", in: url)
        try write("b\n", to: "b.txt", in: url)
        try runGit(["add", "-A"], in: url)
        try runGit(["commit", "-m", "initial"], in: url)
        try write("a\nA\n", to: "a.txt", in: url)
        try write("b\nB\n", to: "b.txt", in: url)

        let store = makeStore()
        store.usesContinuousDiff = true
        await store.addRepository(at: url)

        let unstagedA = try XCTUnwrap(store.continuousPlan.first { $0.id == "u:a.txt" })
        let unstagedB = try XCTUnwrap(store.continuousPlan.first { $0.id == "u:b.txt" })
        let visible = NSRange(location: 0, length: 20)
        store.loadContinuousEntries(
            visibleRange: visible,
            fileRanges: [
                unstagedA.id: NSRange(location: 0, length: 10),
                unstagedB.id: NSRange(location: 10, length: 10),
            ])

        let loadDeadline = Date().addingTimeInterval(2)
        while store.continuousLoaded[unstagedA.id] == nil
                || store.continuousLoaded[unstagedB.id] == nil,
              Date() < loadDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(store.continuousLoaded[unstagedA.id])
        XCTAssertNotNil(store.continuousLoaded[unstagedB.id])

        let fullRefresh = Task { await store.refreshFileList(invalidateAllCachedDiffs: true) }
        var spins = 0
        while !store.isLoadingFileList, spins < 10_000 {
            await Task.yield()
            spins += 1
        }
        XCTAssertTrue(store.isLoadingFileList, "应观察到全量刷新已启动")
        XCTAssertTrue(store.continuousLoaded.isEmpty,
                      "全量失效必须在 cancel/spawn 之前丢掉连续滚动缓存")
        await fullRefresh.value
    }

    func testInitDoesNotDeleteAPIKeyWhenKeychainGetFails() {
        let keychain = RecordingKeychain()
        keychain.values["api-key"] = "sk-secret"
        keychain.getError = KeychainError.unexpectedStatus(errSecAuthFailed)
        _ = makeStore(keychain: keychain)
        XCTAssertTrue(keychain.deleted.isEmpty, "读取失败不得删除 Keychain 中的密钥")
        XCTAssertEqual(keychain.values["api-key"], "sk-secret")
    }

    func testSelectReplacesFileSelectionSet() async throws {
        let url = try makeRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("a\n", to: "a.txt", in: url)
        try runGit(["add", "-A"], in: url)
        try runGit(["commit", "-m", "initial"], in: url)
        try write("a\n", to: "new-a.txt", in: url)
        try write("b\n", to: "new-b.txt", in: url)

        let store = makeStore()
        await store.addRepository(at: url)
        let first = try XCTUnwrap(store.fileStatuses.first { $0.path == "new-a.txt" })
        let second = try XCTUnwrap(store.fileStatuses.first { $0.path == "new-b.txt" })
        await store.select(file: first, staged: false)
        XCTAssertEqual(store.selectedFileIDs, ["u:new-a.txt"])

        await store.toggleFileInSelection(second, staged: false)
        XCTAssertEqual(store.selectedFileIDs, ["u:new-a.txt", "u:new-b.txt"])
        XCTAssertEqual(store.selectedFile?.path, "new-a.txt")

        await store.select(file: second, staged: false)
        XCTAssertEqual(store.selectedFileIDs, ["u:new-b.txt"])
        XCTAssertEqual(store.selectedFile?.path, "new-b.txt")
    }

    func testDeleteUntrackedRemovesEveryListedFile() async throws {
        let url = try makeRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("tracked\n", to: "tracked.txt", in: url)
        try runGit(["add", "-A"], in: url)
        try runGit(["commit", "-m", "initial"], in: url)
        try write("a\n", to: "new-a.txt", in: url)
        try write("b\n", to: "new-b.txt", in: url)

        let store = makeStore()
        await store.addRepository(at: url)
        let first = try XCTUnwrap(store.fileStatuses.first { $0.path == "new-a.txt" })
        let second = try XCTUnwrap(store.fileStatuses.first { $0.path == "new-b.txt" })
        await store.deleteUntracked(files: [first, second])

        XCTAssertFalse(store.fileStatuses.contains { $0.path == "new-a.txt" })
        XCTAssertFalse(store.fileStatuses.contains { $0.path == "new-b.txt" })
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("tracked.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("new-a.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("new-b.txt").path))
    }

    func testClearingAPIKeyAfterInitDeletesKeychainItem() {
        let keychain = RecordingKeychain()
        keychain.values["api-key"] = "sk-secret"
        let store = makeStore(keychain: keychain)
        XCTAssertEqual(store.explainAPIKey, "sk-secret")
        store.explainAPIKey = ""
        XCTAssertEqual(keychain.deleted, ["api-key"])
    }

    func testEnablingContinuousDiffTurnsOffBlame() {
        let store = makeStore()
        store.showsBlame = true
        store.usesContinuousDiff = true
        XCTAssertTrue(store.usesContinuousDiff)
        XCTAssertFalse(store.showsBlame)
        store.usesContinuousDiff = false
        XCTAssertFalse(store.showsBlame, "退出连续滚动不得自动打开 blame")
    }

    func testBlameCannotBeEnabledDuringContinuousDiff() {
        let store = makeStore()
        store.usesContinuousDiff = true
        store.showsBlame = true
        XCTAssertFalse(store.showsBlame)
    }

    func testRestoringContinuousDiffTurnsOffPersistedBlame() throws {
        let stateURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sift-state-\(UUID().uuidString)/state.json")
        try PersistedStateStore(fileURL: stateURL).save(
            PersistedState(usesContinuousDiff: true, showsBlame: true))
        let store = RepoStore(
            stateStore: PersistedStateStore(fileURL: stateURL),
            keychain: MemoryKeychain())
        XCTAssertTrue(store.usesContinuousDiff)
        XCTAssertFalse(store.showsBlame)
    }
}

private final class RecordingKeychain: KeychainStore, @unchecked Sendable {
    var values: [String: String] = [:]
    var deleted: [String] = []
    var getError: Error?

    func get(_ account: String) throws -> String? {
        if let getError { throw getError }
        return values[account]
    }

    func set(_ value: String, account: String) throws {
        values[account] = value
    }

    func delete(_ account: String) throws {
        deleted.append(account)
        values.removeValue(forKey: account)
    }
}
