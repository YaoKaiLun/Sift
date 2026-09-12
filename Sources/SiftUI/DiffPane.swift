import SwiftUI
import AppKit
import GitKit
import DiffEngine
import RepoStore
import Highlighter

struct DiffPane: View {
    @Environment(RepoStore.self) private var store
    @State private var confirmsDelete = false

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: store.selectedFile?.fileName ?? "差异",
                       subtitle: subtitle,
                       trailing: { self.headerTrailing })

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.contentBackground)
        .confirmationDialog("删除未跟踪文件？", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let file = store.selectedFile {
                    Task { await store.deleteUntracked(file: file) }
                }
            }
        } message: {
            Text("\(store.selectedFile?.path ?? "")\n此操作无法从 git 恢复。")
        }
        .task(id: "\(store.diffEpoch)-\(store.usesSplitDiff)") {
            await buildDocumentIfNeeded()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.loadedDiff {
        case .none:
            if store.selectedFile == nil {
                PaneEmptyState(title: "选择一个文件", systemImage: "doc.text")
            } else {
                ProgressView().controlSize(.small)
            }
        case .ready(let diff):
            switch diff.content {
            case .empty:
                PaneEmptyState(title: "此文件没有文本差异", systemImage: "equal.circle")
            case .binary:
                PaneEmptyState(title: "二进制文件", systemImage: "doc.badge.gearshape")
            case .modeChangeOnly(let oldMode, let newMode):
                PaneEmptyState(title: "只有文件权限变化",
                               systemImage: "lock.rotation",
                               description: "\(oldMode) → \(newMode)")
            case .textual:
                if let document = store.diffDocument {
                    DiffTextView(document: viewDocument(from: document),
                                 hunkActions: hunkActions)
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

    @ViewBuilder
    private var headerTrailing: some View {
        @Bindable var store = store
        HStack(spacing: 8) {
            if store.selectedFile?.isUntracked == true {
                Button("删除文件") { confirmsDelete = true }
                    .controlSize(.small)
                    .disabled(store.isMutating)
            }
            if let stats = selectedStats {
                HStack(spacing: 6) {
                    Text(store.selectedFileIsStaged ? "已暂存" : "未暂存")
                        .font(Theme.secondaryFont)
                        .foregroundStyle(.secondary)
                    if stats.isBinary {
                        Text("二进制")
                            .font(Theme.secondaryFont)
                            .foregroundStyle(.tertiary)
                    } else {
                        if stats.added > 0 {
                            Text("+\(stats.added)")
                                .font(Theme.secondaryFont.monospacedDigit())
                                .foregroundStyle(.green)
                        }
                        if stats.deleted > 0 {
                            Text("−\(stats.deleted)")
                                .font(Theme.secondaryFont.monospacedDigit())
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            PlainIconToggle(selection: $store.usesSplitDiff,
                            falseIcon: "rectangle.split.1x2",
                            trueIcon: "rectangle.split.2x1",
                            help: "切换统一视图与分栏视图")
        }
    }

    /// 栏头第二行放目录，文件名单独出来，避免长路径把文件名挤没。
    private var subtitle: String? {
        guard let path = store.selectedFile?.path else { return nil }
        let parts = path.split(separator: "/")
        guard parts.count > 1 else { return nil }
        return parts.dropLast().joined(separator: "/")
    }

    private var selectedStats: LineStats? {
        guard let path = store.selectedFile?.path else { return nil }
        return store.selectedFileIsStaged
            ? store.stagedLineStats[path]
            : store.unstagedLineStats[path]
    }

    private var hunkActions: HunkActions? {
        guard let file = store.selectedFile, !file.isUntracked else { return nil }
        let enabled = !store.isMutating
        if store.selectedFileIsStaged {
            return HunkActions(
                showsStage: false,
                showsUnstage: true,
                showsDiscard: false,
                isEnabled: enabled,
                onStage: { _ in },
                onUnstage: { id in performHunk(id) { await store.unstage(hunk: $0) } },
                onDiscard: { _ in }
            )
        }
        return HunkActions(
            showsStage: true,
            showsUnstage: false,
            showsDiscard: true,
            isEnabled: enabled,
            onStage: { id in performHunk(id) { await store.stage(hunk: $0) } },
            onUnstage: { _ in },
            onDiscard: { id in performHunk(id) { await store.discard(hunk: $0) } }
        )
    }

    private func performHunk(_ id: String, _ body: @escaping (Hunk) async -> Void) {
        guard case .ready(let diff) = store.loadedDiff,
              let hunk = diff.hunks.first(where: { $0.id == id }) else { return }
        Task { await body(hunk) }
    }

    /// RepoStore 与 SiftUI 各持有一份 DiffDocument（避免模块循环），字段一一对应。
    private func viewDocument(from stored: RepoStore.DiffDocument) -> DiffDocument {
        DiffDocument(
            text: stored.text,
            splitRight: stored.splitRight,
            hunkHeaders: stored.hunkHeaders.map { DiffHunkHeader(id: $0.id, range: $0.range) }
        )
    }

    private func storeDocument(from built: DiffDocument) -> RepoStore.DiffDocument {
        RepoStore.DiffDocument(
            text: built.text,
            splitRight: built.splitRight,
            hunkHeaders: built.hunkHeaders.map { RepoStore.DiffHunkHeader(id: $0.id, range: $0.range) }
        )
    }

    @MainActor
    private func buildDocumentIfNeeded() async {
        let epoch = store.diffEpoch
        guard case .ready(let diff) = store.loadedDiff,
              case .textual = diff.content else { return }
        let file = store.selectedFile
        let staged = store.selectedFileIsStaged
        let layout: DiffLayout = store.usesSplitDiff ? .split : .unified
        let built = await DiffDocumentBuilder.buildOffMainActor(diff, layout: layout)
        guard store.diffEpoch == epoch,
              store.selectedFile == file,
              store.selectedFileIsStaged == staged,
              (store.usesSplitDiff ? DiffLayout.split : DiffLayout.unified) == layout else { return }
        store.updateDiffDocument(storeDocument(from: built), epoch: epoch)

        let path = file?.path ?? ""
        let highlightTask = Task.detached(priority: .userInitiated) {
            let highlighter = Highlighter()
            let left = DiffSyntaxHighlight.paint(built.text, path: path, highlighter: highlighter)
            let right = built.splitRight.map {
                DiffSyntaxHighlight.paint($0, path: path, highlighter: highlighter)
            }
            return DiffDocument(text: left, splitRight: right, hunkHeaders: built.hunkHeaders)
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
                      highlighter: Highlighter) -> NSAttributedString {
        guard !Task.isCancelled else { return text }
        let result = NSMutableAttributedString(attributedString: text)
        let ns = text.string as NSString
        let full = NSRange(location: 0, length: text.length)
        text.enumerateAttribute(.siftRole, in: full) { value, range, stop in
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
        return result
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
            Text("这是生成文件或体积过大的文件（\(reason.explanation)），已默认折叠。")
                .font(Theme.emptyDescriptionFont)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("仍要查看", action: onExpand)
                .controlSize(.small)
        }
        .padding(24)
        .frame(maxWidth: 380)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
