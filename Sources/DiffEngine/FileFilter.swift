import Darwin
import Foundation

/// 按 glob 判断文件是否应从中栏隐藏。与生成文件折叠是两种产品行为。
public enum FileFilter: Sendable {
    public static let defaultPatterns: [String] = [
        "*.png",
        "*.jpg",
        "*.jpeg",
        "*.gif",
        "*.webp",
        "*.svg",
        "*.ico",
        "*Test.swift",
        "*_test.go",
        "*.test.ts",
        "*.test.tsx",
        "*.spec.ts",
        "*.spec.tsx",
        "*.snap",
    ]

    public static func matches(path: String, patterns: [String]) -> Bool {
        let components = path.split(separator: "/").map { $0.lowercased() }
        guard let fileName = components.last else { return false }

        for raw in patterns {
            let rule = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rule.isEmpty else { continue }
            let pattern = rule.lowercased()
            if pattern.hasSuffix("/") {
                let directoryName = String(pattern.dropLast())
                if components.dropLast().contains(directoryName) {
                    return true
                }
            } else if matchesGlob(fileName, pattern: pattern) {
                return true
            }
        }
        return false
    }

    public static func hiding<T>(_ items: [T], path: (T) -> String,
                                 enabled: Bool, patterns: [String]) -> [T] {
        guard enabled, !patterns.isEmpty else { return items }
        return items.filter { !matches(path: path($0), patterns: patterns) }
    }

    private static func matchesGlob(_ name: String, pattern: String) -> Bool {
        pattern.withCString { patternPointer in
            name.withCString { namePointer in
                fnmatch(patternPointer, namePointer, 0) == 0
            }
        }
    }
}
