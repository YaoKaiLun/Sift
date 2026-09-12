import SwiftUI
import GitKit
import DiffEngine
import RepoStore

struct FileListPane: View {
    @Environment(RepoStore.self) private var store

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            List {
                group(title: "已暂存", statuses: store.fileStatuses.filter(\.hasStagedChanges), staged: true)
                group(title: "未暂存", statuses: store.fileStatuses.filter(\.hasUnstagedChanges), staged: false)
                group(title: "未跟踪", statuses: store.fileStatuses.filter(\.isUntracked), staged: false)
            }
            .listStyle(.inset)
            .overlay {
                if store.fileStatuses.isEmpty && !store.isLoadingFileList {
                    ContentUnavailableView("没有改动", systemImage: "checkmark.circle")
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Picker("", selection: $store.usesTreeView) {
                    Image(systemName: "list.bullet").tag(false)
                    Image(systemName: "list.bullet.indent").tag(true)
                }
                .pickerStyle(.segmented)
                .help("切换平铺视图与树视图")
            }
        }
    }

    @ViewBuilder
    private func group(title: String, statuses: [FileStatus], staged: Bool) -> some View {
        if !statuses.isEmpty {
            Section(title) {
                if store.usesTreeView {
                    let nodes = FileTreeBuilder.build(
                        from: statuses, collapsingSingleChildDirectories: true)
                    ForEach(nodes.map { (id: treeIdentity($0, staged: staged), node: $0) },
                            id: \.id) { item in
                        FileTreeNodeView(node: item.node, staged: staged)
                    }
                } else {
                    ForEach(statuses.map { (id: fileIdentity($0, staged: staged), status: $0) },
                            id: \.id) { item in
                        FileRowView(status: item.status, staged: staged, showsFullPath: true)
                    }
                }
            }
        }
    }

}

private struct FileTreeNodeView: View {
    let node: FileTreeNode
    let staged: Bool

    var body: some View {
        switch node {
        case .file(let status):
            FileRowView(status: status, staged: staged, showsFullPath: false)
        case .directory(let name, _, let children):
            DisclosureGroup {
                ForEach(children.map { (id: treeIdentity($0, staged: staged), node: $0) },
                        id: \.id) { item in
                    FileTreeNodeView(node: item.node, staged: staged)
                }
            } label: {
                Label(name, systemImage: "folder")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct FileRowView: View {
    @Environment(RepoStore.self) private var store
    let status: FileStatus
    let staged: Bool
    let showsFullPath: Bool

    var body: some View {
        let isSelected = store.selectedFile?.path == status.path
            && store.selectedFileIsStaged == staged
        return HStack(spacing: 6) {
            StatusBadge(kind: staged ? status.indexStatus : status.worktreeStatus)
            Text(showsFullPath ? status.path : status.fileName)
                .font(Theme.interfaceFont)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 8)
            if let stats = (staged ? store.stagedLineStats : store.unstagedLineStats)[status.path] {
                LineStatsBadge(stats: stats)
            }
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .background(isSelected ? Color.accentColor.opacity(0.15) : .clear)
        .onTapGesture {
            Task { await store.select(file: status, staged: staged) }
        }
    }
}

private struct LineStatsBadge: View {
    let stats: LineStats

    var body: some View {
        if stats.isBinary {
            Text("二进制")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else {
            HStack(spacing: 4) {
                if stats.added > 0 {
                    Text("+\(stats.added)")
                        .foregroundStyle(.green)
                }
                if stats.deleted > 0 {
                    Text("−\(stats.deleted)")
                        .foregroundStyle(.red)
                }
            }
            .font(.caption.monospacedDigit())
        }
    }
}

private struct StatusBadge: View {
    let kind: FileChangeKind

    var body: some View {
        Text(letter)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
            .frame(width: 14)
    }

    private var letter: String {
        switch kind {
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .copied: "C"
        case .typeChanged: "T"
        case .unmerged: "U"
        case .untracked: "?"
        case .unmodified: " "
        }
    }

    private var color: Color {
        switch kind {
        case .added, .untracked: .green
        case .deleted: .red
        case .renamed, .copied: .purple
        case .unmerged: .orange
        default: .accentColor
        }
    }
}

/// 同一路径可以同时出现在已暂存和未暂存两组，List 身份必须带上 staged。
private func fileIdentity(_ status: FileStatus, staged: Bool) -> String {
    "\(staged ? "s" : "u"):\(status.path)"
}

private func treeIdentity(_ node: FileTreeNode, staged: Bool) -> String {
    let prefix = staged ? "s" : "u"
    switch node {
    case .directory(_, let path, _): return "\(prefix):dir:\(path)"
    case .file(let status): return "\(prefix):file:\(status.path)"
    }
}
