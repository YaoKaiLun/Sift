import AppKit
import SwiftUI
import GitKit
import RepoStore

public extension Notification.Name {
    static let siftAddRepository = Notification.Name("app.sift.addRepository")
}

struct SourceSidebar: View {
    @Environment(RepoStore.self) private var store
    @Environment(UpdateController.self) private var updates
    @Environment(\.trafficLightInset) private var trafficLightInset
    @State private var collapsedRoots: Set<URL> = []
    @State private var hoveredRow: String?
    @State private var expandedCommitWorktrees: Set<URL> = []

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            PaneHeader(title: "仓库",
                       showsDivider: false,
                       leadingInset: trafficLightInset,
                       trailing: {
                PlainIconButton(systemName: "plus", help: "添加仓库", action: presentOpenPanel)
            })

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(store.repositories.enumerated()), id: \.element.sidebarRowID) { index, repository in
                        repositoryRow(repository, isFirst: index == 0)
                            .id(repository.sidebarRowID)
                        if !collapsedRoots.contains(repository.root) {
                            ForEach(repository.worktrees, id: \.sidebarRowID) { worktree in
                                worktreeRow(worktree)
                                    .id(worktree.sidebarRowID)
                                if store.selectedWorktree?.path == worktree.path,
                                   expandedCommitWorktrees.contains(worktree.path) {
                                    ForEach(store.unpushedCommits) { commit in
                                        commitRow(commit)
                                            .id("commit:\(commit.sha)")
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            .overlay {
                if store.repositories.isEmpty {
                    PaneEmptyState(title: "还没有仓库",
                                   systemImage: "folder.badge.plus",
                                   description: "点右上角的 + 添加")
                }
            }

            HStack(spacing: 2) {
                PlainIconMenu(systemName: store.appearance.symbolName, help: "外观") {
                    Button { store.appearance = .system } label: {
                        Label("跟随系统", systemImage: "circle.lefthalf.filled")
                    }
                    Button { store.appearance = .light } label: {
                        Label("浅色", systemImage: "sun.max")
                    }
                    Button { store.appearance = .dark } label: {
                        Label("深色", systemImage: "moon")
                    }
                }
                updateFooterButton
                PlainIconButton(systemName: "gearshape",
                                isSelected: store.showsExplainSettings,
                                help: "模型配置") {
                    store.showsExplainSettings.toggle()
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.horizontalPadding)
            .padding(.top, 6)
            .padding(.bottom, 12)
            .frame(height: Theme.sidebarFooterHeight, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            Theme.sidebarBackground
                .ignoresSafeArea(.container, edges: .top)
        }
        .onReceive(NotificationCenter.default.publisher(for: .siftAddRepository)) { _ in
            presentOpenPanel()
        }
    }

    private func repositoryRow(_ repository: RepositoryEntry, isFirst: Bool) -> some View {
        let id = "repo:\(repository.root.path)"
        let collapsed = collapsedRoots.contains(repository.root)
        let hovering = hoveredRow == id
        return HStack(spacing: Theme.rowSpacing) {
            ZStack {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .opacity(hovering ? 0 : 1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .opacity(hovering ? 1 : 0)
            }
            .foregroundStyle(.secondary)
            .frame(width: Theme.statusColumnWidth, alignment: .center)
            Text(repository.name)
                .font(Theme.repositoryFont)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .rowSurface(isSelected: false, isHovered: hoveredRow == id,
                    height: Theme.sidebarRowHeight)
        .pointerCursor()
        .padding(.top, isFirst ? 4 : Theme.sidebarGroupGap)
        .onHover { hoveredRow = $0 ? id : nil }
        .onTapGesture { toggleExpanded(repository.root) }
        .contextMenu {
            Button("移除此仓库", role: .destructive) {
                store.removeRepository(root: repository.root)
            }
        }
    }

    private func worktreeRow(_ worktree: Worktree) -> some View {
        let id = "wt:\(worktree.path.path)"
        let isCurrent = store.selectedWorktree?.path == worktree.path
        let selected = isCurrent && store.selectedCommit == nil
        let showsUnpushed = isCurrent && !store.unpushedCommits.isEmpty
        let expanded = expandedCommitWorktrees.contains(worktree.path)
        return HStack(spacing: Theme.rowSpacing) {
            if showsUnpushed {
                Button {
                    if expanded {
                        expandedCommitWorktrees.remove(worktree.path)
                    } else {
                        expandedCommitWorktrees.insert(worktree.path)
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: Theme.disclosureColumnWidth, height: Theme.sidebarRowHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
            Group {
                if worktree.isMain {
                    GitBranchSymbol()
                        .frame(width: 13, height: 14)
                } else {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 11))
                }
            }
            .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .frame(width: Theme.statusColumnWidth, alignment: .center)
            Text(worktree.displayName)
                .font(Theme.interfaceFont)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if showsUnpushed {
                Text("↑\(store.unpushedCommits.count)")
                    .font(Theme.secondaryFont.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            if let count = changeCount(for: worktree), count > 0 {
                Text("\(count)")
                    .font(Theme.secondaryFont.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, Theme.sidebarChildIndent)
        .rowSurface(isSelected: selected, isHovered: hoveredRow == id,
                    height: Theme.sidebarRowHeight)
        .pointerCursor()
        .onHover { hoveredRow = $0 ? id : nil }
        .onTapGesture {
            Task { await store.select(worktree: worktree) }
        }
    }

    private func commitRow(_ commit: CommitInfo) -> some View {
        let id = "commit:\(commit.sha)"
        let selected = store.selectedCommit?.sha == commit.sha
        return HStack(spacing: Theme.rowSpacing) {
            Text(commit.shortSHA)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(commit.subject)
                .font(Theme.interfaceFont)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.leading, Theme.sidebarChildIndent + Theme.statusColumnWidth
                 + Theme.rowSpacing + Theme.indentWidth)
        .rowSurface(isSelected: selected, isHovered: hoveredRow == id,
                    height: Theme.sidebarRowHeight)
        .pointerCursor()
        .onHover { hoveredRow = $0 ? id : nil }
        .onTapGesture {
            Task { await store.select(commit: commit) }
        }
    }

    @ViewBuilder
    private var updateFooterButton: some View {
        switch updates.state {
        case .available(let update):
            Button("更新") { updates.download() }
                .buttonStyle(UpdateCapsuleButtonStyle())
                .help("下载 \(update.version.description)")
        case .downloading:
            Button("下载中…") {}
                .buttonStyle(UpdateCapsuleButtonStyle())
                .disabled(true)
        case .ready:
            Button("重启") { updates.restart() }
                .buttonStyle(UpdateCapsuleButtonStyle())
                .help("重启并安装更新")
        default:
            EmptyView()
        }
    }

    private func toggleExpanded(_ root: URL) {
        if collapsedRoots.contains(root) {
            collapsedRoots.remove(root)
        } else {
            collapsedRoots.insert(root)
        }
    }

    /// v1 只为当前选中的 worktree 计算改动数。为所有 worktree 都算需要
    /// 给每个都跑一次 status，那是后台预取的活，等有了真实使用数据再做。
    private func changeCount(for worktree: Worktree) -> Int? {
        guard store.selectedWorktree?.path == worktree.path else { return nil }
        return store.workingTreeFileCount
    }

    private func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "添加"
        panel.message = "选择一个 Git 仓库目录"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await store.addRepository(at: url) }
    }
}
