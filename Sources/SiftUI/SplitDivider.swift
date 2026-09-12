import AppKit
import SwiftUI

/// 分栏线。平时只有 1pt，指上去或拖动时才变粗变亮。
///
/// 变粗画在 overlay 里，不占布局宽度，所以两边的内容不会跟着抖。
struct SplitDivider: View {
    @Binding var width: CGFloat
    let range: ClosedRange<CGFloat>

    @State private var isHovering = false
    @State private var isDragging = false
    @State private var startWidth: CGFloat?
    @State private var didPushCursor = false

    private var isActive: Bool { isHovering || isDragging }

    var body: some View {
        Rectangle()
            .fill(Theme.dividerColor)
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .overlay {
                Rectangle()
                    .fill(Theme.dividerActiveColor)
                    .frame(width: 3)
                    .opacity(isActive ? 1 : 0)
            }
            .overlay {
                // 1pt 太细，鼠标抓不住。热区比线宽得多，但不参与布局。
                Color.clear
                    .frame(width: 11)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        isHovering = hovering
                        syncCursor()
                    }
                    .gesture(dragGesture)
            }
            .animation(.easeOut(duration: 0.12), value: isActive)
            .onDisappear(perform: popCursor)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if startWidth == nil {
                    startWidth = width
                    isDragging = true
                }
                let proposed = (startWidth ?? width) + value.translation.width
                width = min(max(proposed, range.lowerBound), range.upperBound)
            }
            .onEnded { _ in
                startWidth = nil
                isDragging = false
                syncCursor()
            }
    }

    /// push 与 pop 必须配对，漏一次光标就会一直卡在拉伸样式上。
    private func syncCursor() {
        if isActive {
            guard !didPushCursor else { return }
            NSCursor.resizeLeftRight.push()
            didPushCursor = true
        } else {
            popCursor()
        }
    }

    private func popCursor() {
        guard didPushCursor else { return }
        NSCursor.pop()
        didPushCursor = false
    }
}
