import SwiftUI
import UpdateKit

struct UpdateBanner: View {
    let version: Version
    let onRestart: () -> Void

    var body: some View {
        Button(action: onRestart) {
            Text("\(version.description) 已就绪 — 点击重启")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.92), in: Capsule())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help("重启并安装更新")
    }
}

struct UpdateCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(
                Color.accentColor.opacity(configuration.isPressed ? 1 : 0.85),
                in: Capsule()
            )
            .pointerCursor()
    }
}
