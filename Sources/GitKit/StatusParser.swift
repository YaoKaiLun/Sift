import Foundation

public enum StatusParseError: Error, Sendable, Equatable {
    case malformedRecord(String)
    case truncatedRenameRecord(String)
    case unknownStatusCode(Character)
}

/// 解析 `git status --porcelain=v2 -z --untracked-files=all` 的输出。
///
/// 记录以 NUL 分隔。类型 2（重命名/复制）的记录之后紧跟一个**额外的** NUL
/// 分隔字段存放原路径——这是本解析器最容易出错的地方。
public enum StatusParser {
    public static func parse(_ data: Data) throws -> [FileStatus] {
        let fields = data
            .split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }

        var result: [FileStatus] = []
        var index = 0

        while index < fields.count {
            let field = fields[index]
            index += 1
            guard let marker = field.first else { continue }

            switch marker {
            case "1":
                result.append(try parseOrdinary(field))
            case "2":
                guard index < fields.count else {
                    throw StatusParseError.truncatedRenameRecord(field)
                }
                let originalPath = fields[index]
                index += 1
                result.append(try parseRename(field, originalPath: originalPath))
            case "u":
                result.append(try parseUnmerged(field))
            case "?":
                result.append(FileStatus(
                    path: String(field.dropFirst(2)),
                    originalPath: nil,
                    indexStatus: .untracked,
                    worktreeStatus: .untracked))
            default:
                // `#` 开头的头部行、`!` 开头的忽略项，以及任何未来新增的记录类型，
                // 都安全跳过而不是报错——宁可少显示一个文件，也不要整个列表炸掉。
                continue
            }
        }
        return result
    }

    /// `1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>` —— 9 段，path 可能含空格。
    private static func parseOrdinary(_ field: String) throws -> FileStatus {
        let parts = field.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
        guard parts.count == 9 else { throw StatusParseError.malformedRecord(field) }
        let (index, worktree) = try statusPair(parts[1], in: field)
        return FileStatus(path: String(parts[8]), originalPath: nil,
                          indexStatus: index, worktreeStatus: worktree)
    }

    /// `2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path>` —— 10 段。
    private static func parseRename(_ field: String, originalPath: String) throws -> FileStatus {
        let parts = field.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
        guard parts.count == 10 else { throw StatusParseError.malformedRecord(field) }
        let (index, worktree) = try statusPair(parts[1], in: field)
        return FileStatus(path: String(parts[9]), originalPath: originalPath,
                          indexStatus: index, worktreeStatus: worktree)
    }

    /// `u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>` —— 11 段。
    private static func parseUnmerged(_ field: String) throws -> FileStatus {
        let parts = field.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
        guard parts.count == 11 else { throw StatusParseError.malformedRecord(field) }
        return FileStatus(path: String(parts[10]), originalPath: nil,
                          indexStatus: .unmerged, worktreeStatus: .unmerged)
    }

    private static func statusPair(
        _ xy: Substring, in record: String
    ) throws -> (FileChangeKind, FileChangeKind) {
        let characters = Array(xy)
        guard characters.count == 2 else { throw StatusParseError.malformedRecord(record) }
        return (try kind(from: characters[0]), try kind(from: characters[1]))
    }

    private static func kind(from character: Character) throws -> FileChangeKind {
        switch character {
        case ".": return .unmodified
        case "M": return .modified
        case "A": return .added
        case "D": return .deleted
        case "R": return .renamed
        case "C": return .copied
        case "T": return .typeChanged
        case "U": return .unmerged
        default: throw StatusParseError.unknownStatusCode(character)
        }
    }
}
