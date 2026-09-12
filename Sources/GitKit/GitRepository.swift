import Foundation

/// 单个工作树的 git 操作入口。组合 GitRunner 与各解析器，
/// 对上层屏蔽命令行参数细节。
public struct GitRepository: Sendable {
    /// 工作树根目录。对 worktree 而言是该 worktree 自己的目录，不是主仓库目录。
    public let root: URL
    private let runner: GitRunner

    public init(root: URL, runner: GitRunner = GitRunner()) {
        self.root = root
        self.runner = runner
    }

    public func status() async throws -> [FileStatus] {
        let data = try await runner.run(
            ["status", "--porcelain=v2", "-z", "--untracked-files=all"], in: root)
        return try StatusParser.parse(data)
    }

    public func worktrees() async throws -> [Worktree] {
        let data = try await runner.run(["worktree", "list", "--porcelain"], in: root)
        return WorktreeParser.parse(data)
    }

    /// 单个文件的 diff。`staged` 为 true 时对比暂存区与 HEAD，否则对比工作区与暂存区。
    public func diff(path: String, staged: Bool) async throws -> FileDiff {
        var arguments = ["diff", "--no-color", "-U3"]
        if staged { arguments.append("--cached") }
        arguments += ["--", path]
        let data = try await runner.run(arguments, in: root)
        return DiffParser.parse(data, path: path)
    }

    /// 直接从磁盘读文件内容。未跟踪文件没有 diff，需要按"整个文件都是新增"渲染。
    public func fileContents(path: String) async throws -> String {
        let url = root.appendingPathComponent(path)
        let data = try Data(contentsOf: url)
        return String(decoding: data, as: UTF8.self)
    }

    /// 一次性拿到所有已跟踪文件的 +/− 行数，供文件列表展示。
    ///
    /// 两次 numstat 调用（暂存区与工作区）比逐文件算 diff 便宜得多，
    /// 这正是"文件列表要在 150ms 内出来"的做法——列表只需要数字，不需要内容。
    /// 未跟踪文件不在 numstat 输出里，列表中不显示行数。
    public func lineStats() async throws -> [String: LineStats] {
        async let stagedData = runner.run(["diff", "--numstat", "-z", "--cached"], in: root)
        async let unstagedData = runner.run(["diff", "--numstat", "-z"], in: root)
        let staged = NumstatParser.parse(try await stagedData)
        let unstaged = NumstatParser.parse(try await unstagedData)
        return staged.merging(unstaged) { $0.merging($1) }
    }

    /// 从任意路径向上查找仓库根目录。用户通过选择目录添加仓库时使用。
    public static func discoverRoot(at url: URL, runner: GitRunner) async throws -> URL {
        let data = try await runner.run(["rev-parse", "--show-toplevel"], in: url)
        let path = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: path)
    }
}
