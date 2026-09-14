import XCTest
import AIClient
@testable import RepoStore

final class PersistedStateTests: XCTestCase {
    private func temporaryFile() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sift-state-\(UUID().uuidString)/state.json")
    }

    func testLoadReturnsEmptyStateWhenFileMissing() {
        let store = PersistedStateStore(fileURL: temporaryFile())
        let state = store.load()
        XCTAssertTrue(state.repositoryBookmarks.isEmpty)
        XCTAssertNil(state.selectedWorktreePath)
    }

    func testRoundTrip() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = PersistedStateStore(fileURL: url)
        let original = PersistedState(
            repositoryBookmarks: [Data([1, 2, 3])],
            selectedWorktreePath: "/repos/main",
            usesTreeView: true,
            appearance: .dark)
        try store.save(original)

        let loaded = PersistedStateStore(fileURL: url).load()
        XCTAssertEqual(loaded.repositoryBookmarks, [Data([1, 2, 3])])
        XCTAssertEqual(loaded.selectedWorktreePath, "/repos/main")
        XCTAssertTrue(loaded.usesTreeView)
        XCTAssertEqual(loaded.appearance, .dark)
    }

    func testSaveCreatesIntermediateDirectories() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = PersistedStateStore(fileURL: url)
        try store.save(PersistedState(repositoryBookmarks: [], selectedWorktreePath: nil, usesTreeView: false))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    /// 磁盘上的 JSON 损坏时必须优雅降级，不能让应用启动不了。
    func testCorruptFileFallsBackToEmptyState() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("this is not json".utf8).write(to: url)

        let state = PersistedStateStore(fileURL: url).load()
        XCTAssertTrue(state.repositoryBookmarks.isEmpty)
    }

    /// 旧版 state.json 没有 appearance 字段时，必须落到跟随系统，不能解码失败。
    func testMissingAppearanceDefaultsToSystem() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"repositoryBookmarks":[],"usesTreeView":true}"#.utf8).write(to: url)

        let state = PersistedStateStore(fileURL: url).load()
        XCTAssertTrue(state.usesTreeView)
        XCTAssertEqual(state.appearance, .system)
    }

    /// 旧版 state.json 没有 usesSplitDiff 字段时，必须落到统一视图。
    func testMissingSplitDiffDefaultsToFalse() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"repositoryBookmarks":[],"usesTreeView":true}"#.utf8).write(to: url)

        let state = PersistedStateStore(fileURL: url).load()
        XCTAssertFalse(state.usesSplitDiff)
    }

    /// 旧版 state.json 没有浏览模式字段时，栏宽与开关必须落到缺省。
    func testMissingBrowseFieldsUseDefaults() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"repositoryBookmarks":[],"usesTreeView":true}"#.utf8).write(to: url)

        let state = PersistedStateStore(fileURL: url).load()
        XCTAssertTrue(state.usesTreeView)
        XCTAssertEqual(state.sidebarWidth, 220)
        XCTAssertEqual(state.fileListWidth, 300)
        XCTAssertFalse(state.usesContinuousDiff)
        XCTAssertFalse(state.showsBlame)
    }

    /// 旧版 state.json 没有过滤字段时，必须落到不隐藏 + 缺省规则。
    func testMissingFilterFieldsUseDefaults() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"repositoryBookmarks":[],"usesTreeView":true}"#.utf8).write(to: url)

        let state = PersistedStateStore(fileURL: url).load()
        XCTAssertFalse(state.hidesFilteredFiles)
        XCTAssertEqual(state.fileFilterPatterns, PersistedState.defaultFileFilterPatterns)
    }

    /// 旧版 state.json 没有解释设置时，Base URL 与模型名必须落到空字符串。
    func testMissingExplainFieldsDefaultToEmptyString() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"repositoryBookmarks":[],"usesTreeView":true}"#.utf8).write(to: url)

        let state = PersistedStateStore(fileURL: url).load()
        XCTAssertEqual(state.explainBaseURL, "")
        XCTAssertEqual(state.explainModel, "")
    }

    /// 未配置时点「解释」只弹出设置，不打开右侧解释面板，也不发请求。
    @MainActor
    func testStartExplainWhenUnconfiguredOpensSettingsNotPanel() {
        let stateURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sift-state-\(UUID().uuidString)/state.json")
        let store = RepoStore(
            stateStore: PersistedStateStore(fileURL: stateURL),
            keychain: MemoryKeychain())
        XCTAssertFalse(store.isExplainConfigured)

        store.startExplain(selectedText: "let x = 1", surroundingText: "let x = 1")

        XCTAssertTrue(store.showsExplainSettings, "未配置应弹出模型配置")
        XCTAssertFalse(store.showsExplainPanel, "未配置不得打开右侧解释面板")
        XCTAssertNil(store.explainError)
        XCTAssertNil(store.explainTask, "未配置不得发请求")
    }

    /// 流还没吐出第一个 token 时必须是思考中，面板才能立刻显示占位而不是空白。
    @MainActor
    func testStartExplainIsThinkingUntilFirstChunk() async {
        let provider = GatedExplainProvider()
        let store = makeExplainStore(provider: provider)

        store.startExplain(selectedText: "let x = 1", surroundingText: "let x = 1")
        await provider.waitUntilStarted(count: 1)

        XCTAssertTrue(store.isExplainThinking)
        XCTAssertTrue(store.explainStreamingText.isEmpty)

        provider.completeNext(["第一段"])
        await store.explainTask?.value

        XCTAssertFalse(store.isExplainThinking)
        XCTAssertEqual(store.explainHistory.last?.text, "第一段")
    }

    /// 被替换的解释流取消后不得清空新 stream 的句柄，否则后续切文件无法取消。
    @MainActor
    func testStaleExplainCancelDoesNotNilReplacementTask() async throws {
        let provider = GatedExplainProvider()
        let store = makeExplainStore(provider: provider)

        store.startExplain(selectedText: "old", surroundingText: "old")
        await provider.waitUntilStarted(count: 1)
        let first = try XCTUnwrap(store.explainTask)

        store.startExplain(selectedText: "new", surroundingText: "new")
        await provider.waitUntilStarted(count: 2)
        XCTAssertNotNil(store.explainTask)

        await first.value
        XCTAssertNotNil(store.explainTask, "过期取消不得清空新 stream 的句柄")
    }

    /// 旧流完成后的 MainActor 回写不得把助手回复写进已经重置的新对话。
    @MainActor
    func testStaleExplainCompletionDoesNotAppendToNewConversation() async throws {
        let provider = GatedExplainProvider()
        let store = makeExplainStore(provider: provider)

        store.startExplain(selectedText: "old", surroundingText: "old")
        await provider.waitUntilStarted(count: 1)
        let first = try XCTUnwrap(store.explainTask)

        provider.completeNext(["STALE"])
        // 堵住主线程，让后台把完成回调排进队列，但还不能执行。
        Self.stallMainActor(0.05)
        store.startExplain(selectedText: "new", surroundingText: "new")
        await first.value

        XCTAssertFalse(
            store.explainHistory.contains { $0.text.contains("STALE") },
            "过期完成不得把助手回复写进新对话")
        XCTAssertFalse(
            store.explainStreamingText.contains("STALE"),
            "过期完成不得把组装文本漏进新对话")
    }

    nonisolated private static func stallMainActor(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    @MainActor
    private func makeExplainStore(provider: GatedExplainProvider) -> RepoStore {
        let stateURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sift-state-\(UUID().uuidString)/state.json")
        let store = RepoStore(
            stateStore: PersistedStateStore(fileURL: stateURL),
            keychain: MemoryKeychain())
        store.explainProviderOverride = provider
        store.explainBaseURL = "https://example.com/v1"
        store.explainModel = "test-model"
        store.explainAPIKey = "sk-test"
        return store
    }
}

/// 每个 `stream()` 卡住，直到 `completeNext` 或消费者取消。
private final class GatedExplainProvider: ExplainProvider, @unchecked Sendable {
    private struct Item {
        let id: UUID
        let continuation: CheckedContinuation<[String], any Error>
    }

    private let lock = NSLock()
    private var items: [Item] = []
    private var started = 0

    func stream(_ request: ExplainRequest) -> AsyncThrowingStream<String, Error> {
        let id = UUID()
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let chunks = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String], any Error>) in
                        self.lock.lock()
                        self.items.append(Item(id: id, continuation: cont))
                        self.started += 1
                        self.lock.unlock()
                    }
                    for chunk in chunks {
                        try Task.checkCancellation()
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                self.cancelItem(id: id)
            }
        }
    }

    func waitUntilStarted(count: Int) async {
        for _ in 0..<200 {
            if lock.withLock({ started >= count }) { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("解释流未在超时内启动（期望 \(count)，实际 \(lock.withLock { started })）")
    }

    func completeNext(_ chunks: [String]) {
        lock.lock()
        let item = items.removeFirst()
        lock.unlock()
        item.continuation.resume(returning: chunks)
    }

    private func cancelItem(id: UUID) {
        lock.lock()
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            lock.unlock()
            return
        }
        let item = items.remove(at: index)
        lock.unlock()
        item.continuation.resume(throwing: CancellationError())
    }
}
