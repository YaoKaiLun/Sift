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
        public let path: String
        public let added: Int?
        public let deleted: Int?
        public let changeKind: FileChangeKind

        public init(id: String, range: NSRange, isPlaceholder: Bool, isCollapsed: Bool,
                    path: String = "", added: Int? = nil, deleted: Int? = nil,
                    changeKind: FileChangeKind = .unmodified) {
            self.id = id
            self.range = range
            self.isPlaceholder = isPlaceholder
            self.isCollapsed = isCollapsed
            self.path = path
            self.added = added
            self.deleted = deleted
            self.changeKind = changeKind
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
    /// 中栏多选。id 形如 `s:path` / `u:path`，与连续滚动 file id 相同。
    public private(set) var selectedFileIDs: Set<String> = []
    public private(set) var selectionAnchorID: String?
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

    public var hidesFilteredFiles: Bool {
        didSet {
            persist()
            applyVisibleFileFilter()
        }
    }

    public var fileFilterPatterns: [String] {
        didSet {
            persist()
            applyVisibleFileFilter()
        }
    }

    /// 当前选中 worktree 上未推送到上游的 commit。无上游时为空。
    public private(set) var unpushedCommits: [CommitInfo] = []
    public private(set) var hasUpstream = false
    public private(set) var selectedCommit: CommitInfo?
    public private(set) var commitParentSHA: String?
    /// 工作区改动文件数，供侧栏徽章使用；阅读 commit 时不改这个数。
    public private(set) var workingTreeFileCount = 0

    public var visibleFileStatuses: [FileStatus] {
        FileFilter.hiding(fileStatuses, path: \.path,
                          enabled: hidesFilteredFiles,
                          patterns: fileFilterPatterns)
    }

    public var usesContinuousDiff: Bool {
        didSet {
            if usesContinuousDiff, showsBlame {
                showsBlame = false
            }
            persist()
        }
    }

    public var showsBlame: Bool {
        didSet {
            if usesContinuousDiff, showsBlame {
                showsBlame = false
                return
            }
            persist()
        }
    }

    /// 只走 Keychain，不写 state.json。
    public var explainAPIKey: String {
        didSet {
            guard writesExplainAPIKey else { return }
            saveExplainAPIKey()
        }
    }

    public var showsExplainPanel = false
    /// 侧栏设置钮 / 未配置点「解释」时弹出模型配置。
    public var showsExplainSettings = false
    /// 请求已发出、第一个 token 还没到：面板应显示「思考中...」。
    public var isExplainThinking: Bool {
        explainTask != nil && explainStreamingText.isEmpty && explainError == nil
    }
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
    /// init 读 Keychain 时关掉写入，避免 get 失败被当成空密钥而 delete。
    private var writesExplainAPIKey = false

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
        self.hidesFilteredFiles = loaded.hidesFilteredFiles
        self.fileFilterPatterns = loaded.fileFilterPatterns
        self.usesContinuousDiff = loaded.usesContinuousDiff
        self.showsBlame = loaded.usesContinuousDiff ? false : loaded.showsBlame
        do {
            self.explainAPIKey = try keychain.get("api-key") ?? ""
        } catch {
            self.explainAPIKey = ""
        }
        self.writesExplainAPIKey = true
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
            selectedFileIDs = []
            selectionAnchorID = nil
            cancelContinuousExpands()
            continuousPlan = []
            continuousLoaded = [:]
            continuousRevealID = nil
            setLoadedDiff(nil)
            watcher = nil
            resetUnpushedList()
            resetExplainConversation(keepingPanel: false)
        }
        persist()
    }

    // MARK: - 选择

    public func select(worktree: Worktree) async {
        if selectedWorktree == worktree {
            if selectedCommit != nil {
                await clearSelectedCommit()
            }
            return
        }
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
        selectedFileIDs = []
        selectionAnchorID = nil
        setLoadedDiff(nil)
        fileStatuses = []
        stagedLineStats = [:]
        unstagedLineStats = [:]
        workingTreeFileCount = 0
        resetUnpushedList()
        persist()

        startWatching(worktree)
        await refreshFileList()
    }

    public static func fileSelectionID(path: String, staged: Bool, commitSHA: String? = nil) -> String {
        if let commitSHA {
            return "c:\(commitSHA):\(path)"
        }
        return "\(staged ? "s" : "u"):\(path)"
    }

    public static func parseFileSelectionID(_ id: String) -> (path: String, staged: Bool, commitSHA: String?)? {
        if id.hasPrefix("c:") {
            let rest = id.dropFirst(2)
            guard let colon = rest.firstIndex(of: ":") else { return nil }
            let sha = String(rest[..<colon])
            let path = String(rest[rest.index(after: colon)...])
            guard !sha.isEmpty, !path.isEmpty else { return nil }
            return (path, false, sha)
        }
        if id.hasPrefix("s:") {
            return (String(id.dropFirst(2)), true, nil)
        }
        if id.hasPrefix("u:") {
            return (String(id.dropFirst(2)), false, nil)
        }
        return nil
    }

    public func isFileSelected(_ file: FileStatus, staged: Bool) -> Bool {
        selectedFileIDs.contains(currentFileSelectionID(path: file.path, staged: staged))
    }

    private func currentFileSelectionID(path: String, staged: Bool) -> String {
        Self.fileSelectionID(path: path, staged: staged, commitSHA: selectedCommit?.sha)
    }

    public func select(file: FileStatus, staged: Bool, replacingSelection: Bool = true) async {
        if replacingSelection {
            let id = currentFileSelectionID(path: file.path, staged: staged)
            selectedFileIDs = [id]
            selectionAnchorID = id
        }
        let commitSHA = selectedCommit?.sha
        let parent = commitParentSHA
        let side: DiffSide = commitSHA.map { .commit(sha: $0) } ?? .workingTree(staged: staged)
        if usesContinuousDiff {
            let fileChanged = selectedFile?.path != file.path
                || selectedFileIsStaged != staged
                || selectedCommit?.sha != commitSHA
            if fileChanged {
                resetExplainConversation(keepingPanel: true)
            }
            selectedFile = file
            selectedFileIsStaged = staged
            continuousRevealID = currentFileSelectionID(path: file.path, staged: staged)
            return
        }

        diffTask?.cancel()
        let fileChanged = selectedFile?.path != file.path || selectedFileIsStaged != staged
        if fileChanged {
            resetExplainConversation(keepingPanel: true)
        }
        selectedFile = file
        selectedFileIsStaged = staged
        if fileChanged {
            setLoadedDiff(nil)
        }

        guard let worktree = selectedWorktree else { return }
        let repository = GitRepository(root: worktree.path)
        let engine = self.engine

        diffTask = Task { [weak self] in
            do {
                let diff = try await engine.load(
                    status: file, side: side, from: repository, parent: parent)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self,
                          self.selectedFile == file,
                          self.selectedFileIsStaged == staged,
                          self.selectedCommit?.sha == commitSHA else { return }
                    self.setLoadedDiff(diff)
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.errorMessage = "无法加载 diff：\(error)" }
            }
        }
        await diffTask?.value
    }

    public func select(commit: CommitInfo) async {
        guard selectedWorktree != nil else { return }
        guard selectedCommit?.sha != commit.sha else { return }
        selectedCommit = commit
        commitParentSHA = nil
        selectedFile = nil
        selectedFileIDs = []
        selectionAnchorID = nil
        setLoadedDiff(nil)
        cancelContinuousExpands()
        continuousPlan = []
        continuousLoaded = [:]
        continuousRevealID = nil
        continuousPreservesScroll = false
        resetExplainConversation(keepingPanel: true)
        await refreshFileList()
    }

    public func clearSelectedCommit() async {
        guard selectedCommit != nil else { return }
        clearCommitReadingState()
        selectedFile = nil
        selectedFileIDs = []
        selectionAnchorID = nil
        setLoadedDiff(nil)
        cancelContinuousExpands()
        continuousPlan = []
        continuousLoaded = [:]
        continuousRevealID = nil
        continuousPreservesScroll = false
        resetExplainConversation(keepingPanel: true)
        await refreshFileList()
    }

    public func selectAdjacentFile(delta: Int, extending: Bool, orderedIDs: [String]) async {
        guard !orderedIDs.isEmpty else { return }
        let currentID: String?
        if let file = selectedFile {
            currentID = currentFileSelectionID(path: file.path, staged: selectedFileIsStaged)
        } else {
            currentID = selectionAnchorID
        }

        let targetID: String
        if let currentID, let index = orderedIDs.firstIndex(of: currentID) {
            let next = index + delta
            guard orderedIDs.indices.contains(next) else { return }
            targetID = orderedIDs[next]
        } else {
            targetID = delta >= 0 ? orderedIDs[0] : orderedIDs[orderedIDs.count - 1]
        }

        guard let parts = Self.parseFileSelectionID(targetID),
              let file = fileStatuses.first(where: { $0.path == parts.path }) else { return }
        if extending {
            await selectFileRange(orderedIDs: orderedIDs, to: targetID, file: file, staged: parts.staged)
        } else {
            await select(file: file, staged: parts.staged)
        }
    }

    public func toggleFileInSelection(_ file: FileStatus, staged: Bool) async {
        let id = currentFileSelectionID(path: file.path, staged: staged)
        if selectedFileIDs.contains(id) {
            guard selectedFileIDs.count > 1 else { return }
            selectedFileIDs.remove(id)
            if selectedFile?.path == file.path, selectedFileIsStaged == staged {
                await promoteAnotherSelectedFile()
            }
            return
        }
        if selectedFileIDs.isEmpty, let selected = selectedFile {
            selectedFileIDs.insert(currentFileSelectionID(path: selected.path, staged: selectedFileIsStaged))
        }
        selectedFileIDs.insert(id)
        selectionAnchorID = id
    }

    public func selectFileRange(orderedIDs: [String], to id: String,
                                 file: FileStatus, staged: Bool) async {
        let anchor = selectionAnchorID ?? id
        guard let i = orderedIDs.firstIndex(of: anchor),
              let j = orderedIDs.firstIndex(of: id) else {
            await select(file: file, staged: staged)
            return
        }
        let lower = min(i, j)
        let upper = max(i, j)
        selectedFileIDs = Set(orderedIDs[lower...upper])
        await select(file: file, staged: staged, replacingSelection: false)
    }

    private func promoteAnotherSelectedFile() async {
        guard let nextID = selectedFileIDs.sorted().first else {
            selectedFile = nil
            selectionAnchorID = nil
            setLoadedDiff(nil)
            return
        }
        guard let parts = Self.parseFileSelectionID(nextID),
              let next = fileStatuses.first(where: { $0.path == parts.path }) else { return }
        let staged = parts.staged
        selectionAnchorID = nextID
        await select(file: next, staged: staged, replacingSelection: false)
    }

    /// 用户在折叠占位条上点了"仍要查看"。
    public func expandCollapsedDiff() async {
        if usesContinuousDiff, let file = selectedFile {
            expandContinuousCollapsed(id: currentFileSelectionID(path: file.path, staged: selectedFileIsStaged))
            return
        }
        diffTask?.cancel()
        guard let file = selectedFile, let worktree = selectedWorktree else { return }
        let staged = selectedFileIsStaged
        let commitSHA = selectedCommit?.sha
        let parent = commitParentSHA
        let side: DiffSide = commitSHA.map { .commit(sha: $0) } ?? .workingTree(staged: staged)
        let repository = GitRepository(root: worktree.path)
        let engine = self.engine

        diffTask = Task { [weak self] in
            do {
                let diff = try await engine.loadIgnoringCollapse(
                    status: file, side: side, from: repository, parent: parent)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self,
                          self.selectedFile == file,
                          self.selectedFileIsStaged == staged,
                          self.selectedCommit?.sha == commitSHA,
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

    /// 选区或 hunk 上点「解释」。未配置只弹出模型配置，不打开右侧面板。
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
        showsExplainSettings = true
    }

    public func closeExplainSettings() {
        showsExplainSettings = false
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

                let unpushed = try await repository.unpushedCommits()
                guard !Task.isCancelled else { return }

                let commitSHA: String? = await MainActor.run {
                    guard let self, self.selectedWorktree == worktree else { return nil }
                    self.hasUpstream = unpushed != nil
                    self.unpushedCommits = unpushed ?? []
                    if let sha = self.selectedCommit?.sha,
                       !self.unpushedCommits.contains(where: { $0.sha == sha }) {
                        self.abandonSelectedCommit()
                    }
                    return self.selectedCommit?.sha
                }

                if let sha = commitSHA {
                    async let filesResult = repository.commitFiles(sha: sha)
                    let parent = await repository.commitParent(sha: sha)
                    let files = try await filesResult
                    guard !Task.isCancelled else { return }

                    let reload = await MainActor.run { () -> (file: FileStatus, staged: Bool)? in
                        guard let self, self.selectedWorktree == worktree,
                              self.selectedCommit?.sha == sha else { return nil }
                        self.commitParentSHA = parent
                        self.fileStatuses = files.files
                        self.stagedLineStats = files.lineStats
                        self.unstagedLineStats = [:]
                        self.isLoadingFileList = false
                        if self.usesContinuousDiff {
                            if invalidateAllCachedDiffs {
                                self.invalidateContinuousLoaded()
                            }
                            self.reconcileContinuousSelection(with: self.visibleFileStatuses)
                            self.rebuildContinuousPlan(preservesScroll: self.diffDocument != nil)
                            return nil
                        }
                        return self.reconcileSelection(with: self.visibleFileStatuses)
                    }

                    guard !Task.isCancelled else { return }
                    if let reload {
                        await self?.select(file: reload.file, staged: reload.staged)
                    }
                    return
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
                    self.workingTreeFileCount = statuses.count
                    self.isLoadingFileList = false
                    if self.usesContinuousDiff {
                        if invalidateAllCachedDiffs {
                            self.invalidateContinuousLoaded()
                        }
                        self.reconcileContinuousSelection(with: self.visibleFileStatuses)
                        self.rebuildContinuousPlan(preservesScroll: self.diffDocument != nil)
                        return nil
                    }
                    return self.reconcileSelection(with: self.visibleFileStatuses)
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
        await stage(files: [file])
    }

    public func stage(files: [FileStatus]) async {
        let paths = files.map(\.path)
        guard !paths.isEmpty else { return }
        await mutate(paths: paths) { try await $0.stage(paths: paths) }
    }

    public func unstage(file: FileStatus) async {
        await unstage(files: [file])
    }

    public func unstage(files: [FileStatus]) async {
        let paths = files.map(\.path)
        guard !paths.isEmpty else { return }
        await mutate(paths: paths) { try await $0.unstage(paths: paths) }
    }

    public func deleteUntracked(file: FileStatus) async {
        await deleteUntracked(files: [file])
    }

    public func deleteUntracked(files: [FileStatus]) async {
        let targets = files.filter(\.isUntracked)
        guard !targets.isEmpty else {
            if let tracked = files.first(where: { !$0.isUntracked }) {
                errorMessage = "无法删除已跟踪文件：\(tracked.path)"
            }
            return
        }
        await mutate(paths: targets.map(\.path)) { repo in
            for file in targets {
                try await repo.deleteUntracked(path: file.path)
            }
        }
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
        if diff == nil {
            diffDocument = nil
        }
        diffEpoch += 1
    }

    /// 写进行中再点按钮直接忽略。成功后只失效该路径两侧缓存，再立刻刷新列表。
    private func mutate(path: String, _ body: (GitRepository) async throws -> Void) async {
        await mutate(paths: [path], body)
    }

    private func mutate(paths: [String], _ body: (GitRepository) async throws -> Void) async {
        guard selectedCommit == nil else { return }
        guard !isMutating, let worktree = selectedWorktree else { return }
        isMutating = true
        defer { isMutating = false }
        let repository = GitRepository(root: worktree.path)
        do {
            try await body(repository)
            for path in Set(paths) {
                await engine.invalidate(worktreePath: worktree.path, filePath: path)
            }
            await refreshFileList(invalidateAllCachedDiffs: false)
            await reloadMutatedContinuous(paths: Set(paths))
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

    /// 选中的路径+侧还在就返回需要重载的文件；否则改选多选里还在的文件，或清掉选择。
    private func reconcileSelection(with statuses: [FileStatus]) -> (file: FileStatus, staged: Bool)? {
        pruneFileSelection(with: statuses)
        if let selected = selectedFile,
           let current = statuses.first(where: { $0.path == selected.path }),
           sideStillExists(current, staged: selectedFileIsStaged) {
            selectedFile = current
            return (current, selectedFileIsStaged)
        }
        if let next = remainingSelectedFile(in: statuses) {
            selectedFile = next.file
            selectedFileIsStaged = next.staged
            selectionAnchorID = currentFileSelectionID(path: next.file.path, staged: next.staged)
            setLoadedDiff(nil)
            return next
        }
        selectedFile = nil
        selectedFileIDs = []
        selectionAnchorID = nil
        setLoadedDiff(nil)
        resetExplainConversation(keepingPanel: true)
        return nil
    }

    private func reconcileContinuousSelection(with statuses: [FileStatus]) {
        pruneFileSelection(with: statuses)
        if let selected = selectedFile,
           let current = statuses.first(where: { $0.path == selected.path }),
           sideStillExists(current, staged: selectedFileIsStaged) {
            selectedFile = current
            return
        }
        if let next = remainingSelectedFile(in: statuses) {
            selectedFile = next.file
            selectedFileIsStaged = next.staged
            selectionAnchorID = currentFileSelectionID(path: next.file.path, staged: next.staged)
            return
        }
        selectedFile = nil
        selectedFileIDs = []
        selectionAnchorID = nil
        continuousRevealID = nil
        resetExplainConversation(keepingPanel: true)
    }

    private func remainingSelectedFile(in statuses: [FileStatus]) -> (file: FileStatus, staged: Bool)? {
        for id in selectedFileIDs.sorted() {
            guard let parts = Self.parseFileSelectionID(id) else { continue }
            if let current = statuses.first(where: { $0.path == parts.path }),
               sideStillExists(current, staged: parts.staged) {
                return (current, parts.staged)
            }
        }
        return nil
    }

    private func pruneFileSelection(with statuses: [FileStatus]) {
        selectedFileIDs = selectedFileIDs.filter { id in
            guard let parts = Self.parseFileSelectionID(id) else { return false }
            guard let status = statuses.first(where: { $0.path == parts.path }) else { return false }
            return sideStillExists(status, staged: parts.staged)
        }
        if let anchor = selectionAnchorID, !selectedFileIDs.contains(anchor) {
            selectionAnchorID = selectedFileIDs.sorted().first
        }
    }

    private func rebuildContinuousPlan(preservesScroll: Bool = false) {
        if let commit = selectedCommit {
            continuousPlan = ContinuousDiffPlan.buildCommit(
                statuses: visibleFileStatuses,
                sha: commit.sha,
                stats: stagedLineStats)
        } else {
            continuousPlan = ContinuousDiffPlan.build(
                statuses: visibleFileStatuses,
                stagedStats: stagedLineStats,
                unstagedStats: unstagedLineStats)
        }
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

    /// 写完之后只重载已经展开的文件，视口外继续懒加载。
    /// 旧 diff 留到新的到达，避免连续滚动先闪成占位头。
    private func reloadMutatedContinuous(paths: Set<String>) async {
        guard usesContinuousDiff, let worktree = selectedWorktree else { return }
        let entries = paths.flatMap { path in
            [true, false].compactMap { staged -> ContinuousDiffEntry? in
                let id = Self.fileSelectionID(path: path, staged: staged)
                guard continuousLoaded[id] != nil else { return nil }
                return continuousPlan.first(where: { $0.id == id })
            }
        }
        guard !entries.isEmpty else { return }
        let repository = GitRepository(root: worktree.path)
        let engine = self.engine
        var fresh: [(id: String, diff: LoadedDiff)] = []
        for entry in entries {
            continuousExpandTasks[entry.id]?.cancel()
            continuousExpandTasks[entry.id] = nil
            do {
                let diff = try await engine.load(
                    status: entry.status, staged: entry.staged, from: repository)
                fresh.append((entry.id, diff))
            } catch {
                errorMessage = "无法加载 diff：\(error)"
            }
        }
        for item in fresh where continuousPlan.contains(where: { $0.id == item.id }) {
            continuousLoaded[item.id] = item.diff
        }
        continuousPreservesScroll = true
        diffEpoch += 1
    }

    private func startContinuousExpand(_ entry: ContinuousDiffEntry, ignoringCollapse: Bool) {
        if !ignoringCollapse, continuousLoaded[entry.id] != nil { return }
        guard continuousExpandTasks[entry.id] == nil else { return }
        guard let worktree = selectedWorktree else { return }
        let repository = GitRepository(root: worktree.path)
        let engine = self.engine
        let worktreePath = worktree.path
        let side: DiffSide
        let parent: String?
        if let sha = entry.commitSHA {
            side = .commit(sha: sha)
            parent = commitParentSHA
        } else {
            side = .workingTree(staged: entry.staged)
            parent = nil
        }
        continuousExpandTasks[entry.id] = Task { [weak self] in
            do {
                let diff = ignoringCollapse
                    ? try await engine.loadIgnoringCollapse(
                        status: entry.status, side: side, from: repository, parent: parent)
                    : try await engine.load(
                        status: entry.status, side: side, from: repository, parent: parent)
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

    private func sideStillExists(_ status: FileStatus, staged: Bool) -> Bool {
        if selectedCommit != nil { return true }
        if staged { return status.hasStagedChanges }
        return status.hasUnstagedChanges || status.isUntracked
    }

    private func clearCommitReadingState() {
        selectedCommit = nil
        commitParentSHA = nil
    }

    private func resetUnpushedList() {
        unpushedCommits = []
        hasUpstream = false
        clearCommitReadingState()
    }

    /// 当前 SHA 已不在未推送列表里：清掉 commit 选择，随后走工作区刷新。
    private func abandonSelectedCommit() {
        selectedCommit = nil
        commitParentSHA = nil
        selectedFile = nil
        selectedFileIDs = []
        selectionAnchorID = nil
        setLoadedDiff(nil)
        cancelContinuousExpands()
        continuousPlan = []
        continuousLoaded = [:]
        continuousRevealID = nil
        continuousPreservesScroll = false
        resetExplainConversation(keepingPanel: true)
    }

    private func applyVisibleFileFilter() {
        pruneFileSelection(with: visibleFileStatuses)
        if let selected = selectedFile,
           !visibleFileStatuses.contains(where: { $0.path == selected.path }) {
            selectedFile = nil
            selectedFileIDs = []
            selectionAnchorID = nil
            setLoadedDiff(nil)
            continuousRevealID = nil
        }
        if usesContinuousDiff {
            rebuildContinuousPlan(preservesScroll: false)
        }
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
            showsBlame: showsBlame,
            hidesFilteredFiles: hidesFilteredFiles,
            fileFilterPatterns: fileFilterPatterns)
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
            let id = selectedFile.map {
                currentFileSelectionID(path: $0.path, staged: selectedFileIsStaged)
            }
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
        workingTreeFileCount = 0
        selectedFile = nil
        selectedFileIDs = []
        selectionAnchorID = nil
        cancelContinuousExpands()
        continuousPlan = []
        continuousLoaded = [:]
        continuousRevealID = nil
        setLoadedDiff(nil)
        watcher = nil
        resetUnpushedList()
        resetExplainConversation(keepingPanel: false)
        persist()
    }
}
