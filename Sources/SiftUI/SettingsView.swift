import SwiftUI
import RepoStore

/// 标准 macOS 设置窗：Base URL、API 密钥、模型。外观切换留在侧栏。
public struct SettingsView: View {
    @Environment(RepoStore.self) private var store

    public init() {}

    public var body: some View {
        @Bindable var store = store
        Form {
            TextField("Base URL", text: $store.explainBaseURL, prompt: Text("https://api.example.com/v1"))
            SecureField("API 密钥", text: $store.explainAPIKey)
            TextField("模型", text: $store.explainModel, prompt: Text("模型名"))
        }
        .formStyle(.grouped)
        .frame(width: 440, alignment: .leading)
        .padding()
    }
}
