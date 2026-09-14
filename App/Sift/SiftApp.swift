import AppKit
import SwiftUI
import RepoStore
import SiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var observers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = NotificationCenter.default
        let apply: (Notification) -> Void = { note in
            guard let window = note.object as? NSWindow else { return }
            WindowChrome.apply(to: window)
        }
        observers.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main, using: apply))
        observers.append(center.addObserver(
            forName: NSWindow.didResizeNotification, object: nil, queue: .main, using: apply))
        // 全屏切换时 AppKit 会把标题栏整个重建，通知发出来的那一刻改还会被覆盖回去，
        // 所以这两个时机要在之后再补几拍。
        let reapply: (Notification) -> Void = { note in
            apply(note)
            Self.reapplyRepeatedly()
        }
        observers.append(center.addObserver(
            forName: NSWindow.didEnterFullScreenNotification, object: nil, queue: .main, using: reapply))
        observers.append(center.addObserver(
            forName: NSWindow.didExitFullScreenNotification, object: nil, queue: .main, using: reapply))

        Self.reapplyRepeatedly()
    }

    private static func reapplyRepeatedly() {
        for step in 0..<12 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * 0.08) {
                WindowChrome.applyToAllWindows()
            }
        }
    }
}

@main
struct SiftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = RepoStore()
    @State private var updates = UpdateController()

    var body: some Scene {
        @Bindable var store = store
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(updates)
                .preferredColorScheme(store.appearance.colorScheme)
                .task { await store.restore() }
                .task { await updates.check(automatic: true) }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("检查更新…") {
                    Task { await updates.check(automatic: false) }
                }
                if case .downloading = updates.state {
                    Button("取消下载") {
                        updates.cancelDownload()
                    }
                }
            }
            CommandGroup(after: .newItem) {
                Button("添加仓库…") {
                    NotificationCenter.default.post(name: .siftAddRepository, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandMenu("显示") {
                Picker("外观", selection: $store.appearance) {
                    Text("跟随系统").tag(AppearancePreference.system)
                    Text("浅色").tag(AppearancePreference.light)
                    Text("深色").tag(AppearancePreference.dark)
                }
            }
            CommandGroup(replacing: .appSettings) {
                Button("模型配置…") {
                    store.openExplainSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
