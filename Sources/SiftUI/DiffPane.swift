import SwiftUI
import GitKit
import DiffEngine
import RepoStore

struct DiffPane: View {
    @Environment(RepoStore.self) private var store

    var body: some View {
        Group {
            switch store.loadedDiff {
            case .none:
                if store.selectedFile == nil {
                    ContentUnavailableView("选择一个文件", systemImage: "doc.text")
                } else {
                    ProgressView().controlSize(.small)
                }
            case .ready(let diff):
                switch diff.content {
                case .empty:
                    ContentUnavailableView("此文件没有文本差异", systemImage: "equal.circle")
                case .binary:
                    ContentUnavailableView("二进制文件", systemImage: "doc.badge.gearshape")
                case .modeChangeOnly(let oldMode, let newMode):
                    ContentUnavailableView {
                        Label("只有文件权限变化", systemImage: "lock.rotation")
                    } description: {
                        Text("\(oldMode) → \(newMode)")
                            .font(Theme.codeFont)
                    }
                case .textual:
                    DiffTextView(document: DiffDocumentBuilder.build(diff))
                }
            case .collapsed(let reason, let path):
                CollapsedFileView(path: path, reason: reason) {
                    Task { await store.expandCollapsedDiff() }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(store.selectedFile?.path ?? "")
    }
}

private struct CollapsedFileView: View {
    let path: String
    let reason: GeneratedFileReason
    let onExpand: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.zipper")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(path)
                .font(Theme.codeFont)
                .lineLimit(1)
                .truncationMode(.head)
            Text("这是生成文件或体积过大的文件（\(reason.explanation)），已默认折叠。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("仍要查看", action: onExpand)
                .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .frame(maxWidth: 420)
    }
}
