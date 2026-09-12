import AppKit
import Foundation
import Observation
import GitKit
import DiffEngine

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

    public struct DiffDocument: @unchecked Sendable {
        public let text: NSAttributedString
        public let splitRight: NSAttributedString?
        public let hunkHeaders: [DiffHunkHeader]

        public init(text: NSAttributedString,
                    splitRight: NSAttributedString? = nil,
                    hunkHeaders: [DiffHunkHeader]) {
            self.text = text
            self.splitRight = splitRight
            self.hunkHeaders = hunkHeaders
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

    /// 当前选中 worktree 所属的仓库。侧边栏「移除」用这个，避免按路径再扫一遍。
    public var selectedRepository: RepositoryEntry? {
        guard let selected = selectedWorktree else { return nil }
        return repositories.first { entry in
            entry.worktrees.contains { $0.path == selected.path }
        }
    }

    private let engine = DiffEngine()
    private let stateStore: PersistedStateStore
    private var watcher: FileSystemWatcher?

    /// 在途任务句柄。切换选择时取消旧任务——这是"切换即取消"约束的落点。
    private var fileListTask: Task<Void, Never>?
    private var diffTask: Task<Void, Never>?

    public init(stateStore: PersistedStateStore = PersistedStateStore()) {
        self.stateStore = stateStore
        let loaded = stateStore.load()
        self.usesTreeView = loaded.usesTreeView
        self.usesSplitDiff = loaded.usesSplitDiff
        self.appearance = loaded.appearance
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
            setLoadedDiff(nil)
            watcher = nil
        }
        persist()
    }

    // MARK: - 选择

    public func select(worktree: Worktree) async {
        guard selectedWorktree != worktree else { return }
        // 切换 worktree：取消旧的所有在途工作。
        fileListTask?.cancel()
        diffTask?.cancel()

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
        diffTask?.cancel()
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

    // MARK: - 刷新

    public func refreshFileList(invalidateAllCachedDiffs: Bool = true) async {
        await refreshWorktreeLists()
        guard let worktree = selectedWorktree else { return }
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

    public func stage(hunk: Hunk) async {
        guard let file = selectedFile else { return }
        let kind = patchKind(for: file)
        await mutate(path: file.path) {
            try await $0.stage(hunk: hunk, path: file.path,
                               originalPath: file.originalPath, kind: kind)
        }
    }

    public func unstage(hunk: Hunk) async {
        guard let file = selectedFile else { return }
        let kind = patchKind(for: file)
        await mutate(path: file.path) {
            try await $0.unstage(hunk: hunk, path: file.path,
                                 originalPath: file.originalPath, kind: kind)
        }
    }

    public func discard(hunk: Hunk) async {
        guard let file = selectedFile else { return }
        let kind = patchKind(for: file)
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
            await refreshFileList(invalidateAllCachedDiffs: false)
        } catch {
            errorMessage = "无法完成操作：\(error)"
        }
    }

    private func patchKind(for file: FileStatus) -> PatchFileKind {
        if file.isUntracked { return .added }
        if selectedFileIsStaged {
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
        return nil
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

    private func persist() {
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
            appearance: appearance)
        try? stateStore.save(state)
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
        setLoadedDiff(nil)
        watcher = nil
        persist()
    }
}
