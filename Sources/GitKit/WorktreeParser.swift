import Foundation

/// 解析 `git worktree list --porcelain` 的输出。
/// 记录块以空行分隔，第一块永远是主工作树。
public enum WorktreeParser {
    public static func parse(_ data: Data) -> [Worktree] {
        let text = String(decoding: data, as: UTF8.self)
        let blocks = text
            .components(separatedBy: "\n\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        return blocks.enumerated().compactMap { offset, block in
            parseBlock(block, isMain: offset == 0)
        }
    }

    private static func parseBlock(_ block: String, isMain: Bool) -> Worktree? {
        var path: URL?
        var head: String?
        var branch: String?
        var isBare = false
        var isDetached = false
        var isLocked = false

        for line in block.split(separator: "\n", omittingEmptySubsequences: true) {
            if let value = value(of: "worktree", in: line) {
                path = URL(fileURLWithPath: value)
            } else if let value = value(of: "HEAD", in: line) {
                head = value
            } else if let value = value(of: "branch", in: line) {
                // 形如 refs/heads/feature，只保留短名。
                branch = value.hasPrefix("refs/heads/")
                    ? String(value.dropFirst("refs/heads/".count))
                    : value
            } else if line == "bare" {
                isBare = true
            } else if line == "detached" {
                isDetached = true
            } else if line == "locked" || line.hasPrefix("locked ") {
                isLocked = true
            }
        }

        guard let path else { return nil }
        return Worktree(path: path, head: head, branch: branch,
                        isBare: isBare, isDetached: isDetached,
                        isLocked: isLocked, isMain: isMain)
    }

    private static func value(of key: String, in line: Substring) -> String? {
        let prefix = key + " "
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count))
    }
}
