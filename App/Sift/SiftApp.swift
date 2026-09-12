import SwiftUI
import RepoStore
import SiftUI

@main
struct SiftApp: App {
    @State private var store = RepoStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .task { await store.restore() }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("添加仓库…") {
                    NotificationCenter.default.post(name: .siftAddRepository, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}
