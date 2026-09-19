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
        try await load(status: status, side: .workingTree(staged: staged), from: repository)
    }

    public func loadIgnoringCollapse(status: FileStatus, staged: Bool,
                                     from repository: GitRepository) async throws -> LoadedDiff {
        try await load(status: status, side: .workingTree(staged: staged),
                       from: repository, ignoringCollapse: true)
    }

    public func load(status: FileStatus, side: DiffSide,
                     from repository: GitRepository,
                     parent: String? = nil,
                     ignoringCollapse: Bool = false) async throws -> LoadedDiff {
        let key = DiffCacheKey(worktreePath: repository.root,
                               filePath: status.path, side: side)

        if let cached = await cache.value(for: key) {
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
            diff = await imageDiff(status: status, side: side, parent: parent, from: repository)
        } else if case .workingTree = side, status.isUntracked {
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
            switch side {
            case .workingTree(let staged):
                diff = try await repository.diff(path: status.path, staged: staged)
            case .commit(let sha):
                diff = try await repository.diff(path: status.path, from: parent, to: sha)
            case .stash(let selector):
                diff = try await repository.stashDiff(path: status.path, selector: selector)
            }
        }

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

    public func loadIgnoringCollapse(status: FileStatus, side: DiffSide,
                                     from repository: GitRepository,
                                     parent: String? = nil) async throws -> LoadedDiff {
        try await load(status: status, side: side, from: repository,
                       parent: parent, ignoringCollapse: true)
    }

    public func invalidate(worktreePath: URL) async {
        await cache.removeAll(inWorktree: worktreePath)
    }

    public func invalidate(worktreePath: URL, filePath: String) async {
        await cache.remove(inWorktree: worktreePath, filePath: filePath)
    }

    private func imageDiff(status: FileStatus, side: DiffSide, parent: String?,
                           from repository: GitRepository) async -> FileDiff {
        let refs = blobRefs(status: status, side: side, parent: parent)
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

    private func blobRefs(status: FileStatus, side: DiffSide, parent: String?)
        -> (old: (BlobSource, String)?, new: (BlobSource, String)?) {
        let path = status.path
        let original = status.originalPath ?? path
        if case .commit(let sha) = side {
            let old: (BlobSource, String)? = parent.map { (.revision($0), original) }
            let new: (BlobSource, String)? = status.indexStatus == .deleted
                ? nil : (.revision(sha), path)
            return (old, new)
        }
        if case .stash(let selector) = side {
            let old: (BlobSource, String)? = parent.map { (.revision($0), original) }
            if status.indexStatus == .deleted {
                return (old, nil)
            }
            let spec = status.indexStatus == .added ? "\(selector)^3" : selector
            return (old, (.revision(spec), path))
        }
        let staged: Bool
        if case .workingTree(let value) = side { staged = value } else { staged = false }
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
