import AppKit
import SwiftUI

/// 分栏线。布局占 11pt 热区，视觉仍是居中的 1pt；指上去或拖动时才变粗变亮。
///
/// 变粗画在 overlay 里。热区必须自己参与命中，不能挂在 1pt 父框上——
/// 否则会被左右 pane 的布局框抢走。
struct SplitDivider: View {
    @Binding var width: CGFloat
    let range: ClosedRange<CGFloat>
    var onDragEnded: (() -> Void)? = nil
    var hitWidth: CGFloat = 11

    @State private var isHovering = false
    @State private var isDragging = false
    @State private var startWidth: CGFloat?
    @State private var didPushCursor = false

    private var isActive: Bool { isHovering || isDragging }

    var body: some View {
        Color.clear
            .frame(width: hitWidth)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .overlay {
                Rectangle()
                    .fill(Theme.dividerColor)
                    .frame(width: 1)
            }
            .overlay {
                Rectangle()
                    .fill(Theme.dividerActiveColor)
                    .frame(width: 3)
                    .opacity(isActive ? 1 : 0)
            }
            .onHover { hovering in
                isHovering = hovering
                syncCursor()
            }
            .gesture(dragGesture)
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
                onDragEnded?()
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
