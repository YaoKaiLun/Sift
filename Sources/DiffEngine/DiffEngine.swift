import Foundation
import GitKit

/// diff 加载的唯一入口。负责三件事：判断是否折叠、查缓存、把未跟踪文件
/// 伪造成"整个文件都是新增"的 diff。
public actor DiffEngine {
    private let detector: GeneratedFileDetector
    private let cache: DiffCache

    public init(detector: GeneratedFileDetector = GeneratedFileDetector(),
                cache: DiffCache = DiffCache()) {
        self.detector = detector
        self.cache = cache
    }

    /// 加载单个文件的 diff。命中生成文件规则时返回 `.collapsed` 且不读取内容。
    public func load(status: FileStatus, staged: Bool,
                     from repository: GitRepository) async throws -> LoadedDiff {
        try await load(status: status, staged: staged,
                       from: repository, ignoringCollapse: false)
    }

    /// 用户在占位条上点了"仍要查看"时调用，跳过折叠判断。
    public func loadIgnoringCollapse(status: FileStatus, staged: Bool,
                                     from repository: GitRepository) async throws -> LoadedDiff {
        try await load(status: status, staged: staged,
                       from: repository, ignoringCollapse: true)
    }

    public func invalidate(worktreePath: URL) async {
        await cache.removeAll(inWorktree: worktreePath)
    }

    private func load(status: FileStatus, staged: Bool,
                      from repository: GitRepository,
                      ignoringCollapse: Bool) async throws -> LoadedDiff {
        let key = DiffCacheKey(worktreePath: repository.root,
                               filePath: status.path, staged: staged)

        if let cached = await cache.value(for: key) {
            // 折叠占位不算命中——用户明确要求强制加载时得真的去读。
            if !(ignoringCollapse && isCollapsed(cached)) {
                return cached
            }
        }

        if !ignoringCollapse,
           let reason = detector.reason(forPath: status.path, lineCount: nil, byteCount: nil) {
            let result = LoadedDiff.collapsed(reason: reason, path: status.path)
            await cache.insert(result, for: key)
            return result
        }

        let diff: FileDiff
        if status.isUntracked {
            if !ignoringCollapse,
               let size = fileSize(path: status.path, in: repository),
               let reason = detector.reason(forPath: status.path,
                                              lineCount: nil, byteCount: size) {
                let result = LoadedDiff.collapsed(reason: reason, path: status.path)
                await cache.insert(result, for: key)
                return result
            }
            diff = try await untrackedDiff(status: status, repository: repository,
                                           ignoringCollapse: ignoringCollapse)
        } else {
            diff = try await repository.diff(path: status.path, staged: staged)
        }

        // 内容读出来之后才知道真实体量，这里再判一次行数与字节数。
        if !ignoringCollapse {
            let lineCount = diff.hunks.reduce(0) { $0 + $1.lines.count }
            if let reason = detector.reason(forPath: status.path,
                                            lineCount: lineCount,
                                            byteCount: diff.estimatedByteCount) {
                let result = LoadedDiff.collapsed(reason: reason, path: status.path)
                await cache.insert(result, for: key)
                return result
            }
        }

        let result = LoadedDiff.ready(diff)
        await cache.insert(result, for: key)
        return result
    }

    /// 未跟踪文件在 git 眼里没有 diff，这里按"整个文件都是新增"合成一个。
    private func untrackedDiff(status: FileStatus, repository: GitRepository,
                               ignoringCollapse: Bool) async throws -> FileDiff {
        let contents = try await repository.fileContents(path: status.path)
        var lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        // 以换行结尾时 split 会多出一个空串，去掉它。
        if contents.hasSuffix("\n"), lines.last == "" { lines.removeLast() }

        let diffLines = lines.enumerated().map { offset, text in
            DiffLine(kind: .addition, oldLineNumber: nil,
                     newLineNumber: offset + 1, text: text)
        }
        let hunk = Hunk(oldStart: 0, oldCount: 0,
                        newStart: 1, newCount: diffLines.count,
                        sectionHeading: "", lines: diffLines)
        return FileDiff(path: status.path, originalPath: nil,
                        content: diffLines.isEmpty ? .empty : .textual([hunk]))
    }

    /// 读内容之前先看文件大小，避免把超大未跟踪文件整份拉进内存。
    private func fileSize(path: String, in repository: GitRepository) -> Int? {
        let url = repository.root.appendingPathComponent(path)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return nil }
        return size.intValue
    }

    private func isCollapsed(_ diff: LoadedDiff) -> Bool {
        if case .collapsed = diff { return true }
        return false
    }
}
