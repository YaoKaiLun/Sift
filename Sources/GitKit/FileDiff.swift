import Foundation

public enum DiffLineKind: Sendable, Equatable {
    case context
    case addition
    case deletion
    /// `\ No newline at end of file`
    case noNewlineMarker
}

public struct DiffLine: Sendable, Equatable {
    public let kind: DiffLineKind
    /// 旧文件中的行号，新增行为 nil。
    public let oldLineNumber: Int?
    /// 新文件中的行号，删除行为 nil。
    public let newLineNumber: Int?
    /// 行内容，已去掉行首的 `+` / `-` / 空格标记。
    public let text: String

    public init(kind: DiffLineKind, oldLineNumber: Int?, newLineNumber: Int?, text: String) {
        self.kind = kind
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
        self.text = text
    }
}

public struct Hunk: Sendable, Equatable, Identifiable {
    public let oldStart: Int
    public let oldCount: Int
    public let newStart: Int
    public let newCount: Int
    /// `@@ ... @@` 之后的内容，git 通常填所属函数签名。
    public let sectionHeading: String
    public let lines: [DiffLine]

    public var id: String { "\(oldStart),\(oldCount),\(newStart),\(newCount)" }

    public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int,
                sectionHeading: String, lines: [DiffLine]) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.sectionHeading = sectionHeading
        self.lines = lines
    }

    /// 还原成可以喂给 `git apply` 的 hunk 文本。计划二的 stage/discard 会用到。
    public var patchText: String {
        var text = "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"
        if !sectionHeading.isEmpty { text += " \(sectionHeading)" }
        text += "\n"
        for line in lines {
            switch line.kind {
            case .context: text += " \(line.text)\n"
            case .addition: text += "+\(line.text)\n"
            case .deletion: text += "-\(line.text)\n"
            case .noNewlineMarker: text += "\\ No newline at end of file\n"
            }
        }
        return text
    }
}

public enum ImageSide: Sendable, Equatable {
    case bytes(Data)
    case tooLarge(byteCount: Int)
}

public struct ImageDiff: Sendable, Equatable {
    public let old: ImageSide?
    public let new: ImageSide?

    public init(old: ImageSide?, new: ImageSide?) {
        self.old = old
        self.new = new
    }

    public var estimatedBytes: Int {
        Self.bytes(old) + Self.bytes(new)
    }

    private static func bytes(_ side: ImageSide?) -> Int {
        switch side {
        case .none: 0
        case .bytes(let data): data.count
        case .tooLarge: 128
        }
    }
}

public enum ImagePath {
    private static let extensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "tif", "bmp"
    ]

    public static func matches(_ path: String) -> Bool {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        return extensions.contains(ext)
    }
}

public enum BlobSource: Sendable, Equatable {
    case worktree
    case index
    case head
    case revision(String)
}

public enum BlobRead: Sendable, Equatable {
    case missing
    case tooLarge(byteCount: Int)
    case bytes(Data)
}

public enum DiffContent: Sendable, Equatable {
    case textual([Hunk])
    case binary
    case image(ImageDiff)
    case modeChangeOnly(oldMode: String, newMode: String)
    /// git 没有输出任何差异。
    case empty
}

public struct FileDiff: Sendable, Equatable {
    public let path: String
    public let originalPath: String?
    public let content: DiffContent

    public init(path: String, originalPath: String?, content: DiffContent) {
        self.path = path
        self.originalPath = originalPath
        self.content = content
    }

    public var hunks: [Hunk] {
        if case .textual(let hunks) = content { return hunks }
        return []
    }

    public var addedLineCount: Int {
        hunks.reduce(0) { $0 + $1.lines.count(where: { $0.kind == .addition }) }
    }

    public var deletedLineCount: Int {
        hunks.reduce(0) { $0 + $1.lines.count(where: { $0.kind == .deletion }) }
    }

    /// 文本内容的粗算字节数，用来在解析完 git diff 后再判一次 500KB 折叠。
    public var estimatedByteCount: Int {
        hunks.reduce(0) { total, hunk in
            total + hunk.lines.reduce(0) { $0 + $1.text.utf8.count + 1 }
        }
    }
}
