import Foundation

public struct Highlighter: Sendable {
    public init() {}

    /// 按文件路径猜语言；不认识则空数组。可取消。
    public func tokens(in source: String, path: String) -> [TokenSpan] {
        guard !Task.isCancelled else { return [] }
        guard let language = Language.from(path: path) else { return [] }
        return tokenize(source, language: language)
    }
}

private enum Language {
    case swift
    case javaScript
    case typeScript
    case python
    case go
    case json
    case shell
    case markdown

    static func from(path: String) -> Language? {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return .swift
        case "js", "mjs", "cjs": return .javaScript
        case "ts", "tsx": return .typeScript
        case "py": return .python
        case "go": return .go
        case "json", "jsonc": return .json
        case "sh", "bash", "zsh": return .shell
        case "md": return .markdown
        default: return nil
        }
    }

    var config: LanguageConfig {
        switch self {
        case .swift:
            LanguageConfig(
                lineComment: "//",
                blockComment: ("/*", "*/"),
                stringDelimiters: ["\"\"\"", "\""],
                keywords: Self.swiftKeywords,
                highlightTypes: true)
        case .javaScript, .typeScript:
            LanguageConfig(
                lineComment: "//",
                blockComment: ("/*", "*/"),
                stringDelimiters: ["`", "\"", "'"],
                keywords: Self.javaScriptKeywords,
                highlightTypes: true)
        case .python:
            LanguageConfig(
                lineComment: "#",
                blockComment: nil,
                stringDelimiters: ["\"\"\"", "'''", "\"", "'"],
                keywords: Self.pythonKeywords,
                highlightTypes: true)
        case .go:
            LanguageConfig(
                lineComment: "//",
                blockComment: ("/*", "*/"),
                stringDelimiters: ["`", "\"", "'"],
                keywords: Self.goKeywords,
                highlightTypes: true)
        case .json:
            LanguageConfig(
                lineComment: "//",
                blockComment: ("/*", "*/"),
                stringDelimiters: ["\""],
                keywords: ["true", "false", "null"],
                highlightTypes: false)
        case .shell:
            LanguageConfig(
                lineComment: "#",
                blockComment: nil,
                stringDelimiters: ["\"", "'"],
                keywords: Self.shellKeywords,
                highlightTypes: false)
        case .markdown:
            LanguageConfig(
                lineComment: nil,
                blockComment: ("<!--", "-->"),
                stringDelimiters: ["```", "`"],
                keywords: [],
                highlightTypes: false)
        }
    }

    private static let swiftKeywords: Set<String> = [
        "associatedtype", "class", "deinit", "enum", "extension", "fileprivate",
        "func", "import", "init", "inout", "internal", "let", "open", "operator",
        "private", "precedencegroup", "protocol", "public", "rethrows", "static",
        "struct", "subscript", "typealias", "var", "break", "case", "continue",
        "default", "defer", "do", "else", "fallthrough", "for", "guard", "if",
        "in", "repeat", "return", "switch", "where", "while", "as", "Any", "catch",
        "false", "is", "nil", "super", "self", "Self", "throw", "throws", "true",
        "try", "async", "await", "actor", "some", "any", "nonisolated", "isolated",
        "consuming", "borrowing", "each", "package", "macro",
    ]

    private static let javaScriptKeywords: Set<String> = [
        "break", "case", "catch", "class", "const", "continue", "debugger",
        "default", "delete", "do", "else", "export", "extends", "false", "finally",
        "for", "function", "if", "import", "in", "instanceof", "let", "new", "null",
        "return", "super", "switch", "this", "throw", "true", "try", "typeof",
        "var", "void", "while", "with", "yield", "async", "await", "of", "from",
        "static", "as", "interface", "type", "enum", "implements", "package",
        "private", "protected", "public", "readonly", "namespace", "abstract",
        "boolean", "number", "string", "undefined",
    ]

    private static let pythonKeywords: Set<String> = [
        "and", "as", "assert", "async", "await", "break", "class", "continue",
        "def", "del", "elif", "else", "except", "False", "finally", "for", "from",
        "global", "if", "import", "in", "is", "lambda", "None", "nonlocal", "not",
        "or", "pass", "raise", "return", "True", "try", "while", "with", "yield",
        "match", "case",
    ]

    private static let goKeywords: Set<String> = [
        "break", "case", "chan", "const", "continue", "default", "defer", "else",
        "fallthrough", "for", "func", "go", "goto", "if", "import", "interface",
        "map", "package", "range", "return", "select", "struct", "switch", "type",
        "var", "true", "false", "nil", "iota",
    ]

    private static let shellKeywords: Set<String> = [
        "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done",
        "case", "esac", "in", "function", "select", "time", "coproc",
    ]
}

private struct LanguageConfig {
    var lineComment: String?
    var blockComment: (start: String, end: String)?
    var stringDelimiters: [String]
    var keywords: Set<String>
    var highlightTypes: Bool
}

private func tokenize(_ source: String, language: Language) -> [TokenSpan] {
    let units = Array(source.utf16)
    let n = units.count
    let config = language.config
    var spans: [TokenSpan] = []
    var i = 0

    let lineComment = config.lineComment.map { Array($0.utf16) }
    let blockStart = config.blockComment.map { Array($0.start.utf16) }
    let blockEnd = config.blockComment.map { Array($0.end.utf16) }
    let quotes = config.stringDelimiters.map { Array($0.utf16) }

    func matches(_ needle: [UInt16], at index: Int) -> Bool {
        guard index + needle.count <= n else { return false }
        for offset in needle.indices {
            if units[index + offset] != needle[offset] { return false }
        }
        return true
    }

    func emit(_ start: Int, _ end: Int, _ kind: TokenKind) {
        guard end > start else { return }
        spans.append(TokenSpan(range: start..<end, kind: kind))
    }

    func isIdentStart(_ c: UInt16) -> Bool {
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95
    }

    func isIdent(_ c: UInt16) -> Bool {
        isIdentStart(c) || (c >= 48 && c <= 57)
    }

    func isDigit(_ c: UInt16) -> Bool {
        c >= 48 && c <= 57
    }

    func isHex(_ c: UInt16) -> Bool {
        isDigit(c) || (c >= 65 && c <= 70) || (c >= 97 && c <= 102)
    }

    while i < n {
        if Task.isCancelled { return spans }

        if let start = blockStart, let end = blockEnd, matches(start, at: i) {
            let from = i
            i += start.count
            while i < n, !matches(end, at: i) { i += 1 }
            if i < n { i += end.count }
            emit(from, i, .comment)
            continue
        }

        if let comment = lineComment, matches(comment, at: i) {
            let from = i
            i += comment.count
            while i < n, units[i] != 10 { i += 1 }
            emit(from, i, .comment)
            continue
        }

        if let quote = quotes.first(where: { matches($0, at: i) }) {
            let from = i
            i += quote.count
            let raw = quote == Array("`".utf16) || quote.count > 1
            while i < n, !matches(quote, at: i) {
                if !raw, units[i] == 92, i + 1 < n {
                    i += 2
                    continue
                }
                if quote.count == 1, units[i] == 10 { break }
                i += 1
            }
            if i < n, matches(quote, at: i) { i += quote.count }
            emit(from, i, .string)
            continue
        }

        if isDigit(units[i]) || (units[i] == 46 && i + 1 < n && isDigit(units[i + 1])) {
            let from = i
            if units[i] == 48, i + 1 < n, units[i + 1] == 120 || units[i + 1] == 88 {
                i += 2
                while i < n, isHex(units[i]) { i += 1 }
            } else {
                while i < n, isDigit(units[i]) { i += 1 }
                if i < n, units[i] == 46, i + 1 < n, isDigit(units[i + 1]) {
                    i += 1
                    while i < n, isDigit(units[i]) { i += 1 }
                }
                if i < n, units[i] == 101 || units[i] == 69 {
                    let exp = i + 1
                    var next = exp
                    if next < n, units[next] == 43 || units[next] == 45 { next += 1 }
                    if next < n, isDigit(units[next]) {
                        i = next
                        while i < n, isDigit(units[i]) { i += 1 }
                    }
                }
            }
            emit(from, i, .number)
            continue
        }

        if isIdentStart(units[i]) {
            let from = i
            i += 1
            while i < n, isIdent(units[i]) { i += 1 }
            let word = String(utf16CodeUnits: Array(units[from..<i]), count: i - from)
            if config.keywords.contains(word) {
                emit(from, i, .keyword)
            } else if config.highlightTypes, let first = word.utf16.first, first >= 65, first <= 90 {
                emit(from, i, .type)
            }
            continue
        }

        i += 1
    }

    return spans
}
