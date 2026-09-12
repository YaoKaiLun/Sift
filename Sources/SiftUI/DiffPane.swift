import SwiftUI
import GitKit
import DiffEngine
import RepoStore

struct DiffPane: View {
    @Environment(RepoStore.self) private var store

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
        .task(id: store.diffEpoch) {
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
                    DiffTextView(document: document)
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

    @MainActor
    private func buildDocumentIfNeeded() async {
        let epoch = store.diffEpoch
        guard case .ready(let diff) = store.loadedDiff,
              case .textual = diff.content else { return }
        let file = store.selectedFile
        let staged = store.selectedFileIsStaged
        let built = await DiffDocumentBuilder.buildOffMainActor(diff)
        guard store.diffEpoch == epoch,
              store.selectedFile == file,
              store.selectedFileIsStaged == staged else { return }
        store.updateDiffDocument(built, epoch: epoch)
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
