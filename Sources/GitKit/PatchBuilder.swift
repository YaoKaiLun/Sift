import Foundation

public enum PatchFileKind: Sendable, Equatable {
    case modified
    case added
    case deleted
}

public enum PatchBuilder {
    public static func build(
        hunk: Hunk,
        path: String,
        originalPath: String? = nil,
        kind: PatchFileKind
    ) -> String {
        let oldPath = originalPath ?? path
        let gitLine: String
        let oldHeader: String
        let newHeader: String
        switch kind {
        case .modified:
            gitLine = "diff --git a/\(oldPath) b/\(path)"
            oldHeader = "--- a/\(oldPath)"
            newHeader = "+++ b/\(path)"
        case .added:
            // 必须带 new file mode，否则 apply -R 会把 /dev/null 当成相对路径。
            gitLine = "diff --git a/\(path) b/\(path)\nnew file mode 100644"
            oldHeader = "--- /dev/null"
            newHeader = "+++ b/\(path)"
        case .deleted:
            gitLine = "diff --git a/\(path) b/\(path)\ndeleted file mode 100644"
            oldHeader = "--- a/\(path)"
            newHeader = "+++ /dev/null"
        }
        var text = gitLine + "\n" + oldHeader + "\n" + newHeader + "\n" + hunk.patchText
        if !text.hasSuffix("\n") { text += "\n" }
        return text
    }
}
