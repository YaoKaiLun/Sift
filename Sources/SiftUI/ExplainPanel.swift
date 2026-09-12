import SwiftUI
import RepoStore
import AIClient

/// 从右侧滑出的解释面板。错误只显示在这里，不占用全局 alert。
struct ExplainPanel: View {
    @Environment(RepoStore.self) private var store

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("解释")
                    .font(Theme.headerFont)
                Spacer(minLength: 8)
                PlainIconButton(systemName: "xmark", help: "关闭") {
                    store.closeExplainPanel()
                }
            }
            .padding(.horizontal, Theme.horizontalPadding)
            .frame(height: Theme.paneHeaderHeight)
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(store.explainHistory.enumerated()), id: \.offset) { _, turn in
                        transcriptBlock(turn)
                    }
                    if !store.explainStreamingText.isEmpty {
                        Text(store.explainStreamingText)
                            .font(Theme.codeFont)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let error = store.explainError {
                        Text(error)
                            .font(Theme.secondaryFont)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    if store.explainHistory.isEmpty,
                       store.explainStreamingText.isEmpty,
                       store.explainError == nil {
                        Text("选中代码后点「解释这段」。")
                            .font(Theme.emptyDescriptionFont)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(Theme.horizontalPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack(spacing: 8) {
                TextField("追问同一选区…", text: $store.explainDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { store.submitExplainDraft() }
                Button("发送") { store.submitExplainDraft() }
                    .disabled(store.explainDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, Theme.horizontalPadding)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.chromeBackground)
    }

    @ViewBuilder
    private func transcriptBlock(_ turn: ExplainTurn) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(turn.role == .user ? "追问" : "解释")
                .font(Theme.secondaryFont)
                .foregroundStyle(.secondary)
            Text(turn.text)
                .font(Theme.codeFont)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
