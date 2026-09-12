import AppKit
import SwiftUI
import GitKit
import RepoStore

public extension Notification.Name {
    static let siftAddRepository = Notification.Name("app.sift.addRepository")
}

struct SourceSidebar: View {
    @Environment(RepoStore.self) private var store

    var body: some View {
        List(selection: selectionBinding) {
            ForEach(store.repositories) { repository in
                Section {
                    ForEach(repository.worktrees) { worktree in
                        WorktreeRow(worktree: worktree,
                                    changeCount: changeCount(for: worktree))
                            .tag(worktree.path)
                    }
                } header: {
                    HStack {
                        Text(repository.name)
                        Spacer()
                        // 移除按钮必须鼠标可达，不能只有右键菜单。
                        Button {
                            store.removeRepository(root: repository.root)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("移除此仓库")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button {
                presentOpenPanel()
            } label: {
                Label("添加仓库", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
        .onReceive(NotificationCenter.default.publisher(for: .siftAddRepository)) { _ in
            presentOpenPanel()
        }
    }

    private var selectionBinding: Binding<URL?> {
        Binding(
            get: { store.selectedWorktree?.path },
            set: { newValue in
                guard let newValue,
                      let worktree = store.repositories
                        .flatMap(\.worktrees).first(where: { $0.path == newValue })
                else { return }
                Task { await store.select(worktree: worktree) }
            })
    }

    /// v1 只为当前选中的 worktree 计算改动数。为所有 worktree 都算需要
    /// 给每个都跑一次 status，那是后台预取的活，等有了真实使用数据再做。
    private func changeCount(for worktree: Worktree) -> Int? {
        guard store.selectedWorktree == worktree else { return nil }
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

private struct WorktreeRow: View {
    let worktree: Worktree
    let changeCount: Int?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: worktree.isMain ? "folder" : "arrow.triangle.branch")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(worktree.displayName)
                    .lineLimit(1)
                if !worktree.isMain {
                    Text(worktree.path.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if let changeCount, changeCount > 0 {
                Text("\(changeCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
        }
        .padding(.vertical, 2)
    }
}
