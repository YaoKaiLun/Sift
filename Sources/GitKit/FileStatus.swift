import Foundation

public enum FileChangeKind: String, Sendable, Equatable {
    case unmodified
    case modified
    case added
    case deleted
    case renamed
    case copied
    case typeChanged
    case unmerged
    case untracked
}

public struct FileStatus: Sendable, Equatable, Identifiable, Hashable {
    /// 相对仓库根目录的路径。
    public let path: String
    /// 重命名或复制时的原路径，其余情况为 nil。
    public let originalPath: String?
    /// 暂存区一侧的状态（porcelain 的 X 位）。
    public let indexStatus: FileChangeKind
    /// 工作区一侧的状态（porcelain 的 Y 位）。
    public let worktreeStatus: FileChangeKind

    public var id: String { path }

    public init(path: String, originalPath: String?,
                indexStatus: FileChangeKind, worktreeStatus: FileChangeKind) {
        self.path = path
        self.originalPath = originalPath
        self.indexStatus = indexStatus
        self.worktreeStatus = worktreeStatus
    }

    public var isUntracked: Bool { indexStatus == .untracked }
    /// 有已暂存的改动，应出现在 Staged 分组。
    public var hasStagedChanges: Bool {
        !isUntracked && indexStatus != .unmodified
    }
    /// 有未暂存的改动（不含未跟踪），用于和已暂存对照。
    public var hasUnstagedChanges: Bool {
        !isUntracked && worktreeStatus != .unmodified
    }
    /// 工作区分组：未暂存改动和未跟踪文件放在一起，和 SourceTree 一样。
    public var hasWorkingTreeChanges: Bool {
        isUntracked || hasUnstagedChanges
    }
    /// 文件名，用于 UI 显示。
    public var fileName: String {
        String(path.split(separator: "/").last ?? "")
    }

    /// 按相对路径排序，不按增删/未跟踪分组。
    public static func pathOrder(_ lhs: FileStatus, _ rhs: FileStatus) -> Bool {
        lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
    }
}
