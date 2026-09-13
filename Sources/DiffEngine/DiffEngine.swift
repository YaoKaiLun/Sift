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

    public func invalidate(worktreePath: URL, filePath: String) async {
        await cache.remove(inWorktree: worktreePath, filePath: filePath)
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
        if ImagePath.matches(status.path) {
            diff = await imageDiff(status: status, staged: staged, from: repository)
        } else if status.isUntracked {
            if !ignoringCollapse,
               let size = fileSize(path: status.path, in: repository),
               let reason = detector.reason(forPath: status.path,
                                              lineCount: nil, byteCount: size) {
                let result = LoadedDiff.collapsed(reason: reason, path: status.path)
                await cache.insert(result, for: key)
                return result
            }
            if let prefix = repository.filePrefix(path: status.path),
               GitRepository.looksBinary(prefix) {
                diff = FileDiff(path: status.path, originalPath: nil, content: .binary)
            } else {
                diff = try await untrackedDiff(status: status, repository: repository,
                                               ignoringCollapse: ignoringCollapse)
            }
        } else {
            diff = try await repository.diff(path: status.path, staged: staged)
        }

        // 内容读出来之后才知道真实体量，这里再判一次行数与字节数。
        // 图片没有 hunk，estimatedByteCount 为 0，不会被 500KB 文本规则误伤。
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

    private func imageDiff(status: FileStatus, staged: Bool,
                           from repository: GitRepository) async -> FileDiff {
        let refs = blobRefs(status: status, staged: staged)
        let old = await imageSide(refs.old, from: repository)
        let new = await imageSide(refs.new, from: repository)
        let content: DiffContent = (old == nil && new == nil)
            ? .binary
            : .image(ImageDiff(old: old, new: new))
        return FileDiff(path: status.path, originalPath: status.originalPath, content: content)
    }

    private func imageSide(_ ref: (BlobSource, String)?,
                           from repository: GitRepository) async -> ImageSide? {
        guard let ref else { return nil }
        switch await repository.readBlob(path: ref.1, from: ref.0) {
        case .missing: return nil
        case .tooLarge(let count): return .tooLarge(byteCount: count)
        case .bytes(let data): return .bytes(data)
        }
    }

    /// 按当前选中的 staged 侧决定旧/新 blob。
    private func blobRefs(status: FileStatus, staged: Bool)
        -> (old: (BlobSource, String)?, new: (BlobSource, String)?) {
        let path = status.path
        let original = status.originalPath ?? path
        if status.isUntracked {
            return (nil, (.worktree, path))
        }
        if staged {
            switch status.indexStatus {
            case .added:
                return (nil, (.index, path))
            case .deleted:
                return ((.head, original), nil)
            default:
                return ((.head, original), (.index, path))
            }
        }
        switch status.worktreeStatus {
        case .deleted:
            return ((.index, original), nil)
        case .added:
            return (nil, (.worktree, path))
        default:
            return ((.index, original), (.worktree, path))
        }
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
