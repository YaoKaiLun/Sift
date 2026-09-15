import SwiftUI

/// 文案按钮的 hover / 按下 / 手指光标。系统 `Button` 默认没有这套状态，
/// 弹层和空状态里的文字按钮都用这个，不要再裸用 `Button("…")`。
struct BorderedActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BorderedActionButton(configuration: configuration)
    }
}

private struct BorderedActionButton: View {
    let configuration: ButtonStyle.Configuration
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .font(Theme.interfaceFont)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(backgroundFill)
            }
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onHover { isHovering = $0 }
            .pointerCursor()
    }

    private var backgroundFill: Color {
        if configuration.isPressed { return Theme.iconSelectedFill }
        if isHovering { return Theme.iconHoverFill }
        return Color.primary.opacity(0.06)
    }
}
