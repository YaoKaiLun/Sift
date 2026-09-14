import SwiftUI
import AppKit
import GitKit
import DiffEngine
import RepoStore

struct FileListPane: View {
    @Environment(RepoStore.self) private var store
    @Environment(\.trafficLightInset) private var trafficLightInset
    @Binding var showsSidebar: Bool
    @State private var collapsedDirectories: Set<String> = []
    @State private var hoveredRow: String?
    @State private var confirmsDelete = false
    @State private var filesPendingDelete: [FileStatus] = []
    @State private var showsFilterEditor = false

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            PaneHeader(title: "改动",
                       subtitle: store.selectedCommit?.shortSHA ?? store.selectedWorktree?.displayName,
                       showsDivider: true,
                       leadingInset: showsSidebar ? 0 : trafficLightInset,
                       leading: {
                PlainIconButton(systemName: "sidebar.left", help: "显示或隐藏侧边栏") {
                    showsSidebar.toggle()
                }
            },
                       trailing: {
                HStack(spacing: 2) {
                    PlainIconButton(systemName: "line.3.horizontal.decrease",
                                    isSelected: store.hidesFilteredFiles,
                                    help: "隐藏已过滤的文件") {
                        store.hidesFilteredFiles.toggle()
                    }
                    PlainIconButton(systemName: "slider.horizontal.3",
                                    isSelected: showsFilterEditor,
                                    help: "编辑过滤规则") {
                        showsFilterEditor.toggle()
                    }
                    .popover(isPresented: $showsFilterEditor, arrowEdge: .bottom) {
                        FileFilterEditor()
                    }
                    PlainIconToggle(selection: $store.usesTreeView,
                                    falseIcon: "list.bullet",
                                    trueIcon: "list.bullet.indent",
                                    help: "切换平铺视图与树视图")
                }
            })

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let commit = store.selectedCommit {
                        CommitMessageBlock(subject: commit.subject, body: commit.body)
                    }
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            view(for: row)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .background {
                FileListKeyMonitor(orderedIDs: orderedFileIDs) { delta, extending in
                    Task {
                        await store.selectAdjacentFile(
                            delta: delta, extending: extending, orderedIDs: orderedFileIDs)
                    }
                }
            }
            .overlay {
                if store.selectedWorktree == nil {
                    PaneEmptyState(title: "选择一个工作树", systemImage: "sidebar.left")
                } else if store.fileStatuses.isEmpty && !store.isLoadingFileList {
                    PaneEmptyState(title: "没有改动", systemImage: "checkmark.circle")
                } else if store.visibleFileStatuses.isEmpty && !store.isLoadingFileList {
                    PaneEmptyState(title: "过滤后没有文件", systemImage: "line.3.horizontal.decrease")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.contentBackground)
        .confirmationDialog(deleteDialogTitle, isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                let files = filesPendingDelete
                Task { await store.deleteUntracked(files: files) }
            }
                .disabled(store.isMutating)
        } message: {
            Text(deleteDialogMessage)
        }
    }

    // MARK: - 行构建
    //
    // 树也先压平成一维数组再交给 LazyVStack。这样每一行的高度、
    // 左右固定栏都由同一段代码决定，不会出现 DisclosureGroup 自带的另一套间距。

    private var rows: [Row] {
        var result: [Row] = []
        if store.selectedCommit != nil {
            append(&result, title: "改动",
                   statuses: store.visibleFileStatuses.sorted(by: FileStatus.pathOrder),
                   staged: false)
            return result
        }
        append(&result, title: "已暂存",
               statuses: store.visibleFileStatuses.filter(\.hasStagedChanges).sorted(by: FileStatus.pathOrder),
               staged: true)
        append(&result, title: "未暂存",
               statuses: store.visibleFileStatuses.filter(\.hasWorkingTreeChanges).sorted(by: FileStatus.pathOrder),
               staged: false)
        return result
    }

    private var showsFileCheckboxes: Bool { store.selectedCommit == nil }

    private func append(_ rows: inout [Row], title: String, statuses: [FileStatus], staged: Bool) {
        guard !statuses.isEmpty else { return }
        let prefix = staged ? "s" : "u"
        rows.append(Row(id: "\(prefix):section:\(title)", depth: 0,
                        kind: .section(title: title, count: statuses.count, isFirst: rows.isEmpty)))
        if store.usesTreeView {
            let nodes = FileTreeBuilder.build(from: statuses, collapsingSingleChildDirectories: false)
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
                                kind: .directory(name: name, collapsed: collapsed,
                                                 files: children.flatMap(\.descendantFiles),
                                                 staged: staged)))
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
        case .directory(let name, let collapsed, let files, let staged):
            directoryRow(id: row.id, name: name, depth: row.depth, collapsed: collapsed,
                         files: files, staged: staged)
        case .file(let status, let staged, let showsDirectory):
            fileRow(id: row.id, status: status, staged: staged,
                    depth: row.depth, showsDirectory: showsDirectory)
        }
    }

    private func directoryRow(id: String, name: String, depth: Int, collapsed: Bool,
                              files: [FileStatus], staged: Bool) -> some View {
        HStack(spacing: Theme.rowSpacing) {
            if showsFileCheckboxes {
                Toggle("", isOn: Binding(
                    get: { staged },
                    set: { _ in
                        Task {
                            if staged {
                                await store.unstage(files: files)
                            } else {
                                await store.stage(files: files)
                            }
                        }
                    }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .frame(width: Theme.checkboxColumnWidth)
                .disabled(store.isMutating || files.isEmpty)
            }
            HStack(spacing: Theme.rowSpacing) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .frame(width: Theme.disclosureColumnWidth)
                Image(systemName: "folder.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.blue)
                    .frame(width: Theme.statusColumnWidth, height: Theme.statusChipSize.height)
                Text(name)
                    .font(Theme.pathFont)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(depth) * Theme.indentWidth)
            .contentShape(Rectangle())
            .onTapGesture {
                if collapsed {
                    collapsedDirectories.remove(id)
                } else {
                    collapsedDirectories.insert(id)
                }
            }
        }
        .rowSurface(isSelected: false, isHovered: hoveredRow == id)
        .pointerCursor()
        .onHover { hoveredRow = $0 ? id : nil }
    }

    private func fileRow(id: String, status: FileStatus, staged: Bool,
                         depth: Int, showsDirectory: Bool) -> some View {
        let selected = store.isFileSelected(status, staged: staged)
        let stats: LineStats? = {
            if store.selectedCommit != nil { return store.stagedLineStats[status.path] }
            return staged ? store.stagedLineStats[status.path] : store.unstagedLineStats[status.path]
        }()
        let kind = store.selectedCommit != nil
            ? status.indexStatus
            : (staged ? status.indexStatus : status.worktreeStatus)
        return HStack(spacing: Theme.rowSpacing) {
            if showsFileCheckboxes {
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
            }
            HStack(spacing: Theme.rowSpacing) {
                if !showsDirectory {
                    Color.clear.frame(width: Theme.disclosureColumnWidth)
                }
                StatusBadge(kind: kind)
                    .frame(width: Theme.statusColumnWidth)
                Text(showsDirectory ? status.path : status.fileName)
                    .font(Theme.pathFont)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(showsDirectory ? .head : .middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                LineStatsBadge(stats: stats)
                    .frame(width: Theme.statsColumnWidth, alignment: .trailing)
            }
            .padding(.leading, showsDirectory ? 0 : CGFloat(depth) * Theme.indentWidth)
            .contentShape(Rectangle())
            .onTapGesture {
                handleFileClick(status: status, staged: staged)
            }
        }
        .rowSurface(isSelected: selected, isHovered: hoveredRow == id)
        .pointerCursor()
        .onHover { hoveredRow = $0 ? id : nil }
        .untrackedDeleteContextMenu(
            targets: deleteTargets(for: status, staged: staged),
            isMutating: store.isMutating
        ) { targets in
            filesPendingDelete = targets
            confirmsDelete = true
        }
    }

    private var orderedFileIDs: [String] {
        rows.compactMap { row in
            guard case .file(let status, let staged, _) = row.kind else { return nil }
            return RepoStore.fileSelectionID(
                path: status.path, staged: staged, commitSHA: store.selectedCommit?.sha)
        }
    }

    private func handleFileClick(status: FileStatus, staged: Bool) {
        let id = RepoStore.fileSelectionID(
            path: status.path, staged: staged, commitSHA: store.selectedCommit?.sha)
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift) {
            Task { await store.selectFileRange(orderedIDs: orderedFileIDs, to: id, file: status, staged: staged) }
        } else if flags.contains(.command) {
            Task { await store.toggleFileInSelection(status, staged: staged) }
        } else {
            Task { await store.select(file: status, staged: staged) }
        }
    }

    /// 右键若点在已选集合里，就处理整组；否则只处理这一行。菜单只在目标全是未跟踪时出现。
    private func deleteTargets(for status: FileStatus, staged: Bool) -> [FileStatus] {
        let id = RepoStore.fileSelectionID(
            path: status.path, staged: staged, commitSHA: store.selectedCommit?.sha)
        let ids = store.selectedFileIDs.contains(id) ? store.selectedFileIDs : [id]
        let files: [FileStatus] = ids.compactMap { targetID in
            guard let parts = RepoStore.parseFileSelectionID(targetID) else { return nil }
            return store.fileStatuses.first { $0.path == parts.path }
        }
        var unique: [FileStatus] = []
        var seen = Set<String>()
        for file in files where seen.insert(file.path).inserted {
            unique.append(file)
        }
        unique.sort { $0.path < $1.path }
        guard showsFileCheckboxes, !unique.isEmpty, unique.allSatisfy(\.isUntracked) else { return [] }
        return unique
    }

    private var deleteDialogTitle: String {
        filesPendingDelete.count == 1 ? "删除未跟踪文件？" : "删除 \(filesPendingDelete.count) 个未跟踪文件？"
    }

    private var deleteDialogMessage: String {
        let paths = filesPendingDelete.map(\.path).joined(separator: "\n")
        return "\(paths)\n此操作无法从 git 恢复。"
    }

}

private extension View {
    @ViewBuilder
    func untrackedDeleteContextMenu(targets: [FileStatus],
                                    isMutating: Bool,
                                    onDelete: @escaping ([FileStatus]) -> Void) -> some View {
        if targets.isEmpty {
            self
        } else {
            self.contextMenu {
                Button(targets.count == 1 ? "删除文件" : "删除 \(targets.count) 个文件",
                       role: .destructive) {
                    onDelete(targets)
                }
                .disabled(isMutating)
            }
        }
    }
}

private struct Row: Identifiable {
    enum Kind {
        case section(title: String, count: Int, isFirst: Bool)
        case directory(name: String, collapsed: Bool, files: [FileStatus], staged: Bool)
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

struct StatusBadge: View {
    let kind: FileChangeKind

    var body: some View {
        Group {
            if kind == .unmodified {
                Color.clear
            } else {
                FileListChip(fill: FileChangeChrome.fill(for: kind)) {
                    Text(FileChangeChrome.letter(for: kind))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                }
            }
        }
        .frame(width: Theme.statusChipSize.width, height: Theme.statusChipSize.height)
    }
}

/// 文件状态字母色块。
private struct FileListChip<Content: View>: View {
    let fill: Color
    @ViewBuilder var content: Content

    var body: some View {
        content
            .foregroundStyle(.white)
            .frame(width: Theme.statusChipSize.width, height: Theme.statusChipSize.height)
            .background(
                fill,
                in: RoundedRectangle(cornerRadius: Theme.statusChipCornerRadius, style: .continuous)
            )
    }
}

enum FileChangeChrome {
    static func letter(for kind: FileChangeKind) -> String {
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

    static func nsFill(for kind: FileChangeKind) -> NSColor {
        switch kind {
        case .added: .systemGreen
        case .deleted: .systemRed
        case .untracked, .renamed, .copied: .systemPurple
        case .unmerged: .systemOrange
        case .unmodified: .clear
        default: .controlAccentColor
        }
    }

    static func fill(for kind: FileChangeKind) -> Color {
        Color(nsColor: nsFill(for: kind))
    }

    static func drawChip(kind: FileChangeKind, at origin: NSPoint) {
        guard kind != .unmodified else { return }
        let rect = NSRect(origin: origin, size: Theme.statusChipSize)
        let path = NSBezierPath(roundedRect: rect,
                                xRadius: Theme.statusChipCornerRadius,
                                yRadius: Theme.statusChipCornerRadius)
        nsFill(for: kind).setFill()
        path.fill()
        let letter = letter(for: kind) as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = letter.size(withAttributes: attrs)
        letter.draw(
            at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
            withAttributes: attrs)
    }
}
