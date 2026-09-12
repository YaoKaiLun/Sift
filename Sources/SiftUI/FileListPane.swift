import SwiftUI
import GitKit
import DiffEngine
import RepoStore

struct FileListPane: View {
    @Environment(RepoStore.self) private var store
    @Environment(\.trafficLightInset) private var trafficLightInset
    @Binding var showsSidebar: Bool
    @State private var collapsedDirectories: Set<String> = []
    @State private var hoveredRow: String?

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            PaneHeader(title: "改动",
                       subtitle: store.selectedWorktree?.displayName,
                       showsDivider: true,
                       leadingInset: showsSidebar ? 0 : trafficLightInset,
                       leading: {
                // 槽宽必须等于行里的复选框+状态字母栏，标题才会和文件名同一条竖线。
                Color.clear.frame(width: Theme.checkboxColumnWidth)
                PlainIconButton(systemName: "sidebar.left", help: "显示或隐藏侧边栏") {
                    showsSidebar.toggle()
                }
                .frame(width: Theme.statusColumnWidth)
            },
                       trailing: {
                PlainIconToggle(selection: $store.usesTreeView,
                                falseIcon: "list.bullet",
                                trueIcon: "list.bullet.indent",
                                help: "切换平铺视图与树视图")
            })

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        view(for: row)
                    }
                }
                .padding(.vertical, 4)
            }
            .overlay {
                if store.selectedWorktree == nil {
                    PaneEmptyState(title: "选择一个工作树", systemImage: "sidebar.left")
                } else if store.fileStatuses.isEmpty && !store.isLoadingFileList {
                    PaneEmptyState(title: "没有改动", systemImage: "checkmark.circle")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.contentBackground)
    }

    // MARK: - 行构建
    //
    // 树也先压平成一维数组再交给 LazyVStack。这样每一行的高度、
    // 左右固定栏都由同一段代码决定，不会出现 DisclosureGroup 自带的另一套间距。

    private var rows: [Row] {
        var result: [Row] = []
        append(&result, title: "已暂存",
               statuses: store.fileStatuses.filter(\.hasStagedChanges), staged: true)
        append(&result, title: "未暂存",
               statuses: store.fileStatuses.filter(\.hasUnstagedChanges), staged: false)
        append(&result, title: "未跟踪",
               statuses: store.fileStatuses.filter(\.isUntracked), staged: false)
        return result
    }

    private func append(_ rows: inout [Row], title: String, statuses: [FileStatus], staged: Bool) {
        guard !statuses.isEmpty else { return }
        let prefix = staged ? "s" : "u"
        rows.append(Row(id: "\(prefix):section:\(title)", depth: 0,
                        kind: .section(title: title, count: statuses.count, isFirst: rows.isEmpty)))
        if store.usesTreeView {
            let nodes = FileTreeBuilder.build(from: statuses, collapsingSingleChildDirectories: true)
            appendTree(nodes, prefix: prefix, staged: staged, depth: 0, into: &rows)
        } else {
            for status in statuses {
                rows.append(Row(id: "\(prefix):file:\(status.path)", depth: 0,
                                kind: .file(status: status, staged: staged, showsDirectory: true)))
            }
        }
    }

    private func appendTree(_ nodes: [FileTreeNode], prefix: String, staged: Bool,
                            depth: Int, into rows: inout [Row]) {
        for node in nodes {
            switch node {
            case .file(let status):
                rows.append(Row(id: "\(prefix):file:\(status.path)", depth: depth,
                                kind: .file(status: status, staged: staged, showsDirectory: false)))
            case .directory(let name, let path, let children):
                let id = "\(prefix):dir:\(path)"
                let collapsed = collapsedDirectories.contains(id)
                rows.append(Row(id: id, depth: depth,
                                kind: .directory(name: name, collapsed: collapsed)))
                if !collapsed {
                    appendTree(children, prefix: prefix, staged: staged,
                               depth: depth + 1, into: &rows)
                }
            }
        }
    }

    @ViewBuilder
    private func view(for row: Row) -> some View {
        switch row.kind {
        case .section(let title, let count, let isFirst):
            SectionHeaderRow(title: title, count: count, isFirst: isFirst)
        case .directory(let name, let collapsed):
            directoryRow(id: row.id, name: name, depth: row.depth, collapsed: collapsed)
        case .file(let status, let staged, let showsDirectory):
            fileRow(id: row.id, status: status, staged: staged,
                    depth: row.depth, showsDirectory: showsDirectory)
        }
    }

    private func directoryRow(id: String, name: String, depth: Int, collapsed: Bool) -> some View {
        HStack(spacing: Theme.rowSpacing) {
            Color.clear.frame(width: Theme.checkboxColumnWidth)
            Color.clear.frame(width: Theme.statusColumnWidth)
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(collapsed ? 0 : 90))
                .frame(width: 10)
            Text(name)
                .font(Theme.pathFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(depth) * Theme.indentWidth)
        .rowSurface(isSelected: false, isHovered: hoveredRow == id)
        .pointerCursor()
        .onHover { hoveredRow = $0 ? id : nil }
        .onTapGesture {
            if collapsed {
                collapsedDirectories.remove(id)
            } else {
                collapsedDirectories.insert(id)
            }
        }
    }

    private func fileRow(id: String, status: FileStatus, staged: Bool,
                         depth: Int, showsDirectory: Bool) -> some View {
        let selected = store.selectedFile?.path == status.path
            && store.selectedFileIsStaged == staged
        let stats = staged ? store.stagedLineStats[status.path] : store.unstagedLineStats[status.path]
        return HStack(spacing: Theme.rowSpacing) {
            Toggle("", isOn: Binding(
                get: { staged },
                set: { _ in
                    Task {
                        if staged {
                            await store.unstage(file: status)
                        } else {
                            await store.stage(file: status)
                        }
                    }
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .frame(width: Theme.checkboxColumnWidth)
            .disabled(store.isMutating)
            HStack(spacing: Theme.rowSpacing) {
                StatusBadge(kind: staged ? status.indexStatus : status.worktreeStatus)
                    .frame(width: Theme.statusColumnWidth)
                Text(showsDirectory ? status.path : status.fileName)
                    .font(Theme.pathFont)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, CGFloat(depth) * Theme.indentWidth)
                LineStatsBadge(stats: stats)
                    .frame(width: Theme.statsColumnWidth, alignment: .trailing)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                Task { await store.select(file: status, staged: staged) }
            }
        }
        .rowSurface(isSelected: selected, isHovered: hoveredRow == id)
        .pointerCursor()
        .onHover { hoveredRow = $0 ? id : nil }
    }

}

private struct Row: Identifiable {
    enum Kind {
        case section(title: String, count: Int, isFirst: Bool)
        case directory(name: String, collapsed: Bool)
        case file(status: FileStatus, staged: Bool, showsDirectory: Bool)
    }

    /// 同一路径可以同时出现在已暂存和未暂存两组，身份必须带上 staged 前缀。
    let id: String
    let depth: Int
    let kind: Kind
}

private struct LineStatsBadge: View {
    let stats: LineStats?

    var body: some View {
        Group {
            if let stats, stats.isBinary {
                Text("二进制")
                    .foregroundStyle(.tertiary)
            } else if let stats {
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
            }
        }
        .font(Theme.secondaryFont.monospacedDigit())
        .lineLimit(1)
    }
}

private struct StatusBadge: View {
    let kind: FileChangeKind

    var body: some View {
        Text(letter)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity)
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
