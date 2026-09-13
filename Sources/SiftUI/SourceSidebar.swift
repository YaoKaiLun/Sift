import AppKit
import SwiftUI
import GitKit
import RepoStore

public extension Notification.Name {
    static let siftAddRepository = Notification.Name("app.sift.addRepository")
}

struct SourceSidebar: View {
    @Environment(RepoStore.self) private var store
    @Environment(\.trafficLightInset) private var trafficLightInset
    @State private var collapsedRoots: Set<URL> = []
    @State private var hoveredRow: String?

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
                    ForEach(Array(store.repositories.enumerated()), id: \.element.id) { index, repository in
                        repositoryRow(repository, isFirst: index == 0)
                        if !collapsedRoots.contains(repository.root) {
                            ForEach(repository.worktrees) { worktree in
                                worktreeRow(worktree)
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
        return HStack(spacing: Theme.rowSpacing) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(collapsed ? 0 : 90))
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
        let selected = store.selectedWorktree?.path == worktree.path
        return HStack(spacing: Theme.rowSpacing) {
            Image(systemName: worktree.isMain ? "folder" : "arrow.triangle.branch")
                .font(.system(size: 11))
                .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: Theme.statusColumnWidth, alignment: .center)
            Text(worktree.displayName)
                .font(Theme.interfaceFont)
                .lineLimit(1)
                .truncationMode(.middle)
            if !worktree.isMain {
                Text(worktree.path.lastPathComponent)
                    .font(Theme.secondaryFont)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            if let count = changeCount(for: worktree), count > 0 {
                Text("\(count)")
                    .font(Theme.secondaryFont.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, Theme.indentWidth)
        .rowSurface(isSelected: selected, isHovered: hoveredRow == id,
                    height: Theme.sidebarRowHeight)
        .pointerCursor()
        .onHover { hoveredRow = $0 ? id : nil }
        .onTapGesture {
            Task { await store.select(worktree: worktree) }
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
        return store.fileStatuses.count
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
