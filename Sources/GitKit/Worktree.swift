import Foundation

public struct Worktree: Sendable, Equatable, Identifiable, Hashable {
    public let path: URL
    /// 完整的 commit SHA，裸仓库为 nil。
    public let head: String?
    /// 短分支名（已去掉 refs/heads/ 前缀）。游离头指针或裸仓库为 nil。
    public let branch: String?
    public let isBare: Bool
    public let isDetached: Bool
    public let isLocked: Bool
    /// `git worktree list` 输出的第一条永远是主工作树。
    public let isMain: Bool

    public var id: URL { path }

    /// 侧栏 `LazyVStack` 里的行身份。必须和仓库行错开：主工作树的
    /// `path` 等于仓库 `root`，共用 URL 当 id 时当前分支会渲染成空行。
    public var sidebarRowID: String { "wt:\(path.path)" }

    public init(path: URL, head: String?, branch: String?,
                isBare: Bool, isDetached: Bool, isLocked: Bool, isMain: Bool) {
        self.path = path
        self.head = head
        self.branch = branch
        self.isBare = isBare
        self.isDetached = isDetached
        self.isLocked = isLocked
        self.isMain = isMain
    }

    /// 侧边栏中显示的名字：优先分支名，其次短 SHA，最后目录名。
    public var displayName: String {
        if let branch { return branch }
        if let head { return String(head.prefix(7)) }
        return path.lastPathComponent
    }
}
