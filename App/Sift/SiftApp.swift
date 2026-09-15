import AppKit
import SwiftUI
import RepoStore
import SiftLocalization
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
                Button(L10n.checkForUpdates) {
                    Task { await updates.check(automatic: false) }
                }
                if case .downloading = updates.state {
                    Button(L10n.cancelDownload) {
                        updates.cancelDownload()
                    }
                }
            }
            CommandGroup(after: .newItem) {
                Button(L10n.addRepositoryEllipsis) {
                    NotificationCenter.default.post(name: .siftAddRepository, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandMenu(L10n.displayMenu) {
                Picker(L10n.appearance, selection: $store.appearance) {
                    Text(L10n.followSystem).tag(AppearancePreference.system)
                    Text(L10n.lightAppearance).tag(AppearancePreference.light)
                    Text(L10n.darkAppearance).tag(AppearancePreference.dark)
                }
            }
            CommandGroup(replacing: .appSettings) {
                Button(L10n.modelSettingsEllipsis) {
                    store.openExplainSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
