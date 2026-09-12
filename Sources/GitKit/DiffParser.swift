import Foundation

/// 解析 `git diff --no-color -U<n> -- <path>` 针对单个文件的输出。
///
/// 关键点：行的类型必须由**行首第一个字符的位置**决定，不能靠内容猜。
/// 文件内容本身完全可能以 `+++` 或 `---` 开头。
public enum DiffParser {
    public static func parse(_ data: Data, path: String) -> FileDiff {
        // Local regex avoids Swift 6 static Regex concurrency-safety error.
        let hunkHeaderPattern =
            /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@ ?(.*)$/

        let text = String(decoding: data, as: UTF8.self)
        guard !text.isEmpty else {
            return FileDiff(path: path, originalPath: nil, content: .empty)
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)

        var originalPath: String?
        var oldMode: String?
        var newMode: String?
        var hunks: [Hunk] = []
        var isBinary = false

        // 当前正在累积的 hunk
        var currentHeader: (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, heading: String)?
        var currentLines: [DiffLine] = []
        var oldLineNumber = 0
        var newLineNumber = 0

        func flushCurrentHunk() {
            guard let header = currentHeader else { return }
            hunks.append(Hunk(
                oldStart: header.oldStart, oldCount: header.oldCount,
                newStart: header.newStart, newCount: header.newCount,
                sectionHeading: header.heading, lines: currentLines))
            currentHeader = nil
            currentLines = []
        }

        for line in lines {
            // hunk 头
            if line.hasPrefix("@@"),
               let match = try? hunkHeaderPattern.wholeMatch(in: String(line)) {
                flushCurrentHunk()
                let oldStart = Int(match.1) ?? 0
                let oldCount = match.2.flatMap { Int($0) } ?? 1
                let newStart = Int(match.3) ?? 0
                let newCount = match.4.flatMap { Int($0) } ?? 1
                currentHeader = (oldStart, oldCount, newStart, newCount, String(match.5))
                oldLineNumber = oldStart
                newLineNumber = newStart
                continue
            }

            // 尚未进入任何 hunk：解析文件头
            if currentHeader == nil {
                if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                    isBinary = true
                } else if line.hasPrefix("rename from ") {
                    originalPath = String(line.dropFirst("rename from ".count))
                } else if line.hasPrefix("old mode ") {
                    oldMode = String(line.dropFirst("old mode ".count))
                } else if line.hasPrefix("new mode ") {
                    newMode = String(line.dropFirst("new mode ".count))
                }
                continue
            }

            // hunk 内部：靠首字符判断类型
            guard let marker = line.first else {
                // diff 中的空行代表一个空的上下文行。
                currentLines.append(DiffLine(kind: .context,
                                             oldLineNumber: oldLineNumber,
                                             newLineNumber: newLineNumber,
                                             text: ""))
                oldLineNumber += 1
                newLineNumber += 1
                continue
            }

            let body = String(line.dropFirst())
            switch marker {
            case "+":
                currentLines.append(DiffLine(kind: .addition,
                                             oldLineNumber: nil,
                                             newLineNumber: newLineNumber,
                                             text: body))
                newLineNumber += 1
            case "-":
                currentLines.append(DiffLine(kind: .deletion,
                                             oldLineNumber: oldLineNumber,
                                             newLineNumber: nil,
                                             text: body))
                oldLineNumber += 1
            case " ":
                currentLines.append(DiffLine(kind: .context,
                                             oldLineNumber: oldLineNumber,
                                             newLineNumber: newLineNumber,
                                             text: body))
                oldLineNumber += 1
                newLineNumber += 1
            case "\\":
                currentLines.append(DiffLine(kind: .noNewlineMarker,
                                             oldLineNumber: nil,
                                             newLineNumber: nil,
                                             text: body.trimmingCharacters(in: .whitespaces)))
            default:
                // 下一个文件的 `diff --git` 头，或尾部噪音。单文件 diff 中不应出现。
                flushCurrentHunk()
            }
        }
        flushCurrentHunk()

        if isBinary {
            return FileDiff(path: path, originalPath: originalPath, content: .binary)
        }
        if hunks.isEmpty, let oldMode, let newMode {
            return FileDiff(path: path, originalPath: originalPath,
                            content: .modeChangeOnly(oldMode: oldMode, newMode: newMode))
        }
        if hunks.isEmpty {
            return FileDiff(path: path, originalPath: originalPath, content: .empty)
        }
        return FileDiff(path: path, originalPath: originalPath, content: .textual(hunks))
    }
}
