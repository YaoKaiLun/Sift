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
    public private(set) var repositories: [RepositoryEntry] = []
    public private(set) var selectedWorktree: Worktree?
    public private(set) var fileStatuses: [FileStatus] = []
    /// 文件路径到 +/− 行数的映射。未跟踪文件不在其中。
    public private(set) var lineStats: [String: LineStats] = [:]
    public private(set) var selectedFile: FileStatus?
    public private(set) var selectedFileIsStaged = false
    public private(set) var loadedDiff: LoadedDiff?
    public private(set) var isLoadingFileList = false
    public var errorMessage: String?

    public var usesTreeView: Bool {
        didSet { persist() }
    }

    private let engine = DiffEngine()
    private let stateStore: PersistedStateStore
    private var watcher: FileSystemWatcher?

    /// 在途任务句柄。切换选择时取消旧任务——这是"切换即取消"约束的落点。
    private var fileListTask: Task<Void, Never>?
    private var diffTask: Task<Void, Never>?

    public init(stateStore: PersistedStateStore = PersistedStateStore()) {
        self.stateStore = stateStore
        self.usesTreeView = stateStore.load().usesTreeView
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
           !repositories.contains(where: { $0.worktrees.contains(selected) }) {
            selectedWorktree = nil
            fileStatuses = []
            selectedFile = nil
            loadedDiff = nil
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
        loadedDiff = nil
        fileStatuses = []
        persist()

        startWatching(worktree)
        await refreshFileList()
    }

    public func select(file: FileStatus, staged: Bool) async {
        diffTask?.cancel()
        selectedFile = file
        selectedFileIsStaged = staged
        loadedDiff = nil

        guard let worktree = selectedWorktree else { return }
        let repository = GitRepository(root: worktree.path)
        let engine = self.engine

        diffTask = Task { [weak self] in
            do {
                let diff = try await engine.load(status: file, staged: staged, from: repository)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.selectedFile == file else { return }
                    self.loadedDiff = diff
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
        guard let file = selectedFile, let worktree = selectedWorktree else { return }
        let repository = GitRepository(root: worktree.path)
        do {
            loadedDiff = try await engine.loadIgnoringCollapse(
                status: file, staged: selectedFileIsStaged, from: repository)
        } catch {
            errorMessage = "无法加载 diff：\(error)"
        }
    }

    // MARK: - 刷新

    public func refreshFileList() async {
        guard let worktree = selectedWorktree else { return }
        fileListTask?.cancel()
        isLoadingFileList = true

        let repository = GitRepository(root: worktree.path)
        let engine = self.engine

        fileListTask = Task { [weak self] in
            do {
                await engine.invalidate(worktreePath: worktree.path)
                // status 与 numstat 并发发起——两者互不依赖，串行等待是白白浪费预算。
                async let statusResult = repository.status()
                async let statsResult = repository.lineStats()
                let statuses = try await statusResult
                let stats = try await statsResult
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.selectedWorktree == worktree else { return }
                    self.fileStatuses = statuses
                    self.lineStats = stats
                    self.isLoadingFileList = false
                    // 之前选中的文件如果还在，重新加载它的 diff。
                    if let selected = self.selectedFile,
                       !statuses.contains(where: { $0.path == selected.path }) {
                        self.selectedFile = nil
                        self.loadedDiff = nil
                    }
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

    public func restore() async {
        let state = stateStore.load()
        for bookmark in state.repositoryBookmarks {
            var isStale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark,
                                     options: .withSecurityScope,
                                     relativeTo: nil,
                                     bookmarkDataIsStale: &isStale),
                  !isStale else { continue }
            _ = url.startAccessingSecurityScopedResource()
            await addRepository(at: url)
        }
        if let path = state.selectedWorktreePath {
            let target = URL(fileURLWithPath: path)
            let worktree = repositories.flatMap(\.worktrees).first { $0.path == target }
            if let worktree { await select(worktree: worktree) }
        }
    }

    // MARK: - 私有

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
            usesTreeView: usesTreeView)
        try? stateStore.save(state)
    }
}
