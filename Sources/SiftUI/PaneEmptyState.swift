import SwiftUI

/// 中间栏和 diff 栏的空状态。系统 `ContentUnavailableView` 字号按整页设计，
/// 塞进分栏会显得过大。
struct PaneEmptyState: View {
    let title: String
    let systemImage: String
    var description: String?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(Theme.emptySymbolFont)
                .foregroundStyle(.tertiary)
            Text(title)
                .font(Theme.emptyTitleFont)
                .foregroundStyle(.secondary)
            if let description {
                Text(description)
                    .font(Theme.emptyDescriptionFont)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}
