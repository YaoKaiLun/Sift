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

    /// 一次性拿到暂存区与工作区各自的 +/− 行数，供文件列表按分组展示。
    ///
    /// 两次 numstat 调用比逐文件算 diff 便宜得多，
    /// 这正是"文件列表要在 150ms 内出来"的做法——列表只需要数字，不需要内容。
    /// 未跟踪文件不在 numstat 输出里，列表中不显示行数。
    /// 两侧分开返回，避免同一路径在已暂存/未暂存两行上显示合并后的数字。
    public func lineStats() async throws -> (staged: [String: LineStats], unstaged: [String: LineStats]) {
        async let stagedData = runner.run(["diff", "--numstat", "-z", "--cached"], in: root)
        async let unstagedData = runner.run(["diff", "--numstat", "-z"], in: root)
        let staged = NumstatParser.parse(try await stagedData)
        let unstaged = NumstatParser.parse(try await unstagedData)
        return (staged, unstaged)
    }

    /// 从任意路径向上查找仓库根目录。用户通过选择目录添加仓库时使用。
    public static func discoverRoot(at url: URL, runner: GitRunner) async throws -> URL {
        let data = try await runner.run(["rev-parse", "--show-toplevel"], in: url)
        let path = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: path)
    }

    /// 把整个文件加入暂存区。必须拿 index 锁。
    public func stage(path: String) async throws {
        _ = try await runner.run(["add", "--", path], in: root, optionalLocks: false)
    }

    /// 把整个文件从暂存区撤出，工作区内容不动。
    public func unstage(path: String) async throws {
        _ = try await runner.run(
            ["restore", "--staged", "--", path], in: root, optionalLocks: false)
    }

    /// 把 unified patch 喂给 `git apply`。`cached` 只改 index，`reverse` 反向应用。
    public func apply(patch: String, cached: Bool, reverse: Bool) async throws {
        var arguments = ["apply"]
        if cached { arguments.append("--cached") }
        if reverse { arguments.append("-R") }
        _ = try await runner.run(
            arguments, in: root, stdin: Data(patch.utf8), optionalLocks: false)
    }

    /// 删除未跟踪文件。不调 git，路径必须解析后仍在仓库根目录下。
    public func deleteUntracked(path: String) async throws {
        let target = root.appendingPathComponent(path).standardizedFileURL
        let rootStd = root.standardizedFileURL
        guard target.path.hasPrefix(rootStd.path + "/") || target == rootStd else {
            throw GitError.launchFailed("拒绝删除仓库外的路径：\(path)")
        }
        try FileManager.default.removeItem(at: target)
    }

    /// 只暂存一个 hunk：生成 patch 后 `--cached` 正向 apply。
    public func stage(hunk: Hunk, path: String, originalPath: String?, kind: PatchFileKind) async throws {
        let patch = PatchBuilder.build(hunk: hunk, path: path, originalPath: originalPath, kind: kind)
        try await apply(patch: patch, cached: true, reverse: false)
    }

    /// 只取消暂存一个 hunk：同一份 patch `--cached -R`。
    public func unstage(hunk: Hunk, path: String, originalPath: String?, kind: PatchFileKind) async throws {
        let patch = PatchBuilder.build(hunk: hunk, path: path, originalPath: originalPath, kind: kind)
        try await apply(patch: patch, cached: true, reverse: true)
    }

    /// 丢弃工作区一个 hunk：同一份 patch 对工作树 `-R`，不碰 index。
    public func discard(hunk: Hunk, path: String, originalPath: String?, kind: PatchFileKind) async throws {
        let patch = PatchBuilder.build(hunk: hunk, path: path, originalPath: originalPath, kind: kind)
        try await apply(patch: patch, cached: false, reverse: true)
    }
}
