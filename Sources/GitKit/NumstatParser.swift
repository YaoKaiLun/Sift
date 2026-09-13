import Foundation

public struct LineStats: Sendable, Equatable {
    public let added: Int
    public let deleted: Int
    public let isBinary: Bool

    public init(added: Int, deleted: Int, isBinary: Bool) {
        self.added = added
        self.deleted = deleted
        self.isBinary = isBinary
    }

    public func merging(_ other: LineStats) -> LineStats {
        LineStats(added: added + other.added,
                  deleted: deleted + other.deleted,
                  isBinary: isBinary || other.isBinary)
    }
}

/// 解析 `git diff --numstat -z` 的输出。
///
/// 普通记录：`<added>\t<deleted>\t<path>\0`
/// 重命名记录：`<added>\t<deleted>\t\0<oldPath>\0<newPath>\0`
///   —— 路径字段为空，随后是两个**独立的** NUL 字段。没处理这一点的话，
///   重命名之后的所有记录都会错位。
/// 二进制文件的 added / deleted 是 `-`。
public enum NumstatParser {
    public static func parse(_ data: Data) -> [String: LineStats] {
        let fields = data
            .split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }

        var result: [String: LineStats] = [:]
        var index = 0

        while index < fields.count {
            let field = fields[index]
            index += 1
            guard !field.isEmpty else { continue }

            let parts = field.split(separator: "\t", maxSplits: 2,
                                    omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }

            let isBinary = parts[0] == "-"
            let added = Int(parts[0]) ?? 0
            let deleted = Int(parts[1]) ?? 0

            let path: String
            if parts[2].isEmpty {
                // 重命名：跳过旧路径，取新路径。
                guard index + 1 < fields.count else { break }
                index += 1                       // 旧路径
                path = fields[index]             // 新路径
                index += 1
            } else {
                path = String(parts[2])
            }

            let stats = LineStats(added: added, deleted: deleted, isBinary: isBinary)
            result[path] = result[path]?.merging(stats) ?? stats
        }
        return result
    }
}
