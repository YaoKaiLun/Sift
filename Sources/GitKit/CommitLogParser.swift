import Foundation

public struct CommitInfo: Sendable, Equatable, Identifiable {
    public var sha: String
    public var subject: String
    public var body: String
    public var authorName: String
    public var authorDate: Date
    public var id: String { sha }

    public init(sha: String, subject: String, body: String,
                authorName: String, authorDate: Date) {
        self.sha = sha
        self.subject = subject
        self.body = body
        self.authorName = authorName
        self.authorDate = authorDate
    }

    public var shortSHA: String { String(sha.prefix(7)) }
}

/// 解析 `git log --format=%H%x1f%s%x1f%b%x1f%an%x1f%aI%x1e`。
public enum CommitLogParser {
    private static let recordSeparator = UInt8(0x1e)
    private static let fieldSeparator = UInt8(0x1f)

    public static func parse(_ data: Data) -> [CommitInfo] {
        let records = data.split(separator: recordSeparator, omittingEmptySubsequences: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallback = ISO8601DateFormatter()

        return records.compactMap { record in
            let fields = Data(record)
                .split(separator: fieldSeparator, omittingEmptySubsequences: false)
                .map { String(decoding: $0, as: UTF8.self) }
            guard fields.count >= 5 else { return nil }
            let sha = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sha.isEmpty else { return nil }
            let dateText = fields[4].trimmingCharacters(in: .whitespacesAndNewlines)
            let date = formatter.date(from: dateText) ?? fallback.date(from: dateText) ?? Date.distantPast
            return CommitInfo(
                sha: sha,
                subject: fields[1],
                body: fields[2].trimmingCharacters(in: .whitespacesAndNewlines),
                authorName: fields[3],
                authorDate: date)
        }
    }
}
