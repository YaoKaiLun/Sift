import AppKit
import SwiftUI

/// 可点击区域悬停时切到手指光标。push/pop 必须配对。
struct PointerCursor: ViewModifier {
    @State private var didPush = false

    func body(content: Content) -> some View {
        content.onHover { hovering in
            if hovering {
                guard !didPush else { return }
                NSCursor.pointingHand.push()
                didPush = true
            } else {
                guard didPush else { return }
                NSCursor.pop()
                didPush = false
            }
        }
        .onDisappear {
            guard didPush else { return }
            NSCursor.pop()
            didPush = false
        }
    }
}

extension View {
    func pointerCursor() -> some View {
        modifier(PointerCursor())
    }
}
