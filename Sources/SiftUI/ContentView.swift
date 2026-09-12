import SwiftUI
import RepoStore

public struct ContentView: View {
    @Environment(RepoStore.self) private var store

    public init() {}

    public var body: some View {
        NavigationSplitView {
            SourceSidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } content: {
            FileListPane()
                .navigationSplitViewColumnWidth(min: 220, ideal: 300, max: 480)
        } detail: {
            // Task 13 会把这里换成真正的 diff 视图。
            Text("选择一个文件")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .alert("出错了",
               isPresented: .constant(store.errorMessage != nil),
               presenting: store.errorMessage) { _ in
            Button("好") { store.errorMessage = nil }
        } message: { message in
            Text(message)
        }
    }
}
