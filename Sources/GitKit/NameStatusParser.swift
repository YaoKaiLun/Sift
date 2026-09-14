import Foundation

public enum NameStatusParseError: Error, Sendable, Equatable {
    case truncatedRecord(String)
}

/// 解析 `git diff --name-status -z` / `git diff-tree --name-status -z`。
///
/// 普通：`M\0path\0`（或 `M\tpath\0`）
/// 重命名/复制：`R100\0old\0new\0`
public enum NameStatusParser {
    public static func parse(_ data: Data) throws -> [FileStatus] {
        let fields = data
            .split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }

        var result: [FileStatus] = []
        var index = 0

        while index < fields.count {
            let field = fields[index]
            index += 1
            guard !field.isEmpty else { continue }

            let statusToken: String
            let inlinePath: String?
            if let tab = field.firstIndex(of: "\t") {
                statusToken = String(field[..<tab])
                inlinePath = String(field[field.index(after: tab)...])
            } else {
                statusToken = field
                inlinePath = nil
            }

            guard let letter = statusToken.first,
                  let kind = kind(for: letter) else { continue }

            if letter == "R" || letter == "C" {
                if let inlinePath, index < fields.count {
                    let newPath = fields[index]
                    index += 1
                    result.append(FileStatus(
                        path: newPath, originalPath: inlinePath,
                        indexStatus: kind, worktreeStatus: .unmodified))
                } else {
                    guard index + 1 < fields.count else {
                        throw NameStatusParseError.truncatedRecord(statusToken)
                    }
                    let oldPath = fields[index]
                    let newPath = fields[index + 1]
                    index += 2
                    result.append(FileStatus(
                        path: newPath, originalPath: oldPath,
                        indexStatus: kind, worktreeStatus: .unmodified))
                }
            } else {
                let path: String
                if let inlinePath {
                    path = inlinePath
                } else {
                    guard index < fields.count else {
                        throw NameStatusParseError.truncatedRecord(statusToken)
                    }
                    path = fields[index]
                    index += 1
                }
                guard !path.isEmpty else { continue }
                result.append(FileStatus(
                    path: path, originalPath: nil,
                    indexStatus: kind, worktreeStatus: .unmodified))
            }
        }
        return result
    }

    private static func kind(for letter: Character) -> FileChangeKind? {
        switch letter {
        case "M": .modified
        case "A": .added
        case "D": .deleted
        case "T": .typeChanged
        case "U": .unmerged
        case "R": .renamed
        case "C": .copied
        default: nil
        }
    }
}
