import SwiftUI
import AppKit
import RepoStore

/// 模型配置弹窗：接口地址、模型、API Key。点保存才写入。
public struct SettingsView: View {
    @Environment(RepoStore.self) private var store
    @State private var revealsAPIKey = false
    @State private var baseURL = ""
    @State private var model = ""
    @State private var apiKey = ""

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 22) {
                labeledField(
                    title: "接口地址",
                    text: $baseURL,
                    prompt: "https://api.example.com/v1/chat/completions")
                labeledField(
                    title: "模型",
                    text: $model,
                    prompt: "例如 gpt-4o 或 openai/gpt-4o")
                apiKeyField
                HStack {
                    Spacer(minLength: 0)
                    Button("保存", action: save)
                        .buttonStyle(FilledActionButtonStyle())
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 22)
        }
        .frame(width: 460)
        .background(Theme.contentBackground)
        .onAppear(perform: loadFromStore)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("模型配置")
                .font(Theme.headerFont)
            Spacer(minLength: 8)
            Button(action: { store.closeExplainSettings() }) {
                Image(systemName: "xmark")
            }
            .buttonStyle(DialogIconButtonStyle())
            .help("关闭")
        }
        .padding(.horizontal, 20)
        .frame(height: Theme.paneHeaderHeight)
    }

    private func labeledField(title: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            requiredLabel(title)
            TextField("", text: text, prompt: Text(prompt))
                .textFieldStyle(.plain)
                .font(Theme.interfaceFont)
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(fieldFill, in: fieldShape)
                .iBeamCursor()
        }
    }

    private var apiKeyField: some View {
        VStack(alignment: .leading, spacing: 8) {
            requiredLabel("API Key")
            HStack(spacing: 8) {
                Group {
                    if revealsAPIKey {
                        TextField("", text: $apiKey, prompt: Text("请输入 API Key"))
                    } else {
                        SecureField("", text: $apiKey, prompt: Text("请输入 API Key"))
                    }
                }
                .textFieldStyle(.plain)
                .font(Theme.interfaceFont)
                .iBeamCursor()
                Button {
                    revealsAPIKey.toggle()
                } label: {
                    Image(systemName: revealsAPIKey ? "eye.slash" : "eye")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help(revealsAPIKey ? "隐藏密钥" : "显示密钥")
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(fieldFill, in: fieldShape)
        }
    }

    private func requiredLabel(_ title: String) -> some View {
        Text("\(title) *")
            .font(Theme.interfaceFont)
            .foregroundStyle(.primary)
    }

    private var fieldFill: Color {
        Color.primary.opacity(0.055)
    }

    private var fieldShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
    }

    private func loadFromStore() {
        baseURL = store.explainBaseURL
        model = store.explainModel
        apiKey = store.explainAPIKey
    }

    private func save() {
        store.explainBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        store.explainModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        store.explainAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        store.closeExplainSettings()
    }
}

/// 实心主按钮：比输入框矮一截；hover / 按下用和工具栏图标同一套叠色与手指光标。
private struct FilledActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        FilledActionButton(configuration: configuration)
    }
}

private struct FilledActionButton: View {
    let configuration: ButtonStyle.Configuration
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .font(Theme.interfaceFont.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 26)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(overlayFill)
                    }
            }
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onHover { isHovering = $0 }
            .pointerCursor()
    }

    private var overlayFill: Color {
        if configuration.isPressed { return Theme.iconSelectedFill }
        if isHovering { return Theme.iconHoverFill }
        return .clear
    }
}

/// 对话框关闭：和保存同一套 hover 叠色与手指光标，热区略小。
private struct DialogIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DialogIconButton(configuration: configuration)
    }
}

private struct DialogIconButton: View {
    let configuration: ButtonStyle.Configuration
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 22, height: 22)
            .background {
                RoundedRectangle(cornerRadius: Theme.iconCornerRadius, style: .continuous)
                    .fill(overlayFill)
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.iconCornerRadius, style: .continuous))
            .onHover { isHovering = $0 }
            .pointerCursor()
    }

    private var overlayFill: Color {
        if configuration.isPressed { return Theme.iconSelectedFill }
        if isHovering { return Theme.iconHoverFill }
        return .clear
    }
}
