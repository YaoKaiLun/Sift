import Foundation
import GitKit

public struct DiffCacheKey: Sendable, Hashable {
    public let worktreePath: URL
    public let filePath: String
    public let staged: Bool

    public init(worktreePath: URL, filePath: String, staged: Bool) {
        self.worktreePath = worktreePath
        self.filePath = filePath
        self.staged = staged
    }
}

public enum LoadedDiff: Sendable, Equatable {
    case ready(FileDiff)
    /// 生成文件或超大文件，默认不加载内容。
    case collapsed(reason: GeneratedFileReason, path: String)

    /// 估算内存占用，用于缓存容量控制。按每行约 80 字节粗算即可，
    /// 精确值不重要，重要的是大文件占更多份额。
    var estimatedBytes: Int {
        switch self {
        case .collapsed: 128
        case .ready(let diff): diff.hunks.reduce(0) { $0 + $1.lines.count * 80 } + 256
        }
    }
}

/// diff 结果的 LRU 缓存。默认上限 50 条或 50MB，先到者为准。
public actor DiffCache {
    private struct Entry {
        let value: LoadedDiff
        let bytes: Int
    }

    private var entries: [DiffCacheKey: Entry] = [:]
    /// 访问顺序，末尾是最近使用的。
    private var accessOrder: [DiffCacheKey] = []
    private var totalBytes = 0

    private let maximumEntries: Int
    private let maximumBytes: Int

    public init(maximumEntries: Int = 50, maximumBytes: Int = 50_000_000) {
        self.maximumEntries = maximumEntries
        self.maximumBytes = maximumBytes
    }

    public var count: Int { entries.count }

    public func value(for key: DiffCacheKey) -> LoadedDiff? {
        guard let entry = entries[key] else { return nil }
        touch(key)
        return entry.value
    }

    public func insert(_ value: LoadedDiff, for key: DiffCacheKey) {
        if let existing = entries[key] {
            totalBytes -= existing.bytes
        }
        let bytes = value.estimatedBytes
        entries[key] = Entry(value: value, bytes: bytes)
        totalBytes += bytes
        touch(key)
        evictIfNeeded()
    }

    public func removeAll() {
        entries.removeAll()
        accessOrder.removeAll()
        totalBytes = 0
    }

    /// 某个 worktree 的文件发生变化时，只清该 worktree 的缓存。
    public func removeAll(inWorktree path: URL) {
        let doomed = entries.keys.filter { $0.worktreePath == path }
        for key in doomed { remove(key) }
    }

    /// 写操作后只清该路径 staged 与 unstaged 两侧，其它文件的缓存留下。
    public func remove(inWorktree path: URL, filePath: String) {
        let doomed = entries.keys.filter { $0.worktreePath == path && $0.filePath == filePath }
        for key in doomed { remove(key) }
    }

    private func touch(_ key: DiffCacheKey) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }

    private func remove(_ key: DiffCacheKey) {
        if let entry = entries.removeValue(forKey: key) {
            totalBytes -= entry.bytes
        }
        accessOrder.removeAll { $0 == key }
    }

    private func evictIfNeeded() {
        while (entries.count > maximumEntries || totalBytes > maximumBytes),
              let oldest = accessOrder.first {
            remove(oldest)
        }
    }
}
