import SwiftUI

/// 只画线，不接命中。拖动走窗口级 `NSEvent` 监听，才能压过右侧 `NSTextView`。
struct SplitDivider: View {
    var isActive: Bool = false
    var hitWidth: CGFloat = SplitOverlayLayout.defaultHitWidth

    var body: some View {
        Color.clear
            .frame(width: hitWidth)
            .frame(maxHeight: .infinity)
            .overlay {
                Rectangle()
                    .fill(isActive ? Theme.dividerActiveColor : Theme.dividerColor)
                    .frame(width: isActive ? 3 : 1)
            }
            .allowsHitTesting(false)
    }
}
