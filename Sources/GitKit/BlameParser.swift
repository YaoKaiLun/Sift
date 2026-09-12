import Foundation

public struct BlameLine: Sendable, Equatable {
    public let sha: String
    public let author: String
    public let authorTime: Date
    public let summary: String
    public let newLineNumber: Int

    public init(sha: String, author: String, authorTime: Date, summary: String, newLineNumber: Int) {
        self.sha = sha
        self.author = author
        self.authorTime = authorTime
        self.summary = summary
        self.newLineNumber = newLineNumber
    }
}

/// 解析 `git blame -p` 的 porcelain 输出。
///
/// 每行以 `sha origLine finalLine [group]` 开头；同一 SHA 的元数据只出现一次，
/// 后续行复用缓存。正文行以 TAB 开头，忽略。
public enum BlameParser {
    private struct Record {
        var sha: String
        var newLineNumber: Int
        var author: String?
        var authorTime: Date?
        var summary: String?
    }

    private struct Cached {
        var author: String
        var authorTime: Date
        var summary: String
    }

    public static func parse(_ data: Data) -> [BlameLine] {
        let text = String(decoding: data, as: UTF8.self)
        guard !text.isEmpty else { return [] }

        var result: [BlameLine] = []
        var cache: [String: Cached] = [:]
        var current: Record?

        func finishCurrent() {
            guard let current else { return }
            let info: Cached
            if let cached = cache[current.sha] {
                info = cached
            } else if let author = current.author,
                      let authorTime = current.authorTime,
                      let summary = current.summary {
                info = Cached(author: author, authorTime: authorTime, summary: summary)
                cache[current.sha] = info
            } else {
                return
            }
            result.append(BlameLine(
                sha: current.sha,
                author: info.author,
                authorTime: info.authorTime,
                summary: info.summary,
                newLineNumber: current.newLineNumber))
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("\t") { continue }
            if let header = parseHeader(line) {
                finishCurrent()
                var record = Record(sha: header.sha, newLineNumber: header.final)
                if let cached = cache[header.sha] {
                    record.author = cached.author
                    record.authorTime = cached.authorTime
                    record.summary = cached.summary
                }
                current = record
                continue
            }
            guard current != nil else { continue }
            if line.hasPrefix("author-time ") {
                let raw = String(line.dropFirst("author-time ".count))
                if let epoch = TimeInterval(raw) {
                    current?.authorTime = Date(timeIntervalSince1970: epoch)
                }
            } else if line.hasPrefix("author ") {
                current?.author = String(line.dropFirst("author ".count))
            } else if line.hasPrefix("summary ") {
                current?.summary = String(line.dropFirst("summary ".count))
            }
        }
        finishCurrent()
        return result
    }

    /// `40-hex orig final [group]`
    private static func parseHeader(_ line: String) -> (sha: String, final: Int)? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count >= 3,
              parts[0].count == 40,
              parts[0].allSatisfy(\.isHexDigit),
              let final = Int(parts[2]) else { return nil }
        return (String(parts[0]), final)
    }
}
