import SwiftUI
import AppKit
import GitKit
import DiffEngine
import RepoStore
import Highlighter
import SiftLocalization

struct DiffPane: View {
    @Environment(RepoStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var blameLines: [BlameLine] = []
    @State private var continuousBlame: [String: [BlameLine]] = [:]
    @State private var blamedWorktreePath = ""
    @State private var visibleContinuousFileID: String?

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: headerTitle,
                       subtitle: nil,
                       showsDivider: true,
                       leading: { headerLeading },
                       trailing: { self.headerTrailing })

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.contentBackground)
        .task(id: store.usesContinuousDiff) {
            if !store.usesContinuousDiff {
                visibleContinuousFileID = nil
            }
            await store.handleBrowseModeChange()
        }
        .task(id: "\(store.diffEpoch)-\(store.usesContinuousDiff)") {
            if store.usesContinuousDiff {
                await buildContinuousDocumentIfNeeded()
            } else {
                await buildDocumentIfNeeded()
            }
        }
        .task(id: blameTaskID) {
            await loadBlameIfNeeded()
        }
        .task(id: store.continuousRevealID) {
            if let id = store.continuousRevealID {
                visibleContinuousFileID = id
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.usesContinuousDiff {
            continuousContent
        } else {
            singleFileContent
        }
    }

    @ViewBuilder
    private var continuousContent: some View {
        if store.selectedWorktree == nil {
            PaneEmptyState(title: L10n.selectFile, systemImage: "doc.text")
        } else if store.fileStatuses.isEmpty && !store.isLoadingFileList {
            PaneEmptyState(title: L10n.noChanges, systemImage: "checkmark.circle")
        } else if let document = store.diffDocument {
            diffStack(document: document)
        } else if !store.continuousPlan.isEmpty || store.isLoadingFileList {
            ProgressView().controlSize(.small)
        } else {
            PaneEmptyState(title: L10n.noChanges, systemImage: "checkmark.circle")
        }
    }

    @ViewBuilder
    private var singleFileContent: some View {
        switch store.loadedDiff {
        case .none:
            if store.selectedFile == nil {
                PaneEmptyState(title: L10n.selectFile, systemImage: "doc.text")
            } else {
                ProgressView().controlSize(.small)
            }
        case .ready(let diff):
            switch diff.content {
            case .empty:
                PaneEmptyState(title: L10n.noTextDiff, systemImage: "equal.circle")
            case .binary:
                PaneEmptyState(title: L10n.binaryFile, systemImage: "doc.badge.gearshape")
            case .image(let image):
                ImageDiffView(image: image)
            case .modeChangeOnly(let oldMode, let newMode):
                PaneEmptyState(title: L10n.modeChangeOnly,
                               systemImage: "lock.rotation",
                               description: "\(oldMode) → \(newMode)")
            case .textual:
                if let document = store.diffDocument {
                    diffStack(document: document)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        case .collapsed(let reason, let path):
            CollapsedFileView(path: path, reason: reason) {
                Task { await store.expandCollapsedDiff() }
            }
        }
    }

    private func diffStack(document: RepoStore.DiffDocument) -> some View {
        HStack(spacing: 0) {
            DiffTextView(document: viewDocument(from: document),
                         hunkActions: hunkActions,
                         onSelectionChange: { store.updateExplainSelection($0) },
                         onExplain: { selected, surrounding in
                             store.startExplain(selectedText: selected,
                                                surroundingText: surrounding)
                         },
                         codeReferencePath: store.selectedFile?.path ?? "",
                         onVisibleRangeChange: store.usesContinuousDiff ? { range in
                             let fileRanges = Dictionary(uniqueKeysWithValues:
                                document.fileHeaders.map { ($0.id, $0.range) })
                             store.loadContinuousEntries(visibleRange: range, fileRanges: fileRanges)
                             let headers = document.fileHeaders.map {
                                 DiffFileHeader(id: $0.id, range: $0.range,
                                                isPlaceholder: $0.isPlaceholder,
                                                isCollapsed: $0.isCollapsed)
                             }
                             let next = DiffDocumentBuilder.fileID(
                                atCharacter: range.location, in: headers)
                             if visibleContinuousFileID != next {
                                 visibleContinuousFileID = next
                             }
                         } : nil,
                         preserveVisibleRect: store.usesContinuousDiff && store.continuousPreservesScroll,
                         revealRange: revealRange(in: document),
                         onDidReveal: { store.consumeContinuousReveal() },
                         onExpandCollapsedFile: { id in
                             store.expandContinuousCollapsed(id: id)
                         },
                         hunkIsStaged: store.usesContinuousDiff ? { store.hunkIsStaged($0) } : nil,
                         showsBlame: store.showsBlame && !store.usesContinuousDiff,
                         blameByNewLine: blameLookup,
                         blameByFileID: continuousBlameLookup,
                         loadBlameCommit: { line in
                             await loadBlameCommit(line)
                         })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if store.showsExplainPanel {
                Divider()
                ExplainPanel()
                    .frame(width: 320)
                    .transition(reduceMotion ? .identity : .move(edge: .trailing))
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18),
                   value: store.showsExplainPanel)
    }

    private func revealRange(in document: RepoStore.DiffDocument) -> NSRange? {
        guard let id = store.continuousRevealID,
              let header = document.fileHeaders.first(where: { $0.id == id }) else { return nil }
        return header.range
    }

    @ViewBuilder
    private var headerTrailing: some View {
        @Bindable var store = store
        HStack(spacing: 8) {
            PlainIconButton(systemName: "magnifyingglass", help: L10n.find) {
                NotificationCenter.default.post(name: .siftFindInDiff, object: nil)
            }
            PlainIconButton(systemName: "doc.on.doc",
                            isSelected: store.usesContinuousDiff,
                            help: store.usesContinuousDiff ? L10n.switchToSingleFile : L10n.switchToContinuous) {
                store.usesContinuousDiff.toggle()
            }
            PlainIconButton(systemName: store.showsBlame ? "person.crop.circle.fill" : "person.crop.circle",
                            isSelected: store.showsBlame,
                            help: blameHelp) {
                store.showsBlame.toggle()
            }
            .disabled(store.usesContinuousDiff || showsImageDiff)
            .opacity((store.usesContinuousDiff || showsImageDiff) ? 0.4 : 1)
        }
    }

    private var showsImageDiff: Bool {
        if case .ready(let diff) = store.loadedDiff, case .image = diff.content {
            return true
        }
        return false
    }

    private var blameHelp: String {
        if store.usesContinuousDiff { return L10n.blameUnavailableContinuous }
        if showsImageDiff { return L10n.blameUnavailableImage }
        return store.showsBlame ? L10n.hideBlame : L10n.showBlame
    }

    @ViewBuilder
    private var headerLeading: some View {
        if let kind = headerChangeKind {
            StatusBadge(kind: kind)
                .frame(width: Theme.statusColumnWidth)
                .help(headerChangeHelp(kind))
        }
    }

    /// 栏头只放整条路径，文件名不再拆出来。连续滚动跟视口顶部的文件走。
    private var headerTitle: String {
        headerFilePath ?? L10n.diff
    }

    private var headerFilePath: String? {
        if store.usesContinuousDiff, let id = visibleContinuousFileID {
            return Self.path(fromFileID: id)
        }
        return store.selectedFile?.path
    }

    private var headerChangeKind: FileChangeKind? {
        if store.usesContinuousDiff, let id = visibleContinuousFileID {
            let path = Self.path(fromFileID: id)
            guard let file = store.fileStatuses.first(where: { $0.path == path }) else { return nil }
            if id.hasPrefix("c:") || store.isReadingSnapshot {
                return file.indexStatus
            }
            return id.hasPrefix("s:") ? file.indexStatus : file.worktreeStatus
        }
        guard let file = store.selectedFile else { return nil }
        if store.isReadingSnapshot { return file.indexStatus }
        return store.selectedFileIsStaged ? file.indexStatus : file.worktreeStatus
    }

    private func headerChangeHelp(_ kind: FileChangeKind) -> String {
        switch kind {
        case .modified: L10n.modified
        case .added: L10n.added
        case .deleted: L10n.deleted
        case .renamed: L10n.renamed
        case .copied: L10n.copied
        case .typeChanged: L10n.typeChanged
        case .unmerged: L10n.unmerged
        case .untracked: L10n.untracked
        case .unmodified: ""
        }
    }

    private static func path(fromFileID id: String) -> String {
        if id.hasPrefix("c:") {
            let rest = id.dropFirst(2)
            if let colon = rest.firstIndex(of: ":") {
                return String(rest[rest.index(after: colon)...])
            }
        }
        if id.hasPrefix("s:") || id.hasPrefix("u:") {
            return String(id.dropFirst(2))
        }
        return id
    }

    private var hunkActions: HunkActions? {
        if store.isReadingSnapshot { return nil }
        if store.usesContinuousDiff {
            return HunkActions(
                showsStage: true,
                showsUnstage: true,
                showsDiscard: true,
                onStage: { id in performHunk(id) { hunk, file, staged in
                    await store.stage(hunk: hunk, file: file, stagedSide: staged)
                } },
                onUnstage: { id in performHunk(id) { hunk, file, staged in
                    await store.unstage(hunk: hunk, file: file, stagedSide: staged)
                } },
                onDiscard: { id in performHunk(id) { hunk, file, staged in
                    await store.discard(hunk: hunk, file: file, stagedSide: staged)
                } }
            )
        }
        guard let file = store.selectedFile, !file.isUntracked else { return nil }
        if store.selectedFileIsStaged {
            return HunkActions(
                showsStage: false,
                showsUnstage: true,
                showsDiscard: false,
                onStage: { _ in },
                onUnstage: { id in performHunk(id) { hunk, file, staged in
                    await store.unstage(hunk: hunk, file: file, stagedSide: staged)
                } },
                onDiscard: { _ in }
            )
        }
        return HunkActions(
            showsStage: true,
            showsUnstage: false,
            showsDiscard: true,
            onStage: { id in performHunk(id) { hunk, file, staged in
                await store.stage(hunk: hunk, file: file, stagedSide: staged)
            } },
            onUnstage: { _ in },
            onDiscard: { id in performHunk(id) { hunk, file, staged in
                await store.discard(hunk: hunk, file: file, stagedSide: staged)
            } }
        )
    }

    private func performHunk(_ id: String,
                             _ body: @escaping (Hunk, FileStatus, Bool) async -> Void) {
        guard let hunk = store.hunk(matching: id),
              let fileInfo = store.fileForHunk(id: id) else { return }
        Task { await body(hunk, fileInfo.file, fileInfo.staged) }
    }

    /// RepoStore 与 SiftUI 各持有一份 DiffDocument（避免模块循环），字段一一对应。
    private func viewDocument(from stored: RepoStore.DiffDocument) -> DiffDocument {
        DiffDocument(
            text: stored.text,
            splitRight: stored.splitRight,
            hunkHeaders: stored.hunkHeaders.map { DiffHunkHeader(id: $0.id, range: $0.range) },
            fileHeaders: stored.fileHeaders.map {
                DiffFileHeader(id: $0.id, range: $0.range,
                               isPlaceholder: $0.isPlaceholder, isCollapsed: $0.isCollapsed,
                               path: $0.path, added: $0.added, deleted: $0.deleted,
                               changeKind: $0.changeKind)
            }
        )
    }

    private func storeDocument(from built: DiffDocument) -> RepoStore.DiffDocument {
        RepoStore.DiffDocument(
            text: built.text,
            splitRight: built.splitRight,
            hunkHeaders: built.hunkHeaders.map { RepoStore.DiffHunkHeader(id: $0.id, range: $0.range) },
            fileHeaders: built.fileHeaders.map {
                RepoStore.DiffFileHeader(id: $0.id, range: $0.range,
                                         isPlaceholder: $0.isPlaceholder, isCollapsed: $0.isCollapsed,
                                         path: $0.path, added: $0.added, deleted: $0.deleted,
                                         changeKind: $0.changeKind)
            }
        )
    }

    @MainActor
    private func buildDocumentIfNeeded() async {
        let epoch = store.diffEpoch
        guard case .ready(let diff) = store.loadedDiff,
              case .textual = diff.content else { return }
        let file = store.selectedFile
        let staged = store.selectedFileIsStaged
        let layout: DiffLayout = .unified
        let built = await DiffDocumentBuilder.buildOffMainActor(diff, layout: layout)
        guard store.diffEpoch == epoch,
              store.selectedFile == file,
              store.selectedFileIsStaged == staged else { return }
        store.updateDiffDocument(storeDocument(from: built), epoch: epoch)

        let path = file?.path ?? ""
        let highlightTask = Task.detached(priority: .userInitiated) {
            let highlighter = Highlighter()
            let left = DiffSyntaxHighlight.paint(built.text, path: path, highlighter: highlighter)
            let right = built.splitRight.map {
                DiffSyntaxHighlight.paint($0, path: path, highlighter: highlighter)
            }
            return DiffDocument(text: left, splitRight: right, hunkHeaders: built.hunkHeaders,
                                fileHeaders: built.fileHeaders)
        }
        let highlighted = await withTaskCancellationHandler {
            await highlightTask.value
        } onCancel: {
            highlightTask.cancel()
        }
        guard !Task.isCancelled,
              store.diffEpoch == epoch,
              store.selectedFile == file,
              store.selectedFileIsStaged == staged else { return }
        store.updateDiffDocument(storeDocument(from: highlighted), epoch: epoch)
    }

    @MainActor
    private func buildContinuousDocumentIfNeeded() async {
        let epoch = store.diffEpoch
        let layout: DiffLayout = .unified
        let plan = store.continuousPlan
        let loaded = store.continuousLoaded
        let sections = plan.map { entry in (entry, loaded[entry.id]) }
        let built = await DiffDocumentBuilder.buildContinuousOffMainActor(
            sections: sections, layout: layout)
        guard store.diffEpoch == epoch, store.usesContinuousDiff else { return }
        store.updateDiffDocument(storeDocument(from: built), epoch: epoch)

        let highlightTask = Task.detached(priority: .userInitiated) {
            DiffSyntaxHighlight.paintContinuous(built, sections: sections)
        }
        let highlighted = await withTaskCancellationHandler {
            await highlightTask.value
        } onCancel: {
            highlightTask.cancel()
        }
        guard !Task.isCancelled,
              store.diffEpoch == epoch,
              store.usesContinuousDiff else { return }
        store.updateDiffDocument(storeDocument(from: highlighted), epoch: epoch)
    }

    private var blameTaskID: String {
        if !store.showsBlame || store.usesContinuousDiff || showsImageDiff { return "off" }
        let worktree = store.selectedWorktree?.path.path ?? ""
        if store.usesContinuousDiff {
            let ids = store.continuousLoaded.compactMap { id, loaded -> String? in
                if case .ready = loaded { return id }
                return nil
            }.sorted().joined(separator: ",")
            return "c:\(worktree)|\(ids)"
        }
        return "s:\(store.diffEpoch):\(worktree)|\(store.selectedFile?.path ?? "")|\(store.selectedFileIsStaged)"
    }

    private var blameLookup: [Int: BlameLine] {
        Dictionary(blameLines.map { ($0.newLineNumber, $0) }, uniquingKeysWith: { _, last in last })
    }

    private var continuousBlameLookup: [String: [Int: BlameLine]] {
        Dictionary(uniqueKeysWithValues: continuousBlame.map { id, lines in
            (id, Dictionary(lines.map { ($0.newLineNumber, $0) }, uniquingKeysWith: { _, last in last }))
        })
    }

    @MainActor
    private func loadBlameIfNeeded() async {
        guard store.showsBlame, !store.usesContinuousDiff else {
            blameLines = []
            continuousBlame = [:]
            return
        }
        if showsImageDiff {
            blameLines = []
            continuousBlame = [:]
            return
        }
        guard let worktree = store.selectedWorktree else {
            blameLines = []
            continuousBlame = [:]
            return
        }
        let repo = GitRepository(root: worktree.path)
        if blamedWorktreePath != worktree.path.path {
            blameLines = []
            continuousBlame = [:]
            blamedWorktreePath = worktree.path.path
        }
        if store.usesContinuousDiff {
            blameLines = []
            let loadedIDs = Set(store.continuousLoaded.keys)
            continuousBlame = continuousBlame.filter { loadedIDs.contains($0.key) }
            for (id, loaded) in store.continuousLoaded {
                if Task.isCancelled { return }
                guard case .ready = loaded,
                      let entry = store.continuousPlan.first(where: { $0.id == id }),
                      !entry.status.isUntracked else {
                    continuousBlame.removeValue(forKey: id)
                    continue
                }
                if continuousBlame[id] != nil { continue }
                let lines = await repo.blame(path: entry.status.path, staged: entry.staged)
                guard !Task.isCancelled else { return }
                continuousBlame[id] = lines
            }
            return
        }
        continuousBlame = [:]
        guard let file = store.selectedFile, !file.isUntracked else {
            blameLines = []
            return
        }
        if store.isReadingSnapshot, store.commitParentSHA == nil {
            blameLines = []
            return
        }
        blameLines = []
        let lines = await repo.blame(
            path: file.path,
            staged: store.selectedFileIsStaged,
            revision: store.isReadingSnapshot ? store.commitParentSHA : nil)
        guard !Task.isCancelled else { return }
        blameLines = lines
    }

    private func loadBlameCommit(_ line: BlameLine) async -> BlameCommitContent {
        let timeText = BlameCommitContent.formatted(line.authorTime)
        guard let worktree = store.selectedWorktree,
              let header = await GitRepository(root: worktree.path).showCommitHeader(sha: line.sha) else {
            return BlameCommitContent.fallback(for: line)
        }
        return BlameCommitContent(
            author: line.author,
            timeText: timeText,
            header: header)
    }
}

/// 第三遍：只改 code 列 foregroundColor，其它属性（底色、gutter、role）保持不动。
private enum DiffSyntaxHighlight {
    static func color(for kind: TokenKind) -> NSColor {
        switch kind {
        case .keyword: .systemPurple
        case .string: .systemRed
        case .comment: .secondaryLabelColor
        case .number: .systemBlue
        case .type: .systemTeal
        }
    }

    static func paint(_ text: NSAttributedString,
                      path: String,
                      highlighter: Highlighter,
                      in limit: NSRange? = nil) -> NSAttributedString {
        guard !Task.isCancelled else { return text }
        let result = NSMutableAttributedString(attributedString: text)
        paint(result, path: path, highlighter: highlighter, in: limit)
        return result
    }

    static func paint(_ result: NSMutableAttributedString,
                      path: String,
                      highlighter: Highlighter,
                      in limit: NSRange?) {
        guard !Task.isCancelled else { return }
        let ns = result.string as NSString
        let full = NSRange(location: 0, length: result.length)
        let scope = limit.map { NSIntersectionRange($0, full) } ?? full
        guard scope.length > 0 else { return }
        result.enumerateAttribute(.siftRole, in: scope) { value, range, stop in
            if Task.isCancelled {
                stop.pointee = true
                return
            }
            guard (value as? String) == "code" else { return }
            let lineText = ns.substring(with: range)
            for span in highlighter.tokens(in: lineText, path: path) {
                let painted = NSRange(
                    location: range.location + span.range.lowerBound,
                    length: span.range.count)
                guard painted.location >= range.location,
                      NSMaxRange(painted) <= NSMaxRange(range) else { continue }
                result.addAttribute(.foregroundColor, value: color(for: span.kind), range: painted)
            }
        }
    }

    static func paintContinuous(
        _ document: DiffDocument,
        sections: [(ContinuousDiffEntry, LoadedDiff?)]
    ) -> DiffDocument {
        guard !Task.isCancelled else { return document }
        let highlighter = Highlighter()
        let left = NSMutableAttributedString(attributedString: document.text)
        let right = document.splitRight.map { NSMutableAttributedString(attributedString: $0) }
        for (index, header) in document.fileHeaders.enumerated() {
            if Task.isCancelled { return document }
            let path = sections.first(where: { $0.0.id == header.id })?.0.status.path ?? ""
            let start = header.range.location
            let end = index + 1 < document.fileHeaders.count
                ? document.fileHeaders[index + 1].range.location
                : left.length
            let scope = NSRange(location: start, length: max(0, end - start))
            paint(left, path: path, highlighter: highlighter, in: scope)
            if let right {
                paint(right, path: path, highlighter: highlighter, in: scope)
            }
        }
        return DiffDocument(
            text: left,
            splitRight: right,
            hunkHeaders: document.hunkHeaders,
            fileHeaders: document.fileHeaders)
    }
}

private struct CollapsedFileView: View {
    let path: String
    let reason: GeneratedFileReason
    let onExpand: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.zipper")
                .font(Theme.emptySymbolFont)
                .foregroundStyle(.tertiary)
            Text(path)
                .font(Theme.codeFont)
                .lineLimit(1)
                .truncationMode(.head)
            Text(L10n.collapsedNote(reason: reason.explanation))
                .font(Theme.emptyDescriptionFont)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(L10n.viewAnyway, action: onExpand)
                .buttonStyle(BorderedActionButtonStyle())
        }
        .padding(24)
        .frame(maxWidth: 380)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// commit patch 里生成文件 / 超大文件按主视图同一套规则折叠。
enum CommitPatchCollapser {
    static func collapse(_ patch: String, detector: GeneratedFileDetector = GeneratedFileDetector()) -> String {
        guard !patch.isEmpty else { return patch }
        return splitDiffs(patch).map { chunk in
            let path = path(in: chunk) ?? ""
            let lineCount = chunk.split(separator: "\n", omittingEmptySubsequences: false).count
            if let reason = detector.reason(forPath: path, lineCount: lineCount, byteCount: chunk.utf8.count) {
                return collapsedStub(chunk, reason: reason)
            }
            return chunk
        }.joined()
    }

    private static func splitDiffs(_ patch: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "^diff --git ", options: .anchorsMatchLines) else {
            return [patch]
        }
        let ns = patch as NSString
        let matches = regex.matches(in: patch, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [patch] }
        var parts: [String] = []
        if matches[0].range.location > 0 {
            parts.append(ns.substring(to: matches[0].range.location))
        }
        for (index, match) in matches.enumerated() {
            let start = match.range.location
            let end = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
            parts.append(ns.substring(with: NSRange(location: start, length: end - start)))
        }
        return parts
    }

    private static func path(in chunk: String) -> String? {
        for line in chunk.split(separator: "\n") {
            if line.hasPrefix("+++ b/") {
                return String(line.dropFirst(6))
            }
        }
        for line in chunk.split(separator: "\n") {
            if line.hasPrefix("diff --git ") {
                let rest = line.dropFirst("diff --git ".count)
                if let last = rest.split(separator: " ").last, last.hasPrefix("b/") {
                    return String(last.dropFirst(2))
                }
            }
            if line.hasPrefix("--- a/") {
                return String(line.dropFirst(6))
            }
        }
        return nil
    }

    private static func collapsedStub(_ chunk: String, reason: GeneratedFileReason) -> String {
        let header = chunk.split(separator: "\n", omittingEmptySubsequences: false)
            .prefix { !$0.hasPrefix("@@") }
            .joined(separator: "\n")
        let trimmed = header.trimmingCharacters(in: .newlines)
        return trimmed + "\n\(L10n.collapsedStub(reason: reason.explanation))\n"
    }
}

