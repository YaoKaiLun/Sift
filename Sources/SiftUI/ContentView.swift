import AppKit
import SwiftUI
import RepoStore

public struct ContentView: View {
    @Environment(RepoStore.self) private var store
    @State private var showsSidebar = true
    @State private var isFullScreen = false

    public init() {}

    public var body: some View {
        @Bindable var store = store
        // 不用 NavigationSplitView：macOS 26 会把它的侧栏渲染成带圆角和外框的
        // 悬浮玻璃面板，那圈边框在子视图里去不掉。三栏自己分。
        HStack(spacing: 0) {
            if showsSidebar {
                SourceSidebar()
                    .frame(width: store.sidebarWidth)
                SplitDivider(width: sidebarWidthBinding, range: 180...340,
                             onDragEnded: { store.persist() })
            }
            FileListPane(showsSidebar: $showsSidebar)
                .frame(width: store.fileListWidth)
            SplitDivider(width: fileListWidthBinding, range: 240...520,
                         onDragEnded: { store.persist() })
            DiffPane()
                .frame(maxWidth: .infinity)
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
        .preferredColorScheme(store.appearance.colorScheme)
        .alert("出错了",
               isPresented: .constant(store.errorMessage != nil),
               presenting: store.errorMessage) { _ in
            Button("好") { store.errorMessage = nil }
        } message: { message in
            Text(message)
        }
    }

    private var sidebarWidthBinding: Binding<CGFloat> {
        Binding(
            get: { CGFloat(store.sidebarWidth) },
            set: { store.sidebarWidth = Double($0) })
    }

    private var fileListWidthBinding: Binding<CGFloat> {
        Binding(
            get: { CGFloat(store.fileListWidth) },
            set: { store.fileListWidth = Double($0) })
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
