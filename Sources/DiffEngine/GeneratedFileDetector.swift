import Darwin
import Foundation

public enum GeneratedFileReason: Sendable, Equatable {
    /// 命中了某条路径规则，附带规则本身，便于在 UI 中说明原因。
    case pathRule(String)
    case tooManyLines(Int)
    case tooLarge(Int)

    /// 展示给用户的说明文字。
    public var explanation: String {
        switch self {
        case .pathRule(let rule): "匹配规则 \(rule)"
        case .tooManyLines(let count): "共 \(count) 行"
        case .tooLarge(let bytes): "共 \(bytes / 1024) KB"
        }
    }
}

/// 判断一个文件是否应该默认折叠。命中的文件不读内容、不算 diff、不做高亮，
/// 只显示一个占位条，用户点击后才加载。
///
/// 这既是性能保护，也是产品功能——agent 的改动里往往混着大量 lockfile 和构建产物。
public struct GeneratedFileDetector: Sendable {
    /// 支持两种形式：以 `/` 结尾表示目录名（按路径段精确匹配，避免
    /// `distribution/` 被 `dist/` 误伤），否则按文件名做 glob 匹配。
    public static let defaultPathRules: [String] = [
        "dist/", "build/", "node_modules/", "vendor/", ".next/", "target/",
        "*.lock", "*-lock.json", "*-lock.yaml", "*.lockb",
        "*.min.js", "*.min.css", "*.map",
        "*.pb.go", "*_pb2.py", "*.generated.*", "*_generated.*",
    ]

    private let pathRules: [String]
    private let maximumLines: Int
    private let maximumBytes: Int

    public init(pathRules: [String] = GeneratedFileDetector.defaultPathRules,
                maximumLines: Int = 3_000,
                maximumBytes: Int = 500_000) {
        self.pathRules = pathRules
        self.maximumLines = maximumLines
        self.maximumBytes = maximumBytes
    }

    /// 返回折叠原因，nil 表示正常显示。
    /// `lineCount` 与 `byteCount` 未知时传 nil，此时只按路径规则判断。
    public func reason(forPath path: String, lineCount: Int?, byteCount: Int?) -> GeneratedFileReason? {
        let components = path.split(separator: "/").map(String.init)
        guard let fileName = components.last else { return nil }

        for rule in pathRules {
            if rule.hasSuffix("/") {
                let directoryName = String(rule.dropLast())
                // 按路径段精确匹配，不用子串包含。
                if components.dropLast().contains(directoryName) {
                    return .pathRule(rule)
                }
            } else if matchesGlob(fileName, pattern: rule) {
                return .pathRule(rule)
            }
        }

        if let lineCount, lineCount > maximumLines { return .tooManyLines(lineCount) }
        if let byteCount, byteCount > maximumBytes { return .tooLarge(byteCount) }
        return nil
    }

    /// fnmatch 的薄封装。规则里只会用到 `*` 和 `?`，交给系统实现即可。
    private func matchesGlob(_ name: String, pattern: String) -> Bool {
        pattern.withCString { patternPointer in
            name.withCString { namePointer in
                fnmatch(patternPointer, namePointer, 0) == 0
            }
        }
    }
}
