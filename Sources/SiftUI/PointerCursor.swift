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

/// 文本输入区悬停时切到 I 形光标。push/pop 必须配对。
struct IBeamCursor: ViewModifier {
    @State private var didPush = false

    func body(content: Content) -> some View {
        content.onHover { hovering in
            if hovering {
                guard !didPush else { return }
                NSCursor.iBeam.push()
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
            .pointerStyle(.link)
    }

    func iBeamCursor() -> some View {
        modifier(IBeamCursor())
    }
}
