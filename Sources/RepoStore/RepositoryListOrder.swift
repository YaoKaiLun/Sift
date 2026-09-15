import Foundation

public struct RepositoryListItem: Equatable, Sendable {
    public var id: String
    public var isPinned: Bool

    public init(id: String, isPinned: Bool) {
        self.id = id
        self.isPinned = isPinned
    }
}

/// 侧栏仓库顺序：置顶组在前，未置顶组在后。纯函数，方便单测。
public enum RepositoryListOrder {
    /// `/var` 与 `/private/var` 这类符号链接必须当成同一仓库。
    public static func canonicalPath(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// 新仓库插在全部置顶之后、其余未置顶之前。
    public static func insertNew(id: String, into items: [RepositoryListItem]) -> [RepositoryListItem] {
        var result = items
        let index = result.firstIndex(where: { !$0.isPinned }) ?? result.count
        result.insert(RepositoryListItem(id: id, isPinned: false), at: index)
        return result
    }

    public static func setPinned(_ pinned: Bool, id: String, in items: [RepositoryListItem]) -> [RepositoryListItem] {
        guard var item = items.first(where: { $0.id == id }) else { return items }
        if item.isPinned == pinned { return items }
        var result = items.filter { $0.id != id }
        item.isPinned = pinned
        let index = result.firstIndex(where: { !$0.isPinned }) ?? result.count
        result.insert(item, at: index)
        return result
    }

    public static func move(id: String, relativeTo targetID: String, after: Bool,
                            in items: [RepositoryListItem]) -> [RepositoryListItem] {
        guard id != targetID,
              let original = items.first(where: { $0.id == id }),
              let target = items.first(where: { $0.id == targetID }) else { return items }
        var moving = original
        moving.isPinned = target.isPinned
        var result = items.filter { $0.id != id }
        guard let targetIndex = result.firstIndex(where: { $0.id == targetID }) else { return items }
        result.insert(moving, at: after ? targetIndex + 1 : targetIndex)
        return normalize(result)
    }

    public static func normalize(_ items: [RepositoryListItem]) -> [RepositoryListItem] {
        items.filter(\.isPinned) + items.filter { !$0.isPinned }
    }

    public static func isAbove(id: String, relativeTo targetID: String,
                               in items: [RepositoryListItem]) -> Bool {
        guard let draggedIndex = items.firstIndex(where: { $0.id == id }),
              let targetIndex = items.firstIndex(where: { $0.id == targetID }) else {
            return false
        }
        return draggedIndex < targetIndex
    }
}
