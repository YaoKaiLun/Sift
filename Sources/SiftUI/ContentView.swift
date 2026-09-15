import AppKit
import SwiftUI
import RepoStore
import SiftLocalization

public struct ContentView: View {
    @Environment(RepoStore.self) private var store
    @Environment(UpdateController.self) private var updates
    @State private var showsSidebar = true
    @State private var isFullScreen = false
    @State private var activeSplit: SplitOverlayLayout.Divider?

    public init() {}

    public var body: some View {
        @Bindable var store = store
        // 不用 NavigationSplitView：macOS 26 会把它的侧栏渲染成带圆角和外框的
        // 悬浮玻璃面板，那圈边框在子视图里去不掉。三栏自己分。
        HStack(spacing: 0) {
            if showsSidebar {
                SourceSidebar()
                    .frame(width: store.sidebarWidth)
                    .clipped()
            }
            FileListPane(showsSidebar: $showsSidebar)
                .frame(width: store.fileListWidth)
                .clipped()
            DiffPane()
                .frame(maxWidth: .infinity)
                .clipped()
        }
        .overlay(alignment: .leading) {
            let hits = SplitOverlayLayout.hitMinXs(
                showsSidebar: showsSidebar,
                sidebarWidth: store.sidebarWidth,
                fileListWidth: store.fileListWidth)
            ZStack(alignment: .leading) {
                if let x = hits.sidebar {
                    SplitDivider(isActive: activeSplit == .sidebar)
                        .offset(x: x)
                }
                SplitDivider(isActive: activeSplit == .fileList)
                    .offset(x: hits.fileList)
            }
            .allowsHitTesting(false)
        }
        .background {
            SplitDragMonitor(
                showsSidebar: showsSidebar,
                sidebarWidth: CGFloat(store.sidebarWidth),
                fileListWidth: CGFloat(store.fileListWidth),
                onSidebarWidth: { store.sidebarWidth = Double($0) },
                onFileListWidth: { store.fileListWidth = Double($0) },
                onDragEnded: { store.persist() },
                onActiveChange: { activeSplit = $0 })
            .frame(width: 1, height: 1)
        }
        .frame(minWidth: 860, maxWidth: .infinity,
               minHeight: 480, maxHeight: .infinity)
        .background(Theme.contentBackground)
        // 栏头要顶到窗口上沿，红绿灯才会落在栏头那一行里。
        .ignoresSafeArea(.container, edges: .top)
        .siftWindowChrome()
        .environment(\.isWindowFullScreen, isFullScreen)
        .onAppear {
            isFullScreen = NSApplication.shared.windows
                .contains { $0.styleMask.contains(.fullScreen) }
        }
        .onReceive(NotificationCenter.default
            .publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            isFullScreen = true
        }
        .onReceive(NotificationCenter.default
            .publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            isFullScreen = false
        }
        .overlay {
            if store.showsExplainSettings {
                settingsOverlay
            }
        }
        .preferredColorScheme(store.appearance.colorScheme)
        .overlay(alignment: .bottom) {
            if case .ready(let version, _) = updates.state {
                UpdateBanner(version: version) {
                    updates.restart()
                }
                .padding(.bottom, 16)
            }
        }
        .alert(L10n.somethingWentWrong,
               isPresented: .constant(store.errorMessage != nil),
               presenting: store.errorMessage) { _ in
            Button(L10n.ok) { store.errorMessage = nil }
        } message: { message in
            Text(message)
        }
        .alert(L10n.checkUpdatesTitle,
               isPresented: Binding(
                get: { updates.userMessage != nil },
                set: { if !$0 { updates.userMessage = nil } }),
               presenting: updates.userMessage) { _ in
            Button(L10n.ok) { updates.userMessage = nil }
        } message: { message in
            Text(message)
        }
    }

    private var settingsOverlay: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture { store.closeExplainSettings() }
            SettingsView()
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.22), radius: 28, y: 10)
        }
        .onExitCommand { store.closeExplainSettings() }
    }

}

public extension AppearancePreference {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var symbolName: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }
}
