import AppKit
import Foundation
import Observation
import GitKit
import DiffEngine
import AIClient

public struct RepositoryEntry: Identifiable, Sendable {
    public let root: URL
    public let name: String
    public var worktrees: [Worktree]
    public var id: URL { root }
}

/// UI 的唯一数据源。所有 git 工作都通过 async 方法发起，
/// 结果回到主线程后才写入被观察的属性。
@MainActor
@Observable
public final class RepoStore {
    /// 与 SiftUI.DiffDocument 同形。SiftUI 依赖本模块，不能反向 import，因此在此镜像一份供 store 持有。
    public struct DiffHunkHeader: Sendable, Equatable {
        public let id: String
        public let range: NSRange

        public init(id: String, range: NSRange) {
            self.id = id
            self.range = range
        }
    }

    public struct DiffFileHeader: Sendable, Equatable {
        public let id: String
        public let range: NSRange
        public let isPlaceholder: Bool
        public let isCollapsed: Bool

        public init(id: String, range: NSRange, isPlaceholder: Bool, isCollapsed: Bool) {
            self.id = id
            self.range = range
            self.isPlaceholder = isPlaceholder
            self.isCollapsed = isCollapsed
        }
    }

    public struct DiffDocument: @unchecked Sendable {
        public let text: NSAttributedString
        public let splitRight: NSAttributedString?
        public let hunkHeaders: [DiffHunkHeader]
        public let fileHeaders: [DiffFileHeader]

        public init(text: NSAttributedString,
                    splitRight: NSAttributedString? = nil,
                    hunkHeaders: [DiffHunkHeader],
                    fileHeaders: [DiffFileHeader] = []) {
            self.text = text
            self.splitRight = splitRight
            self.hunkHeaders = hunkHeaders
            self.fileHeaders = fileHeaders
        }
    }

    public private(set) var repositories: [RepositoryEntry] = []
    public private(set) var selectedWorktree: Worktree?
    public private(set) var fileStatuses: [FileStatus] = []
    /// 暂存区一侧的 +/−，只给「已暂存」分组用。
    public private(set) var stagedLineStats: [String: LineStats] = [:]
    /// 工作区一侧的 +/−，只给「未暂存」分组用。
    public private(set) var unstagedLineStats: [String: LineStats] = [:]
    public private(set) var selectedFile: FileStatus?
    public private(set) var selectedFileIsStaged = false
    public private(set) var loadedDiff: LoadedDiff?
    /// 已在后台构建好的 diff 文档。DiffPane.body 只负责交给 DiffTextView。
    public private(set) var diffDocument: DiffDocument?
    /// DiffPane 用它触发后台构建；每次 `loadedDiff` 变化都递增。
    public private(set) var diffEpoch = 0
    /// 连续滚动占位列表。只来自 status / numstat，不含 git diff。
    public private(set) var continuousPlan: [ContinuousDiffEntry] = []
    /// 已按视口展开的文件。key 与 `ContinuousDiffEntry.id` 相同。
    public private(set) var continuousLoaded: [String: LoadedDiff] = [:]
    /// 中栏点击后，DiffPane 滚到该文件头。
    public private(set) var continuousRevealID: String?
    /// 展开后重建文档时保住滚动位置。
    public private(set) var continuousPreservesScroll = false
    public private(set) var isLoadingFileList = false
    /// 同一时刻只允许一个在途写；为 true 时写方法立即 return。
    public private(set) var isMutating = false
    public var errorMessage: String?

    public var usesTreeView: Bool {
        didSet { persist() }
    }

    public var usesSplitDiff: Bool {
        didSet { persist() }
    }

    public var appearance: AppearancePreference {
        didSet { persist() }
    }

    public var explainBaseURL: String {
        didSet { persist() }
    }

    public var explainModel: String {
        didSet { persist() }
    }

    public var sidebarWidth: Double

    public var fileListWidth: Double

    public var usesContinuousDiff: Bool {
        didSet { persist() }
    }

    public var showsBlame: Bool {
        didSet { persist() }
    }

    /// 只走 Keychain，不写 state.json。
    public var explainAPIKey: String {
        didSet { saveExplainAPIKey() }
    }

    public var showsExplainPanel = false
    public var explainDraft = ""
    public private(set) var explainHistory: [ExplainTurn] = []
    public private(set) var explainStreamingText = ""
    /// 解释失败只出现在面板里，不占用全局 `errorMessage`。
    public private(set) var explainError: String?
    public private(set) var explainSelection = NSRange(location: 0, length: 0)

    /// 当前选中 worktree 所属的仓库。侧边栏「移除」用这个，避免按路径再扫一遍。
    public var selectedRepository: RepositoryEntry? {
        guard let selected = selectedWorktree else { return nil }
        return repositories.first { entry in
            entry.worktrees.contains { $0.path == selected.path }
        }
    }

    private let engine = DiffEngine()
    private let stateStore: PersistedStateStore
    private let keychain: KeychainStore
    private var watcher: FileSystemWatcher?

    /// 在途任务句柄。切换选择时取消旧任务——这是"切换即取消"约束的落点。
    private var fileListTask: Task<Void, Never>?
    private var diffTask: Task<Void, Never>?
    private var continuousExpandTasks: [String: Task<Void, Never>] = [:]
    private(set) var explainTask: Task<Void, Never>?
    /// 测试可注入；生产路径走 `OpenAICompatibleProvider`。
    var explainProviderOverride: (any ExplainProvider)?
    /// 解释流世代。过期的完成/取消回写必须丢掉，不能动当前句柄。
    private var explainGeneration: UInt64 = 0
    private var lastExplainSelectedText = ""
    private var lastExplainSurroundingText = ""
    private var lastExplainFileDiff = ""

    public init(stateStore: PersistedStateStore = PersistedStateStore(),
                keychain: KeychainStore = SystemKeychain()) {
        self.stateStore = stateStore
        self.keychain = keychain
        let loaded = stateStore.load()
        self.usesTreeView = loaded.usesTreeView
        self.usesSplitDiff = loaded.usesSplitDiff
        self.appearance = loaded.appearance
        self.explainBaseURL = loaded.explainBaseURL
        self.explainModel = loaded.explainModel
        self.sidebarWidth = loaded.sidebarWidth
        self.fileListWidth = loaded.fileListWidth
        self.usesContinuousDiff = loaded.usesContinuousDiff
        self.showsBlame = loaded.showsBlame
        self.explainAPIKey = keychain.get("api-key") ?? ""
    }

    // MARK: - 仓库管理

    public func addRepository(at url: URL) async {
        do {
            let root = try await GitRepository.discoverRoot(at: url, runner: GitRunner())
            guard !repositories.contains(where: { $0.root == root }) else { return }
            let worktrees = try await GitRepository(root: root).worktrees()
            repositories.append(RepositoryEntry(
                root: root, name: root.lastPathComponent, worktrees: worktrees))
            persist()
            if selectedWorktree == nil, let first = worktrees.first {
                await select(worktree: first)
            }
        } catch {
            errorMessage = "无法添加仓库：\(error)"
        }
    }

    public func removeRepository(root: URL) {
        repositories.removeAll { $0.root == root }
        if let selected = selectedWorktree,
           !repositories.contains(where: { $0.worktrees.contains { $0.path == selected.path } }) {
            selectedWorktree = nil
            fileStatuses = []
            stagedLineStats = [:]
            unstagedLineStats = [:]
            selectedFile = nil
            cancelContinuousExpands()
            continuousPlan = []
            continuousLoaded = [:]
            continuousRevealID = nil
            setLoadedDiff(nil)
            watcher = nil
            resetExplainConversation(keepingPanel: false)
        }
        persist()
    }

    // MARK: - 选择

    public func select(worktree: Worktree) async {
        guard selectedWorktree != worktree else { return }
        // 切换 worktree：取消旧的所有在途工作。
        fileListTask?.cancel()
        diffTask?.cancel()
        cancelContinuousExpands()
        continuousPlan = []
        continuousLoaded = [:]
        continuousRevealID = nil
        continuousPreservesScroll = false
        resetExplainConversation(keepingPanel: false)

        selectedWorktree = worktree
        selectedFile = nil
        setLoadedDiff(nil)
        fileStatuses = []
        stagedLineStats = [:]
        unstagedLineStats = [:]
        persist()

        startWatching(worktree)
        await refreshFileList()
    }

    public func select(file: FileStatus, staged: Bool) async {
        if usesContinuousDiff {
            let fileChanged = selectedFile?.path != file.path || selectedFileIsStaged != staged
            if fileChanged {
                resetExplainConversation(keepingPanel: true)
            }
            selectedFile = file
            selectedFileIsStaged = staged
            continuousRevealID = "\(staged ? "s" : "u"):\(file.path)"
            return
        }

        diffTask?.cancel()
        let fileChanged = selectedFile?.path != file.path || selectedFileIsStaged != staged
        if fileChanged {
            resetExplainConversation(keepingPanel: true)
        }
        selectedFile = file
        selectedFileIsStaged = staged
        setLoadedDiff(nil)

        guard let worktree = selectedWorktree else { return }
        let repository = GitRepository(root: worktree.path)
        let engine = self.engine

        diffTask = Task { [weak self] in
            do {
                let diff = try await engine.load(status: file, staged: staged, from: repository)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self,
                          self.selectedFile == file,
                          self.selectedFileIsStaged == staged else { return }
                    self.setLoadedDiff(diff)
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.errorMessage = "无法加载 diff：\(error)" }
            }
        }
        await diffTask?.value
    }

    /// 用户在折叠占位条上点了"仍要查看"。
    public func expandCollapsedDiff() async {
        if usesContinuousDiff, let file = selectedFile {
            expandContinuousCollapsed(id: "\(selectedFileIsStaged ? "s" : "u"):\(file.path)")
            return
        }
        diffTask?.cancel()
        guard let file = selectedFile, let worktree = selectedWorktree else { return }
        let staged = selectedFileIsStaged
        let repository = GitRepository(root: worktree.path)
        let engine = self.engine

        diffTask = Task { [weak self] in
            do {
                let diff = try await engine.loadIgnoringCollapse(
                    status: file, staged: staged, from: repository)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self,
                          self.selectedFile == file,
                          self.selectedFileIsStaged == staged,
                          self.selectedWorktree == worktree else { return }
                    self.setLoadedDiff(diff)
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.errorMessage = "无法加载 diff：\(error)" }
            }
        }
        await diffTask?.value
    }

    /// DiffPane 在后台构建完成后回写。epoch 对不上说明选择已经变了。
    public func updateDiffDocument(_ document: DiffDocument?, epoch: Int) {
        guard epoch == diffEpoch else { return }
        diffDocument = document
    }

    /// 单文件 / 连续滚动切换。连续模式只建占位计划，不预先 load。
    public func handleBrowseModeChange() async {
        if usesContinuousDiff {
            guard continuousPlan.isEmpty else { return }
            diffTask?.cancel()
            loadedDiff = nil
            diffDocument = nil
            rebuildContinuousPlan(preservesScroll: false)
        } else {
            guard !continuousPlan.isEmpty || !continuousLoaded.isEmpty else { return }
            cancelContinuousExpands()
            continuousPlan = []
            continuousLoaded = [:]
            continuousRevealID = nil
            continuousPreservesScroll = false
            if let file = selectedFile {
                await select(file: file, staged: selectedFileIsStaged)
            } else {
                setLoadedDiff(nil)
            }
        }
    }

    /// DiffTextView 报告可见字符范围后，只展开与视口相交的占位头。
    public func loadContinuousEntries(visibleRange: NSRange, fileRanges: [String: NSRange]) {
        guard usesContinuousDiff else { return }
        let needed = ContinuousDiffPlan.entriesNeedingLoad(
            continuousPlan,
            ranges: fileRanges,
            visibleRange: visibleRange,
            alreadyLoaded: Set(continuousLoaded.keys))
        for entry in needed {
            startContinuousExpand(entry, ignoringCollapse: false)
        }
    }

    public func expandContinuousCollapsed(id: String) {
        guard let entry = continuousPlan.first(where: { $0.id == id }) else { return }
        continuousExpandTasks[id]?.cancel()
        continuousExpandTasks[id] = nil
        startContinuousExpand(entry, ignoringCollapse: true)
    }

    public func consumeContinuousReveal() {
        continuousRevealID = nil
    }

    public func hunk(matching id: String) -> Hunk? {
        if usesContinuousDiff {
            return resolveContinuousHunk(id)?.hunk
        }
        guard case .ready(let diff) = loadedDiff else { return nil }
        return diff.hunks.first { $0.id == id }
    }

    public func fileForHunk(id: String) -> (file: FileStatus, staged: Bool)? {
        if usesContinuousDiff, let resolved = resolveContinuousHunk(id) {
            return (resolved.entry.status, resolved.entry.staged)
        }
        guard let file = selectedFile else { return nil }
        return (file, selectedFileIsStaged)
    }

    public func hunkIsStaged(_ id: String) -> Bool? {
        guard let info = fileForHunk(id: id), !info.file.isUntracked else { return nil }
        return info.staged
    }

    // MARK: - 解释

    public var isExplainConfigured: Bool {
        !explainBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !explainModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !explainAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func updateExplainSelection(_ range: NSRange) {
        let previous = explainSelection
        explainSelection = range
        guard showsExplainPanel, range.length > 0, !NSEqualRanges(previous, range) else { return }
        resetExplainConversation(keepingPanel: true)
    }

    /// 选区上点「解释这段」。未配置则打开设置，不发请求。
    public func startExplain(selectedText: String, surroundingText: String) {
        guard isExplainConfigured else {
            openExplainSettings()
            return
        }
        resetExplainConversation(keepingPanel: true)
        lastExplainSelectedText = selectedText
        lastExplainSurroundingText = surroundingText
        lastExplainFileDiff = textualFileDiff()
        showsExplainPanel = true
        startExplainStream()
    }

    public func submitExplainDraft() {
        let text = explainDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard isExplainConfigured else {
            openExplainSettings()
            return
        }
        guard !lastExplainSelectedText.isEmpty else { return }
        explainDraft = ""
        explainHistory.append(ExplainTurn(role: .user, text: text))
        showsExplainPanel = true
        startExplainStream()
    }

    public func closeExplainPanel() {
        showsExplainPanel = false
        explainGeneration += 1
        explainTask?.cancel()
        explainTask = nil
    }

    public func openExplainSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    // MARK: - 刷新

    public func refreshFileList(invalidateAllCachedDiffs: Bool = true) async {
        await refreshWorktreeLists()
        guard let worktree = selectedWorktree else { return }
        if invalidateAllCachedDiffs {
            invalidateContinuousLoaded()
        }
        fileListTask?.cancel()
        isLoadingFileList = true

        let repository = GitRepository(root: worktree.path)
        let engine = self.engine

        fileListTask = Task { [weak self] in
            do {
                if invalidateAllCachedDiffs {
                    await engine.invalidate(worktreePath: worktree.path)
                }
                // status 与 numstat 并发发起——两者互不依赖，串行等待是白白浪费预算。
                async let statusResult = repository.status()
                async let statsResult = repository.lineStats()
                let statuses = try await statusResult
                let stats = try await statsResult
                guard !Task.isCancelled else { return }

                let reload = await MainActor.run { () -> (file: FileStatus, staged: Bool)? in
                    guard let self, self.selectedWorktree == worktree else { return nil }
                    self.fileStatuses = statuses
                    self.stagedLineStats = stats.staged
                    self.unstagedLineStats = stats.unstaged
                    self.isLoadingFileList = false
                    if self.usesContinuousDiff {
                        if invalidateAllCachedDiffs {
                            self.invalidateContinuousLoaded()
                        }
                        self.reconcileContinuousSelection(with: statuses)
                        self.rebuildContinuousPlan(preservesScroll: self.diffDocument != nil)
                        return nil
                    }
                    return self.reconcileSelection(with: statuses)
                }

                guard !Task.isCancelled else { return }
                if let reload {
                    await self?.select(file: reload.file, staged: reload.staged)
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.isLoadingFileList = false
                    self?.errorMessage = "无法读取文件状态：\(error)"
                }
            }
        }
        await fileListTask?.value
    }

    // MARK: - 写操作

    public func stageSelectedFile() async {
        guard let file = selectedFile else { return }
        await stage(file: file)
    }

    public func unstageSelectedFile() async {
        guard let file = selectedFile else { return }
        await unstage(file: file)
    }

    public func stage(file: FileStatus) async {
        await mutate(path: file.path) { try await $0.stage(path: file.path) }
    }

    public func unstage(file: FileStatus) async {
        await mutate(path: file.path) { try await $0.unstage(path: file.path) }
    }

    public func deleteUntracked(file: FileStatus) async {
        await mutate(path: file.path) { try await $0.deleteUntracked(path: file.path) }
    }

    public func stage(hunk: Hunk, file: FileStatus? = nil, stagedSide: Bool? = nil) async {
        guard let file = file ?? selectedFile else { return }
        let staged = stagedSide ?? selectedFileIsStaged
        let kind = patchKind(for: file, staged: staged)
        await mutate(path: file.path) {
            try await $0.stage(hunk: hunk, path: file.path,
                               originalPath: file.originalPath, kind: kind)
        }
    }

    public func unstage(hunk: Hunk, file: FileStatus? = nil, stagedSide: Bool? = nil) async {
        guard let file = file ?? selectedFile else { return }
        let staged = stagedSide ?? selectedFileIsStaged
        let kind = patchKind(for: file, staged: staged)
        await mutate(path: file.path) {
            try await $0.unstage(hunk: hunk, path: file.path,
                                 originalPath: file.originalPath, kind: kind)
        }
    }

    public func discard(hunk: Hunk, file: FileStatus? = nil, stagedSide: Bool? = nil) async {
        guard let file = file ?? selectedFile else { return }
        let staged = stagedSide ?? selectedFileIsStaged
        let kind = patchKind(for: file, staged: staged)
        await mutate(path: file.path) {
            try await $0.discard(hunk: hunk, path: file.path,
                                 originalPath: file.originalPath, kind: kind)
        }
    }

    public func restore() async {
        let state = stateStore.load()
        var needsBookmarkRewrite = false
        for bookmark in state.repositoryBookmarks {
            var isStale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark,
                                     options: .withSecurityScope,
                                     relativeTo: nil,
                                     bookmarkDataIsStale: &isStale)
            else { continue }
            // 书签过期但路径仍能解析时，照样拿安全作用域，并在后面重写书签。
            _ = url.startAccessingSecurityScopedResource()
            await addRepository(at: url)
            if isStale { needsBookmarkRewrite = true }
        }
        if needsBookmarkRewrite {
            persist()
        }
        if let path = state.selectedWorktreePath {
            let target = URL(fileURLWithPath: path)
            let worktree = repositories.flatMap(\.worktrees).first { $0.path == target }
            if let worktree { await select(worktree: worktree) }
        }
    }

    // MARK: - 私有

    private func setLoadedDiff(_ diff: LoadedDiff?) {
        loadedDiff = diff
        diffDocument = nil
        diffEpoch += 1
    }

    /// 写进行中再点按钮直接忽略。成功后只失效该路径两侧缓存，再立刻刷新列表。
    private func mutate(path: String, _ body: (GitRepository) async throws -> Void) async {
        guard !isMutating, let worktree = selectedWorktree else { return }
        isMutating = true
        defer { isMutating = false }
        let repository = GitRepository(root: worktree.path)
        do {
            try await body(repository)
            await engine.invalidate(worktreePath: worktree.path, filePath: path)
            invalidateContinuousLoaded(ids: ["s:\(path)", "u:\(path)"])
            await refreshFileList(invalidateAllCachedDiffs: false)
        } catch {
            errorMessage = "无法完成操作：\(error)"
        }
    }

    private func patchKind(for file: FileStatus, staged: Bool? = nil) -> PatchFileKind {
        let isStaged = staged ?? selectedFileIsStaged
        if file.isUntracked { return .added }
        if isStaged {
            if file.indexStatus == .added { return .added }
            if file.indexStatus == .deleted { return .deleted }
        } else {
            if file.worktreeStatus == .added { return .added }
            if file.worktreeStatus == .deleted { return .deleted }
        }
        return .modified
    }

    /// 选中的路径+侧还在就返回需要重载的文件；否则清掉选择。
    private func reconcileSelection(with statuses: [FileStatus]) -> (file: FileStatus, staged: Bool)? {
        guard let selected = selectedFile else { return nil }
        let staged = selectedFileIsStaged
        if let current = statuses.first(where: { $0.path == selected.path }),
           Self.sideStillExists(current, staged: staged) {
            selectedFile = current
            setLoadedDiff(nil)
            return (current, staged)
        }
        selectedFile = nil
        setLoadedDiff(nil)
        resetExplainConversation(keepingPanel: true)
        return nil
    }

    private func reconcileContinuousSelection(with statuses: [FileStatus]) {
        guard let selected = selectedFile else { return }
        let staged = selectedFileIsStaged
        if let current = statuses.first(where: { $0.path == selected.path }),
           Self.sideStillExists(current, staged: staged) {
            selectedFile = current
            return
        }
        selectedFile = nil
        continuousRevealID = nil
        resetExplainConversation(keepingPanel: true)
    }

    private func rebuildContinuousPlan(preservesScroll: Bool = false) {
        continuousPlan = ContinuousDiffPlan.build(
            statuses: fileStatuses,
            stagedStats: stagedLineStats,
            unstagedStats: unstagedLineStats)
        let ids = Set(continuousPlan.map(\.id))
        continuousLoaded = continuousLoaded.filter { ids.contains($0.key) }
        for (id, task) in continuousExpandTasks where !ids.contains(id) {
            task.cancel()
            continuousExpandTasks[id] = nil
        }
        continuousPreservesScroll = preservesScroll
        diffEpoch += 1
    }

    /// DiffEngine 失效后必须同步丢掉连续滚动的第二份缓存，否则
    /// `loadContinuousEntries` 会把仍在 map 里的 id 当成 `alreadyLoaded` 而跳过 git diff。
    private func invalidateContinuousLoaded(ids: Set<String>? = nil) {
        if let ids {
            for id in ids {
                continuousExpandTasks[id]?.cancel()
                continuousExpandTasks[id] = nil
                continuousLoaded.removeValue(forKey: id)
            }
        } else {
            cancelContinuousExpands()
            continuousLoaded = [:]
        }
    }

    private func cancelContinuousExpands() {
        for task in continuousExpandTasks.values { task.cancel() }
        continuousExpandTasks.removeAll()
    }

    private func startContinuousExpand(_ entry: ContinuousDiffEntry, ignoringCollapse: Bool) {
        if !ignoringCollapse, continuousLoaded[entry.id] != nil { return }
        guard continuousExpandTasks[entry.id] == nil else { return }
        guard let worktree = selectedWorktree else { return }
        let repository = GitRepository(root: worktree.path)
        let engine = self.engine
        let worktreePath = worktree.path
        continuousExpandTasks[entry.id] = Task { [weak self] in
            do {
                let diff = ignoringCollapse
                    ? try await engine.loadIgnoringCollapse(
                        status: entry.status, staged: entry.staged, from: repository)
                    : try await engine.load(
                        status: entry.status, staged: entry.staged, from: repository)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self,
                          !Task.isCancelled,
                          self.usesContinuousDiff,
                          self.selectedWorktree?.path == worktreePath,
                          self.continuousPlan.contains(where: { $0.id == entry.id }) else { return }
                    self.continuousLoaded[entry.id] = diff
                    self.continuousExpandTasks[entry.id] = nil
                    self.continuousPreservesScroll = true
                    self.diffEpoch += 1
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.continuousExpandTasks[entry.id] = nil
                    self?.errorMessage = "无法加载 diff：\(error)"
                }
            }
        }
    }

    private func resolveContinuousHunk(_ id: String) -> (entry: ContinuousDiffEntry, hunk: Hunk)? {
        guard let separator = id.lastIndex(of: ":") else { return nil }
        let fileID = String(id[..<separator])
        let hunkID = String(id[id.index(after: separator)...])
        guard let entry = continuousPlan.first(where: { $0.id == fileID }),
              case .ready(let diff) = continuousLoaded[fileID],
              let hunk = diff.hunks.first(where: { $0.id == hunkID }) else { return nil }
        return (entry, hunk)
    }

    private static func sideStillExists(_ status: FileStatus, staged: Bool) -> Bool {
        if staged { return status.hasStagedChanges }
        return status.hasUnstagedChanges || status.isUntracked
    }

    private func startWatching(_ worktree: Worktree) {
        watcher = FileSystemWatcher(path: worktree.path, debounce: .milliseconds(100)) { [weak self] in
            Task { @MainActor in await self?.refreshFileList() }
        }
    }

    public func persist() {
        let bookmarks = repositories.compactMap { entry in
            try? entry.root.bookmarkData(options: .withSecurityScope,
                                         includingResourceValuesForKeys: nil,
                                         relativeTo: nil)
        }
        let state = PersistedState(
            repositoryBookmarks: bookmarks,
            selectedWorktreePath: selectedWorktree?.path.path,
            usesTreeView: usesTreeView,
            usesSplitDiff: usesSplitDiff,
            appearance: appearance,
            explainBaseURL: explainBaseURL,
            explainModel: explainModel,
            sidebarWidth: sidebarWidth,
            fileListWidth: fileListWidth,
            usesContinuousDiff: usesContinuousDiff,
            showsBlame: showsBlame)
        try? stateStore.save(state)
    }

    private func saveExplainAPIKey() {
        let trimmed = explainAPIKey
        if trimmed.isEmpty {
            try? keychain.delete("api-key")
        } else {
            try? keychain.set(trimmed, account: "api-key")
        }
    }

    private func textualFileDiff() -> String {
        if usesContinuousDiff {
            let id = selectedFile.map { "\(selectedFileIsStaged ? "s" : "u"):\($0.path)" }
            if let id, case .ready(let diff) = continuousLoaded[id] {
                return diff.hunks.map(\.patchText).joined()
            }
            return ""
        }
        guard case .ready(let diff) = loadedDiff else { return "" }
        return diff.hunks.map(\.patchText).joined()
    }

    private func resetExplainConversation(keepingPanel: Bool) {
        explainGeneration += 1
        explainTask?.cancel()
        explainTask = nil
        explainHistory = []
        explainStreamingText = ""
        explainDraft = ""
        explainError = nil
        lastExplainSelectedText = ""
        lastExplainSurroundingText = ""
        lastExplainFileDiff = ""
        if !keepingPanel {
            showsExplainPanel = false
            explainSelection = NSRange(location: 0, length: 0)
        }
    }

    private func startExplainStream() {
        explainTask?.cancel()
        explainError = nil
        explainStreamingText = ""
        explainGeneration += 1
        let generation = explainGeneration

        let request = ExplainRequest(
            path: selectedFile?.path ?? "",
            selectedText: lastExplainSelectedText,
            surroundingText: lastExplainSurroundingText,
            fileDiff: lastExplainFileDiff,
            history: explainHistory)
        let provider: any ExplainProvider = explainProviderOverride ?? OpenAICompatibleProvider(
            baseURL: explainBaseURL,
            apiKey: explainAPIKey,
            model: explainModel)

        explainTask = Task.detached { [weak self] in
            var assembled = ""
            do {
                for try await chunk in provider.stream(request) {
                    try Task.checkCancellation()
                    assembled += chunk
                    await MainActor.run {
                        guard let self, self.explainGeneration == generation else { return }
                        self.explainStreamingText = assembled
                    }
                }
                await MainActor.run {
                    guard let self, self.explainGeneration == generation else { return }
                    if !assembled.isEmpty {
                        self.explainHistory.append(ExplainTurn(role: .assistant, text: assembled))
                    }
                    self.explainStreamingText = ""
                    self.explainTask = nil
                }
            } catch {
                if Self.isCancellation(error) {
                    await MainActor.run {
                        guard let self, self.explainGeneration == generation else { return }
                        self.explainTask = nil
                    }
                    return
                }
                await MainActor.run {
                    guard let self, self.explainGeneration == generation else { return }
                    self.explainError = Self.explainErrorMessage(error)
                    self.explainStreamingText = assembled
                    self.explainTask = nil
                }
            }
        }
    }

    nonisolated private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    nonisolated private static func explainErrorMessage(_ error: Error) -> String {
        if let explain = error as? ExplainError {
            switch explain {
            case .notConfigured:
                return "请先在设置中填写 Base URL、API 密钥和模型。"
            case .httpStatus(let code):
                return "请求失败（HTTP \(code)）。"
            }
        }
        if let urlError = error as? URLError {
            return "网络错误：\(urlError.localizedDescription)"
        }
        return "请求失败：\(error.localizedDescription)"
    }

    /// 刷新时重新跑 `git worktree list`。添加仓库时拍的快照不会跟着磁盘变。
    private func refreshWorktreeLists() async {
        var updated: [RepositoryEntry] = []
        updated.reserveCapacity(repositories.count)
        for entry in repositories {
            do {
                let worktrees = try await GitRepository(root: entry.root).worktrees()
                updated.append(RepositoryEntry(root: entry.root, name: entry.name, worktrees: worktrees))
            } catch {
                updated.append(entry)
            }
        }
        repositories = updated

        guard let selected = selectedWorktree else { return }
        let all = repositories.flatMap(\.worktrees)
        if let match = all.first(where: { $0.path == selected.path }) {
            selectedWorktree = match
            return
        }
        selectedWorktree = nil
        fileStatuses = []
        stagedLineStats = [:]
        unstagedLineStats = [:]
        selectedFile = nil
        cancelContinuousExpands()
        continuousPlan = []
        continuousLoaded = [:]
        continuousRevealID = nil
        setLoadedDiff(nil)
        watcher = nil
        resetExplainConversation(keepingPanel: false)
        persist()
    }
}
