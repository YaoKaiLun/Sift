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
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(store.explainHistory.enumerated()), id: \.offset) { _, turn in
                        transcriptBlock(turn)
                    }
                    if store.isExplainThinking {
                        thinkingRow
                    } else if !store.explainStreamingText.isEmpty {
                        bodyText(store.explainStreamingText)
                    }
                    if let error = store.explainError {
                        Text(error)
                            .font(Theme.secondaryFont)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    if store.explainHistory.isEmpty,
                       !store.isExplainThinking,
                       store.explainStreamingText.isEmpty,
                       store.explainError == nil {
                        Text("选中代码后点「解释这段」。")
                            .font(Theme.emptyDescriptionFont)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            composer
                .padding(.horizontal, Theme.horizontalPadding)
                .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.chromeBackground)
    }

    private var thinkingRow: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("思考中...")
                .font(Theme.secondaryFont)
                .foregroundStyle(.secondary)
        }
    }

    private var composer: some View {
        @Bindable var store = store
        let canSend = !store.explainDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(spacing: 6) {
            TextField("追问同一选区…", text: $store.explainDraft)
                .textFieldStyle(.plain)
                .font(Theme.interfaceFont)
                .iBeamCursor()
                .onSubmit { store.submitExplainDraft() }
            Button(action: store.submitExplainDraft) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(canSend ? Color.white : Color.secondary.opacity(0.7))
                    .frame(width: 22, height: 22)
                    .background(
                        Circle().fill(canSend ? Color.primary : Color.primary.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .pointerCursor()
            .help("发送")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 36)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private func transcriptBlock(_ turn: ExplainTurn) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if turn.role == .user {
                Text("追问")
                    .font(Theme.secondaryFont)
                    .foregroundStyle(.secondary)
            }
            bodyText(turn.text)
        }
    }

    private func bodyText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13.5))
            .foregroundStyle(.primary)
            .lineSpacing(6)
            .multilineTextAlignment(.leading)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
