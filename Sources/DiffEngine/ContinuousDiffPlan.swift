import Foundation
import GitKit

/// 连续滚动里一份文件的占位头。同一路径可因已暂存/未暂存出现两次。
public struct ContinuousDiffEntry: Sendable, Equatable, Identifiable {
    public let status: FileStatus
    public let staged: Bool
    public let added: Int?
    public let deleted: Int?

    public init(status: FileStatus, staged: Bool, added: Int?, deleted: Int?) {
        self.status = status
        self.staged = staged
        self.added = added
        self.deleted = deleted
    }

    /// 与中栏行 id 对齐：`s:path` / `u:path`。
    public var id: String { "\(staged ? "s" : "u"):\(status.path)" }

    /// 占位头文案：`path  +N −M`。缺统计或二进制时省略数字。
    public var headerTitle: String {
        var parts: [String] = []
        if let added, added > 0 { parts.append("+\(added)") }
        if let deleted, deleted > 0 { parts.append("−\(deleted)") }
        if parts.isEmpty { return status.path }
        return "\(status.path)  \(parts.joined(separator: " "))"
    }
}

/// 纯函数：只根据 status / numstat 拼占位列表，不碰 git、不调用 DiffEngine.load。
public enum ContinuousDiffPlan {
    public static func build(
        statuses: [FileStatus],
        stagedStats: [String: LineStats],
        unstagedStats: [String: LineStats]
    ) -> [ContinuousDiffEntry] {
        var entries: [ContinuousDiffEntry] = []
        entries.append(contentsOf: statuses.filter(\.hasStagedChanges).map { status in
            entry(status: status, staged: true, stats: stagedStats[status.path])
        })
        entries.append(contentsOf: statuses.filter(\.hasUnstagedChanges).map { status in
            entry(status: status, staged: false, stats: unstagedStats[status.path])
        })
        entries.append(contentsOf: statuses.filter(\.isUntracked).map { status in
            entry(status: status, staged: false, stats: unstagedStats[status.path])
        })
        return entries
    }

    /// 与可见字符范围相交、且尚未展开的占位头。视口外的文件不会出现在结果里。
    public static func entriesNeedingLoad(
        _ entries: [ContinuousDiffEntry],
        ranges: [String: NSRange],
        visibleRange: NSRange,
        alreadyLoaded: Set<String>
    ) -> [ContinuousDiffEntry] {
        entries.filter { entry in
            guard !alreadyLoaded.contains(entry.id),
                  let range = ranges[entry.id],
                  range.length > 0 else { return false }
            return rangesIntersect(range, visibleRange)
        }
    }

    private static func entry(status: FileStatus, staged: Bool, stats: LineStats?) -> ContinuousDiffEntry {
        let numbers: (Int?, Int?)
        if let stats, !stats.isBinary {
            numbers = (stats.added, stats.deleted)
        } else {
            numbers = (nil, nil)
        }
        return ContinuousDiffEntry(
            status: status, staged: staged, added: numbers.0, deleted: numbers.1)
    }

    private static func rangesIntersect(_ a: NSRange, _ b: NSRange) -> Bool {
        NSIntersectionRange(a, b).length > 0
            || (b.length == 0 && NSLocationInRange(b.location, a))
            || (a.length == 0 && NSLocationInRange(a.location, b))
    }
}
