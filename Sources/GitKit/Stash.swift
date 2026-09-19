import Foundation

public struct StashInfo: Sendable, Equatable, Identifiable, Hashable {
    public let sha: String
    /// `stash@{n}`，应用和删除时用。
    public let reflogSelector: String
    public let message: String
    public var id: String { sha }
    public var sidebarRowID: String { "stash:\(sha)" }

    public init(sha: String, reflogSelector: String, message: String) {
        self.sha = sha
        self.reflogSelector = reflogSelector
        self.message = message
    }
}

/// 解析 `git stash list --format=%H%x1f%gd%x1f%s%x1e`。
public enum StashListParser {
    private static let recordSeparator = UInt8(0x1e)
    private static let fieldSeparator = UInt8(0x1f)

    public static func parse(_ data: Data) -> [StashInfo] {
        let records = data.split(separator: recordSeparator, omittingEmptySubsequences: true)
        return records.compactMap { record in
            let fields = Data(record)
                .split(separator: fieldSeparator, omittingEmptySubsequences: false)
                .map { String(decoding: $0, as: UTF8.self) }
            guard fields.count >= 3 else { return nil }
            let sha = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let selector = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let message = fields[2].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sha.isEmpty, !selector.isEmpty else { return nil }
            return StashInfo(sha: sha, reflogSelector: selector, message: message)
        }
    }
}
